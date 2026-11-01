import Foundation
import CoreModels
import ProcessRunner

public final class DevicectlClient: Sendable {
    private let runner: ProcessRunner
    /// CoreDevice's host service drops Mercury connections when several devicectl
    /// processes talk to devices at once. Keep install, launch, and reconnect serial.
    private let deviceCommands = DeviceCommandSerializer()

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func listDevices() async throws -> [PhysicalDevice] {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noxcode-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        _ = try await runner.run(
            "/usr/bin/xcrun",
            ["devicectl", "list", "devices", "--json-output", outputURL.path]
        )

        let data = try Data(contentsOf: outputURL)
        let response = try JSONDecoder().decode(DevicectlListResponse.self, from: data)
        return response.result.devices
            .compactMap(Self.makePhysicalDevice)
            .sorted {
                if $0.name == $1.name {
                    return $0.identifier < $1.identifier
                }
                return $0.name < $1.name
            }
    }

    public func install(_ identifier: String, appPath: String) async throws {
        try await withDeviceCommandLock {
            _ = try await self.runner.run(
                "/usr/bin/xcrun",
                ["devicectl", "device", "install", "app", "--device", identifier, appPath]
            )
        }
    }

    public func launch(
        _ identifier: String,
        bundleId: String,
        arguments: [String] = [],
        environmentVariables: [String: String] = [:],
        terminateRunningProcess: Bool = false
    ) async throws {
        var launchArgs = ["devicectl", "device", "process", "launch", "--device", identifier]
        if terminateRunningProcess {
            launchArgs.append("--terminate-existing")
        }
        if !environmentVariables.isEmpty {
            let environmentData = try JSONSerialization.data(withJSONObject: environmentVariables.sorted(by: { $0.key < $1.key })
                .reduce(into: [String: String]()) { $0[$1.key] = $1.value }, options: [.withoutEscapingSlashes])
            guard let environmentJSONString = String(data: environmentData, encoding: .utf8) else {
                throw NSError(
                    domain: "DevicectlClient",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode environment variables for devicectl launch."]
                )
            }
            launchArgs += ["--environment-variables", environmentJSONString]
        }
        launchArgs.append(bundleId)
        launchArgs += arguments

        let command = launchArgs
        try await withDeviceCommandLock {
            _ = try await self.runner.run("/usr/bin/xcrun", command)
        }
    }

    /// Bring a paired device back to the state Device Hub reaches by selecting it.
    ///
    /// After a device sits idle, CoreDevice drops the tunnel and developer disk image
    /// services. Selecting the device in Device Hub acquires a usage assertion and
    /// enables those services, retrying when the Mercury connection is interrupted.
    /// `devicectl device info ddiServices --auto-mount-ddis` does that work.
    public func prepareForDeployment(
        _ identifier: String,
        displayName: String? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try await withDeviceCommandLock {
            try await self.prepareForDeploymentWhileLocked(identifier, displayName: displayName, log: log)
        }
    }

