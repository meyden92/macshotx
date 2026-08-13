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
    /// The one way a capture begins: present the capture overlay and let it
    /// decide what gets captured (ADR 0010).
    @MainActor
    static func captureOverlay() async {
        switch await CaptureOverlaySession.run() {
        case .committed(let commit):
            playFeedback()
            // Watermarked here, once: every pipeline action — and a second pass
            // through the editor — then works on the same finished image.
            await PipelineRunner().run(CaptureArtifact(
                image: Watermark.applied(
                    to: commit.image, ConfigStore.shared.config.capture.watermark
                ),
                appName: commit.appName,
                windowTitle: commit.windowTitle
            ))
        case .cancelled:
            break
        case .failed(let error):
            await notifyCaptureFailure(error)
        }
    }

    // MARK: - ScreenCaptureKit

    /// The overlay session's per-display screenshot. It passes macshot itself
    /// in `excluding` so an overlay can never appear inside its own screenshot.
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

    // MARK: - Feedback

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
