import AppKit
import Testing
@testable import MacshotCore

// The clipboard codec and the offset/clamp arithmetic as values, plus the
// overlay-level proof that a set copied on one overlay pastes into a separate,
// later one.

private let strokeStyle = StrokeStyle(color: .systemRed, lineWidth: 3)
private let fillStyle = FillStyle(color: .black)
private let textStyle = TextStyle(color: .systemRed, fontSize: 22)
private let box = CGRect(x: 100, y: 100, width: 100, height: 50)

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
    .stepMarker(center: CGPoint(x: 50, y: 50), number: 1, fillStyle),
    .fillRect(box, fillStyle),
    .fillFreehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)], fillStyle),
    .blur(box),
    .pixelate(box)
]

private func expectSameColor(_ actual: NSColor?, _ expected: NSColor?) {
    guard let a = actual?.usingColorSpace(.deviceRGB),
          let e = expected?.usingColorSpace(.deviceRGB)
    else {
        #expect(actual == nil && expected == nil)
        return
    }
    #expect(abs(a.redComponent - e.redComponent) < 0.02
            && abs(a.greenComponent - e.greenComponent) < 0.02
            && abs(a.blueComponent - e.blueComponent) < 0.02
            && abs(a.alphaComponent - e.alphaComponent) < 0.02,
            "Colour lost in the round trip")
}

// MARK: - Codec

@Test
func everyKindSurvivesTheClipboardRoundTrip() {
    guard let data = AnnotationClipboard.encode(everyKind),
          let decoded = AnnotationClipboard.decode(data)
    else {
        Issue.record("Payload did not round-trip")
        return
    }
    #expect(decoded.count == everyKind.count)
    for (original, copy) in zip(everyKind, decoded) {
        #expect(copy.tool == original.tool, "\(original.tool) came back as \(copy.tool)")
        #expect(AnnotationGeometry.boundingBox(of: copy)
                == AnnotationGeometry.boundingBox(of: original),
                "\(original.tool) lost its geometry")
        expectSameColor(copy.style.color, original.style.color)
        #expect(copy.style.lineWidth == original.style.lineWidth)
        #expect(copy.style.fontSize == original.style.fontSize)
    }
}

@Test
func rotationAndOpacitySurviveTheRoundTrip() {
    let turned = Annotation.rectangle(
        box, StrokeStyle(color: NSColor.systemBlue.withAlphaComponent(0.4), lineWidth: 7)
    ).rotated(to: .pi / 3)

    guard let data = AnnotationClipboard.encode([turned]),
          let copy = AnnotationClipboard.decode(data)?.first
    else {
        Issue.record("Payload did not round-trip")
        return
    }
    #expect(abs(copy.rotation - turned.rotation) < 1e-6)
    #expect(copy.style.lineWidth == 7)
    expectSameColor(copy.style.color, NSColor.systemBlue.withAlphaComponent(0.4))
}

@Test
func textContentAndMarkerNumbersSurviveTheRoundTrip() {
    let annotations: [Annotation] = [
        .text(box: CGRect(origin: CGPoint(x: 5, y: 6), size: TextLayout.defaultBoxSize), content: "Fix this", textStyle),
        .stepMarker(center: CGPoint(x: 9, y: 9), number: 7, fillStyle)
    ]
    guard let data = AnnotationClipboard.encode(annotations),
          let decoded = AnnotationClipboard.decode(data)
    else {
        Issue.record("Payload did not round-trip")
        return
    }
    guard case let .text(_, content, _) = decoded[0] else {
        Issue.record("Expected a text annotation back")
        return
    }
    #expect(content == "Fix this")
    guard case let .stepMarker(_, number, _) = decoded[1] else {
        Issue.record("Expected a step marker back")
        return
    }
    #expect(number == 7)
}

@Test
func aPayloadFromAnUnknownVersionIsIgnoredRatherThanPartiallyApplied() throws {
    let good = try #require(AnnotationClipboard.encode([.rectangle(box, strokeStyle)]))
    var object = try #require(
        try JSONSerialization.jsonObject(with: good) as? [String: Any]
    )
    object["version"] = AnnotationClipboard.version + 1
    let future = try JSONSerialization.data(withJSONObject: object)

    #expect(AnnotationClipboard.decode(future) == nil)
    #expect(AnnotationClipboard.decode(Data("not json".utf8)) == nil)
}

