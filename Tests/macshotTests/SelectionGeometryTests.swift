import CoreGraphics
import Testing
@testable import MacshotCore

// Pure geometry-seam tests: a gesture value plus a cursor point in, a rectangle
// out. No window, no events, no display.

private let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)

private func evaluate(
    _ gesture: inout SelectionGesture,
    at point: CGPoint,
    in area: CGRect = bounds
) -> CGRect {
    SelectionGeometry.rectangle(for: &gesture, at: point, in: area)
}

// MARK: - Ticket 01: drawing, moving, resizing, invariants

@Test
func drawingWorksInAllFourQuadrants() {
    let origin = CGPoint(x: 100, y: 100)
    let cases: [(CGPoint, CGRect)] = [
        (CGPoint(x: 140, y: 130), CGRect(x: 100, y: 100, width: 40, height: 30)),
        (CGPoint(x: 60, y: 130), CGRect(x: 60, y: 100, width: 40, height: 30)),
        (CGPoint(x: 60, y: 70), CGRect(x: 60, y: 70, width: 40, height: 30)),
        (CGPoint(x: 140, y: 70), CGRect(x: 100, y: 70, width: 40, height: 30))
    ]
    for (point, expected) in cases {
        var gesture = SelectionGesture(kind: .drawing(origin: origin), at: origin)
        #expect(evaluate(&gesture, at: point) == expected, "Drawing toward \(point)")
    }
}

@Test
func drawingEnforcesMinimumSize() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    #expect(evaluate(&gesture, at: CGPoint(x: 103, y: 102))
            == CGRect(x: 100, y: 100, width: 8, height: 8))

    var reversed = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    #expect(evaluate(&reversed, at: CGPoint(x: 97, y: 98))
            == CGRect(x: 92, y: 92, width: 8, height: 8))
}

@Test
func drawingStaysInsideDisplayBounds() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 190, y: 190)), at: CGPoint(x: 190, y: 190)
    )
    let rect = evaluate(&gesture, at: CGPoint(x: 250, y: 250))
    #expect(rect == CGRect(x: 190, y: 190, width: 10, height: 10))
}

@Test
func movingTranslatesRigidly() {
    var gesture = SelectionGesture(
        kind: .moving(original: CGRect(x: 20, y: 20, width: 60, height: 60),
                      grab: CGPoint(x: 50, y: 50)),
        at: CGPoint(x: 50, y: 50)
    )
    #expect(evaluate(&gesture, at: CGPoint(x: 90, y: 90))
            == CGRect(x: 60, y: 60, width: 60, height: 60))
}

@Test
func movingClampsInsideDisplayWithoutDeforming() {
    var gesture = SelectionGesture(
        kind: .moving(original: CGRect(x: 20, y: 20, width: 60, height: 60),
                      grab: CGPoint(x: 50, y: 50)),
        at: CGPoint(x: 50, y: 50)
    )
    let rect = evaluate(&gesture, at: CGPoint(x: 300, y: 300))
    #expect(rect == CGRect(x: 140, y: 140, width: 60, height: 60))
}

@Test
func resizingWorksFromEveryHandle() {
    let original = CGRect(x: 50, y: 50, width: 100, height: 100)
    let cases: [(ResizeHandle, CGPoint, CGRect)] = [
        (.topLeft, CGPoint(x: 40, y: 30), CGRect(x: 40, y: 30, width: 110, height: 120)),
        (.top, CGPoint(x: 100, y: 30), CGRect(x: 50, y: 30, width: 100, height: 120)),
        (.topRight, CGPoint(x: 170, y: 30), CGRect(x: 50, y: 30, width: 120, height: 120)),
        (.left, CGPoint(x: 30, y: 100), CGRect(x: 30, y: 50, width: 120, height: 100)),
        (.right, CGPoint(x: 180, y: 100), CGRect(x: 50, y: 50, width: 130, height: 100)),
        (.bottomLeft, CGPoint(x: 30, y: 180), CGRect(x: 30, y: 50, width: 120, height: 130)),
        (.bottom, CGPoint(x: 100, y: 190), CGRect(x: 50, y: 50, width: 100, height: 140)),
        (.bottomRight, CGPoint(x: 190, y: 190), CGRect(x: 50, y: 50, width: 140, height: 140))
    ]
    for (handle, point, expected) in cases {
        var gesture = SelectionGesture(
            kind: .resizing(handle: handle, original: original), at: point
        )
        #expect(evaluate(&gesture, at: point) == expected, "Handle \(handle)")
    }
}

