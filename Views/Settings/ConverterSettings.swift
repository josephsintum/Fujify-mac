import SwiftUI

/// Settings ▸ Converter: which tool turns RAW into DNG, and what is actually
/// installed.
///
/// This replaces the old first-launch setup sheet. dnglab and exiftool ship
/// inside the app, so nothing interrupts launch any more; this page exists
/// for the user who wants Adobe's wider camera support, or who wants to see
/// what is being used.
struct ConverterSettings: View {
    @Environment(ToolLocator.self) private var toolLocator
    @Environment(Pipeline.self) private var pipeline

    @State private var isRechecking = false

    var body: some View {
        @Bindable var toolLocator = toolLocator

        Form {
            Section {
                Picker(selection: $toolLocator.preferredConverter) {
                    ForEach(ConverterPreference.allCases, id: \.self) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: toolLocator.preferredConverter) {
                    pipeline.refreshConverterAvailability()
                }

                LabeledContent("In use") {
                    Text(toolLocator.activeConverter.displayName)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("RAW to DNG converter")
            } footer: {
                Text(
                    "Automatic prefers Adobe DNG Converter and falls back to the "
                        + "built-in dnglab. Choosing a converter that isn't installed "
                        + "switches to DNG-only rather than quietly using the other one."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                toolRow(
                    "Adobe DNG Converter",
                    tool: toolLocator.adobeDngConverter,
                    detail: "Widest camera support, including newer bodies. Free from Adobe.",
                    missingAction: ("Download from Adobe", ExternalLinks.adobeDngConverter)
                )
                toolRow(
                    "dnglab",
                    tool: toolLocator.dnglab,
                    detail: "Ships with Fujify. Doesn't support some newer bodies yet.",
                    missingAction: ("Get dnglab", ExternalLinks.dnglab)
                )
                toolRow(
                    "exiftool",
                    tool: toolLocator.exiftool,
                    detail: "Ships with Fujify. Writes the camera tags.",
                    missingAction: nil
                )

                HStack {
                    Button(isRechecking ? "Checking…" : "Check Again", action: recheck)
                        .disabled(isRechecking)
                    Text("Fujify looks in /Applications each time it starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Installed tools")
            } footer: {
                Text(
                    "Nothing to install. A newer exiftool or dnglab in /opt/homebrew/bin "
                        + "is used automatically if you have one."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func toolRow(
        _ name: String,
        tool: LocatedTool?,
        detail: String,
        missingAction: (title: String, url: URL)?
    ) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                if !toolLocator.hasProbed {
                    ProgressView().controlSize(.small)
                } else if let tool {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(statusText(for: tool))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not installed")
                        .foregroundStyle(.secondary)
                    if let missingAction {
                        Link(missingAction.title, destination: missingAction.url)
                            .font(.callout)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(for tool: LocatedTool) -> String {
        switch tool.source {
        case .bundled: return "Built in · \(tool.version)"
        case .installed(let url):
            return "\(tool.version) · \(url.displayPath)"
        }
    }

    private func recheck() {
        Task {
            isRechecking = true
            await toolLocator.probe()
            pipeline.refreshConverterAvailability()
            isRechecking = false
        }
    }
}