    /// Hold the device-command lock across awaits. An actor method that awaits the
    /// work itself is reentrant, so two devicectl processes could still overlap.
    private func withDeviceCommandLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await deviceCommands.acquire()
        do {
            let value = try await operation()
            await deviceCommands.release()
            return value
        } catch {
            await deviceCommands.release()
            throw error
        }
    }

    private func prepareForDeploymentWhileLocked(
        _ identifier: String,
        displayName: String?,
        log: (@Sendable (String) -> Void)?
    ) async throws {
        let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? identifier
        let snapshot = try await readConnectionSnapshot(identifier, displayName: name, log: log)
        if snapshot?.developerModeEnabled == false {
            throw DevicectlClientError.developerModeDisabled(device: name)
        }
        if snapshot?.pairingState?.lowercased() == "unpaired" {
            log?("\(name) is not paired. Pairing now. Accept the trust prompt on the device if one appears.")
            _ = try await runner.run(
                "/usr/bin/xcrun",
                ["devicectl", "manage", "pair", "--device", identifier, "--timeout", String(Self.pairingTimeoutSeconds)]
            )
        }

        log?("Reconnecting \(name) and enabling developer services…")
        try await enableDeveloperServices(identifier, displayName: name, log: log)
        log?("Developer services ready on \(name).")
    }

    public static func isRetryableConnectionFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let text = String(describing: error).lowercased()
        if text.contains("developer mode") || text.contains("device is locked") || text.contains("passcode") {
            return false
        }
        let retryableMarkers = [
            "coredeviceerror error 3 (",
            "coredeviceerror error 4000",
            "mercury.error",
            "communicating with a remote process",
            "connection was interrupted",
            "connection was invalidated",
            "connection reset by peer",
            "controlchannelconnectionerror",
            "remotepairingerror",
            "could not be established",
            "tunnel listener",
            "connectivity was interrupted",
            "network timed out",
            "operations timed out",
            "could not reach device",
            "device is not connected"
        ]
        return retryableMarkers.contains { text.contains($0) }
    }

    private func readConnectionSnapshot(
        _ identifier: String,
        displayName: String,
        log: (@Sendable (String) -> Void)?
    ) async throws -> ConnectionSnapshot? {
        do {
            let data = try await runJSONCommand(
                ["devicectl", "device", "info", "details", "--device", identifier],
                timeoutSeconds: Self.connectionTimeoutSeconds
            )
            return try JSONDecoder().decode(DeviceDetailsResponse.self, from: data).snapshot
        } catch let error as CancellationError {
            throw error
        } catch {
            log?("Could not read status for \(displayName) (\(Self.summarize(error))). Trying to reconnect anyway.")
            return nil
        }
    }

    private func enableDeveloperServices(
        _ identifier: String,
        displayName: String,
        log: (@Sendable (String) -> Void)?
    ) async throws {
        var lastError: Error?
        for attempt in 1...Self.maxConnectionAttempts {
            do {
                let data = try await runJSONCommand(
                    [
                        "devicectl", "device", "info", "ddiServices",
                        "--device", identifier,
                        "--auto-mount-ddis"
                    ],
                    timeoutSeconds: Self.connectionTimeoutSeconds
                )
                let metadata = try JSONDecoder().decode(DDIServicesResponse.self, from: data).result.ddiMetadata
                if metadata?.isUsable == false {
                    throw DevicectlClientError.developerServicesUnavailable(device: displayName)
                }
                if metadata?.contentIsCompatible == false {
                    throw DevicectlClientError.incompatibleDeveloperDiskImage(device: displayName)
                }
                return
            } catch let error as CancellationError {
                throw error
            } catch {
                lastError = error
                let canRetry = attempt < Self.maxConnectionAttempts && Self.isRetryableConnectionFailure(error)
                if !canRetry {
                    throw error
                }
                let delay = Self.retryDelaySeconds(after: attempt)
                log?(
                    "\(displayName) dropped the connection (attempt \(attempt) of \(Self.maxConnectionAttempts)): \(Self.summarize(error)). Retrying in \(Int(delay))s…"
                )
                try await Task.sleep(for: .seconds(delay))
                try await reviveTunnel(identifier, displayName: displayName, log: log)
            }
        }
        throw lastError ?? DevicectlClientError.developerServicesUnavailable(device: displayName)
    }

    /// Open a fresh CoreDevice tunnel after Mercury interrupts the previous one.
    private func reviveTunnel(
        _ identifier: String,
        displayName: String,
        log: (@Sendable (String) -> Void)?
    ) async throws {
        do {
            _ = try await runJSONCommand(
                ["devicectl", "device", "info", "details", "--device", identifier],
                timeoutSeconds: Self.connectionTimeoutSeconds
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            log?("\(displayName) is still waking up (\(Self.summarize(error))).")
        }
    }

    private func runJSONCommand(_ arguments: [String], timeoutSeconds: Int) async throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noxcode-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var command = arguments
        command += ["--timeout", String(timeoutSeconds), "--json-output", outputURL.path]
        _ = try await runner.run("/usr/bin/xcrun", command)
        return try Data(contentsOf: outputURL)
    }

    private static func summarize(_ error: Error) -> String {
        let raw: String
        if case let ProcessRunnerError.nonZeroExit(_, _, stderr) = error {
            raw = stderr
        } else {
            raw = String(describing: error)
        }
        let line = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("-") }
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.count <= 300 {
            return line
        }
        return String(line.prefix(300)) + "…"
    }

    private static let connectionTimeoutSeconds = 60
    private static let pairingTimeoutSeconds = 90
    private static let maxConnectionAttempts = 5

    private static func retryDelaySeconds(after attempt: Int) -> Double {
        Double(min(2 * attempt, 8))
    }

    private static func makePhysicalDevice(from device: DevicectlDevice) -> PhysicalDevice? {
        guard isPhysicalDevice(device) else { return nil }

        guard let platform = parsePlatform(from: device) else { return nil }
        let name = device.properties?.state?.name
            ?? device.deviceProperties?.name
            ?? device.identifier
        let osVersion = device.properties?.software?.osVersionNumber?.stringValue
            ?? device.deviceProperties?.osVersionNumber
        let connectionState = device.properties?.connection?.state
            ?? device.connectionProperties?.state
            ?? device.connectionProperties?.tunnelState
        let pairingState = device.properties?.connection?.pairingState
            ?? device.connectionProperties?.pairingState
        let state = stateLabel(connectionState: connectionState, pairingState: pairingState)
        let isAvailable = (pairingState?.lowercased() == "paired") || (connectionState?.lowercased() == "connected")

        return PhysicalDevice(
            identifier: device.identifier,
            udid: device.properties?.hardware?.udid ?? device.hardwareProperties?.udid,
            name: name,
            state: state,
            platform: platform,
            osVersion: osVersion,
            isAvailable: isAvailable
        )
    }

    private static func isPhysicalDevice(_ device: DevicectlDevice) -> Bool {
        let reality = (device.properties?.hardware?.reality ?? device.hardwareProperties?.reality)?.lowercased()
        if reality == "simulated" {
            return false
        }
        if reality == "physical" {
            return true
        }
        // Some physical devices (notably certain Apple TV entries) omit reality.
        // Fall back to visibility class and include anything that is not simulator-only.
        let visibilityClass = device.visibilityClass?.lowercased()
        return visibilityClass != "simulators"
    }

    private static func parsePlatform(from device: DevicectlDevice) -> Platform? {
        if let platform = device.properties?.hardware?.platform ?? device.hardwareProperties?.platform,
           let parsed = Platform(rawValue: platform) {
            return parsed
        }

        let fallbackText = [
            device.properties?.hardware?.deviceType,
            device.hardwareProperties?.deviceType,
            device.properties?.hardware?.productType,
            device.hardwareProperties?.productType
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if fallbackText.contains("iphone") || fallbackText.contains("ipad") || fallbackText.contains("ipod") {
            return .iOS
        }
        if fallbackText.contains("appletv") || fallbackText.contains("tvos") {
            return .tvOS
        }
        if fallbackText.contains("watch") {
            return .watchOS
        }
        if fallbackText.contains("vision") || fallbackText.contains("xros") {
            return .visionOS
        }
        return nil
    }

    private static func stateLabel(connectionState: String?, pairingState: String?) -> String {
        let state = connectionState?.lowercased()
        let pairing = pairingState?.lowercased()
        if state == "connected" {
            return "connected"
        }
        if pairing == "paired" {
            return "available (paired)"
        }
        if let connectionState, !connectionState.isEmpty {
            return connectionState
        }
        if let pairingState, !pairingState.isEmpty {
            return pairingState
        }
        return "unknown"
    }
}

