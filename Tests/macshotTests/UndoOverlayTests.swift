import AppKit
import Testing
@testable import MacshotCore

// Overlay-level undo tests: prove the wiring between the capture overlay and
// the annotation document through synthesised events and baked-pixel sampling.
// The undo semantics themselves are covered at the document seam.

@MainActor
private func makeSourceImage(width: Int = 200, height: Int = 200) -> CGImage {
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

@MainActor
private func makeHostedView(width: Int = 200, height: Int = 200) -> (RegionPickerView, NSWindow) {
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let view = RegionPickerView(frame: frame, image: makeSourceImage(width: width, height: height), scale: 1.0, requiresSelection: false)
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func keyEvent(
    _ char: String,
    keyCode: UInt16,
    window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: char,
        charactersIgnoringModifiers: char,
        isARepeat: false,
        keyCode: keyCode
    )!
}

@MainActor
private func mouseEvent(
    _ kind: NSEvent.EventType,
    atViewPoint point: CGPoint,
    in view: RegionPickerView,
    window: NSWindow
) -> NSEvent {
    // The view is flipped (top-left). Convert top-left view point → window (bottom-left) coords.
    let windowLocation = NSPoint(x: point.x, y: view.bounds.height - point.y)
    return NSEvent.mouseEvent(
        with: kind,
        location: windowLocation,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1.0
    )!
}

@MainActor
private func drag(
    in view: RegionPickerView,
    window: NSWindow,
    from: CGPoint,
    to: CGPoint
) {
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: from, in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: to, in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: to, in: view, window: window))
}

@MainActor
private func click(in view: RegionPickerView, window: NSWindow, at point: CGPoint) {
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: point, in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: point, in: view, window: window))
}

@MainActor
private func undoKey(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: keyEvent("z", keyCode: 6, window: window, modifiers: [.command]))
}

@MainActor
private func redoKey(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: keyEvent("z", keyCode: 6, window: window, modifiers: [.command, .shift]))
}

/// Selects (10,10)–(150,150) with the select tool and confirms via Return.
@MainActor
private func bake(_ view: RegionPickerView, _ window: NSWindow) -> CGImage? {
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    drag(in: view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 150, y: 150))
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    return baked
}

/// Red channel of the baked pixel that a view point maps to, given the
/// (10,10) crop origin used by `bake`.
@MainActor
private func redAt(_ baked: CGImage, viewPoint: CGPoint) -> UInt8 {
    let data = baked.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    let x = Int(viewPoint.x) - 10
    let y = Int(viewPoint.y) - 10
    return bytes[y * baked.bytesPerRow + x * 4]
}


/// Opens the picker from the tool-options row's colour well and clicks one of
/// its standard swatches — the path a user takes to a common colour.
@MainActor
private func pickStandardColor(_ color: NSColor, in view: RegionPickerView) {
    let row = view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
    row?.onColorWellClicked?()
    let panel = view.subviews.compactMap { $0 as? ColorPickerPanelView }.first
    let swatch = panel?.standardSwatches.first { $0.color.matchesColor(color) }
    #expect(swatch != nil, "The picker should offer a standard swatch for \(color)")
    swatch?.onClick?(color)
}

// MARK: - Ticket 03: undoable delete

@MainActor
@Test
func undoOfDeleteRestoresAnnotationInBakedImage() async {
    let (view, window) = makeHostedView()

    // Black fill rect at (40,40)–(60,60), then select it and delete it.
    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 60, y: 60))
    click(in: view, window: window, at: CGPoint(x: 50, y: 50))
    view.keyDown(with: keyEvent("\u{08}", keyCode: 51, window: window))

    undoKey(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: CGPoint(x: 50, y: 50)) < 60,
            "Undo of delete should restore the black fill rect")
}

// MARK: - Ticket 04: undoable move, one step per drag

@MainActor
@Test
func undoOfMoveRestoresOriginalPosition() async {
    let (view, window) = makeHostedView()

    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 60, y: 60))

    // Grab the body at (50,50) and drag it to (120,120): rect moves +70/+70.
    drag(in: view, window: window, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 120, y: 120))

    // One Cmd+Z reverses the whole drag.
    undoKey(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: CGPoint(x: 50, y: 50)) < 60,
            "After undoing the move, the fill rect should be back at its original spot")
    #expect(redAt(baked, viewPoint: CGPoint(x: 120, y: 120)) > 100,
            "The moved-to location should be source gray again")
}

// MARK: - Ticket 05: undoable restyle

@MainActor
@Test
func undoOfRestyleRestoresOriginalColor() async {
    let (view, window) = makeHostedView()

    // Red (default) stroked rectangle, selected, then recoloured blue.
    view.keyDown(with: keyEvent("r", keyCode: 15, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 80, y: 80))
    click(in: view, window: window, at: CGPoint(x: 60, y: 60))

    pickStandardColor(.systemBlue, in: view)

    undoKey(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    // Top edge of the rectangle: view (60, 40).
    let data = baked.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    let offset = 30 * baked.bytesPerRow + 50 * 4
    let r = bytes[offset]
    let b = bytes[offset + 2]
    #expect(r > 150 && b < 110,
            "Undo of the recolour should restore the red stroke, got R=\(r) B=\(b)")
}

