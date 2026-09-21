import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(CameraStore.self) private var cameraStore
    @State private var isDropTargeted = false
    @State private var selection: Set<FileItem.ID> = []
    @State private var showInspector = false

    var body: some View {
        VStack(spacing: 0) {
            if showConverterBanner {
                converterBanner
                Divider()
            }

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
        } isTargeted: {
            isDropTargeted = $0
        }
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("Show file metadata")
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(item: selectedItem)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
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
        Table(pipeline.files, selection: $selection) {
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
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            let urls = pipeline.files
                .filter { ids.contains($0.id) }
                .map(\.url)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            .disabled(urls.isEmpty)
            Button("Open with Default App") {
                for url in urls {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(urls.isEmpty)
            Divider()
            Button("Remove from List") {
                pipeline.remove(ids)
                selection.subtract(ids)
            }
            .disabled(ids.isEmpty)
        }
        .onDeleteCommand {
            pipeline.remove(selection)
            selection.removeAll()
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

    /// True when files are queued that can't be processed because no RAW
    /// converter is installed. Structural check — no status-string matching.
    private var showConverterBanner: Bool {
        pipeline.toolLocator.activeConverter == .dngOnly
            && pipeline.files.contains { $0.url.pathExtension.lowercased() != "dng" }
    }

    private var converterBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("No RAW converter installed")
                    .font(.callout.weight(.medium))
                Text("RAW files can't be converted to DNG until you set one up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Text("Open Settings…")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
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

    /// The file to show in the Inspector. Single-selection only; if 0 or 2+
    /// are selected the inspector shows a hint instead of partial info.
    private var selectedItem: FileItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return pipeline.files.first { $0.id == id }
    }

    private var pendingCount: Int {
        pipeline.files.filter { $0.status.isPending }.count
    }

    private var doneCount: Int {
        pipeline.files.filter { $0.status.isDone }.count
    }

    private var skippedCount: Int {
        pipeline.files.filter { $0.status.isSkipped }.count
    }

    private var errorCount: Int {
        pipeline.files.filter { $0.status.isFailed }.count
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
        return parts.isEmpty
            ? "\(total) file\(total == 1 ? "" : "s")" : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func handleProcessButton() {
        if pipeline.isProcessing {
            pipeline.cancel()
        } else {
            pipeline.process(target: cameraStore.selectedTarget)
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

/// The Status column: one word, then the reason in secondary colour.
///
/// The full explanation lives in the Inspector, so this stays readable even
/// when the reason is a long sentence. See docs/PIPELINE-CONTRACT.md §11.
struct StatusBadge: View {
    let status: FileItem.Status

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            Text(status.label)
                .font(.callout)
                .foregroundStyle(status.isPending ? .secondary : .primary)
            if let reason = status.shortReason {
                Text("· \(reason)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(helpText)
    }

    private var icon: String {
        switch status {
        case .pending: return "circle"
        case .processing: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .skipped: return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch status {
        case .pending: return .secondary
        case .processing: return .accentColor
        case .done: return .green
        case .failed: return .orange
        case .skipped: return .yellow
        }
    }

    /// The tooltip carries the full sentence the column had to truncate.
    private var helpText: String {
        switch status {
        case .failed(let failure): return failure.summary
        case .skipped(let reason): return reason.summary
        default: return status.label
        }
    }
}

#Preview {
    ContentView()
}
