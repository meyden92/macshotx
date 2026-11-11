import Testing
@testable import MacshotCore

// The sidebar is built from SettingsPane alone, so its structure and the
// restore fallback are what Settings looks like when it opens.

@Test
func theSidebarListsEveryPaneOnceUnderItsGroupInTheAgreedOrder() {
    let sidebar = SettingsPane.sidebar
    #expect(sidebar.map(\.group) == [.app, .capture, .output, .advanced])
    #expect(sidebar.map(\.panes) == [
        [.general, .permissions],
        [.hotkeys, .pipelines, .destinations],
        [.saving, .watermark],
        [.advanced]
    ])
}

@Test
func everyPaneAndGroupHasSomethingToShow() {
    for pane in SettingsPane.allCases {
        #expect(!pane.title.isEmpty)
        #expect(!pane.systemImage.isEmpty)
    }
    for group in SettingsGroup.allCases {
        #expect(!group.title.isEmpty)
    }
}

@Test
func theLastPaneIsRestoredAndAnythingUnknownOpensGeneral() {
    for pane in SettingsPane.allCases {
        #expect(SettingsPane(storedValue: pane.rawValue) == pane)
    }
    // Tabs that no longer exist, an empty value, and a future pane.
    for stale in ["filenames", "capture", "", "somethingNew"] {
        #expect(SettingsPane(storedValue: stale) == .general)
    }
}
