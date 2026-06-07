import Foundation
import CoreModels

public enum ConfigStoreError: Error, CustomStringConvertible {
    case projectNotFound
    case multipleProjects([String])
    case configNotFound

    public var description: String {
        switch self {
        case .projectNotFound:
            return "No .xcodeproj found in current directory."
        case .multipleProjects(let projects):
            return "Multiple .xcodeproj found: \(projects.joined(separator: ", ")). Specify one with --project."
        case .configNotFound:
            return "Config file .noxcode.json not found."
        }
    }
}

public final class ConfigStore: Sendable {
    public init() {}

    public func resolveProjectPath(in directory: URL, explicitPath: String?) throws -> String {
        if let explicitPath {
            return explicitPath
        }
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let projects = contents.filter { $0.pathExtension == "xcodeproj" }.map { $0.lastPathComponent }
        if projects.isEmpty {
            throw ConfigStoreError.projectNotFound
        }
        if projects.count > 1 {
            throw ConfigStoreError.multipleProjects(projects)
        }
        return projects[0]
    }

    public func configURL(projectPath: String) -> URL {
        let projectURL = URL(fileURLWithPath: projectPath)
        let root = projectURL.deletingLastPathComponent()
        return root.appendingPathComponent(".noxcode.json")
    }

    public func readConfig(projectPath: String) throws -> NoXcodeConfig {
        let url = configURL(projectPath: projectPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigStoreError.configNotFound
        }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(NoXcodeConfig.self, from: data)
        let resolvedProjectPath = resolveProjectPath(config.project, relativeTo: url.deletingLastPathComponent())
        return configByUpdatingProject(config, project: resolvedProjectPath)
    }

    public func writeConfig(_ config: NoXcodeConfig, projectPath: String) throws {
        let url = configURL(projectPath: projectPath)
        let relativeProjectPath = makeProjectPathRelativeIfPossible(
            config.project,
            configDirectory: url.deletingLastPathComponent()
        )
        let persistedConfig = configByUpdatingProject(config, project: relativeProjectPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(persistedConfig)
        try data.write(to: url)
    }

    private func configByUpdatingProject(_ config: NoXcodeConfig, project: String) -> NoXcodeConfig {
        NoXcodeConfig(
            project: project,
            scheme: config.scheme,
            configuration: config.configuration,
            bundleId: config.bundleId,
            storeKitConfigurationFile: config.storeKitConfigurationFile,
            simulators: config.simulators,
            derivedDataPath: config.derivedDataPath,
            launchArguments: config.launchArguments,
            environmentVariableLines: config.environmentVariableLines
        )
    }

    private func resolveProjectPath(_ path: String, relativeTo directory: URL) -> String {
        let resolvedURL: URL
        if path.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            resolvedURL = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        }
        return resolvedURL.path
    }

    private func makeProjectPathRelativeIfPossible(_ path: String, configDirectory: URL) -> String {
        let resolvedProjectPath = resolveProjectPath(path, relativeTo: configDirectory)
        let resolvedConfigDirectory = configDirectory.standardizedFileURL.path
        let directoryPrefix = resolvedConfigDirectory.hasSuffix("/") ? resolvedConfigDirectory : resolvedConfigDirectory + "/"

        guard resolvedProjectPath.hasPrefix(directoryPrefix) else {
            return resolvedProjectPath
        }

        return String(resolvedProjectPath.dropFirst(directoryPrefix.count))
    }
}
