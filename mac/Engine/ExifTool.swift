import Foundation

/// Wraps the `exiftool` command-line tool.
///
/// exiftool is a Perl script, so it is invoked as `perl <script> <args>`
/// rather than executed directly — that way the copy bundled inside the app
/// needs no shebang fix-up, no execute bit and no install step. See
/// docs/PIPELINE-CONTRACT.md §3.4.
///
/// `configFile` points at tools/exiftool-fujify.config, which defines the
/// XMP-fujify namespace used to remember a file's original camera identity
/// (§3.2). It is optional: without it the Fuji tags are still written, only
/// the stash is skipped.
struct ExifTool {
    let perl: URL
    let script: URL
    let configFile: URL?

    init(perl: URL, script: URL, configFile: URL? = nil) {
        self.perl = perl
        self.script = script
        self.configFile = configFile
    }

    /// Arguments common to every invocation.
    private var leadingArguments: [String] {
        var args = [script.path]
        if let configFile {
            args.append(contentsOf: ["-config", configFile.path])
        }
        return args
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        try await runSubprocess(perl, leadingArguments + arguments)
    }

    // MARK: Reading

    /// Reads the `Make` and `Model` EXIF tags for the file list's Camera
    /// column. Returns empty strings if a tag is absent — callers decide
    /// whether that's an error or just unknown.
    func readMakeModel(_ url: URL) async throws -> (make: String, model: String) {
        let result = try await run(["-j", "-Make", "-Model", url.path])
        guard result.didSucceed else {
            throw ExifToolError.failed(stderr: result.stderr)
        }
        let record = try parseFirstJSONRecord(result.stdout)
        return (
            make: record.string("Make"),
            model: record.string("Model")
        )
    }

    /// Reads the camera-identity tags the already-tagged skip compares
    /// against (§9) and the Inspector highlights.
    func readCameraTags(_ url: URL) async throws -> CameraTags {
        let result = try await run([
            "-j",
            "-Make", "-Model", "-UniqueCameraModel",
            "-CameraProfilesMake", "-CameraProfilesModel",
            "-CameraProfilesUniqueCameraModel",
            url.path,
        ])
        guard result.didSucceed else {
            throw ExifToolError.failed(stderr: result.stderr)
        }
        let record = try parseFirstJSONRecord(result.stdout)
        return CameraTags(
            make: record.string("Make"),
            model: record.string("Model"),
            uniqueCameraModel: record.string("UniqueCameraModel"),
            profilesMake: record.string("CameraProfilesMake"),
            profilesModel: record.string("CameraProfilesModel"),
            profilesUniqueCameraModel: record.string("CameraProfilesUniqueCameraModel")
        )
    }

    /// True when this file already carries a Fujify stash, meaning it has
    /// been processed before and its original identity is already recorded.
    private func hasStash(_ url: URL) async -> Bool {
        guard configFile != nil else { return false }
        guard let result = try? await run(["-j", "-XMP-fujify:OriginalMake", url.path]),
            result.didSucceed,
            let record = try? parseFirstJSONRecord(result.stdout)
        else { return false }
        return !record.string("OriginalMake").isEmpty
    }

    /// Dumps every readable tag for the Inspector panel. Values are
    /// stringified so the UI can render them uniformly.
    func readAllMetadata(_ url: URL) async throws -> [String: String] {
        let result = try await run(["-j", url.path])
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

    /// exiftool's own version, shown in Settings and the status bar.
    func version() async throws -> String {
        let result = try await run(["-ver"])
        guard result.didSucceed else {
            throw ExifToolError.failed(stderr: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Writing

    /// Rewrites the DNG's camera-identity tags so Lightroom exposes
    /// `target`'s film simulation profiles, and records what the file used to
    /// be so the change can be undone later.
    ///
    /// Both sets of tags go in one invocation, so the file is rewritten once.
    ///
    /// The `-m` flag is non-negotiable: some DNGs trigger a "minor" warning
    /// (typically "Error copying hidden data") that would otherwise cause
    /// exiftool to refuse the write entirely. Discovered during CLI testing
    /// on real Sony files; see docs/PIPELINE-CONTRACT.md §3.1.
    func inject(target: TargetCamera, into dng: URL) async throws {
        var arguments = target.injectedTags.map { "-\($0.name)=\($0.value)" }

        arguments.append(contentsOf: await stashArguments(for: target, in: dng))

        arguments.append(contentsOf: ["-overwrite_original", "-m", dng.path])

        let result = try await run(arguments)
        guard result.didSucceed else {
            throw ExifToolError.failed(stderr: result.stderr)
        }
    }

    /// The XMP-fujify arguments that remember the file's original identity.
    ///
    /// Returns nothing when there is no config file to define the namespace,
    /// or when the file already carries a stash — in that case the "original"
    /// values on disk are the ones Fujify wrote last time, and overwriting
    /// the stash with them would lose the real camera forever.
    private func stashArguments(
        for target: TargetCamera,
        in dng: URL
    ) async -> [String] {
        guard configFile != nil else { return [] }

        // Always record which target was written, even on a re-tag.
        var arguments = [
            "-XMP-fujify:TargetModel=\(target.model)",
            "-XMP-fujify:Version=\(Self.stashVersion)",
        ]

        if await hasStash(dng) {
            return arguments
        }

        guard let original = try? await readCameraTags(dng) else {
            return arguments
        }

        arguments.append(contentsOf: [
            "-XMP-fujify:OriginalMake=\(original.make)",
            "-XMP-fujify:OriginalModel=\(original.model)",
            "-XMP-fujify:OriginalUniqueCameraModel=\(original.uniqueCameraModel)",
        ])
        return arguments
    }

    /// Bumped if the stash tags ever change shape, so a future revert action
    /// knows how to read what it finds.
    static let stashVersion = 1
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

extension [String: Any] {
    /// exiftool returns a number for a tag whose value happens to look
    /// numeric, so every string read has to cope with both.
    fileprivate func string(_ key: String) -> String {
        switch self[key] {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return ""
        }
    }
}
