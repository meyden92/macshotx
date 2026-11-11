import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Binding helper

extension ConfigStore {
    /// SwiftUI binding into the config; writes persist immediately.
    func binding<T: Sendable>(_ keyPath: WritableKeyPath<AppConfig, T> & Sendable) -> Binding<T> {
        Binding(
            get: { MainActor.assumeIsolated { self.config[keyPath: keyPath] } },
            set: { value in
                MainActor.assumeIsolated { self.update { $0[keyPath: keyPath] = value } }
            }
        )
    }
}

// MARK: - Root

/// System Settings–style window: the sidebar lists `SettingsPane`s under their
/// groups, the selected pane fills the detail column. Fixed width, resizable
/// height, and it reopens on the pane that was shown last.
struct SettingsView: View {
    /// Raw value of the last-shown pane. UI state, not configuration, so it is
    /// deliberately kept out of `AppConfig` and config exports.
    @AppStorage("settings.lastPane") private var lastPane = SettingsPane.general.rawValue

    var body: some View {
        let pane = SettingsPane(storedValue: lastPane)
        NavigationSplitView {
            List(selection: Binding(
                get: { pane },
                set: { selected in if let selected { lastPane = selected.rawValue } }
            )) {
                ForEach(SettingsPane.sidebar, id: \.group) { section in
                    Section(section.group.title) {
                        ForEach(section.panes) { pane in
                            Label(pane.title, systemImage: pane.systemImage)
                                .tag(pane)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(for: pane)
                .navigationTitle(pane.title)
        }
        .frame(width: 750)
        .frame(minHeight: 500, idealHeight: 600)
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .permissions: PermissionsSettingsPane()
        case .hotkeys: HotkeysSettingsPane()
        case .pipelines: PipelinesSettingsPane()
        case .destinations: DestinationsSettingsPane()
        case .saving: SavingSettingsPane()
        case .watermark: WatermarkSettingsPane()
        case .advanced: AdvancedSettingsPane()
        }
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: store.binding(\.general.notificationsEnabled))
                Toggle(
                    "Capture feedback (sound and flash)",
                    isOn: store.binding(\.general.captureFeedbackEnabled)
                )
                Toggle(
                    "Show capture overlay hints",
                    isOn: store.binding(\.capture.showOverlayHints)
                )
                Toggle("Launch at login", isOn: Binding(
                    get: { store.config.general.launchAtLogin },
                    set: { enabled in
                        store.update { $0.general.launchAtLogin = enabled }
                        applyLaunchAtLogin(enabled)
                    }
                ))
                Picker("Color picker copies", selection: store.binding(\.general.colorFormat)) {
                    Text("Hex (#3A7BD5)").tag(ColorOutputFormat.hex)
                    Text("RGB (rgb(58, 123, 213))").tag(ColorOutputFormat.rgb)
                    Text("HSL (hsl(217, 65%, 53%))").tag(ColorOutputFormat.hsl)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(
                    "Privacy: macshot makes no network calls except uploads to "
                    + "destinations you configure. No telemetry, no analytics."
                )
            }
        }
        .formStyle(.grouped)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("Launch-at-login change failed: \(error)")
        }
    }
}

// MARK: - Permissions

