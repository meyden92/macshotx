import AppKit
import Combine
import Sparkle
import SwiftUI

/// Owns the app-wide Sparkle updater. Instantiated lazily on first menu render;
/// starting the controller kicks off Sparkle's scheduled background checks
/// (enabled via SUEnableAutomaticChecks in release bundles, see
/// scripts/bundle.sh). Updates come from the appcast that the release workflow
/// attaches to each stable GitHub release.
@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    private let controller: SPUStandardUpdaterController

    /// False while a check or install is already in flight; drives the menu
    /// item's enabled state.
    @Published private(set) var canCheckForUpdates = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        // Tray app: without activating first, Sparkle's dialog would come up
        // behind the frontmost app and without key focus (same reason
        // Settings… activates).
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