@Test
func resizeCrossingOverFlipsLikeADrag() {
    var gesture = SelectionGesture(
        kind: .resizing(handle: .right, original: CGRect(x: 50, y: 50, width: 100, height: 100)),
        at: CGPoint(x: 150, y: 100)
    )
    #expect(evaluate(&gesture, at: CGPoint(x: 20, y: 100))
            == CGRect(x: 20, y: 50, width: 30, height: 100))
}

@Test
func resizeEnforcesMinimumSize() {
    var gesture = SelectionGesture(
        kind: .resizing(handle: .right, original: CGRect(x: 50, y: 50, width: 100, height: 100)),
        at: CGPoint(x: 150, y: 100)
    )
    #expect(evaluate(&gesture, at: CGPoint(x: 51, y: 100)).width == 8)
}

@Test
func drivenEdgesFollowTheGesture() {
    var drawing = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    _ = evaluate(&drawing, at: CGPoint(x: 140, y: 130))
    #expect(drawing.drivenEdges == [.right, .bottom])
    _ = evaluate(&drawing, at: CGPoint(x: 60, y: 70))
    #expect(drawing.drivenEdges == [.left, .top])

    let corner = SelectionGesture(
        kind: .resizing(handle: .topRight, original: CGRect(x: 50, y: 50, width: 100, height: 100)),
        at: CGPoint(x: 170, y: 30)
    )
    #expect(corner.drivenEdges == [.top, .right])

    // Crossing the fixed anchor flips which edge is actually being driven.
    let crossed = SelectionGesture(
        kind: .resizing(handle: .topRight, original: CGRect(x: 50, y: 50, width: 100, height: 100)),
        at: CGPoint(x: 20, y: 170)
    )
    #expect(crossed.drivenEdges == [.left, .bottom])

    let edge = SelectionGesture(
        kind: .resizing(handle: .left, original: CGRect(x: 50, y: 50, width: 100, height: 100)),
        at: CGPoint(x: 30, y: 100)
    )
    #expect(edge.drivenEdges == [.left])

    let move = SelectionGesture(
        kind: .moving(original: CGRect(x: 50, y: 50, width: 100, height: 100),
                      grab: CGPoint(x: 60, y: 60)),
        at: .zero
    )
    #expect(move.drivenEdges == .all)
}

// MARK: - Ticket 02: Shift-square

@Test
func shiftSquareFollowsDragDirectionInAllQuadrants() {
    let origin = CGPoint(x: 100, y: 100)
    let cases: [(CGPoint, CGRect)] = [
        (CGPoint(x: 160, y: 120), CGRect(x: 100, y: 100, width: 60, height: 60)),
        (CGPoint(x: 40, y: 120), CGRect(x: 40, y: 100, width: 60, height: 60)),
        (CGPoint(x: 40, y: 80), CGRect(x: 40, y: 40, width: 60, height: 60)),
        (CGPoint(x: 160, y: 80), CGRect(x: 100, y: 40, width: 60, height: 60))
    ]
    for (point, expected) in cases {
        var gesture = SelectionGesture(kind: .drawing(origin: origin), at: origin)
        gesture.shiftHeld = true
        #expect(evaluate(&gesture, at: point) == expected, "Square toward \(point)")
    }
}

@Test
func shiftCornerHandleKeepsOppositeCornerFixed() {
    var gesture = SelectionGesture(
        kind: .resizing(handle: .topLeft, original: CGRect(x: 50, y: 50, width: 100, height: 100)),
        at: CGPoint(x: 50, y: 50)
    )
    gesture.shiftHeld = true
    // Opposite corner (150,150) stays fixed; side = max(|dx|, |dy|) = 70.
    #expect(evaluate(&gesture, at: CGPoint(x: 80, y: 90))
            == CGRect(x: 80, y: 80, width: 70, height: 70))
}

@Test
func shiftEdgeHandleCentersOnPerpendicularAxis() {
    var right = SelectionGesture(
        kind: .resizing(handle: .right, original: CGRect(x: 50, y: 50, width: 100, height: 100)),
        at: CGPoint(x: 150, y: 100)
    )
    right.shiftHeld = true
    #expect(evaluate(&right, at: CGPoint(x: 170, y: 100))
            == CGRect(x: 50, y: 40, width: 120, height: 120))

    var top = SelectionGesture(
        kind: .resizing(handle: .top, original: CGRect(x: 50, y: 50, width: 100, height: 100)),
        at: CGPoint(x: 100, y: 50)
    )
    top.shiftHeld = true
    #expect(evaluate(&top, at: CGPoint(x: 100, y: 20))
            == CGRect(x: 35, y: 20, width: 130, height: 130))
}

