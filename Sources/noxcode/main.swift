import Foundation
import ArgumentParser
import NoXcodeKit
import ProjectConfig
import CoreModels

@main
struct NoXcodeCLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "noxcode",
        abstract: "Build and launch Xcode projects on multiple simulators.",
        subcommands: [ListSims.self, Init.self, Run.self]
    )
}

struct ListSims: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "list-sims",
        abstract: "List available simulators."
    )

    @Flag(help: "Output JSON")
    var json: Bool = false

    func run() async throws {
        let kit = NoXcodeKit()
        let devices = try await kit.listSimulators()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(devices)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        for device in devices.sorted(by: { $0.name < $1.name }) {
            let platform = device.platform?.rawValue ?? "Unknown"
            print("\(device.name) [\(platform)] \(device.udid) \(device.state.rawValue)")
        }
    }
}

struct Init: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a .noxcode.json config file."
    )

    @Option(help: "Path to .xcodeproj (relative or absolute)")
    var project: String?

    @Option(help: "Scheme name")
    var scheme: String

    @Option(name: .customLong("config"), help: "Build configuration (Debug/Release)")
    var configuration: String

    @Option(help: "Bundle identifier override")
    var bundleId: String?

    @Option(help: "StoreKit configuration file path (.storekit), relative to project directory or absolute")
    var storekit: String?

    @Option(parsing: .upToNextOption, help: "Simulator UDIDs (repeatable)")
    var simulator: [String] = []

    func run() async throws {
        let kit = NoXcodeKit()
        let store = ConfigStore()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let projectPath = try store.resolveProjectPath(in: cwd, explicitPath: project)

        let devices = try await kit.listSimulators()
        let byUdid = Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, $0) })
        let selections: [SimulatorSelection] = simulator.compactMap { udid in
            guard let device = byUdid[udid], let platform = device.platform else { return nil }
            return SimulatorSelection(udid: udid, platform: platform)
        }

        if selections.isEmpty {
            throw ValidationError("No valid simulator UDIDs provided. Use `noxcode list-sims` to see UDIDs.")
        }

        let storeKitConfigurationFile = try validateStoreKitPath(
            storekit,
            projectPath: projectPath,
            workingDirectory: cwd
        )

        let config = NoXcodeConfig(
            project: projectPath,
            scheme: scheme,
            configuration: configuration,
            bundleId: bundleId,
            storeKitConfigurationFile: storeKitConfigurationFile,
            simulators: selections,
            derivedDataPath: ".noxcode/DerivedData"
        )
        try kit.writeConfig(config, projectPath: projectPath)
        print("Wrote .noxcode.json for \(projectPath)")
    }

    private func validateStoreKitPath(
        _ storekitPath: String?,
        projectPath: String,
        workingDirectory: URL
    ) throws -> String? {
        guard let storekitPath, !storekitPath.isEmpty else { return nil }
        guard storekitPath.hasSuffix(".storekit") else {
            throw ValidationError("--storekit must point to a .storekit file")
        }

        let projectURL = URL(fileURLWithPath: projectPath, relativeTo: workingDirectory).standardizedFileURL
        let projectDirectoryURL = projectURL.deletingLastPathComponent()
        let inputURL = URL(fileURLWithPath: storekitPath)
        let resolvedURL: URL
        if inputURL.path.hasPrefix("/") {
            resolvedURL = inputURL.standardizedFileURL
        } else {
            resolvedURL = projectDirectoryURL.appendingPathComponent(storekitPath).standardizedFileURL
        }

        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            throw ValidationError("StoreKit file not found: \(resolvedURL.path)")
        }

        if resolvedURL.path.hasPrefix(projectDirectoryURL.path + "/") {
            let relativePath = String(resolvedURL.path.dropFirst(projectDirectoryURL.path.count + 1))
            return relativePath
        }
        return resolvedURL.path
    }
}

struct Run: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and launch based on .noxcode.json"
    )

    @Option(help: "Path to .xcodeproj (relative or absolute)")
    var project: String?

    @Flag(help: "Print actions without executing them")
    var dryRun: Bool = false

    func run() async throws {
        let kit = NoXcodeKit()
        let store = ConfigStore()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let projectPath = try store.resolveProjectPath(in: cwd, explicitPath: project)
        let config = try kit.readConfig(projectPath: projectPath)
        try await kit.run(config: config, workingDirectory: cwd, dryRun: dryRun)
    }
}
