import SwiftUI
import NoXcodeKit
import CoreModels
import ProjectConfig
import UniformTypeIdentifiers

@main
struct NoXcodeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var projectPath: String = ""
    @State private var scheme: String = ""
    @State private var configuration: String = "Debug"
    @State private var schemes: [String] = []
    @State private var configurations: [String] = []
    @State private var bundleId: String = ""
    @State private var derivedDataPath: String = ".noxcode/DerivedData"
    @State private var commandLineArgumentsText: String = ""
    @State private var environmentVariablesText: String = ""
    @State private var devices: [SimDevice] = []
    @State private var selection = Set<String>()
    @State private var log: String = ""
    @State private var isRunning = false
    @State private var showProjectPicker = false
    @State private var configLoadStatus: String = ""
    @State private var isLoadingProjectInfo = false

    private let kit = NoXcodeKit()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Project (.xcodeproj)", text: $projectPath)
                Button("Browse…") { showProjectPicker = true }
                Picker("Scheme", selection: $scheme) {
                    ForEach(schemes, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 140)
                .disabled(schemes.isEmpty)

                Picker("Configuration", selection: $configuration) {
                    ForEach(configurations, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 120)
                .disabled(configurations.isEmpty)
            }
            if isLoadingProjectInfo {
                ProgressView("Scanning project…")
            }
            HStack(spacing: 12) {
                TextField("Bundle ID (optional)", text: $bundleId)
                TextField("DerivedData Path", text: $derivedDataPath)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command Line Arguments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $commandLineArgumentsText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 52)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Environment Variables (KEY=VALUE, one per line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $environmentVariablesText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 52)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            }
            if !configLoadStatus.isEmpty {
                Text(configLoadStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Simulators")
                Spacer()
                Button("Refresh") { Task { await refreshDevices() } }
            }

            List(devices) { device in
                Toggle(isOn: binding(for: device)) {
                    HStack {
                        Text(device.name)
                        Spacer()
                        Text(device.osDisplayName)
                        Text(device.state.rawValue)
                        Text(device.udid).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 200)

            HStack {
                Button("Save Config") { Task { await saveConfig() } }
                    .disabled(isRunning)
                Button("Run") { Task { await runLaunch() } }
                    .disabled(isRunning)
            }

            TextEditor(text: $log)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 120)
        }
        .padding()
        .task { await refreshDevices() }
        .onChange(of: projectPath) { _, _ in
            Task { await loadProjectInfo() }
        }
        .onChange(of: scheme) { _, _ in
            Task { await updateBundleId() }
        }
        .onChange(of: configuration) { _, _ in
            Task { await updateBundleId() }
        }
        .fileImporter(
            isPresented: $showProjectPicker,
            allowedContentTypes: [.package],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if url.pathExtension == "xcodeproj" {
                    projectPath = url.path
                } else {
                    appendLog("Selected item is not an .xcodeproj: \(url.lastPathComponent)")
                }
            case .failure(let error):
                appendLog("Failed to select project: \(error)")
            }
        }
    }

    private func refreshDevices() async {
        do {
            devices = try await kit.listSimulators()
        } catch {
            appendLog("Failed to list simulators: \(error)")
        }
    }

    private func saveConfig() async {
        do {
            let selections = devices.compactMap { device -> SimulatorSelection? in
                guard selection.contains(device.udid), let platform = device.platform else { return nil }
                return SimulatorSelection(udid: device.udid, platform: platform)
            }
            let config = NoXcodeConfig(
                project: projectPath,
                scheme: scheme,
                configuration: configuration,
                bundleId: bundleId.isEmpty ? nil : bundleId,
                simulators: selections,
                derivedDataPath: derivedDataPath,
                launchArguments: parseCommandLineArguments(commandLineArgumentsText),
                environmentVariables: parseEnvironmentVariables(environmentVariablesText)
            )
            try kit.writeConfig(config, projectPath: projectPath)
            appendLog("Saved .noxcode.json")
        } catch {
            appendLog("Failed to save config: \(error)")
        }
    }

    private func runLaunch() async {
        isRunning = true
        defer { isRunning = false }
        do {
            let config = try kit.readConfig(projectPath: projectPath)
            try await kit.run(config: config, logger: ViewLogger(append: appendLog(_:)))
        } catch {
            appendLog("Run failed: \(error)")
        }
    }

    private func appendLog(_ message: String) {
        log.append(message)
        log.append("\n")
    }

    private func loadProjectInfo() async {
        guard !projectPath.isEmpty else { return }
        await MainActor.run {
            isLoadingProjectInfo = true
            appendLog("Scanning project for schemes and configurations…")
        }
        do {
            let info = try await kit.listProjectInfo(projectPath: projectPath)
            schemes = info.schemes.sorted()
            configurations = info.configurations.sorted()
            if let config = try? kit.readConfig(projectPath: projectPath) {
                applyConfig(config)
                configLoadStatus = "Loaded .noxcode.json"
            } else {
                configLoadStatus = "No .noxcode.json found"
            }
            if scheme.isEmpty || !schemes.contains(scheme) {
                scheme = schemes.first ?? ""
            }
            if configuration.isEmpty || !configurations.contains(configuration) {
                configuration = configurations.first ?? ""
            }
            await updateBundleId()
        } catch {
            appendLog("Failed to read project info: \(error)")
        }
        await MainActor.run {
            isLoadingProjectInfo = false
        }
    }

    private func applyConfig(_ config: NoXcodeConfig) {
        bundleId = config.bundleId ?? ""
        derivedDataPath = config.derivedDataPath ?? ".noxcode/DerivedData"
        commandLineArgumentsText = config.launchArguments.joined(separator: " ")
        environmentVariablesText = config.environmentVariables
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        selection = Set(config.simulators.map { $0.udid })
        if schemes.contains(config.scheme) {
            scheme = config.scheme
        }
        if configurations.contains(config.configuration) {
            configuration = config.configuration
        }
    }

    private func updateBundleId() async {
        guard !projectPath.isEmpty, !scheme.isEmpty, !configuration.isEmpty else { return }
        do {
            if let value = try await kit.fetchBundleIdentifier(
                projectPath: projectPath,
                scheme: scheme,
                configuration: configuration
            ) {
                bundleId = value
            } else {
                bundleId = ""
            }
        } catch {
            appendLog("Failed to read bundle ID: \(error)")
        }
    }

    private func binding(for device: SimDevice) -> Binding<Bool> {
        Binding(
            get: { selection.contains(device.udid) },
            set: { isSelected in
                if isSelected {
                    selection.insert(device.udid)
                } else {
                    selection.remove(device.udid)
                }
            }
        )
    }

    private func parseCommandLineArguments(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func parseEnvironmentVariables(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}

private struct ViewLogger: RunLogger {
    let append: @Sendable (String) -> Void
    func log(_ event: RunEvent) { append(event.message) }
}

