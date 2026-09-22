import AppKit
import SwiftUI

/// Right-side panel for the selected file: what happened to it, and its full
/// exiftool dump.
///
/// The Result card at the top is the part that matters. The Status column can
/// only show a few words, so this is where a failure explains itself, names
/// the tool, offers the fix, and lets the user copy the raw output for a bug
/// report. See docs/PIPELINE-CONTRACT.md §8.
///
/// Selection behaviour matches Finder ⌘I:
/// - 0 selected → "Select a file" hint.
/// - 1 selected → result card + metadata.
/// - 2+ selected → "Select a single file" hint.
struct InspectorView: View {
    let item: FileItem?

    @Environment(Pipeline.self) private var pipeline
    @Environment(CameraStore.self) private var cameraStore

    @State private var metadata: [String: String] = [:]
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var filter = ""

    var body: some View {
        Group {
            if let item {
                content(for: item)
            } else {
                emptyState
            }
        }
        // One task, keyed on the two things that change the answer: which
        // file is selected, and whether it has settled (the output DNG only
        // exists once processing finishes).
        //
        // These were two separate .task modifiers, which meant every
        // selection spawned two concurrent exiftool dumps of the same file,
        // and each step of a running batch spawned another against a DNG the
        // converter was still writing. Keying on `isSettled` rather than the
        // whole status also stops the intermediate .processing steps from
        // re-firing it and wiping the tag filter mid-type.
        .task(id: InspectionKey(item)) {
            await loadMetadata()
        }
    }

    /// What the Inspector's contents actually depend on.
    private struct InspectionKey: Equatable {
        let id: FileItem.ID?
        let isSettled: Bool

