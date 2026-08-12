import AppKit
import Testing
@testable import MacshotCore

// Pure annotation-geometry tests: an annotation value plus a point in, bounds /
// a hit / a new annotation out. No view, no window, no synthesized events —
// which is the whole point of extracting this seam out of the overlay.

private let strokeStyle = StrokeStyle(color: .systemRed, lineWidth: 3)
private let fillStyle = FillStyle(color: .black)
private let textStyle = TextStyle(color: .systemRed, fontSize: 22)
private let box = CGRect(x: 100, y: 100, width: 100, height: 50)

/// One of every kind, so a sweep can assert a property holds across all of them.
private let everyKind: [Annotation] = [
    .rectangle(box, strokeStyle),
    .ellipse(box, strokeStyle),
    .line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 90, y: 60), strokeStyle),
    .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 90, y: 60), strokeStyle),
    .freehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)], strokeStyle),
    .highlighter(
        points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)],
        StrokeStyle(color: NSColor.systemYellow.withAlphaComponent(0.35), lineWidth: 22)
    ),
    .text(box: CGRect(origin: CGPoint(x: 30, y: 40), size: TextLayout.defaultBoxSize), content: "Hello", textStyle),
    .callout(
        anchor: CGPoint(x: 10, y: 10), box: CGRect(origin: CGPoint(x: 80, y: 90), size: TextLayout.defaultBoxSize),
        content: "Note", textStyle
    ),
    .stepMarker(center: CGPoint(x: 50, y: 50), number: 1, FillStyle(color: .systemRed)),
    .measure(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 120, y: 30), strokeStyle),
    .loupe(
        source: CGPoint(x: 40, y: 40), sourceRadius: 20,
        lens: CGPoint(x: 140, y: 90), lensRadius: 40, .default
    ),
    .spotlight(box, .default),
    .fillRect(box, fillStyle),
    .fillFreehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)], fillStyle),
    .blur(box),
    .pixelate(box)
]

private func rgba(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    let c = color.usingColorSpace(.deviceRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
}

private func expectColor(_ actual: NSColor?, matches expected: NSColor) {
    guard let actual else {
        Issue.record("Expected a color, got nil")
        return
    }
    let a = rgba(actual)
    let e = rgba(expected)
    #expect(abs(a.0 - e.0) < 0.02 && abs(a.1 - e.1) < 0.02 && abs(a.2 - e.2) < 0.02
            && abs(a.3 - e.3) < 0.02,
            "Expected color \(e), got \(a)")
}

// MARK: - Bounds

@Test
func boundsOfRectLikeKindsIsTheRectItself() {
    for annotation in [Annotation.rectangle(box, strokeStyle), .ellipse(box, strokeStyle),
                       .fillRect(box, fillStyle), .blur(box), .pixelate(box)] {
        #expect(AnnotationGeometry.boundingBox(of: annotation) == box)
    }
}

@Test
func boundsOfLineLikeKindsSpansTheEndpointsRegardlessOfDirection() {
    let expected = CGRect(x: 10, y: 20, width: 80, height: 40)
    let forward = Annotation.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 90, y: 60), strokeStyle)
    let backward = Annotation.arrow(from: CGPoint(x: 90, y: 60), to: CGPoint(x: 10, y: 20), strokeStyle)
    #expect(AnnotationGeometry.boundingBox(of: forward) == expected)
    #expect(AnnotationGeometry.boundingBox(of: backward) == expected)
}

@Test
func boundsOfPointCloudsWrapsEveryPoint() {
    let points = [CGPoint(x: 30, y: 10), CGPoint(x: 10, y: 50), CGPoint(x: 60, y: 20)]
    let expected = CGRect(x: 10, y: 10, width: 50, height: 40)
    #expect(AnnotationGeometry.boundingBox(of: .freehand(points: points, strokeStyle)) == expected)
    #expect(AnnotationGeometry.boundingBox(of: .highlighter(points: points, strokeStyle)) == expected)
    #expect(AnnotationGeometry.boundingBox(of: .fillFreehand(points: points, fillStyle)) == expected)
}

@Test
func boundsOfAnEmptyPointCloudIsZero() {
    #expect(AnnotationGeometry.boundingBox(of: .freehand(points: [], strokeStyle)) == .zero)
}

