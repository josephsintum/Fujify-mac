import SwiftUI
import AppKit

struct ContentView: View {
    @State private var pipeline = Pipeline(toolLocator: ToolLocator())
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if pipeline.files.isEmpty {
                emptyState
            } else {
                fileTable
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await pipeline.add(urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await addFiles() }
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: handleProcessButton) {
                    Label(processButtonTitle, systemImage: processButtonIcon)
                }
                .disabled(!canProcess)
            }
        }
        .navigationTitle("Fujify")
    }

    // MARK: Subviews

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Drop RAW files or folders here")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTable: some View {
        Table(pipeline.files) {
            TableColumn("Filename") { (item: FileItem) in
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TableColumn("Camera") { (item: FileItem) in
                Text(cameraDisplay(item))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("Status") { (item: FileItem) in
                StatusBadge(status: item.status)
            }
        }
    }

    // MARK: Derived state

    private var pendingCount: Int {
        pipeline.files.filter { $0.status == .pending }.count
    }

    private var canProcess: Bool {
        pipeline.isProcessing || pendingCount > 0
    }

    private var processButtonTitle: String {
        if pipeline.isProcessing { return "Stop" }
        switch pendingCount {
        case 0: return "Process"
        case 1: return "Process 1 file"
        case let n: return "Process \(n) files"
        }
    }

    private var processButtonIcon: String {
        pipeline.isProcessing ? "stop.fill" : "play.fill"
    }

    // MARK: Actions

    private func handleProcessButton() {
        if pipeline.isProcessing {
            pipeline.cancel()
        } else {
            pipeline.process()
        }
    }

    @MainActor
    private func addFiles() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose RAW files or folders"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        await pipeline.add(panel.urls)
    }

    // MARK: Helpers

    private func cameraDisplay(_ item: FileItem) -> String {
        let make = item.make == "NIKON CORPORATION" ? "NIKON" : item.make
        return [make, item.model]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct StatusBadge: View {
    let status: FileItem.Status

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(label)
    }

    private var icon: String {
        switch status {
        case .pending: return "circle"
        case .processing: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .skipped: return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch status {
        case .pending: return .secondary
        case .processing: return .accentColor
        case .done: return .green
        case .error: return .orange
        case .skipped: return .yellow
        }
    }

    private var label: String {
        switch status {
        case .pending: return "Pending"
        case .processing: return "Processing…"
        case .done: return "Done"
        case .error(let msg): return msg.isEmpty ? "Error" : msg
        case .skipped(let reason): return reason
        }
    }
}

#Preview {
    ContentView()
}
