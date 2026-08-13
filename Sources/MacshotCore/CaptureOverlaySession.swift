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
        let mode: CaptureMode
        let appName: String?
        let windowTitle: String?
        let companionImage: CGImage?
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
    private var scWindowsByID: [UInt32: SCWindow] = [:]
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
            Task { [weak self] in
                await self?.performCommit(
                    on: held.display, route: held.route, payload: held.payload
                )
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
            self?.requestCommit(on: index, route: .dragSelection, payload: .drag(rect))
        }
        view.onCancel = { [weak self] in self?.cancelRequested() }
        view.onSelectionActivity = { [weak self] active in
            self?.selectionActivity(on: index, active: active)
        }
        view.onTabPressed = { [weak self] in self?.tabPressed() }
        view.onFullscreenKey = { [weak self] in self?.fullscreenKeyPressed() }
        view.onIdleClick = { [weak self] in
            // A click on an idle overlay must not fire while another display
            // holds the selection — a misclick would discard careful work
            // for a capture nobody asked for.
            guard let self, self.model.selectionOwner == nil else { return }
            self.requestCommit(on: index, route: .displayClick, payload: .wholeDisplay)
        }
        view.onSnapClick = { [weak self] candidate in
            self?.requestCommit(on: index, route: .windowSnap, payload: .window(candidate))
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

    /// `F`: fullscreen for the display under the cursor while that overlay is
    /// idle; in every other state it keeps selecting the fill-rect tool.
    private func fullscreenKeyPressed() {
        if let index = overlayIndexUnderCursor(), overlays[index].view.isIdle {
            requestCommit(on: index, route: .fullscreenKey, payload: .wholeDisplay)
            return
        }
        for overlay in overlays { overlay.view.adoptTool(.fillRect) }
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

    private func requestCommit(
        on index: Int, route: OverlayCommitRoute, payload: OverlayCommitPayload
    ) {
        switch model.requestCommit(on: index, route: route, payload: payload) {
        case .perform:
            Task { [weak self] in
                await self?.performCommit(on: index, route: route, payload: payload)
            }
        case .held, .ignored:
            break
        }
    }

    private func performCommit(
        on index: Int, route: OverlayCommitRoute, payload: OverlayCommitPayload
    ) async {
        guard overlays.indices.contains(index) else { return }
        let overlay = overlays[index]
        let commit: Commit?
        switch payload {
        case .drag(let rect):
            commit = overlay.view.bakedImage(croppingTo: rect).map {
                Commit(
                    image: $0, mode: route.captureMode,
                    appName: frontAppName, windowTitle: frontWindowTitle,
                    companionImage: nil,
                    mayContainTransparency: overlay.view.mayContainTransparency
                )
            }
        case .wholeDisplay:
            commit = overlay.view.bakedImage().map {
                Commit(
                    image: $0, mode: route.captureMode,
                    appName: frontAppName, windowTitle: frontWindowTitle,
                    companionImage: nil,
                    mayContainTransparency: overlay.view.mayContainTransparency
                )
            }
        case .window(let candidate):
            commit = await windowCommit(candidate, overlay: overlay)
        }
        if let commit {
            finish(.committed(commit))
        } else {
            finish(.failed(CaptureError.captureFailed(BakeFailedError())))
        }
    }

    /// Window snap: crop the frozen image (annotations baked) to the window,
    /// plus the best-effort shadow-free companion image for phase 6.
    private func windowCommit(
        _ candidate: WindowCandidate, overlay: Overlay
    ) async -> Commit? {
        let includeShadow = ConfigStore.shared.config.capture.includeWindowShadow
        let scWindow = scWindowsByID[candidate.id]

        var companion: CGImage?
        if let scWindow {
            do {
                companion = try await Self.captureSingleWindow(scWindow, ignoreShadows: true)
            } catch {
                Log.error("Window companion capture failed: \(error)")
            }
        }

        var shadowedBounds: CGRect?
        if includeShadow, let scWindow, let companion {
            shadowedBounds = await Self.probeShadowedBounds(
                of: scWindow, frame: candidate.frame, shadowFree: companion
            )
        }

        guard
            let cropRect = WindowCropGeometry.flatCropRect(
                windowFrame: candidate.frame,
                shadowedBounds: shadowedBounds,
                includeShadow: includeShadow,
                displayQuartzFrame: overlay.quartzFrame
            )
        else { return nil }
        // Beautify composites the clean window instead of the flat crop, so the
        // backdrop shows through its real corners. With beautify off the flat
        // capture is still what a window capture produces.
        overlay.view.setWindowCompanion(companion, for: cropRect)
        guard let image = overlay.view.bakedImage(croppingTo: cropRect) else { return nil }
        return Commit(
            image: image,
            mode: .window,
            appName: candidate.applicationName,
            windowTitle: candidate.title,
            companionImage: companion,
            mayContainTransparency: overlay.view.mayContainTransparency
        )
    }

    private static func captureSingleWindow(
        _ window: SCWindow, ignoreShadows: Bool
    ) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = ignoreShadows
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
    }

    /// Best-effort shadowed bounds: capture the window once with its shadow
    /// and compare opaque bounding boxes against the shadow-free companion —
    /// the margin arithmetic lives in WindowCropGeometry where it is tested.
    /// Snapshots are size-capped via PixelSnapshot and scanned off the main
    /// actor; nil on any surprise, and the flat crop falls back to the frame.
    private static func probeShadowedBounds(
        of window: SCWindow, frame: CGRect, shadowFree: CGImage
    ) async -> CGRect? {
        guard
            let shadowed = try? await captureSingleWindow(window, ignoreShadows: false),
            shadowed.width == shadowFree.width,
            shadowed.height == shadowFree.height,
            let shadowSnapshot = PixelSnapshot(image: shadowed),
            let freeSnapshot = PixelSnapshot(image: shadowFree)
        else { return nil }
        let boxes = await Task.detached(priority: .userInitiated) {
            (
                shadow: WindowCropGeometry.opaqueBoundingBox(of: shadowSnapshot),
                window: WindowCropGeometry.opaqueBoundingBox(of: freeSnapshot)
            )
        }.value
        guard let shadowBox = boxes.shadow, let windowBox = boxes.window else {
            return nil
        }
        return WindowCropGeometry.shadowedBounds(
            windowBox: windowBox, shadowBox: shadowBox, frame: frame
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
