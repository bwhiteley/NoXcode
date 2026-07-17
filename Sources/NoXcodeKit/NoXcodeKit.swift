import Foundation
import CoreModels
import ProcessRunner
import Simctl
import Devicectl
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
    public let key: BuildBucketKey
    public let sdk: String
    public let destination: String
}

public enum BuildTarget: String, Codable, Hashable, Sendable {
    case simulator
    case physicalDevice
}

public struct BuildBucketKey: Hashable, Sendable {
    public let platform: Platform
    public let target: BuildTarget
}

public final class NoXcodeKit: Sendable {
    private let simctl: SimctlClient
    private let devicectl: DevicectlClient
    private let xcodebuild: XcodeBuildClient
    private let configStore: ConfigStore

    public init(
        simctl: SimctlClient = SimctlClient(),
        devicectl: DevicectlClient = DevicectlClient(),
        xcodebuild: XcodeBuildClient = XcodeBuildClient(),
        configStore: ConfigStore = ConfigStore()
    ) {
        self.simctl = simctl
        self.devicectl = devicectl
        self.xcodebuild = xcodebuild
        self.configStore = configStore
    }

    public func listSimulators() async throws -> [SimDevice] {
        try await simctl.listDevices()
    }

    public func listPhysicalDevices() async throws -> [PhysicalDevice] {
        try await devicectl.listDevices()
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

    public func listStoreKitConfigurationFiles(projectPath: String) throws -> [String] {
        let projectURL = URL(fileURLWithPath: projectPath)
        let projectDirectoryURL = projectURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: projectDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var candidates: [URL] = []
        for entry in entries {
            var isDirectory = ObjCBool(false)
            let exists = fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory)
            guard exists else { continue }
            if isDirectory.boolValue {
                let childEntries = try fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                candidates.append(contentsOf: childEntries.filter { $0.pathExtension == "storekit" })
            } else if entry.pathExtension == "storekit" {
                candidates.append(entry)
            }
        }

        return candidates
            .map { $0.path.replacingOccurrences(of: projectDirectoryURL.path + "/", with: "") }
            .sorted()
    }

