import SwiftUI

/// Settings window. Reachable via ⌘, or the Fujify → Settings… menu.
///
/// Interim single-page form. Stage 6 of the design rework replaces this with
/// the three-tab window on the canvas (General, Cameras, Converter); what is
/// here now is the minimum that keeps every setting reachable while the
/// engine work lands.
struct SettingsView: View {
    @Environment(ToolLocator.self) private var toolLocator
    @Environment(Pipeline.self) private var pipeline
    @State private var isRechecking = false

    var body: some View {
        @Bindable var toolLocator = toolLocator
        @Bindable var pipeline = pipeline

        Form {
            Section {
                Picker("Converter", selection: $toolLocator.preferredConverter) {
                    ForEach(ConverterPreference.allCases, id: \.self) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                .onChange(of: toolLocator.preferredConverter) {
                    pipeline.refreshConverterAvailability()
                }

                LabeledContent("In use") {
                    Text(toolLocator.activeConverter.displayName)
                        .foregroundStyle(.secondary)
                }

                toolRow("Adobe DNG Converter", tool: toolLocator.adobeDngConverter)
                toolRow("dnglab", tool: toolLocator.dnglab)
                toolRow("exiftool", tool: toolLocator.exiftool)

                Button(isRechecking ? "Checking…" : "Check Again") {
                    Task {
                        isRechecking = true
                        await toolLocator.probe()
                        pipeline.refreshConverterAvailability()
                        isRechecking = false
                    }
                }
                .disabled(isRechecking)
            } header: {
                Text("RAW Converter")
            } footer: {
                Text(
                    "dnglab and exiftool ship with Fujify, so there is nothing to "
                        + "install. Adobe DNG Converter is optional and supports the "
                        + "widest range of cameras, including newer bodies dnglab "
                        + "doesn't cover yet."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
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
                    "Embedding roughly doubles the output size but lets you recover "
                        + "the original from the DNG. Re-tagging for a different camera "
                        + "always runs, even with skipping on."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
    }

    @ViewBuilder
    private func toolRow(_ name: String, tool: LocatedTool?) -> some View {
        LabeledContent(name) {
            if let tool {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(tool.source.isBundled ? "Built in · \(tool.version)" : tool.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Not installed")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
