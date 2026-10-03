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
    image: CGImage?, showOverlayHints: Bool = true
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
        scale: 1.0,
        showOverlayHints: showOverlayHints
    )
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func key(
    _ char: String, _ keyCode: UInt16, _ window: NSWindow,
    flags: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
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

@MainActor
private func click(at point: CGPoint, view: RegionPickerView, window: NSWindow) {
    view.mouseDown(with: mouse(.leftMouseDown, at: point, view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: point, view: view, window: window))
}

@MainActor
private func toolbar(of view: RegionPickerView) -> RegionToolbarView? {
    view.subviews.compactMap { $0 as? RegionToolbarView }.first
}

@MainActor
private func activeTool(of view: RegionPickerView) -> Tool? {
    toolbar(of: view)?.subviews.compactMap { $0 as? ToolButton }.first { $0.isActive }?.tool
}

private let someWindow = WindowCandidate(
    id: 42, frame: CGRect(x: 0, y: 0, width: 200, height: 200),
    bundleIdentifier: "com.example.app", layer: 0, isOnScreen: true
)

// MARK: - The idle state (ADR 0016)

@MainActor
@Test
func theOverlayOpensIdleWithTheHelperCardTheSelectToolAndNoToolStrip() {
    let (view, _) = makeOverlayView(image: makeImage())
    #expect(view.isIdle)
    view.viewWillDraw()
    #expect(view.helperCard != nil)
    #expect(toolbar(of: view)?.isHidden == true, "No tools before there is a Selection")
    #expect(activeTool(of: view) == .select)
}

@MainActor
@Test
func theHelperCardFollowsTheSnapStateAndTheHintsSetting() {
    let (view, _) = makeOverlayView(image: makeImage())
    view.setSnapArmed(true)
    view.viewWillDraw()
    #expect(view.helperCard?.content.status == "Window snap: ON (Tab)")
    view.setSnapArmed(false)
    view.viewWillDraw()
    #expect(view.helperCard?.content.status == "Window snap: OFF (Tab)")

    let (quiet, _) = makeOverlayView(image: makeImage(), showOverlayHints: false)
    quiet.viewWillDraw()
    #expect(quiet.helperCard == nil)
}

@MainActor
@Test
func toolShortcutsAreInertWhileIdleSoADragAlwaysDrawsASelection() {
    let (view, window) = makeOverlayView(image: makeImage())
    view.keyDown(with: key("r", 15, window))
    #expect(activeTool(of: view) == .select)
    drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 90, y: 90), view: view, window: window)
    #expect(view.annotations.isEmpty, "The drag drew a Selection, not a rectangle")
    #expect(!view.isIdle)
}

@MainActor
@Test
func aToolChosenOnAnotherDisplayIsNotAdoptedWhileIdle() {
    let (view, window) = makeOverlayView(image: makeImage())
    view.adoptTool(.rectangle)
    #expect(activeTool(of: view) == .select)
    drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 90, y: 90), view: view, window: window)
    #expect(view.annotations.isEmpty)
}

// MARK: - Seeding routes: none of them capture

@MainActor
@Test
func aDragDrawsAnAdjustableSelectionAndReleasingCapturesNothing() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    var activity: [Bool] = []
    view.onCommitRequested = { requested = $0 }
    view.onSelectionActivity = { activity.append($0) }

    drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60), view: view, window: window)
    #expect(requested == nil, "Releasing the drag only made the Selection")
    #expect(activity.last == true, "and this display owns it")
    view.viewWillDraw()
    #expect(view.helperCard == nil)
    #expect(toolbar(of: view)?.isHidden == false, "The tools come up around it")
}

@MainActor
@Test
func aBareClickOnEmptySpaceCapturesNothingAndStaysIdle() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    view.onSnapHover = { _ in nil }
    view.setSnapArmed(true)
    click(at: CGPoint(x: 50, y: 50), view: view, window: window)
    #expect(requested == nil)
    #expect(view.isIdle)
}

