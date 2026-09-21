import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(CameraStore.self) private var cameraStore
    @Environment(ToolLocator.self) private var toolLocator

    @State private var isDropTargeted = false
    @State private var selection: Set<FileItem.ID> = []
    @State private var showInspector = false
    @State private var statusFilter: StatusFilter = .all
    @State private var showAddCamera = false
    @State private var showInPlaceConfirm = false

    /// Which outcomes the table is showing. After a large batch this is the
    /// difference between finding the nine skipped files and scrolling past
    /// two thousand successful ones.
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case done = "Done"
        case skipped = "Skipped"
        case failed = "Failed"

        var id: Self { self }

        func matches(_ status: FileItem.Status) -> Bool {
            switch self {
            case .all: return true
            case .done: return status.isDone
            case .skipped: return status.isSkipped
            case .failed: return status.isFailed
            }
        }
    }

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
        .frame(minWidth: 820, minHeight: 480)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await pipeline.add(urls) }
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            if isDropTargeted { dropOverlay }
        }
        .toolbar { toolbarContent }
        .inspector(isPresented: $showInspector) {
            InspectorView(item: selectedItem)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .navigationTitle("Fujify")
        .sheet(isPresented: $showAddCamera) {
            AddCameraSheet()
        }
        .sheet(isPresented: $showInPlaceConfirm) {
            @Bindable var pipeline = pipeline
            InPlaceConfirmSheet(
                dngCount: pipeline.pendingInPlaceDngCount,
                rawCount: pendingCount - pipeline.pendingInPlaceDngCount,
                suppressFutureAsks: Binding(
                    get: { !pipeline.confirmInPlaceDng },
                    set: { pipeline.confirmInPlaceDng = !$0 }
                ),
                onUpdateInPlace: startProcessing,
                onChooseFolder: {
                    Task {
                        if await chooseOutputFolder() { startProcessing() }
                    }
                }
            )
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await addFiles() }
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Add RAW files or folders")
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 10) {
                outputFolderMenu
                targetCameraMenu
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: handleProcessButton) {
                Label(processButtonTitle, systemImage: processButtonIcon)
            }
            .buttonStyle(.borderedProminent)
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
            Button("Choose Folder…") {
                Task { _ = await chooseOutputFolder() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text("Save to")
                    .foregroundStyle(.secondary)
                Text(outputFolderLabel)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .help("Where processed DNGs are saved")
    }

    /// Picks which camera Lightroom will think took these photos.
    private var targetCameraMenu: some View {
        Menu {
            ForEach(TargetCamera.builtIns) { camera in
                targetButton(camera)
            }
            if !cameraStore.userCameras.isEmpty {
                Divider()
                ForEach(cameraStore.userCameras) { camera in
                    targetButton(camera)
                }
            }
            Divider()
            Button("Add Camera…") { showAddCamera = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "camera")
                Text("Profile as")
                    .foregroundStyle(.secondary)
                Text(cameraStore.selectedTarget.displayName)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .help("Which camera Lightroom will see")
    }

    @ViewBuilder
    private func targetButton(_ camera: TargetCamera) -> some View {
        Button {
            cameraStore.selectedTarget = camera
        } label: {
            // Two lines: the name, and what switching to it buys you.
            if camera.note.isEmpty {
                Text(camera.displayName)
            } else {
                Text(camera.displayName)
                Text(camera.note)
            }
            if camera == cameraStore.selectedTarget {
                Image(systemName: "checkmark")
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var contentArea: some View {
        if pipeline.files.isEmpty {
            emptyState
        } else {
            fileTable
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("Drop RAW files or folders here")
                .font(.title3.weight(.semibold))
            Text(
                "Fujify converts them to DNG and tags each one so Lightroom Classic "
                    + "offers the Fujifilm film simulations. RAW files are never changed. "
                    + "Fujify asks before updating a DNG in place."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)

            Button("Add Files…") {
                Task { await addFiles() }
            }
            .padding(.top, 2)

            readyLine
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Confirms at a glance that the app can actually do its job, which the
    /// old empty state left the user to find out by trying.
    private var readyLine: some View {
        HStack(spacing: 6) {
            if !toolLocator.hasProbed {
                ProgressView().controlSize(.small)
                Text("Checking for converters…")
            } else if toolLocator.hasMinimumTools {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready · \(toolSummary)")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("exiftool is missing — reinstall Fujify")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var fileTable: some View {
        Table(visibleFiles, selection: $selection) {
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
            .width(min: 180, ideal: 300)
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            contextMenu(for: ids)
        }
        .onDeleteCommand {
            pipeline.remove(selection)
            selection.removeAll()
        }
    }

    /// Right-click on a row.
    ///
    /// Process Again and Retry are both always present, with one of them
    /// disabled, so the menu keeps its shape and muscle memory survives
    /// between a finished file and a failed one.
    @ViewBuilder
    private func contextMenu(for ids: Set<FileItem.ID>) -> some View {
        let items = pipeline.files.filter { ids.contains($0.id) }
        let sourceURLs = items.map(\.url)
        let outputURLs = items.compactMap(\.outputURL)
        let count = items.count

        Button(plural("Show in Finder", count)) {
            NSWorkspace.shared.activateFileViewerSelecting(sourceURLs)
        }
        .disabled(sourceURLs.isEmpty)

        Button(plural("Show Output DNG in Finder", outputURLs.count)) {
            NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
        }
        .disabled(outputURLs.isEmpty)

        // Hidden rather than disabled when Lightroom is absent: a permanently
        // greyed item is just clutter.
        if Lightroom.isInstalled {
            Button(plural("Open in Lightroom", count)) {
                // The output once there is one, so the user sees the tagged
                // file rather than the untouched source.
                for item in items { Lightroom.open(item.inspectionURL) }
            }
            .disabled(items.isEmpty)
        }

        Button(plural("Open with Default App", count)) {
            for url in sourceURLs { NSWorkspace.shared.open(url) }
        }
        .disabled(sourceURLs.isEmpty)

        Divider()

        Button("Inspect") {
            selection = ids
            showInspector = true
        }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(ids.count != 1)

        Button(plural("Copy Path", count)) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                items.map(\.inspectionURL.path).joined(separator: "\n"), forType: .string)
        }
        .keyboardShortcut("c", modifiers: [.command, .option])
        .disabled(items.isEmpty)

        Divider()

        Button("Process Again") { pipeline.reprocess(ids) }
            .disabled(items.isEmpty || pipeline.isProcessing)

        Button("Retry") { pipeline.retry(ids) }
            .disabled(!items.contains { $0.status.isRetryable })

        Divider()

        Button(count > 1 ? "Remove \(count) from List" : "Remove from List") {
            pipeline.remove(ids)
            selection.subtract(ids)
        }
        .disabled(ids.isEmpty)
    }

    /// "Show in Finder" for one, "Show 3 in Finder" for several — matching
    /// how macOS menus pluralise.
    private func plural(_ title: String, _ count: Int) -> String {
        guard count > 1 else { return title }
        if let range = title.range(of: " in ") ?? title.range(of: " with ") {
            return title.replacingCharacters(
                in: range.lowerBound..<range.lowerBound, with: " \(count)")
        }
        return "\(title) (\(count))"
    }

    // MARK: Banner

    /// True when files are queued that can't be processed because DNG-only
    /// mode is on. dnglab ships with the app, so this can now only happen
    /// when the user has chosen it deliberately.
    private var showConverterBanner: Bool {
        pipeline.toolLocator.activeConverter == .dngOnly
            && pipeline.files.contains { $0.url.pathExtension.lowercased() != "dng" }
    }

    private var converterBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("RAW files aren't being converted")
                    .font(.callout.weight(.medium))
                Text("DNG-only mode is on. Turn it off in Settings to convert RAW files.")
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

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.06)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(6)
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Drop to add to the queue")
                    .font(.headline)
                Text("RAW and DNG files, or folders")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
        .allowsHitTesting(false)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if pipeline.isProcessing {
                ProgressView(
                    value: Double(pipeline.completedCount),
                    total: Double(max(pipeline.files.count, 1))
                )
                .progressViewStyle(.linear)
                .frame(width: 180)

                Text(statusBarText)
            } else if hasSettledOutcomes {
                Picker("Show", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { filter in
                        Text(filterLabel(filter)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if statusFilter != .all, statusFilter != .done, retryableCount > 0 {
                    Button("Retry All") { pipeline.retryAll() }
                        .controlSize(.small)
                }
            } else {
                Text(statusBarText)
            }

            Spacer()

            if let duration = pipeline.batchDuration, !pipeline.isProcessing {
                Text("Finished in \(formatted(duration))")
            }
            Text(toolSummary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func filterLabel(_ filter: StatusFilter) -> String {
        let counts = pipeline.counts
        let n =
            switch filter {
            case .all: counts.total
            case .done: counts.done
            case .skipped: counts.skipped
            case .failed: counts.failed
            }
        return "\(filter.rawValue) \(n.formatted())"
    }

    // MARK: Derived state

    private var visibleFiles: [FileItem] {
        statusFilter == .all
            ? pipeline.files
            : pipeline.files.filter { statusFilter.matches($0.status) }
    }

    /// The file to show in the Inspector. Single-selection only; if 0 or 2+
    /// are selected the inspector shows a hint instead of partial info.
    private var selectedItem: FileItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return pipeline.files.first { $0.id == id }
    }

    private var pendingCount: Int { pipeline.counts.pending }
    private var retryableCount: Int {
        pipeline.files.filter { $0.status.isRetryable }.count
    }

    /// Whether a batch has actually run, which is when the filter earns its
    /// place in the status bar.
    private var hasSettledOutcomes: Bool {
        let counts = pipeline.counts
        return counts.done + counts.skipped + counts.failed > 0
    }

    private var canProcess: Bool {
        pipeline.isProcessing || (pendingCount > 0 && toolLocator.hasMinimumTools)
    }

    private var processButtonTitle: String {
        if pipeline.isProcessing { return "Stop" }
        switch pendingCount {
        case 0: return "Process"
        case 1: return "Process 1 file"
        case let n: return "Process \(n.formatted()) files"
        }
    }

    private var processButtonIcon: String {
        pipeline.isProcessing ? "stop.fill" : "play.fill"
    }

    private var outputFolderLabel: String {
        guard let folder = pipeline.outputFolder else { return "In place" }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// "Adobe DNG Converter · exiftool 13.59", so the user always knows which
    /// tools produced their files.
    private var toolSummary: String {
        var parts: [String] = []
        switch pipeline.toolLocator.activeConverter {
        case .adobe: parts.append("Adobe DNG Converter")
        case .dnglab:
            parts.append(
                "built-in dnglab \(pipeline.toolLocator.dnglab?.version ?? "")"
                    .trimmingCharacters(in: .whitespaces))
        case .dngOnly: parts.append("DNG-only mode")
        }
        if let exif = pipeline.toolLocator.exiftool {
            parts.append("exiftool \(exif.version)")
        }
        return parts.joined(separator: " · ")
    }

    private var statusBarText: String {
        let counts = pipeline.counts
        if pipeline.isProcessing {
            var text = "\(counts.settled.formatted()) of \(counts.total.formatted()) processed"
            if let remaining = pipeline.estimatedRemaining {
                text += " · about \(formatted(remaining)) left"
            }
            return text
        }
        var parts: [String] = []
        if counts.done > 0 { parts.append("\(counts.done.formatted()) done") }
        if counts.skipped > 0 { parts.append("\(counts.skipped.formatted()) skipped") }
        if counts.failed > 0 { parts.append("\(counts.failed.formatted()) failed") }
        if counts.pending > 0 { parts.append("\(counts.pending.formatted()) pending") }
        return parts.isEmpty
            ? "\(counts.total.formatted()) file\(counts.total == 1 ? "" : "s")"
            : parts.joined(separator: " · ")
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = interval < 60 ? [.second] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(interval, 1)) ?? "a moment"
    }

    // MARK: Actions

    private func handleProcessButton() {
        if pipeline.isProcessing {
            pipeline.cancel()
            return
        }
        // Rewriting a DNG in place is destructive in a way converting a RAW
        // is not, so it is confirmed once per batch (contract §7).
        if pipeline.confirmInPlaceDng, pipeline.pendingInPlaceDngCount > 0 {
            showInPlaceConfirm = true
            return
        }
        startProcessing()
    }

    private func startProcessing() {
        statusFilter = .all
        pipeline.process(target: cameraStore.selectedTarget)
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

    /// Returns true when the user actually picked a folder, so the in-place
    /// sheet's "Choose Folder…" can go straight on to processing.
    @MainActor
    private func chooseOutputFolder() async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder for processed DNGs"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        pipeline.outputFolder = url
        return true
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
