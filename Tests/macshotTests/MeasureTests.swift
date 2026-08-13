import AppKit
import Testing
@testable import MacshotCore

// Axis snapping and the device-pixel readout as arithmetic, then the same
// things through the overlay: what a drag stores, what the bake draws, and what
// survives an undo.

// MARK: - Snap

/// A point `degrees` off the axis running right from the origin, at a distance
/// far enough that the snap is a real decision rather than rounding.
private func offHorizontal(_ degrees: CGFloat) -> CGPoint {
    let radians = degrees * .pi / 180
    return CGPoint(x: 100 * cos(radians), y: 100 * sin(radians))
}

private func offVertical(_ degrees: CGFloat) -> CGPoint {
    let radians = degrees * .pi / 180
    return CGPoint(x: 100 * sin(radians), y: 100 * cos(radians))
}

@Test
func aDragJustOffHorizontalIsStoredExactlyHorizontal() {
    let snapped = MeasureGeometry.snapped(offHorizontal(2), anchoredAt: .zero)
    #expect(snapped.y == 0, "2° off horizontal should land on the anchor's row")
    #expect(snapped.x == offHorizontal(2).x, "and keep the length the user dragged")
}

@Test
func aDragJustOffVerticalIsStoredExactlyVertical() {
    let snapped = MeasureGeometry.snapped(offVertical(2), anchoredAt: .zero)
    #expect(snapped.x == 0)
    #expect(snapped.y == offVertical(2).y)
}

@Test
func aClearlyDiagonalDragKeepsTheAngleItWasDrawnAt() {
    let diagonal = CGPoint(x: 100, y: 100)
    #expect(MeasureGeometry.snapped(diagonal, anchoredAt: .zero) == diagonal)
}

@Test
func theSnapStopsExactlyAtItsTolerance() {
    // Either side of 5°, on both axes: inside snaps, outside is left alone.
    #expect(MeasureGeometry.snapped(offHorizontal(4), anchoredAt: .zero).y == 0)
    #expect(MeasureGeometry.snapped(offHorizontal(6), anchoredAt: .zero).y != 0)
    #expect(MeasureGeometry.snapped(offVertical(4), anchoredAt: .zero).x == 0)
    #expect(MeasureGeometry.snapped(offVertical(6), anchoredAt: .zero).x != 0)
}

@Test
func snappingWorksInEveryDirectionNotJustDownAndRight() {
    for (dx, dy) in [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] {
        let anchor = CGPoint(x: 50, y: 50)
        let nearlyFlat = CGPoint(x: anchor.x + 100 * dx, y: anchor.y + 3 * dy)
        #expect(MeasureGeometry.snapped(nearlyFlat, anchoredAt: anchor).y == anchor.y,
                "A nearly-flat drag toward (\(dx), \(dy)) should flatten")
    }
}

// MARK: - Readout

@Test
func theReadoutIsTheDistanceInDevicePixels() {
    let from = CGPoint(x: 20, y: 40), to = CGPoint(x: 140, y: 40)
    #expect(MeasureGeometry.readout(from: from, to: to, pixelScale: 1) == "120 px")
    // A Retina capture has twice as many pixels across the same points, and the
    // number in the bug report has to be the pixel count.
    #expect(MeasureGeometry.readout(from: from, to: to, pixelScale: 2) == "240 px")
}

@Test
func aDiagonalReadsItsStraightLineDistance() {
    let value = MeasureGeometry.devicePixels(
        from: .zero, to: CGPoint(x: 30, y: 40), pixelScale: 1
    )
    #expect(value == 50, "A 3-4-5 triangle's hypotenuse, not its legs")
}

@Test
func aSnappedHorizontalReadsItsWidthAndNotAHypotenuse() {
    let anchor = CGPoint(x: 10, y: 100)
    let dragged = CGPoint(x: 210, y: 106)
    let end = MeasureGeometry.snapped(dragged, anchoredAt: anchor)
    #expect(MeasureGeometry.devicePixels(from: anchor, to: end, pixelScale: 1) == 200,
            "The 6pt of tremor should be gone from the number, not rolled into it")
}

// MARK: - Readout placement

