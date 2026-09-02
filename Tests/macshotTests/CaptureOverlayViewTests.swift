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

// MARK: - Commit routing and the pending frozen image

@MainActor
@Test
func aDragCapturesOnReleaseThroughTheSessionInsteadOfBakingLocally() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    var bakedLocally = false
    view.onCommitRequested = { requested = $0 }
    view.onCommit = { _ in bakedLocally = true }

    drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60), view: view, window: window)

    #expect(requested == NSRect(x: 10, y: 10, width: 100, height: 50),
            "Releasing the drag is the capture; nothing waits for Return")
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

    // A region dragged before any pixels exist.
    drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100), view: view, window: window)
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

// MARK: - Click captures (ADR 0014)

@MainActor
private func click(at point: CGPoint, view: RegionPickerView, window: NSWindow) {
    view.mouseDown(with: mouse(.leftMouseDown, at: point, view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: point, view: view, window: window))
}

private let someWindow = WindowCandidate(
    id: 42, frame: CGRect(x: 0, y: 0, width: 200, height: 200),
    bundleIdentifier: "com.example.app", layer: 0, isOnScreen: true
)

@MainActor
@Test
func aClickOnEmptySpaceCapturesTheWholeDisplayImmediately() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    click(at: CGPoint(x: 50, y: 50), view: view, window: window)
    #expect(requested == NSRect(x: 0, y: 0, width: 200, height: 200))
}

@MainActor
@Test
func aClickOnAHighlightedWindowCapturesItClampedToTheDisplay() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    // A window hanging off the right edge.
    view.onSnapHover = { _ in (someWindow, NSRect(x: 150, y: 20, width: 200, height: 60)) }
    view.setSnapArmed(true)

    view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 160, y: 40), view: view, window: window))
    click(at: CGPoint(x: 160, y: 40), view: view, window: window)
    #expect(requested == NSRect(x: 150, y: 20, width: 50, height: 60))
}

@MainActor
@Test
func withSnapDisarmedTheSameClickCapturesTheDisplayInstead() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    view.onSnapHover = { _ in (someWindow, NSRect(x: 20, y: 20, width: 60, height: 60)) }
    view.setSnapArmed(false)

    click(at: CGPoint(x: 40, y: 40), view: view, window: window)
    #expect(requested == view.bounds, "Tab changes what a click captures, not whether it captures")
}

@MainActor
@Test
func aClickThatHitsAnAnnotationSelectsItAndTheNextClickClearsTheSetBeforeAnyCapture() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    view.onSnapHover = { _ in (someWindow, NSRect(x: 0, y: 0, width: 200, height: 200)) }
    view.setSnapArmed(true)

    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 90, y: 90), view: view, window: window)
    view.keyDown(with: key("s", 1, window))
    view.keyDown(with: key("\u{1b}", 53, window))  // deselect what was just drawn

    click(at: CGPoint(x: 60, y: 60), view: view, window: window)
    #expect(requested == nil, "Hitting the rectangle selects it")
    click(at: CGPoint(x: 150, y: 150), view: view, window: window)
    #expect(requested == nil, "The next click only clears the selected set")
    click(at: CGPoint(x: 150, y: 150), view: view, window: window)
    #expect(requested == NSRect(x: 0, y: 0, width: 200, height: 200),
            "and only from a clean canvas does a click capture the window")
}

@MainActor
@Test
func aClickWithADrawingToolInHandNeverCaptures() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    view.onSnapHover = { _ in (someWindow, NSRect(x: 0, y: 0, width: 200, height: 200)) }
    view.setSnapArmed(true)

    view.keyDown(with: key("r", 15, window))
    click(at: CGPoint(x: 50, y: 50), view: view, window: window)
    #expect(requested == nil)
    #expect(view.annotations.isEmpty)
}

