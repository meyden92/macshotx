import AppKit
import SwiftUI
import UserNotifications

/// First-launch wizard (PRD §9.1): permissions, save folder, hotkeys, done.
/// Skippable at any point.
@MainActor
enum OnboardingController {
    private static var window: NSWindow?

    static func showIfNeeded() {
        guard ConfigStore.shared.isFirstRun else { return }
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
    @State private var page = 0
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    private let pageCount = 4

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
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
                Button("Skip") { onFinish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                if page < pageCount - 1 {
                    Button("Continue") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Try It Now") {
                        onFinish()
                        Task { await CaptureService.captureRegion() }
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

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.bold())
            HStack {
                Image(systemName: screenRecordingGranted
                    ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(screenRecordingGranted ? .green : .orange)
                VStack(alignment: .leading) {
                    Text("Screen Recording").bold()
                    Text("Required for every capture mode.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Request") {
                    CGRequestScreenCaptureAccess()
                    screenRecordingGranted = CGPreflightScreenCaptureAccess()
                }
                Button("Open System Settings") {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            HStack {
                Image(systemName: "bell.badge")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Notifications").bold()
                    Text("Capture success and failure banners with quick actions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Request") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound])
                    }
                }
            }
            Text(
                "Hotkeys use the system hotkey API and need no Accessibility "
                + "permission. After granting Screen Recording you may need to "
                + "relaunch macshot."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Re-check") {
                screenRecordingGranted = CGPreflightScreenCaptureAccess()
            }
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
