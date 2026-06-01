import SwiftUI
import AppKit

struct ContentView: View {
    @State private var pipeline = Pipeline(toolLocator: ToolLocator())
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !pipeline.files.isEmpty {
                Divider()
                statusBar
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
            ToolbarItem(placement: .principal) {
                outputFolderMenu
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

    @ViewBuilder
    private var contentArea: some View {
        if pipeline.files.isEmpty {
            emptyState
        } else {
            fileTable
        }
    }

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
            TableColumn("") { (item: FileItem) in
                ThumbnailCell(image: item.thumbnail)
            }
            .width(min: 56, ideal: 56, max: 56)
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

    private var outputFolderMenu: some View {
        Menu {
            Button {
                pipeline.outputFolder = nil
            } label: {
                if pipeline.outputFolder == nil {
                    Label("In place", systemImage: "checkmark")
                } else {
                    Text("In place")
                }
            }
            if let folder = pipeline.outputFolder {
                Divider()
                Text(folder.path)
                    .font(.caption)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            Divider()
            Button("Choose folder…") {
                Task { await chooseOutputFolder() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(outputFolderLabel)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if pipeline.isProcessing {
                ProgressView(
                    value: Double(pipeline.completedCount),
                    total: Double(max(pipeline.files.count, 1))
                )
                .progressViewStyle(.linear)
                .frame(width: 200)
            }
            Text(statusBarText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Derived state

    private var pendingCount: Int {
        pipeline.files.filter { $0.status == .pending }.count
    }

    private var doneCount: Int {
        pipeline.files.filter { if case .done = $0.status { true } else { false } }.count
    }

    private var skippedCount: Int {
        pipeline.files.filter { if case .skipped = $0.status { true } else { false } }.count
    }

    private var errorCount: Int {
        pipeline.files.filter { if case .error = $0.status { true } else { false } }.count
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

    private var outputFolderLabel: String {
        guard let folder = pipeline.outputFolder else { return "In place" }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    private var statusBarText: String {
        let total = pipeline.files.count
        if pipeline.isProcessing {
            return "\(pipeline.completedCount) of \(total) processed"
        }
        var parts: [String] = []
        if doneCount > 0 { parts.append("\(doneCount) done") }
        if skippedCount > 0 { parts.append("\(skippedCount) skipped") }
        if errorCount > 0 { parts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")") }
        if pendingCount > 0 { parts.append("\(pendingCount) pending") }
        return parts.isEmpty ? "\(total) file\(total == 1 ? "" : "s")" : parts.joined(separator: " · ")
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

    @MainActor
    private func chooseOutputFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder for processed DNGs"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            pipeline.outputFolder = url
        }
    }

    // MARK: Helpers

    private func cameraDisplay(_ item: FileItem) -> String {
        let make = item.make == "NIKON CORPORATION" ? "NIKON" : item.make
        return [make, item.model]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct ThumbnailCell: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 14))
                    }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4))
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