        @MainActor
        init(_ item: FileItem?) {
            id = item?.id
            isSettled = item?.status.isSettled ?? false
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(for item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(for: item)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ResultCard(
                        item: item,
                        target: cameraStore.selectedTarget,
                        onRetry: { pipeline.retry([item.id]) },
                        onReprocess: { pipeline.reprocess([item.id]) },
                        onChooseFolder: { chooseOutputFolder() }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)

            filterField

            Divider()

            if isLoading {
                loadingPlaceholder
            } else if let loadError {
                errorPlaceholder(loadError)
            } else {
                metadataList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(for item: FileItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ThumbnailCell(image: item.thumbnail)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                let camera = cameraLine(item)
                if !camera.isEmpty {
                    Text(camera)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(item.url.deletingLastPathComponent().displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func cameraLine(_ item: FileItem) -> String {
        let make = item.make == "NIKON CORPORATION" ? "NIKON" : item.make
        var parts = [make, item.model].filter { !$0.isEmpty }
        if let size = metadata["ImageSize"] {
            parts.append(size.replacingOccurrences(of: "x", with: " × "))
        }
        return parts.joined(separator: " · ")
    }

    private var filterField: some View {
        TextField("Filter tags", text: $filter)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private var metadataList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredPairs, id: \.key) { pair in
                    metadataRow(key: pair.key, value: pair.value)
                    Divider()
                }
            }
        }
    }

    private func metadataRow(key: String, value: String) -> some View {
        let isInjected = Self.injectedTagNames.contains(key)
        return VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .foregroundStyle(isInjected ? Color.accentColor : .primary)
                .fontWeight(isInjected ? .medium : .regular)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tags Fujify writes, highlighted so the user can see the trick
    /// worked without knowing which tags to look for.
    private static let injectedTagNames = TargetCamera.injectedTagNames

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select a file to inspect")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Reading metadata…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorPlaceholder(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Derived

    private var filteredPairs: [(key: String, value: String)] {
        let pairs = metadata.map { (key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pairs }
        return pairs.filter {
            $0.key.localizedCaseInsensitiveContains(trimmed)
                || $0.value.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: Loading

    private func loadMetadata() async {
        metadata = [:]
        loadError = nil
        filter = ""

        guard let item else { return }
        guard let exif = pipeline.toolLocator.makeExifTool() else {
            loadError = "exiftool not found"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            // Reads the output DNG once there is one, so the Inspector shows
            // the tags Fujify actually wrote rather than the source's.
            metadata = try await exif.readAllMetadata(item.inspectionURL)
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func chooseOutputFolder() {
        guard let url = FolderPicker.choose(message: FolderPicker.outputFolderMessage)
        else { return }
        pipeline.outputFolder = url
        if let item { pipeline.retry([item.id]) }
    }
}

// MARK: - Result card

/// What happened to this file, in the same shape whatever the outcome:
/// icon and one word, then what happened, then what to do, then the facts,
/// then the actions.
private struct ResultCard: View {
    let item: FileItem
    let target: TargetCamera
    let onRetry: () -> Void
    let onReprocess: () -> Void
    let onChooseFolder: () -> Void

    @State private var showRawOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headline

            if let explanation {
                Text(explanation)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let recovery {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            facts

            actions

            if let output = rawOutput, !output.isEmpty {
                rawOutputDisclosure(output)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private var headline: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            Text(item.status.label)
                .font(.callout.weight(.semibold))
            if let qualifier {
                Text("· \(qualifier)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            GridRow {
                Text("Output").foregroundStyle(.secondary)
                Text(outputDescription)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let converter = item.converterUsed {
                GridRow {
                    Text("Converter").foregroundStyle(.secondary)
                    Text(converter.displayName)
                }
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch item.status {
            case .done:
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.inspectionURL])
                }
                if Lightroom.isInstalled {
                    Button("Open in Lightroom") {
                        Lightroom.open(item.inspectionURL)
                    }
                }

            case .failed(let failure):
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                if failure.cause == .readOnlyOutput || failure.cause == .diskFull {
                    Button("Choose Folder…", action: onChooseFolder)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }

            case .skipped(let reason):
                switch reason {
                case .unsupportedCamera:
                    SettingsButton(title: "Set Up Converter…", tab: .converter)
                        .buttonStyle(.borderedProminent)
                    Button("Retry", action: onRetry)
                case .dngOnlyMode:
                    SettingsButton(title: "Open Settings…", tab: .converter)
                        .buttonStyle(.borderedProminent)
                    Button("Retry", action: onRetry)
                case .alreadyTagged:
                    // Nothing is wrong, so there is nothing to fix. Process
                    // Again is offered for the user who meant it anyway.
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    Button("Process Again", action: onReprocess)
                }

            case .pending, .processing:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    private func rawOutputDisclosure(_ output: String) -> some View {
        DisclosureGroup(isExpanded: $showRawOutput) {
            VStack(alignment: .leading, spacing: 6) {
                Text(output)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        } label: {
            Text("Output from \(toolName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Content per status

    private var icon: String {
        switch item.status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .skipped: return "exclamationmark.circle"
        case .processing: return "arrow.triangle.2.circlepath"
        case .pending: return "circle"
        }
    }

    private var iconColor: Color {
        switch item.status {
        case .done: return .green
        case .failed: return .orange
        case .skipped: return .yellow
        case .processing: return .accentColor
        case .pending: return .secondary
        }
    }

    /// The short phrase after the one word: "while converting", or what the
    /// file gained.
    private var qualifier: String? {
        switch item.status {
        case .done: return "\(target.displayName) simulations unlocked"
        case .failed(let failure): return failure.step.verb
        case .skipped(.unsupportedCamera): return "unsupported camera"
        case .skipped(.alreadyTagged): return "nothing to do"
        case .skipped(.dngOnlyMode): return "needs a converter"
        case .pending, .processing: return nil
        }
    }

    private var explanation: String? {
        switch item.status {
        case .failed(let failure): return failure.summary
        case .skipped(let reason): return reason.summary
        case .done, .pending, .processing: return nil
        }
    }

    private var recovery: String? {
        switch item.status {
        case .failed(let failure): return failure.recovery
        case .skipped(let reason): return reason.recovery
        case .done, .pending, .processing: return nil
        }
    }

    private var outputDescription: String {
        if let output = item.outputURL {
            return output.displayPath
        }
        if case .failed = item.status { return "Not created" }
        if case .skipped = item.status { return "Not created" }
        return "—"
    }

    private var rawOutput: String? {
        if case .failed(let failure) = item.status { return failure.toolOutput }
        return nil
    }

    private var toolName: String {
        if case .failed(let failure) = item.status { return failure.tool.displayName }
        return "the converter"
    }
}
