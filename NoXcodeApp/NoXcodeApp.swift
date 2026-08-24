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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Project (.xcodeproj)", text: $model.projectPath)
                Button("Browse…") { showProjectPicker = true }
                Text("Scheme")
                    .foregroundStyle(.secondary)
                Menu(scheme.isEmpty ? "Select" : scheme) {
                    ForEach(schemes, id: \.self) { value in
                        Button(value) {
                            scheme = value
                        }
                    }
                }
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
                Text(bundleId.isEmpty ? "Bundle ID" : bundleId)
                    .foregroundStyle(bundleId.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)
                    .help(bundleId.isEmpty ? "Bundle ID" : bundleId)
                Picker("StoreKit", selection: $selectedStoreKitConfigurationFile) {
                    Text("None").tag("")
                    ForEach(storeKitFiles, id: \.self) { file in
                        Text(file).tag(file)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 220)
                Text("Derived Data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Path", text: $derivedDataPath)
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
                Button("Run") { Task { await runLaunch(rerun: false) } }
                    .disabled(isRunning)
                Button("Rerun") { Task { await runLaunch(rerun: true) } }
                    .disabled(isRunning)
            }

            LogTextView(text: $log)
                .frame(minHeight: 120)
        }
        .padding()
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

private struct LogTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
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

