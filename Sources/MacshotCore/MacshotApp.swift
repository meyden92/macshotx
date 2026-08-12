import AppKit
import SwiftUI
import UserNotifications

public struct MacshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra("macshot", systemImage: "camera.viewfinder") {
            MenuContent()
        }

        Settings {
            SettingsView()
        }
    }
}

struct MenuContent: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Button("Capture Region") {
            Task { await CaptureService.captureRegion() }
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])
        Button("Capture Window") {
            Task { await CaptureService.captureWindow() }
        }
        .keyboardShortcut("2", modifiers: [.command, .shift])
        Button("Capture Fullscreen") {
            Task { await CaptureService.captureFullscreen() }
        }
        .keyboardShortcut("3", modifiers: [.command, .shift])
        Divider()
        Button("Pick Color") {
            Task { await ColorSampler.run(copyToClipboard: true) }
        }
        Button("Magnifier") {
            Task { await ColorSampler.run(copyToClipboard: false) }
        }
        Divider()
        let recents = store.config.recents.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        if !recents.isEmpty {
            Menu("Recent Captures") {
                ForEach(recents, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    }
                }
            }
            Divider()
        }
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit macshot") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tray-only: no Dock tile and no Cmd-Tab entry. LSUIElement already says
        // so for the bundled app; this also covers an unbundled `swift run`.
        NSApp.setActivationPolicy(.accessory)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Notifier.registerCategories()
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        HotkeyManager.shared.handler = { action in
            AppDelegate.perform(action)
        }
        HotkeyManager.shared.apply(ConfigStore.shared.config.hotkeys)
        OnboardingController.showIfNeeded()
        Log.info("macshot launched")
    }

    static func perform(_ action: HotkeyAction) {
        // Region and Window both open the capture overlay; the hotkey
        // determines only the initial snap state.
        if let snapArmed = action.overlayInitialSnapArmed {
            Task { await CaptureService.captureOverlay(initialSnapArmed: snapArmed) }
            return
        }
        switch action {
        case .captureFullscreen:
            Task { await CaptureService.captureFullscreen() }
        case .colorPicker:
            Task { await ColorSampler.run(copyToClipboard: true) }
        case .magnifier:
            Task { await ColorSampler.run(copyToClipboard: false) }
        case .captureRegion, .captureWindow:
            break // handled above
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let filePath = userInfo["filePath"] as? String
        let urlString = userInfo["url"] as? String
        let actionID = response.actionIdentifier

        Task { @MainActor in
            switch actionID {
            case NotificationActionID.reveal, UNNotificationDefaultActionIdentifier:
                if let filePath {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: filePath)]
                    )
                }
            case NotificationActionID.copyURL:
                if let urlString {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(urlString, forType: .string)
                }
            case NotificationActionID.showDetails:
                NSWorkspace.shared.open(Log.shared.logFileURL)
            case NotificationActionID.retry:
                await PipelineRunner().retryPending()
            default:
                break
            }
        }
        completionHandler()
    }
}