@MainActor
@Test
func withSnapArmedAClickOnAWindowSeedsTheSelectionToItClampedToTheDisplay() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    // A window hanging off the right edge.
    view.onSnapHover = { _ in (someWindow, NSRect(x: 150, y: 20, width: 200, height: 60)) }
    view.setSnapArmed(true)

    click(at: CGPoint(x: 160, y: 40), view: view, window: window)
    #expect(requested == nil, "Seeding never captures")
    #expect(!view.isIdle)

    view.keyDown(with: key("\r", 36, window))
    #expect(requested == NSRect(x: 150, y: 20, width: 50, height: 60))
}

@MainActor
@Test
func withSnapDisarmedAClickOnAWindowDoesNothing() {
    let (view, window) = makeOverlayView(image: makeImage())
    view.onSnapHover = { _ in (someWindow, NSRect(x: 20, y: 20, width: 60, height: 60)) }
    view.setSnapArmed(false)
    click(at: CGPoint(x: 40, y: 40), view: view, window: window)
    #expect(view.isIdle)
}

@MainActor
@Test
func fWhileIdleSelectsTheWholeDisplayAndWithASelectionUpItIsTheFillRectTool() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    var activity: [Bool] = []
    view.onCommitRequested = { requested = $0 }
    view.onSelectionActivity = { activity.append($0) }

    view.keyDown(with: key("f", 3, window))
    #expect(requested == nil, "F seeds; it does not capture")
    #expect(activity == [true])
    #expect(activeTool(of: view) == .select)

    view.keyDown(with: key("f", 3, window))
    #expect(activeTool(of: view) == .fillRect)
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 60, y: 60), view: view, window: window)
    if case .fillRect = view.annotations.first {} else {
        Issue.record("F should have selected the fill-rect tool")
    }

    view.keyDown(with: key("\r", 36, window))
    #expect(requested == view.bounds)
}

@MainActor
@Test
func aSeededSelectionMovesResizesAndAnnotatesLikeADraggedOne() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    view.onSnapHover = { _ in (someWindow, NSRect(x: 40, y: 40, width: 100, height: 100)) }
    view.setSnapArmed(true)
    click(at: CGPoint(x: 90, y: 90), view: view, window: window)

    // Grab the edge band (clear of the handles) and move it 10pt right and down.
    drag(from: CGPoint(x: 110, y: 42), to: CGPoint(x: 120, y: 52), view: view, window: window)
    // Resize by its bottom-right corner handle.
    drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 170, y: 170), view: view, window: window)
    // And annotate inside it.
    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 70, y: 70), to: CGPoint(x: 110, y: 110), view: view, window: window)
    #expect(view.annotations.count == 1)

    view.keyDown(with: key("\r", 36, window))
    #expect(requested == NSRect(x: 50, y: 50, width: 120, height: 120))
}

@MainActor
@Test
func aClickOutsideTheSelectionDismissesItAndTheOverlayIsIdleAgain() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }
    drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 90, y: 90), view: view, window: window)

    click(at: CGPoint(x: 150, y: 150), view: view, window: window)
    #expect(view.isIdle)
    view.viewWillDraw()
    #expect(view.helperCard != nil)
    #expect(toolbar(of: view)?.isHidden == true)
    view.keyDown(with: key("\r", 36, window))
    #expect(requested == nil, "Dismissing captures nothing, and neither does Return without a Selection")
}

@MainActor
@Test
func anotherDisplayTakingTheSelectionLeavesThisOneIdleWithOnlyTheSelectTool() {
    let (view, window) = makeOverlayView(image: makeImage())
    view.selectWholeDisplay()
    view.keyDown(with: key("r", 15, window))
    view.keyDown(with: key("b", 11, window, flags: .option))
    #expect(view.isBeautifying)

    view.clearWholeSelection()
    #expect(view.isIdle)
    #expect(activeTool(of: view) == .select)
    #expect(!view.isBeautifying, "Post-processing has no Selection left to preview")
    drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 90, y: 90), view: view, window: window)
    #expect(view.annotations.isEmpty, "A drag draws a Selection again")
}

// MARK: - Window provenance (ADR 0018)

private let xcodeWindow = WindowCandidate(
    id: 7, frame: CGRect(x: 40, y: 40, width: 100, height: 100),
    bundleIdentifier: "com.apple.dt.Xcode", applicationName: "Xcode", title: "Main.swift",
    layer: 0, isOnScreen: true
)

