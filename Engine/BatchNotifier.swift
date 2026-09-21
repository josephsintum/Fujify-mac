import AppKit
import Foundation
import UserNotifications

/// Tells the user a batch finished, when they are not looking at Fujify.
///
/// A 2,000-file batch takes the better part of an hour, and nobody watches a
/// progress bar for that long. Notifying only when the app is inactive keeps
/// it useful without interrupting someone who is already watching.
enum BatchNotifier {

    /// Asked for the first time a batch finishes rather than at launch, so
    /// the permission prompt arrives with an obvious reason attached.
    private static var hasRequestedAuthorization = false

    static func batchFinished(
        done: Int,
        skipped: Int,
        failed: Int,
        notify: Bool,
        revealFolder: URL?
    ) {
        if let revealFolder {
            NSWorkspace.shared.activateFileViewerSelecting([revealFolder])
        }

        guard notify, !NSApplication.shared.isActive else { return }

        Task {
            let center = UNUserNotificationCenter.current()

            if !hasRequestedAuthorization {
                hasRequestedAuthorization = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }

            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }

            let content = UNMutableNotificationContent()
            content.title = "Fujify finished"
            content.body = summary(done: done, skipped: skipped, failed: failed)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    /// "2,046 done · 9 skipped · 2 failed", leaving out whatever is zero.
    static func summary(done: Int, skipped: Int, failed: Int) -> String {
        var parts: [String] = []
        if done > 0 { parts.append("\(done.formatted()) done") }
        if skipped > 0 { parts.append("\(skipped.formatted()) skipped") }
        if failed > 0 { parts.append("\(failed.formatted()) failed") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: " · ")
    }
}
