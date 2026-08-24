import SwiftUI
import AppKit
import NoXcodeKit
import CoreModels
import ProjectConfig
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var projectPath: String = ""
    var openMessage: String?
    /// Bumped on every successful open so analysis re-runs even if the path is unchanged.
    private(set) var projectLoadToken: UInt = 0

    func openProject(at url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let resolved = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            openMessage = "Path does not exist: \(resolved.path)"
            return
        }

        guard let projectURL = resolveXcodeProject(from: resolved, isDirectory: isDirectory.boolValue) else {
            return
        }

        projectPath = projectURL.path
        NSDocumentController.shared.noteNewRecentDocumentURL(projectURL)
        projectLoadToken &+= 1
        openMessage = nil
    }

    /// Accepts an `.xcodeproj` package, or a folder that contains exactly one.
    private func resolveXcodeProject(from url: URL, isDirectory: Bool) -> URL? {
        if url.pathExtension == "xcodeproj" {
            return url
        }

        guard isDirectory else {
            openMessage = "Not an .xcodeproj: \(url.lastPathComponent)"
            return nil
        }

        do {
            let relativePath = try ConfigStore().resolveProjectPath(in: url, explicitPath: nil)
            return url.appendingPathComponent(relativePath)
        } catch ConfigStoreError.projectNotFound {
            openMessage = "No .xcodeproj found in \(url.path)"
            return nil
        } catch ConfigStoreError.multipleProjects(let projects) {
            openMessage = "Multiple .xcodeproj found in \(url.lastPathComponent): \(projects.joined(separator: ", "))"
            return nil
        } catch {
            openMessage = "Unable to look for .xcodeproj in \(url.path): \(error.localizedDescription)"
            return nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let projectURL = urls.first(where: { $0.pathExtension == "xcodeproj" }) ?? urls.first
            guard let projectURL else { return }
            AppModel.shared.openProject(at: projectURL)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { @MainActor in
            AppModel.shared.openProject(at: URL(fileURLWithPath: filename))
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Task { @MainActor in
            if let first = filenames.first {
                AppModel.shared.openProject(at: URL(fileURLWithPath: first))
                NSApp.activate(ignoringOtherApps: true)
            }
            sender.reply(toOpenOrPrint: .success)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = Array(CommandLine.arguments.dropFirst())
        let projectArg = args.first(where: { ($0 as NSString).pathExtension == "xcodeproj" })
            ?? args.first(where: Self.isExistingDirectory)
        guard let path = projectArg else { return }
        Task { @MainActor in
            AppModel.shared.openProject(at: URL(fileURLWithPath: path))
        }
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

@main
struct NoXcodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // Route file-open events to AppDelegate instead of spawning windows.
                .handlesExternalEvents(preferring: [], allowing: [])
                .onOpenURL { url in
                    model.openProject(at: url)
                }
        }
        .handlesExternalEvents(matching: [])
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
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

    private var projectPath: String {
        get { model.projectPath }
        nonmutating set { model.projectPath = newValue }
    }

    private let kit = NoXcodeKit()

    var body: some View {
        ZStack {
            LCARSTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                lcarsPanel(title: "Project Routing", accent: LCARSTheme.accentOrange) {
                    HStack(spacing: 10) {
                        TextField("Project (.xcodeproj)", text: $model.projectPath)
                            .lcarsField()
                        Button("Browse") { showProjectPicker = true }
                            .buttonStyle(LCARSButtonStyle(accent: LCARSTheme.accentGold, textColor: LCARSTheme.textDark))
                        Menu {
                            ForEach(schemes, id: \.self) { value in
                                Button(value) {
                                    scheme = value
                                }
                            }
                        } label: {
                            lcarsMenuLabel(scheme.isEmpty ? "Scheme" : scheme, isPlaceholder: scheme.isEmpty)
                        }
                        .lcarsMenuTrigger(isDimmed: schemes.isEmpty)
                        .frame(minWidth: 200)
                        .disabled(schemes.isEmpty)
                        .lcarsControl(isDimmed: schemes.isEmpty)

                        Menu {
                            ForEach(configurations, id: \.self) { value in
                                Button(value) {
                                    configuration = value
                                }
                            }
                        } label: {
                            lcarsMenuLabel(
                                configuration.isEmpty ? "Configuration" : configuration,
                                isPlaceholder: configuration.isEmpty
                            )
                        }
                        .lcarsMenuTrigger(isDimmed: configurations.isEmpty)
                        .frame(minWidth: 180)
                        .disabled(configurations.isEmpty)
                        .lcarsControl(isDimmed: configurations.isEmpty)
                    }
                }

                if isLoadingProjectInfo {
                    HStack(spacing: 10) {
                        LCARSSpinner()
                        Text("Scanning project for commands and build configurations…")
                            .font(.caption)
                            .foregroundStyle(LCARSTheme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                }

                lcarsPanel(title: "Launch Context", accent: LCARSTheme.accentPurple) {
                    HStack(spacing: 10) {
                        labeledValue(title: "Bundle ID", value: bundleId.isEmpty ? "Unavailable" : bundleId)
                        Menu {
                            Button("None") {
                                selectedStoreKitConfigurationFile = ""
                            }
                            ForEach(storeKitFiles, id: \.self) { file in
                                Button(file) {
                                    selectedStoreKitConfigurationFile = file
                                }
                            }
                        } label: {
                            let selectedValue = selectedStoreKitConfigurationFile.isEmpty ? "None" : selectedStoreKitConfigurationFile
                            lcarsMenuLabel(selectedValue, isPlaceholder: selectedStoreKitConfigurationFile.isEmpty)
                        }
                        .lcarsMenuTrigger()
                        .frame(minWidth: 240)
                        .lcarsControl()
                        Text("Derived Data")
                            .font(.caption)
                            .foregroundStyle(LCARSTheme.textSecondary)
                        TextField("Path", text: $derivedDataPath)
                            .lcarsField()
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Command Line Arguments")
                                .font(.caption)
                                .foregroundStyle(LCARSTheme.textSecondary)
                            TextEditor(text: $commandLineArgumentsText)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minHeight: 56)
                                .lcarsEditor()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Environment Variables (KEY=VALUE, one per line; # and // comments are ignored at launch)")
                                .font(.caption)
                                .foregroundStyle(LCARSTheme.textSecondary)
                            TextEditor(text: $environmentVariablesText)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minHeight: 56)
                                .lcarsEditor()
                        }
                    }
                }

                if !configLoadStatus.isEmpty {
                    Text(configLoadStatus)
                        .font(.caption)
                        .foregroundStyle(LCARSTheme.textSecondary)
                        .padding(.horizontal, 12)
                }

                lcarsPanel(title: "Destination Matrix", accent: LCARSTheme.accentBlue) {
                    HStack {
                        Text("Select simulators and physical devices")
                            .font(.caption)
                            .foregroundStyle(LCARSTheme.textSecondary)
                        Spacer()
                        Button("Refresh") { Task { await refreshDestinations() } }
                            .buttonStyle(LCARSButtonStyle(accent: LCARSTheme.accentBlue, textColor: LCARSTheme.textDark))
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Simulators")
                                .font(.headline)
                                .foregroundStyle(LCARSTheme.textPrimary)
                            List(simulators) { simulator in
                                Toggle(isOn: simulatorBinding(for: simulator)) {
                                    simulatorRow(for: simulator)
                                }
                                .toggleStyle(.checkbox)
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(LCARSTheme.controlBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(LCARSTheme.controlBorder, lineWidth: 1)
                            )
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Physical Devices")
                                .font(.headline)
                                .foregroundStyle(LCARSTheme.textPrimary)
                            List(physicalDevices) { device in
                                Toggle(isOn: physicalDeviceBinding(for: device)) {
                                    physicalDeviceRow(for: device)
                                }
                                .toggleStyle(.checkbox)
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(LCARSTheme.controlBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(LCARSTheme.controlBorder, lineWidth: 1)
                            )
                        }
                    }
                    .frame(minHeight: 210)
                }

                HStack(spacing: 10) {
                    Button("Save Config") { Task { await saveConfig() } }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(LCARSButtonStyle(accent: LCARSTheme.accentTeal, textColor: LCARSTheme.textDark))
                        .disabled(isRunning)
                    Button("Run") { Task { await runLaunch(rerun: false) } }
                        .buttonStyle(LCARSButtonStyle(accent: LCARSTheme.accentOrange, textColor: LCARSTheme.textDark))
                        .disabled(isRunning)
                    Button("Rerun") { Task { await runLaunch(rerun: true) } }
                        .buttonStyle(LCARSButtonStyle(accent: LCARSTheme.accentPurple, textColor: .white))
                        .disabled(isRunning)
                }

                lcarsPanel(title: "Operations Log", accent: LCARSTheme.accentTeal) {
                    LogTextView(text: $log)
                        .frame(minHeight: 120)
                }
            }
            .padding(14)
            .foregroundStyle(LCARSTheme.textPrimary)
        }
        .task { await refreshDestinations() }
        // Prefer task(id:) over onChange so a path set during launch (before the view
        // appears) still triggers scheme/configuration scanning.
        .task(id: "\(model.projectLoadToken)\n\(model.projectPath)") {
            guard !model.projectPath.isEmpty else { return }
            await loadProjectInfo()
        }
        // When users switch schemes, align configuration with the scheme's
        // LaunchAction default from the .xcscheme file.
        .task(id: "\(model.projectPath)\n\(scheme)") {
            applySchemeLaunchConfigurationIfNeeded()
        }
        // Prefer task(id:) over onChange so picker-driven scheme/configuration
        // changes always refresh the displayed bundle ID, including cancelling
        // an in-flight lookup for the previous selection.
        .task(id: "\(model.projectPath)\n\(scheme)\n\(configuration)") {
            await updateBundleId()
        }
        .onChange(of: model.openMessage) { _, message in
            guard let message else { return }
            appendLog(message)
            model.openMessage = nil
        }
        .fileImporter(
            isPresented: $showProjectPicker,
            allowedContentTypes: [.package],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.openProject(at: url)
            case .failure(let error):
                appendLog("Failed to select project: \(error)")
            }
        }
    }

    private func lcarsPanel<Content: View>(
        title: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accent)
                    .frame(width: 56, height: 12)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(LCARSTheme.textSecondary)
                Rectangle()
                    .fill(accent.opacity(0.45))
                    .frame(height: 1)
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LCARSTheme.panelBackground.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(LCARSTheme.panelBorder, lineWidth: 1)
                )
        )
    }

    private func labeledValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(LCARSTheme.textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LCARSTheme.textPrimary)
                .lineLimit(1)
                .textSelection(.enabled)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LCARSTheme.controlBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(LCARSTheme.controlBorder, lineWidth: 1)
                        )
                )
                .help(value)
        }
        .frame(maxWidth: 280, alignment: .leading)
    }

    private func lcarsMenuLabel(_ title: String, isPlaceholder: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isPlaceholder ? LCARSTheme.textSecondary : LCARSTheme.textPrimary)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LCARSTheme.textSecondary)
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

    private func currentConfig() -> NoXcodeConfig {
        let simulatorSelections = simulators.compactMap { device -> SimulatorSelection? in
            guard selectedSimulators.contains(device.udid), let platform = device.platform else { return nil }
            return SimulatorSelection(udid: device.udid, platform: platform)
        }
        let physicalSelections = physicalDevices.compactMap { device -> PhysicalDeviceSelection? in
            guard selectedPhysicalDevices.contains(device.identifier) else { return nil }
            return PhysicalDeviceSelection(identifier: device.identifier, platform: device.platform)
        }
        return NoXcodeConfig(
            project: projectPath,
            scheme: scheme,
            configuration: configuration,
            storeKitConfigurationFile: selectedStoreKitConfigurationFile.isEmpty ? nil : selectedStoreKitConfigurationFile,
            simulators: simulatorSelections,
            physicalDevices: physicalSelections,
            derivedDataPath: derivedDataPath,
            launchArguments: parseCommandLineArguments(commandLineArgumentsText),
            environmentVariableLines: parseEnvironmentVariableLines(environmentVariablesText)
        )
    }

    @discardableResult
    private func saveConfig() async -> Bool {
        do {
            try kit.writeConfig(currentConfig(), projectPath: projectPath)
            appendLog("Saved .noxcode.json")
            return true
        } catch {
            appendLog("Failed to save config: \(error)")
            return false
        }
    }

    private func runLaunch(rerun: Bool) async {
        log = ""
        isRunning = true
        defer { isRunning = false }
        if !rerun {
            guard await saveConfig() else { return }
        }
        do {
            let config = try kit.readConfig(projectPath: projectPath)
            let workingDirectory = URL(fileURLWithPath: config.project).deletingLastPathComponent()
            try await kit.run(
                config: config,
                workingDirectory: workingDirectory,
                rerun: rerun,
                logger: ViewLogger(append: appendLog(_:))
            )
        } catch {
            let action = rerun ? "Rerun" : "Run"
            appendLog("\(action) failed: \(error)")
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
            applySchemeLaunchConfigurationIfNeeded()
        } catch {
            appendLog("Failed to read project info: \(error)")
        }
        await MainActor.run {
            isLoadingProjectInfo = false
        }
    }

    private func applyConfig(_ config: NoXcodeConfig) {
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
        guard !projectPath.isEmpty, !scheme.isEmpty, !configuration.isEmpty else {
            bundleId = ""
            return
        }

        let requestedProject = projectPath
        let requestedScheme = scheme
        let requestedConfiguration = configuration
        bundleId = ""
        do {
            let value = try await kit.fetchBundleIdentifier(
                projectPath: requestedProject,
                scheme: requestedScheme,
                configuration: requestedConfiguration
            ) ?? ""
            guard projectPath == requestedProject,
                  scheme == requestedScheme,
                  configuration == requestedConfiguration else { return }
            bundleId = value
        } catch is CancellationError {
            return
        } catch {
            guard projectPath == requestedProject,
                  scheme == requestedScheme,
                  configuration == requestedConfiguration else { return }
            bundleId = ""
            appendLog("Failed to read bundle ID: \(error)")
        }
    }

    private func applySchemeLaunchConfigurationIfNeeded() {
        guard !projectPath.isEmpty, !scheme.isEmpty else { return }
        do {
            guard let preferred = try kit.fetchLaunchConfiguration(
                projectPath: projectPath,
                scheme: scheme
            ) else { return }
            guard configurations.contains(preferred) else { return }
            guard configuration != preferred else { return }
            configuration = preferred
            appendLog("Using \(preferred) for scheme \(scheme).")
        } catch {
            appendLog("Failed to read launch configuration for \(scheme): \(error)")
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
                .foregroundStyle(LCARSTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DestinationColumn.simulatorNameWidth, alignment: .leading)
            Text(simulator.osDisplayName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LCARSTheme.textSecondary)
                .frame(width: DestinationColumn.osWidth, alignment: .leading)
            Text(simulator.state.rawValue)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LCARSTheme.textSecondary)
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
                .foregroundStyle(LCARSTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DestinationColumn.deviceNameWidth, alignment: .leading)
            Text(device.osDisplayName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LCARSTheme.textSecondary)
                .frame(width: DestinationColumn.osWidth, alignment: .leading)
            Text(device.state)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LCARSTheme.textSecondary)
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