@Test
func boundsOfTextIsItsBoxGrownToFitTheWrappedContent() {
    let box = CGRect(x: 30, y: 40, width: 120, height: 20)
    let short = AnnotationGeometry.boundingBox(of: .text(box: box, content: "Hi", textStyle))
    #expect(short.origin == box.origin)
    #expect(short.width == box.width, "The width the user chose is the wrap width")
    #expect(short.height >= box.height)

    // Enough words to need several lines at that width.
    let long = AnnotationGeometry.boundingBox(
        of: .text(box: box, content: String(repeating: "wrap ", count: 20), textStyle)
    )
    #expect(long.width == box.width, "Wrapping never widens the box")
    #expect(long.height > short.height, "The box grows in height to fit its content")
}

@Test
func boundsOfACalloutCoversBothTheBubbleAndTheAnchor() {
    let anchor = CGPoint(x: 10, y: 10)
    let bubble = CGPoint(x: 80, y: 90)
    let bounds = AnnotationGeometry.boundingBox(
        of: .callout(anchor: anchor, box: CGRect(origin: bubble, size: TextLayout.defaultBoxSize), content: "Note", textStyle)
    )
    let bubbleRect = CalloutGeometry.bubbleRect(box: CGRect(origin: bubble, size: TextLayout.defaultBoxSize), content: "Note", style: textStyle)
    #expect(bounds.contains(anchor))
    #expect(bounds.contains(CGPoint(x: bubbleRect.maxX - 1, y: bubbleRect.maxY - 1)))
}

@Test
func boundsOfAStepMarkerIsItsCircleAroundTheCenter() {
    let bounds = AnnotationGeometry.boundingBox(
        of: .stepMarker(center: CGPoint(x: 50, y: 50), number: 1, FillStyle(color: .systemRed))
    )
    #expect(bounds == CGRect(x: 36, y: 36, width: 28, height: 28))
}

// MARK: - Hit-testing

@Test
func aDiagonalLineIsHitOnItsStrokeAndMissedElsewhereInItsBoundingBox() {
    let line = Annotation.line(from: .zero, to: CGPoint(x: 100, y: 100), strokeStyle)
    #expect(AnnotationGeometry.hitTest(line, at: CGPoint(x: 50, y: 50)))
    #expect(AnnotationGeometry.hitTest(line, at: CGPoint(x: 50, y: 52)))
    // Inside the bounding box, far from the ink.
    #expect(!AnnotationGeometry.hitTest(line, at: CGPoint(x: 90, y: 10)))
}

@Test
func aPolylineIsHitNearAnyOfItsSegments() {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)]
    for annotation in [Annotation.freehand(points: points, strokeStyle),
                       .highlighter(points: points, strokeStyle)] {
        #expect(AnnotationGeometry.hitTest(annotation, at: CGPoint(x: 25, y: 2)))
        #expect(AnnotationGeometry.hitTest(annotation, at: CGPoint(x: 48, y: 40)))
        #expect(!AnnotationGeometry.hitTest(annotation, at: CGPoint(x: 25, y: 25)))
    }
}

@Test
func aSingleStrokePointCanNeverBeHit() {
    #expect(!AnnotationGeometry.hitTest(
        .freehand(points: [CGPoint(x: 10, y: 10)], strokeStyle), at: CGPoint(x: 10, y: 10)
    ))
}

@Test
func rectLikeKindsAreHitInsideTheirToleranceAndMissedOutsideIt() {
    let rectangle = Annotation.rectangle(box, strokeStyle)
    #expect(AnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 150, y: 125)))
    // 3pt outside the edge is within the 4pt tolerance; 6pt is not.
    #expect(AnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 97, y: 125)))
    #expect(!AnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 94, y: 125)))
}

@Test
func aFarAwayPointHitsNothing() {
    for annotation in everyKind {
        #expect(!AnnotationGeometry.hitTest(annotation, at: CGPoint(x: 5000, y: 5000)),
                "\(annotation) should not be hit at (5000, 5000)")
    }
}

@Test
func theTopmostOverlappingAnnotationWins() {
    let lower = Annotation.rectangle(box, strokeStyle)
    let upper = Annotation.fillRect(box, fillStyle)
    let point = CGPoint(x: 150, y: 125)
    #expect(AnnotationGeometry.hitIndex(in: [lower, upper], at: point) == 1)
    #expect(AnnotationGeometry.hitIndex(in: [upper, lower], at: point) == 1)
    #expect(AnnotationGeometry.hitIndex(in: [lower, upper], at: CGPoint(x: 5000, y: 5000)) == nil)
}

// MARK: - Handles

