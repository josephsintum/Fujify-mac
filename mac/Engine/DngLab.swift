import Foundation

/// Wraps the `dnglab` command-line tool.
///
/// dnglab ships inside the app bundle, so this is the converter that runs
/// when the user has installed nothing. It takes an explicit destination
/// path, unlike Adobe's, so there is no rename step.
///
/// See docs/PIPELINE-CONTRACT.md §4.2.
struct DngLab {
    let executable: URL

    /// Converts `src` to a DNG at `dst`. With `embedRaw` true the original
    /// file is embedded inside the DNG; false keeps the output ~half the size.
    ///
    /// - Throws: `DngLabError.unsupportedCamera` when dnglab does not know
    ///   the body — a skip, not a failure — and
    ///   `ProcessingFailure` for anything else.
    func convert(src: URL, dst: URL, embedRaw: Bool) async throws {
        var args = ["convert"]
        if !embedRaw {
            args.append(contentsOf: ["--embed-raw", "false"])
        }
        args.append(contentsOf: [src.path, dst.path])

        let result = try await runSubprocess(executable, args)

        // Checked before the exit code, because dnglab exits non-zero for an
        // unsupported camera and that case is a skip rather than an error.
        if let model = Self.unsupportedCameraModel(in: result.stderr) {
            throw DngLabError.unsupportedCamera(model: model)
        }

        guard
            result.didSucceed,
            FileManager.default.fileExists(atPath: dst.path)
        else {
            throw ProcessingFailure.classify(
                stderr: result.stderr.isEmpty
                    ? "dnglab exited \(result.exitCode) without writing a DNG."
                    : result.stderr,
                step: .convert,
                tool: .dnglab
            )
        }
    }

    /// Matches dnglab's unsupported-camera message and pulls out the model.
    ///
    /// The real string, from dnglab 0.8.0 on a Nikon D1H:
    ///
    ///     Error: Unsupported file: Error: Unknown camera, model 'NIKON D1H',
    ///     make: 'NIKON CORPORATION', mode: '12bit'
    ///
    /// Returns nil when the message isn't there.
    static func unsupportedCameraModel(in stderr: String) -> String? {
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

/// The one dnglab outcome that isn't a failure.
enum DngLabError: Error, LocalizedError {
    case unsupportedCamera(model: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCamera(let model):
            return SkipReason.unsupportedCamera(model: model).summary
        }
    }
}