private enum LCARSTheme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.14, green: 0.11, blue: 0.22),
            Color(red: 0.08, green: 0.07, blue: 0.14)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let panelBackground = Color(red: 0.19, green: 0.16, blue: 0.30)
    static let panelBorder = Color(red: 0.99, green: 0.67, blue: 0.37).opacity(0.55)
    static let controlBackground = Color(red: 0.25, green: 0.22, blue: 0.37)
    static let controlBorder = Color(red: 0.98, green: 0.75, blue: 0.48).opacity(0.6)
    static let textPrimary = Color(red: 0.99, green: 0.97, blue: 0.92)
    static let textSecondary = Color(red: 0.89, green: 0.83, blue: 0.73)
    static let textDark = Color(red: 0.13, green: 0.10, blue: 0.08)
    static let accentOrange = Color(red: 0.97, green: 0.54, blue: 0.26)
    static let accentGold = Color(red: 0.96, green: 0.74, blue: 0.34)
    static let accentPurple = Color(red: 0.62, green: 0.45, blue: 0.90)
    static let accentBlue = Color(red: 0.42, green: 0.72, blue: 0.95)
    static let accentTeal = Color(red: 0.36, green: 0.86, blue: 0.82)
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

private struct LogTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = NSColor(
            red: 0.98,
            green: 0.96,
            blue: 0.91,
            alpha: 1
        )
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard textView.string != text else { return }

        let wasAtBottom = isAtBottom(scrollView)
        textView.string = text

        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visibleRect = scrollView.contentView.bounds
        let distanceFromBottom = documentView.frame.maxY - visibleRect.maxY
        return distanceFromBottom <= 2
    }
}

