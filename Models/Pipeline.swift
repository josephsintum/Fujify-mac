import Foundation
import Observation

/// Batch orchestrator. Walks input URLs, queues FileItems, processes them
/// serially against ExifTool (+ a converter, once wired up).
@Observable @MainActor
final class Pipeline {
    var files: [FileItem] = []
    var isProcessing: Bool = false
    var outputFolder: URL?
    var embedRaw: Bool = false

    let toolLocator: ToolLocator

    /// The task running the current batch, retained so cancel() can abort it.
    private var currentTask: Task<Void, Never>?

    init(toolLocator: ToolLocator) {
        self.toolLocator = toolLocator
    }

    var completedCount: Int {
        files.lazy.filter { $0.status.isDone }.count
    }

    /// All supported RAW + DNG extensions (matches the Windows app and CLI).
    static let supportedExtensions: Set<String> = [
        "dng", "cr3", "cr2", "crw", "erf", "raf", "3fr", "kdc", "dcs",
        "dcr", "iiq", "mos", "mef", "mrw", "nef", "nrw", "orf", "rw2",
        "pef", "srw", "arw", "srf", "sr2", "ari",
    ]

    /// Cap on how many camera-info / thumbnail tasks run at once. Each
    /// spawns a subprocess (exiftool) and/or QuickLook work — letting
    /// thousands fan out at once would thrash CPU and FDs.
    private static let populateConcurrency = 8

    // MARK: Adding files

    /// Adds files to the queue. Folders are walked recursively. Unsupported
    /// extensions and duplicates (by URL) are silently filtered out. When
    /// the active converter is .dngOnly, non-DNG files are also dropped.
    func add(_ urls: [URL]) async {
        let dngOnly = (toolLocator.activeConverter == .dngOnly)
        let existing = Set(files.map(\.url))

        var collected: [URL] = []
        for url in urls {
            collectSupportedFiles(at: url, into: &collected)
        }

        let filtered =
            collected
            .filter { !existing.contains($0) }
            .filter { dngOnly ? $0.pathExtension.lowercased() == "dng" : true }

        let newItems = filtered.map { url -> FileItem in
            let item = FileItem(url: url)
            files.append(item)
            return item
        }

        Task { [weak self] in await self?.populateMetadata(for: newItems) }
    }

    /// Removes the files with the given ids from the queue. Files currently
    /// being processed remain in their in-flight Task (the batch holds its
    /// own captured snapshot) but disappear from the visible list.
    func remove(_ ids: Set<FileItem.ID>) {
        files.removeAll { ids.contains($0.id) }
    }

    // MARK: Processing

    /// Kicks off the batch. No-op if already processing or if exiftool isn't
    /// available. Sets isProcessing to true; observers can watch it.
    func process() {
        guard !isProcessing else { return }
        guard let exiftoolURL = toolLocator.exiftool else { return }
        guard files.contains(where: { $0.status.isPending }) else { return }

        isProcessing = true
        let exif = ExifTool(executable: exiftoolURL)
        let resolved = toolLocator.activeConverter
        let pendingItems = files.filter { $0.status.isPending }

        currentTask = Task { @MainActor [weak self] in
            for item in pendingItems {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                item.status = .processing

                do {
                    let dng = try await self.prepareDng(item, converter: resolved)
                    try await exif.injectFujiMetadata(dng: dng)
                    item.status = .done
                } catch is CancellationError {
                    item.status = .pending
                    break
                } catch DngLabError.unsupportedCamera(let model) {
                    item.status = .skipped(
                        reason: "Unsupported camera (\(model)). "
                            + "Try Adobe DNG Converter or pre-convert with Lightroom Classic."
                    )
                } catch PipelineError.dngOnlyMode {
                    item.status = .skipped(
                        reason: "DNG-only mode — pre-convert with Lightroom Classic first."
                    )
                } catch {
                    item.status = .error(error.localizedDescription)
                }
            }
            self?.isProcessing = false
            self?.currentTask = nil
        }
    }

    /// Cancels the current batch. Subprocess gets SIGTERM via Subprocess's
    /// cancellation handler; the in-flight file reverts to .pending.
    func cancel() {
        currentTask?.cancel()
    }

    // MARK: Internals

    /// Resolves the DNG to inject metadata into.
    ///
    /// - For `.dng` input with no output folder: returns the source — the
    ///   exiftool step modifies it in place.
    /// - For `.dng` input with an output folder: copies the DNG into that
    ///   folder atomically so the source stays untouched.
    /// - For other RAW formats: dispatches to the active converter, which
    ///   produces a DNG either alongside the source (no output folder) or
    ///   inside the chosen output folder.
    private func prepareDng(
        _ item: FileItem,
        converter: ResolvedConverter
    ) async throws -> URL {
        let src = item.url
        let outputDir = outputFolder ?? src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        let dst = outputDir.appendingPathComponent(stem + ".dng")

        if src.pathExtension.lowercased() == "dng" {
            if dst.standardizedFileURL == src.standardizedFileURL {
                return src
            }
            try atomicallyCopy(from: src, to: dst)
            return dst
        }

        switch converter {
        case .dngOnly:
            throw PipelineError.dngOnlyMode
        case .adobe(let executable):
            try await AdobeDngConverter(executable: executable)
                .convert(src: src, dst: dst, embedRaw: embedRaw)
        case .dnglab(let executable):
            try await DngLab(executable: executable)
                .convert(src: src, dst: dst, embedRaw: embedRaw)
        }
        return dst
    }

    /// Runs camera-info + thumbnail population across the given items with
    /// bounded concurrency. We use a sliding window so adding 10k files at
    /// once doesn't spawn 20k concurrent tasks against exiftool/QuickLook.
    /// Strong self is fine — Pipeline lives for the app's lifetime.
    private func populateMetadata(for items: [FileItem]) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, item) in items.enumerated() {
                if index >= Self.populateConcurrency {
                    await group.next()
                }
                group.addTask {
                    await self.populateCameraInfo(item)
                    await self.populateThumbnail(item)
                }
            }
        }
    }

    private func populateCameraInfo(_ item: FileItem) async {
        guard let exiftoolURL = toolLocator.exiftool else { return }
        let exif = ExifTool(executable: exiftoolURL)
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
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
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
        case .dngOnlyMode:
            return "DNG-only mode — pre-convert with Lightroom Classic first"
        }
    }
}

/// Copies `src` to `dst` such that an existing file at `dst` is only
/// replaced after the copy fully completes. Uses a sibling temp file so a
/// failed copy can't leave the user's destination missing.
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
