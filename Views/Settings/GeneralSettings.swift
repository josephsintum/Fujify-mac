import AppKit
import SwiftUI

/// Settings ▸ General: what happens to the output, and what happens when a
/// batch ends.
struct GeneralSettings: View {
    @Environment(Pipeline.self) private var pipeline

    var body: some View {
        @Bindable var pipeline = pipeline

        Form {
            Section {
                LabeledContent("Save new batches to") {
                    Menu(defaultFolderLabel) {
                        Button("In place") { setDefaultFolder(nil) }
                        Divider()
                        Button("Choose Folder…") {
                            chooseDefaultFolder()
                        }
                    }
                    .fixedSize()
                }

                Toggle("Embed original RAW in DNG", isOn: $pipeline.embedRaw)

                Toggle(
                    "Skip files already tagged as the target camera",
                    isOn: $pipeline.skipAlreadyTagged
                )

                Toggle(
                    "Ask before updating DNGs in place",
                    isOn: $pipeline.confirmInPlaceDng
                )
            } header: {
                Text("Output")
            } footer: {
                Text(
                    "You can still change the folder per batch from the toolbar. "
                        + "Embedding roughly doubles the output size but lets you recover "
                        + "the original from the DNG. Re-tagging for a different camera "
                        + "always runs, even with skipping on."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show a notification", isOn: $pipeline.notifyOnFinish)
                Toggle("Reveal the output folder in Finder", isOn: $pipeline.revealOnFinish)
            } header: {
                Text("After a batch finishes")
            } footer: {
                Text("Notifications appear only when Fujify isn't the active app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var defaultFolderLabel: String {
        guard let folder = pipeline.defaultOutputFolder else { return "In place" }
        return folder.displayPath
    }

    @MainActor
    private func chooseDefaultFolder() {
        guard let url = FolderPicker.choose(message: "Choose where new batches are saved")
        else { return }
        setDefaultFolder(url)
    }

    /// Both menu items go through here so they agree. "Choose Folder…" used
    /// to apply the change to the live batch destination as well while
    /// "In place" only wrote the default, which left Settings reading
    /// "In place" and the toolbar still reading the old folder — and the
    /// next batch went to the folder.
    @MainActor
    private func setDefaultFolder(_ url: URL?) {
        pipeline.defaultOutputFolder = url
        // An empty queue means no batch is in flight, so applying the new
        // default straight away is what the user expects.
        if pipeline.files.isEmpty { pipeline.outputFolder = url }
    }
}