@Test
func rectHandlesSitOnTheCornersEdgeMidpointsOfTheBox() {
    let positions = Dictionary(
        uniqueKeysWithValues: AnnotationGeometry.rectHandlePositions(box).map { ("\($0.0)", $0.1) }
    )
    #expect(positions["topLeft"] == CGPoint(x: 100, y: 100))
    #expect(positions["top"] == CGPoint(x: 150, y: 100))
    #expect(positions["topRight"] == CGPoint(x: 200, y: 100))
    #expect(positions["left"] == CGPoint(x: 100, y: 125))
    #expect(positions["right"] == CGPoint(x: 200, y: 125))
    #expect(positions["bottomLeft"] == CGPoint(x: 100, y: 150))
    #expect(positions["bottom"] == CGPoint(x: 150, y: 150))
    #expect(positions["bottomRight"] == CGPoint(x: 200, y: 150))
}

@Test
func rectLikeKindsGetEightHandlesAndLineLikeKindsGetTheirEndpoints() {
    for annotation in [Annotation.rectangle(box, strokeStyle), .ellipse(box, strokeStyle),
                       .fillRect(box, fillStyle), .blur(box), .pixelate(box)] {
        #expect(AnnotationGeometry.handlePositions(for: annotation).count == 8)
    }
    let from = CGPoint(x: 10, y: 20)
    let to = CGPoint(x: 90, y: 60)
    for annotation in [Annotation.line(from: from, to: to, strokeStyle),
                       .arrow(from: from, to: to, strokeStyle)] {
        let handles = AnnotationGeometry.handlePositions(for: annotation)
        #expect(handles.count == 2)
        #expect(handles.first?.1 == from)
        #expect(handles.last?.1 == to)
    }
}

@Test
func aCalloutGetsAnAnchorHandleAndABubbleCenterHandle() {
    let anchor = CGPoint(x: 10, y: 10)
    let bubble = CGPoint(x: 80, y: 90)
    let rect = CalloutGeometry.bubbleRect(box: CGRect(origin: bubble, size: TextLayout.defaultBoxSize), content: "Note", style: textStyle)
    let handles = AnnotationGeometry.handlePositions(
        for: .callout(anchor: anchor, box: CGRect(origin: bubble, size: TextLayout.defaultBoxSize), content: "Note", textStyle)
    )
    #expect(handles.count == 2)
    #expect(handles.first?.1 == anchor)
    #expect(handles.last?.1 == CGPoint(x: rect.midX, y: rect.midY))
}

@Test
func kindsWithoutResizeGeometryOfferNoHandles() {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)]
    for annotation in [Annotation.stepMarker(center: .zero, number: 1, FillStyle(color: .systemRed)),
                       .freehand(points: points, strokeStyle),
                       .highlighter(points: points, strokeStyle),
                       .fillFreehand(points: points, fillStyle)] {
        #expect(AnnotationGeometry.handlePositions(for: annotation).isEmpty)
    }
}

@Test
func aHandleGrabsWithinHalfItsSizePlusTwoAndNotBeyond() {
    let rectangle = Annotation.rectangle(box, strokeStyle)
    let corner = CGPoint(x: 100, y: 100)
    let grabbed = AnnotationGeometry.handle(at: corner, on: rectangle, handleSize: 10)
    #expect(grabbed == .topLeft)
    // handleSize 10 → 7pt of slop.
    #expect(AnnotationGeometry.handle(
        at: CGPoint(x: corner.x + 7, y: corner.y - 7), on: rectangle, handleSize: 10
    ) != nil)
    #expect(AnnotationGeometry.handle(
        at: CGPoint(x: corner.x - 8, y: corner.y - 8), on: rectangle, handleSize: 10
    ) == nil)
}

@Test
func rectHandleHitTestingWorksOffAPlainRect() {
    #expect(AnnotationGeometry.rectHandle(
        at: CGPoint(x: 200, y: 150), in: box, handleSize: 10
    ) == .bottomRight)
    #expect(AnnotationGeometry.rectHandle(
        at: CGPoint(x: 150, y: 125), in: box, handleSize: 10
    ) == nil)
}

// MARK: - Translation

@Test
func translationMovesEveryKindByTheSameDelta() {
    for annotation in everyKind {
        let before = AnnotationGeometry.boundingBox(of: annotation)
        let moved = AnnotationGeometry.translate(annotation, dx: 12, dy: -7)
        #expect(AnnotationGeometry.boundingBox(of: moved) == before.offsetBy(dx: 12, dy: -7),
                "\(annotation) did not translate as a whole")
    }
}

