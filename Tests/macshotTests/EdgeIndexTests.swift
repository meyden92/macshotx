import AppKit
import Testing
@testable import MacshotCore

// Boundary-snap tests: the edge index built from synthesised images with known
// geometry, and the snap stage driven through the pure geometry seam.

/// 200×200 white image with a filled black rectangle at (50,50)–(150,150),
/// giving strong colour edges at x=50, x=150, y=50 and y=150.
@MainActor
private func makeBorderImage() -> CGImage {
    let ctx = CGContext(
        data: nil, width: 200, height: 200,
        bitsPerComponent: 8, bytesPerRow: 800,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
    return ctx.makeImage()!
}

@MainActor
private func makeBorderIndex() -> EdgeIndex {
    EdgeIndex.build(from: PixelSnapshot(image: makeBorderImage())!)
}

private let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)

// MARK: - Index build and query

@MainActor
@Test
func buildFindsCandidateLinesOnRectangleBorders() {
    let index = makeBorderIndex()
    #expect(index.columns.map(\.position) == [50, 150],
            "Columns should be found exactly on the vertical borders")
    #expect(index.rows.map(\.position) == [50, 150])
}

@MainActor
@Test
func majoritySupportAcceptsAndRejects() {
    let index = makeBorderIndex()
    // Span fully inside the rectangle's border run: supported.
    #expect(index.column(near: 52, spanning: 60...140, radius: 8) == 50)
    // Span mostly outside the border run (100 of 190 samples): rejected.
    #expect(index.column(near: 52, spanning: 5...195, radius: 8) == nil,
            "A colour edge supporting under 60% of the span must not qualify")
}

@MainActor
@Test
func nearestQualifyingCandidateWins() {
    // Two black stripes → candidates at 100, 103, 110, 113.
    let ctx = CGContext(
        data: nil, width: 200, height: 200,
        bitsPerComponent: 8, bytesPerRow: 800,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 100, y: 0, width: 3, height: 200))
    ctx.fill(CGRect(x: 110, y: 0, width: 3, height: 200))
    let index = EdgeIndex.build(from: PixelSnapshot(image: ctx.makeImage()!)!)

    #expect(index.column(near: 104, spanning: 20...180, radius: 8) == 103,
            "The nearest qualifying candidate wins")
}

@MainActor
@Test
func oversizedImageYieldsNoSnapshot() {
    #expect(PixelSnapshot(image: makeBorderImage(), maxPixels: 100) == nil,
            "Past the pixel cap the snapshot — and therefore the index — is skipped")
}

// MARK: - Snap through the geometry seam

@MainActor
@Test
func drawingSnapsOnlyDrivenEdgesWithinRadius() {
    let index = makeBorderIndex()
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 60, y: 60)), at: CGPoint(x: 60, y: 60)
    )
    let rect = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 144, y: 100), in: bounds,
        snapping: index, pixelScale: 1
    )
    #expect(rect == CGRect(x: 60, y: 60, width: 90, height: 40),
            "Right edge (6pt away) snaps to 150; bottom edge (50pt away) does not")
    #expect(gesture.snapState.right == 150)
    #expect(gesture.snapState.bottom == nil)
}

@MainActor
@Test
func snapHysteresisHoldsThenReleases() {
    let index = makeBorderIndex()
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 60, y: 60)), at: CGPoint(x: 60, y: 60)
    )
    _ = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 147, y: 100), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(gesture.snapState.right == 150)

    // 5pt past the line: within the release radius, the edge stays locked.
    let held = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 155, y: 100), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(held.maxX == 150, "The edge stays snapped through small movement")

    // 15pt past: clearly pulled away, and no candidate within the radius.
    let released = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 165, y: 100), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(released.maxX == 165, "Past the release radius the edge lets go")
    #expect(gesture.snapState.right == nil)
}

@MainActor
@Test
func leftHandleResizeNeverMovesTheRightEdge() {
    let index = makeBorderIndex()
    var gesture = SelectionGesture(
        kind: .resizing(handle: .left, original: CGRect(x: 100, y: 60, width: 60, height: 60)),
        at: CGPoint(x: 100, y: 90)
    )
    let rect = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 55, y: 90), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(rect.minX == 50, "The driven left edge snaps to the border")
    #expect(rect.maxX == 160, "The undriven right edge must not move")
}

@MainActor
@Test
func movingSnapsOneEdgePerAxisAndTranslatesRigidly() {
    let index = makeBorderIndex()
    var gesture = SelectionGesture(
        kind: .moving(original: CGRect(x: 100, y: 100, width: 40, height: 40),
                      grab: CGPoint(x: 120, y: 120)),
        at: CGPoint(x: 120, y: 120)
    )
    let rect = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 72, y: 120), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(rect == CGRect(x: 50, y: 100, width: 40, height: 40),
            "Left edge (2pt from the border) pulls the whole rectangle rigidly")
}

@MainActor
@Test
func optionAndShiftSuppressSnapping() {
    let index = makeBorderIndex()

    var option = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 60, y: 60)), at: CGPoint(x: 60, y: 60)
    )
    option.optionHeld = true
    let bypassed = SelectionGeometry.rectangle(
        for: &option, at: CGPoint(x: 144, y: 100), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(bypassed.maxX == 144, "Option turns snapping off completely")

    var shift = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 60, y: 60)), at: CGPoint(x: 60, y: 60)
    )
    shift.shiftHeld = true
    let square = SelectionGeometry.rectangle(
        for: &shift, at: CGPoint(x: 144, y: 100), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(square.width == square.height && square.maxX == 144,
            "An exact ratio constraint keeps snapping off so 1:1 stays 1:1")
}

@MainActor
@Test
func emptyIndexSnapsNothing() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 60, y: 60)), at: CGPoint(x: 60, y: 60)
    )
    let rect = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 144, y: 100), in: bounds,
        snapping: .empty, pixelScale: 1
    )
    #expect(rect.maxX == 144)
    #expect(gesture.snapState == .none)
}

// MARK: - Review regression tests

@MainActor
@Test
func crossingTheAnchorSnapsTheNewDrivenEdgeNotTheFixedOne() {
    let index = makeBorderIndex()
    // Right-handle drag that crosses left past the anchor at x=147: the left
    // edge is now the one moving; the fixed edge (now at 147, 3pt from the
    // 150 candidate) must not be snapped.
    var gesture = SelectionGesture(
        kind: .resizing(handle: .right, original: CGRect(x: 147, y: 60, width: 40, height: 60)),
        at: CGPoint(x: 187, y: 90)
    )
    let rect = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 100, y: 90), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(rect.maxX == 147, "The fixed edge must stay exactly where it was")
    #expect(gesture.snapState.right == nil)
}

@MainActor
@Test
func pressingSpaceWithASnappedEdgeDoesNotMoveTheSelection() {
    let index = makeBorderIndex()
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 60, y: 60)), at: CGPoint(x: 60, y: 60)
    )
    let snapped = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 147, y: 100), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(snapped.maxX == 150)

    gesture.pressSpace()
    let frozen = SelectionGeometry.rectangle(
        for: &gesture, at: CGPoint(x: 147, y: 100), in: bounds, snapping: index, pixelScale: 1
    )
    #expect(frozen == snapped, "Pressing Space must freeze the displayed (snapped) rectangle")
}
