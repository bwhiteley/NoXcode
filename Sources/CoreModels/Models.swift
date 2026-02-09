import Foundation

public enum Platform: String, Codable, CaseIterable, Sendable {
    case iOS
    case tvOS
    case watchOS
    case visionOS
}

public enum SimState: String, Codable, Sendable {
    case booted
    case shutdown
    case unknown
}

public struct SimDevice: Codable, Hashable, Sendable, Identifiable {
    public let udid: String
    public let name: String
    public let state: SimState
    public let runtimeIdentifier: String
    public let isAvailable: Bool
    public let deviceTypeIdentifier: String?

    public var id: String { udid }

    public init(
        udid: String,
        name: String,
        state: SimState,
        runtimeIdentifier: String,
        isAvailable: Bool,
        deviceTypeIdentifier: String?
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtimeIdentifier = runtimeIdentifier
        self.isAvailable = isAvailable
        self.deviceTypeIdentifier = deviceTypeIdentifier
    }

    public var platform: Platform? {
        if runtimeIdentifier.contains(".SimRuntime.iOS-") { return .iOS }
        if runtimeIdentifier.contains(".SimRuntime.tvOS-") { return .tvOS }
        if runtimeIdentifier.contains(".SimRuntime.watchOS-") { return .watchOS }
        if runtimeIdentifier.contains(".SimRuntime.xrOS-") { return .visionOS }
        return nil
    }

    public var osVersion: String? {
        guard let last = runtimeIdentifier.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        let versionParts = parts.dropFirst()
        return versionParts.joined(separator: ".")
    }

    public var osDisplayName: String {
        let platformName = platform?.rawValue ?? "Unknown"
        if let version = osVersion {
            return "\(platformName) \(version)"
        }
        return platformName
    }
}

public struct SimulatorSelection: Codable, Hashable, Sendable {
    public let udid: String
    public let platform: Platform

    public init(udid: String, platform: Platform) {
        self.udid = udid
        self.platform = platform
    }
}

public struct XcodeProjectInfo: Codable, Sendable {
    public let schemes: [String]
    public let configurations: [String]

    public init(schemes: [String], configurations: [String]) {
        self.schemes = schemes
        self.configurations = configurations
    }
}

public struct NoXcodeConfig: Codable, Sendable {
    public let project: String
    public let scheme: String
    public let configuration: String
    public let bundleId: String?
    public let simulators: [SimulatorSelection]
    public let derivedDataPath: String?

    public init(
        project: String,
        scheme: String,
        configuration: String,
        bundleId: String? = nil,
        simulators: [SimulatorSelection],
        derivedDataPath: String? = ".noxcode/DerivedData"
    ) {
        self.project = project
        self.scheme = scheme
        self.configuration = configuration
        self.bundleId = bundleId
        self.simulators = simulators
        self.derivedDataPath = derivedDataPath
    }
}
