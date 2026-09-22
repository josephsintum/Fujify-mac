import SwiftUI

/// Adds a target camera the built-in list doesn't cover.
///
/// The honest part of this sheet is the note at the bottom: Fujify cannot
/// check that Lightroom recognises a camera name. Only Lightroom can. So
/// rather than pretending to validate, the sheet shows exactly which tags
/// will be written and links to Adobe's list for the exact spelling.
///
/// See docs/PIPELINE-CONTRACT.md §2.
struct AddCameraSheet: View {
    @Environment(CameraStore.self) private var cameraStore
    @Environment(\.dismiss) private var dismiss

    @State private var make = "FUJIFILM"
    @State private var model = ""
    @State private var problem: String?
    @FocusState private var modelFocused: Bool

    /// What will be written, updating as the user types, so there is no
    /// guessing about what "adding a camera" actually does.
    private var preview: TargetCamera {
        TargetCamera(make: make, model: model.isEmpty ? "…" : model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a Target Camera")
                    .font(.title3.weight(.semibold))
                Text(
                    "Lightroom only offers film simulations for camera names it "
                        + "recognizes. Copy the model name exactly as Adobe lists it, "
                        + "including capitals and hyphens."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Link(destination: ExternalLinks.adobeCameraList) {
                    Label("Adobe's supported cameras list", systemImage: "arrow.up.right")
                        .font(.callout)
                }
                .buttonStyle(.link)
            }

            Form {
                TextField("Make", text: $make)
                TextField("Model", text: $model)
                    .focused($modelFocused)
                    .onSubmit(add)
            }
            .formStyle(.columns)

            tagPreview

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(
                    "Fujify can't check that Lightroom knows this camera. If the "
                        + "simulations don't appear after import, compare the spelling "
                        + "with Adobe's list."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Camera", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { modelFocused = true }
    }

    private var tagPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags Fujify will write to each DNG")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                ForEach(preview.injectedTags, id: \.name) { tag in
                    tagRow(tag.name, tag.value)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private func tagRow(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
        }
    }

    private func add() {
        switch cameraStore.add(make: make, model: model) {
        case .added:
            dismiss()
        case .duplicate(let existing):
            problem = "\(existing.displayName) is already in the list."
        case .invalid(let reason):
            problem = reason
        }
    }
}
