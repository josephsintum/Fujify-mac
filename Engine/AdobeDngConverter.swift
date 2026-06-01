import Foundation

/// Wraps Adobe's free DNG Converter CLI.
///
/// The CLI lives inside the Adobe DNG Converter.app bundle and is invoked
/// directly (not via `open -a`). Unlike dnglab, Adobe's tool always writes
/// to a directory and auto-names the output `<srcStem>.dng` — so this
/// wrapper writes to `dst.parent` then renames if the caller asked for a
/// different filename.
struct AdobeDngConverter {
    let executable: URL

    static let defaultPath = URL(fileURLWithPath:
        "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"
    )

    /// Converts `src` to a DNG at `dst`.
    /// Flags used:
    ///   -c   compressed DNG (default, kept explicit for clarity)
    ///   -fl  embed fast-load data (better Lightroom open speed)
    ///   -p2  full-size JPEG preview embedded
    ///   -e   embed original RAW (only when embedRaw is true)
    ///   -d   output directory
    func convert(src: URL, dst: URL, embedRaw: Bool) async throws {
        let outputDir = dst.deletingLastPathComponent()
        var args = ["-c", "-fl", "-p2"]
        if embedRaw {
            args.append("-e")
        }
        args.append(contentsOf: ["-d", outputDir.path, src.path])

        let result = try await runSubprocess(executable, args)
        guard result.didSucceed else {
            throw AdobeDngConverterError.conversionFailed(stderr: result.stderr)
        }

        // Adobe always writes <stem>.dng in the output directory. Rename to
        // the requested dst if it differs (it usually won't — we ask for the
        // expected location — but be defensive).
        let actual = outputDir.appendingPathComponent(
            src.deletingPathExtension().lastPathComponent + ".dng"
        )
        guard FileManager.default.fileExists(atPath: actual.path) else {
            throw AdobeDngConverterError.conversionFailed(
                stderr: "Adobe DNG Converter reported success but no DNG was produced"
            )
        }
        if actual != dst {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: actual, to: dst)
        }
    }
}

enum AdobeDngConverterError: Error, LocalizedError {
    case conversionFailed(stderr: String)

    var errorDescription: String? {
        switch self {
        case .conversionFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Adobe DNG Converter failed: \(trimmed.isEmpty ? "unknown error" : trimmed)"
        }
    }
}
