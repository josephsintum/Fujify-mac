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
        counts: Pipeline.Counts,
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
            // outcomeSummary is empty only for an empty batch, which cannot
            // reach here in practice; the fallback keeps the body non-empty.
            let body = counts.outcomeSummary
            content.body = body.isEmpty ? "Nothing to do" : body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