    public func run(
        config: NoXcodeConfig,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        dryRun: Bool = false,
        rerun: Bool = false,
        logger: RunLogger = StdoutLogger()
    ) async throws {
        if config.simulators.isEmpty && config.physicalDevices.isEmpty {
            logger.log(.init("No simulators or physical devices selected in config."))
            return
        }

        var buildResults: [BuildBucketKey: BuildResult] = [:]
        let bundleId: String

        if rerun {
            bundleId = try await resolveBundleIdForRerun(config: config, logger: logger, dryRun: dryRun)
        } else {
            let projectPath = config.project
            let derivedDataBase = config.derivedDataPath ?? ".noxcode/DerivedData"
            let buckets = buildBuckets(
                forSimulators: config.simulators,
                physicalDevices: config.physicalDevices
            )
            if buckets.isEmpty {
                logger.log(.init("No supported platforms found in config."))
                return
            }

            if dryRun {
                for bucket in buckets {
                    let targetName = bucket.key.target == .simulator ? "simulators" : "physical devices"
                    logger.log(
                        .init(
                            "Would build \(config.scheme) (\(config.configuration)) for \(bucket.key.platform.rawValue) \(targetName) SDK \(bucket.sdk)"
                        )
                    )
                }
            } else {
                try await withThrowingTaskGroup(of: (BuildBucketKey, BuildResult).self) { group in
                    for bucket in buckets {
                        group.addTask {
                            let targetSuffix = bucket.key.target == .simulator ? "simulator" : "physical"
                            let derivedData = "\(derivedDataBase)-\(bucket.key.platform.rawValue.lowercased())-\(targetSuffix)"
                            let request = BuildRequest(
                                projectPath: projectPath,
                                scheme: config.scheme,
                                configuration: config.configuration,
                                sdk: bucket.sdk,
                                destination: bucket.destination,
                                derivedDataPath: derivedData,
                                buildSettingOverrides: self.buildSettingOverrides(for: bucket)
                            )
                            let result = try await self.xcodebuild.build(request) { line, isStderr in
                                let prefix = isStderr ? "stderr" : "stdout"
                                let destinationName = bucket.key.target == .simulator ? "simulator" : "device"
                                logger.log(
                                    .init(
                                        "[\(bucket.key.platform.rawValue) \(destinationName)] \(prefix): \(line.trimmingCharacters(in: .newlines))"
                                    )
                                )
                            }
                            return (bucket.key, result)
                        }
                    }
                    for try await (key, result) in group {
                        buildResults[key] = result
                    }
                }
            }
            bundleId = try resolveBundleId(config: config, buildResults: buildResults, logger: logger, dryRun: dryRun)
        }

        if dryRun {
            let targetsSummary = "\(config.simulators.count) simulators and \(config.physicalDevices.count) physical devices"
            if rerun {
                logger.log(.init("Would relaunch \(bundleId) on \(targetsSummary) (skip build + install)."))
            } else {
                logger.log(.init("Would install + launch \(bundleId) on \(targetsSummary)."))
            }
            return
        }

        let simulatorDevicesByUDID = config.simulators.isEmpty
            ? [:]
            : Dictionary(uniqueKeysWithValues: (try? await simctl.listDevices())?.map { ($0.udid, $0) } ?? [])
        let physicalDevices = config.physicalDevices.isEmpty
            ? []
            : ((try? await devicectl.listDevices()) ?? [])
        let physicalDevicesByIdentifier = Dictionary(
            uniqueKeysWithValues: physicalDevices.map { ($0.identifier, $0) }
        )
        let physicalDevicesByUDID = Dictionary(
            uniqueKeysWithValues: physicalDevices.compactMap { device -> (String, PhysicalDevice)? in
                guard let udid = device.udid else { return nil }
                return (udid, device)
            }
        )
        let semaphore = AsyncSemaphore(maxConcurrent: 6)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for sim in config.simulators {
                group.addTask {
                    await semaphore.acquire()
                    defer { Task { await semaphore.release() } }
                    try await self.simctl.boot(sim.udid)
                    if !rerun {
                        let key = BuildBucketKey(platform: sim.platform, target: .simulator)
                        guard let build = buildResults[key] else {
                            logger.log(.init("No build output for \(sim.platform.rawValue); skipping \(sim.udid)."))
                            return
                        }
                        try await self.simctl.install(sim.udid, appPath: build.appPath)
                    }
                    if !rerun,
                       let storeKitConfigurationFile = config.storeKitConfigurationFile,
                       !storeKitConfigurationFile.isEmpty {
                        try self.copyStoreKitConfigurationFile(
                            storeKitConfigurationFile,
                            config: config,
                            workingDirectory: workingDirectory,
                            simulatorUDID: sim.udid,
                            bundleId: bundleId
                        )
                        logger.log(.init("Applied StoreKit config to \(sim.udid): \(storeKitConfigurationFile)"))
                    }
                    try await self.simctl.launch(
                        sim.udid,
                        bundleId: bundleId,
                        arguments: config.launchArguments,
                        environmentVariables: config.environmentVariables,
                        terminateRunningProcess: rerun
                    )
                    let launchVerb = rerun ? "Relaunched" : "Launched"
                    let device = simulatorDevicesByUDID[sim.udid]
                    let deviceType = device?.name ?? "Unknown Device"
                    let osVersion = device?.osVersion ?? "Unknown OS"
                    logger.log(.init("\(launchVerb) \(bundleId) on \(sim.udid) (\(deviceType), OS \(osVersion))."))
                }
            }

            for physicalDevice in config.physicalDevices {
                group.addTask {
                    await semaphore.acquire()
                    defer { Task { await semaphore.release() } }
                    if !rerun {
                        let key = BuildBucketKey(platform: physicalDevice.platform, target: .physicalDevice)
                        guard let build = buildResults[key] else {
                            logger.log(
                                .init(
                                    "No build output for \(physicalDevice.platform.rawValue); skipping \(physicalDevice.identifier)."
                                )
                            )
                            return
                        }
                        try await self.devicectl.install(physicalDevice.identifier, appPath: build.appPath)
                    }
                    try await self.devicectl.launch(
                        physicalDevice.identifier,
                        bundleId: bundleId,
                        arguments: config.launchArguments,
                        environmentVariables: config.environmentVariables,
                        terminateRunningProcess: rerun
                    )
                    let launchVerb = rerun ? "Relaunched" : "Launched"
                    let resolvedDevice = physicalDevicesByIdentifier[physicalDevice.identifier]
                        ?? physicalDevicesByUDID[physicalDevice.identifier]
                    let deviceName = resolvedDevice?.name ?? "Unknown Device"
                    let osVersion = resolvedDevice?.osVersion ?? "Unknown OS"
                    logger.log(
                        .init(
                            "\(launchVerb) \(bundleId) on \(physicalDevice.identifier) (\(deviceName), OS \(osVersion))."
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        if !config.simulators.isEmpty {
            try await simctl.openSimulatorApp()
        }
    }

    private func buildBuckets(
        forSimulators simulators: [SimulatorSelection],
        physicalDevices: [PhysicalDeviceSelection]
    ) -> [BuildBucket] {
        var buckets: [BuildBucket] = []
        let simulatorPlatforms = Set(simulators.map(\.platform)).sorted { $0.rawValue < $1.rawValue }
        let physicalPlatforms = Set(physicalDevices.map(\.platform)).sorted { $0.rawValue < $1.rawValue }

        buckets.append(contentsOf: simulatorPlatforms.compactMap(simulatorBuildBucket(for:)))
        buckets.append(contentsOf: physicalPlatforms.compactMap(physicalBuildBucket(for:)))
        return buckets
    }

    private func simulatorBuildBucket(for platform: Platform) -> BuildBucket? {
        switch platform {
        case .iOS:
            return BuildBucket(
                key: BuildBucketKey(platform: .iOS, target: .simulator),
                sdk: "iphonesimulator",
                destination: "generic/platform=iOS Simulator"
            )
        case .tvOS:
            return BuildBucket(
                key: BuildBucketKey(platform: .tvOS, target: .simulator),
                sdk: "appletvsimulator",
                destination: "generic/platform=tvOS Simulator"
            )
        case .watchOS:
            return BuildBucket(
                key: BuildBucketKey(platform: .watchOS, target: .simulator),
                sdk: "watchsimulator",
                destination: "generic/platform=watchOS Simulator"
            )
        case .visionOS:
            return BuildBucket(
                key: BuildBucketKey(platform: .visionOS, target: .simulator),
                sdk: "xrsimulator",
                destination: "generic/platform=visionOS Simulator"
            )
        }
    }

    private func physicalBuildBucket(for platform: Platform) -> BuildBucket? {
        switch platform {
        case .iOS:
            return BuildBucket(
                key: BuildBucketKey(platform: .iOS, target: .physicalDevice),
                sdk: "iphoneos",
                destination: "generic/platform=iOS"
            )
        case .tvOS:
            return BuildBucket(
                key: BuildBucketKey(platform: .tvOS, target: .physicalDevice),
                sdk: "appletvos",
                destination: "generic/platform=tvOS"
            )
        case .watchOS:
            return BuildBucket(
                key: BuildBucketKey(platform: .watchOS, target: .physicalDevice),
                sdk: "watchos",
                destination: "generic/platform=watchOS"
            )
        case .visionOS:
            return BuildBucket(
                key: BuildBucketKey(platform: .visionOS, target: .physicalDevice),
                sdk: "xros",
                destination: "generic/platform=visionOS"
            )
        }
    }

    private func buildSettingOverrides(for bucket: BuildBucket) -> [String] {
        guard bucket.key.target == .simulator, shouldForceArm64SimulatorBuilds else {
            return []
        }
        // On Apple Silicon, default simulator builds to arm64 to avoid x86_64 slices.
        return [
            "ARCHS=arm64",
            "ONLY_ACTIVE_ARCH=YES",
            "EXCLUDED_ARCHS=x86_64"
        ]
    }

    private var shouldForceArm64SimulatorBuilds: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private func resolveBundleId(
        config: NoXcodeConfig,
        buildResults: [BuildBucketKey: BuildResult],
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

    private func resolveBundleIdForRerun(
        config: NoXcodeConfig,
        logger: RunLogger,
        dryRun: Bool
    ) async throws -> String {
        if let bundleId = config.bundleId {
            return bundleId
        }
        if dryRun {
            return "com.example.app"
        }
        if let bundleId = try await xcodebuild.bundleIdentifier(
            projectPath: config.project,
            scheme: config.scheme,
            configuration: config.configuration
        ), !bundleId.isEmpty {
            logger.log(.init("Inferred bundleId: \(bundleId)"))
            return bundleId
        }
        throw NSError(
            domain: "NoXcodeKit",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Unable to resolve bundleId for rerun. Set bundleId in .noxcode.json or ensure xcodebuild can read PRODUCT_BUNDLE_IDENTIFIER."
            ]
        )
    }

    private func copyStoreKitConfigurationFile(
        _ storeKitConfigurationFile: String,
        config: NoXcodeConfig,
        workingDirectory: URL,
        simulatorUDID: String,
        bundleId: String
    ) throws {
        let projectURL = resolvedProjectURL(for: config, workingDirectory: workingDirectory)
        let projectDirectoryURL = projectURL.deletingLastPathComponent()
        let sourceURL: URL
        if storeKitConfigurationFile.hasPrefix("/") {
            sourceURL = URL(fileURLWithPath: storeKitConfigurationFile)
        } else {
            sourceURL = projectDirectoryURL.appendingPathComponent(storeKitConfigurationFile)
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(
                domain: "NoXcodeKit",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "StoreKit config not found at path: \(sourceURL.path)"]
            )
        }

        let systemRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            .appendingPathComponent(simulatorUDID)
            .appendingPathComponent("data/Containers/Data/System")
        let systemContainerURL = try resolveSystemContainer(in: systemRoot)
        let destinationDirectory = systemContainerURL
            .appendingPathComponent("Documents/Persistence/Octane")
            .appendingPathComponent(bundleId)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = destinationDirectory.appendingPathComponent("Configuration.storekit")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func resolvedProjectURL(for config: NoXcodeConfig, workingDirectory: URL) -> URL {
        let configuredProjectURL = URL(fileURLWithPath: config.project)
        if configuredProjectURL.path.hasPrefix("/") {
            return configuredProjectURL
        }
        return workingDirectory.appendingPathComponent(config.project)
    }

    private func resolveSystemContainer(in systemRoot: URL) throws -> URL {
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: systemRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let directories = children.filter { url in
            var isDirectory = ObjCBool(false)
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
        if let persistenceContainer = directories.first(where: { directory in
            fileManager.fileExists(atPath: directory.appendingPathComponent("Documents/Persistence").path)
        }) {
            return persistenceContainer
        }
        if let first = directories.first {
            return first
        }
        throw NSError(
            domain: "NoXcodeKit",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Unable to locate simulator system container at \(systemRoot.path)"]
        )
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
