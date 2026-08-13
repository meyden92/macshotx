import AppKit
import Testing
@testable import MacshotCore

@MainActor
private func makeImage(width: Int = 200, height: Int = 200) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 4 * width,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.gray.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// An overlay-mode view: requiresSelection, optionally starting with no
/// frozen image, hosted like the real capture overlay.
@MainActor
private func makeOverlayView(
    image: CGImage?
) -> (RegionPickerView, NSWindow) {
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let view = RegionPickerView(
        frame: frame,
        image: image,
        scale: 1.0
    )
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func key(
    _ char: String, _ keyCode: UInt16, _ window: NSWindow
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: keyCode
    )!
}

@MainActor
private func mouse(
    _ kind: NSEvent.EventType,
    at point: CGPoint,
    view: RegionPickerView,
    window: NSWindow
) -> NSEvent {
    let location = NSPoint(x: point.x, y: view.bounds.height - point.y)
    return NSEvent.mouseEvent(
        with: kind, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1.0
    )!
}

@MainActor
private func drag(
    from start: CGPoint, to end: CGPoint,
    view: RegionPickerView, window: NSWindow
) {
    view.mouseDown(with: mouse(.leftMouseDown, at: start, view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: end, view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: end, view: view, window: window))
}

// MARK: - Idle definition

@MainActor
@Test
func overlayStartsIdleAndLeavesIdleWithWork() {
    let (view, window) = makeOverlayView(image: makeImage())
    #expect(view.isIdle)

    // A committed selection is not idle.
    drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 90, y: 90), view: view, window: window)
    #expect(!view.isIdle)

    view.clearWholeSelection()
    #expect(view.isIdle)

    // An annotation is not idle either.
    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 80, y: 80), view: view, window: window)
    #expect(!view.isIdle)
}

// MARK: - Commit routing and the pending frozen image

@MainActor
@Test
func dragCommitRoutesThroughTheSessionInsteadOfBakingLocally() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    var bakedLocally = false
    view.onCommitRequested = { requested = $0 }
    view.onCommit = { _ in bakedLocally = true }

    drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60), view: view, window: window)
    view.keyDown(with: key("\r", 36, window))

    #expect(requested == NSRect(x: 10, y: 10, width: 100, height: 50))
    #expect(!bakedLocally)
}

@MainActor
@Test
func selectionSurvivesUntilTheImageArrivesAndThenBakes() {
    let (view, window) = makeOverlayView(image: nil)
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }

    #expect(!view.hasFrozenImage)
    #expect(view.bakedImage() == nil)

    // Selection drawn before any pixels exist.
    drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100), view: view, window: window)
    view.keyDown(with: key("\r", 36, window))
    let rect = requested
    #expect(rect == NSRect(x: 0, y: 0, width: 100, height: 100))

    // The image lands: the held rectangle bakes at full fidelity.
    view.installFrozenImage(makeImage())
    #expect(view.hasFrozenImage)
    let baked = rect.flatMap { view.bakedImage(croppingTo: $0) }
    #expect(baked?.width == 100)
    #expect(baked?.height == 100)
}

// MARK: - Overlay keys

@MainActor
@Test
func tabForwardsToTheSessionOnlyInOverlayMode() {
    let (view, window) = makeOverlayView(image: makeImage())
    var toggles = 0
    view.onTabPressed = { toggles += 1 }
    view.keyDown(with: key("\t", 48, window))
    #expect(toggles == 1)
}

@MainActor
@Test
func fullscreenKeyForwardsToTheSessionInOverlayMode() {
    let (view, window) = makeOverlayView(image: makeImage())
    var presses = 0
    view.onFullscreenKey = { presses += 1 }
    view.keyDown(with: key("f", 3, window))
    #expect(presses == 1)
}

@MainActor
@Test
func escapeDeselectsBeforeItCancels() {
    let (view, window) = makeOverlayView(image: makeImage())
    var cancelled = 0
    view.onCancel = { cancelled += 1 }

    // Draw and select an annotation.
    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 90, y: 90), view: view, window: window)
    view.keyDown(with: key("s", 1, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 60, y: 60), view: view, window: window))

    // First Escape deselects only; second cancels the capture.
    view.keyDown(with: key("\u{1b}", 53, window))
    #expect(cancelled == 0)
    view.keyDown(with: key("\u{1b}", 53, window))
    #expect(cancelled == 1)
}

// MARK: - Bare clicks

@MainActor
@Test
func idleClickWithSnapOffAsksTheSessionToSeedTheDisplay() {
    let (view, window) = makeOverlayView(image: makeImage())
    var idleClicks = 0
    view.onIdleClick = { idleClicks += 1 }

    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 50), view: view, window: window))
    #expect(idleClicks == 1)
}

@MainActor
@Test
func clickAfterAnnotationsDoesNotSeedTheDisplay() {
    let (view, window) = makeOverlayView(image: makeImage())
    var idleClicks = 0
    view.onIdleClick = { idleClicks += 1 }

    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 90, y: 90), view: view, window: window)
    view.keyDown(with: key("s", 1, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 150, y: 150), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 150, y: 150), view: view, window: window))
    #expect(idleClicks == 0)
}

