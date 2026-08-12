import AppKit
import Testing
@testable import MacshotCore

// The text box: wrapping arithmetic as values, and the overlay's re-edit flow
// asserted on baked pixels.

private let textStyle = TextStyle(color: .systemRed, fontSize: 22)
private let manyWords = String(repeating: "wrap ", count: 24)

// MARK: - Wrapping

@Test
func aBoxGrowsInHeightToFitItsWrappedContentButNeverInWidth() {
    let box = CGRect(x: 10, y: 10, width: 120, height: 24)
    let short = TextLayout.fittedBox(box, content: "Hi", style: textStyle)
    let long = TextLayout.fittedBox(box, content: manyWords, style: textStyle)

    #expect(short.width == 120 && long.width == 120,
            "The width the user chose is the wrap width and stays put")
    #expect(long.height > short.height, "More lines means a taller box")
    #expect(long.origin == box.origin, "The box grows downward from where it was placed")
}

@Test
func anarrowerBoxWrapsIntoMoreLines() {
    let wide = TextLayout.fittedBox(
        CGRect(x: 0, y: 0, width: 400, height: 20), content: manyWords, style: textStyle
    )
    let narrow = TextLayout.fittedBox(
        CGRect(x: 0, y: 0, width: 100, height: 20), content: manyWords, style: textStyle
    )
    #expect(narrow.height > wide.height, "Narrowing the box should push the text taller")
}

@Test
func aBoxNeverCollapsesBelowItsMinimum() {
    let tiny = TextLayout.fittedBox(
        CGRect(x: 5, y: 5, width: 1, height: 1), content: "", style: textStyle
    )
    #expect(tiny.width >= TextLayout.minimumBoxSize.width)
    #expect(tiny.height >= TextLayout.minimumBoxSize.height)
}

@Test
func aTextBoxIsResizableAndReWrapsAsItIsDragged() {
    let text = Annotation.text(
        box: CGRect(x: 20, y: 20, width: 300, height: 24), content: manyWords, textStyle
    )
    let handles = AnnotationGeometry.handlePositions(for: text)
    #expect(handles.count == 8, "The text box carries the eight box handles")

    let narrowed = AnnotationGeometry.resize(text, handle: .right, to: CGPoint(x: 120, y: 20))
    let before = AnnotationGeometry.boundingBox(of: text)
    let after = AnnotationGeometry.boundingBox(of: narrowed)
    #expect(after.width == 100)
    #expect(after.height > before.height, "Narrowing should have re-wrapped the text taller")
}

@Test
func aCalloutBubbleSizesToItsWrappedTextBox() {
    let box = CGRect(x: 40, y: 40, width: 120, height: 24)
    let short = CalloutGeometry.bubbleRect(box: box, content: "Hi", style: textStyle)
    let long = CalloutGeometry.bubbleRect(box: box, content: manyWords, style: textStyle)

    #expect(long.height > short.height, "The bubble follows the wrapped text")
    #expect(short.width == long.width, "and keeps the width the box was given")
    #expect(short.minX < box.minX && short.minY < box.minY,
            "The bubble stands off the text box by its padding")
}

@Test
func textAndCalloutHitTestingUsesTheBox() {
    let text = Annotation.text(
        box: CGRect(x: 20, y: 20, width: 200, height: 40), content: "Hi", textStyle
    )
    // Well past the glyphs but inside the box the user sized.
    #expect(AnnotationGeometry.hitTest(text, at: CGPoint(x: 190, y: 40)))
    #expect(!AnnotationGeometry.hitTest(text, at: CGPoint(x: 260, y: 40)))
}

// MARK: - Through the overlay

@MainActor
private func makeHostedView() -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 300, height: 300,
        bitsPerComponent: 8, bytesPerRow: 4 * 300,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
    let frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: ctx.makeImage()!, scale: 1.0, requiresSelection: false
    )
    window.contentView = view
    window.makeFirstResponder(view)
    window.makeKeyAndOrderFront(nil)
    return (view, window)
}

@MainActor
private func key(
    _ char: String, _ keyCode: UInt16, _ window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: keyCode
    )!
}

@MainActor
private func mouse(
    _ kind: NSEvent.EventType, at point: CGPoint,
    view: RegionPickerView, window: NSWindow, clicks: Int = 1
) -> NSEvent {
    NSEvent.mouseEvent(
        with: kind, location: NSPoint(x: point.x, y: view.bounds.height - point.y),
        modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: clicks, pressure: 1.0
    )!
}

@MainActor
private func drag(in view: RegionPickerView, window: NSWindow, from: CGPoint, to: CGPoint) {
    view.mouseDown(with: mouse(.leftMouseDown, at: from, view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: to, view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: to, view: view, window: window))
}

@MainActor
private func doubleClick(in view: RegionPickerView, window: NSWindow, at point: CGPoint) {
    view.mouseDown(with: mouse(.leftMouseDown, at: point, view: view, window: window, clicks: 2))
    view.mouseUp(with: mouse(.leftMouseUp, at: point, view: view, window: window, clicks: 2))
}

