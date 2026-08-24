import Foundation
import CoreModels
import ProcessRunner

public struct BuildRequest: Sendable {
    public let projectPath: String
    public let scheme: String
    public let configuration: String
    public let sdk: String
    public let destination: String
    public let derivedDataPath: String
    public let buildSettingOverrides: [String]

    public init(
        projectPath: String,
        scheme: String,
        configuration: String,
        sdk: String,
        destination: String,
        derivedDataPath: String,
        buildSettingOverrides: [String] = []
    ) {
        self.projectPath = projectPath
        self.scheme = scheme
        self.configuration = configuration
        self.sdk = sdk
        self.destination = destination
        self.derivedDataPath = derivedDataPath
        self.buildSettingOverrides = buildSettingOverrides
    }
}

public struct BuildResult: Sendable {
    public let sdk: String
    public let appPath: String
}

public final class XcodeBuildClient: Sendable {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func listProjectInfo(projectPath: String) async throws -> XcodeProjectInfo {
        let result = try await runner.run(
            "/usr/bin/xcodebuild",
            ["-list", "-json", "-project", projectPath]
        )
        let data = Data(result.stdout.utf8)
        let decoded = try JSONDecoder().decode(XcodeListResponse.self, from: data)
        let schemes = decoded.project.schemes ?? []
        let configs = decoded.project.buildConfigurations ?? decoded.project.configurations ?? []
        return XcodeProjectInfo(schemes: schemes, configurations: configs)
    }

    public func build(_ request: BuildRequest, streamOutput: ProcessRunner.OutputHandler? = nil) async throws -> BuildResult {
        var command = [
            "-skipPackageUpdates",
            "-skipMacroValidation",
            "-skipPackagePluginValidation",
            "-project", request.projectPath,
            "-scheme", request.scheme,
            "-configuration", request.configuration,
            "-sdk", request.sdk,
            "-destination", request.destination,
            "-derivedDataPath", request.derivedDataPath
        ]
        command += request.buildSettingOverrides
        command.append("build")
        _ = try await runner.run(
            "/usr/bin/xcodebuild",
            command,
            streamOutput: streamOutput
        )

        return try await resolveAppPath(request)
    }

    public func resolveAppPath(_ request: BuildRequest) async throws -> BuildResult {
        let settings = try await showBuildSettings(request)
        let appPath = (settings.targetBuildDir as NSString).appendingPathComponent(settings.wrapperName)
        return BuildResult(sdk: request.sdk, appPath: appPath)
    }

    public func showBuildSettings(_ request: BuildRequest) async throws -> BuildSettings {
        var command = [
            "-showBuildSettings",
            "-json",
            "-skipMacroValidation",
            "-skipPackagePluginValidation",
            "-project", request.projectPath,
            "-scheme", request.scheme,
            "-configuration", request.configuration,
            "-sdk", request.sdk,
            "-destination", request.destination,
            "-derivedDataPath", request.derivedDataPath
        ]
        command += request.buildSettingOverrides
        let result = try await runner.run(
            "/usr/bin/xcodebuild",
            command
        )
        return try parseBuildSettings(result.stdout, scheme: request.scheme)
    }

    public func bundleIdentifier(
        projectPath: String,
        scheme: String,
        configuration: String
    ) async throws -> String? {
        let result = try await runner.run(
            "/usr/bin/xcodebuild",
            [
                "-showBuildSettings",
                "-json",
                "-skipMacroValidation",
                "-skipPackagePluginValidation",
                "-project", projectPath,
                "-scheme", scheme,
                "-configuration", configuration
            ]
        )
        let entries = parseBuildSettingsEntries(from: result.stdout)
        if let preferred = preferredBuildSettingsEntry(scheme: scheme, entries: entries),
           let id = bundleIdentifier(from: preferred.settings) {
            return id
        }
        return parseBuildSettingsDictionary(result.stdout)["PRODUCT_BUNDLE_IDENTIFIER"]
    }

    public func launchConfiguration(projectPath: String, scheme: String) throws -> String? {
        guard let schemeURL = try resolveSchemeFileURL(projectPath: projectPath, scheme: scheme) else {
            return nil
        }
        let contents = try String(contentsOf: schemeURL)
        return parseLaunchConfiguration(fromSchemeXML: contents)
    }

