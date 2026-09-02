import AppKit
import Testing
@testable import MacshotCore

// Overlay-level rotation tests: the handle is grabbed with synthesised events
// and the result is read back out of the baked image, so what is asserted is
// what the user would have saved. The rotation maths itself is covered at the
// annotation-geometry seam.

@MainActor
private func makeSourceImage(width: Int, height: Int) -> CGImage {
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

/// A 200×200-point overlay over a source image of `scale` pixels per point.
@MainActor
private func makeHostedView(scale: CGFloat = 1.0) -> (RegionPickerView, NSWindow) {
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let pixels = Int(200 * scale)
    let view = RegionPickerView(
        frame: frame,
        image: makeSourceImage(width: pixels, height: pixels),
        scale: scale,
        requiresSelection: false
    )
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func keyEvent(_ char: String, keyCode: UInt16, window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: keyCode
    )!
}

@MainActor
private func mouseEvent(
    _ kind: NSEvent.EventType,
    atViewPoint point: CGPoint,
    in view: RegionPickerView,
    window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    // The view is flipped (top-left). Convert top-left view point → window coords.
    let windowLocation = NSPoint(x: point.x, y: view.bounds.height - point.y)
    return NSEvent.mouseEvent(
        with: kind, location: windowLocation, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1.0
    )!
}

/// A drag reported over several ticks, so a per-tick recording bug has room to
/// show itself in the undo stack.
@MainActor
private func drag(
    in view: RegionPickerView,
    window: NSWindow,
    from: CGPoint,
    to: CGPoint,
    modifiers: NSEvent.ModifierFlags = [],
    ticks: Int = 1
) {
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: from, in: view, window: window))
    for tick in 1...ticks {
        let t = CGFloat(tick) / CGFloat(ticks)
        let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        view.mouseDragged(with: mouseEvent(
            .leftMouseDragged, atViewPoint: point, in: view, window: window, modifiers: modifiers
        ))
    }
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: to, in: view, window: window))
}

@MainActor
private func click(in view: RegionPickerView, window: NSWindow, at point: CGPoint) {
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: point, in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: point, in: view, window: window))
}

@MainActor
private func undoKey(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
    )!)
}

private let cropOrigin = CGPoint(x: 10, y: 10)

/// Selects (10,10)–(150,150) with the select tool and confirms via Return.
@MainActor
private func bake(_ view: RegionPickerView, _ window: NSWindow) -> CGImage? {
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    drag(in: view, window: window, from: cropOrigin, to: CGPoint(x: 150, y: 150))
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    return baked
}

/// Red channel of the baked pixel a view point maps to. Gray source reads high,
/// the black fill rect reads low.
@MainActor
private func redAt(_ baked: CGImage, viewPoint: CGPoint, scale: CGFloat) -> UInt8 {
    let data = baked.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    let x = Int((viewPoint.x - cropOrigin.x) * scale)
    let y = Int((viewPoint.y - cropOrigin.y) * scale)
    return bytes[y * baked.bytesPerRow + x * 4]
}

/// Draws a black 70×20 fill rect at (40,60)–(110,80) and selects it. Its centre
/// is (75,70) and its rotation handle sits at (75,38).
@MainActor
private func placeWideFillRect(in view: RegionPickerView, window: NSWindow) {
    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 60), to: CGPoint(x: 110, y: 80))
    // Grabbing the rotation knob is the select tool's job; a drag with the
    // fill tool still active would draw another rect.
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    click(in: view, window: window, at: CGPoint(x: 75, y: 70))
}

private let rotationKnob = CGPoint(x: 75, y: 38)
/// Straight out to the right of the centre: a clean quarter turn.
private let quarterTurnPointer = CGPoint(x: 150, y: 70)
/// Inside the quarter-turned rect, outside the rect as it was drawn.
private let onlyWhenTurned = CGPoint(x: 75, y: 45)
/// Inside the rect as drawn, outside the quarter-turned one.
private let onlyWhenStraight = CGPoint(x: 45, y: 70)

// MARK: - Rotation in the baked image

@MainActor
@Test(arguments: [CGFloat(1.0), CGFloat(2.0)])
func aRotatedAnnotationBakesRotated(scale: CGFloat) {
    let (view, window) = makeHostedView(scale: scale)
    placeWideFillRect(in: view, window: window)

    drag(in: view, window: window, from: rotationKnob, to: quarterTurnPointer)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: onlyWhenTurned, scale: scale) < 60,
            "The turned rect should cover what it now spans at scale \(scale)")
    #expect(redAt(baked, viewPoint: onlyWhenStraight, scale: scale) > 100,
            "Where the rect used to be should be source gray again at scale \(scale)")
}

// MARK: - Shift snapping through the overlay

@MainActor
@Test
func shiftDuringARotationDragSnapsToAQuarterTurn() {
    let (view, window) = makeHostedView()
    placeWideFillRect(in: view, window: window)

    // A pointer at roughly 115° — near enough a quarter turn to snap to it, far
    // enough that the unsnapped angle would leave the sampled pixel uncovered.
    drag(
        in: view, window: window,
        from: rotationKnob, to: CGPoint(x: 166, y: 112),
        modifiers: .shift
    )

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: onlyWhenTurned, scale: 1) < 60,
            "The rect should have turned")
    // 33pt along the long axis from the centre: covered at exactly 90°, off the
    // end of the rect at the unsnapped 115°.
    #expect(redAt(baked, viewPoint: CGPoint(x: 75, y: 103), scale: 1) < 60,
            "Shift should have snapped the drag to an exact quarter turn")
}

// MARK: - Undo

@MainActor
@Test
func undoOfARotationRestoresThePreviousAngle() {
    let (view, window) = makeHostedView()
    placeWideFillRect(in: view, window: window)

    drag(in: view, window: window, from: rotationKnob, to: quarterTurnPointer, ticks: 5)
    undoKey(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: onlyWhenStraight, scale: 1) < 60,
            "Undo should put the rect back the way it was drawn")
    #expect(redAt(baked, viewPoint: onlyWhenTurned, scale: 1) > 100,
            "Nothing should be left where the turned rect was")
}

@MainActor
@Test
func aWholeRotationDragIsOneUndoEntry() {
    let (view, window) = makeHostedView()
    placeWideFillRect(in: view, window: window)

    drag(in: view, window: window, from: rotationKnob, to: quarterTurnPointer, ticks: 5)

    // The discriminating assertion: one undo for the drag, one for the draw. If
    // the intermediate angles were each recorded, the second undo would still be
    // walking back through them and the rect would still be on the canvas.
    undoKey(view, window)
    undoKey(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: onlyWhenStraight, scale: 1) > 100,
            "Two undos should remove the rect entirely")
    #expect(redAt(baked, viewPoint: onlyWhenTurned, scale: 1) > 100,
            "Two undos should remove the rect entirely")
}