@MainActor
private func resolutionBox(of view: RegionPickerView) -> ResolutionBoxView? {
    view.subviews.compactMap { $0 as? ResolutionBoxView }.first
}

/// An overlay whose Selection window snap seeded to `xcodeWindow`.
@MainActor
private func snappedToXcode() -> (RegionPickerView, NSWindow) {
    let (view, window) = makeOverlayView(image: makeImage())
    view.onSnapHover = { _ in (xcodeWindow, NSRect(x: 40, y: 40, width: 100, height: 100)) }
    view.setSnapArmed(true)
    click(at: CGPoint(x: 90, y: 90), view: view, window: window)
    return (view, window)
}

@MainActor
@Test
func aWindowSnappedSelectionCarriesItsWindowAndSaysSoBesideTheResolutionBox() {
    var seeded: WindowCandidate?
    let (view, window) = makeOverlayView(image: makeImage())
    view.onWindowSeeded = { seeded = $0 }
    view.onSnapHover = { _ in (xcodeWindow, NSRect(x: 40, y: 40, width: 100, height: 100)) }
    view.setSnapArmed(true)
    click(at: CGPoint(x: 90, y: 90), view: view, window: window)

    #expect(view.windowProvenance == xcodeWindow)
    #expect(seeded == xcodeWindow, "The session is told, so it can capture the companion")
    #expect(resolutionBox(of: view)?.provenance == "Xcode — Main.swift")
}

@MainActor
@Test
func everyEditToTheSelectionDropsItsWindowAndTheIndicatorWithIt() {
    let edits: [(String, (RegionPickerView, NSWindow) -> Void)] = [
        ("move", { view, window in
            drag(from: CGPoint(x: 110, y: 42), to: CGPoint(x: 120, y: 52), view: view, window: window)
        }),
        ("resize", { view, window in
            drag(from: CGPoint(x: 140, y: 140), to: CGPoint(x: 160, y: 160), view: view, window: window)
        }),
        ("nudge", { view, window in
            view.keyDown(with: key("\u{F703}", 124, window))
        }),
        ("typed size", { view, _ in
            resolutionBox(of: view)?.onSizeCommitted?(120, nil)
        }),
        ("aspect lock", { view, window in
            resolutionBox(of: view)?.onPresetsTapped?()
            let panel = view.subviews.compactMap { $0 as? PresetsPanelView }.first
            let row = panel?.subviews.compactMap { $0 as? PresetRowButton }.first { $0.title == "16:9" }
            row?.mouseDown(with: mouse(.leftMouseDown, at: .zero, view: view, window: window))
        }),
    ]
    for (name, edit) in edits {
        let (view, window) = snappedToXcode()
        #expect(view.windowProvenance != nil)
        edit(view, window)
        #expect(view.windowProvenance == nil, "\(name) makes it a plain area")
        #expect(resolutionBox(of: view)?.provenance == nil, "\(name) hides the indicator")
    }
}

@MainActor
@Test
func aClickInsideTheSelectionIsNoEditAndKeepsItsWindow() {
    let (view, window) = snappedToXcode()
    click(at: CGPoint(x: 90, y: 90), view: view, window: window)
    #expect(view.windowProvenance == xcodeWindow)
}

@MainActor
@Test
func draggedFullscreenAndClampedSelectionsCarryNoWindow() {
    let (dragged, draggedWindow) = makeOverlayView(image: makeImage())
    drag(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 140, y: 140), view: dragged, window: draggedWindow)
    #expect(dragged.windowProvenance == nil)

    let (fullscreen, fullscreenWindow) = makeOverlayView(image: makeImage())
    fullscreen.keyDown(with: key("f", 3, fullscreenWindow))
    #expect(fullscreen.windowProvenance == nil)
    #expect(resolutionBox(of: fullscreen)?.provenance == nil)

    // Hanging off the display, the Selection is only part of the window.
    let (clamped, clampedWindow) = makeOverlayView(image: makeImage())
    clamped.onSnapHover = { _ in (xcodeWindow, NSRect(x: 150, y: 20, width: 200, height: 60)) }
    clamped.setSnapArmed(true)
    click(at: CGPoint(x: 160, y: 40), view: clamped, window: clampedWindow)
    #expect(!clamped.isIdle)
    #expect(clamped.windowProvenance == nil)
}

