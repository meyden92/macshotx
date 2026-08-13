import AppKit
import SwiftUI

/// First-launch wizard (PRD §9.1): permissions, save folder, hotkeys, done.
/// Skippable at any point.
@MainActor
enum OnboardingController {
    private static var window: NSWindow?

    /// Shown on every launch until the user finishes or skips it, so granting
    /// Screen Recording and relaunching resumes setup instead of dropping the
    /// user into a half-configured app with no way back in.
    static func showIfNeeded() {
        guard !ConfigStore.shared.config.general.setupCompleted else { return }
        show()
    }

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView {
            close()
        })
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Welcome to macshot"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow
        NSApp.activate()
        newWindow.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void
    @ObservedObject private var store = ConfigStore.shared
    @State private var page: Int

    private let pageCount = 4

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _page = State(initialValue: ConfigStore.shared.config.general.setupPage ?? 0)
    }

    /// Each step is recorded as it is reached, which is what survives the
    /// relaunch the permissions page asks for.
    private func go(to next: Int) {
        page = next
        store.update { $0.general.setupPage = next }
    }

    /// Setup ends only when the user says so, by finishing or skipping.
    private func finish() {
        store.update { $0.general.setupPage = nil }
        onFinish()
    }

    var body: some View {
        VStack(spacing: 16) {
            Group {
                switch page {
                case 0: welcome
                case 1: permissions
                case 2: saveFolder
                default: hotkeysAndDone
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack {
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if page > 0 {
                    Button("Back") { go(to: page - 1) }
                }
                if page < pageCount - 1 {
                    Button("Continue") { go(to: page + 1) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Try It Now") {
                        finish()
                        Task { await CaptureService.captureOverlay() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Welcome to macshot")
                .font(.largeTitle.bold())
            Text(
                "Keyboard-driven screenshots with ShareX-grade automation: "
                + "annotate on the live screen, then pipe the capture through "
                + "copy, save, upload and shell actions — all configurable."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 32)
    }

    /// The same list Settings → Permissions shows, so the wizard and the panel
    /// can never disagree about what macshot needs.
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.bold())
            PermissionsList()
        }
    }

    private var saveFolder: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where should screenshots go?")
                .font(.title2.bold())
            HStack {
                TextField("Save folder", text: store.binding(\.capture.saveDirectory))
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        store.update { $0.capture.saveDirectory = url.path }
                    }
                }
            }
            Text(
                "Every capture is copied to the clipboard and saved here by "
                + "default. Change the pipeline later in Settings → Pipeline."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var hotkeysAndDone: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Default hotkeys")
                .font(.title2.bold())
            ForEach(HotkeyAction.allCases, id: \.self) { action in
                HStack {
                    Text(action.label)
                    Spacer()
                    Text(store.config.hotkeys.binding(for: action)?.displayString ?? "None")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Text("Rebind any of these in Settings → Hotkeys.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
