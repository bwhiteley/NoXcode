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
        return try JSONDecoder().decode(NoXcodeConfig.self, from: data)
    }

    public func writeConfig(_ config: NoXcodeConfig, projectPath: String) throws {
        let url = configURL(projectPath: projectPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url)
    }
}
