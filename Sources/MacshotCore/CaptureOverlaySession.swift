import AppKit
import ScreenCaptureKit

final class KeyableOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One capture: the capture overlay on every display at once. Owns one
/// overlay window per NSScreen, broadcasts cross-display state (snap, active
/// tool, style values, selection ownership) so all overlays agree, and
/// resolves exactly once — with a committed capture, or with a cancellation.
///
/// Presentation does not wait for pixels: the shareable-content fetch and the
/// per-display screenshot requests are issued first, the overlays appear
/// immediately over a clear background, and app activation happens only after
/// the screenshot requests are in flight so another app's open menu survives
/// into the frozen images.
@MainActor
final class CaptureOverlaySession {
    struct Commit {
        let image: CGImage
        let appName: String?
        let windowTitle: String?
        let mayContainTransparency: Bool
    }

    enum Outcome {
        case committed(Commit)
        case cancelled
        case failed(Error)
    }

    /// The live session, if any. The capture hotkey pressed while the overlay
    /// is already up is a no-op rather than a second set of overlays.
    private static weak var active: CaptureOverlaySession?

    static func run() async -> Outcome {
        guard active == nil else { return .cancelled }
        let session = CaptureOverlaySession()
        active = session
        defer { if active === session { active = nil } }
        return await session.run()
    }

    private struct Overlay {
        let screen: NSScreen
        let window: NSWindow
        let view: RegionPickerView
        /// The display's frame in global Quartz coordinates (top-left origin).
        let quartzFrame: CGRect
    }

    private struct BakeFailedError: LocalizedError {
        var errorDescription: String? { "Could not render the capture." }
    }

    private var model: CaptureSessionModel
    private let screens: [NSScreen]
    private let primaryHeight: CGFloat
    private var overlays: [Overlay] = []
    /// Snap candidates, already filtered and z-order-deduplicated — computed
    /// once per capture, scanned per hover.
    private var snapCandidates: [WindowCandidate] = []
    private var frontAppName: String?
    private var frontAppPID: pid_t?
    private var frontWindowTitle: String?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var hasResumed = false

    private init() {
        let screens = NSScreen.screens
        self.screens = screens
        self.primaryHeight = screens.first?.frame.height ?? 0
        // The overlay always starts with snap off: nothing about the capture is
        // decided before it is on screen (ADR 0010).
        self.model = CaptureSessionModel(displayCount: screens.count, snapArmed: false)
    }

