import Foundation

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var didSucceed: Bool { exitCode == 0 }
}

enum SubprocessError: Error, LocalizedError {
    case toolNotFound(URL)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let url):
            return "Tool not found at \(url.path)"
        case .launchFailed(let message):
            return "Failed to launch subprocess: \(message)"
        }
    }
}

/// Runs a subprocess to completion, capturing stdout and stderr.
///
/// - Both pipes are drained on background tasks so the child can never block
///   waiting for buffer space.
/// - The parent's write-ends of the pipes are closed immediately after
///   spawn — so if the child fails to exec or exits without writing, the
///   reads still see EOF and we don't deadlock.
/// - Honors `Task` cancellation by sending SIGTERM to the child. The pipe
///   readers then hit EOF and the await unblocks naturally.
func runSubprocess(_ tool: URL, _ arguments: [String]) async throws -> ProcessResult {
    guard FileManager.default.fileExists(atPath: tool.path) else {
        throw SubprocessError.toolNotFound(tool)
    }

    let process = Process()
    process.executableURL = tool
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        throw SubprocessError.launchFailed(error.localizedDescription)
    }

    // The parent doesn't write to these pipes. Closing the write ends here
    // means the reader sees EOF when the child exits — even if the child
    // exec'd then crashed without writing anything.
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()

    return await withTaskCancellationHandler {
        async let stdoutData = Task.detached(priority: .utility) {
            (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value
        async let stderrData = Task.detached(priority: .utility) {
            (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value

        let (out, err) = await (stdoutData, stderrData)
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? ""
        )
    } onCancel: {
        process.terminate()
    }
}
