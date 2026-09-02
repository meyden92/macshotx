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

// MARK: - Click ladder

@Test
func aClickThatHitsAnAnnotationSelectsIt() {
    #expect(SelectGesture.click(facts { $0.hitsAnnotation = true; $0.snapArmed = true; $0.windowUnderCursor = true })
            == .selectAnnotation)
    #expect(SelectGesture.click(facts { $0.tool = .rectangle; $0.hitsAnnotation = true })
            == .selectAnnotation)
}

@Test
func withSnapArmedAClickSeedsTheWindowUnderItOrNothing() {
    #expect(SelectGesture.click(facts { $0.snapArmed = true; $0.windowUnderCursor = true })
            == .seedWindow)
    #expect(SelectGesture.click(facts { $0.snapArmed = true }) == .nothing)
    // A drawing-tool click still snap-seeds.
    #expect(SelectGesture.click(facts { $0.tool = .pen; $0.snapArmed = true; $0.windowUnderCursor = true })
            == .seedWindow)
}

@Test
func withSnapOffOnlyAnIdleSelectToolClickSeedsTheDisplay() {
    #expect(SelectGesture.click(facts { $0.isIdle = true }) == .seedDisplay)
    #expect(SelectGesture.click(facts { $0.isIdle = false }) == .nothing)
    #expect(SelectGesture.click(facts { $0.tool = .pen; $0.isIdle = true }) == .nothing)
}
