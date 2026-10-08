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
        /// What `%app` and `%window` expand to.
        let appName: String?
        let windowTitle: String?

        /// A capture is filed under its window when the confirmed Selection
        /// still carries window provenance — wholly, never mixed with the
        /// fallback — and otherwise under the app that was frontmost when the
        /// overlay opened (ADR 0018).
        init(
            image: CGImage, window: WindowCandidate?,
            frontAppName: String?, frontWindowTitle: String?
        ) {
            self.image = image
            if let window {
                appName = window.applicationName
                windowTitle = window.title
            } else {
                appName = frontAppName
                windowTitle = frontWindowTitle
            }
        }
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
        guard active == nil else {
            Log.info("Capture requested while a session is already up; ignored")
            return .cancelled
        }
        Log.info("Capture session starting on \(NSScreen.screens.count) screen(s)")
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
    private var overlays: [Overlay] = []
    /// Snap candidates, already filtered and z-order-deduplicated — computed
    /// once per capture, scanned per hover.
    private var snapCandidates: [WindowCandidate] = []
    /// The windows behind `snapCandidates`, for capturing a window companion.
    private var scWindowsByID: [UInt32: SCWindow] = [:]
    /// The companion image for the window the Selection was last snapped to,
    /// captured as soon as the snap seeds it so beautify can preview it; a
    /// commit carrying that window waits for it (ADR 0018).
    private var companion: (windowID: UInt32, task: Task<CGImage?, Never>)?
    private var frontAppName: String?
    private var frontAppPID: pid_t?
    private var frontWindowTitle: String?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var hasResumed = false

    private init() {
        let screens = NSScreen.screens
        self.screens = screens
        // Snap starts armed (ADR 0016); the model carries that default so it is
        // pinned by its own tests.
        self.model = CaptureSessionModel(displayCount: screens.count)
    }

    private func run() async -> Outcome {
        guard !screens.isEmpty else { return .cancelled }
        // The fallback %app / %window context, for every capture whose
        // Selection carries no window (ADR 0018), snapshotted before
        // activation makes macshot itself frontmost.
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
                let screenID = Self.displayID(of: overlay.screen),
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
                    applicationName: window.owningApplication?.applicationName,
                    title: window.title,
                    layer: window.windowLayer,
                    isOnScreen: window.isOnScreen
                )
            },
            ownBundleID: ourBundle
        )
        scWindowsByID = Dictionary(
            content.windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        Log.info("Window snap: \(snapCandidates.count) of \(content.windows.count) windows eligible")
        // The pointer may not move again before the click; highlight now.
        for overlay in overlays { overlay.view.refreshSnapHighlightNow() }
        resolveFrontWindowTitle(from: content, ourBundle: ourBundle)
    }

    private func imageArrived(on index: Int, image: CGImage) {
        guard !hasResumed, overlays.indices.contains(index) else { return }
        let view = overlays[index].view
        // The frozen image sizes the pixel scale (#51); bounds must match the display.
        Log.info("Overlay \(index): frozen image \(image.width)x\(image.height) for bounds \(view.bounds.size)")
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
            Task { [weak self] in
                await self?.performCommit(on: held.display, rect: held.rect, window: held.window)
            }
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

            // No `screen:` argument: with one, AppKit reads `contentRect`
            // relative to that screen, which lands every non-primary overlay
            // off its display (#50). `setFrame` is unambiguously global.
            let window = KeyableOverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.setFrame(screen.frame, display: false)
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

            let quartz = quartzFrame(of: screen)
            Log.info(
                "Overlay \(index): screen \(screen.frame) window \(window.frame) "
                    + "quartz \(quartz) scale \(screen.backingScaleFactor)"
            )
            overlays.append(Overlay(
                screen: screen,
                window: window,
                view: view,
                quartzFrame: quartz
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
        view.onSnapHover = { [weak self] localPoint in
            self?.snapTarget(at: localPoint, for: index)
        }
        view.onWindowSeeded = { [weak self] candidate in
            self?.captureCompanion(of: candidate, for: index)
        }
        view.onPointerMoved = { [weak self] in self?.pointerMoved(over: index) }
        view.onToolChosen = { [weak self] tool in self?.toolChosen(tool, from: index) }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The display's global Quartz frame (top-left origin at the primary
    /// display's top-left corner), straight from CoreGraphics — the same
    /// space `SCWindow.frame` is in, with no Cocoa flip to get wrong.
    private func quartzFrame(of screen: NSScreen) -> CGRect {
        if let id = Self.displayID(of: screen) { return CGDisplayBounds(id) }
        // No display id (virtual screens): flip against the zero screen.
        let primaryHeight = screens.first?.frame.height ?? 0
        return CGRect(
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

    /// `localPoint` is in the overlay's own view space; the display's Quartz
    /// frame carries it to the global window list (#52).
    private func snapTarget(
        at localPoint: NSPoint, for index: Int
    ) -> (candidate: WindowCandidate, rect: NSRect)? {
        guard overlays.indices.contains(index) else { return nil }
        return WindowSnapResolver.target(
            in: snapCandidates,
            displayFrame: overlays[index].quartzFrame,
            localPoint: localPoint
        )
    }

    // MARK: - Commit route
    //
    // Confirming a Selection is the only commit (ADR 0016). The model holds
    // one whose frozen image has not landed yet.

    private func requestCommit(on index: Int, rect: CGRect) {
        guard overlays.indices.contains(index) else { return }
        let window = overlays[index].view.windowProvenance
        switch model.requestCommit(on: index, rect: rect, window: window) {
        case .perform:
            Task { [weak self] in
                await self?.performCommit(on: index, rect: rect, window: window)
            }
        case .held:
            Log.info("Commit on display \(index) held until its frozen image lands")
        case .ignored:
            break
        }
    }

    /// The one commit: bake this display's frozen image, annotations and all,
    /// cropped to the confirmed Selection. A Selection that still carries its
    /// window waits for that window's companion image first, so a quick
    /// `Return` composes the same as a slow one (ADR 0018).
    private func performCommit(on index: Int, rect: CGRect, window: WindowCandidate?) async {
        guard overlays.indices.contains(index) else { return }
        let overlay = overlays[index]
        if let window, let companion, companion.windowID == window.id,
           let image = await companion.task.value {
            overlay.view.setWindowCompanion(image, for: window)
        }
        guard let image = overlay.view.bakedImage(croppingTo: rect) else {
            finish(.failed(CaptureError.captureFailed(BakeFailedError())))
            return
        }
        finish(.committed(Commit(
            image: image, window: window,
            frontAppName: frontAppName, frontWindowTitle: frontWindowTitle
        )))
    }

    // MARK: - Window companion

    /// Window snap seeded the Selection on `index`: capture that window on its
    /// own, shadow-free, so it comes back with transparent rounded corners for
    /// beautify's backdrop to show through, and hand it to the overlay once it
    /// lands. The view keeps it only while its Selection still carries that
    /// window. Best effort — without it the capture composes from the frozen
    /// screen like any other.
    private func captureCompanion(of candidate: WindowCandidate, for index: Int) {
        // Snapped to the same window again: the capture already made serves.
        if companion?.windowID != candidate.id {
            companion = scWindowsByID[candidate.id].map { scWindow in
                (candidate.id, Task {
                    do {
                        return try await Self.captureSingleWindow(scWindow)
                    } catch {
                        Log.error("Window companion capture failed: \(error)")
                        return nil
                    }
                })
            }
        }
        guard let task = companion?.task else { return }
        Task { [weak self] in
            guard let image = await task.value, let self, !self.hasResumed,
                  self.overlays.indices.contains(index)
            else { return }
            self.overlays[index].view.setWindowCompanion(image, for: candidate)
        }
    }

    private static func captureSingleWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
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
        switch outcome {
        case .committed(let commit):
            Log.info("Capture session committed \(commit.image.width)x\(commit.image.height)")
        case .cancelled:
            Log.info("Capture session cancelled")
        case .failed(let error):
            Log.error("Capture session failed: \(error)")
        }
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