@MainActor
@Test
func aClickWhileTypingCommitsTheTextInsteadOfCapturing() throws {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }

    // Place a label, then re-open it for editing with the select tool by
    // double-clicking it.
    view.keyDown(with: key("t", 17, window))
    click(at: CGPoint(x: 40, y: 40), view: view, window: window)
    try #require(view.subviews.compactMap { $0 as? InlineTextView }.first).string = "Label"
    view.keyDown(with: key("s", 1, window))
    #expect(view.annotations.count == 1)
    view.keyDown(with: key("\u{1b}", 53, window))
    let location = NSPoint(x: 48, y: view.bounds.height - 48)
    let doubleClick = NSEvent.mouseEvent(
        with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 2, pressure: 1.0
    )!
    view.mouseDown(with: doubleClick)
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 48, y: 48), view: view, window: window))
    #expect(view.isEditingText)

    click(at: CGPoint(x: 150, y: 150), view: view, window: window)
    #expect(!view.isEditingText, "The click ended the edit")
    #expect(requested == nil, "and did not fire the shutter")
    click(at: CGPoint(x: 150, y: 150), view: view, window: window)
    #expect(requested == view.bounds, "The next click, from a clean canvas, captures")
}

@MainActor
@Test
func enterWithNoSelectionAsksTheSessionForTheDisplayUnderTheCursor() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    var displayCaptures = 0
    view.onCommitRequested = { requested = $0 }
    view.onDisplayCaptureRequested = { displayCaptures += 1 }
    view.keyDown(with: key("\r", 36, window))
    #expect(displayCaptures == 1)
    #expect(requested == nil, "The session decides which display that is")
}

@MainActor
@Test
func fIsAlwaysTheFillRectTool() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    view.keyDown(with: key("f", 3, window))
    #expect(requested == nil, "F is not a fullscreen route")
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 60, y: 60), view: view, window: window)
    #expect(view.annotations.count == 1)
    if case .fillRect = view.annotations[0] {} else {
        Issue.record("F should have selected the fill-rect tool")
    }
}

@MainActor
@Test
func annotationsOutsideTheCapturedRectAreClippedAway() throws {
    let (view, window) = makeOverlayView(image: makeImage())
    view.keyDown(with: key("f", 3, window))
    drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30), view: view, window: window)
    drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 120), view: view, window: window)
    view.keyDown(with: key("s", 1, window))
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    drag(from: CGPoint(x: 80, y: 80), to: CGPoint(x: 140, y: 140), view: view, window: window)
    let image = try #require(baked)
    #expect(image.width == 60 && image.height == 60)
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    #expect(bytes[30 * image.bytesPerRow + 30 * 4] < 40, "The rect inside the crop is baked")
    #expect(bytes[5 * image.bytesPerRow + 5 * 4] > 100,
            "and the one outside it is gone without a trace")
}

// MARK: - Editing with a drawing tool in hand: click selects, drag draws

@MainActor
@Test
func withADrawingToolAClickSelectsAnElementADragDrawsOnTopAndASelectedElementDrags() {
    let (view, window) = makeOverlayView(image: makeImage())
    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 90, y: 90), view: view, window: window)
    view.keyDown(with: key("\u{1b}", 53, window))

    // A drag starting on the unselected rectangle draws a new one on top.
    drag(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 60, y: 60), view: view, window: window)
    #expect(view.annotations.count == 2)
    view.keyDown(with: key("\u{1b}", 53, window))

    // A bare click on the big rectangle selects it, placing nothing; Delete
    // then removes it.
    click(at: CGPoint(x: 85, y: 85), view: view, window: window)
    #expect(view.annotations.count == 2, "The click drew nothing")
    view.keyDown(with: key("\u{7f}", 51, window))
    #expect(view.annotations.count == 1, "It selected the rectangle under it")

    // Click the small one, then drag it: selected, it moves instead of drawing.
    click(at: CGPoint(x: 50, y: 50), view: view, window: window)
    drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 100, y: 100), view: view, window: window)
    #expect(view.annotations.count == 1, "The drag moved it rather than drawing")
    if case let .rectangle(rect, _) = view.annotations[0] {
        #expect(rect.origin == CGPoint(x: 90, y: 90), "moved by the drag delta")
    } else {
        Issue.record("Expected the rectangle")
    }
}

