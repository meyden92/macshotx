import AppKit
import Testing
@testable import MacshotCore

// The loupe's circle geometry as values, then placement through the overlay and
// the magnified content in the baked image.

// MARK: - Circle geometry

@Test
func magnificationIsTheRatioOfTheTwoRadii() {
    #expect(LoupeGeometry.magnification(sourceRadius: 20, lensRadius: 60) == 3)
    #expect(LoupeGeometry.magnification(sourceRadius: 30, lensRadius: 30) == 1)
}

@Test
func aLensRadiusIsChosenSoThePairMagnifiesByTheAskedForFactor() {
    let radius = LoupeGeometry.lensRadius(sourceRadius: 25, magnification: 2.5)
    #expect(LoupeGeometry.magnification(sourceRadius: 25, lensRadius: radius) == 2.5)
    #expect(LoupeGeometry.lensRadius(sourceRadius: 25, magnification: 0.5) == 25,
            "A loupe that shrinks is not a loupe")
}

@Test
func theBoundingBoxIsTheUnionOfBothCircles() {
    let bounds = LoupeGeometry.bounds(
        source: CGPoint(x: 50, y: 50), sourceRadius: 20,
        lens: CGPoint(x: 150, y: 100), lensRadius: 40
    )
    #expect(bounds == CGRect(x: 30, y: 30, width: 160, height: 110))
}

@Test
func theConnectorRunsBetweenTheTwoCircleEdges() throws {
    let (start, end) = try #require(LoupeGeometry.connector(
        source: CGPoint(x: 50, y: 100), sourceRadius: 20,
        lens: CGPoint(x: 200, y: 100), lensRadius: 40
    ))
    #expect(start == CGPoint(x: 70, y: 100), "Starts on the source circle's edge")
    #expect(end == CGPoint(x: 160, y: 100), "and stops on the lens circle's edge")
}

@Test
func circlesThatTouchHaveNoGapToConnect() {
    #expect(LoupeGeometry.connector(
        source: CGPoint(x: 50, y: 100), sourceRadius: 20,
        lens: CGPoint(x: 90, y: 100), lensRadius: 40
    ) == nil)
}

@Test
func aLoupesBoundsComeFromBothCirclesTogether() {
    let loupe = Annotation.loupe(
        source: CGPoint(x: 50, y: 50), sourceRadius: 20,
        lens: CGPoint(x: 150, y: 100), lensRadius: 40, .default
    )
    #expect(AnnotationGeometry.boundingBox(of: loupe)
            == CGRect(x: 30, y: 30, width: 160, height: 110))
    #expect(AnnotationGeometry.hitTest(loupe, at: CGPoint(x: 150, y: 100)),
            "A click on the lens should select it")
    #expect(!AnnotationGeometry.hitTest(loupe, at: CGPoint(x: 400, y: 400)))
}

@Test
func movingALoupeCarriesBothCircles() {
    let loupe = Annotation.loupe(
        source: CGPoint(x: 50, y: 50), sourceRadius: 20,
        lens: CGPoint(x: 150, y: 100), lensRadius: 40, .default
    )
    guard case let .loupe(source, _, lens, _, _) =
            AnnotationGeometry.translate(loupe, dx: 10, dy: -5) else {
        Issue.record("Not a loupe")
        return
    }
    #expect(source == CGPoint(x: 60, y: 45) && lens == CGPoint(x: 160, y: 95))
}

// MARK: - Through the overlay

/// A grey field with a red block at (90…110, 90…110): small enough to be hard
/// to read at scale, which is the whole reason the tool exists.
@MainActor
private func makeBlockView(scale: CGFloat = 1) -> (RegionPickerView, NSWindow) {
    let pixels = Int(240 * scale)
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 4 * pixels,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.setFillColor(NSColor.systemRed.cgColor)
    // Bottom-left origin here; top-left rows 90…110 in the overlay's space.
    ctx.fill(CGRect(
        x: 90 * scale, y: CGFloat(pixels) - 110 * scale,
        width: 20 * scale, height: 20 * scale
    ))

    let frame = NSRect(x: 0, y: 0, width: 240, height: 240)
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
private func send(
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
    case .leftMouseDragged: view.mouseDragged(with: event)
    case .leftMouseUp: view.mouseUp(with: event)
    default: view.mouseMoved(with: event)
    }
}