private let displayArea = CGRect(x: 0, y: 0, width: 200, height: 200)
private let pillSize = CGSize(width: 40, height: 20)

@Test
func theReadoutSitsOffToOneSideOfTheLine() {
    let center = MeasureGeometry.readoutCenter(
        from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100),
        size: pillSize, within: displayArea
    )
    #expect(center.x == 100, "Centred on the midpoint")
    #expect(abs(center.y - 100) == MeasureGeometry.readoutOffset, "and clear of the line")
}

@Test
func theReadoutFlipsToTheOtherSideRatherThanRunOffTheDisplay() {
    let againstTheEdge = MeasureGeometry.readoutCenter(
        from: CGPoint(x: 40, y: 196), to: CGPoint(x: 160, y: 196),
        size: pillSize, within: displayArea
    )
    #expect(againstTheEdge.y < 196, "The pill should move to the inside of the line")

    let roomy = MeasureGeometry.readoutCenter(
        from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100),
        size: pillSize, within: displayArea
    )
    #expect(roomy.y > 100, "and stay on its usual side when there is room")
}

// MARK: - Through the overlay

@MainActor
private func makeHostedView(scale: CGFloat = 1) -> (RegionPickerView, NSWindow) {
    let pixels = Int(200 * scale)
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 4 * pixels,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(frame: frame, image: ctx.makeImage()!, scale: scale)
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
private func drag(
    in view: RegionPickerView, window: NSWindow,
    from: CGPoint, to: CGPoint
) {
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

/// Whether the baked image carries stroke colour at a view point. The
/// measurement is red on white, so ink is anywhere the blue channel drops.
private func inkAt(_ baked: CGImage, _ point: CGPoint, scale: CGFloat = 1) -> Bool {
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    let offset = Int(point.y * scale) * baked.bytesPerRow + Int(point.x * scale) * 4
    return bytes[offset + 2] < 160
}

private func measureEndpoints(_ annotation: Annotation?) -> (CGPoint, CGPoint)? {
    guard case let .measure(from, to, _)? = annotation else { return nil }
    return (from, to)
}

@MainActor
@Test
func draggingWithTheMeasureToolPlacesADimensionLine() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("m", 46, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))

    let placed = try #require(measureEndpoints(view.annotations.last))
    #expect(placed.0 == CGPoint(x: 40, y: 100) && placed.1 == CGPoint(x: 160, y: 100))

    let baked = try #require(view.bakedImage())
    #expect(inkAt(baked, CGPoint(x: 100, y: 100)), "The run itself should be ink")
    // End caps stick out across the line, where the run alone never reaches.
    #expect(inkAt(baked, CGPoint(x: 160, y: 104)), "and each end should wear a cap")
    #expect(inkAt(baked, CGPoint(x: 40, y: 96)))
    // The readout pill floats clear of the line on one side: a band of ink far
    // deeper than the 2pt run, counted rather than sampled so a glyph's own
    // white hole cannot decide the test.
    let besideTheMidpoint = (105...130)
        .filter { inkAt(baked, CGPoint(x: 100, y: CGFloat($0))) }
        .count
    #expect(besideTheMidpoint > 12, "The readout pill should sit beside the midpoint")
}

@MainActor
@Test
func aNearlyHorizontalDragIsStoredExactlyHorizontal() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("m", 46, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 105))

    let placed = try #require(measureEndpoints(view.annotations.last))
    #expect(placed.1.y == 100, "A 2° drag measures the row, not the tremor")
}

@MainActor
@Test
func endpointsAreHeldInsideTheOverlay() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("m", 46, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 260))

    let placed = try #require(measureEndpoints(view.annotations.last))
    #expect(placed.1.x <= 200 && placed.1.y <= 200,
            "A drag off the display should measure to its edge, not past it")
}

