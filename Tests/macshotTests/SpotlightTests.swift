import AppKit
import Testing
@testable import MacshotCore

// The composed dim path as a value, then what the bake actually darkens.

private let area = CGRect(x: 0, y: 0, width: 200, height: 200)

// MARK: - The composed path

@Test
func theDimCoversEverythingOutsideASpotlightAndNothingInside() throws {
    let path = try #require(SpotlightGeometry.dimPath(
        area: area, spotlights: [(CGRect(x: 40, y: 40, width: 60, height: 60), .rectangle)]
    ))
    #expect(path.contains(CGPoint(x: 10, y: 10), using: .evenOdd), "Outside is dimmed")
    #expect(!path.contains(CGPoint(x: 70, y: 70), using: .evenOdd), "and inside is not")
}

@Test
func overlappingSpotlightsAreBrightExactlyOnceWhereTheyMeet() throws {
    let path = try #require(SpotlightGeometry.dimPath(area: area, spotlights: [
        (CGRect(x: 20, y: 20, width: 80, height: 80), .rectangle),
        (CGRect(x: 60, y: 60, width: 80, height: 80), .rectangle)
    ]))
    // The regression test for double-dimming: were the shapes not unioned
    // before the subtraction, the overlap would land back inside the dim.
    #expect(!path.contains(CGPoint(x: 80, y: 80), using: .evenOdd),
            "The overlap belongs to both spotlights and must stay bright")
    #expect(!path.contains(CGPoint(x: 30, y: 30), using: .evenOdd))
    #expect(!path.contains(CGPoint(x: 130, y: 130), using: .evenOdd))
    #expect(path.contains(CGPoint(x: 180, y: 20), using: .evenOdd),
            "and everything in neither is still dimmed")
}

@Test
func anEllipseSpotlightLeavesTheCornersOfItsBoxDimmed() throws {
    let path = try #require(SpotlightGeometry.dimPath(
        area: area, spotlights: [(CGRect(x: 50, y: 50, width: 100, height: 100), .ellipse)]
    ))
    #expect(!path.contains(CGPoint(x: 100, y: 100), using: .evenOdd), "The middle is bright")
    #expect(path.contains(CGPoint(x: 55, y: 55), using: .evenOdd),
            "but the corner of its bounding box is not part of the ellipse")
}

@Test
func noSpotlightsMeansNoDimAtAll() {
    #expect(SpotlightGeometry.dimPath(area: area, spotlights: []) == nil)
}

@Test
func theDimIsBoundedByTheAreaItWasGiven() throws {
    let path = try #require(SpotlightGeometry.dimPath(
        area: CGRect(x: 50, y: 50, width: 100, height: 100),
        spotlights: [(CGRect(x: 60, y: 60, width: 20, height: 20), .rectangle)]
    ))
    #expect(path.contains(CGPoint(x: 120, y: 120), using: .evenOdd))
    #expect(!path.contains(CGPoint(x: 10, y: 10), using: .evenOdd),
            "Outside the area is somebody else's business")
}

// MARK: - Through the overlay

@MainActor
private func makeHostedView(
    styles: EditorStyles = EditorStyles(),
    onStylesChanged: ((EditorStyles) -> Void)? = nil
) -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: ctx.makeImage()!, scale: 1.0,
        styles: styles, onStylesChanged: onStylesChanged
    )
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

/// Brightness of a baked pixel, over the white source: 255 is untouched.
@MainActor
private func brightness(_ view: RegionPickerView, _ point: CGPoint) throws -> Int {
    let baked = try #require(view.bakedImage())
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    return Int(bytes[Int(point.y) * baked.bytesPerRow + Int(point.x) * 4])
}

@MainActor
@Test
func oneSpotlightLeavesItsRegionBrightAndDarkensTheRest() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("d", 2, window))
    drag(in: view, window: window, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 140))

    #expect(try brightness(view, CGPoint(x: 100, y: 100)) == 255,
            "Inside the spotlight the capture is untouched")
    let outside = try brightness(view, CGPoint(x: 20, y: 20))
    let expected = Int((255 * (1 - SpotlightGeometry.defaultStrength)).rounded())
    #expect(abs(outside - expected) <= 2,
            "Outside should be darkened by the configured amount, got \(outside)")
}

