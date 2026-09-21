import Foundation
import Observation

/// Batch orchestrator. Walks input URLs, queues FileItems, and processes them
/// one at a time against the active converter and exiftool.
///
/// The batch is deliberately serial: converters already saturate the CPU and
/// the disk is the bottleneck, so running several at once made throughput
/// worse and the progress bar meaningless. See docs/PIPELINE-CONTRACT.md §10.
@Observable @MainActor
final class Pipeline {
    var files: [FileItem] = []
    private(set) var isProcessing: Bool = false
    var outputFolder: URL?

    var embedRaw: Bool {
        didSet { UserDefaults.standard.set(embedRaw, forKey: Self.embedRawKey) }
    }

    /// Skip files that already claim to be the current target (§9).
    var skipAlreadyTagged: Bool {
        didSet {
            UserDefaults.standard.set(skipAlreadyTagged, forKey: Self.skipAlreadyTaggedKey)
        }
    }

    /// Ask before rewriting DNGs in place (§7). The UI does the asking;
    /// `process` just honours whatever it decided.
    var confirmInPlaceDng: Bool {
        didSet {
            UserDefaults.standard.set(confirmInPlaceDng, forKey: Self.confirmInPlaceKey)
        }
    }

    let toolLocator: ToolLocator

    private(set) var batchStartedAt: Date?
    private(set) var batchFinishedAt: Date?

    /// The task running the current batch, retained so cancel() can abort it.
    private var currentTask: Task<Void, Never>?

    private static let embedRawKey = "embedRaw"
    private static let skipAlreadyTaggedKey = "skipAlreadyTagged"
    private static let confirmInPlaceKey = "confirmInPlaceDng"

    init(toolLocator: ToolLocator, defaults: UserDefaults = .standard) {
        self.toolLocator = toolLocator
        self.embedRaw = defaults.bool(forKey: Self.embedRawKey)
        // Both default to on, so an absent key has to read as true.
        self.skipAlreadyTagged =
            defaults.object(forKey: Self.skipAlreadyTaggedKey) as? Bool ?? true
        self.confirmInPlaceDng =
            defaults.object(forKey: Self.confirmInPlaceKey) as? Bool ?? true
    }

    /// All supported RAW + DNG extensions. Locked to the contract (§5.1) by
    /// Tests/SupportedExtensionsTests.swift.
    static let supportedExtensions: Set<String> = [
        "dng", "cr3", "cr2", "crw", "erf", "raf", "3fr", "kdc", "dcs",
        "dcr", "iiq", "mos", "mef", "mrw", "nef", "nrw", "orf", "rw2",
        "pef", "srw", "arw", "srf", "sr2", "ari",
    ]

    /// Cap on how many camera-info / thumbnail tasks run at once. Each spawns
    /// a subprocess and/or QuickLook work — letting thousands fan out at once
    /// would thrash CPU and file descriptors.
    private static let populateConcurrency = 8

    // MARK: Derived state

    struct Counts: Equatable {
        var pending = 0
        var processing = 0
        var done = 0
        var skipped = 0
        var failed = 0

        var total: Int { pending + processing + done + skipped + failed }
        /// Everything that will not be worked on again without user action.
        var settled: Int { done + skipped + failed }
    }

    var counts: Counts {
        var counts = Counts()
        for file in files {
            switch file.status {
            case .pending: counts.pending += 1
            case .processing: counts.processing += 1
            case .done: counts.done += 1
            case .skipped: counts.skipped += 1
            case .failed: counts.failed += 1
            }
        }
        return counts
    }

    var completedCount: Int { counts.settled }

    /// How many queued DNGs would be rewritten in place if the batch started
    /// now. Drives the confirmation in §7; zero means nothing to ask about.
    var pendingInPlaceDngCount: Int {
        guard outputFolder == nil else { return 0 }
        return files.filter {
            $0.status.isPending && $0.url.pathExtension.lowercased() == "dng"
        }.count
    }