@MainActor
@Test
func dismissingAndDrawingANewSelectionLeavesNoWindowBehind() {
    let (view, window) = snappedToXcode()
    click(at: CGPoint(x: 180, y: 180), view: view, window: window)
    #expect(view.isIdle)
    #expect(view.windowProvenance == nil)
}

// MARK: - Committing: Return, and only Return

@MainActor
@Test
func returnConfirmsThroughTheSessionInsteadOfBakingLocally() {
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
func returnWithNoSelectionDoesNothing() {
    let (view, window) = makeOverlayView(image: makeImage())
    var requested: NSRect?
    var baked: CGImage?
    view.onCommitRequested = { requested = $0 }
    view.onCommit = { baked = $0 }
    view.keyDown(with: key("\r", 36, window))
    #expect(requested == nil)
    #expect(baked == nil)
}

@MainActor
@Test
func selectionSurvivesUntilTheImageArrivesAndThenBakes() {
    let (view, window) = makeOverlayView(image: nil)
    var requested: NSRect?
    view.onCommitRequested = { requested = $0 }

    #expect(!view.hasFrozenImage)
    #expect(view.bakedImage() == nil)

    // Selection drawn and confirmed before any pixels exist.
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

@MainActor
@Test
func annotationsOutsideTheSelectionAreClippedAway() throws {
    let (view, window) = makeOverlayView(image: makeImage())
    drag(from: CGPoint(x: 80, y: 80), to: CGPoint(x: 140, y: 140), view: view, window: window)
    view.keyDown(with: key("f", 3, window))
    drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30), view: view, window: window)
    drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 120), view: view, window: window)
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: key("\r", 36, window))
    let image = try #require(baked)
    #expect(image.width == 60 && image.height == 60)
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    #expect(bytes[30 * image.bytesPerRow + 30 * 4] < 40, "The rect inside the Selection is baked")
    #expect(bytes[5 * image.bytesPerRow + 5 * 4] > 100,
            "and the one outside it is gone without a trace")
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
    view.selectWholeDisplay()
    view.keyDown(with: key("r", 15, window))
    drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 90, y: 90), view: view, window: window)
    view.keyDown(with: key("s", 1, window))
    click(at: CGPoint(x: 60, y: 60), view: view, window: window)

    // First Escape deselects only; second cancels the capture.
    view.keyDown(with: key("\u{1b}", 53, window))
    #expect(cancelled == 0)
    view.keyDown(with: key("\u{1b}", 53, window))
    #expect(cancelled == 1)
}

// MARK: - Editing with a drawing tool in hand: click selects, drag draws

@MainActor
@Test
func withADrawingToolAClickSelectsAnElementADragDrawsOnTopAndASelectedElementDrags() {
    let (view, window) = makeOverlayView(image: makeImage())
    view.selectWholeDisplay()
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
    view.selectWholeDisplay()
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
    view.selectWholeDisplay()
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

// MARK: - Window snap highlight (idle only)

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
func theHighlightDrawsWhileIdleGoesWithTheSelectionAndComesBackWithoutMovingTheMouse() throws {
    let (view, window) = makeOverlayView(image: makeImage())
    view.onSnapHover = { _ in (someWindow, NSRect(x: 20, y: 20, width: 160, height: 160)) }
    view.setSnapArmed(true)
    view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 100, y: 100), view: view, window: window))

    let idle = try paint(view, at: CGPoint(x: 100, y: 100))
    #expect(idle.blue > idle.red + 10, "The window under the pointer is highlighted")

    view.selectWholeDisplay()
    let selected = try paint(view, at: CGPoint(x: 100, y: 100))
    #expect(selected.blue == selected.red, "A Selection leaves the highlight nothing to offer")

    view.clearWholeSelection()
    let back = try paint(view, at: CGPoint(x: 100, y: 100))
    #expect(back.blue > back.red + 10, "Idle again, the highlight returns, unprompted")
}
