import AppKit
import Testing
@testable import MacshotCore

// Overlay-level multi-select tests. The marquee, the combined outline and the
// grouped undo entries are all driven with synthesised events and read back out
// of the baked image. The marquee's membership maths is covered at the
// annotation-geometry seam.

@MainActor
private func makeSourceImage() -> CGImage {
    let ctx = CGContext(
        data: nil, width: 200, height: 200,
        bitsPerComponent: 8, bytesPerRow: 4 * 200,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.gray.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    return ctx.makeImage()!
}

@MainActor
private func makeHostedView() -> (RegionPickerView, NSWindow) {
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(frame: frame, image: makeSourceImage(), scale: 1.0, requiresSelection: false)
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func keyEvent(
    _ char: String, keyCode: UInt16, window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: keyCode
    )!
}

@MainActor
private func mouseEvent(
    _ kind: NSEvent.EventType, atViewPoint point: CGPoint,
    in view: RegionPickerView, window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    let windowLocation = NSPoint(x: point.x, y: view.bounds.height - point.y)
    return NSEvent.mouseEvent(
        with: kind, location: windowLocation, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1.0
    )!
}

@MainActor
private func drag(
    in view: RegionPickerView, window: NSWindow,
    from: CGPoint, to: CGPoint,
    modifiers: NSEvent.ModifierFlags = []
) {
    view.mouseDown(with: mouseEvent(
        .leftMouseDown, atViewPoint: from, in: view, window: window, modifiers: modifiers
    ))
    view.mouseDragged(with: mouseEvent(
        .leftMouseDragged, atViewPoint: to, in: view, window: window, modifiers: modifiers
    ))
    view.mouseUp(with: mouseEvent(
        .leftMouseUp, atViewPoint: to, in: view, window: window, modifiers: modifiers
    ))
}

@MainActor
private func click(
    in view: RegionPickerView, window: NSWindow, at point: CGPoint,
    modifiers: NSEvent.ModifierFlags = []
) {
    view.mouseDown(with: mouseEvent(
        .leftMouseDown, atViewPoint: point, in: view, window: window, modifiers: modifiers
    ))
    view.mouseUp(with: mouseEvent(
        .leftMouseUp, atViewPoint: point, in: view, window: window, modifiers: modifiers
    ))
}

@MainActor
private func pressDelete(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: keyEvent("\u{08}", keyCode: 51, window: window))
}

@MainActor
private func pressEscape(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: keyEvent("\u{1b}", keyCode: 53, window: window))
}

@MainActor
private func undoKey(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: keyEvent("z", keyCode: 6, window: window, modifiers: [.command]))
}

/// Two black fill rects — A at (30,30)–(50,50), B at (70,70)–(90,90) — and a
/// committed Selection covering (10,10)–(150,150), which is what `bake` crops
/// to.
@MainActor
private func makeSceneWithTwoRects() -> (RegionPickerView, NSWindow) {
    let (view, window) = makeHostedView()
    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 50, y: 50))
    drag(in: view, window: window, from: CGPoint(x: 70, y: 70), to: CGPoint(x: 90, y: 90))
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    drag(in: view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 150, y: 150))
    return (view, window)
}

/// Marquee across both rects, from empty canvas inside the Selection. Command
/// is what distinguishes it from the plain drag, which moves the Selection.
@MainActor
private func marqueeBothRects(_ view: RegionPickerView, _ window: NSWindow) {
    drag(
        in: view, window: window,
        from: CGPoint(x: 22, y: 22), to: CGPoint(x: 95, y: 95),
        modifiers: [.command]
    )
}

/// Confirms the committed Selection and returns the baked crop.
@MainActor
private func bake(_ view: RegionPickerView, _ window: NSWindow) -> CGImage? {
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    return baked
}

