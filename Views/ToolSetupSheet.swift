import AppKit
import SwiftUI

/// First-launch picker for the RAW converter backend. Three options:
/// install Adobe DNG Converter, install dnglab via Homebrew, or use
/// DNG-only mode (pre-convert with Lightroom Classic).
///
/// Auto-presented on launch when no converter is installed AND the user
/// hasn't dismissed it before. Reachable later from the Settings sheet's
/// "Re-check converters…" action (step 10).
struct ToolSetupSheet: View {
    @Bindable var toolLocator: ToolLocator
    @AppStorage("hasSeenToolSetup") private var hasSeenToolSetup: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            VStack(spacing: 10) {
                adobeOption
                dnglabOption
                dngOnlyOption
            }
            footer
        }
        .padding(24)
        .frame(width: 560)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up a RAW Converter")
                .font(.title2.weight(.semibold))
            Text(
                "Fujify needs a tool to convert RAW files to DNG before " +
                "applying Fuji film simulation profiles. Pick whichever " +
                "works for you."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Options

    private var adobeOption: some View {
        OptionCard(
            title: "Adobe DNG Converter",
            badge: "Recommended",
            subtitle: "Best camera support, including newer bodies like the Sony A7 V. Free ~700 MB download from Adobe.",
            installed: toolLocator.adobeDngConverter != nil
        ) {
            if let url = toolLocator.adobeDngConverter {
                InstalledPath(url: url)
            } else {
                Button("Download from Adobe") {
                    if let downloadURL = URL(string:
                        "https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html"
                    ) {
                        openURL(downloadURL)
                    }
                }
            }
        }
    }

    private var dnglabOption: some View {
        OptionCard(
            title: "dnglab",
            badge: "Lightweight",
            subtitle: "Open-source, ~12 MB. Doesn't yet support every newer body — Sony A7 V isn't covered.",
            installed: toolLocator.dnglab != nil
        ) {
            if let url = toolLocator.dnglab {
                InstalledPath(url: url)
            } else {
                Button("Get dnglab") {
                    if let repoURL = URL(string: "https://github.com/dnglab/dnglab") {
                        openURL(repoURL)
                    }
                }
            }
        }
    }

    private var dngOnlyOption: some View {
        OptionCard(
            title: "Pre-convert with Lightroom Classic",
            badge: nil,
            subtitle: "Use LRc's Library → Convert Photo to DNG, then drop the DNGs into Fujify. No extra install needed.",
            installed: nil
        ) {
            EmptyView()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Re-check") {
                toolLocator.probe()
            }
            Spacer()
            Button("Continue") {
                hasSeenToolSetup = true
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Subviews

private struct OptionCard<ActionView: View>: View {
    let title: String
    let badge: String?
    let subtitle: String
    /// nil = no install state (e.g., DNG-only mode); true/false = installed or not.
    let installed: Bool?
    @ViewBuilder let action: () -> ActionView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.medium))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(.tint.opacity(0.18), in: .capsule)
                        .foregroundStyle(.tint)
                }
                Spacer()
                if installed == true {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Installed")
                }
            }
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}

private struct InstalledPath: View {
    let url: URL

    var body: some View {
        Text(url.path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