@MainActor
private func drag(in view: RegionPickerView, window: NSWindow, from: CGPoint, to: CGPoint) {
    send(.leftMouseDown, at: from, in: view, window: window)
    send(.leftMouseDragged, at: to, in: view, window: window)
    send(.leftMouseUp, at: to, in: view, window: window)
}

private func circles(_ annotation: Annotation?) -> (
    source: CGPoint, sourceRadius: CGFloat, lens: CGPoint, lensRadius: CGFloat
)? {
    guard case let .loupe(source, sourceRadius, lens, lensRadius, _)? = annotation else {
        return nil
    }
    return (source, sourceRadius, lens, lensRadius)
}

@MainActor
@Test
func draggingRootsTheSourceAndLetsTheLensFollowTheCursor() throws {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 180, y: 60))

    let placed = try #require(circles(view.annotations.last))
    #expect(placed.source == CGPoint(x: 100, y: 100), "The source roots where the drag began")
    #expect(placed.lens == CGPoint(x: 180, y: 60), "and the lens lands where it ended")
    #expect(
        LoupeGeometry.magnification(
            sourceRadius: placed.sourceRadius, lensRadius: placed.lensRadius
        ) == LoupeGeometry.defaultMagnification,
        "The lens radius tracks the magnification setting throughout"
    )
}

@MainActor
@Test
func aBareClickPutsTheLensAtItsDefaultOffset() throws {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    drag(in: view, window: window, from: CGPoint(x: 60, y: 140), to: CGPoint(x: 60, y: 140))

    let placed = try #require(circles(view.annotations.last))
    #expect(placed.lens == CGPoint(
        x: 60 + LoupeGeometry.defaultLensOffset.dx,
        y: 140 + LoupeGeometry.defaultLensOffset.dy
    ))
}

@MainActor
@Test
func hoveringPreviewsExactlyWhatAClickWouldPlace() throws {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    send(.mouseMoved, at: CGPoint(x: 60, y: 140), in: view, window: window)

    let previewed = try #require(view.hoverPreview)
    #expect(view.annotations.isEmpty, "Hovering commits nothing")

    drag(in: view, window: window, from: CGPoint(x: 60, y: 140), to: CGPoint(x: 60, y: 140))
    #expect(view.annotations.last == previewed,
            "Nothing should change appearance on mouse-up, because it is the same value")
    #expect(view.hoverPreview == nil, "and the preview gives way to the placed loupe")
}

@MainActor
@Test
func switchingToolsMidHoverLeavesNoStrayPreview() {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    send(.mouseMoved, at: CGPoint(x: 60, y: 140), in: view, window: window)
    view.keyDown(with: key("r", 15, window))

    #expect(view.hoverPreview == nil)
    #expect(view.annotations.isEmpty)
}

@MainActor
@Test
func aLoupeIsSelectableMovableAndDeletableLikeAnyOtherAnnotation() throws {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 180, y: 60))

    // Grabbed between the circles rather than on one of them, which moves the
    // whole magnifier.
    drag(in: view, window: window, from: CGPoint(x: 90, y: 20), to: CGPoint(x: 100, y: 40))
    let moved = try #require(circles(view.annotations.last))
    #expect(moved.source == CGPoint(x: 110, y: 120) && moved.lens == CGPoint(x: 190, y: 80))

    view.keyDown(with: key("\u{8}", 51, window))
    #expect(view.annotations.isEmpty)

    let undo = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
    )!
    view.keyDown(with: undo)
    #expect(view.annotations.count == 1, "Undo brings it back")
    view.keyDown(with: undo)
    let backToPlacement = try #require(circles(view.annotations.last))
    #expect(backToPlacement.lens == CGPoint(x: 180, y: 60), "and again undoes the move")
}

// MARK: - What the lens shows

@MainActor
private func bakedBytes(_ view: RegionPickerView) throws -> (CGImage, UnsafePointer<UInt8>) {
    let baked = try #require(view.bakedImage())
    return (baked, CFDataGetBytePtr(baked.dataProvider!.data!)!)
}

/// How much of a horizontal run of view points is red, in the baked image.
@MainActor
private func redRun(
    _ baked: CGImage, _ bytes: UnsafePointer<UInt8>,
    y: CGFloat, from: Int, to: Int, scale: CGFloat = 1
) -> Int {
    (from...to).filter { x in
        let offset = Int(y * scale) * baked.bytesPerRow + Int(CGFloat(x) * scale) * 4
        return bytes[offset] > 180 && bytes[offset + 1] < 110 && bytes[offset + 2] < 110
    }.count
}

