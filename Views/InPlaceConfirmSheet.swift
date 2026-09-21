import SwiftUI

/// Asks before rewriting DNGs in place.
///
/// Converting a RAW produces a new file and leaves the original alone.
/// Tagging a DNG with no output folder set does not: it rewrites the camera
/// identity inside the file the user already has, and photographers keep
/// DNGs as masters. So this is asked once per batch rather than being
/// allowed to happen quietly.
///
/// Drawn as a sheet rather than an `.alert` because an alert cannot carry
/// the "Don't ask again" toggle. See docs/PIPELINE-CONTRACT.md §7.
struct InPlaceConfirmSheet: View {
    let dngCount: Int
    let rawCount: Int
    @Binding var suppressFutureAsks: Bool

    let onUpdateInPlace: () -> Void
    let onChooseFolder: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Don't ask again", isOn: $suppressFutureAsks)
                .font(.callout)
                .toggleStyle(.checkbox)

            VStack(spacing: 8) {
                Button("Update in Place") {
                    dismiss()
                    onUpdateInPlace()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)

                Button("Choose Folder…") {
                    dismiss()
                    onChooseFolder()
                }
                .frame(maxWidth: .infinity)

                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 320)
    }

    private var title: String {
        dngCount == 1
            ? "Update 1 DNG in place?"
            : "Update \(dngCount.formatted()) DNGs in place?"
    }

    private var message: String {
        var text =
            "Save to is set to In place, so Fujify will rewrite the camera tags "
            + "inside "
            + (dngCount == 1 ? "this DNG file." : "these DNG files.")
        if rawCount > 0 {
            text +=
                " Your \(rawCount.formatted()) RAW "
                + (rawCount == 1 ? "file is" : "files are")
                + " converted to new DNGs and never changed."
        }
        return text
    }
}