private actor DeviceCommandSerializer {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            busy = false
        }
    }
}

public enum DevicectlClientError: Error, CustomStringConvertible {
    case developerModeDisabled(device: String)
    case developerServicesUnavailable(device: String)
    case incompatibleDeveloperDiskImage(device: String)

    public var description: String {
        switch self {
        case let .developerModeDisabled(device):
            return "Developer Mode is turned off on \(device). Turn it on in Settings → Privacy & Security → Developer Mode, then deploy again."
        case let .developerServicesUnavailable(device):
            return "Developer services on \(device) are not usable. Unlock the device, keep it awake, and deploy again."
        case let .incompatibleDeveloperDiskImage(device):
            return "The developer disk image for \(device) is not compatible with this Xcode. Open Xcode once so it can install a matching disk image, then deploy again."
        }
    }
}

private struct DevicectlListResponse: Decodable {
    let result: DevicectlResult
}

private struct DevicectlResult: Decodable {
    let devices: [DevicectlDevice]
}

private struct DevicectlDevice: Decodable {
    let identifier: String
    let visibilityClass: String?
    let properties: DevicectlProperties?
    let hardwareProperties: DevicectlLegacyHardwareProperties?
    let deviceProperties: DevicectlLegacyDeviceProperties?
    let connectionProperties: DevicectlLegacyConnectionProperties?
}

