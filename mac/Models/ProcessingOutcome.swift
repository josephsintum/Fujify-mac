import Foundation

/// Which half of the pipeline was running. Lets the UI say "while converting"
/// rather than just "failed".
enum ProcessingStep: Equatable, Sendable {
    case convert
    case writeTags

    var verb: String {
        switch self {
        case .convert: return "while converting"
        case .writeTags: return "while writing tags"
        }
    }
}

/// The external program involved, so failure text can name it.
enum ToolName: String, Equatable, Sendable {
    case adobeDngConverter = "Adobe DNG Converter"
    case dnglab = "dnglab"
    case exiftool = "exiftool"

    /// dnglab and exiftool ship inside the app, so their output is our
    /// problem; Adobe's is the user's install.
    var isBundled: Bool { self != .adobeDngConverter }

    var displayName: String {
        self == .dnglab ? "Built-in dnglab" : rawValue
    }
}

/// A failure that carries enough structure for the UI to offer the right fix.
///
/// See docs/PIPELINE-CONTRACT.md §8.1. The point of the `cause` enum is that
/// the Inspector maps it to actions — a read-only output folder gets a
/// "Choose Folder…" button, an unknown error does not — instead of the user
/// reading raw stderr and guessing.
struct ProcessingFailure: Error, Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        case readOnlyOutput
        case diskFull
        case toolMissing
        case other
    }

    let step: ProcessingStep
    let tool: ToolName
    let cause: Cause
    /// The tool's raw stderr, shown collapsed under "Output from <tool>" with
    /// a Copy button so a bug report is one click.
    let toolOutput: String

    /// One sentence naming the tool and what went wrong.
    var summary: String {
        switch cause {
        case .readOnlyOutput:
            return "\(tool.displayName) couldn't save the DNG because the output "
                + "folder is read-only."
        case .diskFull:
            return "\(tool.displayName) ran out of space while writing the DNG."
        case .toolMissing:
            return "\(tool.displayName) couldn't be found."
        case .other:
            let trimmed = toolOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? ""
            return firstLine.isEmpty
                ? "\(tool.displayName) failed \(step.verb)."
                : "\(tool.displayName) failed \(step.verb): \(firstLine)"
        }
    }

    /// What the user should do, plus the reassurance that their RAW is intact.
    var recovery: String {
        switch cause {
        case .readOnlyOutput:
            return "Choose another folder or fix its permissions, then retry. "
                + "The RAW file is untouched."
        case .diskFull:
            return "Free some space or choose a folder on another disk, then retry. "
                + "The RAW file is untouched."
        case .toolMissing:
            return "Check the converter setup in Settings, then retry. "
                + "The RAW file is untouched."
        case .other:
            return "Retry, and if it keeps failing copy the output below into a "
                + "bug report. The RAW file is untouched."
        }
    }

    /// Short text for the Status column, which shows one word plus this.
    var shortReason: String {
        switch cause {
        case .readOnlyOutput: return "Output folder is read-only"
        case .diskFull: return "Disk is full"
        case .toolMissing: return "\(tool.displayName) not found"
        case .other: return "\(tool.displayName) error"
        }
    }

    /// Maps a tool's stderr onto a cause.
    ///
    /// This is the single place either platform decides what went wrong, so
    /// the Mac app, the Windows app and the tests cannot drift apart.
    ///
    /// Every pattern below was taken from a tool's actual output, not
    /// guessed — see Tests/FailureClassificationTests.swift, which asserts
    /// against the real strings. The one that matters most is exiftool's:
    /// it reports a permissions problem as
    ///
    ///     Error creating file: <path>_exiftool_tmp - <path>
    ///
    /// with no mention of permissions at all, so matching only on
    /// "permission denied" would file it under "unknown error" and the user
    /// would get no Choose Folder button.
    static func classify(
        stderr: String,
        step: ProcessingStep,
        tool: ToolName
    ) -> ProcessingFailure {
        let haystack = stderr.lowercased()

        let cause: Cause
        if haystack.contains("permission denied")  // dnglab, POSIX tools
            || haystack.contains("error creating file")  // exiftool
            || haystack.contains("read-only file system")
            || haystack.contains("access is denied")  // Windows
            || haystack.contains("operation not permitted")
            || haystack.contains("os error 13")  // Rust io::Error
        {
            cause = .readOnlyOutput
        } else if haystack.contains("no space left")
            || haystack.contains("disk full")
            || haystack.contains("not enough space")
            || haystack.contains("os error 28")  // ENOSPC via Rust
        {
            cause = .diskFull
        } else if haystack.contains("not found at")  // SubprocessError.toolNotFound
            || (haystack.contains("no such file or directory")
                && haystack.contains(tool.rawValue.lowercased()))
        {
            cause = .toolMissing
        } else {
            cause = .other
        }

        return ProcessingFailure(step: step, tool: tool, cause: cause, toolOutput: stderr)
    }
}

/// Why a file was deliberately not processed.
///
/// A skip is not a failure: nothing went wrong, the file just didn't need or
/// couldn't have the work done. See docs/PIPELINE-CONTRACT.md §8.2.
enum SkipReason: Equatable, Sendable {
    /// The file already claims to be the current target (§9).
    case alreadyTagged(as: String)
    /// dnglab does not know this body yet.
    case unsupportedCamera(model: String)
    /// Non-DNG input while DNG-only mode is on.
    case dngOnlyMode

    var summary: String {
        switch self {
        case .alreadyTagged(let name):
            return "This file is already tagged as \(name), so there was nothing to do."
        case .unsupportedCamera(let model):
            return "The built-in dnglab converter doesn't support the \(model) yet, "
                + "so this file wasn't converted."
        case .dngOnlyMode:
            return "DNG-only mode is on, so RAW files aren't converted."
        }
    }

    var recovery: String {
        switch self {
        case .alreadyTagged:
            return "Use Process Again if you want to write the tags anyway."
        case .unsupportedCamera:
            return "Install Adobe DNG Converter for the widest camera support, or "
                + "convert this file to DNG in Lightroom Classic and add the DNG instead."
        case .dngOnlyMode:
            return "Turn DNG-only mode off in Settings, or pre-convert in "
                + "Lightroom Classic and add the DNGs instead."
        }
    }

    var shortReason: String {
        switch self {
        case .alreadyTagged(let name): return "Already tagged as \(name)"
        case .unsupportedCamera(let model): return "Unsupported by dnglab (\(model))"
        case .dngOnlyMode: return "Needs a RAW converter"
        }
    }
}