@Test
func shiftTogglesMidGestureWithoutCursorMovement() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    #expect(evaluate(&gesture, at: CGPoint(x: 160, y: 120))
            == CGRect(x: 100, y: 100, width: 60, height: 20))

    gesture.shiftHeld = true
    #expect(evaluate(&gesture, at: gesture.lastPoint)
            == CGRect(x: 100, y: 100, width: 60, height: 60),
            "Pressing Shift must square the rectangle with no cursor movement")

    gesture.shiftHeld = false
    #expect(evaluate(&gesture, at: gesture.lastPoint)
            == CGRect(x: 100, y: 100, width: 60, height: 20),
            "Releasing Shift must return to freeform immediately")
}

@Test
func shiftSquareClampPreservesTheRatio() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 150, y: 100)), at: CGPoint(x: 150, y: 100)
    )
    gesture.shiftHeld = true
    // The unconstrained square would be 90×90, but only 50pt fit horizontally.
    let rect = evaluate(&gesture, at: CGPoint(x: 200, y: 190))
    #expect(rect.width == rect.height, "A clamped square must stay square")
    #expect(bounds.contains(rect))
    #expect(rect == CGRect(x: 150, y: 100, width: 50, height: 50))
}

@Test
func shiftSquareMinimumIsStillSquare() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    gesture.shiftHeld = true
    let rect = evaluate(&gesture, at: CGPoint(x: 101, y: 101))
    #expect(rect == CGRect(x: 100, y: 100, width: 8, height: 8))
}

// MARK: - Ticket 03: Space repositioning

@Test
func spaceFreezesSizeAndTranslates() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    _ = evaluate(&gesture, at: CGPoint(x: 140, y: 130))
    gesture.pressSpace()

    let slid = evaluate(&gesture, at: CGPoint(x: 150, y: 150))
    #expect(slid == CGRect(x: 110, y: 120, width: 40, height: 30),
            "Space must translate the frozen rectangle by the cursor delta")
}

@Test
func spaceResumeIsJumpFree() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    _ = evaluate(&gesture, at: CGPoint(x: 140, y: 130))
    gesture.pressSpace()
    let beforeRelease = evaluate(&gesture, at: CGPoint(x: 150, y: 150))
    gesture.releaseSpace()

    let afterRelease = evaluate(&gesture, at: CGPoint(x: 150, y: 150))
    #expect(afterRelease == beforeRelease, "Releasing Space must not move the rectangle")

    // The gesture resumes sizing from the new position.
    #expect(evaluate(&gesture, at: CGPoint(x: 160, y: 160))
            == CGRect(x: 110, y: 120, width: 50, height: 40))
}

@Test
func multipleSpaceCyclesAccumulate() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    _ = evaluate(&gesture, at: CGPoint(x: 140, y: 130))

    gesture.pressSpace()
    _ = evaluate(&gesture, at: CGPoint(x: 150, y: 140))
    gesture.releaseSpace()

    gesture.pressSpace()
    _ = evaluate(&gesture, at: CGPoint(x: 160, y: 150))
    gesture.releaseSpace()

    // Two +10/+10 slides: origin carried from (100,100) to (120,120).
    #expect(evaluate(&gesture, at: CGPoint(x: 160, y: 150))
            == CGRect(x: 120, y: 120, width: 40, height: 30))
}

@Test
func spaceComposesWithShift() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    gesture.shiftHeld = true
    _ = evaluate(&gesture, at: CGPoint(x: 140, y: 130))
    gesture.pressSpace()

    let slid = evaluate(&gesture, at: CGPoint(x: 150, y: 150))
    #expect(slid == CGRect(x: 110, y: 120, width: 40, height: 40),
            "A repositioned square is still a square")

    // Shift can be toggled while Space is held.
    gesture.shiftHeld = false
    #expect(evaluate(&gesture, at: CGPoint(x: 150, y: 150))
            == CGRect(x: 110, y: 120, width: 40, height: 30))
    gesture.shiftHeld = true
    #expect(evaluate(&gesture, at: CGPoint(x: 150, y: 150))
            == CGRect(x: 110, y: 120, width: 40, height: 40))

    gesture.releaseSpace()
    #expect(evaluate(&gesture, at: CGPoint(x: 150, y: 150))
            == CGRect(x: 110, y: 120, width: 40, height: 40),
            "Resume after Space keeps the square in place")
}