/// Red channel of a baked pixel, addressed in view points given a crop origin.
private func redAt(
    _ baked: CGImage, viewPoint: CGPoint, cropOrigin: CGPoint = CGPoint(x: 10, y: 10)
) -> UInt8 {
    let data = baked.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    let x = Int(viewPoint.x - cropOrigin.x)
    let y = Int(viewPoint.y - cropOrigin.y)
    return bytes[y * baked.bytesPerRow + x * 4]
}

private let insideA = CGPoint(x: 40, y: 40)
private let insideB = CGPoint(x: 80, y: 80)
private let black: UInt8 = 60
private let gray: UInt8 = 100

// MARK: - Marquee, delete, undo

@MainActor
@Test
func aMarqueeSelectsEverythingItTouchesAndDeleteRemovesTheSetInOneUndoStep() {
    let (view, window) = makeSceneWithTwoRects()

    marqueeBothRects(view, window)
    pressDelete(view, window)

    guard let afterDelete = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(afterDelete, viewPoint: insideA) > gray, "Delete should remove the first rect")
    #expect(redAt(afterDelete, viewPoint: insideB) > gray, "Delete should remove the second rect")

    // One undo, both back: the multi-delete was a single grouped entry.
    undoKey(view, window)

    guard let afterUndo = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(afterUndo, viewPoint: insideA) < black, "One undo should restore both rects")
    #expect(redAt(afterUndo, viewPoint: insideB) < black, "One undo should restore both rects")
}

// MARK: - Moving the set

@MainActor
@Test
func draggingInsideTheCombinedOutlineMovesTheWholeSetAsOneUndoStep() {
    let (view, window) = makeSceneWithTwoRects()
    marqueeBothRects(view, window)

    // (60,60) is inside the combined outline but on neither rect.
    drag(in: view, window: window, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 60, y: 110))

    guard let afterMove = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(afterMove, viewPoint: insideA) > gray, "The first rect should have left")
    #expect(redAt(afterMove, viewPoint: CGPoint(x: 40, y: 90)) < black,
            "The first rect should have moved down by the drag delta")
    #expect(redAt(afterMove, viewPoint: CGPoint(x: 80, y: 130)) < black,
            "The second rect should have moved by the same delta")

    // One undo puts both back: the group move was a single entry.
    undoKey(view, window)

    guard let afterUndo = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(afterUndo, viewPoint: insideA) < black, "One undo should move both rects back")
    #expect(redAt(afterUndo, viewPoint: insideB) < black, "One undo should move both rects back")
    #expect(redAt(afterUndo, viewPoint: CGPoint(x: 40, y: 90)) > gray,
            "Nothing should be left where the set was dragged to")
}

@MainActor
@Test
func aSetOfSeveralHasNoResizeHandles() {
    let (view, window) = makeSceneWithTwoRects()
    marqueeBothRects(view, window)

    // (50,50) is the first rect's bottom-right corner — a resize handle when it
    // is the only thing selected. With a set it is just a point inside the
    // combined outline, so the drag moves everything.
    drag(in: view, window: window, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 80))

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: insideB) > gray, "The second rect should have moved too")
    #expect(redAt(baked, viewPoint: CGPoint(x: 80, y: 110)) < black,
            "The drag should have moved the set, not resized one member")
}

// MARK: - Fixing up the set

@MainActor
@Test
func shiftClickTogglesMembershipOfTheSet() {
    let (view, window) = makeSceneWithTwoRects()
    marqueeBothRects(view, window)

    click(in: view, window: window, at: insideB, modifiers: .shift)
    pressDelete(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: insideA) > gray, "The rect still in the set should be gone")
    #expect(redAt(baked, viewPoint: insideB) < black,
            "Shift-click should have dropped the second rect from the set")
}

@MainActor
@Test
func escapeDropsTheSetWithoutCancellingTheCapture() {
    let (view, window) = makeSceneWithTwoRects()
    var cancelled = false
    view.onCancel = { cancelled = true }

    marqueeBothRects(view, window)
    pressEscape(view, window)
    pressDelete(view, window)

    #expect(!cancelled, "Escape with a selected set should not cancel the capture")

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: insideA) < black, "Escape should have dropped the set")
    #expect(redAt(baked, viewPoint: insideB) < black, "Escape should have dropped the set")
}