@Test
func translatingACalloutMovesBothItsAnchorAndItsBubble() {
    let moved = AnnotationGeometry.translate(
        .callout(anchor: CGPoint(x: 10, y: 10), box: CGRect(origin: CGPoint(x: 80, y: 90), size: TextLayout.defaultBoxSize),
                 content: "Note", textStyle),
        dx: 5, dy: 6
    )
    guard case let .callout(anchor, box, _, _) = moved else {
        Issue.record("Expected a callout")
        return
    }
    #expect(anchor == CGPoint(x: 15, y: 16))
    #expect(box.origin == CGPoint(x: 85, y: 96))
}

// MARK: - Resize

@Test
func resizingFromEachRectHandleMovesOnlyThatHandlesEdges() {
    let cases: [(ResizeHandle, CGPoint, CGRect)] = [
        (.topLeft, CGPoint(x: 90, y: 90), CGRect(x: 90, y: 90, width: 110, height: 60)),
        (.top, CGPoint(x: 0, y: 80), CGRect(x: 100, y: 80, width: 100, height: 70)),
        (.topRight, CGPoint(x: 220, y: 90), CGRect(x: 100, y: 90, width: 120, height: 60)),
        (.left, CGPoint(x: 60, y: 0), CGRect(x: 60, y: 100, width: 140, height: 50)),
        (.right, CGPoint(x: 250, y: 0), CGRect(x: 100, y: 100, width: 150, height: 50)),
        (.bottomLeft, CGPoint(x: 80, y: 180), CGRect(x: 80, y: 100, width: 120, height: 80)),
        (.bottom, CGPoint(x: 0, y: 200), CGRect(x: 100, y: 100, width: 100, height: 100)),
        (.bottomRight, CGPoint(x: 210, y: 210), CGRect(x: 100, y: 100, width: 110, height: 110))
    ]
    for (handle, point, expected) in cases {
        #expect(AnnotationGeometry.resizedRect(box, handle: handle, to: point) == expected,
                "Resizing from \(handle)")
    }
}

@Test
func draggingAHandlePastTheOppositeEdgeFlipsTheRectInsteadOfInvertingIt() {
    let flipped = AnnotationGeometry.resizedRect(box, handle: .left, to: CGPoint(x: 260, y: 0))
    #expect(flipped == CGRect(x: 200, y: 100, width: 60, height: 50))
    #expect(flipped.width > 0 && flipped.height > 0)
}

@Test
func resizingCarriesTheKindAndItsStyleThrough() {
    let point = CGPoint(x: 250, y: 0)
    let resized = AnnotationGeometry.resize(
        .ellipse(box, strokeStyle), handle: .right, to: point
    )
    guard case let .ellipse(rect, style) = resized else {
        Issue.record("Expected an ellipse")
        return
    }
    #expect(rect == AnnotationGeometry.resizedRect(box, handle: .right, to: point))
    #expect(style.lineWidth == strokeStyle.lineWidth)
}

@Test
func resizingALineOrArrowMovesOnlyTheDraggedEndpoint() {
    let from = CGPoint(x: 10, y: 20)
    let to = CGPoint(x: 90, y: 60)
    let moved = CGPoint(x: 200, y: 200)

    guard case let .line(start, end, _) = AnnotationGeometry.resize(
        .line(from: from, to: to, strokeStyle), handle: .lineStart, to: moved
    ) else {
        Issue.record("Expected a line")
        return
    }
    #expect(start == moved && end == to)

    guard case let .arrow(arrowStart, arrowEnd, _) = AnnotationGeometry.resize(
        .arrow(from: from, to: to, strokeStyle), handle: .lineEnd, to: moved
    ) else {
        Issue.record("Expected an arrow")
        return
    }
    #expect(arrowStart == from && arrowEnd == moved)
}

@Test
func resizingACalloutMovesTheAnchorOrRecentersTheBubbleOnTheHandle() {
    let callout = Annotation.callout(
        anchor: CGPoint(x: 10, y: 10), box: CGRect(origin: CGPoint(x: 80, y: 90), size: TextLayout.defaultBoxSize),
        content: "Note", textStyle
    )
    let target = CGPoint(x: 300, y: 300)

    guard case let .callout(anchor, box, _, _) = AnnotationGeometry.resize(
        callout, handle: .lineStart, to: target
    ) else {
        Issue.record("Expected a callout")
        return
    }
    #expect(anchor == target)
    #expect(box.origin == CGPoint(x: 80, y: 90))

    guard case let .callout(_, movedBox, _, _) = AnnotationGeometry.resize(
        callout, handle: .lineEnd, to: target
    ) else {
        Issue.record("Expected a callout")
        return
    }
    let rect = CalloutGeometry.bubbleRect(box: movedBox, content: "Note", style: textStyle)
    #expect(abs(rect.midX - target.x) < 0.01 && abs(rect.midY - target.y) < 0.01,
            "The bubble handle should keep the bubble centered on the cursor")
}

