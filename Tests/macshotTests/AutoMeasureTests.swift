import AppKit
import Testing
@testable import MacshotCore

// The boundary scan as arithmetic over a readback of a purpose-built bitmap,
// then the whole gesture — hold a direction key, sweep, click — through the
// overlay.

// MARK: - Synthetic bitmaps

/// A readback of an image painted by `paint`, in device pixels.
private func readback(
    width: Int = 200, height: Int = 200, _ paint: (CGContext) -> Void
) -> PixelBuffer {
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 4 * width,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    paint(ctx)
    return PixelBuffer(image: ctx.makeImage()!)!
}

/// A `CGContext` is bottom-left origin while `PixelBuffer` reads top-left, so
/// every fixture paints through this and states its rows the way the scan sees
/// them.
private func fill(_ ctx: CGContext, _ color: NSColor, rows: ClosedRange<Int>, height: Int = 200) {
    ctx.setFillColor(color.cgColor)
    ctx.fill(CGRect(
        x: 0, y: CGFloat(height - 1 - rows.upperBound),
        width: CGFloat(ctx.width), height: CGFloat(rows.count)
    ))
}

private func fill(_ ctx: CGContext, _ color: NSColor, columns: ClosedRange<Int>) {
    ctx.setFillColor(color.cgColor)
    ctx.fill(CGRect(
        x: CGFloat(columns.lowerBound), y: 0,
        width: CGFloat(columns.count), height: CGFloat(ctx.height)
    ))
}

// MARK: - The scan

@Test
func aVerticalScanFindsTheBandTheCursorIsSittingIn() throws {
    let pixels = readback { ctx in
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        fill(ctx, .white, rows: 40...59)
    }
    // The answer must not depend on where inside the band the user pointed.
    for anchor in [40, 47, 59] {
        let span = try #require(MeasureGeometry.boundarySpan(
            in: pixels, x: 100, y: anchor, along: .vertical
        ))
        #expect(span == MeasureGeometry.BoundarySpan(low: 40, high: 59),
                "Anchor \(anchor) should still find rows 40–59")
        #expect(span.length == 20)
    }
}

@Test
func aHorizontalScanFindsTheStripeTheCursorIsSittingIn() throws {
    let pixels = readback { ctx in
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        fill(ctx, .white, columns: 40...59)
    }
    let span = try #require(MeasureGeometry.boundarySpan(
        in: pixels, x: 47, y: 100, along: .horizontal
    ))
    #expect(span == MeasureGeometry.BoundarySpan(low: 40, high: 59))
}

@Test
func theAxisAskedForIsTheAxisScanned() throws {
    let pixels = readback { ctx in
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        fill(ctx, .white, rows: 40...59)
    }
    // A horizontal scan across a horizontal band never leaves it, so it runs
    // out to both edges rather than reporting the band's height.
    let span = try #require(MeasureGeometry.boundarySpan(
        in: pixels, x: 100, y: 47, along: .horizontal
    ))
    #expect(span == MeasureGeometry.BoundarySpan(low: 0, high: 199))
}

@Test
func aFieldWithNoBoundaryAtAllSpansTheWholeImage() throws {
    let pixels = readback { ctx in
        ctx.setFillColor(NSColor.gray.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    }
    let span = try #require(MeasureGeometry.boundarySpan(
        in: pixels, x: 100, y: 100, along: .vertical
    ))
    #expect(span == MeasureGeometry.BoundarySpan(low: 0, high: 199),
            "Nothing to find should still show the user what the tool found")
    #expect(span.length == 200)
}

@Test
func aBoundaryOnOneSideOnlyLeavesTheOtherEdgeAtTheImageEdge() throws {
    let pixels = readback { ctx in
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        fill(ctx, .white, rows: 0...59)
    }
    let span = try #require(MeasureGeometry.boundarySpan(
        in: pixels, x: 100, y: 30, along: .vertical
    ))
    #expect(span == MeasureGeometry.BoundarySpan(low: 0, high: 59))
}

@Test
func aSmoothGradientIsNotAnEdge() throws {
    let pixels = readback { ctx in
        // One shade per row: exactly the case that must not read as a boundary.
        for row in 0..<200 {
            let level = CGFloat(row) / 199
            fill(ctx, NSColor(white: level, alpha: 1), rows: row...row)
        }
    }
    let span = try #require(MeasureGeometry.boundarySpan(
        in: pixels, x: 100, y: 100, along: .vertical
    ))
    #expect(span == MeasureGeometry.BoundarySpan(low: 0, high: 199),
            "A gradient should not be chopped into bands")
}

@Test
func aStepJustOverTheThresholdIsAnEdgeAndOneUnderItIsNot() throws {
    func spanAcrossAStep(of levels: Int) throws -> MeasureGeometry.BoundarySpan {
        let base = 100
        let pixels = readback { ctx in
            fill(ctx, NSColor(white: CGFloat(base) / 255, alpha: 1), rows: 0...199)
            fill(ctx, NSColor(white: CGFloat(base + levels) / 255, alpha: 1), rows: 100...199)
        }
        return try #require(MeasureGeometry.boundarySpan(
            in: pixels, x: 100, y: 50, along: .vertical
        ))
    }

    let over = try spanAcrossAStep(of: MeasureGeometry.boundaryThreshold + 2)
    #expect(over.high == 99, "A step past the threshold is the edge the user can see")

    let under = try spanAcrossAStep(of: MeasureGeometry.boundaryThreshold - 2)
    #expect(under.high == 199, "and a subtler one is noise, not an edge")
}

