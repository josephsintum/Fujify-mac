import AppKit
import Foundation
import Observation

@Observable @MainActor
final class FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    var status: Status = .pending
    var make: String = ""
    var model: String = ""
    var thumbnail: NSImage?

    /// Where the processed DNG ended up. Set on success so "Show Output DNG"
    /// and "Open in Lightroom" have something to point at, and so the
    /// Inspector reads the output rather than the source.
    var outputURL: URL?

    /// Which converter produced the output, for the Inspector's Result card.
    var converterUsed: ResolvedConverter?

    /// Set by "Process Again" to bypass the already-tagged skip for this file
    /// only. Cleared once the file has been processed.
    var forceReprocess: Bool = false

    init(url: URL) {
        self.url = url
    }

    /// The file the Inspector should read and actions should target: the
    /// output once there is one, otherwise the source.
    var inspectionURL: URL { outputURL ?? url }

    enum Status: Equatable {
        case pending
        case processing(ProcessingStep)
        case done
        case failed(ProcessingFailure)
        case skipped(SkipReason)

        var isPending: Bool { if case .pending = self { true } else { false } }
        var isProcessing: Bool { if case .processing = self { true } else { false } }
        var isDone: Bool { if case .done = self { true } else { false } }
        var isFailed: Bool { if case .failed = self { true } else { false } }
        var isSkipped: Bool { if case .skipped = self { true } else { false } }

        /// Failed and skipped items are both offered Retry.
        var isRetryable: Bool { isFailed || isSkipped }

        /// The one word the Status column leads with.
        var label: String {
            switch self {
            case .pending: return "Pending"
            case .processing(.convert): return "Converting…"
            case .processing(.writeTags): return "Writing tags…"
            case .done: return "Done"
            case .failed: return "Failed"
            case .skipped: return "Skipped"
            }
        }

        /// The grey text after the middle dot in the Status column. The full
        /// explanation lives in the Inspector.
        var shortReason: String? {
            switch self {
            case .failed(let failure): return failure.shortReason
            case .skipped(let reason): return reason.shortReason
            case .pending, .processing, .done: return nil
            }
        }
    }

    nonisolated static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
