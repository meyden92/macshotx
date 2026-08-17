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
    @ObservedObject private var updater = UpdaterService.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Each entry advertises its configured global hotkey (Settings →
        // Hotkeys), not a menu-only combination: nil binding, no shortcut drawn.
        Button("Capture") {
            Task { await CaptureService.captureOverlay() }
        }
        .keyboardShortcut(store.config.hotkeys.capture?.menuShortcut)
        Divider()
        Button("Pick Color") {
            Task { await ColorSampler.run(copyToClipboard: true) }
        }
        .keyboardShortcut(store.config.hotkeys.colorPicker?.menuShortcut)
        Button("Magnifier") {
            Task { await ColorSampler.run(copyToClipboard: false) }
        }
        .keyboardShortcut(store.config.hotkeys.magnifier?.menuShortcut)
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
        // Opening the window is not enough: the tray menu belongs to whatever
        // app was already frontmost, so Settings would come up behind it and
        // without key focus. Every other window here (editor, wizard, loupe)
        // activates first for the same reason.
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
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

        // No authorization request here: prompting at launch would burn the one
        // prompt macOS gives before the user has any context. The wizard and
        // Settings → Permissions ask for it, and Notifier asks lazily before the
        // first banner.
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerCategories()

        HotkeyManager.shared.handler = { action in
            AppDelegate.perform(action)
        }
        HotkeyManager.shared.apply(ConfigStore.shared.config.hotkeys)
        OnboardingController.showIfNeeded()
        Log.info("macshot launched")
    }

    static func perform(_ action: HotkeyAction) {
        switch action {
        case .capture:
            Task { await CaptureService.captureOverlay() }
        case .colorPicker:
            Task { await ColorSampler.run(copyToClipboard: true) }
        case .magnifier:
            Task { await ColorSampler.run(copyToClipboard: false) }
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