@MainActor
@Test
func draggingAnEndpointMovesThatEndOfTheLine() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("m", 46, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))

    // Editing a placed measurement is the select tool's job; a drag with the
    // measure tool still active would draw another one.
    view.keyDown(with: key("s", 1, window))
    // Select it by its body, then take the far endpoint somewhere else.
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
    drag(in: view, window: window, from: CGPoint(x: 160, y: 100), to: CGPoint(x: 160, y: 140))

    let placed = try #require(measureEndpoints(view.annotations.last))
    #expect(placed.0 == CGPoint(x: 40, y: 100), "The end that was not dragged should stand still")
    #expect(placed.1 == CGPoint(x: 160, y: 140))

    let baked = try #require(view.bakedImage())
    #expect(inkAt(baked, CGPoint(x: 130, y: 130)), "The line should follow the dragged end")
    #expect(!inkAt(baked, CGPoint(x: 130, y: 100)), "and no longer run where it did")
}

@MainActor
@Test
func draggingAnEndpointReAppliesTheSnap() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("m", 46, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
    drag(in: view, window: window, from: CGPoint(x: 160, y: 100), to: CGPoint(x: 180, y: 105))

    let placed = try #require(measureEndpoints(view.annotations.last))
    #expect(placed.1 == CGPoint(x: 180, y: 100),
            "An axis-aligned measurement should stay axis-aligned after an edit")
}

@MainActor
@Test
func draggingTheBodyMovesTheWholeLineWithoutChangingItsLength() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("m", 46, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 60))

    let placed = try #require(measureEndpoints(view.annotations.last))
    #expect(placed.0 == CGPoint(x: 40, y: 60) && placed.1 == CGPoint(x: 160, y: 60))
}

@MainActor
@Test
func undoingAMeasurementRestoresTheUntouchedCapture() throws {
    let (pristine, _) = makeHostedView()
    let clean = try #require(pristine.bakedImage())

    let (view, window) = makeHostedView()
    view.keyDown(with: key("m", 46, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))
    #expect(view.annotations.count == 1)

    let undo = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
    )!
    view.keyDown(with: undo)
    #expect(view.annotations.isEmpty)

    let undone = try #require(view.bakedImage())
    #expect(
        CFDataGetBytePtr(undone.dataProvider!.data!).map { pointer in
            CFDataGetBytePtr(clean.dataProvider!.data!).map { reference in
                memcmp(pointer, reference, clean.bytesPerRow * clean.height) == 0
            } ?? false
        } ?? false,
        "Undoing the only measurement should leave the capture byte-identical"
    )
}

@MainActor
@Test
func deleteRemovesASelectedMeasurement() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("m", 46, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
    view.keyDown(with: key("\u{8}", 51, window))

    #expect(view.annotations.isEmpty)
}

@MainActor
@Test
func theMeasureToolOffersItsColourAndWidthAndKeepsThemForTheNextCapture() throws {
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

    view.keyDown(with: key("m", 46, window))
    #expect(Tool.measure.options == [.color, .lineWidth])
    optionsRow(of: view)?.onLineWidthSelected?(6)

    #expect(saved?.measureLineWidth == 6)

    let reloaded = RegionPickerView(
        frame: frame, image: nil, scale: 1.0, styles: try #require(saved)
    )
    window.contentView = reloaded
    reloaded.keyDown(with: key("m", 46, window))
    drag(in: reloaded, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 120, y: 40))

    guard case let .measure(_, _, style)? = reloaded.annotations.last else {
        Issue.record("No measurement placed")
        return
    }
    #expect(style.lineWidth == 6, "The saved width should reach the next capture's measurements")
}

@MainActor
@Test
func restylingASelectedMeasurementChangesThatOneRatherThanTheToolDefault() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("m", 46, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
    optionsRow(of: view)?.onLineWidthSelected?(9)

    guard case let .measure(_, _, style)? = view.annotations.last else {
        Issue.record("No measurement placed")
        return
    }
    #expect(style.lineWidth == 9)
}

@Test
func aConfigFromBeforeMeasureDecodesWithItsDefaults() throws {
    let json = Data("""
    {"strokeColorHex":"#FF3B30","strokeLineWidth":3}
    """.utf8)
    let decoded = try JSONDecoder().decode(EditorStyles.self, from: json)
    #expect(decoded.measureColorHex == EditorStyles().measureColorHex)
    #expect(decoded.measureLineWidth == EditorStyles().measureLineWidth)
    #expect(decoded.strokeLineWidth == 3, "and leave what was already there alone")
}