@MainActor
@Test
func theDimShowsWhileTheSpotlightIsStillBeingDragged() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("d", 2, window))
    // Down and dragged, deliberately not released — and low enough on so small
    // an overlay to be clear of the toolbar.
    for (kind, point) in [
        (NSEvent.EventType.leftMouseDown, CGPoint(x: 40, y: 130)),
        (.leftMouseDragged, CGPoint(x: 100, y: 190))
    ] {
        let event = NSEvent.mouseEvent(
            with: kind, location: NSPoint(x: point.x, y: 200 - point.y),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
        )!
        if kind == .leftMouseDown { view.mouseDown(with: event) } else {
            view.mouseDragged(with: event)
        }
    }

    #expect(view.annotations.isEmpty, "Nothing is committed until the drag ends")
    #expect(try onScreenBrightness(view, CGPoint(x: 70, y: 160)) > 240,
            "The region being dragged out stays bright")
    #expect(try onScreenBrightness(view, CGPoint(x: 170, y: 160)) < 160,
            "and the rest is already dimmed, so the framing can be judged")
}

@MainActor
@Test
func twoOverlappingSpotlightsNeverDarkenTheirOverlap() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("d", 2, window))
    drag(in: view, window: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 100))
    // Started outside the first spotlight and dragged back across it, so this
    // draws a second one rather than grabbing the first.
    drag(in: view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 60, y: 60))
    #expect(view.annotations.count == 2)

    let overlap = try brightness(view, CGPoint(x: 80, y: 80))
    let single = try brightness(view, CGPoint(x: 30, y: 30))
    #expect(overlap == 255 && single == 255,
            "Both spotlit regions keep their full brightness, overlap included")
    #expect(try brightness(view, CGPoint(x: 180, y: 180)) < 200,
            "and the remainder is darkened exactly once")
}

@MainActor
@Test
func anEllipseSpotlightBakesWithItsCornersDimmed() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("d", 2, window))
    optionsRow(of: view)?.onSpotlightShapeSelected?(.ellipse)
    drag(in: view, window: window, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))

    #expect(try brightness(view, CGPoint(x: 100, y: 100)) == 255)
    #expect(try brightness(view, CGPoint(x: 55, y: 55)) < 200,
            "The corner of the bounding box is outside the ellipse")
}

@MainActor
@Test
func deletingTheLastSpotlightRestoresTheUndimmedCapture() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("d", 2, window))
    drag(in: view, window: window, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 140))
    #expect(try brightness(view, CGPoint(x: 20, y: 20)) < 200)

    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
    view.keyDown(with: key("\u{8}", 51, window))

    #expect(view.annotations.isEmpty)
    #expect(try brightness(view, CGPoint(x: 20, y: 20)) == 255,
            "With nothing spotlighted there is nothing to dim")
}

@MainActor
@Test
func theDimLandsAtTheEarliestSpotlightSoLaterAnnotationsStayBright() throws {
    let (view, window) = makeHostedView()
    // Two identical red blocks, one placed before the spotlight and one after,
    // both well outside the spotlit region.
    view.keyDown(with: key("f", 3, window))
    optionsRow(of: view)?.onColorWellClicked?()
    view.subviews.compactMap { $0 as? ColorPickerPanelView }.first?.onColorChanged?(.systemRed)
    drag(in: view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))

    view.keyDown(with: key("d", 2, window))
    drag(in: view, window: window, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 120, y: 120))

    view.keyDown(with: key("f", 3, window))
    drag(in: view, window: window, from: CGPoint(x: 160, y: 160), to: CGPoint(x: 190, y: 190))

    let earlier = try brightness(view, CGPoint(x: 25, y: 25))
    let later = try brightness(view, CGPoint(x: 175, y: 175))
    #expect(later > 240, "An annotation placed after the spotlight draws on top of the dim")
    #expect(earlier < later - 80,
            "and one placed before it is dimmed along with the background, got \(earlier)")
}

