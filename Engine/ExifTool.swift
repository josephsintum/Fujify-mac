import Foundation

/// Wraps the `exiftool` command-line tool.
///
/// The tool's location is injectable so ToolLocator can pass in whatever
/// path it resolved (Homebrew at `/opt/homebrew/bin/exiftool`, MacPorts,
/// or a custom install). Defaults to the Apple Silicon Homebrew path so
/// callers can skip the URL when they don't care.
struct ExifTool {
    let executable: URL

    static let defaultPath = URL(fileURLWithPath: "/opt/homebrew/bin/exiftool")

    init(executable: URL = ExifTool.defaultPath) {
        self.executable = executable
    }

    /// Reads the `Make` and `Model` EXIF tags. Returns empty strings if a tag
    /// is absent — callers decide whether that's an error or just unknown.
    func readMakeModel(_ url: URL) async throws -> (make: String, model: String) {
        let result = try await runSubprocess(
            executable,
            ["-j", "-Make", "-Model", url.path]
        )
        guard result.didSucceed else {
            throw ExifToolError.failed(stderr: result.stderr)
        }
        let record = try parseFirstJSONRecord(result.stdout)
        return (
            make: (record["Make"] as? String) ?? "",
            model: (record["Model"] as? String) ?? ""
        )
    }

    /// Rewrites DNG camera-profile tags so Adobe Lightroom exposes the Fuji
    /// film simulation profiles for this file. Overwrites in place (no
    /// `.dng_original` backup left behind).
    ///
    /// The `-m` flag is non-negotiable: some DNGs trigger a "minor" warning
    /// (typically "Error copying hidden data") that would otherwise cause
    /// exiftool to refuse the write entirely. Discovered during CLI testing.
    func injectFujiMetadata(dng: URL) async throws {
        let result = try await runSubprocess(
            executable,
            [
                "-CameraProfilesMake=FUJIFILM",
                "-CameraProfilesModel=X-T5",
                "-CameraProfilesUniqueCameraModel=Fujifilm X-T5",
                "-CameraProfilesCameraRawProfile=True",
                "-UniqueCameraModel=Fujifilm X-T5",
                "-overwrite_original",
                "-m",
                dng.path,
            ])
        guard result.didSucceed else {
            throw ExifToolError.failed(stderr: result.stderr)
        }
    }

    /// Dumps every readable tag for the Inspector panel. Values are
    /// stringified so the UI can render them uniformly.
    func readAllMetadata(_ url: URL) async throws -> [String: String] {
        let result = try await runSubprocess(executable, ["-j", url.path])
        guard result.didSucceed else {
            throw ExifToolError.failed(stderr: result.stderr)
        }
        let record = try parseFirstJSONRecord(result.stdout)
        return record.compactMapValues { value in
            switch value {
            case let str as String: return str
            case let num as NSNumber: return num.stringValue
            case let bool as Bool: return bool ? "true" : "false"
            default: return String(describing: value)
            }
        }
    }
}

enum ExifToolError: Error, LocalizedError {
    case failed(stderr: String)
    case unparseableOutput(String)

    var errorDescription: String? {
        switch self {
        case .failed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "exiftool failed: \(trimmed.isEmpty ? "unknown error" : trimmed)"
        case .unparseableOutput(let detail):
            return "exiftool output could not be parsed: \(detail)"
        }
    }
}

private func parseFirstJSONRecord(_ output: String) throws -> [String: Any] {
    guard let data = output.data(using: .utf8) else {
        throw ExifToolError.unparseableOutput("non-UTF8 output")
    }
    let parsed = try JSONSerialization.jsonObject(with: data)
    guard
        let array = parsed as? [[String: Any]],
        let first = array.first
    else {
        throw ExifToolError.unparseableOutput("expected JSON array of objects")
    }
    return first
}
