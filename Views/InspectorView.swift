import SwiftUI

/// Right-side panel showing the full exiftool metadata dump for the
/// currently-selected file. Loads lazily when the selection changes.
///
/// The inspector pattern matches Finder ⌘I / Notes / Photos:
/// - 0 files selected → "Select a file" hint.
/// - 1 file selected → full metadata table, with a search field.
/// - 2+ selected → "Select a single file" hint.
struct InspectorView: View {
    let item: FileItem?
    @Environment(Pipeline.self) private var pipeline
    @State private var metadata: [String: String] = [:]
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var filter = ""

    var body: some View {
        Group {
            if let item {
                metadataView(for: item)
            } else {
                emptyState
            }
        }
        .task(id: item?.id) {
            await loadMetadata()
        }
    }

    // MARK: Subviews

    @ViewBuilder
    private func metadataView(for item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(item.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

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
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
            $0.key.localizedCaseInsensitiveContains(trimmed) ||
                $0.value.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: Loading

    private func loadMetadata() async {
        metadata = [:]
        loadError = nil
        filter = ""

        guard let item else { return }
        guard let exiftoolURL = pipeline.toolLocator.exiftool else {
            loadError = "exiftool not found"
            return
        }

        isLoading = true
        defer { isLoading = false }

        let exif = ExifTool(executable: exiftoolURL)
        do {
            metadata = try await exif.readAllMetadata(item.url)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
