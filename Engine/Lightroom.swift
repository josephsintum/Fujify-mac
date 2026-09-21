import AppKit
import Foundation

/// Finds Lightroom and hands files to it.
///
/// The action is called "Open in Lightroom", never "Open in Lightroom
/// Classic", because it opens the file with whichever Lightroom is installed
/// and must not imply a catalog import. Explanatory copy elsewhere still
/// names Lightroom Classic where the trick genuinely depends on it.
/// See docs/PIPELINE-CONTRACT.md §11.
enum Lightroom {

    /// Bundle identifiers, most preferred first.
    ///
    /// Classic comes first because the film-simulation trick only works
    /// there — the profile picker in the cloud version behaves differently.
    /// Verified on this machine: Classic is `com.adobe.LightroomClassicCC7`
    /// and the cloud app is `com.adobe.lightroomCC`.
    private static let bundleIdentifiers = [
        "com.adobe.LightroomClassicCC7",
        "com.adobe.LightroomClassicCC",
        "com.adobe.Lightroom7",
        "com.adobe.lightroomCC",
    ]

    /// The installed Lightroom, or nil. Actions that would open it hide
    /// themselves when this is nil rather than failing when clicked.
    static func installedApplication() -> URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identifier)
            {
                return url
            }
        }
        return nil
    }

    static var isInstalled: Bool { installedApplication() != nil }

    /// The app's own name, so a menu item can say "Open in Lightroom
    /// Classic" when that is genuinely what will open.
    static var installedName: String? {
        installedApplication().map {
            FileManager.default.displayName(atPath: $0.path)
                .replacingOccurrences(of: ".app", with: "")
        }
    }

    /// Opens `url` in Lightroom. Falls back to the default handler if
    /// Lightroom has gone away since the menu was built.
    static func open(_ url: URL) {
        guard let app = installedApplication() else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
    }
}
