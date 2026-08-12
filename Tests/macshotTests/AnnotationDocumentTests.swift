import AppKit
import Testing
@testable import MacshotCore

// Document-seam tests: drive the public mutation API, assert on the observable
// annotation list — never on stack depths or entry internals.

@MainActor
private func rect(_ width: CGFloat, color: NSColor = .systemRed, lineWidth: CGFloat = 3) -> Annotation {
    .rectangle(
        CGRect(x: 10, y: 10, width: width, height: 20),
        StrokeStyle(color: color, lineWidth: lineWidth)
    )
}

@MainActor
private func widths(_ document: AnnotationDocument) -> [CGFloat] {
    document.annotations.compactMap {
        if case let .rectangle(rect, _) = $0 { return rect.width }
        return nil
    }
}

@MainActor
private func markerNumbers(_ document: AnnotationDocument) -> [Int] {
    document.annotations.compactMap {
        if case let .stepMarker(_, number, _) = $0 { return number }
        return nil
    }
}

@MainActor
private func strokeStyle(_ document: AnnotationDocument, _ id: AnnotationDocument.ID) -> StrokeStyle? {
    if case let .rectangle(_, style)? = document.annotation(for: id) { return style }
    Issue.record("Expected a rectangle annotation for \(id)")
    return nil
}

@MainActor
private func textParts(
    _ document: AnnotationDocument, _ id: AnnotationDocument.ID
) -> (content: String, style: TextStyle)? {
    if case let .text(_, content, style)? = document.annotation(for: id) {
        return (content, style)
    }
    Issue.record("Expected a text annotation for \(id)")
    return nil
}

private func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
    let c = color.usingColorSpace(.deviceRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent)
}

private func expectColor(_ actual: NSColor, matches expected: NSColor) {
    let a = rgb(actual)
    let e = rgb(expected)
    #expect(abs(a.0 - e.0) < 0.02 && abs(a.1 - e.1) < 0.02 && abs(a.2 - e.2) < 0.02,
            "Expected color \(e), got \(a)")
}

// MARK: - Add / undo / redo

@MainActor
@Test
func addUndoRedoRoundTrips() {
    var document = AnnotationDocument()
    document.insert(rect(30))
    #expect(document.annotations.count == 1)

    document.undo()
    #expect(document.annotations.isEmpty)

    document.redo()
    #expect(widths(document) == [30])
}

@MainActor
@Test
func newMutationAfterUndoDiscardsRedoPath() {
    var document = AnnotationDocument()
    document.insert(rect(30))
    document.undo()
    document.insert(rect(40))

    document.redo()
    #expect(widths(document) == [40], "Redo must not resurrect the undone annotation")
}

@MainActor
@Test
func undoAndRedoWithEmptyHistoryAreNoOps() {
    var document = AnnotationDocument()
    document.undo()
    document.redo()
    #expect(document.annotations.isEmpty)

    document.insert(rect(30))
    document.redo()
    #expect(widths(document) == [30])
}

// MARK: - Delete restores stacking order

@MainActor
@Test
func undoDeleteFromMiddleRestoresStackingOrder() {
    var document = AnnotationDocument()
    document.insert(rect(10))
    let middle = document.insert(rect(20))
    document.insert(rect(30))

    document.remove(middle)
    #expect(widths(document) == [10, 30])

    document.undo()
    #expect(widths(document) == [10, 20, 30], "Restored annotation must return to its original z-position")

    document.redo()
    #expect(widths(document) == [10, 30])
}

// MARK: - Move / resize (one step per drag)

@MainActor
@Test
func moveUndoRestoresExactPriorGeometry() {
    var document = AnnotationDocument()
    let id = document.insert(rect(30))
    let before = document.annotation(for: id)!

    document.updateLive(id, to: .rectangle(
        CGRect(x: 80, y: 90, width: 30, height: 20), .default
    ))
    document.commitChange(id, from: before)

    document.undo()
    guard case let .rectangle(restored, _)? = document.annotation(for: id) else {
        Issue.record("Annotation missing after undo")
        return
    }
    #expect(restored.origin == CGPoint(x: 10, y: 10))

    document.redo()
    guard case let .rectangle(moved, _)? = document.annotation(for: id) else {
        Issue.record("Annotation missing after redo")
        return
    }
    #expect(moved.origin == CGPoint(x: 80, y: 90))
}