private struct LCARSSpinner: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 1)
            .stroke(
                AngularGradient(
                    colors: [
                        LCARSTheme.accentGold.opacity(0.25),
                        LCARSTheme.accentGold,
                        LCARSTheme.accentOrange
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.7, lineCap: .round)
            )
            .frame(width: 15, height: 15)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                rotation = 360
            }
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotation)
            .accessibilityLabel("Loading")
    }
}

private struct LCARSButtonStyle: ButtonStyle {
    let accent: Color
    let textColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(textColor.opacity(configuration.isPressed ? 0.85 : 1))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}

private extension View {
    func lcarsField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(LCARSTheme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LCARSTheme.controlBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(LCARSTheme.controlBorder, lineWidth: 1)
                    )
            )
    }

    func lcarsControl(isDimmed: Bool = false) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(isDimmed ? LCARSTheme.textSecondary : LCARSTheme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LCARSTheme.controlBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(LCARSTheme.controlBorder, lineWidth: 1)
                    )
            )
    }

    func lcarsEditor() -> some View {
        scrollContentBackground(.hidden)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LCARSTheme.controlBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(LCARSTheme.controlBorder, lineWidth: 1)
                    )
            )
            .foregroundStyle(LCARSTheme.textPrimary)
    }

    func lcarsMenuTrigger(isDimmed: Bool = false) -> some View {
        buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .opacity(isDimmed ? 0.72 : 1)
    }
}

