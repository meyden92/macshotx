import AppKit
import SwiftUI
import UserNotifications

// MARK: - Model

/// A macOS privacy permission macshot asks for, and where the user manages it.
/// Hotkeys deliberately need no Accessibility grant (ADR 0002), so this list is
/// the whole of what macshot requires.
enum SystemPermission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .notifications: "Notifications"
        }
    }

    /// Why macshot asks for it, in the user's terms.
    var purpose: String {
        switch self {
        case .screenRecording: "Required for every capture."
        case .notifications: "Capture success and failure banners with quick actions."
        }
    }

    /// Screen Recording is the one macshot cannot work without.
    var isRequired: Bool { self == .screenRecording }

    /// The System Settings pane that grants it. The pane identifiers are fixed
    /// system strings, so the URL always parses.
    var settingsURL: URL {
        let pane = switch self {
        case .screenRecording: "com.apple.preference.security?Privacy_ScreenCapture"
        case .notifications: "com.apple.Notifications-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:\(pane)")!
    }

    /// Whether an in-app prompt can still do anything, given the current status.
    /// macOS prompts for notifications exactly once; Screen Recording's
    /// preflight cannot tell "never asked" from "refused", so its request stays
    /// on offer until granted — asking again when it is moot is harmless.
    func canRequest(_ status: PermissionStatus) -> Bool {
        switch self {
        case .screenRecording: status != .granted
        case .notifications: status == .notDetermined
        }
    }
}

/// Where a permission stands right now.
enum PermissionStatus: Sendable, Equatable {
    case granted
    /// Never asked — an in-app prompt still works.
    case notDetermined
    /// Refused — or refused-or-never-asked, where macOS won't say which.
    case notGranted

    var label: String {
        switch self {
        case .granted: "Granted"
        case .notDetermined: "Not requested"
        case .notGranted: "Not granted"
        }
    }

    /// Provisional authorization delivers quietly, with none of the banners the
    /// row promises, so only full authorization counts as granted.
    init(_ authorization: UNAuthorizationStatus) {
        switch authorization {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        default: self = .notGranted
        }
    }
}

/// Live permission statuses, shared by the setup wizard and Settings →
/// Permissions. A permission with no entry has not been checked yet — the rows
/// say so rather than guessing a grant.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var statuses: [SystemPermission: PermissionStatus] = [:]

    func status(_ permission: SystemPermission) -> PermissionStatus? {
        statuses[permission]
    }

    /// Re-reads every permission from the system. Runs once when the list
    /// appears; a grant made in System Settings while the list is already on
    /// screen shows up when the user hits Re-check.
    func refresh() async {
        var next: [SystemPermission: PermissionStatus] = [:]
        for permission in SystemPermission.allCases {
            next[permission] = await Self.currentStatus(of: permission)
        }
        statuses = next
    }

    /// Asks macOS to prompt, then re-reads. Screen Recording's grant only takes
    /// effect on the next launch, so the status can stay "not granted" here.
    func request(_ permission: SystemPermission) async {
        switch permission {
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .notifications:
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
        await refresh()
    }

    func openSystemSettings(for permission: SystemPermission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    private static func currentStatus(of permission: SystemPermission) async -> PermissionStatus {
        switch permission {
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .notifications:
            PermissionStatus(await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus)
        }
    }
}

// MARK: - View

/// The permission list shown by both the setup wizard and Settings →
/// Permissions, so the two can never disagree about what macshot needs.
struct PermissionsList: View {
    @StateObject private var model = PermissionsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(SystemPermission.allCases) { permission in
                PermissionRow(permission: permission, status: model.status(permission)) {
                    Task { await model.request(permission) }
                } openSettings: {
                    model.openSystemSettings(for: permission)
                }
            }
            Text(
                "Hotkeys use the system hotkey API and need no Accessibility "
                + "permission. After granting Screen Recording you may need to "
                + "relaunch macshot."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Re-check") { Task { await model.refresh() } }
        }
        .task { await model.refresh() }
    }
}

private struct PermissionRow: View {
    let permission: SystemPermission
    /// `nil` until the first check comes back.
    let status: PermissionStatus?
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(permission.title).bold()
                    if !permission.isRequired {
                        Text("Optional")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(permission.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(status?.label ?? "Checking…")
                    .font(.callout)
                    .foregroundStyle(status == .granted ? .secondary : iconColor)
            }
            Spacer()
            if status != .granted {
                if let status, permission.canRequest(status) {
                    Button("Request", action: request)
                }
                Button("Open System Settings", action: openSettings)
            }
        }
    }

    // Missing is missing, whether or not the permission is required — the
    // "Optional" badge is what says how much it matters, so the status itself
    // stays readable at a glance.
    private var icon: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .none: "circle.dashed"
        default: "exclamationmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch status {
        case .granted: .green
        case .none: .secondary
        default: .orange
        }
    }
}
