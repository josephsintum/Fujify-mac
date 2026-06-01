import Foundation
import AppKit
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
    }

    nonisolated static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