@MainActor
@Test
func aClickWithAPixelOfWobbleStillSelectsRatherThanDrawing() {
    let (view, window) = makeOverlayView(image: makeImage())
    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 90, y: 90), view: view, window: window)
    view.keyDown(with: key("\u{1b}", 53, window))

    // Down on the rectangle, a two-pixel wobble, up: a click, not a drawing.
    drag(from: CGPoint(x: 60, y: 60), to: CGPoint(x: 62, y: 61), view: view, window: window)
    #expect(view.annotations.count == 1, "The wobble drew nothing")
    view.keyDown(with: key("\u{7f}", 51, window))
    #expect(view.annotations.isEmpty, "and the click had selected the rectangle")
}

@MainActor
@Test
func shiftConstrainsAHandleDragOnASelectedLine() {
    let (view, window) = makeOverlayView(image: makeImage())
    view.keyDown(with: key("l", 37, window))
    drag(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 120, y: 100), view: view, window: window)
    // The line stays selected; drag its end handle up-and-right with Shift.
    let location = NSPoint(x: 160, y: view.bounds.height - 70)
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 120, y: 100), view: view, window: window))
    let shifted = NSEvent.mouseEvent(
        with: .leftMouseDragged, location: location, modifierFlags: [.shift], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
    )!
    view.mouseDragged(with: shifted)
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 160, y: 70), view: view, window: window))

    guard case let .line(from, to, _) = view.annotations[0] else {
        Issue.record("Expected the line")
        return
    }
    #expect(from == CGPoint(x: 20, y: 100))
    #expect(abs(to.x - 160) < 0.001 && abs(to.y - 100) < 0.001,
            "A nearly horizontal drag snaps flat onto the ray through the anchored end")
}

// MARK: - Tools live from the first frame (#59, ADR 0013)

@MainActor
@Test
func theOverlayOpensWithTheSelectToolActive() {
    let (view, _) = makeOverlayView(image: makeImage())
    let toolbar = view.subviews.compactMap { $0 as? RegionToolbarView }.first
    let active = toolbar?.subviews.compactMap { $0 as? ToolButton }.first { $0.isActive }
    #expect(active?.tool == .select)
}

@MainActor
@Test
func anAnnotationDrawnWithNoSelectionSurvivesIntoTheBakedImage() throws {
    let (view, window) = makeOverlayView(image: makeImage())
    view.keyDown(with: key("f", 3, window))
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 60, y: 60), view: view, window: window)
    #expect(view.annotations.count == 1)

    let baked = try #require(view.bakedImage())
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    #expect(bytes[45 * baked.bytesPerRow + 45 * 4] < 40, "The redaction is black in the bake")
    #expect(bytes[100 * baked.bytesPerRow + 100 * 4] > 100, "and the rest is the frozen screen")
}

// MARK: - Window snap highlight follows the select tool (#61)

/// The overlay's own paint at `point`, chrome hidden: (red, blue) so a blue
/// window highlight over the grey screen reads as blue > red.
@MainActor
private func paint(_ view: RegionPickerView, at point: CGPoint) throws -> (red: Int, blue: Int) {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplayWithoutChrome(to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let color = try #require(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
    return (Int((color.redComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
}

@MainActor
@Test
func theHighlightDrawsOnlyWhileTheSelectToolIsActiveAndComesBackWithoutMovingTheMouse() throws {
    let (view, window) = makeOverlayView(image: makeImage())
    view.onSnapHover = { _ in (someWindow, NSRect(x: 20, y: 20, width: 160, height: 160)) }
    view.setSnapArmed(true)
    view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 100, y: 100), view: view, window: window))

    let armed = try paint(view, at: CGPoint(x: 100, y: 100))
    #expect(armed.blue > armed.red + 10, "The window under the pointer is highlighted")

    view.keyDown(with: key("r", 15, window))
    let drawing = try paint(view, at: CGPoint(x: 100, y: 100))
    #expect(drawing.blue == drawing.red, "A drawing tool in hand draws no highlight")

    view.keyDown(with: key("s", 1, window))
    let back = try paint(view, at: CGPoint(x: 100, y: 100))
    #expect(back.blue > back.red + 10, "Back on the select tool the highlight returns, unprompted")
}
