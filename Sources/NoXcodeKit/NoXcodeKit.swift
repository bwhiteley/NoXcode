import Foundation
import CoreModels
import ProcessRunner
import Simctl
import XcodeBuild
import ProjectConfig

public struct RunEvent: Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public protocol RunLogger: Sendable {
    func log(_ event: RunEvent)
}

public struct StdoutLogger: RunLogger {
    public init() {}
    public func log(_ event: RunEvent) { print(event.message) }
}

public struct BuildBucket: Sendable {
    public let platform: Platform
    public let sdk: String
    public let destinationPlatform: String
}

public final class NoXcodeKit: Sendable {
    private let simctl: SimctlClient
    private let xcodebuild: XcodeBuildClient
    private let configStore: ConfigStore

    public init(
        simctl: SimctlClient = SimctlClient(),
        xcodebuild: XcodeBuildClient = XcodeBuildClient(),
        configStore: ConfigStore = ConfigStore()
    ) {
        self.simctl = simctl
        self.xcodebuild = xcodebuild
        self.configStore = configStore
    }

    public func listSimulators() async throws -> [SimDevice] {
        try await simctl.listDevices()
    }

    public func listProjectInfo(projectPath: String) async throws -> XcodeProjectInfo {
        try await xcodebuild.listProjectInfo(projectPath: projectPath)
    }

    public func fetchBundleIdentifier(projectPath: String, scheme: String, configuration: String) async throws -> String? {
        try await xcodebuild.bundleIdentifier(
            projectPath: projectPath,
            scheme: scheme,
            configuration: configuration
        )
    }

    public func readConfig(projectPath: String) throws -> NoXcodeConfig {
        try configStore.readConfig(projectPath: projectPath)
    }

    public func writeConfig(_ config: NoXcodeConfig, projectPath: String) throws {
        try configStore.writeConfig(config, projectPath: projectPath)
    }

    public func run(
        config: NoXcodeConfig,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        dryRun: Bool = false,
        logger: RunLogger = StdoutLogger()
    ) async throws {
        let projectPath = config.project
        let derivedDataBase = config.derivedDataPath ?? ".noxcode/DerivedData"

        let buckets = buildBuckets(for: config.simulators)
        if buckets.isEmpty {
            logger.log(.init("No supported simulator platforms found in config."))
            return
        }

        var buildResults: [Platform: BuildResult] = [:]
        if dryRun {
            for bucket in buckets {
                logger.log(.init("Would build \(config.scheme) (\(config.configuration)) for \(bucket.platform.rawValue) SDK \(bucket.sdk)"))
            }
        } else {
            try await withThrowingTaskGroup(of: (Platform, BuildResult).self) { group in
                for bucket in buckets {
                    group.addTask {
                        let derivedData = "\(derivedDataBase)-\(bucket.platform.rawValue.lowercased())"
                        let request = BuildRequest(
                            projectPath: projectPath,
                            scheme: config.scheme,
                            configuration: config.configuration,
                            sdk: bucket.sdk,
                            destinationPlatform: bucket.destinationPlatform,
                            derivedDataPath: derivedData
                        )
                        let result = try await self.xcodebuild.build(request) { line, isStderr in
                            let prefix = isStderr ? "stderr" : "stdout"
                            logger.log(.init("[\(bucket.platform.rawValue)] \(prefix): \(line.trimmingCharacters(in: .newlines))"))
                        }
                        return (bucket.platform, result)
                    }
                }
                for try await (platform, result) in group {
                    buildResults[platform] = result
                }
            }
        }

        let bundleId = try resolveBundleId(config: config, buildResults: buildResults, logger: logger, dryRun: dryRun)
        if dryRun {
            logger.log(.init("Would install + launch \(bundleId) on \(config.simulators.count) simulators."))
            return
        }

        let semaphore = AsyncSemaphore(maxConcurrent: 6)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for sim in config.simulators {
                group.addTask {
                    await semaphore.acquire()
                    defer { Task { await semaphore.release() } }
                    guard let build = buildResults[sim.platform] else {
                        logger.log(.init("No build output for \(sim.platform.rawValue); skipping \(sim.udid)."))
                        return
                    }
                    try await self.simctl.boot(sim.udid)
                    try await self.simctl.install(sim.udid, appPath: build.appPath)
                    try await self.simctl.launch(
                        sim.udid,
                        bundleId: bundleId,
                        arguments: config.launchArguments,
                        environmentVariables: config.environmentVariables
                    )
                    logger.log(.init("Launched \(bundleId) on \(sim.udid)."))
                }
            }
            try await group.waitForAll()
        }

        try await simctl.openSimulatorApp()
    }

    private func buildBuckets(for simulators: [SimulatorSelection]) -> [BuildBucket] {
        let platforms = Set(simulators.map { $0.platform })
        return platforms.compactMap { platform in
            switch platform {
            case .iOS:
                return BuildBucket(platform: .iOS, sdk: "iphonesimulator", destinationPlatform: "iOS")
            case .tvOS:
                return BuildBucket(platform: .tvOS, sdk: "appletvsimulator", destinationPlatform: "tvOS")
            case .watchOS:
                return BuildBucket(platform: .watchOS, sdk: "watchsimulator", destinationPlatform: "watchOS")
            case .visionOS:
                return BuildBucket(platform: .visionOS, sdk: "xrsimulator", destinationPlatform: "visionOS")
            }
        }
    }

    private func resolveBundleId(
        config: NoXcodeConfig,
        buildResults: [Platform: BuildResult],
        logger: RunLogger,
        dryRun: Bool
    ) throws -> String {
        if let bundleId = config.bundleId {
            return bundleId
        }
        guard let firstBuild = buildResults.first?.value else {
            if dryRun { return "com.example.app" }
            throw NSError(domain: "NoXcodeKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "No build results to infer bundleId."])
        }
        let infoPlist = URL(fileURLWithPath: firstBuild.appPath).appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoPlist)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        if let bundleId = plist?["CFBundleIdentifier"] as? String {
            logger.log(.init("Inferred bundleId: \(bundleId)"))
            return bundleId
        }
        throw NSError(domain: "NoXcodeKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "CFBundleIdentifier not found in Info.plist."])
    }
}

private actor AsyncSemaphore {
    private let maxConcurrent: Int
    private var current: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async {
        if current < maxConcurrent {
            current += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() async {
        if let continuation = waiters.first {
            waiters.removeFirst()
            continuation.resume()
        } else {
            current = max(0, current - 1)
        }
    }
}
