import Foundation
import CoreModels
import ProcessRunner

public final class SimctlClient: Sendable {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func listDevices() async throws -> [SimDevice] {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            ["simctl", "list", "-j", "devices", "available"]
        )
        let data = Data(result.stdout.utf8)
        let decoded = try JSONDecoder().decode(SimctlDevicesResponse.self, from: data)
        return decoded.devices.flatMap { runtime, devices in
            devices.map { device in
                SimDevice(
                    udid: device.udid,
                    name: device.name,
                    state: SimState(rawValue: device.state.lowercased()) ?? .unknown,
                    runtimeIdentifier: runtime,
                    isAvailable: device.isAvailable ?? device.available ?? false,
                    deviceTypeIdentifier: device.deviceTypeIdentifier
                )
            }
        }
    }

    public func boot(_ udid: String) async throws {
        do {
            _ = try await runner.run("/usr/bin/xcrun", ["simctl", "boot", udid])
        } catch let error as ProcessRunnerError {
            if shouldIgnoreBootError(error) {
                return
            }
            throw error
        }
    }

    public func install(_ udid: String, appPath: String) async throws {
        _ = try await runner.run("/usr/bin/xcrun", ["simctl", "install", udid, appPath])
    }

    public func launch(
        _ udid: String,
        bundleId: String,
        arguments: [String] = [],
        environmentVariables: [String: String] = [:]
    ) async throws {
        var simctlEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environmentVariables {
            simctlEnvironment["SIMCTL_CHILD_\(key)"] = value
        }
        let launchArgs = ["simctl", "launch", udid, bundleId] + arguments
        _ = try await runner.run(
            "/usr/bin/xcrun",
            launchArgs,
            environment: simctlEnvironment
        )
    }

    public func openSimulatorApp() async throws {
        _ = try await runner.run("/usr/bin/osascript", ["-e", "tell application \"Simulator\" to activate"])
    }

    private func shouldIgnoreBootError(_ error: ProcessRunnerError) -> Bool {
        switch error {
        case let .nonZeroExit(_, _, stderr):
            return stderr.contains("(domain=com.apple.CoreSimulator.SimError, code=405)")
        }
    }
}

private struct SimctlDevicesResponse: Codable {
    let devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Codable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool?
    let available: Bool?
    let deviceTypeIdentifier: String?
}