@Test
func kindsWithoutResizeGeometryComeBackUnchanged() {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)]
    for annotation in [Annotation.stepMarker(center: .zero, number: 1, FillStyle(color: .systemRed)),
                       .freehand(points: points, strokeStyle),
                       .fillFreehand(points: points, fillStyle)] {
        let resized = AnnotationGeometry.resize(annotation, handle: .topLeft, to: CGPoint(x: 9, y: 9))
        #expect(AnnotationGeometry.boundingBox(of: resized)
                == AnnotationGeometry.boundingBox(of: annotation))
    }
}

// MARK: - Composed style axes

@Test
func everyKindReportsTheAxesItCarries() {
    let strokeKinds: [Annotation] = [
        .rectangle(box, strokeStyle), .ellipse(box, strokeStyle),
        .line(from: .zero, to: CGPoint(x: 1, y: 1), strokeStyle),
        .arrow(from: .zero, to: CGPoint(x: 1, y: 1), strokeStyle),
        .freehand(points: [.zero], strokeStyle), .highlighter(points: [.zero], strokeStyle)
    ]
    for annotation in strokeKinds {
        #expect(annotation.style.lineWidth == 3)
        #expect(annotation.style.fontSize == nil)
        expectColor(annotation.style.color, matches: .systemRed)
    }

    for annotation in [Annotation.text(box: CGRect(origin: .zero, size: TextLayout.defaultBoxSize), content: "Hi", textStyle),
                       .callout(anchor: .zero, box: CGRect(origin: .zero, size: TextLayout.defaultBoxSize), content: "Hi", textStyle)] {
        #expect(annotation.style.fontSize == 22)
        #expect(annotation.style.lineWidth == nil)
    }

    for annotation in [Annotation.fillRect(box, fillStyle),
                       .fillFreehand(points: [.zero], fillStyle),
                       .stepMarker(center: .zero, number: 1, FillStyle(color: .black))] {
        expectColor(annotation.style.color, matches: .black)
        #expect(annotation.style.lineWidth == nil && annotation.style.fontSize == nil)
    }

    for annotation in [Annotation.blur(box), .pixelate(box)] {
        #expect(annotation.style == AnnotationStyle())
    }
}

@Test
func writingAnAxisAKindCarriesChangesIt() {
    for annotation in everyKind where annotation.style.color != nil {
        let recolored = annotation.applyingStyle { $0.color = .systemBlue }
        #expect(recolored.style.color != nil, "\(annotation) lost its color")
        if case .highlighter = annotation { continue }
        expectColor(recolored.style.color, matches: .systemBlue)
    }

    let thicker = Annotation.rectangle(box, strokeStyle).applyingStyle { $0.lineWidth = 9 }
    #expect(thicker.style.lineWidth == 9)

    let bigger = Annotation.text(box: CGRect(origin: .zero, size: TextLayout.defaultBoxSize), content: "Hi", textStyle)
        .applyingStyle { $0.fontSize = 40 }
    #expect(bigger.style.fontSize == 40)
}

@Test
func writingAnAxisAKindDoesNotCarryIsIgnored() {
    let text = Annotation.text(box: CGRect(origin: .zero, size: TextLayout.defaultBoxSize), content: "Hi", textStyle)
    #expect(text.applyingStyle { $0.lineWidth = 99 } == text)

    let rectangle = Annotation.rectangle(box, strokeStyle)
    #expect(rectangle.applyingStyle { $0.fontSize = 99 } == rectangle)
}

@Test
func recoloringAHighlighterTakesTheNewColorsOwnTransparency() {
    // Transparency used to belong to the tool and survive a recolour. It is an
    // axis of the colour now, so the highlighter takes whatever the picker
    // hands it — including fully opaque.
    let highlighter = Annotation.highlighter(
        points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)],
        StrokeStyle(color: NSColor.systemYellow.withAlphaComponent(0.35), lineWidth: 22)
    )
    let opaque = highlighter.applyingStyle { $0.color = .systemBlue }
    expectColor(opaque.style.color, matches: .systemBlue)

    let translucent = highlighter.applyingStyle {
        $0.color = NSColor.systemBlue.withAlphaComponent(0.5)
    }
    expectColor(translucent.style.color, matches: NSColor.systemBlue.withAlphaComponent(0.5))
}

