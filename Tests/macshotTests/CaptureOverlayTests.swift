import CoreGraphics
import Foundation
import Testing
@testable import MacshotCore

// MARK: - Session model: selection ownership

@Test
func startingSelectionClearsTheOtherDisplaysSelection() {
    var model = CaptureSessionModel(displayCount: 3, snapArmed: false)
    #expect(model.startSelection(on: 0) == [])
    #expect(model.selectionOwner == 0)
    #expect(model.startSelection(on: 2) == [0])
    #expect(model.selectionOwner == 2)
    // Re-selecting on the owning display clears nothing.
    #expect(model.startSelection(on: 2) == [])
}

@Test
func clearingSelectionOnlyAffectsTheOwner() {
    var model = CaptureSessionModel(displayCount: 2, snapArmed: false)
    _ = model.startSelection(on: 1)
    model.clearSelection(on: 0)
    #expect(model.selectionOwner == 1)
    model.clearSelection(on: 1)
    #expect(model.selectionOwner == nil)
}

// MARK: - Session model: snap toggling

@Test
func tabTogglesSnapOnlyWhileNoSelectionExists() {
    var model = CaptureSessionModel(displayCount: 2, snapArmed: false)
    var changed = model.toggleSnap()
    #expect(changed)
    #expect(model.snapArmed)
    changed = model.toggleSnap()
    #expect(changed)
    #expect(!model.snapArmed)

    _ = model.startSelection(on: 0)
    changed = model.toggleSnap()
    #expect(!changed)
    #expect(!model.snapArmed)

    // Selection cleared: Tab works again.
    model.clearSelection(on: 0)
    changed = model.toggleSnap()
    #expect(changed)
    #expect(model.snapArmed)
}

// MARK: - Session model: pending images, held commits

@Test
func commitBeforeImageArrivesIsHeldThenPerformed() {
    var model = CaptureSessionModel(displayCount: 2, snapArmed: false)
    let rect = CGRect(x: 5, y: 5, width: 50, height: 40)
    #expect(model.requestCommit(on: 1, route: .dragSelection, payload: .drag(rect)) == .held)
    #expect(model.resolution == .pending)

    // Another display's image landing does not release the held commit.
    #expect(model.imageArrived(on: 0) == nil)
    #expect(model.resolution == .pending)

    let held = model.imageArrived(on: 1)
    #expect(held == CaptureSessionModel.HeldCommit(
        display: 1, route: .dragSelection, payload: .drag(rect)
    ))
    #expect(model.resolution == .committed)
}

@Test
func commitAfterImageArrivedPerformsImmediately() {
    var model = CaptureSessionModel(displayCount: 1, snapArmed: false)
    _ = model.imageArrived(on: 0)
    #expect(model.requestCommit(on: 0, route: .windowSnap, payload: .wholeDisplay) == .perform)
    #expect(model.resolution == .committed)
}

@Test
func cancelIsNeverHeld() {
    var model = CaptureSessionModel(displayCount: 2, snapArmed: false)
    #expect(model.cancel() == true)
    #expect(model.resolution == .cancelled)
    // No transition escapes a resolved session — a screenshot failure
    // routes through the same cancel.
    #expect(model.imageArrived(on: 0) == nil)
    #expect(model.requestCommit(on: 0, route: .dragSelection, payload: .wholeDisplay) == .ignored)
    let cancelledAgain = model.cancel()
    #expect(!cancelledAgain)
}

@Test
func cancelWinsOverAHeldCommit() {
    var model = CaptureSessionModel(displayCount: 1, snapArmed: false)
    #expect(model.requestCommit(on: 0, route: .dragSelection, payload: .wholeDisplay) == .held)
    let cancelled = model.cancel()
    #expect(cancelled)
    // The image landing later must not resurrect the held commit.
    #expect(model.imageArrived(on: 0) == nil)
    #expect(model.resolution == .cancelled)
}

