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

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
            HotkeysSettingsTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            CaptureSettingsTab()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            FilenamesSettingsTab()
                .tabItem { Label("Filenames", systemImage: "textformat.abc") }
            PipelineSettingsTab()
                .tabItem { Label("Pipeline", systemImage: "arrow.right.square") }
            DestinationsSettingsTab()
                .tabItem { Label("Destinations", systemImage: "icloud.and.arrow.up") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 640)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
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

            Section {
                Text(
                    "Privacy: macshot makes no network calls except uploads to "
                    + "destinations you configure. No telemetry, no analytics."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
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
struct PermissionsSettingsTab: View {
    var body: some View {
        VStack(alignment: .leading) {
            PermissionsList()
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Hotkeys

struct HotkeysSettingsTab: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            ForEach(HotkeyAction.allCases, id: \.self) { action in
                HotkeyRecorderRow(action: action, store: store)
            }
            let conflicts = store.config.hotkeys.conflicts()
            if !conflicts.isEmpty {
                Label(
                    conflicts
                        .map { "\($0.0.label) and \($0.1.label) share the same shortcut" }
                        .joined(separator: "\n"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
            Text("Click a shortcut, then press the new key combination. Esc cancels.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct HotkeyRecorderRow: View {
    let action: HotkeyAction
    @ObservedObject var store: ConfigStore
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(action.label)
            Spacer()
            Button(recording ? "Press keys…" : currentLabel) {
                recording ? stopRecording() : startRecording()
            }
            .frame(minWidth: 110)
            Button {
                store.update { $0.hotkeys.setBinding(nil, for: action) }
                HotkeyManager.shared.apply(store.config.hotkeys)
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
            store.update { $0.hotkeys.setBinding(binding, for: action) }
            HotkeyManager.shared.apply(store.config.hotkeys)
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

// MARK: - Capture

struct CaptureSettingsTab: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
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
        .padding(20)
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

// MARK: - Filenames

struct FilenamesSettingsTab: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
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

            Section("Tokens") {
                Text(
                    "%y %mo %d — date · %h %mi %s %ms — time · %counter — per-folder counter\n"
                    + "%window %app — active window/app\n"
                    + "%host %user — machine/user · %uuid — UUID · %rand:N — random characters"
                )
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func preview(of template: String) -> String {
        var context = FilenameTemplate.Context()
        context.windowTitle = "Project_Plan"
        context.appName = "Safari"
        context.counter = 42
        context.counterPadding = store.config.filenames.counterPadding
        return FilenameTemplate.expand(template, context: context)
    }
}

// MARK: - Pipeline

struct PipelineSettingsTab: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Pipeline") {
                    PipelineActionsEditor(actions: store.binding(\.pipeline.actions))
                }
                Text(
                    "Actions run top to bottom after every capture. If one fails, the "
                    + "pipeline stops and shows a notification with a Retry option."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(20)
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
        .padding(6)
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

struct DestinationsSettingsTab: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var selectedID: UUID?
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(store.config.destinations) { destination in
                        VStack(alignment: .leading) {
                            Text(destination.name.isEmpty ? "(unnamed)" : destination.name)
                            Text(kindLabel(destination.kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(destination.id)
                    }
                }
                .frame(width: 200)
                Divider()
                if let index = selectedIndex {
                    DestinationForm(store: store, index: index)
                } else {
                    VStack {
                        Text("Select or add a destination")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Menu("Add") {
                    Button("S3-compatible") { add(.s3) }
                    Button("SFTP") { add(.sftp) }
                    Button("FTP") { add(.ftp) }
                    Button("WebDAV") { add(.webdav) }
                    Button("Custom HTTP (ShareX)") { add(.customHTTP) }
                    Divider()
                    Button("Import ShareX .sxcu…") { importing = true }
                }
                .frame(width: 90)
                Button("Remove") { removeSelected() }
                    .disabled(selectedIndex == nil)
                Spacer()
                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(10)
        }
        .frame(height: 460)
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

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return store.config.destinations.firstIndex { $0.id == selectedID }
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
        selectedID = destination.id
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        let destination = store.config.destinations[index]
        Keychain.delete(account: Keychain.secretAccount(for: destination.id, field: "secretKey"))
        Keychain.delete(account: Keychain.secretAccount(for: destination.id, field: "password"))
        store.update { $0.destinations.remove(at: index) }
        selectedID = nil
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
            selectedID = destination.id
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

struct DestinationForm: View {
    @ObservedObject var store: ConfigStore
    let index: Int
    @State private var secret = ""
    @State private var secretLoadedFor: UUID?

    private var destination: Destination {
        store.config.destinations[index]
    }

    private func field<T: Sendable>(
        _ keyPath: WritableKeyPath<Destination, T> & Sendable
    ) -> Binding<T> {
        Binding(
            get: {
                MainActor.assumeIsolated { store.config.destinations[index][keyPath: keyPath] }
            },
            set: { value in
                MainActor.assumeIsolated {
                    store.update { $0.destinations[index][keyPath: keyPath] = value }
                }
            }
        )
    }

    var body: some View {
        Form {
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
                    Text("SFTP uses SSH key authentication in v1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Text(
                    "Headers, parameters and arguments are editable in config.json "
                    + "or imported from a ShareX .sxcu file."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .onAppear { loadSecret() }
        .onChange(of: destination.id) { loadSecret() }
    }

    @ViewBuilder
    private func secretField(_ label: String, field: String) -> some View {
        SecureField(label, text: Binding(
            get: { MainActor.assumeIsolated { secret } },
            set: { value in
                MainActor.assumeIsolated {
                    secret = value
                    Keychain.set(
                        value,
                        account: Keychain.secretAccount(for: destination.id, field: field)
                    )
                }
            }
        ))
        Text("Stored in the macOS Keychain, never in config.json.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func loadSecret() {
        guard secretLoadedFor != destination.id else { return }
        secretLoadedFor = destination.id
        let field = destination.kind == .s3 ? "secretKey" : "password"
        secret = Keychain.get(
            account: Keychain.secretAccount(for: destination.id, field: field)
        ) ?? ""
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var includeSecrets = false
    @State private var passphrase = ""
    @State private var portStatus: String?

    var body: some View {
        Form {
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

            Section("Export / import") {
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
            }

            Section {
                Text(
                    "The config file is plain JSON and safe to edit by hand while "
                    + "macshot is not running. Secrets live in the Keychain under "
                    + "the service \"dev.macshot.app\" and are excluded from exports "
                    + "unless you opt in."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
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
                + "Pipeline actions: \(bundle.config.pipeline.actions.count)"
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