@Test
func anAnchorOutsideTheImageHasNothingToScan() {
    let pixels = readback { ctx in
        ctx.setFillColor(NSColor.gray.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    }
    #expect(MeasureGeometry.boundarySpan(in: pixels, x: 400, y: 10, along: .vertical) == nil)
    #expect(MeasureGeometry.boundarySpan(in: pixels, x: 10, y: -1, along: .horizontal) == nil)
}

@Test
func sweepingOverAFullDisplaySizedImageStaysResponsive() {
    // One column read per pointer move is the whole cost model; a 4K column
    // scanned a thousand times over should not be close to a second.
    let pixels = readback(width: 3840, height: 2160) { ctx in
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
    }
    let started = Date()
    for step in 0..<1000 {
        _ = MeasureGeometry.boundarySpan(
            in: pixels, x: step % 3840, y: 1080, along: .vertical
        )
    }
    #expect(Date().timeIntervalSince(started) < 2.0)
}

// MARK: - Through the overlay

/// A grey field with a white band across rows 60–139, so a vertical scan from
/// the middle finds an 80px span and red annotation ink stands out from both.
@MainActor
private func makeBandedView() -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 60, width: 200, height: 80))

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
private func arrow(
    _ keyCode: UInt16, _ window: NSWindow, up: Bool = false, repeated: Bool = false
) -> NSEvent {
    NSEvent.keyEvent(
        with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: .function, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
        isARepeat: repeated, keyCode: keyCode
    )!
}

@MainActor
private func toolKey(_ char: String, _ keyCode: UInt16, _ window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: keyCode
    )!
}

@MainActor
private func mouse(
    _ kind: NSEvent.EventType, at point: CGPoint,
    in view: RegionPickerView, window: NSWindow
) {
    let event = NSEvent.mouseEvent(
        with: kind,
        location: NSPoint(x: point.x, y: view.bounds.height - point.y),
        modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1.0
    )!
    switch kind {
    case .leftMouseDown: view.mouseDown(with: event)
    case .leftMouseUp: view.mouseUp(with: event)
    default: view.mouseMoved(with: event)
    }
}

private func endpoints(_ annotation: Annotation?) -> (CGPoint, CGPoint)? {
    guard case let .measure(from, to, _)? = annotation else { return nil }
    return (from, to)
}

/// The measure tool, armed for a vertical scan, pointing into the band.
@MainActor
private func armedOverTheBand() -> (RegionPickerView, NSWindow) {
    let (view, window) = makeBandedView()
    view.keyDown(with: toolKey("m", 46, window))
    mouse(.mouseMoved, at: CGPoint(x: 100, y: 100), in: view, window: window)
    view.keyDown(with: arrow(126, window))
    return (view, window)
}

@MainActor
@Test
func holdingADirectionKeyPreviewsTheSpanBetweenTheNearestBoundaries() throws {
    let (view, _) = armedOverTheBand()

    let preview = try #require(endpoints(view.autoMeasurePreview))
    #expect(preview.0 == CGPoint(x: 100, y: 60) && preview.1 == CGPoint(x: 100, y: 140),
            "The preview should span the band the cursor sits in")
    #expect(view.annotations.isEmpty, "and commit nothing until the user clicks")
}

@MainActor
@Test
func theHorizontalKeyScansTheOtherAxis() throws {
    let (view, window) = makeBandedView()
    view.keyDown(with: toolKey("m", 46, window))
    mouse(.mouseMoved, at: CGPoint(x: 100, y: 100), in: view, window: window)
    view.keyDown(with: arrow(124, window))

    let preview = try #require(endpoints(view.autoMeasurePreview))
    #expect(preview.0.y == 100 && preview.1.y == 100, "A horizontal scan measures across")
    #expect(preview.0 == CGPoint(x: 0, y: 100) && preview.1 == CGPoint(x: 200, y: 100),
            "and the band runs the full width, so it finds the display's own edges")
}

@MainActor
@Test
func thePreviewFollowsTheCursorWhileTheKeyIsHeld() throws {
    let (view, window) = armedOverTheBand()
    mouse(.mouseMoved, at: CGPoint(x: 100, y: 20), in: view, window: window)

    let preview = try #require(endpoints(view.autoMeasurePreview))
    #expect(preview.0 == CGPoint(x: 100, y: 0) && preview.1 == CGPoint(x: 100, y: 60),
            "Sweeping out of the band should show the field above it instead")
}