private struct DevicectlProperties: Decodable {
    let hardware: DevicectlHardwareProperties?
    let software: DevicectlSoftwareProperties?
    let state: DevicectlStateProperties?
    let connection: DevicectlConnectionProperties?
}

private struct DevicectlHardwareProperties: Decodable {
    let platform: String?
    let reality: String?
    let udid: String?
    let deviceType: String?
    let productType: String?
}

private struct DevicectlSoftwareProperties: Decodable {
    let osVersionNumber: DevicectlVersionNumber?
}

private struct DevicectlVersionNumber: Decodable {
    let stringValue: String?
}

private struct DevicectlStateProperties: Decodable {
    let name: String?
}

private struct DevicectlConnectionProperties: Decodable {
    let state: String?
    let pairingState: String?
}

private struct DevicectlLegacyHardwareProperties: Decodable {
    let platform: String?
    let reality: String?
    let udid: String?
    let deviceType: String?
    let productType: String?
}

private struct DevicectlLegacyDeviceProperties: Decodable {
    let name: String?
    let osVersionNumber: String?
}

private struct DevicectlLegacyConnectionProperties: Decodable {
    let state: String?
    let pairingState: String?
    let tunnelState: String?
}

private struct ConnectionSnapshot {
    let pairingState: String?
    let developerModeEnabled: Bool?
}

private struct DeviceDetailsResponse: Decodable {
    let result: DeviceDetailsResult

    var snapshot: ConnectionSnapshot {
        ConnectionSnapshot(
            pairingState: result.properties?.connection?.pairingState,
            developerModeEnabled: result.properties?.state?.developerModeStatus?.isEnabled
        )
    }
}

private struct DeviceDetailsResult: Decodable {
    let properties: DeviceDetailsProperties?
}

private struct DeviceDetailsProperties: Decodable {
    let connection: DeviceDetailsConnection?
    let state: DeviceDetailsState?
}

private struct DeviceDetailsConnection: Decodable {
    let pairingState: String?
}

private struct DeviceDetailsState: Decodable {
    let developerModeStatus: DeveloperModeStatusValue?
}

private struct DeveloperModeStatusValue: Decodable {
    let isEnabled: Bool?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            if container.contains(.enabled) {
                isEnabled = true
            } else if container.contains(.disabled) {
                isEnabled = false
            } else {
                isEnabled = nil
            }
            return
        }

        let string = try? decoder.singleValueContainer().decode(String.self)
        switch string?.lowercased() {
        case "enabled":
            isEnabled = true
        case "disabled":
            isEnabled = false
        default:
            isEnabled = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case disabled
    }
}

private struct DDIServicesResponse: Decodable {
    let result: DDIServicesResult
}

private struct DDIServicesResult: Decodable {
    let ddiMetadata: DDIMetadata?
}

private struct DDIMetadata: Decodable {
    let isUsable: Bool?
    let contentIsCompatible: Bool?
}