    /// Rough time left, from how long the settled files actually took. Nil
    /// until enough has finished to mean anything.
    var estimatedRemaining: TimeInterval? {
        guard isProcessing, let started = batchStartedAt else { return nil }
        let counts = counts
        guard counts.settled >= 3, counts.pending > 0 else { return nil }
        let perFile = Date().timeIntervalSince(started) / Double(counts.settled)
        return perFile * Double(counts.pending)
    }

    /// How long the finished batch took, for the status bar.
    var batchDuration: TimeInterval? {
        guard let start = batchStartedAt, let end = batchFinishedAt else { return nil }
        return end.timeIntervalSince(start)
    }

    // MARK: Adding files

    /// Adds files to the queue. Folders are walked recursively. Unsupported
    /// extensions and duplicates (by URL) are silently filtered out. When the
    /// active converter is .dngOnly, non-DNG files are still added but marked
    /// `.skipped` so the user sees why they can't be processed rather than
    /// having them silently vanish.
    func add(_ urls: [URL]) async {
        let dngOnly = (toolLocator.activeConverter == .dngOnly)
        let existing = Set(files.map(\.url))

        var collected: [URL] = []
        for url in urls {
            collectSupportedFiles(at: url, into: &collected)
        }

        let newItems =
            collected
            .filter { !existing.contains($0) }
            .map { url -> FileItem in
                let item = FileItem(url: url)
                if dngOnly, url.pathExtension.lowercased() != "dng" {
                    item.status = .skipped(.dngOnlyMode)
                }
                files.append(item)
                return item
            }

        Task { [weak self] in await self?.populateMetadata(for: newItems) }
    }

    /// Re-evaluates queued non-DNG files against the active converter. Call
    /// after the converter changes: in DNG-only mode pending RAWs become
    /// skipped; once a converter is available, items previously skipped for
    /// lack of one flip back to pending so they can be retried without
    /// re-adding.
    func refreshConverterAvailability() {
        let dngOnly = (toolLocator.activeConverter == .dngOnly)
        for item in files where item.url.pathExtension.lowercased() != "dng" {
            switch (dngOnly, item.status) {
            case (true, .pending):
                item.status = .skipped(.dngOnlyMode)
            case (false, .skipped(.dngOnlyMode)), (false, .skipped(.unsupportedCamera)):
                item.status = .pending
            default:
                break
            }
        }
    }

    /// Removes the files with the given ids from the queue.
    func remove(_ ids: Set<FileItem.ID>) {
        files.removeAll { ids.contains($0.id) }
    }

    // MARK: Retrying

    /// Returns failed and skipped items to pending so the next batch picks
    /// them up. Done items are left alone — use `reprocess` for those.
    func retry(_ ids: Set<FileItem.ID>) {
        for item in files where ids.contains(item.id) && item.status.isRetryable {
            item.status = .pending
        }
    }

    /// Returns items to pending and forces them past the already-tagged skip.
    /// This is what "Process Again" does, and the only way to re-tag a file
    /// the skip rule would otherwise pass over.
    func reprocess(_ ids: Set<FileItem.ID>) {
        for item in files where ids.contains(item.id) {
            guard !item.status.isProcessing else { continue }
            item.forceReprocess = true
            item.status = .pending
        }
    }

    /// Retries everything that failed or was skipped, for the status bar's
    /// "Retry All" when a filter is active.
    func retryAll() {
        for item in files where item.status.isRetryable {
            item.status = .pending
        }
    }

    // MARK: Processing