@Test
func redactionsThatCarryNoStyleAreUnchangedByAnyStyleWrite() {
    for annotation in [Annotation.blur(box), .pixelate(box)] {
        let written = annotation.applyingStyle {
            $0.color = .systemBlue
            $0.lineWidth = 9
            $0.fontSize = 40
        }
        #expect(written == annotation)
    }
}

@Test
func everyKindMapsToTheToolThatDrawsIt() {
    let expected: [Tool] = [
        .rectangle, .ellipse, .line, .arrow, .pen, .highlighter, .text, .callout,
        .stepMarker, .measure, .loupe, .spotlight,
        .fillRect, .fillFreehand, .blur, .pixelate
    ]
    #expect(everyKind.map(\.tool) == expected)
}

// MARK: - Applicable options

@Test
func eachToolOffersExactlyTheOptionsItsAnnotationsCarry() {
    let expected: [Tool: AnnotationOptions] = [
        .select: [],
        .rectangle: [.color, .lineWidth, .fillMode, .cornerRadius],
        .ellipse: [.color, .lineWidth, .fillMode],
        .line: [.color, .lineWidth, .dash],
        .arrow: [.color, .lineWidth, .dash, .arrowHead],
        .pen: [.color, .lineWidth],
        .highlighter: [.color, .lineWidth],
        .spotlight: [.spotlightShape, .dimStrength],
        .text: .richText,
        .callout: .richText,
        .stepMarker: [.color],
        .measure: [.color, .lineWidth],
        .loupe: [.color, .magnification, .outlineVisible],
        .fillRect: [.color],
        .fillFreehand: [.color],
        .blur: [],
        .pixelate: []
    ]
    for tool in Tool.allCases {
        #expect(tool.options == expected[tool], "Options for \(tool)")
    }
}

@Test
func theOptionsAToolOffersMatchTheAxesTheStyleActuallyCarries() {
    for annotation in everyKind {
        let options = annotation.options
        #expect(options.contains(.color) == (annotation.style.color != nil),
                "\(annotation): color option and colour axis disagree")
        #expect(options.contains(.lineWidth) == (annotation.style.lineWidth != nil),
                "\(annotation): line-width option and axis disagree")
        #expect(options.contains(.fontSize) == (annotation.style.fontSize != nil),
                "\(annotation): font-size option and axis disagree")
    }
}

@Test
func toolsWithNothingToConfigureOfferNoOptionsAtAll() {
    for tool in [Tool.select, .blur, .pixelate] {
        #expect(tool.options.isEmpty, "\(tool) should collapse the options row")
    }
}

// MARK: - Rotation

private let quarterTurn = CGFloat.pi / 2

/// The kinds that take a rotation handle; everything else is direction-encoding
/// geometry or an axis-aligned redaction crop.
private let rotatableTools: Set<Tool> = [.rectangle, .ellipse, .fillRect, .text, .callout]

@Test
func rotationIsOfferedOnlyForRectLikeAndTextKinds() {
    for annotation in everyKind {
        #expect(annotation.supportsRotation == rotatableTools.contains(annotation.tool),
                "\(annotation.tool) rotatability")
        guard !annotation.supportsRotation else { continue }
        #expect(annotation.rotated(to: quarterTurn) == annotation,
                "\(annotation.tool) should ignore a rotation")
        #expect(AnnotationGeometry.rotationHandlePosition(for: annotation) == nil,
                "\(annotation.tool) should show no rotation handle")
    }
}

@Test
func rotationRoundTripsAndAFullTurnComparesEqualToNone() {
    let straight = Annotation.rectangle(box, strokeStyle)
    #expect(straight.rotation == 0)

    let turned = straight.rotated(to: quarterTurn)
    #expect(abs(turned.rotation - quarterTurn) < 1e-9)

    #expect(turned.rotated(to: 2 * .pi) == straight)
    #expect(turned.rotated(to: 2 * .pi).rotation == 0)
    // A turn the other way lands on the same angle read forwards.
    #expect(abs(straight.rotated(to: -quarterTurn).rotation - 3 * quarterTurn) < 1e-9)
    #expect(abs(straight.rotated(to: 5 * quarterTurn).rotation - quarterTurn) < 1e-9)
}

