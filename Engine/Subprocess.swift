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
/// Both pipes are drained on background tasks so the child can never block
/// waiting for buffer space (the classic "small subprocess hangs forever
/// because we forgot to read its output" trap).
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
}
