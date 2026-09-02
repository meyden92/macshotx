import Testing
@testable import MacshotCore

// The select tool's click and drag ladders as a truth table (#58, ADR 0014).
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
func commandDragInsideTheSelectionIsTheMarquee() {
    let f = facts { $0.hasSelection = true; $0.insideSelection = true; $0.commandHeld = true }
    #expect(SelectGesture.drag(f) == .marquee)
}

@Test
func emptyCanvasDrawsANewSelection() {
    #expect(SelectGesture.drag(facts()) == .drawSelection)
    // Outside an existing Selection too: the drag replaces it.
    #expect(SelectGesture.drag(facts { $0.hasSelection = true }) == .drawSelection)
}

// MARK: - Click ladder (ADR 0014)

@Test
func aClickThatHitsAnAnnotationSelectsItBeforeAnythingElse() {
    #expect(SelectGesture.click(facts { $0.hitsAnnotation = true; $0.snapArmed = true; $0.windowUnderCursor = true })
            == .selectAnnotation)
    #expect(SelectGesture.click(facts { $0.tool = .rectangle; $0.hitsAnnotation = true })
            == .selectAnnotation)
}

@Test
func aClickOverAWindowWithASelectedSetClearsTheSetAndCapturesNothing() {
    let f = facts { $0.hasSelectedSet = true; $0.snapArmed = true; $0.windowUnderCursor = true }
    #expect(SelectGesture.click(f) == .clearSelectedSet)
    // The following click, from the now-clean canvas, captures the window.
    #expect(SelectGesture.click(facts { $0.snapArmed = true; $0.windowUnderCursor = true })
            == .captureWindow)
}

@Test
func aClickWhileATextEditIsOpenCommitsTheTextRatherThanCapturing() {
    #expect(SelectGesture.click(facts { $0.isEditingText = true }) == .clearSelectedSet)
}

@Test
func aClickWithADrawingToolInHandCapturesNothing() {
    let f = facts { $0.tool = .arrow; $0.snapArmed = true; $0.windowUnderCursor = true }
    #expect(SelectGesture.click(f) == .nothing)
    #expect(SelectGesture.click(facts { $0.tool = .pen }) == .nothing)
}

@Test
func aClickOutsideTheSelectionDismissesItAndInsideDoesNothing() {
    #expect(SelectGesture.click(facts { $0.hasSelection = true }) == .clearSelection)
    #expect(SelectGesture.click(facts { $0.hasSelection = true; $0.insideSelection = true }) == .nothing)
    #expect(SelectGesture.click(facts { $0.hasSelection = true; $0.selectionHandle = .top }) == .nothing)
    // Even over a window: dismissing the Selection never captures.
    let overWindow = facts { $0.hasSelection = true; $0.snapArmed = true; $0.windowUnderCursor = true }
    #expect(SelectGesture.click(overWindow) == .clearSelection)
}

@Test
func fromACleanCanvasAClickCapturesTheWindowUnderItOrElseTheDisplay() {
    #expect(SelectGesture.click(facts { $0.snapArmed = true; $0.windowUnderCursor = true })
            == .captureWindow)
    #expect(SelectGesture.click(facts { $0.snapArmed = true }) == .captureDisplay)
    // Disarming snap changes what a click captures, not whether it captures.
    #expect(SelectGesture.click(facts { $0.snapArmed = false; $0.windowUnderCursor = true })
            == .captureDisplay)
    #expect(SelectGesture.click(facts()) == .captureDisplay)
}
