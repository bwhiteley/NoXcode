import Foundation
import CoreModels
import ProcessRunner

public struct BuildRequest: Sendable {
    public let projectPath: String
    public let scheme: String
    public let configuration: String
    public let sdk: String
    public let destinationPlatform: String
    public let derivedDataPath: String

    public init(
        projectPath: String,
        scheme: String,
        configuration: String,
        sdk: String,
        destinationPlatform: String,
        derivedDataPath: String
    ) {
        self.projectPath = projectPath
        self.scheme = scheme
        self.configuration = configuration
        self.sdk = sdk
        self.destinationPlatform = destinationPlatform
        self.derivedDataPath = derivedDataPath
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
        _ = try await runner.run(
            "/usr/bin/xcodebuild",
            [
                "-skipPackageUpdates",
                "-skipMacroValidation",
                "-skipPackagePluginValidation",
                "-project", request.projectPath,
                "-scheme", request.scheme,
                "-configuration", request.configuration,
                "-destination", "generic/platform=\(request.destinationPlatform) Simulator",
                "-derivedDataPath", request.derivedDataPath,
                "build"
            ],
            streamOutput: streamOutput
        )

        let settings = try await showBuildSettings(request)
        let appPath = (settings.targetBuildDir as NSString).appendingPathComponent(settings.wrapperName)
        return BuildResult(sdk: request.sdk, appPath: appPath)
    }

    public func showBuildSettings(_ request: BuildRequest) async throws -> BuildSettings {
        let result = try await runner.run(
            "/usr/bin/xcodebuild",
            [
                "-showBuildSettings",
                "-skipMacroValidation",
                "-skipPackagePluginValidation",
                "-project", request.projectPath,
                "-scheme", request.scheme,
                "-configuration", request.configuration,
                "-destination", "generic/platform=\(request.destinationPlatform) Simulator",
                "-derivedDataPath", request.derivedDataPath
            ]
        )
        return try parseBuildSettings(result.stdout)
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
                "-skipMacroValidation",
                "-skipPackagePluginValidation",
                "-project", projectPath,
                "-scheme", scheme,
                "-configuration", configuration
            ]
        )
        let settings = parseBuildSettingsDictionary(result.stdout)
        return settings["PRODUCT_BUNDLE_IDENTIFIER"]
    }

    private func parseBuildSettings(_ output: String) throws -> BuildSettings {
        let settings = parseBuildSettingsDictionary(output)
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
