import AppKit
import Darwin
import MacFSUAEKit
import SwiftUI
import UniformTypeIdentifiers

private struct FSUAEFocusedActions {
    let canEdit: Bool
    let canBoot: Bool
    let canStop: Bool
    let canPause: Bool
    let newConfiguration: () -> Void
    let editConfiguration: () -> Void
    let revealConfigurations: () -> Void
    let boot: () -> Void
    let stop: () -> Void
    let pause: () -> Void
    let releaseMouse: () -> Void
    let reset: (Bool) -> Void
}

private struct FSUAEFocusedActionsKey: FocusedValueKey {
    typealias Value = FSUAEFocusedActions
}

private extension FocusedValues {
    var fsuaeActions: FSUAEFocusedActions? {
        get { self[FSUAEFocusedActionsKey.self] }
        set { self[FSUAEFocusedActionsKey.self] = newValue }
    }
}

private struct FSUAECommands: Commands {
    @FocusedValue(\.fsuaeActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Configuration…") { actions?.newConfiguration() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
        }

        CommandMenu("Configuration") {
            Button("Edit Configuration…") { actions?.editConfiguration() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(actions?.canEdit != true)
            Divider()
            Button("Show Configurations in Finder") { actions?.revealConfigurations() }
                .disabled(actions == nil)
        }

        CommandMenu("Machine") {
            Button("Boot Configuration") { actions?.boot() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(actions?.canBoot != true)
            Button("Stop") { actions?.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(actions?.canStop != true)
            Divider()
            Button("Pause") { actions?.pause() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(actions?.canPause != true)
            Button("Release Mouse") { actions?.releaseMouse() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions?.canStop != true)
            Divider()
            Button("Reset") { actions?.reset(false) }
                .disabled(actions?.canStop != true)
            Button("Hard Reset") { actions?.reset(true) }
                .disabled(actions?.canStop != true)
        }
    }
}

@main
struct FSUAEMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var mcpServer = MacFSUAEMCPServer.shared

    var body: some Scene {
        WindowGroup("FS-UAE Mac") {
            if ProcessInfo.processInfo.arguments.contains("--fsuae-mac-smoke-test") {
                SmokeTestView()
            } else {
                EmulatorView()
            }
        }
        .defaultSize(width: 1080, height: 720)
        .windowToolbarStyle(.unified)
        .commands { FSUAECommands() }
        .environmentObject(mcpServer)

        Settings {
            AppSettingsView()
                .environmentObject(mcpServer)
        }
    }
}

private struct SmokeTestView: View {
    @ObservedObject private var session = MacFSUAEEngineSession.shared

    var body: some View {
        Color.black.task {
            let environment = ProcessInfo.processInfo.environment["FSUAE_MAC_SMOKE_CONFIGURATION"]
                .map(URL.init(fileURLWithPath:))
            guard let configuration = environment ?? FSUAEConfigurationLibrary().configurations.first?.url else {
                fputs("FS-UAE Mac app smoke test failed: no configuration\n", stderr)
                Darwin.exit(1)
            }
            session.start(configuration: configuration)
            for _ in 0..<200 {
                if session.frames.latest(after: 0) != nil {
                    session.stop()
                    print("FS-UAE Mac app smoke test passed")
                    fflush(stdout)
                    Darwin.exit(0)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            fputs("FS-UAE Mac app smoke test failed: \(session.status)\n", stderr)
            session.stop()
            Darwin.exit(1)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { _ = MacFSUAEMCPServer.shared }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MacFSUAEMCPServer.shared.shutdown()
            MacFSUAEEngineSession.shared.stop()
        }
    }
}

private struct EmulatorView: View {
    @EnvironmentObject private var mcpServer: MacFSUAEMCPServer
    @StateObject private var library = FSUAEConfigurationLibrary.shared
    @State private var selectedID: URL?
    @State private var editingConfiguration: FSUAEConfiguration?
    @State private var importingFloppy = false
    @State private var importingFloppyDrive = 0
    @State private var showingConfigurationInfo = false
    @State private var operationError: String?

    private var selected: FSUAEConfiguration? {
        library.configurations.first { $0.url == selectedID }
    }

    private var selectedMachine: MacFSUAERunningMachine? {
        selected.flatMap { mcpServer.presentedMachine(configuration: $0.name) }
    }

    private var canEditSelected: Bool {
        selected != nil && selectedMachine == nil
    }

    private var canBootSelected: Bool {
        selected != nil && selectedMachine == nil
    }

    var body: some View {
        NavigationSplitView {
            configurationSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if selectedMachine != nil {
                    runningDisplay
                } else {
                    configurationDetail
                }
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle(selected?.name ?? "FS-UAE Mac")
        .toolbar { mainToolbar }
        .fileImporter(isPresented: $importingFloppy, allowedContentTypes: [.data]) { result in
            guard let url = try? result.get() else { return }
            guard let machine = selectedMachine else { return }
            mcpServer.insertFloppy(url, drive: importingFloppyDrive, machineID: machine.id)
        }
        .sheet(item: $editingConfiguration) { configuration in
            ConfigurationEditor(configuration: configuration, library: library) { url in
                selectedID = url
            }
        }
        .focusedSceneValue(\.fsuaeActions, focusedActions)
        .alert("Machine Error", isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
                Button("OK") { operationError = nil }
            } message: {
                Text(operationError ?? "Unknown error")
            }
        .onAppear {
            ensureSelection()
            updateMachineSelection()
        }
        .onChange(of: selectedID) { _, _ in updateMachineSelection() }
        .onChange(of: mcpServer.runningMachines) { _, _ in updateMachineSelection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.reload()
            ensureSelection()
        }
    }

    private var configurationSidebar: some View {
        List(selection: $selectedID) {
            Section("Configurations") {
                ForEach(library.configurations) { configuration in
                    HStack(spacing: 8) {
                        Label(configuration.name,
                              systemImage: configuration.model.hasPrefix("CD")
                                ? "opticaldisc" : "desktopcomputer")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        let machines = mcpServer.runningMachines.filter {
                            $0.configuration == configuration.name
                        }
                        let headlessCount = machines.count { $0.presentation == "headless" }
                        if headlessCount > 0 {
                            Label("\(headlessCount)", systemImage: "terminal")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help("\(headlessCount) headless session\(headlessCount == 1 ? "" : "s")")
                        }
                        if !machines.isEmpty {
                            Circle()
                                .fill(machines.allSatisfy(\.isPaused)
                                      ? Color.orange.opacity(0.8)
                                      : Color.green.opacity(0.75))
                                .frame(width: 7, height: 7)
                                .accessibilityLabel(machines.allSatisfy(\.isPaused)
                                                    ? "Paused" : "Running")
                                .help(machines.allSatisfy(\.isPaused)
                                      ? "All sessions paused" : "Running")
                        }
                    }
                    .tag(configuration.url)
                    .help("\(configuration.name) — \(configuration.model)")
                    .contextMenu {
                        Button("Edit Configuration…") {
                            selectedID = configuration.url
                            editingConfiguration = configuration
                        }
                        .disabled(mcpServer.presentedMachine(configuration: configuration.name) != nil)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([configuration.url])
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if library.configurations.isEmpty {
                ContentUnavailableView("No Configurations",
                                       systemImage: "desktopcomputer",
                                       description: Text("Create a configuration to set up an Amiga."))
            }
        }
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { newConfiguration() } label: {
                Label("New Configuration", systemImage: "plus")
            }
            .help("New Configuration")

            Button { editSelected() } label: {
                Label("Edit Configuration", systemImage: "pencil")
            }
            .disabled(!canEditSelected)
            .help("Edit Configuration")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { selectedMachine == nil ? boot() : stop() } label: {
                Label(selectedMachine == nil ? "Boot" : "Stop",
                      systemImage: selectedMachine == nil ? "play.fill" : "stop.fill")
            }
            .disabled(selectedMachine == nil && !canBootSelected)
            .help(selectedMachine == nil ? "Boot Configuration" : "Stop")

            Button { pause() } label: {
                Label(selectedMachine?.isPaused == true ? "Resume" : "Pause",
                      systemImage: selectedMachine?.isPaused == true
                        ? "play.fill" : "pause.fill")
            }
            .disabled(selectedMachine == nil)
            .help(selectedMachine?.isPaused == true ? "Resume" : "Pause")

            Menu {
                Button("Reset") { reset() }
                Button("Hard Reset") { reset(hard: true) }
            } label: {
                Label("Reset", systemImage: "restart")
            }
            .disabled(selectedMachine == nil)
            .help("Reset")

            Button {
                importingFloppyDrive = 0
                importingFloppy = true
            } label: {
                Label("Insert Floppy", systemImage: "externaldrive.badge.plus")
            }
            .disabled(selectedMachine == nil)
            .help("Insert Floppy in DF0")
        }
    }

    private var configurationDetail: some View {
        Group {
            if let configuration = selected {
                VStack(spacing: 16) {
                    Image(systemName: configuration.model.hasPrefix("CD")
                          ? "opticaldisc" : "desktopcomputer")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(spacing: 4) {
                        Text(configuration.name)
                            .font(.title2.weight(.semibold))
                        Text(configuration.model)
                            .foregroundStyle(.secondary)
                    }
                    Text(romSummary(configuration))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(configuration.value(for: "kickstart_file") ?? "Kickstart not configured")
                    HStack(spacing: 8) {
                        Button("Edit Configuration…") { editSelected() }
                            .disabled(!canEditSelected)
                        Button("Boot") { boot() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canBootSelected)
                            .help("Boot Configuration")
                    }
                }
                .padding(24)
            } else {
                ContentUnavailableView {
                    Label("Select a Configuration", systemImage: "sidebar.left")
                } description: {
                    Text("Choose a saved Amiga configuration in the sidebar, or create a new one.")
                } actions: {
                    Button("New Configuration…") { newConfiguration() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var runningDisplay: some View {
        ZStack {
            Color.black
            if let machine = selectedMachine,
               let source = mcpServer.frameSource(for: machine.id) {
                MacFSUAEDisplayView(source: source,
                                    capturesMouse: !machine.isPaused,
                                    controls: mcpServer.inputControls(for: machine.id))
                    .id(machine.id)
            }

            if selectedMachine?.isPaused == true {
                Color.black.opacity(0.52)
                    .allowsHitTesting(false)
                Image(systemName: "pause.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .accessibilityLabel("Paused")
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    guard let machine = selectedMachine else { return }
                    mcpServer.insertFloppy(url, drive: 0, machineID: machine.id)
                }
            }
            return true
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let configuration = selected {
                Button { showingConfigurationInfo.toggle() } label: {
                    HStack(spacing: 6) {
                        Label(configuration.name, systemImage: "cpu")
                            .lineLimit(1)
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Configuration Details")
                .popover(isPresented: $showingConfigurationInfo) {
                    ConfigurationInfoPopover(configuration: configuration)
                }
            }

            Text(selectedMachine?.status.capitalized ?? "Ready")
                .foregroundStyle(.secondary)

            let headlessCount = mcpServer.runningMachines.count { $0.presentation == "headless" }
            if headlessCount > 0 {
                Text("\(headlessCount) headless")
                    .foregroundStyle(.tertiary)
            }

            if let machine = selectedMachine {
                Menu {
                    Picker("Emulation Speed", selection: Binding(
                        get: { machine.speed },
                        set: { mcpServer.setSpeed($0, for: machine.id) })) {
                        Text("1×").tag(1.0)
                        Text("2× (Muted)").tag(2.0)
                        Text("4× (Muted)").tag(4.0)
                        Text("Maximum (Muted)").tag(0.0)
                    }
                } label: {
                    Label(speedLabel(machine.speed), systemImage: "speedometer")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Emulation Speed")

                Text("Click display to control · ⌘G releases")
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let machine = selectedMachine {
                HStack(spacing: 2) {
                    ForEach(machine.drives.filter { $0.kind == .floppy }) { drive in
                        FloppyDriveIndicator(drive: drive) {
                            importingFloppyDrive = drive.index
                            importingFloppy = true
                        } onEject: {
                            mcpServer.ejectFloppy(drive.index, machineID: machine.id)
                        }
                    }
                    ForEach(machine.drives.filter { $0.kind == .hardDisk }) { drive in
                        DriveActivityIndicator(drive: drive)
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.bar)
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == 0
            ? "Maximum"
            : "\(Int(speed))×"
    }

    private var focusedActions: FSUAEFocusedActions {
        FSUAEFocusedActions(
            canEdit: canEditSelected,
            canBoot: canBootSelected,
            canStop: selectedMachine != nil,
            canPause: selectedMachine != nil,
            newConfiguration: newConfiguration,
            editConfiguration: editSelected,
            revealConfigurations: {
                NSWorkspace.shared.activateFileViewerSelecting([library.directory])
            },
            boot: boot,
            stop: stop,
            pause: pause,
            releaseMouse: { NSApp.keyWindow?.makeFirstResponder(nil) },
            reset: { reset(hard: $0) })
    }

    private func ensureSelection() {
        if selected == nil { selectedID = library.configurations.first?.url }
    }

    private func newConfiguration() {
        editingConfiguration = library.draft()
    }

    private func boot() {
        guard let selected, canBootSelected else { return }
        do {
            let machine = try mcpServer.startPresented(selected)
            mcpServer.selectPresentedMachine(machine.id)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func stop() {
        guard let machine = selectedMachine else { return }
        do { try mcpServer.stop(machine.id) }
        catch { operationError = error.localizedDescription }
    }

    private func pause() {
        guard let machine = selectedMachine else { return }
        mcpServer.pause(machine.id)
    }

    private func reset(hard: Bool = false) {
        guard let machine = selectedMachine else { return }
        mcpServer.reset(machine.id, hard: hard)
    }

    private func editSelected() {
        guard let selected, canEditSelected else { return }
        editingConfiguration = selected
    }

    private func updateMachineSelection() {
        mcpServer.selectPresentedMachine(selectedMachine?.id)
    }

    private func romSummary(_ configuration: FSUAEConfiguration) -> String {
        configuration.value(for: "kickstart_file").map { ($0 as NSString).lastPathComponent }
            ?? "Kickstart not configured"
    }
}

private struct FloppyDriveIndicator: View {
    @State private var isPresented = false
    let drive: MacFSUAEDrive
    let onLoad: () -> Void
    let onEject: () -> Void

    var body: some View {
        Button { isPresented.toggle() } label: {
            driveLabel(color: drive.isActive ? .green : .secondary.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(isPresented ? Color.secondary.opacity(0.18) : .clear,
                    in: Capsule())
        .help("Manage \(drive.name)")
        .accessibilityLabel("\(drive.name), \(drive.isActive ? "active" : "idle"), \(diskName)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Label("\(drive.name) Floppy Drive", systemImage: "externaldrive")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text(drive.mediaPath.isEmpty ? "No disk inserted" : diskName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if !drive.mediaPath.isEmpty {
                        Text(drive.mediaPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(drive.mediaPath)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Button {
                        isPresented = false
                        DispatchQueue.main.async { onLoad() }
                    } label: {
                        Label("Load Disk…", systemImage: "folder")
                    }
                    Button {
                        onEject()
                        isPresented = false
                    } label: {
                        Label("Eject", systemImage: "eject")
                    }
                    .disabled(drive.mediaPath.isEmpty)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }

    private var diskName: String {
        drive.mediaPath.isEmpty ? "Empty" : (drive.mediaPath as NSString).lastPathComponent
    }

    private func driveLabel(color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(drive.name)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct DriveActivityIndicator: View {
    let drive: MacFSUAEDrive

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(drive.isActive ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(drive.name)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .help(drive.mediaPath)
        .accessibilityLabel("\(drive.name) hard disk, \(drive.isActive ? "active" : "idle")")
    }
}

private struct ConfigurationInfoPopover: View {
    let configuration: FSUAEConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(configuration.name, systemImage: "cpu")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                detailRow("Model", configuration.model)
                detailRow("Video", configuration.value(for: "ntsc_mode") == "1" ? "NTSC" : "PAL")
                detailRow("Kickstart", fileName(for: "kickstart_file"))
                detailRow("DF0", fileName(for: "floppy_drive_0"))
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).help(value)
        }
    }

    private func fileName(for key: String) -> String {
        configuration.value(for: key).map { ($0 as NSString).lastPathComponent } ?? "Not configured"
    }
}

private enum ConfigurationEditorPane: String, CaseIterable, Identifiable {
    case machine = "Machine"
    case memory = "Memory"
    case expansion = "Expansion"
    case drives = "Drives"
    case integration = "Audio & Integration"
    case advanced = "Advanced"

    var id: Self { self }
    var systemImage: String {
        switch self {
        case .machine: "desktopcomputer"
        case .memory: "memorychip"
        case .expansion: "rectangle.stack.badge.plus"
        case .drives: "externaldrive"
        case .integration: "speaker.wave.2"
        case .advanced: "text.alignleft"
        }
    }
}

private struct ConfigurationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: FSUAEConfigurationLibrary
    @State private var draft: FSUAEConfiguration
    @State private var name: String
    @State private var pane = ConfigurationEditorPane.machine
    @State private var error: String?
    @State private var confirmingDiscard = false
    private let original: FSUAEConfiguration
    private let originalName: String
    private let isNew: Bool
    let didSave: (URL) -> Void

    init(configuration: FSUAEConfiguration, library: FSUAEConfigurationLibrary,
         didSave: @escaping (URL) -> Void) {
        self.library = library
        self.didSave = didSave
        original = configuration
        originalName = configuration.name
        isNew = !library.configurations.contains(where: { $0.url == configuration.url })
        _draft = State(initialValue: configuration)
        _name = State(initialValue: configuration.name)
    }

    private var isDirty: Bool {
        draft.text != original.text || name != originalName
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "New Configuration" : "Edit Configuration")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            Divider()

            HStack(spacing: 0) {
                List(ConfigurationEditorPane.allCases, selection: $pane) { item in
                    Label(item.rawValue, systemImage: item.systemImage)
                        .tag(item)
                }
                .listStyle(.sidebar)
                .frame(width: 190)

                Divider()
                editorDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack(spacing: 8) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { requestCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 780, minHeight: 600)
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes to this configuration will be lost.")
        }
    }

    @ViewBuilder
    private var editorDetail: some View {
        switch pane {
        case .machine: machineForm
        case .memory: memoryForm
        case .expansion: expansionForm
        case .drives: drivesForm
        case .integration: integrationForm
        case .advanced: advancedEditor
        }
    }

    private var machineForm: some View {
        Form {
            Section("Configuration") {
                TextField("Name", text: $name)
                choiceSetting("Amiga model", key: "amiga_model")
                LabeledContent("Hardware profile") {
                    Text("\(draft.modelProfile.chipset) · \(draft.modelProfile.defaultCPU) · \(draft.modelProfile.defaultFloppyCount) floppy \(draft.modelProfile.defaultFloppyCount == 1 ? "drive" : "drives")")
                        .foregroundStyle(.secondary)
                }
                choiceSetting("Video standard", key: "ntsc_mode")
            }
            Section("ROMs") {
                PathSettingRow("Kickstart", value: option("kickstart_file"))
                PathSettingRow("Extended Kickstart", value: option("kickstart_ext_file"))
            }
            Section("Processor") {
                choiceSetting("CPU", key: "cpu")
                if draft.optionChoices(for: "fpu").count > 2 {
                    choiceSetting("FPU", key: "fpu")
                }
                if draft.optionChoices(for: "mmu").count > 2 {
                    choiceSetting("MMU", key: "mmu")
                }
                if !["68000", "68010"].contains(draft.effectiveCPU) {
                    Toggle("JIT compiler", isOn: booleanOption("jit_compiler"))
                    if booleanOption("jit_compiler").wrappedValue {
                        choiceSetting("JIT memory", key: "jit_memory")
                    }
                }
                choiceSetting("Emulation accuracy", key: "accuracy")
                LabeledContent("CPU idle") {
                    Stepper(value: integerOption("cpu_idle", default: 2), in: 0...10) {
                        Text("\(integerOption("cpu_idle", default: 2).wrappedValue)")
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var memoryForm: some View {
        Form {
            Section("Chipset Memory") {
                memorySetting("Chip memory", key: "chip_memory")
                if draft.model.uppercased().hasPrefix("A500") {
                    memorySetting("Trapdoor / slow memory", key: "slow_memory")
                }
            }
            Section("Expansion Memory") {
                memorySetting("Fast memory", key: "fast_memory")
                if draft.supportsZorroIIIMemory || draft.value(for: "zorro_iii_memory") != nil {
                    memorySetting("Zorro III memory", key: "zorro_iii_memory")
                    memorySetting("Motherboard RAM", key: "motherboard_ram")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var expansionForm: some View {
        Form {
            if !draft.modelProfile.acceleratorChoices.isEmpty || draft.effectiveAccelerator != "0" {
                Section("Accelerator") {
                    choiceSetting("Board", key: "accelerator")
                    if draft.effectiveAccelerator != "0" {
                        memorySetting("Board memory", key: "accelerator_memory")
                        PathSettingRow("Board ROM", value: option("accelerator_rom"))
                        if ["blizzard-1230-iv", "blizzard-1240", "blizzard-1260"]
                            .contains(draft.effectiveAccelerator) {
                            Toggle("Blizzard SCSI Kit", isOn: booleanOption("blizzard_scsi_kit"))
                        }
                    }
                }
            }
            Section("Graphics") {
                choiceSetting("Graphics card", key: "graphics_card")
                if effectiveGraphicsCard != "none" {
                    memorySetting("Graphics memory", key: "graphics_card_memory")
                    PathSettingRow("Graphics card ROM", value: option("graphics_card_rom"))
                }
            }
            Section("Expansion Cards") {
                choiceSetting("Network card", key: "network_card")
                choiceSetting("Sound card", key: "sound_card")
            }
        }
        .formStyle(.grouped)
    }

    private var drivesForm: some View {
        Form {
            Section("Drive Hardware") {
                choiceSetting("Floppy drive count", key: "floppy_drive_count")
                choiceSetting("Floppy speed", key: "floppy_drive_speed")
                PercentageSettingRow("Drive sounds", value: integerOption("floppy_drive_volume", default: 20))
                PercentageSettingRow("Empty drive sounds", value: integerOption("floppy_drive_volume_empty", default: 0))
            }
            Section("Floppy Drives") {
                if floppyDriveCount == 0 {
                    Text("This model has no floppy drive by default.")
                        .foregroundStyle(.secondary)
                }
                ForEach(0..<floppyDriveCount, id: \.self) { drive in
                    PathSettingRow("DF\(drive)", value: option("floppy_drive_\(drive)"))
                }
            }
            Section("Hard Drives") {
                ForEach(0..<10) { drive in
                    HardDriveSettingRow(index: drive,
                        path: option("hard_drive_\(drive)"),
                        label: option("hard_drive_\(drive)_label"),
                        readOnly: booleanOption("hard_drive_\(drive)_read_only"),
                        priority: integerOption("hard_drive_\(drive)_priority", default: 0),
                        controller: option("hard_drive_\(drive)_controller"),
                        controllerChoices: draft.optionChoices(for: "hard_drive_\(drive)_controller"),
                        type: option("hard_drive_\(drive)_type"),
                        typeChoices: draft.optionChoices(for: "hard_drive_\(drive)_type"),
                        fileSystem: option("hard_drive_\(drive)_file_system"))
                }
            }
            Section("CD-ROM") {
                choiceSetting("Drive count", key: "cdrom_drive_count")
                if cdromDriveCount > 0 || draft.value(for: "cdrom_drive_0") != nil {
                    PathSettingRow("CD0", value: option("cdrom_drive_0"))
                    if !draft.modelProfile.hasBuiltInCD {
                        choiceSetting("Controller", key: "cdrom_drive_0_controller")
                    }
                    Toggle("Mechanical loading delay", isOn: booleanOption("cdrom_drive_0_delay"))
                    Toggle("Mount CDs in Workbench", isOn: booleanOption("cdfs", default: true))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var integrationForm: some View {
        Form {
            Section("Audio") {
                choiceSetting("Stereo separation", key: "stereo_separation")
            }
            Section("Amiga Integration") {
                Toggle("BSD socket library", isOn: booleanOption("bsdsocket_library"))
                Toggle("Share clipboard", isOn: booleanOption("clipboard_sharing"))
                Toggle("Save states", isOn: booleanOption("save_states", default: true))
            }
            Section("Video Compatibility") {
                Toggle("Line doubling", isOn: booleanOption("line_doubling", default: true))
                Toggle("Low resolution", isOn: booleanOption("low_resolution"))
            }
        }
        .formStyle(.grouped)
    }

    private var advancedEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Complete Configuration")
                .font(.headline)
            Text("Edit any FS-UAE 3.x option directly. Options not represented by native controls are preserved here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("FS-UAE option reference", destination: URL(string: "https://fs-uae.net/docs/options/")!)
                .font(.callout)
            TextEditor(text: $draft.text)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("FS-UAE configuration contents")
        }
        .padding(20)
    }

    private func option(_ key: String) -> Binding<String> {
        Binding(get: { draft.value(for: key) ?? "" },
                set: { draft.setValue($0.isEmpty ? nil : $0, for: key) })
    }

    private func booleanOption(_ key: String, default defaultValue: Bool = false) -> Binding<Bool> {
        Binding(get: {
            guard let value = draft.value(for: key)?.lowercased() else { return defaultValue }
            return ["1", "true", "yes"].contains(value)
        }, set: { draft.setValue($0 ? "1" : "0", for: key) })
    }

    private func integerOption(_ key: String, default defaultValue: Int) -> Binding<Int> {
        Binding(get: { Int(draft.value(for: key) ?? "") ?? defaultValue },
                set: { draft.setValue(String($0), for: key) })
    }

    private func choiceSetting(_ title: String, key: String) -> some View {
        ChoiceSettingRow(title, value: option(key), choices: draft.optionChoices(for: key))
    }

    private func memoryOption(_ key: String) -> Binding<String> {
        Binding(get: {
            let value = draft.value(for: key)
                ?? (key == "graphics_card_memory" ? draft.value(for: "graphics_memory") : nil)
                ?? ""
            return FSUAEConfiguration.canonicalMemoryValue(value, for: key) ?? value
        }, set: {
            draft.setValue($0.isEmpty ? nil : $0, for: key)
            if key == "graphics_card_memory" { draft.setValue(nil, for: "graphics_memory") }
        })
    }

    private func memorySetting(_ title: String, key: String) -> some View {
        var choices = FSUAEConfiguration.memoryChoices(for: key)
        if ["zorro_iii_memory", "motherboard_ram"].contains(key),
           !draft.supportsZorroIIIMemory {
            choices.removeAll { !$0.value.isEmpty && $0.value != "0" }
        }
        if key == "accelerator_memory" {
            choices.removeAll { Int($0.value).map { $0 > draft.maximumAcceleratorMemory } == true }
        }
        if key == "graphics_card_memory" {
            choices.removeAll { Int($0.value).map { $0 > draft.maximumGraphicsMemory } == true }
        }
        if let defaultValue = defaultMemoryValue(for: key),
           let defaultChoice = choices.first(where: { $0.value == defaultValue }) {
            choices[0] = .init("", "Model Default (\(defaultChoice.title))")
        }
        return ChoiceSettingRow(title, value: memoryOption(key), choices: choices)
    }

    private func defaultMemoryValue(for key: String) -> String? {
        switch key {
        case "chip_memory": draft.modelProfile.defaultChipMemory
        case "slow_memory": draft.modelProfile.defaultSlowMemory
        case "fast_memory", "zorro_iii_memory": "0"
        case "motherboard_ram": draft.modelProfile.defaultMotherboardRAM
        case "accelerator_memory": switch draft.effectiveAccelerator {
            case "blizzard-1230-iv", "blizzard-1240", "blizzard-1260": "32768"
            case "blizzard-ppc": "262144"
            case "cyberstorm-ppc": "131072"
            default: nil
        }
        case "graphics_card_memory": effectiveGraphicsCard.contains("z3") ? "16384" : "4096"
        default: nil
        }
    }

    private var effectiveGraphicsCard: String {
        let value = draft.value(for: "graphics_card") ?? ""
        return value.isEmpty ? draft.modelProfile.defaultGraphicsCard : value.lowercased()
    }

    private var floppyDriveCount: Int {
        let configured = Int(draft.value(for: "floppy_drive_count") ?? "")
            ?? draft.modelProfile.defaultFloppyCount
        let lastMounted = (0..<4).last(where: { !(draft.value(for: "floppy_drive_\($0)") ?? "").isEmpty })
        return min(4, max(configured, lastMounted.map { $0 + 1 } ?? 0))
    }

    private var cdromDriveCount: Int {
        Int(draft.value(for: "cdrom_drive_count") ?? "") ?? draft.modelProfile.defaultCDCount
    }

    private func requestCancel() {
        if isDirty { confirmingDiscard = true } else { dismiss() }
    }

    private func save() {
        do {
            let url = try library.save(draft, named: name)
            didSave(url)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ChoiceSettingRow: View {
    let title: String
    @Binding var value: String
    let choices: [FSUAEOptionChoice]

    init(_ title: String, value: Binding<String>, choices: [FSUAEOptionChoice]) {
        self.title = title
        _value = value
        self.choices = choices
    }

    var body: some View {
        Picker(title, selection: $value) {
            if !value.isEmpty, !choices.contains(where: { $0.value == value }) {
                Text("Invalid: \(value)").tag(value)
            }
            ForEach(choices) { choice in
                Text(choice.title).tag(choice.value)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(title)
    }
}

private struct PercentageSettingRow: View {
    let title: String
    @Binding var value: Int

    init(_ title: String, value: Binding<Int>) {
        self.title = title
        _value = value
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0) }),
                       in: 0...100, step: 5)
                    .frame(width: 160)
                Text("\(value)%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }
}

private struct HardDriveSettingRow: View {
    let index: Int
    @Binding var path: String
    @Binding var label: String
    @Binding var readOnly: Bool
    @Binding var priority: Int
    @Binding var controller: String
    let controllerChoices: [FSUAEOptionChoice]
    @Binding var type: String
    let typeChoices: [FSUAEOptionChoice]
    @Binding var fileSystem: String

    var body: some View {
        DisclosureGroup {
            PathSettingRow("Image or directory", value: $path, canChooseDirectories: true)
            if !path.isEmpty {
                TextField("Volume label", text: $label)
                Toggle("Read only", isOn: $readOnly)
                ChoiceSettingRow("Controller", value: $controller, choices: controllerChoices)
                ChoiceSettingRow("Image type", value: $type, choices: typeChoices)
                PathSettingRow("Filesystem handler", value: $fileSystem)
                LabeledContent("Boot priority") {
                    Stepper(value: $priority, in: -128...127) {
                        Text("\(priority)").monospacedDigit()
                    }
                }
            }
        } label: {
            HStack {
                Text("DH\(index)")
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                Spacer()
                Text(path.isEmpty ? "Not configured" : (path as NSString).lastPathComponent)
                    .foregroundStyle(path.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct PathSettingRow: View {
    let title: String
    @Binding var value: String
    var canChooseDirectories = false

    init(_ title: String, value: Binding<String>, canChooseDirectories: Bool = false) {
        self.title = title
        _value = value
        self.canChooseDirectories = canChooseDirectories
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(value.isEmpty ? "Not configured" : (value as NSString).lastPathComponent)
                    .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .help(value)
                Button("Choose…") { choose() }
                if !value.isEmpty {
                    Button { value = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear \(title)")
                    .help("Clear \(title)")
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(title)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
}