@Test
func spaceTranslationRespectsDisplayContainment() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    _ = evaluate(&gesture, at: CGPoint(x: 140, y: 130))
    gesture.pressSpace()

    let slid = evaluate(&gesture, at: CGPoint(x: 400, y: 400))
    #expect(slid == CGRect(x: 160, y: 170, width: 40, height: 30),
            "The frozen rectangle slides to the display edge and stops")
}

@Test
func spaceWorksDuringHandleResize() {
    var gesture = SelectionGesture(
        kind: .resizing(handle: .right, original: CGRect(x: 50, y: 50, width: 100, height: 100)),
        at: CGPoint(x: 150, y: 100)
    )
    #expect(evaluate(&gesture, at: CGPoint(x: 180, y: 100))
            == CGRect(x: 50, y: 50, width: 130, height: 100))

    gesture.pressSpace()
    #expect(evaluate(&gesture, at: CGPoint(x: 190, y: 110))
            == CGRect(x: 60, y: 60, width: 130, height: 100))
    gesture.releaseSpace()

    #expect(evaluate(&gesture, at: CGPoint(x: 190, y: 110))
            == CGRect(x: 60, y: 60, width: 130, height: 100),
            "Resume after Space is jump-free for a resize too")
    #expect(evaluate(&gesture, at: CGPoint(x: 200, y: 110))
            == CGRect(x: 60, y: 60, width: 140, height: 100),
            "The resize continues from the translated original")
}

// MARK: - Ticket 04: anchored tracking

@Test
func anchoredTrackingMatchesTheEquivalentDrag() {
    let origin = CGPoint(x: 100, y: 100)
    for point in [CGPoint(x: 160, y: 130), CGPoint(x: 40, y: 60), CGPoint(x: 60, y: 150)] {
        var drag = SelectionGesture(kind: .drawing(origin: origin), at: origin)
        var anchored = SelectionGesture(kind: .anchored(anchor: origin), at: origin)
        #expect(evaluate(&drag, at: point) == evaluate(&anchored, at: point),
                "Anchored tracking must equal the drag toward \(point)")
    }
}

@Test
func anchoredTrackingHonoursShiftAndSpace() {
    var gesture = SelectionGesture(
        kind: .anchored(anchor: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    gesture.shiftHeld = true
    #expect(evaluate(&gesture, at: CGPoint(x: 160, y: 120))
            == CGRect(x: 100, y: 100, width: 60, height: 60))

    gesture.pressSpace()
    #expect(evaluate(&gesture, at: CGPoint(x: 170, y: 130))
            == CGRect(x: 110, y: 110, width: 60, height: 60))
    gesture.releaseSpace()
    #expect(evaluate(&gesture, at: CGPoint(x: 170, y: 130))
            == CGRect(x: 110, y: 110, width: 60, height: 60))
}

// MARK: - Tickets 09/10: typed resize and aspect locks

@Test
func typedResizeIsCentreAnchored() {
    let resized = SelectionGeometry.resizedAboutCenter(
        CGRect(x: 50, y: 50, width: 100, height: 100),
        to: CGSize(width: 160, height: 60),
        ratio: nil,
        in: CGRect(x: 0, y: 0, width: 900, height: 600)
    )
    #expect(resized == CGRect(x: 20, y: 70, width: 160, height: 60),
            "The centre (100,100) must not move")
}

@Test
func typedResizeTranslatesBackInsideBeforeShrinking() {
    // Centre near the left edge: the requested size fits the display, so it
    // is pulled back inside rather than shrunk.
    let pulled = SelectionGeometry.resizedAboutCenter(
        CGRect(x: 20, y: 80, width: 40, height: 40),
        to: CGSize(width: 160, height: 40),
        ratio: nil,
        in: bounds
    )
    #expect(pulled.width == 160, "A size that fits must never be shrunk")
    #expect(pulled.minX == 0, "Pulled minimally back inside the display")

    // A size that genuinely cannot fit is scaled down, preserving the ratio
    // when one is active.
    let shrunk = SelectionGeometry.resizedAboutCenter(
        CGRect(x: 80, y: 80, width: 40, height: 40),
        to: CGSize(width: 400, height: 300),
        ratio: 4.0 / 3,
        in: bounds
    )
    #expect(shrunk.width == 200 && shrunk.height == 150,
            "Display-fit under a lock is a ratio-preserving scale")
}

