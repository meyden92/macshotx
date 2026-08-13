import AppKit
import Testing
@testable import MacshotCore

// Adjusting a placed loupe: each circle moves and resizes on its own, and the
// options row drives magnification and the chrome.

private let loupe = Annotation.loupe(
    source: CGPoint(x: 100, y: 100), sourceRadius: 20,
    lens: CGPoint(x: 220, y: 100), lensRadius: 40, .default
)

private func circles(_ annotation: Annotation?) -> (
    source: CGPoint, sourceRadius: CGFloat, lens: CGPoint, lensRadius: CGFloat
)? {
    guard case let .loupe(source, sourceRadius, lens, lensRadius, _)? = annotation else {
        return nil
    }
    return (source, sourceRadius, lens, lensRadius)
}

private func magnification(_ annotation: Annotation?) -> CGFloat? {
    guard let placed = circles(annotation) else { return nil }
    return LoupeGeometry.magnification(
        sourceRadius: placed.sourceRadius, lensRadius: placed.lensRadius
    )
}

// MARK: - Handles

@Test
func selectingALoupeOffersACentreAndARadiusHandleForEachCircle() {
    let handles = AnnotationGeometry.handlePositions(for: loupe)
    let byKind = Dictionary(uniqueKeysWithValues: handles.map { ("\($0.0)", $0.1) })
    #expect(handles.count == 4)
    #expect(byKind["loupeSource"] == CGPoint(x: 100, y: 100))
    #expect(byKind["loupeSourceRadius"] == CGPoint(x: 120, y: 100))
    #expect(byKind["loupeLens"] == CGPoint(x: 220, y: 100))
    #expect(byKind["loupeLensRadius"] == CGPoint(x: 260, y: 100))
}

@Test
func aCentreHandleMovesItsOwnCircleAndLeavesTheOtherAlone() throws {
    let sourceMoved = try #require(circles(
        AnnotationGeometry.resize(loupe, handle: .loupeSource, to: CGPoint(x: 80, y: 60))
    ))
    #expect(sourceMoved.source == CGPoint(x: 80, y: 60))
    #expect(sourceMoved.lens == CGPoint(x: 220, y: 100), "The lens should not have moved")

    let lensMoved = try #require(circles(
        AnnotationGeometry.resize(loupe, handle: .loupeLens, to: CGPoint(x: 300, y: 200))
    ))
    #expect(lensMoved.lens == CGPoint(x: 300, y: 200))
    #expect(lensMoved.source == CGPoint(x: 100, y: 100))
}

@Test
func growingTheSourceKeepsTheMagnificationAndTakesTheLensWithIt() throws {
    let grown = try #require(circles(
        AnnotationGeometry.resize(loupe, handle: .loupeSourceRadius, to: CGPoint(x: 140, y: 100))
    ))
    #expect(grown.sourceRadius == 40, "More surrounding context is pulled in")
    #expect(grown.lensRadius == 80, "and the lens follows")
    #expect(magnification(
        AnnotationGeometry.resize(loupe, handle: .loupeSourceRadius, to: CGPoint(x: 140, y: 100))
    ) == 2, "The magnification the user chose survives a source resize")
}

@Test
func growingTheLensLeavesTheSourceAloneAndMagnifiesHarder() throws {
    let resized = AnnotationGeometry.resize(
        loupe, handle: .loupeLensRadius, to: CGPoint(x: 300, y: 100)
    )
    let grown = try #require(circles(resized))
    #expect(grown.sourceRadius == 20 && grown.source == CGPoint(x: 100, y: 100))
    #expect(grown.lensRadius == 80)
    #expect(magnification(resized) == 4, "A bigger inset over the same detail zooms harder")
}

@Test
func aCircleCannotBeResizedAwayToNothing() throws {
    let collapsed = try #require(circles(
        AnnotationGeometry.resize(loupe, handle: .loupeLensRadius, to: CGPoint(x: 220, y: 100))
    ))
    #expect(collapsed.lensRadius == LoupeGeometry.minimumRadius)
}

@Test
func settingAMagnificationRescalesTheLensAndHoldsTheSource() throws {
    let restyled = loupe.applyingStyle { $0.magnification = 3 }
    let scaled = try #require(circles(restyled))
    #expect(scaled.sourceRadius == 20, "The source is what is being looked at, and does not move")
    #expect(scaled.lensRadius == 60)
    #expect(magnification(restyled) == 3)
}

