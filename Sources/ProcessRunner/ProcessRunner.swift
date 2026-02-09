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

        try process.run()
        process.waitUntilExit()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        let stdout = String(data: stdoutBuffer.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
        let result = ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)

        if process.terminationStatus != 0 {
            throw ProcessRunnerError.nonZeroExit(code: result.exitCode, stdout: stdout, stderr: stderr)
        }

        return result
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