// MARK: - Floating delete affordance

@MainActor
@Test
func theFloatingDeleteAffordanceRemovesTheSetAndOnlyExistsForOne() {
    let (view, window) = makeSceneWithTwoRects()

    // Single selection first: the affordance is not there, so a click where it
    // would sit must not delete anything.
    click(in: view, window: window, at: insideA)
    click(in: view, window: window, at: affordanceCenter)

    guard let afterSingle = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(afterSingle, viewPoint: insideA) < black,
            "A single selection should offer no delete affordance")

    marqueeBothRects(view, window)
    click(in: view, window: window, at: affordanceCenter)

    guard let afterSet = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(afterSet, viewPoint: insideA) > gray, "The affordance should delete the set")
    #expect(redAt(afterSet, viewPoint: insideB) > gray, "The affordance should delete the set")
}

/// The combined outline of the two rects is (27,27)–(93,93); the affordance sits
/// just off its top-right corner.
private let affordanceCenter = CGPoint(x: 108, y: 12)

// MARK: - Marquee with no Selection (#62)

@MainActor
@Test
func aMarqueeSelectsAnnotationsBeforeAnySelectionExists() {
    let (view, window) = makeHostedView()
    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 50, y: 50))
    drag(in: view, window: window, from: CGPoint(x: 70, y: 70), to: CGPoint(x: 90, y: 90))
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    pressEscape(view, window)

    // Command-drag across both with no Selection in existence, then delete.
    marqueeBothRects(view, window)
    pressDelete(view, window)
    #expect(view.annotations.isEmpty, "Both marks joined the set and went together")
}

@MainActor
@Test
func aMarqueeInsideTheSelectionLeavesTheSelectionWhereItWas() {
    let (view, window) = makeSceneWithTwoRects()
    marqueeBothRects(view, window)
    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(baked.width == 140 && baked.height == 140, "The Selection was neither moved nor cleared")
}

// MARK: - Moving the Selection the marquee shares an interior with

@MainActor
@Test
func aPlainDragInsideTheSelectionMovesIt() {
    let (view, window) = makeHostedView()

    // A black rect at (100,100)–(120,120), then the Selection (10,10)–(150,150).
    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 120))
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    drag(in: view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 150, y: 150))

    // Grab the middle — the instinctive gesture, which used to rubber-band and
    // drop the Selection — and push it right by 40.
    drag(in: view, window: window, from: CGPoint(x: 80, y: 40), to: CGPoint(x: 120, y: 40))

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(baked.width == 140 && baked.height == 140, "The Selection should keep its size")
    let cropOrigin = CGPoint(x: 50, y: 10)
    #expect(redAt(baked, viewPoint: CGPoint(x: 110, y: 110), cropOrigin: cropOrigin) < black,
            "The rect should be where the moved crop puts it")
    #expect(redAt(baked, viewPoint: CGPoint(x: 60, y: 110), cropOrigin: cropOrigin) > gray,
            "The moved crop should have picked up fresh source pixels on the left")
}

// MARK: - Duplicate, copy and paste (ticket 06)

@MainActor
private func commandKey(_ char: String, keyCode: UInt16, window: NSWindow) -> NSEvent {
    keyEvent(char, keyCode: keyCode, window: window, modifiers: [.command])
}

@MainActor
private func pressDuplicate(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: commandKey("d", keyCode: 2, window: window))
}

@MainActor
private func pressCopy(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: commandKey("c", keyCode: 8, window: window))
}

@MainActor
private func pressPaste(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: commandKey("v", keyCode: 9, window: window))
}