@Test
func aPointInsideACircleNamesThatCircleAndTheLensWinsWhereTheyOverlap() {
    #expect(AnnotationGeometry.loupeCircle(of: loupe, at: CGPoint(x: 105, y: 100)) == .source)
    #expect(AnnotationGeometry.loupeCircle(of: loupe, at: CGPoint(x: 215, y: 100)) == .lens)
    #expect(AnnotationGeometry.loupeCircle(of: loupe, at: CGPoint(x: 160, y: 100)) == nil,
            "Between the circles belongs to neither")

    let overlapping = Annotation.loupe(
        source: CGPoint(x: 100, y: 100), sourceRadius: 40,
        lens: CGPoint(x: 120, y: 100), lensRadius: 40, .default
    )
    #expect(AnnotationGeometry.loupeCircle(of: overlapping, at: CGPoint(x: 110, y: 100)) == .lens,
            "The lens is drawn on top, so it is what a click lands on")
}

// MARK: - Through the overlay

@MainActor
private func makeHostedView(
    styles: EditorStyles = EditorStyles(),
    onStylesChanged: ((EditorStyles) -> Void)? = nil
) -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 320, height: 320, bitsPerComponent: 8, bytesPerRow: 4 * 320,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor(white: 0.35, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
    let frame = NSRect(x: 0, y: 0, width: 320, height: 320)
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

/// A placed loupe with its source at (100, 100) and its lens at (220, 220),
/// selected and ready to be adjusted.
@MainActor
private func placedLoupe() -> (RegionPickerView, NSWindow) {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("g", 5, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 220))
    // Adjusting a placed element is the select tool's job: with the loupe tool
    // still active, dragging its circles would draw another loupe.
    view.keyDown(with: key("s", 1, window))
    // Click the lens to select the loupe (and, in passing, grab nothing).
    drag(in: view, window: window, from: CGPoint(x: 220, y: 220), to: CGPoint(x: 220, y: 220))
    return (view, window)
}

@MainActor
@Test
func draggingOneCirclesBodyMovesOnlyThatCircle() throws {
    let (view, window) = placedLoupe()
    drag(in: view, window: window, from: CGPoint(x: 230, y: 230), to: CGPoint(x: 250, y: 260))

    let moved = try #require(circles(view.annotations.last))
    #expect(moved.lens == CGPoint(x: 240, y: 250), "The lens parks where it was dragged")
    #expect(moved.source == CGPoint(x: 100, y: 100), "without disturbing what it points at")

    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 90))
    let nudged = try #require(circles(view.annotations.last))
    #expect(nudged.source == CGPoint(x: 110, y: 90))
    #expect(nudged.lens == CGPoint(x: 240, y: 250), "and the lens stays parked")
}

@MainActor
@Test
func aPerCircleDragIsOneUndoStep() throws {
    let (view, window) = placedLoupe()
    let before = try #require(circles(view.annotations.last))
    drag(in: view, window: window, from: CGPoint(x: 230, y: 230), to: CGPoint(x: 250, y: 260))

    let undo = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
    )!
    view.keyDown(with: undo)
    let restored = try #require(circles(view.annotations.last))
    #expect(restored.lens == before.lens)

    // The second undo takes the placement itself, which is what proves the drag
    // was one entry rather than one per intermediate value.
    view.keyDown(with: undo)
    #expect(view.annotations.isEmpty)
}

@MainActor
@Test
func draggingARadiusHandleResizesThatCircleAsOneUndoStep() throws {
    let (view, window) = placedLoupe()
    let before = try #require(circles(view.annotations.last))
    // The lens radius handle sits on its right edge.
    drag(
        in: view, window: window,
        from: CGPoint(x: 220 + before.lensRadius, y: 220),
        to: CGPoint(x: 220 + before.lensRadius + 20, y: 220)
    )

    let grown = try #require(circles(view.annotations.last))
    #expect(grown.lensRadius == before.lensRadius + 20)
    #expect(grown.sourceRadius == before.sourceRadius, "A lens resize is the lens's business")
    #expect(magnification(view.annotations.last) ?? 0 > LoupeGeometry.defaultMagnification)
}