@Test
func rotatingAPointTurnsItAboutTheCentreAndBackAgain() {
    let center = CGPoint(x: 100, y: 100)
    let point = CGPoint(x: 140, y: 100)

    // View coordinates are flipped, so a positive quarter turn takes a point to
    // the right of the centre to a point below it — the same way the context
    // turns when the annotation is drawn.
    let turned = point.rotated(by: quarterTurn, about: center)
    #expect(abs(turned.x - 100) < 1e-6 && abs(turned.y - 140) < 1e-6)

    let back = turned.rotated(by: -quarterTurn, about: center)
    #expect(abs(back.x - point.x) < 1e-6 && abs(back.y - point.y) < 1e-6)
}

@Test
func aRotatedAnnotationIsHitWhereItIsDrawnAndNotWhereItsBoxUsedToBe() {
    // box is 100×50 at (100,100); a quarter turn about (150,125) makes it 50×100.
    let straight = Annotation.rectangle(box, strokeStyle)
    let turned = straight.rotated(to: quarterTurn)

    let insideTurned = CGPoint(x: 150, y: 90)
    let insideStraight = CGPoint(x: 110, y: 125)

    #expect(AnnotationGeometry.hitTest(turned, at: insideTurned))
    #expect(!AnnotationGeometry.hitTest(turned, at: insideStraight))
    #expect(AnnotationGeometry.hitTest(straight, at: insideStraight))
    #expect(!AnnotationGeometry.hitTest(straight, at: insideTurned))
}

@Test
func resizeHandlesRideTheRotation() {
    let straight = Annotation.rectangle(box, strokeStyle)
    let turned = straight.rotated(to: quarterTurn)

    let topLeft = AnnotationGeometry.handlePositions(for: turned).first { $0.0 == .topLeft }?.1
    #expect(topLeft != nil)
    // (100,100) turned a quarter about (150,125).
    #expect(abs((topLeft?.x ?? 0) - 175) < 1e-6 && abs((topLeft?.y ?? 0) - 75) < 1e-6)

    // Unrotated, the handles are exactly where they always were.
    let flat = AnnotationGeometry.handlePositions(for: straight).first { $0.0 == .topLeft }?.1
    #expect(flat == CGPoint(x: box.minX, y: box.minY))
}

@Test
func theRotationHandleSitsAboveTheBoxAndTurnsWithIt() {
    let straight = Annotation.rectangle(box, strokeStyle)
    let knob = AnnotationGeometry.rotationHandlePosition(for: straight)
    #expect(knob == CGPoint(x: box.midX, y: box.minY - AnnotationGeometry.rotationHandleOffset))

    // Half a turn puts it the same distance below the bottom edge.
    let flipped = AnnotationGeometry.rotationHandlePosition(for: straight.rotated(to: .pi))
    #expect(abs((flipped?.x ?? 0) - box.midX) < 1e-6)
    #expect(abs((flipped?.y ?? 0) - (box.maxY + AnnotationGeometry.rotationHandleOffset)) < 1e-6)
}

@Test
func draggingTheHandleStraightAboveTheCentreMeansNoRotation() {
    let straight = Annotation.rectangle(box, strokeStyle)
    let above = CGPoint(x: box.midX, y: box.minY - 60)
    #expect(abs(AnnotationGeometry.rotation(of: straight, towards: above, snapping: false)) < 1e-9)
}

@Test
func shiftSnapsRotationToExactQuarterTurns() {
    let straight = Annotation.rectangle(box, strokeStyle)
    // Just past 3 o'clock from the centre (150,125): a hair over a quarter turn.
    let point = CGPoint(x: 250, y: 135)

    let free = AnnotationGeometry.rotation(of: straight, towards: point, snapping: false)
    #expect(abs(free - quarterTurn) > 0.05, "Unsnapped rotation should follow the pointer exactly")
    #expect(abs(free - quarterTurn) < 0.3)

    let snapped = AnnotationGeometry.rotation(of: straight, towards: point, snapping: true)
    #expect(abs(snapped - quarterTurn) < 1e-9)
}

@Test
func resizingARotatedBoxMovesTheDraggedEdgeAndLeavesTheOppositeOneWhereItIs() {
    let turned = Annotation.rectangle(box, strokeStyle).rotated(to: quarterTurn)
    // On screen the turned box spans x 125…175, y 75…175, and the left handle
    // has ridden round to the top edge at (150,75).
    let left = AnnotationGeometry.handlePositions(for: turned).first { $0.0 == .left }?.1
    #expect(left == CGPoint(x: 150, y: 75))

    let resized = AnnotationGeometry.resize(
        turned, handle: .left, to: CGPoint(x: 150, y: 55)
    )
    let corners = AnnotationGeometry.rotatedCorners(of: resized)
    let xs = corners.map(\.x), ys = corners.map(\.y)

    #expect(abs(xs.min()! - 125) < 1e-6 && abs(xs.max()! - 175) < 1e-6,
            "The sides the drag did not touch should not have moved")
    #expect(abs(ys.min()! - 55) < 1e-6, "The dragged edge should follow the pointer")
    #expect(abs(ys.max()! - 175) < 1e-6, "The opposite edge should stay put")
    #expect(abs(resized.rotation - quarterTurn) < 1e-9, "Resizing should not change the angle")
}