    private func run() async -> Outcome {
        guard !screens.isEmpty else { return .cancelled }
        // %app / %window context for drag and fullscreen routes, snapshotted
        // before activation makes macshot itself frontmost.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontAppName = front.localizedName
            frontAppPID = front.processIdentifier
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            beginCapture()
            present()
        }
    }

    // MARK: - Frozen screenshots and window list

    private func beginCapture() {
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true
                )
                await self?.contentArrived(content)
            } catch {
                self?.fail(CaptureError.captureFailed(error))
            }
        }
    }

    private func contentArrived(_ content: SCShareableContent) async {
        guard !hasResumed else { return }
        let ourBundle = Bundle.main.bundleIdentifier
        let ourApp = content.applications.first { $0.bundleIdentifier == ourBundle }
        var matchedAny = false
        for (index, overlay) in overlays.enumerated() {
            guard
                let screenID = overlay.screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID,
                let display = content.displays.first(where: { $0.displayID == screenID })
            else {
                // A screen ScreenCaptureKit cannot enumerate (Sidecar,
                // virtual displays): drop that one overlay and carry on
                // rather than killing the whole capture — unless the user
                // already committed on it, which can now never bake.
                Log.error("No capturable display for screen \(index); skipping its overlay")
                overlay.window.orderOut(nil)
                if model.heldCommit?.display == index {
                    fail(CaptureError.noDisplayUnderCursor)
                    return
                }
                continue
            }
            matchedAny = true
            Task { [weak self] in
                do {
                    let image = try await CaptureService.captureDisplayImage(
                        display, showsCursor: false, excluding: ourApp
                    )
                    self?.imageArrived(on: index, image: image)
                } catch {
                    self?.fail(error)
                }
            }
        }
        guard matchedAny else {
            fail(CaptureError.noDisplayUnderCursor)
            return
        }
        // Yield so the capture tasks run up to their first suspension — the
        // screenshot requests are then genuinely issued before activation,
        // and activating macshot cannot dismiss what the user froze.
        await Task.yield()
        guard !hasResumed else { return }
        NSApp.activate()
        keyWindowUnderCursor()

        snapCandidates = WindowSnapResolver.eligible(
            content.windows.map { window in
                WindowCandidate(
                    id: window.windowID,
                    frame: window.frame,
                    bundleIdentifier: window.owningApplication?.bundleIdentifier,
                    layer: window.windowLayer,
                    isOnScreen: window.isOnScreen
                )
            },
            ownBundleID: ourBundle
        )
        // The pointer may not move again before the click; highlight now.
        for overlay in overlays { overlay.view.refreshSnapHighlightNow() }
        resolveFrontWindowTitle(from: content, ourBundle: ourBundle)
    }

    private func imageArrived(on index: Int, image: CGImage) {
        guard !hasResumed, overlays.indices.contains(index) else { return }
        let view = overlays[index].view
        view.installFrozenImage(image)
        // Boundary-snap edge index, built off the main actor once the frozen
        // image exists; early gestures simply don't snap.
        if let snapshot = PixelSnapshot(image: image) {
            Task { @MainActor [weak view] in
                let edgeIndex = await Task.detached(priority: .utility) {
                    EdgeIndex.build(from: snapshot)
                }.value
                view?.edgeIndex = edgeIndex
            }
        }
        if let held = model.imageArrived(on: index) {
            performCommit(on: held.display, rect: held.rect)
        }
    }

    private func resolveFrontWindowTitle(
        from content: SCShareableContent, ourBundle: String?
    ) {
        if let pid = frontAppPID {
            frontWindowTitle = content.windows.first {
                $0.windowLayer == 0 && $0.isOnScreen
                    && $0.owningApplication?.processID == pid
            }?.title
            return
        }
        // macshot itself was frontmost (menu bar click) — fall back to the
        // topmost regular window on screen.
        let window = content.windows.first {
            $0.windowLayer == 0 && $0.isOnScreen
                && $0.owningApplication?.bundleIdentifier != ourBundle
        }
        frontAppName = window?.owningApplication?.applicationName
        frontWindowTitle = window?.title
    }

    // MARK: - Presentation

    private func present() {
        let config = ConfigStore.shared.config
        for (index, screen) in screens.enumerated() {
            let viewFrame = NSRect(origin: .zero, size: screen.frame.size)
            let view = RegionPickerView(
                frame: viewFrame,
                image: nil,
                scale: screen.backingScaleFactor,
                styles: config.editorStyles,
                onStylesChanged: { [weak self] styles in
                    self?.stylesEdited(styles, from: index)
                },
                showOverlayHints: config.capture.showOverlayHints,
                selectionPrefs: config.selection,
                onSelectionPrefsChanged: { prefs in
                    ConfigStore.shared.update { $0.selection = prefs }
                },
                beautifyDefaults: config.beautify,
                onBeautifyDefaultsChanged: { defaults in
                    ConfigStore.shared.update { $0.beautify = defaults }
                }
            )
            wire(view, at: index)

            let window = KeyableOverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [
                .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary
            ]
            window.contentView = view

            overlays.append(Overlay(
                screen: screen,
                window: window,
                view: view,
                quartzFrame: quartzFrame(of: screen)
            ))
            window.orderFrontRegardless()
            window.makeFirstResponder(view)
        }
        keyWindowUnderCursor()
        NSCursor.crosshair.set()
        pushSnapState()
    }

    private func wire(_ view: RegionPickerView, at index: Int) {
        view.onCommitRequested = { [weak self] rect in
            self?.requestCommit(on: index, rect: rect)
        }
        view.onCancel = { [weak self] in self?.cancelRequested() }
        view.onSelectionActivity = { [weak self] active in
            self?.selectionActivity(on: index, active: active)
        }
        view.onTabPressed = { [weak self] in self?.tabPressed() }
        view.onFullscreenKey = { [weak self] in self?.fullscreenKeyPressed() }
        view.onIdleClick = { [weak self] in
            // A click on an idle overlay must not fire while another display
            // holds the selection — a misclick would discard careful work.
            guard let self, self.model.selectionOwner == nil else { return }
            self.seedWholeDisplay(on: index)
        }
        view.onSnapClick = { [weak self] candidate in
            self?.seedWindow(candidate, on: index)
        }
        view.onSnapHover = { [weak self] cocoaPoint in
            self?.snapTarget(at: cocoaPoint, for: index)
        }
        view.onPointerMoved = { [weak self] in self?.pointerMoved(over: index) }
        view.onToolChosen = { [weak self] tool in self?.toolChosen(tool, from: index) }
        view.helperCardContent = { [weak self] in
            guard let self else { return nil }
            return HelperCard.content(
                snapArmed: self.model.snapArmed,
                suppressed: !ConfigStore.shared.config.capture.showOverlayHints
            )
        }
    }

    /// Cocoa screen frame → global Quartz frame (top-left origin at the
    /// primary display's top-left corner).
    private func quartzFrame(of screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    /// Index of the overlay whose screen contains the pointer.
    private func overlayIndexUnderCursor() -> Int? {
        let mouse = NSEvent.mouseLocation
        return overlays.firstIndex { NSPointInRect(mouse, $0.screen.frame) }
    }

    /// Keys the overlay under the pointer so keyboard input follows the
    /// display the user is looking at.
    private func keyWindowUnderCursor() {
        let overlay = overlayIndexUnderCursor().map { overlays[$0] } ?? overlays.first
        overlay?.window.makeKey()
    }

    private func pointerMoved(over index: Int) {
        guard overlays.indices.contains(index) else { return }
        let window = overlays[index].window
        guard !window.isKeyWindow, NSApp.isActive else { return }
        // Hovering must not yank key away from an overlay mid-text-edit —
        // that would end the edit the user is still typing.
        guard !overlays.contains(where: {
            $0.window.isKeyWindow && $0.view.isEditingText
        }) else { return }
        window.makeKey()
    }

    // MARK: - Cross-display state

    private func selectionActivity(on index: Int, active: Bool) {
        if active {
            for display in model.startSelection(on: index)
            where overlays.indices.contains(display) {
                overlays[display].view.clearWholeSelection()
            }
        } else {
            model.clearSelection(on: index)
        }
    }

    private func tabPressed() {
        guard model.toggleSnap() else { return }
        pushSnapState()
    }

    private func pushSnapState() {
        for overlay in overlays { overlay.view.setSnapArmed(model.snapArmed) }
    }

    private func toolChosen(_ tool: Tool, from index: Int) {
        for (i, overlay) in overlays.enumerated() where i != index {
            overlay.view.adoptTool(tool)
        }
    }

    private func stylesEdited(_ styles: EditorStyles, from index: Int) {
        ConfigStore.shared.update { $0.editorStyles = styles }
        for (i, overlay) in overlays.enumerated() where i != index {
            overlay.view.adoptStyles(styles)
        }
    }

    /// `F`: fills the Selection to the display under the cursor while that
    /// overlay is idle; in every other state it keeps selecting the fill-rect
    /// tool, whose shortcut it is.
    private func fullscreenKeyPressed() {
        if let index = overlayIndexUnderCursor(), overlays[index].view.isIdle {
            seedWholeDisplay(on: index)
            return
        }
        for overlay in overlays { overlay.view.adoptTool(.fillRect) }
    }

    // MARK: - Seeding routes
    //
    // None of these capture: they hand the overlay a Selection and the user
    // confirms it like any other (ADR 0011).

    private func seedWholeDisplay(on index: Int) {
        guard overlays.indices.contains(index) else { return }
        let view = overlays[index].view
        view.seedSelection(view.bounds)
    }

    private func seedWindow(_ candidate: WindowCandidate, on index: Int) {
        guard overlays.indices.contains(index) else { return }
        let overlay = overlays[index]
        // The candidate's frame is global Quartz; the overlay's view space is
        // the same orientation, offset to the display's own top-left corner.
        overlay.view.seedSelection(candidate.frame.offsetBy(
            dx: -overlay.quartzFrame.minX, dy: -overlay.quartzFrame.minY
        ))
    }

    private func snapTarget(
        at cocoaPoint: NSPoint, for index: Int
    ) -> (candidate: WindowCandidate, rect: NSRect)? {
        guard overlays.indices.contains(index) else { return nil }
        let quartzPoint = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        guard let candidate = snapCandidates.first(where: {
            $0.frame.contains(quartzPoint)
        }) else { return nil }
        let display = overlays[index].quartzFrame
        let local = candidate.frame.offsetBy(dx: -display.minX, dy: -display.minY)
        return (candidate, local)
    }

    // MARK: - Commit routes

    private func requestCommit(on index: Int, rect: CGRect) {
        switch model.requestCommit(on: index, rect: rect) {
        case .perform:
            performCommit(on: index, rect: rect)
        case .held, .ignored:
            break
        }
    }

    /// The one commit: bake this display's frozen image, annotations and all,
    /// cropped to the confirmed Selection.
    private func performCommit(on index: Int, rect: CGRect) {
        guard overlays.indices.contains(index) else { return }
        let overlay = overlays[index]
        guard let image = overlay.view.bakedImage(croppingTo: rect) else {
            finish(.failed(CaptureError.captureFailed(BakeFailedError())))
            return
        }
        finish(.committed(Commit(
            image: image,
            appName: frontAppName,
            windowTitle: frontWindowTitle,
            mayContainTransparency: overlay.view.mayContainTransparency
        )))
    }

    // MARK: - Resolution

    private func cancelRequested() {
        guard model.cancel() else { return }
        finish(.cancelled)
    }

    private func fail(_ error: Error) {
        guard model.cancel() else { return }
        finish(.failed(error))
    }

    private func finish(_ outcome: Outcome) {
        guard !hasResumed else { return }
        hasResumed = true
        NSCursor.arrow.set()
        for overlay in overlays {
            overlay.window.orderOut(nil)
        }
        overlays.removeAll()
        let cont = continuation
        continuation = nil
        cont?.resume(returning: outcome)
    }
}