@MainActor
@Test
func snapArmedClickAsksTheSessionToSeedTheHighlightedWindow() {
    let (view, window) = makeOverlayView(image: makeImage())
    let target = WindowCandidate(
        id: 42, frame: CGRect(x: 0, y: 0, width: 200, height: 200),
        bundleIdentifier: "com.example.app", applicationName: "App",
        title: "Doc", layer: 0, isOnScreen: true
    )
    var clicked: WindowCandidate?
    var idleClicks = 0
    view.onSnapClick = { clicked = $0 }
    view.onIdleClick = { idleClicks += 1 }
    view.onSnapHover = { _ in (target, NSRect(x: 0, y: 0, width: 200, height: 200)) }
    view.setSnapArmed(true)

    view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 50, y: 50), view: view, window: window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 50), view: view, window: window))

    #expect(clicked?.id == 42)
    #expect(idleClicks == 0)
}

@MainActor
@Test
func snapArmedClickWithNoCandidateDoesNothing() {
    let (view, window) = makeOverlayView(image: makeImage())
    var clicked = false
    var idleClicks = 0
    view.onSnapClick = { _ in clicked = true }
    view.onIdleClick = { idleClicks += 1 }
    view.onSnapHover = { _ in nil }
    view.setSnapArmed(true)

    view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 50, y: 50), view: view, window: window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 50), view: view, window: window))

    #expect(!clicked)
    #expect(idleClicks == 0)
}

@MainActor
@Test
func snapDisarmClearsTheHighlightAndDragStillSelects() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    view.onSnapHover = { _ in nil }
    view.setSnapArmed(true)

    // A drag with snap armed still produces a Region-style selection commit.
    drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60), view: view, window: window)
    view.keyDown(with: key("\r", 36, window))
    #expect(requested == NSRect(x: 10, y: 10, width: 50, height: 50))
}

// MARK: - Seeded selections

@MainActor
@Test
func seedingProducesASelectionAndCapturesNothingUntilItIsConfirmed() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    var activity: [Bool] = []
    view.onCommitRequested = { requested = $0 }
    view.onSelectionActivity = { activity.append($0) }

    // What `F` and a bare display click both come down to: the whole display.
    view.seedSelection(view.bounds)
    #expect(requested == nil, "Seeding must not capture")
    #expect(activity == [true], "The display owns the Selection now")
    // No longer idle, so `F` goes back to meaning the fill-rect tool.
    #expect(!view.isIdle)

    view.keyDown(with: key("\r", 36, window))
    #expect(requested == NSRect(x: 0, y: 0, width: 200, height: 200))
}

@MainActor
@Test
func aSeededSelectionMovesResizesAndAnnotatesLikeADraggedOne() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }

    // A window-snap-shaped seed, well inside the display.
    view.seedSelection(NSRect(x: 40, y: 40, width: 100, height: 100))

    // Grab the edge band (clear of the handles) and move it 10pt right and down.
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 110, y: 42), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 120, y: 52), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 120, y: 52), view: view, window: window))

    // Resize by its bottom-right corner handle.
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 150, y: 150), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 170, y: 170), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 170, y: 170), view: view, window: window))

    // And annotate inside it.
    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 70, y: 70), to: CGPoint(x: 110, y: 110), view: view, window: window)
    #expect(view.annotations.count == 1)

    view.keyDown(with: key("\r", 36, window))
    #expect(requested == NSRect(x: 50, y: 50, width: 120, height: 120))
}

@MainActor
@Test
func seedingIsClampedToTheDisplayAndIgnoredWhenItMissesEntirely() {
    let (view, _) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }

    // A window hanging off the right edge seeds only the part on this display.
    view.seedSelection(NSRect(x: 150, y: 20, width: 200, height: 60))
    view.keyDown(with: key("\r", 36, view.window!))
    #expect(requested == NSRect(x: 150, y: 20, width: 50, height: 60))

    // One that lies on another display entirely leaves this overlay idle.
    let (other, _) = makeOverlayView(image: makeImage())
    other.seedSelection(NSRect(x: 400, y: 400, width: 100, height: 100))
    #expect(other.isIdle)
}

@MainActor
@Test
func cancellingAfterSeedingCapturesNothing() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    var cancelled = 0
    view.onCommitRequested = { requested = $0 }
    view.onCancel = { cancelled += 1 }

    view.seedSelection(view.bounds)
    view.keyDown(with: key("\u{1b}", 53, window))
    #expect(cancelled == 1)
    #expect(requested == nil)
}

// MARK: - Idle helper card

@MainActor
@Test
func helperCardShowsWhileIdleAndFollowsTheSnapState() {
    let (view, window) = makeOverlayView(image: makeImage())
    var snapArmed = false
    view.helperCardContent = {
        HelperCard.content(snapArmed: snapArmed, suppressed: false)
    }

    view.viewWillDraw()
    #expect(view.helperCard != nil)
    let offStatus = view.helperCard?.content.status
    #expect(offStatus == "Window snap: OFF (Tab)")

    snapArmed = true
    view.viewWillDraw()
    #expect(view.helperCard?.content.status == "Window snap: ON (Tab)")

    // The card leaves as soon as the overlay is no longer idle...
    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 80, y: 80), view: view, window: window)
    view.viewWillDraw()
    #expect(view.helperCard == nil)

    // ...and returns when it is idle again: select the annotation and
    // delete it.
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 55, y: 30), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 55, y: 30), view: view, window: window))
    view.keyDown(with: key("\u{7f}", 51, window))
    view.viewWillDraw()
    #expect(view.helperCard != nil)
}

@MainActor
@Test
func suppressedHelperCardNeverAppears() {
    let (view, _) = makeOverlayView(image: makeImage())
    view.helperCardContent = {
        HelperCard.content(snapArmed: false, suppressed: true)
    }
    view.viewWillDraw()
    #expect(view.helperCard == nil)
}