@MainActor
@Test
func resizeUndoRestoresExactPriorGeometry() {
    var document = AnnotationDocument()
    let id = document.insert(rect(30))
    let before = document.annotation(for: id)!

    document.updateLive(id, to: .rectangle(
        CGRect(x: 10, y: 10, width: 120, height: 60), .default
    ))
    document.commitChange(id, from: before)

    document.undo()
    guard case let .rectangle(restored, _)? = document.annotation(for: id) else {
        Issue.record("Annotation missing after undo")
        return
    }
    #expect(restored.size == CGSize(width: 30, height: 20))
}

@MainActor
@Test
func dragEndingWhereItStartedRecordsNothing() {
    var document = AnnotationDocument()
    let id = document.insert(rect(30))
    let before = document.annotation(for: id)!

    document.updateLive(id, to: .rectangle(CGRect(x: 50, y: 50, width: 30, height: 20), .default))
    document.updateLive(id, to: before)
    document.commitChange(id, from: before)

    // The only recorded step must be the insert itself.
    document.undo()
    #expect(document.annotations.isEmpty, "A no-op drag must not consume an undo step")
}

@MainActor
@Test
func undoReversesLastActionNotNewestAnnotation() {
    var document = AnnotationDocument()
    let first = document.insert(rect(10))
    document.insert(rect(20))

    let before = document.annotation(for: first)!
    document.updateLive(first, to: .rectangle(CGRect(x: 99, y: 99, width: 10, height: 20), .default))
    document.commitChange(first, from: before)

    document.undo()
    #expect(widths(document) == [10, 20], "Undo of a move must not delete the newest annotation")
    guard case let .rectangle(restored, _)? = document.annotation(for: first) else {
        Issue.record("Moved annotation missing after undo")
        return
    }
    #expect(restored.origin == CGPoint(x: 10, y: 10))
}

// MARK: - Restyle and text content

@MainActor
@Test
func restyleUndoRestoresExactPriorColor() {
    var document = AnnotationDocument()
    let id = document.insert(rect(30, color: .systemRed))

    document.replace(id, with: rect(30, color: .systemBlue))
    guard let changed = strokeStyle(document, id) else { return }
    expectColor(changed.color, matches: .systemBlue)

    document.undo()
    guard let restored = strokeStyle(document, id) else { return }
    expectColor(restored.color, matches: .systemRed)

    document.redo()
    guard let redone = strokeStyle(document, id) else { return }
    expectColor(redone.color, matches: .systemBlue)
}

@MainActor
@Test
func lineWidthUndoRestoresPriorWidth() {
    var document = AnnotationDocument()
    let id = document.insert(rect(30, lineWidth: 3))

    document.replace(id, with: rect(30, lineWidth: 6))
    document.undo()

    #expect(strokeStyle(document, id)?.lineWidth == 3)
}

@MainActor
@Test
func fontSizeUndoRestoresPriorSize() {
    var document = AnnotationDocument()
    let id = document.insert(.text(box: CGRect(origin: CGPoint(x: 5, y: 5), size: TextLayout.defaultBoxSize), content: "Hi",
        TextStyle(color: .systemRed, fontSize: 22)
    ))

    document.replace(id, with: .text(box: CGRect(origin: CGPoint(x: 5, y: 5), size: TextLayout.defaultBoxSize), content: "Hi",
        TextStyle(color: .systemRed, fontSize: 32)
    ))
    document.undo()

    #expect(textParts(document, id)?.style.fontSize == 22)
}

@MainActor
@Test
func textContentChangeUndoRestoresPriorText() {
    var document = AnnotationDocument()
    let id = document.insert(.text(box: CGRect(origin: CGPoint(x: 5, y: 5), size: TextLayout.defaultBoxSize), content: "Before", TextStyle.default
    ))

    document.replace(id, with: .text(box: CGRect(origin: CGPoint(x: 5, y: 5), size: TextLayout.defaultBoxSize), content: "After", TextStyle.default
    ))
    #expect(textParts(document, id)?.content == "After")

    document.undo()
    #expect(textParts(document, id)?.content == "Before")

    document.redo()
    #expect(textParts(document, id)?.content == "After")
}