@MainActor
private func editor(in view: RegionPickerView) -> InlineTextView? {
    view.subviews.compactMap { $0 as? InlineTextView }.first
}

/// The whole 300×300 canvas, since these views need no crop selection.
@MainActor
private func bake(_ view: RegionPickerView, _ window: NSWindow) -> CGImage? {
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: key("\r", 36, window))
    return baked
}

/// Whether any ink (a non-white pixel) appears in a band of the baked image.
@MainActor
private func hasInk(_ baked: CGImage, in rect: CGRect) -> Bool {
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            if bytes[y * baked.bytesPerRow + x * 4 + 2] < 200 { return true }
        }
    }
    return false
}

@MainActor
@Test
func draggingWithTheTextToolSizesTheBoxAndTheTextWrapsInsideIt() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("t", 17, window))

    // Drag a tall narrow box, then fill it with more words than fit on a line.
    drag(in: view, window: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 60))
    editor(in: view)?.string = manyWords

    guard let baked = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    #expect(hasInk(baked, in: CGRect(x: 20, y: 20, width: 100, height: 30)),
            "The first line should be inside the box")
    #expect(hasInk(baked, in: CGRect(x: 20, y: 80, width: 100, height: 40)),
            "The text should have wrapped down the page rather than run off the side")
    #expect(!hasInk(baked, in: CGRect(x: 140, y: 20, width: 140, height: 100)),
            "Nothing should spill past the box's right edge")
}

@MainActor
@Test
func aBareClickWithTheTextToolStillJustLetsYouType() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("t", 17, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 30, y: 30), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 30, y: 30), view: view, window: window))

    #expect(editor(in: view) != nil, "A click should open the editor straight away")
    #expect(editor(in: view)?.frame.width == TextLayout.defaultBoxSize.width,
            "and give it the default box")
}

@MainActor
@Test
func doubleClickingAPlacedTextReopensItWithItsContent() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("t", 17, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 40, y: 40), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 40, y: 40), view: view, window: window))
    editor(in: view)?.string = "teh typo"
    view.keyDown(with: key("s", 1, window))
    #expect(editor(in: view) == nil,
            "Switching tools should have committed the text and closed the editor")

    doubleClick(in: view, window: window, at: CGPoint(x: 60, y: 50))

    #expect(editor(in: view)?.string == "teh typo",
            "Re-editing should open on the existing content")
}

@MainActor
@Test
func aReEditBakesTheChangedStringAndIsOneUndoEntry() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("t", 17, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 40, y: 40), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 40, y: 40), view: view, window: window))
    editor(in: view)?.string = "IIIIIIIIIIIIIIIIIIII"
    view.keyDown(with: key("s", 1, window))

    // Re-open it and replace the content with something much shorter.
    doubleClick(in: view, window: window, at: CGPoint(x: 60, y: 50))
    editor(in: view)?.string = "I"

    guard let baked = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    #expect(hasInk(baked, in: CGRect(x: 40, y: 40, width: 20, height: 30)),
            "The shortened string should still be drawn")
    #expect(!hasInk(baked, in: CGRect(x: 120, y: 40, width: 100, height: 30)),
            "and the long one it replaced should be gone")

    // One undo takes the whole edit back.
    view.keyDown(with: key("z", 6, window, modifiers: [.command]))
    guard let afterUndo = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    #expect(hasInk(afterUndo, in: CGRect(x: 120, y: 40, width: 100, height: 30)),
            "Undo should restore the original string")
}

@MainActor
@Test
func committingEmptyContentRemovesTheAnnotation() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("t", 17, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 40, y: 40), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 40, y: 40), view: view, window: window))
    editor(in: view)?.string = "IIIIIIII"
    view.keyDown(with: key("s", 1, window))

    doubleClick(in: view, window: window, at: CGPoint(x: 60, y: 50))
    editor(in: view)?.string = ""

    guard let baked = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    #expect(!hasInk(baked, in: CGRect(x: 30, y: 30, width: 200, height: 40)),
            "An emptied label should leave nothing behind")
}

@MainActor
@Test
func escapeDuringAReEditRestoresThePreviousContent() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("t", 17, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 40, y: 40), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 40, y: 40), view: view, window: window))
    editor(in: view)?.string = "IIIIIIIIIIIIIIIIIIII"
    view.keyDown(with: key("s", 1, window))

    doubleClick(in: view, window: window, at: CGPoint(x: 60, y: 50))
    editor(in: view)?.string = "wrecked"
    view.textView(editor(in: view)!, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

    guard let baked = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    #expect(hasInk(baked, in: CGRect(x: 120, y: 40, width: 100, height: 30)),
            "Escape should leave the annotation exactly as it was")
}

@MainActor
@Test
func doubleClickingEmptyCanvasStillConfirmsTheCapture() {
    let (view, window) = makeHostedView()
    var committed = false
    view.onCommit = { _ in committed = true }

    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 200, y: 200))
    doubleClick(in: view, window: window, at: CGPoint(x: 100, y: 100))

    #expect(committed, "A double-click on empty canvas should still confirm")
}
