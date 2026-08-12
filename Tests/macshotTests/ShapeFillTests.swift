import AppKit
import Testing
@testable import MacshotCore

// Fill modes and corner radius: the clamp as arithmetic, the painted result
// through the overlay's bake.

// MARK: - Corner radius clamping

@Test
func aCornerRadiusIsClampedToHalfTheShorterSide() {
    let wide = CGRect(x: 0, y: 0, width: 200, height: 40)
    #expect(AnnotationGeometry.clampedCornerRadius(8, in: wide) == 8)
    #expect(AnnotationGeometry.clampedCornerRadius(100, in: wide) == 20,
            "A radius past half the shorter side would turn the rect into a blob")
    #expect(AnnotationGeometry.clampedCornerRadius(-5, in: wide) == 0)
}

@Test
func shrinkingARoundedRectangleDegradesGracefully() {
    // The same generous radius against rectangles as they shrink: it follows
    // the rect down rather than the rect refusing to shrink.
    var last = CGFloat.infinity
    for side in stride(from: 100.0, through: 4.0, by: -8.0) {
        let rect = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        let radius = AnnotationGeometry.clampedCornerRadius(40, in: rect)
        #expect(radius <= CGFloat(side) / 2 + 1e-9, "Radius escaped the rect at side \(side)")
        #expect(radius <= last, "Radius should never grow as the rect shrinks")
        last = radius
    }
}

@Test
func aZeroSizedRectangleHasNoRadiusToApply() {
    #expect(AnnotationGeometry.clampedCornerRadius(20, in: .zero) == 0)
}

// MARK: - Through the overlay

@MainActor
private func makeHostedView() -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 200, height: 200,
        bitsPerComponent: 8, bytesPerRow: 4 * 200,
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
private func bake(_ view: RegionPickerView, _ window: NSWindow) -> CGImage? {
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 190, y: 190))
    view.keyDown(with: key("\r", 36, window))
    return baked
}

/// (red, blue) of the baked pixel a view point maps to, over the white source.
@MainActor
private func pixel(_ baked: CGImage, _ point: CGPoint) -> (r: UInt8, b: UInt8) {
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    let offset = (Int(point.y) - 10) * baked.bytesPerRow + (Int(point.x) - 10) * 4
    return (bytes[offset], bytes[offset + 2])
}

/// Draws a rectangle from (50,50) to (150,130) with the given setup applied
/// first, and returns the baked image.
@MainActor
private func bakedRectangle(
    _ setup: (ToolOptionsRowView?) -> Void
) -> CGImage? {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("r", 15, window))
    setup(optionsRow(of: view))
    drag(in: view, window: window, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 130))
    return bake(view, window)
}

private let interior = CGPoint(x: 100, y: 90)
private let onTheEdge = CGPoint(x: 100, y: 50)

@MainActor
@Test
func strokeOnlyIsStillTheDefaultAndLeavesTheInteriorAlone() {
    guard let baked = bakedRectangle({ _ in }) else {
        Issue.record("No baked image")
        return
    }
    #expect(pixel(baked, interior).b > 200, "Stroke-only should leave the interior untouched")
    #expect(pixel(baked, onTheEdge).b < 160, "The edge should still be stroked")
}

@MainActor
@Test
func fillOnlyPaintsTheInteriorAndDropsTheStroke() {
    guard let baked = bakedRectangle({ row in row?.onFillModeSelected?(.fillOnly) }) else {
        Issue.record("No baked image")
        return
    }
    // Default fill is the stroke red at 30%, so the interior tints but does not
    // go solid.
    let inside = pixel(baked, interior)
    #expect(inside.b < 220 && inside.b > 120,
            "Fill-only should tint the interior, got blue=\(inside.b)")
    #expect(inside.r > 200, "A red tint should leave the red channel high")
}

