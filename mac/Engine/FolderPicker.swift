import AppKit

/// The output-folder chooser, in one place.
///
/// Three views need it — the toolbar, the Inspector's recovery actions and
/// Settings — and they had drifted: two of the three had already lost
/// `allowsMultipleSelection = false`. Anything added here later (seeding
/// `directoryURL` to the last folder, a security-scoped bookmark if the app
/// is ever sandboxed) now lands in all three at once.
///
/// `runModal()` blocks, so this is deliberately synchronous; the callers'
/// only asynchrony was the wrapper.
@MainActor
enum FolderPicker {
    static func choose(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The wording every caller that picks a batch destination shares.
    static let outputFolderMessage = "Choose output folder for processed DNGs"
}