@Test
func sessionResolvesExactlyOnce() {
    var model = CaptureSessionModel(displayCount: 1, snapArmed: false)
    _ = model.imageArrived(on: 0)
    #expect(model.requestCommit(on: 0, route: .dragSelection, payload: .wholeDisplay) == .perform)
    #expect(model.requestCommit(on: 0, route: .fullscreenKey, payload: .wholeDisplay) == .ignored)
    let cancelAfterCommit = model.cancel()
    #expect(!cancelAfterCommit)
    #expect(model.resolution == .committed)
}

// MARK: - Commit route → capture mode

@Test
func commitRoutesDeclareTheirCaptureModes() {
    #expect(OverlayCommitRoute.dragSelection.captureMode == .region)
    #expect(OverlayCommitRoute.windowSnap.captureMode == .window)
    #expect(OverlayCommitRoute.displayClick.captureMode == .fullscreen)
    #expect(OverlayCommitRoute.fullscreenKey.captureMode == .fullscreen)
}

@Test
func hotkeyActionDeterminesOnlyTheInitialSnapState() {
    #expect(HotkeyAction.captureRegion.overlayInitialSnapArmed == false)
    #expect(HotkeyAction.captureWindow.overlayInitialSnapArmed == true)
    #expect(HotkeyAction.captureFullscreen.overlayInitialSnapArmed == nil)
    #expect(HotkeyAction.colorPicker.overlayInitialSnapArmed == nil)
    #expect(HotkeyAction.magnifier.overlayInitialSnapArmed == nil)
}

// MARK: - Helper card content

@Test
func helperCardWordingFollowsTheSnapState() throws {
    let on = try #require(HelperCard.content(snapArmed: true, suppressed: false))
    let off = try #require(HelperCard.content(snapArmed: false, suppressed: false))
    #expect(on.instruction != off.instruction)
    #expect(on.instruction.contains("window"))
    #expect(on.instruction.contains("F for fullscreen"))
    #expect(off.instruction.contains("F for fullscreen"))
    #expect(on.status == "Window snap: ON (Tab)")
    #expect(off.status == "Window snap: OFF (Tab)")
}

@Test
func suppressedHelperCardProducesNothing() {
    #expect(HelperCard.content(snapArmed: true, suppressed: true) == nil)
    #expect(HelperCard.content(snapArmed: false, suppressed: true) == nil)
}

// MARK: - Settings round-trip for the suppression flag

@Test
func configWithoutOverlayHintsFlagDecodesToDefault() throws {
    let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
    #expect(config.capture.showOverlayHints)
}

@Test
func overlayHintsFlagRoundTrips() throws {
    var config = AppConfig()
    config.capture.showOverlayHints = false
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(!decoded.capture.showOverlayHints)
}

// MARK: - Window snap resolver

private func candidate(
    id: UInt32,
    _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
    bundle: String? = "com.example.app",
    layer: Int = 0,
    onScreen: Bool = true
) -> WindowCandidate {
    WindowCandidate(
        id: id,
        frame: CGRect(x: x, y: y, width: w, height: h),
        bundleIdentifier: bundle,
        applicationName: "App",
        title: "Window \(id)",
        layer: layer,
        isOnScreen: onScreen
    )
}

@Test
func topmostContainingWindowWins() {
    let front = candidate(id: 1, 100, 100, 400, 300)
    let back = candidate(id: 2, 0, 0, 900, 900)
    let hit = WindowSnapResolver.resolve(
        [front, back], at: CGPoint(x: 200, y: 200), ownBundleID: nil
    )
    #expect(hit?.id == 1)
    // Outside the front window, the one behind wins.
    let behind = WindowSnapResolver.resolve(
        [front, back], at: CGPoint(x: 700, y: 700), ownBundleID: nil
    )
    #expect(behind?.id == 2)
}

