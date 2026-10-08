import CoreGraphics
import Testing
@testable import MacshotCore

// Placement-solver tests: display bounds, safe area, Selection and box sizes
// in — non-overlapping origins out. Flipped (top-left origin) coordinates.

private let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)
private let strip = CGSize(width: 400, height: 80)
private let hint = CGSize(width: 260, height: 24)
private let box = CGSize(width: 180, height: 28)

@Test
func toolStripPrefersSittingBelowTheSelection() {
    let selection = CGRect(x: 100, y: 100, width: 300, height: 200)
    let placed = ChromePlacement.solve(
        bounds: display, safeAreaTop: 0, selection: selection,
        boxes: .init(toolStrip: strip)
    )
    #expect(placed.toolStrip?.origin == CGPoint(x: 50, y: 308),
            "Strip should sit 8pt below the Selection, centred on it")
}

@Test
func toolStripFlipsAboveNearTheBottomEdge() {
    let selection = CGRect(x: 100, y: 800, width: 300, height: 150)
    let placed = ChromePlacement.solve(
        bounds: display, safeAreaTop: 0, selection: selection,
        boxes: .init(toolStrip: strip)
    )
    #expect(placed.toolStrip?.origin.y == 712,
            "With no room below, the strip flips 8pt above the Selection")
}

@Test
func chromeNeverIntersectsTheSafeAreaInset() {
    // Selection fills the display, so the flipped-above stack would land in
    // the menu-bar/notch band without the clamp.
    let selection = CGRect(x: 100, y: 40, width: 800, height: 930)
    let placed = ChromePlacement.solve(
        bounds: display, safeAreaTop: 30, selection: selection,
        boxes: .init(toolStrip: strip, hint: hint)
    )
    #expect(placed.toolStrip!.minY >= 30, "Strip must stay clear of the safe area")
    #expect(placed.hint!.minY >= 30, "Hint must stay clear of the safe area")
}

@Test
func allBoxesArePairwiseNonIntersecting() {
    let selection = CGRect(x: 300, y: 300, width: 300, height: 200)
    let placed = ChromePlacement.solve(
        bounds: display, safeAreaTop: 30, selection: selection,
        boxes: .init(toolStrip: strip, resolutionBox: box, hint: hint)
    )
    let rects = [placed.toolStrip, placed.resolutionBox, placed.hint].compactMap { $0 }
    #expect(rects.count == 3)
    for i in rects.indices {
        for j in rects.indices where j > i {
            #expect(!rects[i].intersects(rects[j]),
                    "Boxes \(i) and \(j) must not overlap: \(rects[i]) vs \(rects[j])")
        }
    }
}

@Test
func chromeIsClampedInsideTheDisplay() {
    // Selection jammed into the top-left corner.
    let selection = CGRect(x: 0, y: 0, width: 60, height: 60)
    let placed = ChromePlacement.solve(
        bounds: display, safeAreaTop: 24, selection: selection,
        boxes: .init(toolStrip: strip, resolutionBox: box, hint: hint)
    )
    for rect in [placed.toolStrip, placed.resolutionBox, placed.hint].compactMap({ $0 }) {
        #expect(rect.minX >= 8 && rect.maxX <= 992, "Horizontally clamped: \(rect)")
        #expect(rect.minY >= 24 && rect.maxY <= 992, "Vertically clamped: \(rect)")
    }
}

@Test
func resolutionBoxPrefersTheRightSideAndFlipsWhenFull() {
    let roomy = ChromePlacement.solve(
        bounds: display, safeAreaTop: 0,
        selection: CGRect(x: 100, y: 100, width: 300, height: 200),
        boxes: .init(resolutionBox: box)
    )
    #expect(roomy.resolutionBox?.origin == CGPoint(x: 408, y: 100),
            "Box rides beside the Selection's top-right corner")

    let jammedRight = ChromePlacement.solve(
        bounds: display, safeAreaTop: 0,
        selection: CGRect(x: 650, y: 100, width: 340, height: 200),
        boxes: .init(resolutionBox: box)
    )
    #expect(jammedRight.resolutionBox?.origin == CGPoint(x: 462, y: 100),
            "With no room on the right, the box moves to the left side")
}

@Test
func placementIsDeterministic() {
    let selection = CGRect(x: 220, y: 340, width: 420, height: 260)
    let boxes = ChromePlacement.Boxes(toolStrip: strip, resolutionBox: box, hint: hint)
    let first = ChromePlacement.solve(
        bounds: display, safeAreaTop: 30, selection: selection, boxes: boxes
    )
    let second = ChromePlacement.solve(
        bounds: display, safeAreaTop: 30, selection: selection, boxes: boxes
    )
    #expect(first == second)
}
