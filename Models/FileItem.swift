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

    init(url: URL) {
        self.url = url
    }

    enum Status: Equatable {
        case pending
        case processing
        case done
        case error(String)
        case skipped(reason: String)

        var isPending: Bool { if case .pending = self { true } else { false } }
        var isProcessing: Bool { if case .processing = self { true } else { false } }
        var isDone: Bool { if case .done = self { true } else { false } }
        var isError: Bool { if case .error = self { true } else { false } }
        var isSkipped: Bool { if case .skipped = self { true } else { false } }
    }

    nonisolated static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