@Test
func fullyCoveredWindowIsNeverOffered() {
    let front = candidate(id: 1, 0, 0, 800, 600)
    let covered = candidate(id: 2, 100, 100, 200, 200)
    let back = candidate(id: 3, 0, 0, 2000, 2000)
    // Even a point only inside the covered window resolves to what covers it.
    let hit = WindowSnapResolver.resolve(
        [front, covered, back], at: CGPoint(x: 150, y: 150), ownBundleID: nil
    )
    #expect(hit?.id == 1)
}

@Test
func exactlyOverlappingFramesResolveToTheFrontOne() {
    let front = candidate(id: 1, 50, 50, 300, 300)
    let twin = candidate(id: 2, 50, 50, 300, 300)
    let hit = WindowSnapResolver.resolve(
        [front, twin], at: CGPoint(x: 60, y: 60), ownBundleID: nil
    )
    #expect(hit?.id == 1)
}

@Test
func resolverExcludesIneligibleWindows() {
    let own = candidate(id: 1, 0, 0, 500, 500, bundle: "com.example.macshot")
    let offScreen = candidate(id: 2, 0, 0, 500, 500, onScreen: false)
    let zeroArea = candidate(id: 3, 0, 0, 0, 0)
    let desktop = candidate(id: 4, 0, 0, 500, 500, layer: -2147483623)
    let statusBar = candidate(id: 5, 0, 0, 500, 500, layer: 25)
    let normal = candidate(id: 6, 0, 0, 500, 500)
    let hit = WindowSnapResolver.resolve(
        [own, offScreen, zeroArea, desktop, statusBar, normal],
        at: CGPoint(x: 10, y: 10),
        ownBundleID: "com.example.macshot"
    )
    #expect(hit?.id == 6)
}

@Test
func pointOverNothingResolvesToNothing() {
    let window = candidate(id: 1, 100, 100, 100, 100)
    let hit = WindowSnapResolver.resolve(
        [window], at: CGPoint(x: 900, y: 900), ownBundleID: nil
    )
    #expect(hit == nil)
}

@Test
func coveredWindowDoesNotShadowWhatIsBehindTheCoveringWindow() {
    // 2 is fully inside 1 (dropped); a point outside 1 but inside 3 must
    // still reach 3.
    let front = candidate(id: 1, 0, 0, 400, 400)
    let covered = candidate(id: 2, 10, 10, 100, 100)
    let back = candidate(id: 3, 0, 0, 1000, 1000)
    let hit = WindowSnapResolver.resolve(
        [front, covered, back], at: CGPoint(x: 600, y: 600), ownBundleID: nil
    )
    #expect(hit?.id == 3)
}

// MARK: - Flat window crop geometry

@Test
func cropRectConvertsGlobalFrameIntoDisplaySpace() {
    // Secondary display sitting to the right of a 1920×1080 primary.
    let display = CGRect(x: 1920, y: 200, width: 1440, height: 900)
    let window = CGRect(x: 2000, y: 300, width: 600, height: 400)
    let crop = WindowCropGeometry.flatCropRect(
        windowFrame: window,
        shadowedBounds: nil,
        includeShadow: false,
        displayQuartzFrame: display
    )
    #expect(crop == CGRect(x: 80, y: 100, width: 600, height: 400))
}

@Test
func cropExpandsToShadowedBoundsOnlyWhenTheSettingIsOn() {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let window = CGRect(x: 500, y: 400, width: 400, height: 300)
    let shadowed = window.insetBy(dx: -40, dy: -40)

    let withShadow = WindowCropGeometry.flatCropRect(
        windowFrame: window,
        shadowedBounds: shadowed,
        includeShadow: true,
        displayQuartzFrame: display
    )
    #expect(withShadow == CGRect(x: 460, y: 360, width: 480, height: 380))

    let withoutShadow = WindowCropGeometry.flatCropRect(
        windowFrame: window,
        shadowedBounds: shadowed,
        includeShadow: false,
        displayQuartzFrame: display
    )
    #expect(withoutShadow == CGRect(x: 500, y: 400, width: 400, height: 300))
}

