import AppKit
import Testing
@testable import MacshotCore

// Dash distribution as arithmetic, flip as a value transform, and the rendered
// result of both — plus each head variant — through the overlay's bake.

private let strokeStyle = StrokeStyle(color: .systemRed, lineWidth: 3)

// MARK: - Dash distribution

@Test
func aSolidStrokeHasNoDashPatternAtAll() {
    #expect(AnnotationGeometry.dashPattern(.solid, length: 100, lineWidth: 3).isEmpty)
}

@Test
func dashesDivideThePathEvenlyAtEveryLengthAndWidth() {
    for length in stride(from: 8.0, through: 400.0, by: 7.0) {
        for width in [1.0, 3.0, 7.5, 22.0] as [CGFloat] {
            let pattern = AnnotationGeometry.dashPattern(
                .dashed, length: CGFloat(length), lineWidth: width
            )
            guard pattern.count == 2 else { continue }
            let (dash, gap) = (pattern[0], pattern[1])
            #expect(dash > 0 && gap > 0, "Degenerate pattern at \(length)/\(width)")
            // n dashes and n-1 gaps must span the path exactly, so the stroke
            // starts on a dash and ends on one.
            let count = (CGFloat(length) + gap) / (dash + gap)
            #expect(abs(count - count.rounded()) < 1e-6,
                    "Length \(length) at width \(width) ends mid-dash (\(count) periods)")
        }
    }
}

@Test
func dotsLandOnBothEndsOfThePathAtEveryLengthAndWidth() {
    for length in stride(from: 8.0, through: 400.0, by: 7.0) {
        for width in [1.0, 3.0, 7.5] as [CGFloat] {
            let pattern = AnnotationGeometry.dashPattern(
                .dotted, length: CGFloat(length), lineWidth: width
            )
            guard pattern.count == 2 else { continue }
            #expect(pattern[0] == 0, "Dots are zero-length dashes under a round cap")
            let spacing = pattern[1]
            let gaps = CGFloat(length) / spacing
            #expect(abs(gaps - gaps.rounded()) < 1e-6,
                    "Length \(length) at width \(width) ends between dots")
        }
    }
}

@Test
func dotSpacingScalesWithTheLineWidth() {
    let thin = AnnotationGeometry.dashPattern(.dotted, length: 200, lineWidth: 2)
    let thick = AnnotationGeometry.dashPattern(.dotted, length: 200, lineWidth: 10)
    #expect(thick[1] > thin[1], "A heavier dotted line should space its dots further apart")
}

@Test
func aStrokeShorterThanItsOwnWidthStaysSolid() {
    #expect(AnnotationGeometry.dashPattern(.dashed, length: 2, lineWidth: 22).isEmpty)
    #expect(AnnotationGeometry.dashPattern(.dotted, length: 0, lineWidth: 3).isEmpty)
}

// MARK: - Flip

@Test
func flippingSwapsTheEndpointsAndNothingElse() {
    let from = CGPoint(x: 10, y: 20), to = CGPoint(x: 90, y: 60)
    let arrow = Annotation.arrow(from: from, to: to, strokeStyle)

    // Identical to the same arrow drawn the other way round, so the render is
    // pixel-identical by construction.
    #expect(AnnotationGeometry.flipped(arrow) == .arrow(from: to, to: from, strokeStyle))
    #expect(AnnotationGeometry.flipped(AnnotationGeometry.flipped(arrow)) == arrow)

    let line = Annotation.line(from: from, to: to, strokeStyle)
    #expect(AnnotationGeometry.flipped(line) == .line(from: to, to: from, strokeStyle))
}

@Test
func flippingLeavesKindsWithNoDirectionAlone() {
    let rect = Annotation.rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), strokeStyle)
    #expect(AnnotationGeometry.flipped(rect) == rect)
}

@Test
func onlyAPlacedArrowOffersFlip() {
    let arrow = Annotation.arrow(from: .zero, to: CGPoint(x: 10, y: 10), strokeStyle)
    let line = Annotation.line(from: .zero, to: CGPoint(x: 10, y: 10), strokeStyle)
    #expect(arrow.options.contains(.flip))
    #expect(!line.options.contains(.flip))
    #expect(!Tool.arrow.options.contains(.flip),
            "There is no direction to flip about a tool's default style")
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

/// How red the baked pixel is at a view point, over the white source.
@MainActor
private func inkAt(_ baked: CGImage, _ point: CGPoint) -> Bool {
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    let offset = (Int(point.y) - 10) * baked.bytesPerRow + (Int(point.x) - 10) * 4
    // The stroke is red on white: ink is anywhere the blue channel drops.
    return bytes[offset + 2] < 160
}

/// Samples along a horizontal stroke and reports how many of the sampled points
/// carry ink.
@MainActor
private func inkRun(_ baked: CGImage, y: CGFloat, from startX: Int, to endX: Int) -> Int {
    (startX...endX).filter { inkAt(baked, CGPoint(x: CGFloat($0), y: y)) }.count
}

