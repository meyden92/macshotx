import AppKit
import CoreGraphics
import Testing
@testable import MacshotCore

// Shift constrains a drawing drag: directional tools onto 45° rays, rectangular
// ones onto a square. All of it is a pure function of the drag's two ends, which
// is what lets the overlay re-run it when Shift goes down or up mid-drag.

private let origin = CGPoint(x: 100, y: 100)

private func expectClose(
    _ point: CGPoint, _ expected: CGPoint, _ label: Comment, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(point.x - expected.x) < 0.001, label, sourceLocation: sourceLocation)
    #expect(abs(point.y - expected.y) < 0.001, label, sourceLocation: sourceLocation)
}

@Test
func aNearlyAxisAlignedDragSnapsFlatOntoThatAxis() {
    // The endpoint keeps how far along the axis it was dragged — the same rule
    // the measure tool's own tolerance snap already follows.
    expectClose(
        ShiftConstraint.angleSnapped(CGPoint(x: 180, y: 108), anchoredAt: origin),
        CGPoint(x: 180, y: 100), "a drag 8pt off horizontal lands on the horizontal"
    )
    expectClose(
        ShiftConstraint.angleSnapped(CGPoint(x: 94, y: 30), anchoredAt: origin),
        CGPoint(x: 100, y: 30), "and 6pt off vertical lands on the vertical"
    )
}

@Test
func aDiagonalDragSnapsOntoTheNearest45DegreeRay() {
    let snapped = ShiftConstraint.angleSnapped(CGPoint(x: 160, y: 150), anchoredAt: origin)
    #expect(abs(abs(snapped.x - origin.x) - abs(snapped.y - origin.y)) < 0.001,
            "equal run and rise is what makes it 45°")
    #expect(snapped.x > origin.x && snapped.y > origin.y, "and it stays in the dragged quadrant")

    // All four diagonals, not just the one the arithmetic happens to favour.
    for (dx, dy) in [(60.0, 60.0), (-60.0, 60.0), (60.0, -60.0), (-60.0, -60.0)] {
        let target = CGPoint(x: origin.x + dx, y: origin.y + dy)
        expectClose(ShiftConstraint.angleSnapped(target, anchoredAt: origin), target,
                    "an exact diagonal is already on a ray and must not move")
    }
}

@Test
func squaringKeepsTheDragsDirectionAndItsLongerSide() {
    // Down-right, up-left and the two mixed quadrants: the square always grows
    // away from the anchor, never flipping across it.
    let cases: [(CGPoint, CGRect)] = [
        (CGPoint(x: 180, y: 140), CGRect(x: 100, y: 100, width: 80, height: 80)),
        (CGPoint(x: 20, y: 60), CGRect(x: 20, y: 20, width: 80, height: 80)),
        (CGPoint(x: 180, y: 60), CGRect(x: 100, y: 20, width: 80, height: 80)),
        (CGPoint(x: 20, y: 140), CGRect(x: 20, y: 100, width: 80, height: 80))
    ]
    for (target, expected) in cases {
        #expect(ShiftConstraint.squared(from: origin, to: target) == expected,
                "drag to \(target)")
    }
}

@Test
func clampingAConstrainedEndpointKeepsItOnItsRay() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)

    // A 45° drag that overshoots the right edge: clamping x and y separately
    // would leave it at (200, 300) — off the ray, and no longer 45°.
    let clamped = ShiftConstraint.clamped(
        CGPoint(x: 300, y: 300), from: CGPoint(x: 50, y: 50), within: bounds
    )
    expectClose(clamped, CGPoint(x: 200, y: 200), "pulled back along the ray")

    // Inside the bounds nothing moves.
    let inside = CGPoint(x: 150, y: 120)
    expectClose(ShiftConstraint.clamped(inside, from: CGPoint(x: 50, y: 50), within: bounds),
                inside, "an endpoint already inside is left alone")

    // A shallow ray leaves by the correct edge, keeping its slope.
    let shallow = ShiftConstraint.clamped(
        CGPoint(x: 400, y: 150), from: CGPoint(x: 0, y: 100), within: bounds
    )
    expectClose(shallow, CGPoint(x: 200, y: 125), "same slope, stopped at the edge it reaches first")
}

@Test
func aDegenerateDragProducesNothingRatherThanCrashing() {
    #expect(ShiftConstraint.squared(from: origin, to: origin) == CGRect(origin: origin, size: .zero))
    expectClose(ShiftConstraint.angleSnapped(origin, anchoredAt: origin), origin,
                "no drag, no direction to snap to")
}

// MARK: - Through the overlay

@MainActor
private func hostedView() -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 4 * 200,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(frame: frame, image: ctx.makeImage()!, scale: 1.0)
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func pickTool(_ char: String, _ keyCode: UInt16, _ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: keyCode
    )!)
}

@MainActor
private func drag(
    in view: RegionPickerView, window: NSWindow,
    from: CGPoint, to: CGPoint, holdingShift: Bool
) {
    for (kind, point) in [
        (NSEvent.EventType.leftMouseDown, from), (.leftMouseDragged, to), (.leftMouseUp, to)
    ] {
        let event = NSEvent.mouseEvent(
            with: kind,
            location: NSPoint(x: point.x, y: view.bounds.height - point.y),
            modifierFlags: holdingShift ? [.shift] : [], timestamp: 0,
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
@Test
func shiftDraggingALineInTheOverlayLandsItPerfectlyHorizontal() {
    let (view, window) = hostedView()
    pickTool("l", 37, view, window)
    // 40pt of rise over 120pt of run: free drawing keeps it, Shift flattens it.
    drag(in: view, window: window,
         from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 140), holdingShift: true)

    guard case let .line(from, to, _)? = view.annotations.first else {
        Issue.record("No line was placed: \(view.annotations)")
        return
    }
    #expect(abs(to.y - from.y) < 0.001, "Shift snapped it onto the horizontal")
    #expect(abs(to.x - 160) < 0.001, "and it still ends under the cursor's x")
}

@MainActor
@Test
func shiftDraggingARectangleInTheOverlayLandsItSquare() {
    let (view, window) = hostedView()
    pickTool("r", 15, view, window)
    drag(in: view, window: window,
         from: CGPoint(x: 40, y: 40), to: CGPoint(x: 160, y: 100), holdingShift: true)

    guard case let .rectangle(rect, _)? = view.annotations.first else {
        Issue.record("No rectangle was placed: \(view.annotations)")
        return
    }
    #expect(abs(rect.width - rect.height) < 0.001, "Shift made it square")
    #expect(abs(rect.width - 120) < 0.001, "on the longer of the two spans")
}

@MainActor
@Test
func withoutShiftTheSameDragIsLeftExactlyWhereItWasDrawn() {
    let (view, window) = hostedView()
    pickTool("l", 37, view, window)
    drag(in: view, window: window,
         from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 140), holdingShift: false)

    guard case let .line(_, to, _)? = view.annotations.first else {
        Issue.record("No line was placed: \(view.annotations)")
        return
    }
    expectClose(to, CGPoint(x: 160, y: 140), "free drawing is untouched")
}
