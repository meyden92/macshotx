import AppKit
import Testing
@testable import MacshotCore

// An element that was just drawn is still the one the options row edits, so a
// setting can be adjusted after the fact instead of undo-and-redraw.

@MainActor
private func makeHostedView() -> (RegionPickerView, NSWindow) {
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let ctx = CGContext(
        data: nil, width: 200, height: 200,
        bitsPerComponent: 8, bytesPerRow: 4 * 200,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(frame: frame, image: ctx.makeImage()!, scale: 1)
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func key(_ char: String, _ keyCode: UInt16, _ window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: keyCode
    )!
}

@MainActor
private func drag(in view: RegionPickerView, window: NSWindow, from: CGPoint, to: CGPoint) {
    for (kind, point) in [
        (NSEvent.EventType.leftMouseDown, from), (.leftMouseDragged, to), (.leftMouseUp, to)
    ] {
        let event = NSEvent.mouseEvent(
            with: kind,
            location: NSPoint(x: point.x, y: view.bounds.height - point.y),
            modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1.0
        )!
        switch kind {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
}

@MainActor
private func optionsRow(of view: RegionPickerView) -> ToolOptionsRowView? {
    view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
}

@MainActor
@Test
func aToolOptionChangedRightAfterDrawingLandsOnTheElementJustPlaced() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("l", 37, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))

    optionsRow(of: view)?.onLineWidthSelected?(9)
    optionsRow(of: view)?.onDashSelected?(.dashed)

    #expect(view.annotations.count == 1, "A restyle, not a second element")
    #expect(view.annotations.last?.style.lineWidth == 9,
            "The line just drawn should take the new width")
    #expect(view.annotations.last?.style.dash == .dashed)
}

@MainActor
@Test
func everyAxisOfTheOptionsRowReachesTheElementJustPlaced() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("r", 15, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 140, y: 120))

    optionsRow(of: view)?.onFillModeSelected?(.strokeAndFill)
    optionsRow(of: view)?.onCornerRadiusSelected?(6)

    #expect(view.annotations.last?.style.fillMode == .strokeAndFill)
    #expect(view.annotations.last?.style.cornerRadius == 6)
}

@MainActor
@Test
func aStyleChosenBeforeDrawingStillSetsTheToolDefaultForWhatComesNext() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("r", 15, window))
    // Nothing placed yet, so this moves the tool's own default.
    optionsRow(of: view)?.onLineWidthSelected?(7)

    drag(in: view, window: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
    #expect(view.annotations.last?.style.lineWidth == 7)

    // And a second element still picks the default up rather than inheriting
    // the selection left behind by the first.
    drag(in: view, window: window, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 180, y: 180))
    #expect(view.annotations.count == 2)
    #expect(view.annotations.last?.style.lineWidth == 7)
}
