import Testing
@testable import MacshotCore

// The select tool's click and drag ladders as a truth table (#58, ADR 0016).
// Facts in, outcome out; nothing here hosts a window.

private func facts(_ edit: (inout SelectGesture.Facts) -> Void = { _ in }) -> SelectGesture.Facts {
    var f = SelectGesture.Facts()
    edit(&f)
    return f
}

// MARK: - Drag ladder

@Test
func aDrawingToolClaimsTheDragEvenOverAnAnnotationOrInsideTheSelection() {
    let f = facts {
        $0.tool = .rectangle
        $0.hitsAnnotation = true
        $0.hasSelection = true
        $0.insideSelection = true
    }
    #expect(SelectGesture.drag(f) == .draw)
}

@Test
func whatIsAlreadySelectedDragsWithAnyTool() {
    // Click selects, drag draws — but a drag from a selected element edits it.
    let selected = facts { $0.tool = .rectangle; $0.hitsAnnotation = true; $0.hitsSelectedAnnotation = true }
    #expect(SelectGesture.drag(selected) == .grabAnnotation)
    let handle = facts { $0.tool = .stepMarker; $0.onSelectedHandle = true }
    #expect(SelectGesture.drag(handle) == .manipulateSelected)
    let set = facts { $0.tool = .arrow; $0.insideSelectedSet = true }
    #expect(SelectGesture.drag(set) == .manipulateSelected)
    // Shift over a selected element is not a grab: the drawing tool draws.
    let shifted = facts { $0.tool = .arrow; $0.hitsAnnotation = true; $0.hitsSelectedAnnotation = true; $0.shiftHeld = true }
    #expect(SelectGesture.drag(shifted) == .draw)
}

@Test
func commandLetsADrawingToolGrabAnAnnotationWithoutSwitchingTools() {
    let f = facts { $0.tool = .arrow; $0.commandHeld = true; $0.hitsAnnotation = true }
    #expect(SelectGesture.drag(f) == .grabAnnotation)
    // Over empty canvas the drawing tool still draws.
    #expect(SelectGesture.drag(facts { $0.tool = .arrow; $0.commandHeld = true }) == .draw)
}

@Test
func theSelectedAnnotationsHandlesBeatEverythingBelowThem() {
    let f = facts {
        $0.onSelectedHandle = true
        $0.hitsAnnotation = true
        $0.hasSelection = true
        $0.insideSelection = true
    }
    #expect(SelectGesture.drag(f) == .manipulateSelected)
}

@Test
func aSetOfSeveralMovesFromInsideItsOutlineUnlessShiftIsChangingMembership() {
    let inside = facts { $0.insideSelectedSet = true; $0.hasSelectedSet = true }
    #expect(SelectGesture.drag(inside) == .manipulateSelected)
    let shifted = facts {
        $0.insideSelectedSet = true; $0.hasSelectedSet = true
        $0.shiftHeld = true; $0.hitsAnnotation = true
    }
    #expect(SelectGesture.drag(shifted) == .toggleMembership)
}

@Test
func hittingAnAnnotationGrabsItAndShiftTogglesItInstead() {
    #expect(SelectGesture.drag(facts { $0.hitsAnnotation = true }) == .grabAnnotation)
    #expect(SelectGesture.drag(facts { $0.hitsAnnotation = true; $0.shiftHeld = true })
            == .toggleMembership)
    // Above the Selection rungs: an annotation inside the Selection is grabbed,
    // not the Selection moved.
    let inside = facts { $0.hitsAnnotation = true; $0.hasSelection = true; $0.insideSelection = true }
    #expect(SelectGesture.drag(inside) == .grabAnnotation)
}

@Test
func theSelectionResizesByItsHandlesAndMovesFromInside() {
    let handle = facts { $0.hasSelection = true; $0.selectionHandle = .bottomRight }
    #expect(SelectGesture.drag(handle) == .resizeSelection(.bottomRight))
    let inside = facts { $0.hasSelection = true; $0.insideSelection = true }
    #expect(SelectGesture.drag(inside) == .moveSelection)
}

