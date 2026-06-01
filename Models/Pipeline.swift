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
        files.lazy.filter { if case .done = $0.status { true } else { false } }.count
    }

    /// All supported RAW + DNG extensions (matches the Windows app and CLI).
    static let supportedExtensions: Set<String> = [
        "dng", "cr3", "cr2", "crw", "erf", "raf", "3fr", "kdc", "dcs",
        "dcr", "iiq", "mos", "mef", "mrw", "nef", "nrw", "orf", "rw2",
        "pef", "srw", "arw", "srf", "sr2", "ari",
    ]

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

        let filtered = collected
            .filter { !existing.contains($0) }
            .filter { dngOnly ? $0.pathExtension.lowercased() == "dng" : true }

        for url in filtered {
            let item = FileItem(url: url)
            files.append(item)
            Task { await populateCameraInfo(item) }
        }
    }

    // MARK: Processing

    /// Kicks off the batch. No-op if already processing or if exiftool isn't
    /// available. Sets isProcessing to true; observers can watch it.
    func process() {
        guard !isProcessing else { return }
        guard let exiftoolURL = toolLocator.exiftool else { return }
        guard files.contains(where: { $0.status == .pending }) else { return }

        isProcessing = true
        let exif = ExifTool(executable: exiftoolURL)
        let resolved = toolLocator.activeConverter
        let pendingItems = files.filter { $0.status == .pending }

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
                } catch {
                    item.status = .error(error.localizedDescription)
                }
            }
            self?.isProcessing = false
            self?.currentTask = nil
        }
    }

    /// Cancels the current batch. The in-flight file (if any) reverts to
    /// .pending so the next process() picks it up. TODO: also terminate the
    /// currently-running subprocess — requires exposing Process from
    /// runSubprocess, deferred until the UI Cancel button needs it.
    func cancel() {
        currentTask?.cancel()
    }

    // MARK: Internals

    /// Resolves the DNG to inject metadata into. For .dng input the file is
    /// returned as-is. For other RAW formats we'd hand off to the active
    /// converter — those wrappers don't exist yet (step 8 of the plan), so
    /// for now non-DNG paths throw.
    private func prepareDng(
        _ item: FileItem,
        converter: ResolvedConverter
    ) async throws -> URL {
        if item.url.pathExtension.lowercased() == "dng" {
            return item.url
        }
        switch converter {
        case .dngOnly:
            throw PipelineError.dngOnlyMode
        case .adobe, .dnglab:
            throw PipelineError.converterNotImplemented
        }
    }

    private func populateCameraInfo(_ item: FileItem) async {
        guard let exiftoolURL = toolLocator.exiftool else { return }
        let exif = ExifTool(executable: exiftoolURL)
        if let (make, model) = try? await exif.readMakeModel(item.url) {
            item.make = make
            item.model = model
        }
    }

    private func collectSupportedFiles(at url: URL, into result: inout [URL]) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else { return }

        if isDirectory.boolValue {
            guard let walker = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
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
    case converterNotImplemented

    var errorDescription: String? {
        switch self {
        case .dngOnlyMode:
            return "DNG-only mode — pre-convert with Lightroom Classic first"
        case .converterNotImplemented:
            return "RAW converter not yet wired up"
        }
    }
}