@MainActor
@Test
func duplicateOffsetsTheSetAndUndoesInOneStep() {
    let (view, window) = makeSceneWithTwoRects()
    marqueeBothRects(view, window)

    pressDuplicate(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    let step = Int(AnnotationGeometry.pasteOffsetStep)
    #expect(redAt(baked, viewPoint: insideA) < black, "The originals should still be there")
    #expect(redAt(baked, viewPoint: CGPoint(x: 40 + step, y: 40 + step)) < black,
            "The duplicate should land offset from its original")
    #expect(redAt(baked, viewPoint: CGPoint(x: 80 + step, y: 80 + step)) < black,
            "Both members of the set should have been duplicated")

    // One undo removes both copies however many were created.
    undoKey(view, window)
    guard let afterUndo = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(afterUndo, viewPoint: CGPoint(x: 40 + step, y: 40 + step)) > gray,
            "One undo should take the whole duplicate back")
    #expect(redAt(afterUndo, viewPoint: insideA) < black, "The originals should survive it")
}

@MainActor
@Test
func repeatedPastesCascadeInsteadOfStacking() {
    let (view, window) = makeSceneWithTwoRects()
    marqueeBothRects(view, window)

    pressCopy(view, window)
    pressPaste(view, window)
    pressPaste(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    let step = Int(AnnotationGeometry.pasteOffsetStep)
    #expect(redAt(baked, viewPoint: CGPoint(x: 40 + step, y: 40 + step)) < black,
            "The first paste should be one step off")
    #expect(redAt(baked, viewPoint: CGPoint(x: 40 + step * 2, y: 40 + step * 2)) < black,
            "The second paste should cascade past the first")
}

@MainActor
@Test
func pastedAnnotationsArriveSelectedSoTheyCanBeDraggedStraightIntoPosition() {
    let (view, window) = makeSceneWithTwoRects()
    marqueeBothRects(view, window)
    pressCopy(view, window)
    pressPaste(view, window)

    // No click, no marquee: drag the copies straight off the paste. They are
    // the selected set, so the drag moves them and leaves the originals.
    let step = AnnotationGeometry.pasteOffsetStep
    drag(
        in: view, window: window,
        from: CGPoint(x: 60 + step, y: 60 + step),
        to: CGPoint(x: 60 + step, y: 110 + step)
    )

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    #expect(redAt(baked, viewPoint: insideA) < black, "The originals should not have moved")
    #expect(redAt(baked, viewPoint: CGPoint(x: 40 + Int(step), y: 90 + Int(step))) < black,
            "The pasted set should have moved with the drag")
}

@MainActor
@Test
func annotationsCopiedInOneCapturePasteIntoTheNext() {
    let (source, sourceWindow) = makeSceneWithTwoRects()
    marqueeBothRects(source, sourceWindow)
    pressCopy(source, sourceWindow)

    // A completely separate overlay, as the next capture would be.
    let (view, window) = makeHostedView()
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    drag(in: view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 150, y: 150))

    pressPaste(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    let step = Int(AnnotationGeometry.pasteOffsetStep)
    #expect(redAt(baked, viewPoint: CGPoint(x: 40 + step, y: 40 + step)) < black,
            "A set copied on one overlay should paste into a later one")
    #expect(redAt(baked, viewPoint: CGPoint(x: 80 + step, y: 80 + step)) < black,
            "Both copied annotations should arrive")
}

@MainActor
@Test
func copyWithNothingSelectedIsANoOp() {
    let (view, window) = makeSceneWithTwoRects()
    marqueeBothRects(view, window)
    pressCopy(view, window)

    // Drop the set, copy again — the earlier payload must survive — then paste.
    pressEscape(view, window)
    pressCopy(view, window)
    pressPaste(view, window)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image produced")
        return
    }
    let step = Int(AnnotationGeometry.pasteOffsetStep)
    #expect(redAt(baked, viewPoint: CGPoint(x: 40 + step, y: 40 + step)) < black,
            "An empty copy should not have cleared what was on the pasteboard")
}