@MainActor
@Test
func theDimStrengthControlMovesEverySpotlightAtOnceAndUndoesInOneStep() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("d", 2, window))
    drag(in: view, window: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 60))
    drag(in: view, window: window, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 160, y: 160))

    optionsRow(of: view)?.onDimStrengthSelected?(0.9)
    let strengths = view.annotations.compactMap { annotation -> CGFloat? in
        guard case let .spotlight(_, style) = annotation else { return nil }
        return style.strength
    }
    #expect(strengths == [0.9, 0.9], "One layer, one darkness")
    #expect(try brightness(view, CGPoint(x: 100, y: 100)) < 40)

    let undo = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
    )!
    view.keyDown(with: undo)
    let restored = view.annotations.compactMap { annotation -> CGFloat? in
        guard case let .spotlight(_, style) = annotation else { return nil }
        return style.strength
    }
    #expect(restored == [SpotlightGeometry.defaultStrength, SpotlightGeometry.defaultStrength],
            "and one undo takes the whole change back")
    #expect(view.annotations.count == 2, "without removing anything")
}

@MainActor
@Test
func aSpotlightIsSelectableMovableAndResizable() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("d", 2, window))
    drag(in: view, window: window, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 100, y: 100))

    // Select it, then drag its body somewhere else.
    drag(in: view, window: window, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 80, y: 80))
    drag(in: view, window: window, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 120, y: 120))
    #expect(try brightness(view, CGPoint(x: 120, y: 120)) == 255, "The bright region moved")
    #expect(try brightness(view, CGPoint(x: 65, y: 65)) < 200, "and left where it was")

    // Then grow it by its bottom-right handle.
    drag(in: view, window: window, from: CGPoint(x: 140, y: 140), to: CGPoint(x: 180, y: 180))
    #expect(try brightness(view, CGPoint(x: 170, y: 170)) == 255)
}

/// Brightness of the overlay as it is actually drawn on screen, where the
/// Selection dims everything outside itself.
@MainActor
private func onScreenBrightness(_ view: RegionPickerView, _ point: CGPoint) throws -> Int {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let color = try #require(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
    return Int((color.redComponent * 255).rounded())
}

@MainActor
@Test
func theDimIsClippedToTheSelectionSoItDoesNotStackWithTheOverlaysOwn() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 160, y: 160))

    view.keyDown(with: key("d", 2, window))
    drag(in: view, window: window, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 100, y: 100))

    // Outside the Selection the overlay already dims at 40%, and that area is
    // not captured. Sampled clear of the toolbar, which covers the middle of so
    // small an overlay.
    #expect(try onScreenBrightness(view, CGPoint(x: 20, y: 20)) > 120,
            "Stacking the composed layer on the overlay's own dim would go much darker")

    // The bake has no Selection dimming of its own, so the composed layer runs
    // to the frame's edge there whatever the overlay showed.
    #expect(try brightness(view, CGPoint(x: 20, y: 20)) < 200,
            "The export dims everything outside the spotlight")
    #expect(try brightness(view, CGPoint(x: 80, y: 80)) == 255)
}

@MainActor
@Test
func spotlightDefaultsPersistAcrossCaptures() throws {
    var saved: EditorStyles?
    let (view, window) = makeHostedView(onStylesChanged: { saved = $0 })
    view.keyDown(with: key("d", 2, window))
    optionsRow(of: view)?.onSpotlightShapeSelected?(.ellipse)
    optionsRow(of: view)?.onDimStrengthSelected?(0.8)

    #expect(saved?.spotlightShape == SpotlightShape.ellipse.rawValue)
    #expect(saved?.spotlightDimStrength == 0.8)

    let (reloaded, reloadedWindow) = makeHostedView(styles: try #require(saved))
    reloaded.keyDown(with: key("d", 2, reloadedWindow))
    drag(in: reloaded, window: reloadedWindow, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 140))

    guard case let .spotlight(_, style)? = reloaded.annotations.last else {
        Issue.record("No spotlight placed")
        return
    }
    #expect(style.shape == .ellipse && style.strength == 0.8)
}

@Test
func aConfigFromBeforeTheSpotlightDecodesWithItsDefaults() throws {
    let json = Data("""
    {"strokeColorHex":"#FF3B30","strokeLineWidth":3}
    """.utf8)
    let decoded = try JSONDecoder().decode(EditorStyles.self, from: json)
    #expect(decoded.spotlightShape == SpotlightShape.rectangle.rawValue)
    #expect(decoded.spotlightDimStrength == EditorStyles().spotlightDimStrength)
}
