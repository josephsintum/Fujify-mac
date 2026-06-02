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
/// Cancellable: if the surrounding Task is cancelled (e.g., the user hits
/// the Stop button) we SIGTERM the child, which causes its pipes to close,
/// our pipe drainers to return, the termination handler to fire, and the
/// outer await to unwind with a `CancellationError`. The caller's
/// `catch is CancellationError` handler is then expected to revert state.
///
/// Pipe draining runs on detached Tasks so a chatty child can't block on a
/// full pipe buffer, and `process.waitUntilExit()` is replaced by
/// `Process.terminationHandler` + a continuation so we never synchronously
/// block the actor we're called from.
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

    return try await withTaskCancellationHandler {
        async let stdoutData = Task.detached(priority: .utility) {
            (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value
        async let stderrData = Task.detached(priority: .utility) {
            (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value

        let exitCode: Int32
        do {
            exitCode = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { proc in
                    cont.resume(returning: proc.terminationStatus)
                }
                do {
                    try Task.checkCancellation()
                    try process.run()
                } catch {
                    // Couldn't launch (or task was cancelled before we
                    // could). Close our copy of the pipe write ends so the
                    // drainers see EOF and the outer awaits unwind.
                    process.terminationHandler = nil
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    if error is CancellationError {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(
                            throwing: SubprocessError.launchFailed(error.localizedDescription)
                        )
                    }
                }
            }
        } catch {
            // Make sure the detached drainers finish before bubbling up,
            // otherwise their file descriptors leak briefly.
            _ = await (stdoutData, stderrData)
            throw error
        }

        let (out, err) = await (stdoutData, stderrData)
        try Task.checkCancellation()

        return ProcessResult(
            exitCode: exitCode,
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? ""
        )
    } onCancel: {
        // Synchronous; must not block. SIGTERM the child. It dies, closes
        // its pipes, drainers return, terminationHandler fires, the await
        // above unwinds. Task.checkCancellation() then throws.
        process.terminate()
    }
}
