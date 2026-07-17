import Foundation
import CoreModels
import ProcessRunner

public final class DevicectlClient: Sendable {
    private let runner: ProcessRunner

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
        _ = try await runner.run(
            "/usr/bin/xcrun",
            ["devicectl", "device", "install", "app", "--device", identifier, appPath]
        )
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
                .reduce(into: [String: String]()) { $0[$1.key] = $1.value })
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

        _ = try await runner.run("/usr/bin/xcrun", launchArgs)
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
