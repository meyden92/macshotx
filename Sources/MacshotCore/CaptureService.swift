import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplayUnderCursor
    case captureFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplayUnderCursor:
            return "Could not identify a display to capture."
        case .captureFailed(let error):
            return "Capture failed: \(error.localizedDescription)"
        }
    }
}

enum CaptureService {
    @MainActor
    static func captureFullscreen() async {
        do {
            let content = try await shareableContent(excludingDesktopWindows: false)
            guard let display = displayUnderCursor(from: content.displays) else {
                throw CaptureError.noDisplayUnderCursor
            }
            let front = frontmostInfo(in: content)
            let image = try await captureDisplayImage(display, showsCursor: true)
            playFeedback()
            await PipelineRunner().run(CaptureArtifact(
                image: image,
                mode: .fullscreen,
                appName: front.appName,
                windowTitle: front.windowTitle
            ))
        } catch {
            await notifyCaptureFailure(error)
        }
    }

    /// Region and Window are two entries into one surface: the capture
    /// overlay. The entry determines only the initial snap state; the commit
    /// route inside the overlay determines the capture mode.
    @MainActor
    static func captureRegion() async {
        await captureOverlay(initialSnapArmed: false)
    }

    @MainActor
    static func captureWindow() async {
        await captureOverlay(initialSnapArmed: true)
    }

    @MainActor
    static func captureOverlay(initialSnapArmed: Bool) async {
        switch await CaptureOverlaySession.run(initialSnapArmed: initialSnapArmed) {
        case .committed(let commit):
            playFeedback()
            await PipelineRunner().run(CaptureArtifact(
                image: commit.image,
                mode: commit.mode,
                appName: commit.appName,
                windowTitle: commit.windowTitle,
                companionImage: commit.companionImage,
                mayContainTransparency: commit.mayContainTransparency
            ))
        case .cancelled:
            break
        case .failed(let error):
            await notifyCaptureFailure(error)
        }
    }

    // MARK: - ScreenCaptureKit

    private static func shareableContent(
        excludingDesktopWindows: Bool
    ) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                excludingDesktopWindows,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    /// Shared by fullscreen capture and the capture overlay session. The
    /// overlay passes macshot itself in `excluding` so an overlay can never
    /// appear inside its own screenshot.
    @MainActor
    static func captureDisplayImage(
        _ display: SCDisplay,
        showsCursor: Bool,
        excluding app: SCRunningApplication? = nil
    ) async throws -> CGImage {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: app.map { [$0] } ?? [],
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        // SCDisplay.width/height are in points; capture at native pixel
        // resolution or Retina output comes back 1x and looks blurry.
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = showsCursor
        config.capturesAudio = false
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    // MARK: - Context helpers

    /// Frontmost app and window title at trigger time, for %app / %window.
    @MainActor
    private static func frontmostInfo(
        in content: SCShareableContent
    ) -> (appName: String?, windowTitle: String?) {
        let ourBundle = Bundle.main.bundleIdentifier
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != ourBundle
        else {
            // macshot itself is frontmost (menu bar click) — fall back to the
            // topmost regular window on screen.
            let window = content.windows.first {
                $0.windowLayer == 0 && $0.isOnScreen
                    && $0.owningApplication?.bundleIdentifier != ourBundle
            }
            return (window?.owningApplication?.applicationName, window?.title)
        }
        let window = content.windows.first {
            $0.windowLayer == 0 && $0.isOnScreen
                && $0.owningApplication?.processID == app.processIdentifier
        }
        return (app.localizedName, window?.title)
    }

    @MainActor
    private static func displayUnderCursor(from displays: [SCDisplay]) -> SCDisplay? {
        let mouseLocation = NSEvent.mouseLocation
        let screenContainingMouse = NSScreen.screens.first { screen in
            NSPointInRect(mouseLocation, screen.frame)
        }
        guard
            let screen = screenContainingMouse,
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return displays.first
        }
        return displays.first(where: { $0.displayID == screenID }) ?? displays.first
    }

    @MainActor
    private static func playFeedback() {
        if ConfigStore.shared.config.general.captureFeedbackEnabled {
            CaptureFeedback.play()
        }
    }

    @MainActor
    private static func notifyCaptureFailure(_ error: Error) async {
        Log.error("Capture failed: \(error)")
        await Notifier.failure(
            title: "Capture failed",
            error: error,
            enabled: ConfigStore.shared.config.general.notificationsEnabled
        )
    }
}