@MainActor
@Test
func theLensShowsTheDetailUnderTheSourceEnlarged() throws {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    // Source over the 20pt block, lens parked in empty space below it.
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 190))

    let (baked, bytes) = try bakedBytes(view)
    let onTheBlock = redRun(baked, bytes, y: 100, from: 60, to: 140)
    let inTheLens = redRun(baked, bytes, y: 190, from: 30, to: 170)
    #expect(onTheBlock == 20, "The block itself is untouched at its own size")
    #expect(
        inTheLens >= Int(20 * LoupeGeometry.defaultMagnification) - 4
            && inTheLens <= Int(20 * LoupeGeometry.defaultMagnification) + 4,
        "The lens should show it at the magnification the pair implies, got \(inTheLens)"
    )
}

@MainActor
@Test
func everythingOutsideTheLensIsLeftAlone() throws {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 190))

    let (baked, bytes) = try bakedBytes(view)
    // A row above both circles, and one between them but clear of the connector.
    #expect(redRun(baked, bytes, y: 20, from: 0, to: 239) == 0)
    #expect(redRun(baked, bytes, y: 140, from: 0, to: 60) == 0)
}

@MainActor
@Test
func theLensSamplesTheCaptureAtItsOwnPixelScale() throws {
    // On a Retina capture the source circle covers twice as many pixels; the
    // lens must still show the same content at the same magnification.
    let (view, window) = makeBlockView(scale: 2)
    view.keyDown(with: key("g", 5, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 190))

    let (baked, bytes) = try bakedBytes(view)
    // Sampled per view point, so this is directly comparable with the 1× case:
    // the same block should fill the same part of the lens either way.
    let inTheLens = redRun(baked, bytes, y: 190, from: 30, to: 170, scale: 2)
    #expect(
        inTheLens >= Int(20 * LoupeGeometry.defaultMagnification) - 4
            && inTheLens <= Int(20 * LoupeGeometry.defaultMagnification) + 4,
        "A Retina capture should magnify by the same factor, got \(inTheLens)"
    )
}

@MainActor
@Test
func theMagnifiedContentIsClippedToTheLensCircle() throws {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    // The source is placed so the block lands in the very corner of its square,
    // which magnifies into a corner of the lens's bounding box — inside the
    // square, well outside the circle.
    drag(in: view, window: window, from: CGPoint(x: 118, y: 118), to: CGPoint(x: 100, y: 190))

    let (baked, bytes) = try bakedBytes(view)
    #expect(redRun(baked, bytes, y: 140, from: 46, to: 52) == 0,
            "The corner of the lens's square is not part of the lens")
    #expect(redRun(baked, bytes, y: 160, from: 30, to: 170) > 20,
            "while the lens itself still shows the magnified detail")
}

@MainActor
@Test
func annotationsPlacedAfterALoupeDrawOnTopOfIt() throws {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 190))

    // A filled black redaction straight over the lens.
    view.keyDown(with: key("f", 3, window))
    drag(in: view, window: window, from: CGPoint(x: 70, y: 160), to: CGPoint(x: 130, y: 220))

    let (baked, bytes) = try bakedBytes(view)
    #expect(redRun(baked, bytes, y: 190, from: 71, to: 129) == 0,
            "The later annotation should cover the lens, not sit under it")
}

@MainActor
@Test
func aSourceOutsideTheSelectionStillMagnifies() throws {
    let (view, window) = makeBlockView()
    view.keyDown(with: key("g", 5, window))
    // Source on the block, lens down in the region that will be captured.
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 190))

    // A Selection that excludes the source entirely.
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 20, y: 150), to: CGPoint(x: 220, y: 230))

    var committed: CGImage?
    view.onCommit = { committed = $0 }
    view.keyDown(with: key("\r", 36, window))

    let baked = try #require(committed)
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    // Row 190 of the overlay is row 40 of the crop, which starts at y = 150.
    let inTheLens = (30...170).filter { x in
        let offset = 40 * baked.bytesPerRow + (x - 20) * 4
        return bytes[offset] > 180 && bytes[offset + 1] < 110 && bytes[offset + 2] < 110
    }.count
    #expect(inTheLens > 30,
            "The lens samples the frozen image, Selection or no Selection, got \(inTheLens)")
}
