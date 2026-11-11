/// The panes of the Settings sidebar, declared in sidebar order. It is the one
/// source of truth for the sidebar's structure and for reopening the pane that
/// was last shown; `SettingsView` only renders it.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case permissions
    case hotkeys
    case pipelines
    case destinations
    case saving
    case watermark
    case advanced

    var id: String { rawValue }

    /// The pane to reopen from a stored raw value. Anything unknown (a pane that
    /// no longer exists, such as the old "filenames" tab, or one from a newer
    /// version) opens General.
    init(storedValue: String) {
        self = SettingsPane(rawValue: storedValue) ?? .general
    }

    var group: SettingsGroup {
        switch self {
        case .general, .permissions: .app
        case .hotkeys, .pipelines, .destinations: .capture
        case .saving, .watermark: .output
        case .advanced: .advanced
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .hotkeys: "Hotkeys"
        case .pipelines: "Pipelines"
        case .destinations: "Destinations"
        case .saving: "Saving"
        case .watermark: "Watermark"
        case .advanced: "Advanced"
        }
    }

    /// SF Symbol shown beside the title in the sidebar.
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "hand.raised"
        case .hotkeys: "keyboard"
        case .pipelines: "arrow.right.square"
        case .destinations: "icloud.and.arrow.up"
        case .saving: "square.and.arrow.down"
        case .watermark: "seal"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    /// The sidebar's sections: every group in display order, each with its
    /// panes in sidebar order.
    static var sidebar: [(group: SettingsGroup, panes: [SettingsPane])] {
        SettingsGroup.allCases.map { group in
            (group, allCases.filter { $0.group == group })
        }
    }
}

/// A section header in the Settings sidebar, declared in display order.
enum SettingsGroup: String, CaseIterable, Sendable {
    case app
    case capture
    case output
    case advanced

    var title: String {
        switch self {
        case .app: "App"
        case .capture: "Capture"
        case .output: "Output"
        case .advanced: "Advanced"
        }
    }
}