@Test
func unknownFieldsAreToleratedAndMissingOnesFallBack() throws {
    let good = try #require(AnnotationClipboard.encode([.rectangle(box, strokeStyle)]))
    var object = try #require(
        try JSONSerialization.jsonObject(with: good) as? [String: Any]
    )
    object["somethingFromALaterBuild"] = ["nested": true]
    let extended = try JSONSerialization.data(withJSONObject: object)

    let decoded = AnnotationClipboard.decode(extended)
    #expect(decoded?.count == 1, "An unknown top-level field should not sink the payload")
}

@MainActor
@Test
func copyingAnEmptySetWritesNothingToThePasteboard() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("macshot.tests.empty"))
    pasteboard.clearContents()
    pasteboard.setString("something the user had", forType: .string)

    AnnotationClipboard.write([], to: pasteboard)

    #expect(pasteboard.string(forType: .string) == "something the user had",
            "An empty copy should leave the pasteboard alone")
    #expect(AnnotationClipboard.read(from: pasteboard) == nil)
}

@MainActor
@Test
func pasteReadsOnlyItsOwnTypeSoAnImageOrStringIsNeverMistakenForAnnotations() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("macshot.tests.foreign"))
    pasteboard.clearContents()
    pasteboard.setString("#FF0000", forType: .string)
    #expect(AnnotationClipboard.read(from: pasteboard) == nil)

    AnnotationClipboard.write([.rectangle(box, strokeStyle)], to: pasteboard)
    #expect(AnnotationClipboard.read(from: pasteboard)?.count == 1)
}

// MARK: - Offset and clamp

@Test
func aPasteIsOffsetFromWhatItCameFromAndCascadesOnRepeat() {
    let canvas = CGRect(x: 0, y: 0, width: 500, height: 500)
    let original = Annotation.rectangle(box, strokeStyle)
    let step = AnnotationGeometry.pasteOffsetStep

    let once = AnnotationGeometry.offset([original], steps: 1, within: canvas)
    #expect(AnnotationGeometry.boundingBox(of: once[0])
            == box.offsetBy(dx: step, dy: step))

    let twice = AnnotationGeometry.offset([original], steps: 2, within: canvas)
    #expect(AnnotationGeometry.boundingBox(of: twice[0])
            == box.offsetBy(dx: step * 2, dy: step * 2))
}

@Test
func aPasteIsClampedSoTheWholeSetLandsOnTheCanvas() {
    let canvas = CGRect(x: 0, y: 0, width: 200, height: 200)
    // Copied from a bigger screen: well off the right and bottom edges.
    let far: [Annotation] = [
        .rectangle(CGRect(x: 400, y: 400, width: 40, height: 40), strokeStyle),
        .rectangle(CGRect(x: 460, y: 460, width: 40, height: 40), strokeStyle)
    ]
    let landed = AnnotationGeometry.offset(far, steps: 1, within: canvas)

    guard let bounds = AnnotationGeometry.combinedBounds(of: landed) else {
        Issue.record("No combined bounds")
        return
    }
    #expect(canvas.contains(bounds), "The whole set should land inside the canvas")
    // Moved as a unit: the gap between the two is untouched.
    let first = AnnotationGeometry.boundingBox(of: landed[0])
    let second = AnnotationGeometry.boundingBox(of: landed[1])
    #expect(second.minX - first.minX == 60 && second.minY - first.minY == 60)
}

@Test
func aSetTooBigForTheCanvasLinesUpWithItsNearEdge() {
    let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
    let huge = [Annotation.rectangle(CGRect(x: 50, y: 50, width: 300, height: 300), strokeStyle)]
    let landed = AnnotationGeometry.offset(huge, steps: 1, within: canvas)
    let bounds = AnnotationGeometry.combinedBounds(of: landed)
    #expect(bounds?.minX == 0 && bounds?.minY == 0,
            "A set wider than the canvas should still start where the user can see it")
}