/// What the app requires and whether macOS has granted it — the same list the
/// setup wizard shows, so it stays reachable after the wizard is gone.
struct PermissionsSettingsPane: View {
    var body: some View {
        Form {
            Section {
                PermissionsList()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotkeys

extension ConfigStore {
    /// Edits the hotkeys and re-registers them, so every change takes effect
    /// without a restart.
    func updateHotkeys(_ mutate: (inout HotkeySettings) -> Void) {
        update { mutate(&$0.hotkeys) }
        HotkeyManager.shared.apply(config.hotkeys)
    }
}

struct HotkeysSettingsPane: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        let hotkeys = store.config.hotkeys
        Form {
            Section {
                ForEach(hotkeys.captures) { hotkey in
                    CaptureHotkeyRow(hotkey: hotkey, store: store)
                }
                // The menu bar lists captures in this order, and re-registering
                // through updateHotkeys keeps it in step without a restart.
                .onMove { source, destination in
                    store.updateHotkeys {
                        $0.captures.move(fromOffsets: source, toOffset: destination)
                    }
                }
            } header: {
                Text("Capture")
            } footer: {
                HStack(alignment: .top) {
                    Text(
                        "Each capture hotkey opens the capture overlay and runs its pipeline. "
                        + "Click a shortcut, then press the new key combination. Esc cancels. "
                        + "Drag a row to reorder."
                    )
                    Spacer()
                    Button { add() } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add capture hotkey")
                }
            }
            Section {
                ForEach([HotkeyAction.colorPicker, .magnifier], id: \.self) { action in
                    HStack {
                        Text(hotkeys.label(for: action))
                        Spacer()
                        HotkeyRecorder(action: action, store: store)
                    }
                }
            } header: {
                Text("Utilities")
            } footer: {
                let conflicts = hotkeys.conflicts()
                if !conflicts.isEmpty {
                    Label(
                        conflicts
                            .map {
                                "\(hotkeys.label(for: $0.0)) and \(hotkeys.label(for: $0.1)) "
                                    + "share the same shortcut"
                            }
                            .joined(separator: "\n"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        var hotkey = CaptureHotkey()
        hotkey.name = "New capture"
        hotkey.pipelineID = store.config.pipelines[0].id
        store.updateHotkeys { $0.captures.append(hotkey) }
    }
}

/// One capture entry on a single row: name, shortcut, pipeline and delete.
/// Edits go by id, so a row never writes to a stale index.
struct CaptureHotkeyRow: View {
    let hotkey: CaptureHotkey
    @ObservedObject var store: ConfigStore

    var body: some View {
        let pipelines = store.config.pipelines
        let dangling = !pipelines.contains { $0.id == hotkey.pipelineID }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: Binding(
                    get: { hotkey.name },
                    set: { name in edit { $0.name = name } }
                ))
                .labelsHidden()
                HotkeyRecorder(action: .capture(hotkey.id), store: store)
                Picker("Pipeline", selection: Binding(
                    get: { hotkey.pipelineID },
                    set: { id in edit { $0.pipelineID = id } }
                )) {
                    ForEach(pipelines) { pipeline in
                        Text(pipeline.name).tag(pipeline.id)
                    }
                    if dangling {
                        Text("— deleted —").tag(hotkey.pipelineID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                Button {
                    store.updateHotkeys { $0.captures.removeAll { $0.id == hotkey.id } }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete capture hotkey")
            }
            if dangling {
                Label(
                    "Its pipeline was deleted, so it runs “\(pipelines[0].name)” instead.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    private func edit(_ mutate: (inout CaptureHotkey) -> Void) {
        store.updateHotkeys { hotkeys in
            guard let index = hotkeys.captures.firstIndex(where: { $0.id == hotkey.id })
            else { return }
            mutate(&hotkeys.captures[index])
        }
    }
}

/// Click-to-record shortcut button with a clear button beside it.
struct HotkeyRecorder: View {
    let action: HotkeyAction
    @ObservedObject var store: ConfigStore
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? "Press keys…" : currentLabel) {
                recording ? stopRecording() : startRecording()
            }
            .frame(minWidth: 110)
            Button {
                store.updateHotkeys { $0.setBinding(nil, for: action) }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.config.hotkeys.binding(for: action) == nil)
        }
        .onDisappear { stopRecording() }
    }

    private var currentLabel: String {
        store.config.hotkeys.binding(for: action)?.displayString ?? "None"
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stopRecording()
                return nil
            }
            let modifiers = HotkeyBinding.carbonModifiers(from: event.modifierFlags)
            // Require a modifier unless it's a function key.
            let isFunctionKey = (96...122).contains(event.keyCode)
            guard modifiers != 0 || isFunctionKey else { return nil }
            let binding = HotkeyBinding(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: modifiers
            )
            store.updateHotkeys { $0.setBinding(binding, for: action) }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

// MARK: - Saving

/// Where and how a capture is written: folder, format and quality, then the
/// filename template.
struct SavingSettingsPane: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Save folder", text: store.binding(\.capture.saveDirectory))
                    Button("Choose…") { chooseFolder() }
                }
                Picker("Format", selection: store.binding(\.capture.format)) {
                    Text("PNG (lossless)").tag(ImageFormat.png)
                    Text("JPEG").tag(ImageFormat.jpeg)
                    Text("HEIC").tag(ImageFormat.heic)
                }
                if store.config.capture.format != .png {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(store.config.capture.quality) },
                                set: { value in store.update { $0.capture.quality = Int(value) } }
                            ),
                            in: 1...100,
                            step: 1
                        ) {
                            Text("Quality")
                        }
                        Text("\(store.config.capture.quality)")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            Section {
                TextField("Template", text: store.binding(\.filenames.template))
                    .font(.body.monospaced())
                Stepper(
                    "Counter padding: \(store.config.filenames.counterPadding) digits",
                    value: store.binding(\.filenames.counterPadding),
                    in: 1...10
                )

                let template = store.config.filenames.template
                if FilenameTemplate.isValid(template) {
                    LabeledContent("Preview") {
                        Text(preview(of: template))
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label(
                        "Template would produce an empty filename",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Filename")
            } footer: {
                Text(
                    "%y %mo %d — date · %h %mi %s %ms — time · %counter — per-folder counter\n"
                    + "%window %app — snapped window, else the frontmost app\n"
                    + "%host %user — machine/user · %uuid — UUID · %rand:N — random characters"
                )
                .monospaced()
            }
        }
        .formStyle(.grouped)
    }

    private func preview(of template: String) -> String {
        var context = FilenameTemplate.Context()
        context.windowTitle = "Project_Plan"
        context.appName = "Safari"
        context.counter = 42
        context.counterPadding = store.config.filenames.counterPadding
        return FilenameTemplate.expand(template, context: context)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(
            fileURLWithPath: (store.config.capture.saveDirectory as NSString).expandingTildeInPath
        )
        if panel.runModal() == .OK, let url = panel.url {
            store.update { $0.capture.saveDirectory = url.path }
        }
    }
}

// MARK: - Watermark

struct WatermarkSettingsPane: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Add a watermark to every capture", isOn: store.binding(\.capture.watermark.enabled))
                // Configuring a logo is deliberately not gated on the toggle:
                // picking one first and switching it on after is the natural
                // order, and the logo survives switching it back off.
                HStack {
                    TextField("Logo image", text: store.binding(\.capture.watermark.imagePath))
                    Button("Choose…") { chooseLogo() }
                }
            }
            Section {
                // Its placement is greyed out while it is off — but never the
                // toggle that turns it back on.
                Group {
                    Picker("Position", selection: store.binding(\.capture.watermark.corner)) {
                        ForEach(WatermarkCorner.allCases, id: \.self) { corner in
                            Text(corner.label).tag(corner)
                        }
                    }
                    percentSlider("Size", \.capture.watermark.scalePercent, in: 1...100)
                    percentSlider("Margin", \.capture.watermark.marginPercent, in: 0...40)
                    percentSlider("Opacity", \.capture.watermark.opacityPercent, in: 1...100)
                    WatermarkPreview(settings: store.config.capture.watermark)
                }
                .disabled(!store.config.capture.watermark.enabled)
            } footer: {
                Text("Size and margin are percentages of the capture's width, so "
                     + "one setting looks the same on a fullscreen shot and on a "
                     + "small crop.")
            }
        }
        .formStyle(.grouped)
    }

    /// One row for each of the watermark's three percentages: slider, live
    /// value, same width.
    private func percentSlider(
        _ label: String,
        _ keyPath: WritableKeyPath<AppConfig, Int> & Sendable,
        in range: ClosedRange<Double>
    ) -> some View {
        HStack {
            Slider(
                value: Binding(
                    get: { Double(store.config[keyPath: keyPath]) },
                    set: { value in store.update { $0[keyPath: keyPath] = Int(value) } }
                ),
                in: range,
                step: 1
            ) {
                Text(label)
            }
            Text("\(store.config[keyPath: keyPath])%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .image]
        if panel.runModal() == .OK, let url = panel.url {
            store.update { $0.capture.watermark.imagePath = url.path }
        }
    }
}

// MARK: - Drill-down helpers

extension ConfigStore {
    /// Binding to one field of an entry in a config list (pipelines,
    /// destinations). The entry is looked up by id on every read and write, so
    /// a reorder or delete never makes an open editor edit a different entry.
    /// Reads fall back to `entry`'s value once it is gone.
    func binding<Entry: Identifiable & Sendable, T: Sendable>(
        _ list: WritableKeyPath<AppConfig, [Entry]> & Sendable,
        _ entry: Entry,
        _ field: WritableKeyPath<Entry, T> & Sendable
    ) -> Binding<T> where Entry.ID: Sendable {
        let id = entry.id
        let fallback = entry[keyPath: field]
        return Binding(
            get: {
                MainActor.assumeIsolated {
                    self.config[keyPath: list].first { $0.id == id }?[keyPath: field] ?? fallback
                }
            },
            set: { value in
                MainActor.assumeIsolated {
                    self.update { config in
                        guard let index = config[keyPath: list].firstIndex(where: { $0.id == id })
                        else { return }
                        config[keyPath: list][index][keyPath: field] = value
                    }
                }
            }
        )
    }

    /// Removes a pipeline unless it is the last one: there is always one to run.
    func deletePipeline(_ id: UUID) {
        guard config.pipelines.count > 1 else { return }
        update { $0.pipelines.removeAll { $0.id == id } }
    }

    /// Removes a destination together with its Keychain secrets, so no
    /// credentials are left behind.
    func deleteDestination(_ id: UUID) {
        Keychain.delete(account: Keychain.secretAccount(for: id, field: "secretKey"))
        Keychain.delete(account: Keychain.secretAccount(for: id, field: "password"))
        update { $0.destinations.removeAll { $0.id == id } }
    }
}

// MARK: - Pipelines

/// Named pipelines as rows; clicking one pushes its editor into the same
/// column. Navigation goes by id, never by index. The last pipeline cannot be
/// deleted: there is always one to run.
struct PipelinesSettingsPane: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    ForEach(store.config.pipelines) { pipeline in
                        NavigationLink(value: pipeline.id) {
                            VStack(alignment: .leading) {
                                Text(pipeline.name.isEmpty ? "(unnamed)" : pipeline.name)
                                Text(pipeline.actions.count == 1
                                    ? "1 action" : "\(pipeline.actions.count) actions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Duplicate") { duplicate(pipeline.id) }
                            Button("Delete", role: .destructive) {
                                store.deletePipeline(pipeline.id)
                            }
                            .disabled(store.config.pipelines.count <= 1)
                        }
                    }
                } footer: {
                    HStack {
                        Spacer()
                        Button { add() } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add pipeline")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationDestination(for: UUID.self) { id in
                PipelineEditor(id: id, store: store)
            }
        }
    }

    private func add() {
        var pipeline = Pipeline()
        pipeline.name = "New pipeline"
        store.update { $0.pipelines.append(pipeline) }
        path.append(pipeline.id)
    }

    private func duplicate(_ id: UUID) {
        guard let index = store.config.pipelines.firstIndex(where: { $0.id == id }) else { return }
        var copy = store.config.pipelines[index]
        copy.id = UUID()
        copy.name += " copy"
        store.update { $0.pipelines.insert(copy, at: index + 1) }
        path.append(copy.id)
    }
}

/// One pipeline's name and actions at full width. Pops back to the list once
/// the pipeline no longer exists, which is also how "Delete Pipeline" returns.
struct PipelineEditor: View {
    let id: UUID
    @ObservedObject var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let pipeline = store.config.pipelines.first(where: { $0.id == id }) {
            Form {
                Section {
                    TextField("Name", text: store.binding(\.pipelines, pipeline, \.name))
                }
                Section {
                    PipelineActionsEditor(
                        actions: store.binding(\.pipelines, pipeline, \.actions)
                    )
                } header: {
                    Text("Actions")
                } footer: {
                    Text(
                        "Actions run top to bottom. Each capture hotkey picks the "
                        + "pipeline it runs in Settings → Hotkeys. If an action fails, "
                        + "the pipeline stops and shows a notification with a Retry "
                        + "option."
                    )
                }
                Section {
                    Button("Delete Pipeline", role: .destructive) {
                        store.deletePipeline(id)
                    }
                    .disabled(store.config.pipelines.count <= 1)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pipeline.name.isEmpty ? "(unnamed)" : pipeline.name)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}

struct PipelineActionsEditor: View {
    @Binding var actions: [PipelineAction]
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(actions.indices, id: \.self) { index in
                HStack {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    actionRow(at: index)
                    Spacer()
                    Button {
                        actions.swapAt(index, index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    Button {
                        actions.swapAt(index, index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == actions.count - 1)
                    Button {
                        actions.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.borderless)
            }
            Menu("Add Action") {
                Button("Open in editor") { actions.append(.openInEditor) }
                Button("Copy image to clipboard") { actions.append(.copyImage) }
                Button("Save to disk") { actions.append(.saveToDisk) }
                Button("Upload to destination") {
                    actions.append(
                        .upload(destination: store.config.destinations.first?.name ?? "")
                    )
                }
                Button("Copy URL to clipboard") { actions.append(.copyURL) }
                Button("Run shell command") { actions.append(.runShell(command: "")) }
                Button("Open in app") { actions.append(.openInApp(bundleID: "")) }
                Button("Extract text (OCR)") { actions.append(.extractText) }
            }
            .frame(maxWidth: 180)
        }
    }

    @ViewBuilder
    private func actionRow(at index: Int) -> some View {
        switch actions[index] {
        case .openInEditor:
            Text("Open in editor")
        case .copyImage:
            Text("Copy image to clipboard")
        case .saveToDisk:
            Text("Save to disk")
        case .upload(let destination):
            Text("Upload to")
            Picker("", selection: Binding(
                get: { destination },
                set: { actions[index] = .upload(destination: $0) }
            )) {
                ForEach(store.config.destinations) { dest in
                    Text(dest.name).tag(dest.name)
                }
                if !store.config.destinations.contains(where: { $0.name == destination }) {
                    Text(destination.isEmpty ? "— none —" : destination).tag(destination)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
        case .copyURL:
            Text("Copy URL to clipboard")
        case .runShell(let command):
            Text("Shell")
            TextField("command ($1 = file, $2 = URL)", text: Binding(
                get: { command },
                set: { actions[index] = .runShell(command: $0) }
            ))
            .font(.body.monospaced())
        case .openInApp(let bundleID):
            Text("Open in app")
            TextField("bundle ID (e.g. com.apple.Preview)", text: Binding(
                get: { bundleID },
                set: { actions[index] = .openInApp(bundleID: $0) }
            ))
        case .extractText:
            Text("Extract text (OCR) to clipboard")
        }
    }
}

// MARK: - Destinations

/// Destinations as rows; clicking one pushes its form into the same column,
/// the same shape as the Pipelines pane.
struct DestinationsSettingsPane: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var path: [UUID] = []
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    ForEach(store.config.destinations) { destination in
                        NavigationLink(value: destination.id) {
                            VStack(alignment: .leading) {
                                Text(destination.name.isEmpty ? "(unnamed)" : destination.name)
                                Text(kindLabel(destination.kind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                store.deleteDestination(destination.id)
                            }
                        }
                    }
                    if store.config.destinations.isEmpty {
                        Text("No destinations yet")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    HStack(alignment: .top) {
                        if let importError {
                            Text(importError)
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Menu {
                            Button("S3-compatible") { add(.s3) }
                            Button("SFTP") { add(.sftp) }
                            Button("FTP") { add(.ftp) }
                            Button("WebDAV") { add(.webdav) }
                            Button("Custom HTTP (ShareX)") { add(.customHTTP) }
                            Divider()
                            Button("Import ShareX .sxcu…") { importing = true }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add destination")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationDestination(for: UUID.self) { id in
                DestinationForm(store: store, id: id)
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: sxcuTypes,
            allowsMultipleSelection: false
        ) { result in
            importSxcu(result)
        }
    }

    private var sxcuTypes: [UTType] {
        var types: [UTType] = [.json, .text, .data]
        if let sxcu = UTType(filenameExtension: "sxcu") {
            types.insert(sxcu, at: 0)
        }
        return types
    }

    private func kindLabel(_ kind: DestinationKind) -> String {
        switch kind {
        case .s3: return "S3-compatible"
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
        case .webdav: return "WebDAV"
        case .customHTTP: return "Custom HTTP"
        }
    }

    private func add(_ kind: DestinationKind) {
        var destination = Destination()
        destination.kind = kind
        destination.name = "New \(kindLabel(kind))"
        store.update { $0.destinations.append(destination) }
        path.append(destination.id)
    }

    private func importSxcu(_ result: Result<[URL], Error>) {
        importError = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        do {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let destination = try SxcuImporter.parse(data)
            store.update { $0.destinations.append(destination) }
            path.append(destination.id)
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

/// One destination's settings at full width, bound by id. Pops back to the
/// list once the destination no longer exists, which is also how "Delete
/// Destination" returns.
struct DestinationForm: View {
    @ObservedObject var store: ConfigStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var secretLoadedFor: UUID?

    var body: some View {
        if let destination = store.config.destinations.first(where: { $0.id == id }) {
            form(destination)
                .onAppear { loadSecret(destination) }
                .onChange(of: id) { loadSecret(destination) }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private func form(_ destination: Destination) -> some View {
        func field<T: Sendable>(
            _ keyPath: WritableKeyPath<Destination, T> & Sendable
        ) -> Binding<T> {
            store.binding(\.destinations, destination, keyPath)
        }
        return Form {
            Section {
                TextField("Name", text: field(\.name))
                switch destination.kind {
                case .s3:
                    TextField("Endpoint URL", text: field(\.s3.endpoint))
                    TextField("Region", text: field(\.s3.region))
                    TextField("Bucket", text: field(\.s3.bucket))
                    TextField("Access key", text: field(\.s3.accessKey))
                    secretField("Secret key", field: "secretKey")
                    TextField("Path prefix (optional)", text: field(\.s3.pathPrefix))
                    Toggle("Public-read ACL", isOn: field(\.s3.publicReadACL))
                    Toggle("Server-side encryption", isOn: field(\.s3.serverSideEncryption))
                    TextField(
                        "Public URL template ({key})", text: field(\.s3.publicURLTemplate)
                    )
                case .sftp, .ftp, .webdav:
                    TextField(
                        destination.kind == .webdav ? "Base URL" : "Host",
                        text: field(\.server.host)
                    )
                    TextField("Port (0 = default)", value: field(\.server.port), format: .number)
                    TextField("Username", text: field(\.server.username))
                    if destination.kind == .sftp {
                        TextField("SSH key path", text: field(\.server.sshKeyPath))
                    } else {
                        secretField("Password", field: "password")
                    }
                    TextField("Remote directory", text: field(\.server.remoteDirectory))
                    TextField(
                        "Public URL template ({filename} or {path})",
                        text: field(\.server.publicURLTemplate)
                    )
                case .customHTTP:
                    TextField("Request URL", text: field(\.custom.requestURL))
                    Picker("Method", selection: field(\.custom.requestMethod)) {
                        Text("POST").tag("POST")
                        Text("PUT").tag("PUT")
                    }
                    Picker("Body", selection: field(\.custom.bodyType)) {
                        Text("Multipart form data").tag("MultipartFormData")
                        Text("Binary").tag("Binary")
                        Text("JSON").tag("JSON")
                        Text("Form URL-encoded").tag("FormURLEncoded")
                    }
                    TextField("File form name", text: field(\.custom.fileFormName))
                    TextField("URL template", text: field(\.custom.urlTemplate))
                }
            } footer: {
                switch destination.kind {
                case .s3, .ftp, .webdav:
                    Text("Secrets are stored in the macOS Keychain, never in config.json.")
                case .sftp:
                    Text("SFTP uses SSH key authentication in v1.")
                case .customHTTP:
                    Text(
                        "Headers, parameters and arguments are editable in config.json "
                        + "or imported from a ShareX .sxcu file."
                    )
                }
            }
            Section {
                Button("Delete Destination", role: .destructive) {
                    store.deleteDestination(id)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(destination.name.isEmpty ? "(unnamed)" : destination.name)
    }

    private func secretField(_ label: String, field: String) -> some View {
        SecureField(label, text: Binding(
            get: { MainActor.assumeIsolated { secret } },
            set: { value in
                MainActor.assumeIsolated {
                    secret = value
                    Keychain.set(
                        value,
                        account: Keychain.secretAccount(for: id, field: field)
                    )
                }
            }
        ))
    }

    private func loadSecret(_ destination: Destination) {
        guard secretLoadedFor != destination.id else { return }
        secretLoadedFor = destination.id
        let field = destination.kind == .s3 ? "secretKey" : "password"
        secret = Keychain.get(
            account: Keychain.secretAccount(for: destination.id, field: field)
        ) ?? ""
    }
}

// MARK: - Advanced

struct AdvancedSettingsPane: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var includeSecrets = false
    @State private var passphrase = ""
    @State private var portStatus: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Config file") {
                    Button("Open in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.configURL])
                    }
                }
                LabeledContent("Log file") {
                    Button("Open") {
                        NSWorkspace.shared.open(Log.shared.logFileURL)
                    }
                }
            }

            Section {
                Toggle("Include secrets (Keychain passwords and keys)", isOn: $includeSecrets)
                SecureField("Passphrase (optional — encrypts the bundle)", text: $passphrase)
                HStack {
                    Button("Export Config…") { exportConfig() }
                    Button("Import Config…") { importConfig() }
                    if let portStatus {
                        Text(portStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Export / import")
            } footer: {
                Text(
                    "The config file is plain JSON and safe to edit by hand while "
                    + "macshot is not running. Secrets live in the Keychain under "
                    + "the service \"dev.macshot.app\" and are excluded from exports "
                    + "unless you opt in."
                )
            }
        }
        .formStyle(.grouped)
    }

    private func exportConfig() {
        portStatus = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macshot-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let secrets = includeSecrets
                ? ConfigPorter.gatherSecrets(for: store.config.destinations)
                : nil
            let data = try ConfigPorter.export(
                config: store.config,
                secrets: secrets,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
            try data.write(to: url, options: .atomic)
            portStatus = "Exported."
        } catch {
            portStatus = error.localizedDescription
        }
    }

    private func importConfig() {
        portStatus = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            var pass: String? = passphrase.isEmpty ? nil : passphrase
            if ConfigPorter.isEncrypted(data), pass == nil {
                portStatus = "Bundle is encrypted — enter the passphrase above first."
                return
            }
            if !ConfigPorter.isEncrypted(data) { pass = nil }
            let bundle = try ConfigPorter.import(data, passphrase: pass)

            // Confirmation summary; shell commands are surfaced explicitly
            // before activation (PRD §15).
            let alert = NSAlert()
            alert.messageText = "Replace current configuration?"
            var info = "Destinations: \(bundle.config.destinations.count) · "
                + "Pipelines: \(bundle.config.pipelines.count)"
            let commands = ConfigPorter.shellCommands(in: bundle.config)
            if !commands.isEmpty {
                info += "\n\n⚠️ This config runs shell commands:\n"
                    + commands.map { "• \($0)" }.joined(separator: "\n")
            }
            if bundle.secrets?.isEmpty == false {
                info += "\n\nIncludes \(bundle.secrets!.count) secret(s) that will be "
                    + "stored in your Keychain."
            }
            alert.informativeText = info
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            store.replace(with: bundle.config)
            if let secrets = bundle.secrets {
                ConfigPorter.restoreSecrets(secrets)
            }
            HotkeyManager.shared.apply(store.config.hotkeys)
            portStatus = "Imported."
        } catch {
            portStatus = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
