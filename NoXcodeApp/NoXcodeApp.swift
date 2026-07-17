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
    @State private var storeKitFiles: [String] = []
    @State private var selectedStoreKitConfigurationFile: String = ""
    @State private var derivedDataPath: String = ".noxcode/DerivedData"
    @State private var commandLineArgumentsText: String = ""
    @State private var environmentVariablesText: String = ""
    @State private var simulators: [SimDevice] = []
    @State private var physicalDevices: [PhysicalDevice] = []
    @State private var selectedSimulators = Set<String>()
    @State private var selectedPhysicalDevices = Set<String>()
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
                Picker("StoreKit", selection: $selectedStoreKitConfigurationFile) {
                    Text("None").tag("")
                    ForEach(storeKitFiles, id: \.self) { file in
                        Text(file).tag(file)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 220)
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
                    Text("Environment Variables (KEY=VALUE, one per line; # and // comments are ignored at launch)")
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
                Text("Destinations")
                Spacer()
                Button("Refresh") { Task { await refreshDestinations() } }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Simulators")
                        .font(.headline)
                    List(simulators) { simulator in
                        Toggle(isOn: simulatorBinding(for: simulator)) {
                            simulatorRow(for: simulator)
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Physical Devices")
                        .font(.headline)
                    List(physicalDevices) { device in
                        Toggle(isOn: physicalDeviceBinding(for: device)) {
                            physicalDeviceRow(for: device)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(minHeight: 200)

            HStack {
                Button("Save Config") { Task { await saveConfig() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(isRunning)
                Button("Run") { Task { await runLaunch() } }
                    .disabled(isRunning)
            }

            TextEditor(text: $log)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 120)
        }
        .padding()
        .task { await refreshDestinations() }
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

    private func refreshDestinations() async {
        do {
            simulators = sortSimulators(try await kit.listSimulators())
            let simulatorIDs = Set(simulators.map(\.udid))
            selectedSimulators = selectedSimulators.filter { simulatorIDs.contains($0) }
        } catch {
            appendLog("Failed to list simulators: \(error)")
        }

        do {
            physicalDevices = try await kit.listPhysicalDevices()
            let physicalIDs = Set(physicalDevices.map(\.identifier))
            selectedPhysicalDevices = selectedPhysicalDevices.filter { physicalIDs.contains($0) }
        } catch {
            appendLog("Failed to list physical devices: \(error)")
        }
    }

    private func saveConfig() async {
        do {
            let simulatorSelections = simulators.compactMap { device -> SimulatorSelection? in
                guard selectedSimulators.contains(device.udid), let platform = device.platform else { return nil }
                return SimulatorSelection(udid: device.udid, platform: platform)
            }
            let physicalSelections = physicalDevices.compactMap { device -> PhysicalDeviceSelection? in
                guard selectedPhysicalDevices.contains(device.identifier) else { return nil }
                return PhysicalDeviceSelection(identifier: device.identifier, platform: device.platform)
            }
            let config = NoXcodeConfig(
                project: projectPath,
                scheme: scheme,
                configuration: configuration,
                bundleId: bundleId.isEmpty ? nil : bundleId,
                storeKitConfigurationFile: selectedStoreKitConfigurationFile.isEmpty ? nil : selectedStoreKitConfigurationFile,
                simulators: simulatorSelections,
                physicalDevices: physicalSelections,
                derivedDataPath: derivedDataPath,
                launchArguments: parseCommandLineArguments(commandLineArgumentsText),
                environmentVariableLines: parseEnvironmentVariableLines(environmentVariablesText)
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
            storeKitFiles = try kit.listStoreKitConfigurationFiles(projectPath: projectPath)
            if let config = try? kit.readConfig(projectPath: projectPath) {
                applyConfig(config)
                configLoadStatus = "Loaded .noxcode.json"
            } else {
                configLoadStatus = "No .noxcode.json found"
                selectedStoreKitConfigurationFile = ""
            }
            normalizeStoreKitSelection()
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
        selectedStoreKitConfigurationFile = config.storeKitConfigurationFile ?? ""
        derivedDataPath = config.derivedDataPath ?? ".noxcode/DerivedData"
        commandLineArgumentsText = config.launchArguments.joined(separator: " ")
        environmentVariablesText = config.environmentVariableLines.joined(separator: "\n")
        selectedSimulators = Set(config.simulators.map { $0.udid })
        selectedPhysicalDevices = Set(config.physicalDevices.map { $0.identifier })
        if schemes.contains(config.scheme) {
            scheme = config.scheme
        }
        if configurations.contains(config.configuration) {
            configuration = config.configuration
        }
        normalizeStoreKitSelection()
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

    private func simulatorBinding(for device: SimDevice) -> Binding<Bool> {
        Binding(
            get: { selectedSimulators.contains(device.udid) },
            set: { isSelected in
                if isSelected {
                    selectedSimulators.insert(device.udid)
                } else {
                    selectedSimulators.remove(device.udid)
                }
            }
        )
    }

    private func physicalDeviceBinding(for device: PhysicalDevice) -> Binding<Bool> {
        Binding(
            get: { selectedPhysicalDevices.contains(device.identifier) },
            set: { isSelected in
                if isSelected {
                    selectedPhysicalDevices.insert(device.identifier)
                } else {
                    selectedPhysicalDevices.remove(device.identifier)
                }
            }
        )
    }

    private func parseCommandLineArguments(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func parseEnvironmentVariableLines(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func normalizeStoreKitSelection() {
        guard !selectedStoreKitConfigurationFile.isEmpty else { return }
        if !storeKitFiles.contains(selectedStoreKitConfigurationFile) {
            selectedStoreKitConfigurationFile = ""
        }
    }

    private func simulatorRow(for simulator: SimDevice) -> some View {
        HStack(spacing: 10) {
            Text(simulator.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DestinationColumn.simulatorNameWidth, alignment: .leading)
            Text(simulator.osDisplayName)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: DestinationColumn.osWidth, alignment: .leading)
            Text(simulator.state.rawValue)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DestinationColumn.simulatorStateWidth, alignment: .leading)
            Text(simulator.udid)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func physicalDeviceRow(for device: PhysicalDevice) -> some View {
        HStack(spacing: 10) {
            Text(device.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DestinationColumn.deviceNameWidth, alignment: .leading)
            Text(device.osDisplayName)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: DestinationColumn.osWidth, alignment: .leading)
            Text(device.state)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DestinationColumn.deviceStateWidth, alignment: .leading)
            Text(device.identifier)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sortSimulators(_ devices: [SimDevice]) -> [SimDevice] {
        devices.sorted { lhs, rhs in
            let lhsPlatformRank = platformSortRank(lhs.platform)
            let rhsPlatformRank = platformSortRank(rhs.platform)
            if lhsPlatformRank != rhsPlatformRank {
                return lhsPlatformRank < rhsPlatformRank
            }

            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }

            let versionOrder = compareVersion(lhs.osVersion, rhs.osVersion)
            if versionOrder != .orderedSame {
                return versionOrder == .orderedAscending
            }

            return lhs.udid < rhs.udid
        }
    }

    private func platformSortRank(_ platform: Platform?) -> Int {
        switch platform {
        case .iOS: return 0
        case .tvOS: return 1
        case .watchOS: return 2
        case .visionOS: return 3
        case .none: return 4
        }
    }

    private func compareVersion(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?):
            let leftComponents = versionComponents(from: left)
            let rightComponents = versionComponents(from: right)
            let count = max(leftComponents.count, rightComponents.count)
            for index in 0..<count {
                let leftValue = index < leftComponents.count ? leftComponents[index] : 0
                let rightValue = index < rightComponents.count ? rightComponents[index] : 0
                if leftValue != rightValue {
                    return leftValue < rightValue ? .orderedAscending : .orderedDescending
                }
            }
            return .orderedSame
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        case (.none, .none):
            return .orderedSame
        }
    }

    private func versionComponents(from version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

private enum DestinationColumn {
    static let simulatorNameWidth: CGFloat = 300
    static let deviceNameWidth: CGFloat = 220
    static let osWidth: CGFloat = 100
    static let simulatorStateWidth: CGFloat = 100
    static let deviceStateWidth: CGFloat = 150
}

private struct ViewLogger: RunLogger {
    let append: @MainActor @Sendable (String) -> Void

    func log(_ event: RunEvent) {
        Task { @MainActor in
            append(event.message)
        }
    }
}