@Test
func anUnrotatedAnnotationsCornersAreItsPlainBox() {
    let corners = AnnotationGeometry.rotatedCorners(of: .rectangle(box, strokeStyle))
    #expect(corners == [
        CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
        CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)
    ])
}

// MARK: - Marquee

@Test
func aMarqueeTakesWhatItTouchesNotOnlyWhatItContains() {
    let rect = Annotation.rectangle(box, strokeStyle)
    #expect(AnnotationGeometry.intersects(
        rect, marquee: CGRect(x: 50, y: 50, width: 200, height: 200)
    ), "A marquee that swallows the annotation takes it")
    #expect(AnnotationGeometry.intersects(
        rect, marquee: CGRect(x: 50, y: 50, width: 60, height: 60)
    ), "Clipping one corner is enough")
    #expect(AnnotationGeometry.intersects(
        rect, marquee: CGRect(x: 120, y: 110, width: 10, height: 10)
    ), "A marquee entirely inside the annotation still touches it")
    #expect(!AnnotationGeometry.intersects(
        rect, marquee: CGRect(x: 0, y: 0, width: 40, height: 40)
    ), "A disjoint marquee takes nothing")
}

@Test
func aMarqueeUsesARotatedAnnotationsOrientedBounds() {
    let turned = Annotation.rectangle(box, strokeStyle).rotated(to: quarterTurn)
    // The turned box spans x 125…175, y 75…175.
    #expect(AnnotationGeometry.intersects(
        turned, marquee: CGRect(x: 140, y: 60, width: 20, height: 30)
    ), "A marquee over where the turned box is should take it")
    #expect(!AnnotationGeometry.intersects(
        turned, marquee: CGRect(x: 100, y: 120, width: 20, height: 10)
    ), "A marquee over where its unrotated box used to be should not")
}

@Test
func aMarqueeNearADiagonalStrokeMissesItAndOneCrossingItTakesIt() {
    let diagonal = Annotation.line(
        from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100), strokeStyle
    )
    #expect(!AnnotationGeometry.intersects(
        diagonal, marquee: CGRect(x: 70, y: 10, width: 20, height: 20)
    ), "Inside the line's bounding box but well off the ink is a miss")
    #expect(AnnotationGeometry.intersects(
        diagonal, marquee: CGRect(x: 40, y: 45, width: 20, height: 10)
    ), "A marquee straddling the ink takes it")
}

@Test
func marqueeMembershipComesBackInZOrder() {
    let annotations: [Annotation] = [
        .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), strokeStyle),
        .rectangle(CGRect(x: 100, y: 100, width: 10, height: 10), strokeStyle),
        .rectangle(CGRect(x: 20, y: 20, width: 10, height: 10), strokeStyle)
    ]
    let touched = AnnotationGeometry.indices(
        in: annotations, touching: CGRect(x: 0, y: 0, width: 50, height: 50)
    )
    #expect(touched == [0, 2])
}

@Test
func combinedBoundsWrapEveryAnnotationWhereItIsDrawn() {
    let first = Annotation.rectangle(CGRect(x: 10, y: 10, width: 20, height: 20), strokeStyle)
    let second = Annotation.fillRect(CGRect(x: 60, y: 40, width: 20, height: 20), fillStyle)
    #expect(AnnotationGeometry.combinedBounds(of: [first, second])
            == CGRect(x: 10, y: 10, width: 70, height: 50))
    #expect(AnnotationGeometry.combinedBounds(of: []) == nil)

    // A turned annotation contributes the box it actually occupies, not the
    // one it was drawn as.
    let turned = Annotation.rectangle(box, strokeStyle).rotated(to: quarterTurn)
    let bounds = AnnotationGeometry.combinedBounds(of: [turned])
    #expect(abs((bounds?.minX ?? 0) - 125) < 1e-6)
    #expect(abs((bounds?.maxX ?? 0) - 175) < 1e-6)
    #expect(abs((bounds?.minY ?? 0) - 75) < 1e-6)
    #expect(abs((bounds?.maxY ?? 0) - 175) < 1e-6)
}