    /// Kicks off the batch against `target`. No-op if already processing, if
    /// exiftool is missing, or if nothing is pending.
    ///
    /// The in-place confirmation (§7) is the UI's job and must happen before
    /// this is called.
    func process(target: TargetCamera) {
        guard !isProcessing else { return }
        guard let exif = toolLocator.makeExifTool() else { return }
        guard files.contains(where: { $0.status.isPending }) else { return }

        isProcessing = true
        batchStartedAt = Date()
        batchFinishedAt = nil

        let resolved = toolLocator.activeConverter

        currentTask = Task { @MainActor [weak self] in
            // Reads the live queue rather than a snapshot, so files dropped
            // in mid-batch are picked up and removals are honoured.
            while let item = self?.files.first(where: { $0.status.isPending }) {
                guard !Task.isCancelled, let self else { break }
                await self.processOne(item, target: target, converter: resolved, exif: exif)
            }
            self?.isProcessing = false
            self?.batchFinishedAt = Date()
            self?.currentTask = nil
        }
    }

    /// Cancels the current batch. The running child process gets SIGTERM via
    /// runSubprocess's cancellation handler; the in-flight file reverts to
    /// pending and any half-written output is deleted (§10).
    func cancel() {
        currentTask?.cancel()
    }

    private func processOne(
        _ item: FileItem,
        target: TargetCamera,
        converter: ResolvedConverter,
        exif: ExifTool
    ) async {
        // Where the output will land, needed by the cancellation cleanup as
        // well as by the work itself.
        let destination = destinationURL(for: item)
        let isInPlace = destination.standardizedFileURL == item.url.standardizedFileURL

        do {
            if let reason = await skipReason(for: item, target: target, exif: exif) {
                item.status = .skipped(reason)
                item.forceReprocess = false
                return
            }

            item.status = .processing(.convert)
            try Task.checkCancellation()
            try await prepareDng(item, destination: destination, converter: converter)

            item.status = .processing(.writeTags)
            try Task.checkCancellation()
            try await exif.inject(target: target, into: destination)

            item.outputURL = destination
            item.converterUsed = converter
            item.forceReprocess = false
            item.status = .done
        } catch is CancellationError {
            // Never leave a half-written DNG behind. The source is only
            // deleted if it *is* the destination, which cannot happen because
            // an in-place run never creates a new file.
            if !isInPlace {
                try? FileManager.default.removeItem(at: destination)
            }
            item.status = .pending
        } catch DngLabError.unsupportedCamera(let model) {
            item.status = .skipped(.unsupportedCamera(model: model))
        } catch let failure as ProcessingFailure {
            item.status = .failed(failure)
        } catch PipelineError.dngOnlyMode {
            item.status = .skipped(.dngOnlyMode)
        } catch let error as ExifToolError {
            item.status = .failed(
                ProcessingFailure.classify(
                    stderr: error.localizedDescription, step: .writeTags, tool: .exiftool))
        } catch {
            item.status = .failed(
                ProcessingFailure(
                    step: .convert, tool: .exiftool, cause: .other,
                    toolOutput: error.localizedDescription))
        }
    }

    /// Whether this file should be passed over without doing any work.
    private func skipReason(
        for item: FileItem,
        target: TargetCamera,
        exif: ExifTool
    ) async -> SkipReason? {
        guard Self.mightBeAlreadyTagged(
            url: item.url,
            skipEnabled: skipAlreadyTagged,
            forceReprocess: item.forceReprocess
        ) else { return nil }

        guard let tags = try? await exif.readCameraTags(item.url) else { return nil }
        guard tags.alreadyTagged(as: target) else { return nil }
        return .alreadyTagged(as: target.displayName)
    }

    /// Whether it is even worth reading a file's tags to decide about the
    /// already-tagged skip (§9).
    ///
    /// Pure, so the three conditions can be tested without a real file or a
    /// real exiftool. Only a DNG can already carry the tags — a RAW never
    /// does, and any DNG about to be created is brand new — so skipping the
    /// read for RAW input also saves a subprocess per file in a large batch.
    static func mightBeAlreadyTagged(
        url: URL,
        skipEnabled: Bool,
        forceReprocess: Bool
    ) -> Bool {
        guard skipEnabled else { return false }
        guard !forceReprocess else { return false }
        return url.pathExtension.lowercased() == "dng"
    }

    // MARK: Internals