// MARK: - Ticket 02: a slider drag is one undo entry

@MainActor
@Test
func aWholeSliderDragIsOneUndoEntry() async {
    let (view, window) = makeHostedView()

    // A 3pt red rectangle (the default width), selected.
    view.keyDown(with: keyEvent("r", keyCode: 15, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 100, y: 100))
    click(in: view, window: window, at: CGPoint(x: 70, y: 70))

    // One drag of the line-width slider: several live values between a
    // gesture's begin and end.
    let row = view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
    #expect(row != nil, "The toolbar should host a tool-options row")
    row?.onGestureBegan?()
    for width in [12, 14, 16] as [CGFloat] { row?.onLineWidthSelected?(width) }
    row?.onGestureEnded?()

    // Two undos: the first takes back the whole drag, the second takes back
    // the rectangle. If the drag had recorded per intermediate value, the
    // second undo would still be walking back widths and the stroke would
    // still be there.
    undoKey(view, window)
    undoKey(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    // The top edge sits at y=40; nothing may remain of it.
    #expect(redAt(baked, viewPoint: CGPoint(x: 70, y: 40)) < 160,
            "A slider drag plus the draw is two undo entries, not one per tick")
    #expect(redAt(baked, viewPoint: CGPoint(x: 70, y: 36)) < 160,
            "No intermediate width may survive either")
}

@MainActor
@Test
func undoOfASliderDragRestoresTheOriginalWidth() async {
    let (view, window) = makeHostedView()

    view.keyDown(with: keyEvent("r", keyCode: 15, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 100, y: 100))
    click(in: view, window: window, at: CGPoint(x: 70, y: 70))

    let row = view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
    row?.onGestureBegan?()
    for width in [12, 14, 16] as [CGFloat] { row?.onLineWidthSelected?(width) }
    row?.onGestureEnded?()

    undoKey(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    // Back to the 3pt default: ink on the edge itself, none 4pt above it.
    #expect(redAt(baked, viewPoint: CGPoint(x: 70, y: 40)) > 160,
            "Undo must keep the rectangle, only reverting its width")
    #expect(redAt(baked, viewPoint: CGPoint(x: 70, y: 36)) < 160,
            "Undo should restore the 3pt stroke, not an intermediate width")
}

// MARK: - Redo wiring

@MainActor
@Test
func redoAfterUndoRestoresAnnotation() async {
    let (view, window) = makeHostedView()

    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 60, y: 60))

    undoKey(view, window)
    redoKey(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: CGPoint(x: 50, y: 50)) < 60,
            "Redo should bring the undone fill rect back")
}

@MainActor
@Test
func newMutationInvalidatesRedo() async {
    let (view, window) = makeHostedView()

    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 60, y: 60))
    undoKey(view, window)

    // Drawing something new discards the redo path.
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 120))
    redoKey(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: CGPoint(x: 50, y: 50)) > 100,
            "Redo after a new mutation must not resurrect the undone annotation")
    #expect(redAt(baked, viewPoint: CGPoint(x: 110, y: 110)) < 60,
            "The newly drawn annotation should still be present")
}

// MARK: - Undo never touches the selection rectangle

@MainActor
@Test
func undoLeavesSelectionRectangleUntouched() async {
    let (view, window) = makeHostedView()
    var baked: CGImage?
    var cancelled = false
    view.onCommit = { baked = $0 }
    view.onCancel = { cancelled = true }

    // Frame a 100×100 selection, then annotate.
    drag(in: view, window: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 120))
    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 60, y: 60))

    // Undo the draw, then undo again with nothing left — both must leave the
    // selection alone and never cancel the capture.
    undoKey(view, window)
    undoKey(view, window)

    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    #expect(!cancelled, "Cmd+Z with empty history must not cancel the capture")
    #expect(baked?.width == 100, "The framed selection must survive undo unchanged")
    #expect(baked?.height == 100)
}

// MARK: - Escape mid-drag cancels the manipulation

@MainActor
@Test
func escapeMidDragCancelsMoveWithoutStrandingIt() async {
    let (view, window) = makeHostedView()

    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 60, y: 60))

    // Grab and drag, then hit Escape before releasing the mouse.
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 50, y: 50), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 120, y: 120), in: view, window: window))
    view.keyDown(with: keyEvent("\u{1B}", keyCode: 53, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 120, y: 120), in: view, window: window))

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: CGPoint(x: 50, y: 50)) < 60,
            "Escape must cancel the drag, leaving the fill rect at its original spot")
    #expect(redAt(baked, viewPoint: CGPoint(x: 120, y: 120)) > 100,
            "No stranded, unrecorded move may survive Escape")
}
