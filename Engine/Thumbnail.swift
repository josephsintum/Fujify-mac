import AppKit
import QuickLookThumbnailing

/// Generates thumbnails via QuickLook — built into macOS, already knows how
/// to render previews for every RAW format macOS supports. No libraw or
/// dcraw dependency required (the Windows app bundled simple_dcraw.exe;
/// we get this for free).
enum Thumbnail {
    static let defaultSize = CGSize(width: 48, height: 48)

    static func generate(
        for url: URL,
        size: CGSize = defaultSize
    ) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }
}