    private func parseBuildSettings(_ output: String, scheme: String) throws -> BuildSettings {
        let entries = parseBuildSettingsEntries(from: output)
        let settings = preferredBuildSettingsEntry(scheme: scheme, entries: entries)?.settings
            ?? parseBuildSettingsDictionary(output)
        guard let targetBuildDir = settings["TARGET_BUILD_DIR"],
              let wrapperName = settings["WRAPPER_NAME"] else {
            throw XcodeBuildError.missingBuildSetting
        }
        return BuildSettings(targetBuildDir: targetBuildDir, wrapperName: wrapperName)
    }

    private func parseBuildSettingsDictionary(_ output: String) -> [String: String] {
        var settings: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                settings[parts[0]] = parts[1]
            }
        }
        return settings
    }

    private func parseBuildSettingsEntries(from output: String) -> [(target: String, settings: [String: String])] {
        // xcodebuild can print log lines before JSON; parse from the first '[' when present.
        guard let start = output.firstIndex(of: "[") else { return [] }
        let data = Data(output[start...].utf8)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return raw.map { item in
            let target = item["target"] as? String ?? ""
            let rawSettings = item["buildSettings"] as? [String: Any] ?? [:]
            var settings: [String: String] = [:]
            for (key, value) in rawSettings {
                if let string = value as? String {
                    settings[key] = string
                }
            }
            return (target, settings)
        }
    }

    private func preferredBuildSettingsEntry(
        scheme: String,
        entries: [(target: String, settings: [String: String])]
    ) -> (target: String, settings: [String: String])? {
        if let appTarget = entries.first(where: { $0.target == scheme && isApp($0.settings) }) {
            return appTarget
        }
        if let appTarget = entries.first(where: { isApp($0.settings) }) {
            return appTarget
        }
        if let nonTestTarget = entries.first(where: { !isTest($0.target, $0.settings) }) {
            return nonTestTarget
        }
        return entries.first
    }

    private func bundleIdentifier(from settings: [String: String]) -> String? {
        let value = settings["PRODUCT_BUNDLE_IDENTIFIER"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        return value
    }

    private func resolveSchemeFileURL(projectPath: String, scheme: String) throws -> URL? {
        let fileManager = FileManager.default
        let projectURL = URL(fileURLWithPath: projectPath)
        let sharedURL = projectURL
            .appendingPathComponent("xcshareddata")
            .appendingPathComponent("xcschemes")
            .appendingPathComponent("\(scheme).xcscheme")
        if fileManager.fileExists(atPath: sharedURL.path) {
            return sharedURL
        }

        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "xcscheme" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if name == scheme {
                return url
            }
        }
        return nil
    }

    private func parseLaunchConfiguration(fromSchemeXML xml: String) -> String? {
        guard let launchActionRange = xml.range(of: "<LaunchAction"),
              let tagEnd = xml[launchActionRange.lowerBound...].firstIndex(of: ">") else {
            return nil
        }
        let launchActionTag = String(xml[launchActionRange.lowerBound...tagEnd])
        let pattern = #"buildConfiguration\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(launchActionTag.startIndex..<launchActionTag.endIndex, in: launchActionTag)
        guard let match = regex.firstMatch(in: launchActionTag, range: nsRange),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: launchActionTag) else {
            return nil
        }
        return String(launchActionTag[capture])
    }

    private func isTest(_ target: String, _ settings: [String: String]) -> Bool {
        settings["WRAPPER_EXTENSION"] == "xctest"
            || target.hasSuffix("Tests")
            || target.hasSuffix("UITests")
    }

    private func isApp(_ settings: [String: String]) -> Bool {
        settings["WRAPPER_EXTENSION"] == "app"
    }
}

public struct BuildSettings: Sendable {
    public let targetBuildDir: String
    public let wrapperName: String
}

public enum XcodeBuildError: Error {
    case missingBuildSetting
}

private struct XcodeListResponse: Codable {
    let project: XcodeProject
}

private struct XcodeProject: Codable {
    let schemes: [String]?
    let buildConfigurations: [String]?
    let configurations: [String]?
}