@MainActor
@Test
func theOptionsRowShowsTheLoupesControlsAndNoOthers() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("g", 5, window))
    #expect(Tool.loupe.options == [.color, .magnification, .outlineVisible])
    #expect(optionsRow(of: view)?.ringToggle.isHidden == false)

    view.keyDown(with: key("r", 15, window))
    #expect(optionsRow(of: view)?.ringToggle.isHidden == true,
            "A tool with no rings should not offer a rings switch")
}

@MainActor
@Test
func theMagnificationControlRescalesASelectedLoupeAndSetsTheDefaultOtherwise() throws {
    let (view, window) = placedLoupe()
    optionsRow(of: view)?.onMagnificationSelected?(4)

    let scaled = try #require(circles(view.annotations.last))
    #expect(scaled.sourceRadius == LoupeGeometry.defaultSourceRadius)
    #expect(magnification(view.annotations.last) == 4)

    // With nothing selected the control moves the tool's own default, which the
    // next placement picks up.
    view.keyDown(with: key("g", 5, window))
    optionsRow(of: view)?.onMagnificationSelected?(3)
    drag(in: view, window: window, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 60, y: 200))
    #expect(magnification(view.annotations.last) == 3)
}

@MainActor
@Test
func turningTheOutlineOffTakesTheRingsAndTheConnectorWithIt() throws {
    // A colour that appears nowhere in the field, so any of it in the baked
    // image is the loupe's chrome.
    let (view, window) = placedLoupe()
    optionsRow(of: view)?.onColorWellClicked?()
    view.subviews.compactMap { $0 as? ColorPickerPanelView }.first?
        .onColorChanged?(.systemGreen)

    func greenPixels() throws -> Int {
        let baked = try #require(view.bakedImage())
        let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
        return (0..<(320 * 320)).filter { index in
            let offset = (index / 320) * baked.bytesPerRow + (index % 320) * 4
            return bytes[offset] < 120 && bytes[offset + 1] > 130 && bytes[offset + 2] < 120
        }.count
    }

    #expect(try greenPixels() > 100, "The rings and connector should be drawn")

    optionsRow(of: view)?.onOutlineVisibilityToggled?(false)
    #expect(try greenPixels() == 0, "and vanish entirely when the outline is off")

    optionsRow(of: view)?.onOutlineVisibilityToggled?(true)
    #expect(try greenPixels() > 100, "and come back in the chosen colour")
}

@MainActor
@Test
func loupeOptionsPersistAcrossCaptures() throws {
    var saved: EditorStyles?
    let (view, window) = makeHostedView(onStylesChanged: { saved = $0 })
    view.keyDown(with: key("g", 5, window))
    optionsRow(of: view)?.onMagnificationSelected?(5)
    optionsRow(of: view)?.onOutlineVisibilityToggled?(false)

    #expect(saved?.loupeMagnification == 5)
    #expect(saved?.loupeOutlineVisible == false)

    let (reloaded, reloadedWindow) = makeHostedView(styles: try #require(saved))
    reloaded.keyDown(with: key("g", 5, reloadedWindow))
    drag(in: reloaded, window: reloadedWindow, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 60, y: 260))

    #expect(magnification(reloaded.annotations.last) == 5)
    guard case let .loupe(_, _, _, _, style)? = reloaded.annotations.last else {
        Issue.record("No loupe placed")
        return
    }
    #expect(!style.outlineVisible, "and the chrome choice survives too")
}

@Test
func aConfigFromBeforeTheLoupeDecodesWithItsDefaults() throws {
    let json = Data("""
    {"strokeColorHex":"#FF3B30","strokeLineWidth":3}
    """.utf8)
    let decoded = try JSONDecoder().decode(EditorStyles.self, from: json)
    #expect(decoded.loupeMagnification == EditorStyles().loupeMagnification)
    #expect(decoded.loupeOutlineVisible)
    #expect(decoded.loupeOutlineColorHex == EditorStyles().loupeOutlineColorHex)
}

@MainActor
@Test
func anOptionsChangeOnASelectedLoupeIsUndoable() throws {
    let (view, window) = placedLoupe()
    optionsRow(of: view)?.onOutlineVisibilityToggled?(false)

    let undo = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
    )!
    view.keyDown(with: undo)

    guard case let .loupe(_, _, _, _, style)? = view.annotations.last else {
        Issue.record("No loupe")
        return
    }
    #expect(style.outlineVisible, "Undo should put the chrome back")
}
