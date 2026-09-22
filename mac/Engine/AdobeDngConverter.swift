import Foundation

/// Wraps Adobe's free DNG Converter CLI.
///
/// The CLI lives inside the Adobe DNG Converter.app bundle and is invoked
/// directly, not via `open -a`. Adobe's licence forbids redistribution, so
/// this one is always user-installed — and always preferred when present,
/// because its camera coverage is the widest available.
///
/// Unlike dnglab, Adobe always writes `<srcStem>.dng` into a directory and
/// offers no way to name the output, so this wrapper writes to `dst`'s parent
/// and renames afterwards.
///
/// See docs/PIPELINE-CONTRACT.md §4.1.
struct AdobeDngConverter {
    let executable: URL

    /// Converts `src` to a DNG at `dst`.
    ///
    /// Flags used:
    ///   -c   compressed DNG (the default, kept explicit for clarity)
    ///   -fl  embed fast-load data (better Lightroom open speed)
    ///   -p2  full-size JPEG preview embedded
    ///   -e   embed original RAW (only when embedRaw is true)
    ///   -d   output directory
    ///
    /// - Throws: `ProcessingFailure` describing what went wrong.
    func convert(src: URL, dst: URL, embedRaw: Bool) async throws {
        let outputDir = dst.deletingLastPathComponent()
        var args = ["-c", "-fl", "-p2"]
        if embedRaw {
            args.append("-e")
        }
        args.append(contentsOf: ["-d", outputDir.path, src.path])

        let result = try await runSubprocess(executable, args)
        guard result.didSucceed else {
            throw ProcessingFailure.classify(
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr,
                step: .convert,
                tool: .adobeDngConverter
            )
        }

        // A zero exit does not guarantee output: Adobe reports success for
        // files it then declines to write. Contract §4.1.
        let actual = outputDir.appendingPathComponent(
            src.deletingPathExtension().lastPathComponent + ".dng"
        )
        guard FileManager.default.fileExists(atPath: actual.path) else {
            throw ProcessingFailure(
                step: .convert,
                tool: .adobeDngConverter,
                cause: .other,
                toolOutput: "Adobe DNG Converter reported success but no DNG was produced.\n"
                    + result.stderr
            )
        }

        guard actual != dst else { return }

        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                // Atomic on APFS — only replaces dst once `actual` is in
                // place, so a failure here can't lose the previous file.
                _ = try FileManager.default.replaceItemAt(dst, withItemAt: actual)
            } else {
                try FileManager.default.moveItem(at: actual, to: dst)
            }
        } catch {
            throw ProcessingFailure.classify(
                stderr: "Could not move the converted DNG into place: "
                    + error.localizedDescription,
                step: .convert,
                tool: .adobeDngConverter
            )
        }
    }
}