@MainActor
@Test
func clickingCommitsThePreviewedSpanAsAnOrdinaryMeasurement() throws {
    let (view, window) = armedOverTheBand()
    mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: view, window: window)
    mouse(.leftMouseUp, at: CGPoint(x: 100, y: 100), in: view, window: window)

    #expect(view.annotations.count == 1, "One click, one measurement")
    let placed = try #require(endpoints(view.annotations.last))
    #expect(placed.0 == CGPoint(x: 100, y: 60) && placed.1 == CGPoint(x: 100, y: 140))
    #expect(
        MeasureGeometry.devicePixels(from: placed.0, to: placed.1, pixelScale: 1) == 80,
        "and it reads out exactly the span the scan found"
    )

    // From here it is an ordinary annotation: selectable and movable like any
    // other, with no trace of how it was placed.
    view.keyUp(with: arrow(126, window, up: true))
    mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: view, window: window)
    mouse(.leftMouseUp, at: CGPoint(x: 100, y: 100), in: view, window: window)
    view.keyDown(with: toolKey("\u{8}", 51, window))
    #expect(view.annotations.isEmpty)
}

@MainActor
@Test
func aCommittedSpanBakesAsADimensionLineAcrossTheBand() throws {
    let (view, window) = armedOverTheBand()
    mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: view, window: window)
    mouse(.leftMouseUp, at: CGPoint(x: 100, y: 100), in: view, window: window)

    let baked = try #require(view.bakedImage())
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    func isInk(_ x: Int, _ y: Int) -> Bool {
        let offset = y * baked.bytesPerRow + x * 4
        // Red annotation ink, against a grey field and a white band.
        return bytes[offset] > 200 && bytes[offset + 1] < 100 && bytes[offset + 2] < 100
    }
    // Sampled clear of the readout pill, which sits over the midpoint.
    #expect(isInk(100, 70), "The run should cross the band")
    #expect(isInk(103, 60), "and wear a cap at the band's top edge")
    #expect(isInk(103, 140), "and one at its bottom edge")
    #expect(!isInk(100, 40), "with nothing outside the span it measured")
}

@MainActor
@Test
func releasingTheKeyLeavesNothingBehind() {
    let (view, window) = armedOverTheBand()
    view.keyUp(with: arrow(126, window, up: true))

    #expect(view.autoMeasurePreview == nil, "The preview is genuinely a preview")
    #expect(view.annotations.isEmpty)
}

@MainActor
@Test
func escapeAndAToolSwitchBothDisarmWithoutCommitting() {
    let (escaped, escapeWindow) = armedOverTheBand()
    escaped.keyDown(with: toolKey("\u{1b}", 53, escapeWindow))
    #expect(escaped.autoMeasurePreview == nil && escaped.annotations.isEmpty)

    let (switched, switchWindow) = armedOverTheBand()
    switched.keyDown(with: toolKey("r", 15, switchWindow))
    #expect(switched.autoMeasurePreview == nil && switched.annotations.isEmpty)
}

@MainActor
@Test
func autoRepeatLeavesThePreviewExactlyWhereItWas() throws {
    let (view, window) = armedOverTheBand()
    let before = try #require(endpoints(view.autoMeasurePreview))

    for _ in 0..<5 { view.keyDown(with: arrow(126, window, repeated: true)) }

    let after = try #require(endpoints(view.autoMeasurePreview))
    #expect(after == before, "A held key should not make the preview jump")
    #expect(view.annotations.isEmpty)
}

@MainActor
@Test
func theArrowKeysOnlyScanForTheMeasureToolWithNothingSelected() {
    // Another tool: the key is not the measure tool's to take.
    let (otherTool, otherWindow) = makeBandedView()
    otherTool.keyDown(with: toolKey("r", 15, otherWindow))
    mouse(.mouseMoved, at: CGPoint(x: 100, y: 100), in: otherTool, window: otherWindow)
    otherTool.keyDown(with: arrow(126, otherWindow))
    #expect(otherTool.autoMeasurePreview == nil)

    // Measure tool, but something is selected: the editing model keeps the key.
    let (selected, selectedWindow) = makeBandedView()
    selected.keyDown(with: toolKey("m", 46, selectedWindow))
    // Draw one measurement, then click its body to select it.
    for (kind, point) in [
        (NSEvent.EventType.leftMouseDown, CGPoint(x: 40, y: 20)),
        (.leftMouseDragged, CGPoint(x: 160, y: 20)),
        (.leftMouseUp, CGPoint(x: 160, y: 20))
    ] {
        let event = NSEvent.mouseEvent(
            with: kind, location: NSPoint(x: point.x, y: 200 - point.y),
            modifierFlags: [], timestamp: 0, windowNumber: selectedWindow.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
        )!
        if kind == .leftMouseDown { selected.mouseDown(with: event) }
        else if kind == .leftMouseDragged { selected.mouseDragged(with: event) }
        else { selected.mouseUp(with: event) }
    }
    mouse(.leftMouseDown, at: CGPoint(x: 100, y: 20), in: selected, window: selectedWindow)
    mouse(.leftMouseUp, at: CGPoint(x: 100, y: 20), in: selected, window: selectedWindow)
    #expect(selected.annotations.count == 1)

    selected.keyDown(with: arrow(126, selectedWindow))
    #expect(selected.autoMeasurePreview == nil,
            "An in-progress edit should keep the arrow keys")
}