@MainActor
@Test
func aDashedLineLeavesGapsWhereASolidOneDoesNot() {
    let (solidView, solidWindow) = makeHostedView()
    solidView.keyDown(with: key("l", 37, solidWindow))
    drag(in: solidView, window: solidWindow, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))
    guard let solid = bake(solidView, solidWindow) else {
        Issue.record("No baked image")
        return
    }

    let (view, window) = makeHostedView()
    view.keyDown(with: key("l", 37, window))
    optionsRow(of: view)?.onDashSelected?(.dashed)
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))
    guard let dashed = bake(view, window) else {
        Issue.record("No baked image")
        return
    }

    let solidInk = inkRun(solid, y: 100, from: 45, to: 155)
    let dashedInk = inkRun(dashed, y: 100, from: 45, to: 155)
    #expect(solidInk == 111, "A solid line should be ink the whole way along")
    #expect(dashedInk > 20 && dashedInk < solidInk - 15,
            "A dashed line should be part ink, part background, got \(dashedInk)")
}

/// Every overlay arrow below runs (40,100)→(160,100) at the default 3pt width,
/// which puts a 12pt head at each end. These sample inside a head's own spread,
/// 3pt off the centre line — clear of the 3pt shaft, so ink there means a head.
private let headEdge = CGPoint(x: 152, y: 103)
private let tailEdge = CGPoint(x: 48, y: 103)

@MainActor
@Test
func everyArrowHeadLeavesInkAtTheHeadEnd() {
    for head in ArrowHead.allCases {
        let (view, window) = makeHostedView()
        view.keyDown(with: key("a", 0, window))
        optionsRow(of: view)?.onArrowHeadSelected?(head)
        drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))

        guard let baked = bake(view, window) else {
            Issue.record("No baked image for \(head)")
            return
        }
        // Midway along the head's own edge: off the shaft entirely, so only a
        // head puts ink there.
        #expect(inkAt(baked, headEdge),
                "\(head) should leave ink at the head end")
    }
}

@MainActor
@Test
func aDoubleEndedArrowPutsAHeadAtBothEndsAndAStandardOneDoesNot() {
    for (head, expected) in [(ArrowHead.standard, false), (.doubleEnded, true)] {
        let (view, window) = makeHostedView()
        view.keyDown(with: key("a", 0, window))
        optionsRow(of: view)?.onArrowHeadSelected?(head)
        drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))

        guard let baked = bake(view, window) else {
            Issue.record("No baked image for \(head)")
            return
        }
        #expect(inkAt(baked, tailEdge) == expected,
                "\(head) at the tail end: expected ink == \(expected)")
    }
}

@MainActor
@Test
func flipMovesTheHeadToTheOtherEnd() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("a", 0, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))

    // Select the arrow by clicking its shaft, then flip it.
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
    optionsRow(of: view)?.onFlip?()

    guard let baked = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    #expect(inkAt(baked, tailEdge),
            "After the flip the head should be at the far end")
    #expect(!inkAt(baked, headEdge),
            "and no longer where it was drawn")
}

@MainActor
@Test
func dashAndHeadPersistAsToolDefaultsAndApplyToTheNextAnnotation() {
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

    view.keyDown(with: key("a", 0, window))
    optionsRow(of: view)?.onDashSelected?(.dotted)
    optionsRow(of: view)?.onArrowHeadSelected?(.openV)

    #expect(saved?.strokeDashStyle == DashStyle.dotted.rawValue)
    #expect(saved?.arrowHeadStyle == ArrowHead.openV.rawValue)

    // A fresh overlay loaded with those styles draws with them.
    let reloaded = RegionPickerView(
        frame: frame, image: nil, scale: 1.0, styles: saved ?? EditorStyles()
    )
    window.contentView = reloaded
    reloaded.keyDown(with: key("a", 0, window))
    drag(in: reloaded, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 120, y: 40))

    let row = optionsRow(of: reloaded)
    #expect(row?.dashControl.selectedIndex == DashStyle.allCases.firstIndex(of: .dotted))
    #expect(row?.headControl.selectedIndex == ArrowHead.allCases.firstIndex(of: .openV))
}

@MainActor
@Test
func rectangleStrokesStaySolidEvenWhenTheStrokeDefaultIsDashed() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("l", 37, window))
    optionsRow(of: view)?.onDashSelected?(.dashed)

    view.keyDown(with: key("r", 15, window))
    drag(in: view, window: window, from: CGPoint(x: 40, y: 60), to: CGPoint(x: 160, y: 140))

    guard let baked = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    // The rectangle's top edge should be continuous ink end to end.
    #expect(inkRun(baked, y: 60, from: 45, to: 155) == 111,
            "Dash styles are line-and-arrow only in this phase")
}
