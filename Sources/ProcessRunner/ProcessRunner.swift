import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case nonZeroExit(code: Int32, stdout: String, stderr: String)

    public var description: String {
        switch self {
        case let .nonZeroExit(code, stdout, stderr):
            return "Process failed (\(code))\nstdout: \(stdout)\nstderr: \(stderr)"
        }
    }
}

public final class ProcessRunner: Sendable {
    public typealias OutputHandler = @Sendable (String, Bool) -> Void

    public init() {}

    public func run(
        _ launchPath: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        streamOutput: OutputHandler? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            stdoutBuffer.append(data)
            streamOutput?(chunk, false)
        }

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            stderrBuffer.append(data)
            streamOutput?(chunk, true)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let resumeGate = ContinuationResumeGate()

                process.terminationHandler = { proc in
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    if let extra = try? stdoutHandle.readToEnd(), !extra.isEmpty {
                        stdoutBuffer.append(extra)
                    }
                    if let extra = try? stderrHandle.readToEnd(), !extra.isEmpty {
                        stderrBuffer.append(extra)
                    }

                    let stdout = String(data: stdoutBuffer.data, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
                    let result = ProcessResult(exitCode: proc.terminationStatus, stdout: stdout, stderr: stderr)
                    resumeGate.run {
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if proc.terminationStatus != 0 {
                            continuation.resume(
                                throwing: ProcessRunnerError.nonZeroExit(
                                    code: result.exitCode,
                                    stdout: stdout,
                                    stderr: stderr
                                )
                            )
                        } else {
                            continuation.resume(returning: result)
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    resumeGate.run {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }
}

private final class ContinuationResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func run(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        action()
    }
}
