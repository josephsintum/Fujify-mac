import SwiftUI

/// Settings window. Reachable via ⌘, or the Fujify → Settings… menu.
///
/// Two sections:
/// - RAW Converter: explicit picker for which backend the Pipeline uses,
///   plus a live readout of what was actually resolved and a button to
///   open the full ToolSetupSheet for install help.
/// - Output: the embed-original-RAW toggle.
struct SettingsView: View {
    @Environment(ToolLocator.self) private var toolLocator
    @Environment(Pipeline.self) private var pipeline
    @State private var showToolSetup = false

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

                LabeledContent("Resolved") {
                    Text(toolLocator.activeConverter.displayName)
                        .foregroundStyle(.secondary)
                }

                Button("Manage Converters…") {
                    showToolSetup = true
                }
            } header: {
                Text("RAW Converter")
            } footer: {
                Text("Auto prefers Adobe DNG Converter, falls back to dnglab. " +
                    "Manage Converters re-opens the install picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Embed original RAW in DNG", isOn: $pipeline.embedRaw)
            } header: {
                Text("Output")
            } footer: {
                Text("When on, the source RAW is embedded inside the DNG — " +
                    "roughly doubles the output file size but lets you recover " +
                    "the original without keeping the source file. " +
                    "Has no effect in DNG-only mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
        .sheet(isPresented: $showToolSetup) {
            ToolSetupSheet(toolLocator: toolLocator)
        }
    }
}