@Test
func lockedRatioDrivesEveryHandleClass() {
    // Fresh drag under a 16:9 lock.
    var drawing = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 10, y: 10)), at: CGPoint(x: 10, y: 10)
    )
    drawing.lockedRatio = 16.0 / 9
    let drawn = evaluate(&drawing, at: CGPoint(x: 90, y: 40))
    #expect(abs(drawn.width / drawn.height - 16.0 / 9) < 0.001)

    // Corner handle: opposite corner fixed.
    var corner = SelectionGesture(
        kind: .resizing(handle: .bottomRight, original: CGRect(x: 20, y: 20, width: 80, height: 45)),
        at: CGPoint(x: 100, y: 65)
    )
    corner.lockedRatio = 16.0 / 9
    let cornered = evaluate(&corner, at: CGPoint(x: 140, y: 80))
    #expect(cornered.origin == CGPoint(x: 20, y: 20), "Opposite corner stays put")
    #expect(abs(cornered.width / cornered.height - 16.0 / 9) < 0.001)

    // Edge handle: opposite edge fixed, centred on the perpendicular axis.
    var edge = SelectionGesture(
        kind: .resizing(handle: .right, original: CGRect(x: 20, y: 60, width: 80, height: 45)),
        at: CGPoint(x: 100, y: 80)
    )
    edge.lockedRatio = 16.0 / 9
    let edged = evaluate(&edge, at: CGPoint(x: 120, y: 80))
    #expect(edged.minX == 20)
    #expect(abs(edged.midY - 82.5) < 0.001, "Centred on the perpendicular axis")
    #expect(abs(edged.width / edged.height - 16.0 / 9) < 0.001)
}

@Test
func shiftBeatsTheArmedAspectLock() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 10, y: 10)), at: CGPoint(x: 10, y: 10)
    )
    gesture.lockedRatio = 16.0 / 9
    gesture.shiftHeld = true
    let rect = evaluate(&gesture, at: CGPoint(x: 90, y: 40))
    #expect(rect.width == rect.height, "Shift is always a reliable escape to 1:1")

    gesture.shiftHeld = false
    let unlocked = evaluate(&gesture, at: gesture.lastPoint)
    #expect(abs(unlocked.width / unlocked.height - 16.0 / 9) < 0.001,
            "Releasing Shift returns to the armed lock")
}

@Test
func lockedMinimumClampPreservesRatio() {
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 100, y: 100)), at: CGPoint(x: 100, y: 100)
    )
    gesture.lockedRatio = 16.0 / 9
    let rect = evaluate(&gesture, at: CGPoint(x: 101, y: 101))
    #expect(abs(rect.width / rect.height - 16.0 / 9) < 0.001,
            "The minimum-size clamp is a ratio-preserving scale")
    #expect(rect.width >= 8 && rect.height >= 8)
}

@Test
func armedFixedSizeFrameFollowsTheCursorAndClamps() {
    var gesture = SelectionGesture(
        kind: .placingFixedSize(CGSize(width: 80, height: 60)), at: .zero
    )
    #expect(evaluate(&gesture, at: CGPoint(x: 100, y: 100))
            == CGRect(x: 60, y: 70, width: 80, height: 60),
            "The ghost frame centres on the cursor")
    #expect(evaluate(&gesture, at: CGPoint(x: 5, y: 5))
            == CGRect(x: 0, y: 0, width: 80, height: 60),
            "The frame is clamped inside the display, size intact")
}

// MARK: - Review regression tests

@Test
func shiftDragNearTheDisplayEdgeStaysContained() {
    // The unconstrained square would overshoot the 4pt of room to the right;
    // the fit clamp must win over the 8pt minimum rather than escape bounds.
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 196, y: 100)), at: CGPoint(x: 196, y: 100)
    )
    gesture.shiftHeld = true
    let rect = evaluate(&gesture, at: CGPoint(x: 200, y: 140))
    #expect(bounds.contains(rect), "A ratio-constrained rect must never leave the display")
    #expect(rect.width == rect.height)
}

@Test
func spaceResumeAfterAClampedSlideIsJumpFree() {
    // Up-left drag, then a slide that slams into the bottom-right corner.
    var gesture = SelectionGesture(
        kind: .drawing(origin: CGPoint(x: 150, y: 150)), at: CGPoint(x: 150, y: 150)
    )
    _ = evaluate(&gesture, at: CGPoint(x: 110, y: 120))
    gesture.pressSpace()
    let slid = evaluate(&gesture, at: CGPoint(x: 200, y: 200))
    #expect(slid == CGRect(x: 160, y: 170, width: 40, height: 30),
            "The slide stops at the display edge")
    gesture.releaseSpace()
    #expect(evaluate(&gesture, at: CGPoint(x: 200, y: 200)) == slid,
            "Resume must reproduce the clamped rectangle exactly")
}
