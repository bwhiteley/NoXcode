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
    public let storeKitConfigurationFile: String?
    public let simulators: [SimulatorSelection]
    public let derivedDataPath: String?
    public let launchArguments: [String]
    public let environmentVariableLines: [String]

    public var environmentVariables: [String: String] {
        Self.parseEnvironmentVariables(from: environmentVariableLines)
    }

    public init(
        project: String,
        scheme: String,
        configuration: String,
        bundleId: String? = nil,
        storeKitConfigurationFile: String? = nil,
        simulators: [SimulatorSelection],
        derivedDataPath: String? = ".noxcode/DerivedData",
        launchArguments: [String] = [],
        environmentVariableLines: [String] = []
    ) {
        self.project = project
        self.scheme = scheme
        self.configuration = configuration
        self.bundleId = bundleId
        self.storeKitConfigurationFile = storeKitConfigurationFile
        self.simulators = simulators
        self.derivedDataPath = derivedDataPath
        self.launchArguments = launchArguments
        self.environmentVariableLines = environmentVariableLines
    }

    public init(
        project: String,
        scheme: String,
        configuration: String,
        bundleId: String? = nil,
        storeKitConfigurationFile: String? = nil,
        simulators: [SimulatorSelection],
        derivedDataPath: String? = ".noxcode/DerivedData",
        launchArguments: [String] = [],
        environmentVariables: [String: String]
    ) {
        self.init(
            project: project,
            scheme: scheme,
            configuration: configuration,
            bundleId: bundleId,
            storeKitConfigurationFile: storeKitConfigurationFile,
            simulators: simulators,
            derivedDataPath: derivedDataPath,
            launchArguments: launchArguments,
            environmentVariableLines: Self.lines(from: environmentVariables)
        )
    }

    enum CodingKeys: String, CodingKey {
        case project
        case scheme
        case configuration
        case bundleId
        case storeKitConfigurationFile
        case simulators
        case derivedDataPath
        case launchArguments
        case environmentVariableLines
        case environmentVariables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(String.self, forKey: .project)
        scheme = try container.decode(String.self, forKey: .scheme)
        configuration = try container.decode(String.self, forKey: .configuration)
        bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
        storeKitConfigurationFile = try container.decodeIfPresent(String.self, forKey: .storeKitConfigurationFile)
        simulators = try container.decode([SimulatorSelection].self, forKey: .simulators)
        derivedDataPath = try container.decodeIfPresent(String.self, forKey: .derivedDataPath)
        launchArguments = try container.decodeIfPresent([String].self, forKey: .launchArguments) ?? []
        environmentVariableLines = try Self.decodeEnvironmentVariableLines(from: container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(project, forKey: .project)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(configuration, forKey: .configuration)
        try container.encodeIfPresent(bundleId, forKey: .bundleId)
        try container.encodeIfPresent(storeKitConfigurationFile, forKey: .storeKitConfigurationFile)
        try container.encode(simulators, forKey: .simulators)
        try container.encodeIfPresent(derivedDataPath, forKey: .derivedDataPath)
        try container.encode(launchArguments, forKey: .launchArguments)
        try container.encode(environmentVariableLines, forKey: .environmentVariableLines)
        try container.encode(environmentVariables, forKey: .environmentVariables)
    }

    private static func decodeEnvironmentVariableLines(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String] {
        if let lines = try container.decodeIfPresent([String].self, forKey: .environmentVariableLines) {
            return lines
        }
        if let lines = try? container.decode([String].self, forKey: .environmentVariables) {
            return lines
        }
        let environmentVariables = try container.decodeIfPresent([String: String].self, forKey: .environmentVariables) ?? [:]
        return Self.lines(from: environmentVariables)
    }

    private static func parseEnvironmentVariables(from lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private static func lines(from environmentVariables: [String: String]) -> [String] {
        environmentVariables
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }
}