@Test
func cropFallsBackToTheFrameWhenShadowedBoundsAreMissingOrNonsense() {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let window = CGRect(x: 500, y: 400, width: 400, height: 300)

    let missing = WindowCropGeometry.flatCropRect(
        windowFrame: window,
        shadowedBounds: nil,
        includeShadow: true,
        displayQuartzFrame: display
    )
    #expect(missing == window)

    // Shadowed bounds that do not enclose the frame are rejected.
    let nonsense = WindowCropGeometry.flatCropRect(
        windowFrame: window,
        shadowedBounds: CGRect(x: 600, y: 500, width: 100, height: 100),
        includeShadow: true,
        displayQuartzFrame: display
    )
    #expect(nonsense == window)
}

@Test
func shadowedBoundsExpandTheFramePerEdge() {
    // Window occupies a 100×80 px box inside the capture; the shadowed box
    // is 20 px wider on each side, 10 above, 30 below, at 2 px per point
    // (frame is 50×40 points).
    let bounds = WindowCropGeometry.shadowedBounds(
        windowBox: CGRect(x: 40, y: 20, width: 100, height: 80),
        shadowBox: CGRect(x: 20, y: 10, width: 140, height: 120),
        frame: CGRect(x: 500, y: 300, width: 50, height: 40)
    )
    #expect(bounds == CGRect(x: 490, y: 295, width: 70, height: 60))
}

@Test
func degenerateShadowBoxesProduceNoBounds() {
    let frame = CGRect(x: 0, y: 0, width: 50, height: 40)
    // Identical boxes: no shadow margin measured.
    #expect(WindowCropGeometry.shadowedBounds(
        windowBox: CGRect(x: 0, y: 0, width: 100, height: 80),
        shadowBox: CGRect(x: 0, y: 0, width: 100, height: 80),
        frame: frame
    ) == nil)
    // A "shadow" box smaller than the window box is nonsense.
    #expect(WindowCropGeometry.shadowedBounds(
        windowBox: CGRect(x: 0, y: 0, width: 100, height: 80),
        shadowBox: CGRect(x: 10, y: 10, width: 50, height: 50),
        frame: frame
    ) == nil)
}

@Test
func opaqueBoundingBoxFindsTheOpaqueRegion() throws {
    let width = 20, height = 10
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 4 * width,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Opaque block at x 4..<12, and (in bottom-up context coords) y 2..<7 —
    // raster rows counted from the top are 3..<8.
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 4, y: 2, width: 8, height: 5))
    let image = ctx.makeImage()!
    let snapshot = try #require(PixelSnapshot(image: image))
    let box = WindowCropGeometry.opaqueBoundingBox(of: snapshot)
    #expect(box == CGRect(x: 4, y: 3, width: 8, height: 5))

    let empty = CGContext(
        data: nil, width: 4, height: 4,
        bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!.makeImage()!
    let emptySnapshot = try #require(PixelSnapshot(image: empty))
    #expect(WindowCropGeometry.opaqueBoundingBox(of: emptySnapshot) == nil)
}

@Test
func cropIsClampedToTheDisplayAndNilWhenOutside() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let hangingOff = WindowCropGeometry.flatCropRect(
        windowFrame: CGRect(x: 900, y: 700, width: 400, height: 300),
        shadowedBounds: nil,
        includeShadow: false,
        displayQuartzFrame: display
    )
    #expect(hangingOff == CGRect(x: 900, y: 700, width: 100, height: 100))

    let outside = WindowCropGeometry.flatCropRect(
        windowFrame: CGRect(x: 2000, y: 0, width: 400, height: 300),
        shadowedBounds: nil,
        includeShadow: false,
        displayQuartzFrame: display
    )
    #expect(outside == nil)
}