// MARK: - Grouping

@MainActor
@Test
func groupedDeleteUndoesAndRedoesAsOneStep() {
    var document = AnnotationDocument()
    let a = document.insert(rect(10))
    let b = document.insert(rect(20))
    let c = document.insert(rect(30))

    document.beginGroup()
    document.remove(a)
    document.remove(c)
    document.remove(b)
    document.endGroup()
    #expect(document.annotations.isEmpty)

    document.undo()
    #expect(widths(document) == [10, 20, 30], "One undo must restore the whole group in original order")

    document.redo()
    #expect(document.annotations.isEmpty, "One redo must re-apply the whole group")
}

@MainActor
@Test
func mixedGroupRoundTripsExactly() {
    var document = AnnotationDocument()
    let existing = document.insert(rect(10))

    document.beginGroup()
    document.insert(rect(20))
    document.replace(existing, with: rect(10, color: .systemBlue))
    document.insert(rect(30))
    document.endGroup()
    #expect(widths(document) == [10, 20, 30])

    document.undo()
    #expect(widths(document) == [10], "Undo must return to the exact pre-group state")
    guard let style = strokeStyle(document, existing) else { return }
    expectColor(style.color, matches: .systemRed)

    document.redo()
    #expect(widths(document) == [10, 20, 30], "Redo must return to the exact post-group state")
    guard let restyled = strokeStyle(document, existing) else { return }
    expectColor(restyled.color, matches: .systemBlue)
}

@MainActor
@Test
func emptyGroupRecordsNoStep() {
    var document = AnnotationDocument()
    document.insert(rect(30))

    document.beginGroup()
    document.endGroup()

    document.undo()
    #expect(document.annotations.isEmpty, "The empty group must not have consumed the undo step")
}

// MARK: - Step marker numbering

@MainActor
@Test
func markerNumberDerivesFromDocument() {
    var document = AnnotationDocument()
    #expect(document.nextStepMarkerNumber == 1)

    for _ in 0..<3 {
        document.insert(.stepMarker(
            center: CGPoint(x: 50, y: 50),
            number: document.nextStepMarkerNumber,
            FillStyle(color: .systemRed)
        ))
    }
    #expect(document.nextStepMarkerNumber == 4)

    document.undo()
    #expect(document.nextStepMarkerNumber == 3, "Undoing a marker must free its number")

    document.insert(.stepMarker(
        center: CGPoint(x: 60, y: 60),
        number: document.nextStepMarkerNumber,
        FillStyle(color: .systemRed)
    ))
    #expect(markerNumbers(document) == [1, 2, 3])
}

@MainActor
@Test
func redoingMarkerRestoresItsOriginalNumber() {
    var document = AnnotationDocument()
    for _ in 0..<3 {
        document.insert(.stepMarker(
            center: .zero, number: document.nextStepMarkerNumber, FillStyle(color: .systemRed)
        ))
    }
    document.undo()
    document.redo()

    #expect(markerNumbers(document) == [1, 2, 3])
}

// MARK: - Long alternating sequence

@MainActor
@Test
func longAlternatingSequenceEndsInImpliedState() {
    var document = AnnotationDocument()
    let a = document.insert(rect(10))           // [10]
    document.insert(rect(20))                   // [10, 20]
    document.undo()                             // [10]
    document.redo()                             // [10, 20]
    document.replace(a, with: rect(15))         // [15, 20]
    let c = document.insert(rect(30))           // [15, 20, 30]
    document.remove(c)                          // [15, 20]
    document.undo()                             // [15, 20, 30]
    document.undo()                             // [15, 20]
    document.undo()                             // [10, 20]
    document.redo()                             // [15, 20]
    document.insert(rect(40))                   // [15, 20, 40] — kills redo of insert(30)
    document.redo()                             // no-op
    #expect(widths(document) == [15, 20, 40])

    // Undo all the way back to the untouched screenshot.
    document.undo()
    document.undo()
    document.undo()
    document.undo()
    #expect(document.annotations.isEmpty)
}
