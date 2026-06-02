import Foundation

/// Wraps the `dnglab` command-line tool (Homebrew install).
///
/// dnglab signals unsupported cameras with a parseable stderr line — that
/// case is hoisted to a typed error so the UI can show a helpful "skipped"
/// state instead of dumping the raw stderr. Other failures are passed
/// through as `.conversionFailed`.
struct DngLab {
    let executable: URL

    /// Converts `src` (any supported RAW) to a DNG at `dst`. With
    /// `embedRaw` true the original file is embedded inside the DNG; false
    /// keeps the output ~half the size.
    func convert(src: URL, dst: URL, embedRaw: Bool) async throws {
        var args = ["convert"]
        if !embedRaw {
            args.append(contentsOf: ["--embed-raw", "false"])
        }
        args.append(contentsOf: [src.path, dst.path])

        let result = try await runSubprocess(executable, args)

        if let model = unsupportedCameraModel(in: result.stderr) {
            throw DngLabError.unsupportedCamera(model: model)
        }

        guard
            result.didSucceed,
            FileManager.default.fileExists(atPath: dst.path)
        else {
            throw DngLabError.conversionFailed(stderr: result.stderr)
        }
    }

    /// Matches dnglab's "Unknown camera, model 'XXX', make: '...'" stderr
    /// line and pulls out the model. Returns nil if the message isn't there.
    private func unsupportedCameraModel(in stderr: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: "Unknown camera, model '([^']+)'"),
            let match = regex.firstMatch(
                in: stderr,
                range: NSRange(stderr.startIndex..., in: stderr)
            ),
            let range = Range(match.range(at: 1), in: stderr)
        else { return nil }
        return String(stderr[range])
    }
}

enum DngLabError: Error, LocalizedError {
    case unsupportedCamera(model: String)
    case conversionFailed(stderr: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCamera(let model):
            return "Unsupported camera (\(model)). " + "Try Adobe DNG Converter for newer bodies, "
                + "or pre-convert with Lightroom Classic."
        case .conversionFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "dnglab failed: \(trimmed.isEmpty ? "unknown error" : trimmed)"
        }
    }
}