@Test
func commandDragInsideTheSelectionIsTheMarqueeAndOutsideItDrawsANewSelection() {
    // The marquee is confined to the Selection: annotation happens inside one.
    let inside = facts { $0.hasSelection = true; $0.insideSelection = true; $0.commandHeld = true }
    #expect(SelectGesture.drag(inside) == .marquee)
    let outside = facts { $0.hasSelection = true; $0.commandHeld = true }
    #expect(SelectGesture.drag(outside) == .drawSelection)
    #expect(SelectGesture.drag(facts { $0.commandHeld = true }) == .drawSelection,
            "With no Selection a Command-drag still draws one")
    // A Selection handle is an explicit affordance and keeps its grab.
    let handle = facts { $0.hasSelection = true; $0.selectionHandle = .left; $0.commandHeld = true }
    #expect(SelectGesture.drag(handle) == .resizeSelection(.left))
}

@Test
func emptyCanvasDrawsANewSelection() {
    #expect(SelectGesture.drag(facts()) == .drawSelection)
    // Outside an existing Selection too: the drag replaces it.
    #expect(SelectGesture.drag(facts { $0.hasSelection = true }) == .drawSelection)
}

// MARK: - Click ladder (ADR 0016)

@Test
func aClickThatHitsAnAnnotationSelectsItBeforeAnythingElse() {
    #expect(SelectGesture.click(facts { $0.hitsAnnotation = true; $0.snapArmed = true; $0.windowUnderCursor = true })
            == .selectAnnotation)
    #expect(SelectGesture.click(facts { $0.tool = .rectangle; $0.hitsAnnotation = true })
            == .selectAnnotation)
}

@Test
func aClickWithASelectedSetOrAnOpenTextEditOnlyClearsIt() {
    let overWindow = facts { $0.hasSelectedSet = true; $0.snapArmed = true; $0.windowUnderCursor = true }
    #expect(SelectGesture.click(overWindow) == .clearSelectedSet)
    #expect(SelectGesture.click(facts { $0.isEditingText = true }) == .clearSelectedSet)
}

@Test
func aClickWithADrawingToolInHandDoesNothing() {
    let f = facts { $0.tool = .arrow; $0.snapArmed = true; $0.windowUnderCursor = true }
    #expect(SelectGesture.click(f) == .nothing)
    #expect(SelectGesture.click(facts { $0.tool = .pen }) == .nothing)
}

@Test
func aClickOutsideTheSelectionDismissesItAndInsideDoesNothing() {
    #expect(SelectGesture.click(facts { $0.hasSelection = true }) == .clearSelection)
    #expect(SelectGesture.click(facts { $0.hasSelection = true; $0.insideSelection = true }) == .nothing)
    #expect(SelectGesture.click(facts { $0.hasSelection = true; $0.selectionHandle = .top }) == .nothing)
    // Even over a window: one click, one effect. The next one may seed it.
    let overWindow = facts { $0.hasSelection = true; $0.snapArmed = true; $0.windowUnderCursor = true }
    #expect(SelectGesture.click(overWindow) == .clearSelection)
}

@Test
func withNoSelectionAClickOnAWindowSeedsTheSelectionToItWhileSnapIsArmed() {
    #expect(SelectGesture.click(facts { $0.snapArmed = true; $0.windowUnderCursor = true })
            == .seedWindow)
    #expect(SelectGesture.click(facts { $0.snapArmed = false; $0.windowUnderCursor = true })
            == .nothing, "Snap off: a click on a window is a click on empty space")
}

@Test
func aBareClickOnEmptySpaceDoesNothing() {
    // No click captures, and none seeds the whole display: that is `F`.
    #expect(SelectGesture.click(facts()) == .nothing)
    #expect(SelectGesture.click(facts { $0.snapArmed = true }) == .nothing)
}