    /// Where this item's output DNG belongs.
    ///
    /// With no output folder the file stays beside its source, which for DNG
    /// input means the source itself — the in-place case the user confirms.
    private func destinationURL(for item: FileItem) -> URL {
        let outputDir = outputFolder ?? item.url.deletingLastPathComponent()
        let stem = item.url.deletingPathExtension().lastPathComponent
        return outputDir.appendingPathComponent(stem + ".dng")
    }

    /// Gets a DNG in place at `destination`, converting if necessary.
    ///
    /// - DNG input, destination is the source: nothing to do; the exiftool
    ///   step edits it in place.
    /// - DNG input, different destination: copied atomically so the source
    ///   stays untouched.
    /// - Other RAW: handed to the active converter.
    private func prepareDng(
        _ item: FileItem,
        destination: URL,
        converter: ResolvedConverter
    ) async throws {
        let src = item.url

        if src.pathExtension.lowercased() == "dng" {
            guard destination.standardizedFileURL != src.standardizedFileURL else { return }
            do {
                try atomicallyCopy(from: src, to: destination)
            } catch {
                throw ProcessingFailure.classify(
                    stderr: error.localizedDescription, step: .convert, tool: .exiftool)
            }
            return
        }

        switch converter {
        case .dngOnly:
            throw PipelineError.dngOnlyMode
        case .adobe(let executable):
            try await AdobeDngConverter(executable: executable)
                .convert(src: src, dst: destination, embedRaw: embedRaw)
        case .dnglab(let executable):
            try await DngLab(executable: executable)
                .convert(src: src, dst: destination, embedRaw: embedRaw)
        }
    }

    /// Runs camera-info + thumbnail population across the given items with
    /// bounded concurrency, so adding 10k files doesn't spawn 20k tasks.
    private func populateMetadata(for items: [FileItem]) async {
        guard let exif = toolLocator.makeExifTool() else { return }
        await withTaskGroup(of: Void.self) { group in
            for (index, item) in items.enumerated() {
                if index >= Self.populateConcurrency {
                    await group.next()
                }
                group.addTask {
                    await self.populateCameraInfo(item, exif: exif)
                    await self.populateThumbnail(item)
                }
            }
        }
    }

    private func populateCameraInfo(_ item: FileItem, exif: ExifTool) async {
        guard let (make, model) = try? await exif.readMakeModel(item.url) else { return }
        // The item may have been removed mid-populate; don't write to it.
        guard files.contains(where: { $0.id == item.id }) else { return }
        item.make = make
        item.model = model
    }

    private func populateThumbnail(_ item: FileItem) async {
        let thumbnail = await Thumbnail.generate(for: item.url)
        guard files.contains(where: { $0.id == item.id }) else { return }
        item.thumbnail = thumbnail
    }

    private func collectSupportedFiles(at url: URL, into result: inout [URL]) {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { return }

        if isDirectory.boolValue {
            guard
                let walker = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { return }
            for case let child as URL in walker where isSupported(child) {
                result.append(child)
            }
        } else if isSupported(url) {
            result.append(url)
        }
    }

    private func isSupported(_ url: URL) -> Bool {
        Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

enum PipelineError: Error, LocalizedError {
    case dngOnlyMode

    var errorDescription: String? {
        switch self {
        case .dngOnlyMode: return SkipReason.dngOnlyMode.summary
        }
    }
}

/// Copies `src` to `dst` such that an existing file at `dst` is only replaced
/// after the copy fully completes. Uses a sibling temp file so a failed copy
/// can't leave the user's destination missing.
func atomicallyCopy(from src: URL, to dst: URL) throws {
    let tempName = "." + UUID().uuidString + "." + dst.lastPathComponent
    let temp = dst.deletingLastPathComponent().appendingPathComponent(tempName)
    try FileManager.default.copyItem(at: src, to: temp)
    do {
        if FileManager.default.fileExists(atPath: dst.path) {
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: dst)
        }
    } catch {
        try? FileManager.default.removeItem(at: temp)
        throw error
    }
}
