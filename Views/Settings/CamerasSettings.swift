import SwiftUI

/// Settings ▸ Cameras: the default target, and the list of cameras to
/// choose from.
struct CamerasSettings: View {
    @Environment(CameraStore.self) private var cameraStore

    @State private var selection: TargetCamera.ID?
    @State private var showAddCamera = false

    private static let adobeCameraList = URL(
        string: "https://helpx.adobe.com/camera-raw/kb/camera-raw-plug-supported-cameras.html"
    )!

    var body: some View {
        @Bindable var cameraStore = cameraStore

        Form {
            Section {
                Picker("Default for new batches", selection: $cameraStore.selectedTarget) {
                    ForEach(cameraStore.allCameras) { camera in
                        Text(camera.displayName).tag(camera)
                    }
                }
            } header: {
                Text("Target camera")
            } footer: {
                Text(
                    "Lightroom will treat every processed DNG as this camera. "
                        + "You can change it per batch from the toolbar."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                List(selection: $selection) {
                    ForEach(cameraStore.allCameras) { camera in
                        cameraRow(camera).tag(camera.id)
                    }
                }
                .frame(minHeight: 150)
                .alternatingRowBackgrounds()

                HStack(spacing: 6) {
                    Button {
                        showAddCamera = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add a camera")

                    Button {
                        if let camera = selectedCamera { cameraStore.remove(camera) }
                        selection = nil
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedCamera.map(\.isBuiltIn) ?? true)
                    .help("Remove the selected camera")

                    Text("Built-in cameras can't be removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } header: {
                Text("Cameras")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Copy model names exactly as Adobe lists them. Fujify can't "
                            + "check that Lightroom recognizes a name you add."
                    )
                    Link(
                        "Adobe's supported cameras list",
                        destination: Self.adobeCameraList
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddCamera) {
            AddCameraSheet()
        }
    }

    private var selectedCamera: TargetCamera? {
        cameraStore.allCameras.first { $0.id == selection }
    }

    private func cameraRow(_ camera: TargetCamera) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(camera.displayName)
                Text(camera.isBuiltIn ? camera.note : addedDescription(camera))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if camera.isBuiltIn {
                Text("Built in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 1)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }

    /// Shows exactly what will be written, which is the only thing that
    /// distinguishes one user-added camera from another.
    private func addedDescription(_ camera: TargetCamera) -> String {
        "Added by you · \(camera.make) / \(camera.model) / \(camera.uniqueCameraModel)"
    }
}
