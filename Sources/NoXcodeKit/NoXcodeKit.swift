import Foundation
import Darwin
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

    public func fetchLaunchConfiguration(projectPath: String, scheme: String) throws -> String? {
        try xcodebuild.launchConfiguration(projectPath: projectPath, scheme: scheme)
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
        let projectPath = config.project
        let derivedDataBaseURL = resolvedDerivedDataBaseURL(
            path: config.derivedDataPath ?? ".noxcode/DerivedData",
            workingDirectory: workingDirectory
        )
        let runLock = dryRun ? nil : try acquireRunLock(in: derivedDataBaseURL)
        defer { runLock?.release() }
        let buckets = buildBuckets(
            forSimulators: config.simulators,
            physicalDevices: config.physicalDevices
        )
        if buckets.isEmpty {
            logger.log(.init("No supported platforms found in config."))
            return
        }

        if dryRun {
            if !rerun {
                for bucket in buckets {
                    let targetName = bucket.key.target == .simulator ? "simulators" : "physical devices"
                    logger.log(
                        .init(
                            "Would build \(config.scheme) (\(config.configuration)) for \(bucket.key.platform.rawValue) \(targetName) SDK \(bucket.sdk)"
                        )
                    )
                }
            }
            let bundleId = try await resolveBundleIdForDryRun(
                config: config,
                rerun: rerun,
                logger: logger
            )
            let targetsSummary = "\(config.simulators.count) simulators and \(config.physicalDevices.count) physical devices"
            if rerun {
                logger.log(.init("Would install + launch \(bundleId) on \(targetsSummary) (skip build)."))
            } else {
                logger.log(.init("Would install + launch \(bundleId) on \(targetsSummary)."))
            }
            return
        }

        try await withThrowingTaskGroup(of: (BuildBucketKey, BuildResult).self) { group in
            for bucket in buckets {
                group.addTask {
                    let targetSuffix = bucket.key.target == .simulator ? "simulator" : "physical"
                    let derivedDataFolder = "\(bucket.key.platform.rawValue.lowercased())-\(targetSuffix)"
                    let derivedData = derivedDataBaseURL
                        .appendingPathComponent(derivedDataFolder, isDirectory: true)
                        .path
                    let request = BuildRequest(
                        projectPath: projectPath,
                        scheme: config.scheme,
                        configuration: config.configuration,
                        sdk: bucket.sdk,
                        destination: bucket.destination,
                        derivedDataPath: derivedData,
                        buildSettingOverrides: self.buildSettingOverrides(for: bucket)
                    )
                    let destinationName = bucket.key.target == .simulator ? "simulator" : "device"
                    let result: BuildResult
                    if rerun {
                        result = try await self.xcodebuild.resolveAppPath(request)
                        guard FileManager.default.fileExists(atPath: result.appPath) else {
                            throw NSError(
                                domain: "NoXcodeKit",
                                code: 6,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "No existing build product for \(bucket.key.platform.rawValue) \(destinationName) at \(result.appPath). Run without --rerun first."
                                ]
                            )
                        }
                        logger.log(
                            .init(
                                "[\(bucket.key.platform.rawValue) \(destinationName)] Reusing existing build at \(result.appPath)"
                            )
                        )
                    } else {
                        result = try await self.xcodebuild.build(request) { line, isStderr in
                            let prefix = isStderr ? "stderr" : "stdout"
                            logger.log(
                                .init(
                                    "[\(bucket.key.platform.rawValue) \(destinationName)] \(prefix): \(line.trimmingCharacters(in: .newlines))"
                                )
                            )
                        }
                    }
                    return (bucket.key, result)
                }
            }
            for try await (key, result) in group {
                buildResults[key] = result
            }
        }

        let bundleId = try resolveBundleId(buildResults: buildResults, logger: logger)

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
                    let key = BuildBucketKey(platform: sim.platform, target: .simulator)
                    guard let build = buildResults[key] else {
                        logger.log(.init("No build output for \(sim.platform.rawValue); skipping \(sim.udid)."))
                        return
                    }
                    try await self.simctl.install(sim.udid, appPath: build.appPath)
                    if let storeKitConfigurationFile = config.storeKitConfigurationFile,
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
                        terminateRunningProcess: true
                    )
                    let device = simulatorDevicesByUDID[sim.udid]
                    let deviceType = device?.name ?? "Unknown Device"
                    let osVersion = device?.osVersion ?? "Unknown OS"
                    logger.log(.init("Launched \(bundleId) on \(sim.udid) (\(deviceType), OS \(osVersion))."))
                }
            }

            for physicalDevice in config.physicalDevices {
                group.addTask {
                    await semaphore.acquire()
                    defer { Task { await semaphore.release() } }
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
                    try await self.devicectl.launch(
                        physicalDevice.identifier,
                        bundleId: bundleId,
                        arguments: config.launchArguments,
                        environmentVariables: config.environmentVariables,
                        terminateRunningProcess: true
                    )
                    let resolvedDevice = physicalDevicesByIdentifier[physicalDevice.identifier]
                        ?? physicalDevicesByUDID[physicalDevice.identifier]
                    let deviceName = resolvedDevice?.name ?? "Unknown Device"
                    let osVersion = resolvedDevice?.osVersion ?? "Unknown OS"
                    logger.log(
                        .init(
                            "Launched \(bundleId) on \(physicalDevice.identifier) (\(deviceName), OS \(osVersion))."
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
        buildResults: [BuildBucketKey: BuildResult],
        logger: RunLogger
    ) throws -> String {
        guard let firstBuild = buildResults.first?.value else {
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

    private func resolveBundleIdForDryRun(
        config: NoXcodeConfig,
        rerun: Bool,
        logger: RunLogger
    ) async throws -> String {
        if !rerun {
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
        return "com.example.app"
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

    private func resolvedDerivedDataBaseURL(path: String, workingDirectory: URL) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        let baseURL: URL
        if expandedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: expandedPath)
        } else {
            baseURL = workingDirectory.appendingPathComponent(expandedPath)
        }
        return baseURL.standardizedFileURL
    }

    private func acquireRunLock(in derivedDataBaseURL: URL) throws -> DerivedDataRunLock {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: derivedDataBaseURL, withIntermediateDirectories: true)
        let lockURL = derivedDataBaseURL.appendingPathComponent(".noxcode.run.lock", isDirectory: false)

        return try DerivedDataRunLock.acquire(lockURL: lockURL, ownerPID: getpid(), lockScope: derivedDataBaseURL.path)
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

private final class DerivedDataRunLock: @unchecked Sendable {
    private var fileDescriptor: Int32
    private let lockPath: String
    private var released = false

    private init(fileDescriptor: Int32, lockPath: String) {
        self.fileDescriptor = fileDescriptor
        self.lockPath = lockPath
    }

    deinit {
        release()
    }

    static func acquire(lockURL: URL, ownerPID: Int32, lockScope: String) throws -> DerivedDataRunLock {
        let lockPath = lockURL.path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH))
        guard descriptor >= 0 else {
            throw NSError(
                domain: "NoXcodeKit",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Unable to open run lock at \(lockPath): \(String(cString: strerror(errno)))"]
            )
        }

        var fileLock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        if fcntl(descriptor, F_SETLK, &fileLock) == -1 {
            let lockError = errno
            let owningPID = readPID(from: descriptor)
            _ = close(descriptor)
            if lockError == EACCES || lockError == EAGAIN {
                let ownerDescription = owningPID.map { " (pid \($0))" } ?? ""
                throw NSError(
                    domain: "NoXcodeKit",
                    code: 8,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Another noxcode run is already active for derivedDataPath \(lockScope)\(ownerDescription)."
                    ]
                )
            }
            throw NSError(
                domain: "NoXcodeKit",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Unable to lock run lock at \(lockPath): \(String(cString: strerror(lockError)))"]
            )
        }

        do {
            try writePID(ownerPID, to: descriptor, at: lockPath)
        } catch {
            lockPath.withCString { cPath in
                _ = unlink(cPath)
            }
            _ = close(descriptor)
            throw error
        }
        return DerivedDataRunLock(fileDescriptor: descriptor, lockPath: lockPath)
    }

    func release() {
        guard !released else { return }
        released = true

        lockPath.withCString { cPath in
            _ = unlink(cPath)
        }
        if fileDescriptor >= 0 {
            _ = close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private static func writePID(_ pid: Int32, to descriptor: Int32, at lockPath: String) throws {
        let pidLine = "\(pid)\n"
        guard let data = pidLine.data(using: .utf8) else {
            throw NSError(
                domain: "NoXcodeKit",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unable to encode PID for run lock at \(lockPath)."]
            )
        }
        guard ftruncate(descriptor, 0) == 0 else {
            throw NSError(
                domain: "NoXcodeKit",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Unable to truncate run lock at \(lockPath): \(String(cString: strerror(errno)))"]
            )
        }
        guard lseek(descriptor, 0, SEEK_SET) != -1 else {
            throw NSError(
                domain: "NoXcodeKit",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Unable to seek run lock at \(lockPath): \(String(cString: strerror(errno)))"]
            )
        }

        var totalWritten = 0
        while totalWritten < data.count {
            let bytesWritten = data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                let pointer = baseAddress.advanced(by: totalWritten)
                return write(descriptor, pointer, data.count - totalWritten)
            }
            if bytesWritten <= 0 {
                throw NSError(
                    domain: "NoXcodeKit",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to write PID to run lock at \(lockPath): \(String(cString: strerror(errno)))"]
                )
            }
            totalWritten += bytesWritten
        }
        _ = fsync(descriptor)
    }

    private static func readPID(from descriptor: Int32) -> Int32? {
        guard lseek(descriptor, 0, SEEK_SET) != -1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        let pidString = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(pidString)
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