@MainActor
@Test
func strokeAndFillPaintsBothWithIndependentColors() {
    guard let baked = bakedRectangle({ row in
        row?.onFillModeSelected?(.strokeAndFill)
    }) else {
        Issue.record("No baked image")
        return
    }
    let inside = pixel(baked, interior)
    let edge = pixel(baked, onTheEdge)
    #expect(inside.b < 220, "The interior should be filled")
    #expect(edge.b < inside.b - 40,
            "The solid stroke should be darker than its own translucent fill")
}

@MainActor
@Test
func aRoundedRectangleLeavesBackgroundWhereASquareOneHasInk() {
    guard let square = bakedRectangle({ _ in }),
          let rounded = bakedRectangle({ row in row?.onCornerRadiusSelected?(24) })
    else {
        Issue.record("No baked image")
        return
    }
    // Just inside the top-left corner: on the square rectangle this is the
    // corner itself, on the rounded one it is outside the arc.
    let corner = CGPoint(x: 51, y: 51)
    #expect(pixel(square, corner).b < 160, "The square rectangle should have ink at its corner")
    #expect(pixel(rounded, corner).b > 200,
            "The rounded rectangle should have rounded that corner away")
    // The middle of the top edge is on the straight run either way.
    #expect(pixel(rounded, onTheEdge).b < 160)
}

@MainActor
@Test
func fillAndRadiusSurviveARotation() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("r", 15, window))
    optionsRow(of: view)?.onFillModeSelected?(.fillOnly)
    drag(in: view, window: window, from: CGPoint(x: 60, y: 80), to: CGPoint(x: 140, y: 110))

    // Select it and turn it a quarter turn about its centre (100,95).
    drag(in: view, window: window, from: CGPoint(x: 100, y: 95), to: CGPoint(x: 100, y: 95))
    let knob = CGPoint(x: 100, y: 80 - AnnotationGeometry.rotationHandleOffset)
    drag(in: view, window: window, from: knob, to: CGPoint(x: 180, y: 95))

    guard let baked = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    // Turned, the fill covers a tall band: inside it now, outside where it was.
    #expect(pixel(baked, CGPoint(x: 100, y: 70)).b < 220,
            "The fill should have turned with the shape")
    #expect(pixel(baked, CGPoint(x: 70, y: 95)).b > 200,
            "and left where its unrotated box used to be")
}

@MainActor
@Test
func fillDefaultsPersistThroughTheStylesCallback() {
    var saved: EditorStyles?
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: nil, scale: 1.0, onStylesChanged: { saved = $0 }
    )
    window.contentView = view
    window.makeFirstResponder(view)

    view.keyDown(with: key("r", 15, window))
    optionsRow(of: view)?.onFillModeSelected?(.strokeAndFill)
    optionsRow(of: view)?.onCornerRadiusSelected?(12)

    #expect(saved?.shapeFillMode == FillMode.strokeAndFill.rawValue)
    #expect(saved?.rectangleCornerRadius == 12)

    let reloaded = RegionPickerView(
        frame: frame, image: nil, scale: 1.0, styles: saved ?? EditorStyles()
    )
    window.contentView = reloaded
    reloaded.keyDown(with: key("r", 15, window))
    let row = optionsRow(of: reloaded)
    #expect(row?.fillModeControl.selectedIndex
            == FillMode.allCases.firstIndex(of: .strokeAndFill))
    #expect(row?.fillColorWell.isHidden == false,
            "A filled mode should expose the fill colour well")
}

@MainActor
@Test
func theFillColorWellOnlyAppearsOnceSomethingIsBeingFilled() {
    let row = ToolOptionsRowView()
    row.configure(
        options: Tool.rectangle.options,
        style: AnnotationStyle(color: .systemRed, lineWidth: 3, fillMode: .strokeOnly)
    )
    #expect(row.fillColorWell.isHidden, "Stroke-only has no fill colour to pick")

    row.configure(
        options: Tool.rectangle.options,
        style: AnnotationStyle(
            color: .systemRed, lineWidth: 3, fillMode: .strokeAndFill, fillColor: .systemBlue
        )
    )
    #expect(!row.fillColorWell.isHidden)
}
