import CoreGraphics
import Foundation

/// Composition for the spotlight. A spotlight cannot be drawn one at a time —
/// two overlapping dims would darken their overlap twice — so the render pass
/// asks for one path covering everything that is *not* spotlighted and fills it
/// once. Because the bright regions are unioned before the subtraction, a
/// double-dimmed seam is not merely avoided but unrepresentable.
enum SpotlightGeometry {
    static let defaultStrength: CGFloat = 0.6
    static let strengthRange: ClosedRange<CGFloat> = 0.1...0.95

    static func shapePath(_ rect: CGRect, shape: SpotlightShape) -> CGPath {
        switch shape {
        case .rectangle: return CGPath(rect: rect, transform: nil)
        case .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        }
    }

    /// `area` minus the union of every spotlight, as a path to be filled with
    /// the even-odd rule. Nil when there is nothing to dim around.
    static func dimPath(area: CGRect, spotlights: [(rect: CGRect, shape: SpotlightShape)]) -> CGPath? {
        guard !spotlights.isEmpty else { return nil }
        let shapes = spotlights.map { shapePath($0.rect, shape: $0.shape) }
        let bright = shapes.dropFirst().reduce(shapes[0]) { $0.union($1) }
        let path = CGMutablePath()
        path.addRect(area)
        path.addPath(bright)
        return path
    }
}

/// Geometry for the loupe: the two circles, the connector between them, and the
/// magnification the pair implies. Magnification is never stored — it is lens
/// radius ÷ source radius — so the drawn geometry cannot contradict the number
/// the options row reports.
enum LoupeGeometry {
    static let defaultSourceRadius: CGFloat = 28
    static let defaultMagnification: CGFloat = 2
    static let outlineWidth: CGFloat = 2
    /// A circle smaller than this has nothing left to show or to grab.
    static let minimumRadius: CGFloat = 6
    static let magnificationRange: ClosedRange<CGFloat> = 1...8
    /// Where the lens sits when the user has not dragged it anywhere: up and to
    /// the right of the detail, the way an inset is usually parked.
    static let defaultLensOffset = CGVector(dx: 120, dy: -90)

    static func box(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    static func magnification(sourceRadius: CGFloat, lensRadius: CGFloat) -> CGFloat {
        guard sourceRadius > 0 else { return 1 }
        return lensRadius / sourceRadius
    }

    /// The lens radius that makes the pair magnify by `magnification`.
    static func lensRadius(sourceRadius: CGFloat, magnification: CGFloat) -> CGFloat {
        sourceRadius * max(1, magnification)
    }

    /// The two ends of the connector, on each circle's edge along the
    /// centre-to-centre axis. Nil when the circles touch or overlap, where there
    /// is no gap left to join.
    static func connector(
        source: CGPoint, sourceRadius: CGFloat, lens: CGPoint, lensRadius: CGFloat
    ) -> (CGPoint, CGPoint)? {
        let distance = hypot(lens.x - source.x, lens.y - source.y)
        guard distance > sourceRadius + lensRadius else { return nil }
        let direction = CGPoint(x: (lens.x - source.x) / distance, y: (lens.y - source.y) / distance)
        return (
            CGPoint(
                x: source.x + direction.x * sourceRadius, y: source.y + direction.y * sourceRadius
            ),
            CGPoint(x: lens.x - direction.x * lensRadius, y: lens.y - direction.y * lensRadius)
        )
    }

    /// The union of both circles: what selection, hit-testing and the selection
    /// indicator all address.
    static func bounds(
        source: CGPoint, sourceRadius: CGFloat, lens: CGPoint, lensRadius: CGFloat
    ) -> CGRect {
        box(center: source, radius: sourceRadius).union(box(center: lens, radius: lensRadius))
    }
}

/// Geometry for the measure tool: axis snapping, the device-pixel readout, and
/// where the readout sits. Pure functions over value types — the overlay and the
/// renderer call in, and the tests call in directly rather than through
/// synthesized events.
enum MeasureGeometry {
    /// How close to an axis a drag has to be before it counts as being on it.
    /// A constant, not a user setting: the point is that a row height measures
    /// the row rather than the row plus a degree of hand tremor.
    static let snapTolerance: CGFloat = 5 * .pi / 180

    /// How far the readout pill floats off the line it belongs to.
    static let readoutOffset: CGFloat = 18

    /// `point` pulled onto the horizontal or vertical through `anchor` when the
    /// two are within the tolerance of an axis, and left exactly where it is
    /// otherwise. Applied at placement, so the stored endpoint is already
    /// snapped and a later move can never make the readout disagree with the
    /// drawn line.
    static func snapped(_ point: CGPoint, anchoredAt anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let slack = tan(snapTolerance)
        if abs(dy) <= abs(dx) * slack { return CGPoint(x: point.x, y: anchor.y) }
        if abs(dx) <= abs(dy) * slack { return CGPoint(x: anchor.x, y: point.y) }
        return point
    }

    /// The straight-line distance in device pixels. `pixelScale` is the captured
    /// image's pixels-per-point ratio, never `backingScaleFactor` — the two
    /// disagree in scaled HiDPI display modes, and it is the capture the number
    /// has to describe.
    static func devicePixels(from: CGPoint, to: CGPoint, pixelScale: CGFloat) -> Int {
        Int((hypot(to.x - from.x, to.y - from.y) * pixelScale).rounded())
    }

    static func readout(from: CGPoint, to: CGPoint, pixelScale: CGFloat) -> String {
        "\(devicePixels(from: from, to: to, pixelScale: pixelScale)) px"
    }

    // MARK: Auto-measure

    /// Which way the boundary scan runs.
    enum ScanAxis { case horizontal, vertical }

    /// The run of pixels between the nearest boundary on each side of the
    /// anchor, inclusive at both ends.
    struct BoundarySpan: Equatable {
        var low: Int
        var high: Int

        var length: Int { high - low + 1 }
    }

    /// How different two adjacent pixels have to be to count as an edge, as a
    /// maximum absolute per-channel difference. Tuned so an anti-aliased UI edge
    /// registers and a gradient or compression noise does not — one constant,
    /// not a user setting.
    static let boundaryThreshold = 32

    /// Scans outward from a pixel until the colour changes sharply on each side.
    /// A side with no such change runs out to the edge of the image rather than
    /// failing, so the user always sees what the tool found.
    static func boundarySpan(
        in pixels: PixelBuffer, x: Int, y: Int, along axis: ScanAxis
    ) -> BoundarySpan? {
        guard x >= 0, y >= 0, x < pixels.width, y < pixels.height else { return nil }
        let extent = axis == .vertical ? pixels.height : pixels.width
        let anchor = axis == .vertical ? y : x

        func differs(_ a: Int, _ b: Int) -> Bool {
            guard let p = axis == .vertical ? pixels.color(x: x, y: a) : pixels.color(x: a, y: y),
                  let q = axis == .vertical ? pixels.color(x: x, y: b) : pixels.color(x: b, y: y)
            else { return false }
            let difference = max(
                abs(Int(p.r) - Int(q.r)),
                abs(Int(p.g) - Int(q.g)),
                abs(Int(p.b) - Int(q.b))
            )
            return difference > boundaryThreshold
        }

        // Each pixel is compared with its neighbour one step back toward the
        // anchor, so the transition sits between the pair and the span's edge is
        // the pixel on the anchor's side of it.
        var low = 0
        for i in stride(from: anchor - 1, through: 0, by: -1) where differs(i, i + 1) {
            low = i + 1
            break
        }
        var high = extent - 1
        for j in stride(from: anchor + 1, to: extent, by: 1) where differs(j, j - 1) {
            high = j - 1
            break
        }
        return BoundarySpan(low: low, high: high)
    }

    /// Half the length of the tick drawn across each endpoint. Derived from the
    /// stroke width so caps scale with the line.
    static func capReach(forLineWidth width: CGFloat) -> CGFloat {
        max(5, width * 2.5)
    }

    /// Centre of the readout pill: the line's midpoint pushed perpendicular to
    /// the line, flipped to the other side when that would take the pill off the
    /// display. The pill itself is never rotated — that is what keeps the number
    /// upright whichever way the line was drawn.
    static func readoutCenter(
        from: CGPoint, to: CGPoint, size: CGSize, within area: CGRect
    ) -> CGPoint {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let length = max(1, hypot(to.x - from.x, to.y - from.y))
        let normal = CGPoint(x: -(to.y - from.y) / length, y: (to.x - from.x) / length)
        let preferred = CGPoint(
            x: mid.x + normal.x * readoutOffset,
            y: mid.y + normal.y * readoutOffset
        )
        let pill = CGRect(
            x: preferred.x - size.width / 2, y: preferred.y - size.height / 2,
            width: size.width, height: size.height
        )
        guard !area.contains(pill) else { return preferred }
        return CGPoint(
            x: mid.x - normal.x * readoutOffset,
            y: mid.y - normal.y * readoutOffset
        )
    }
}

/// What holding Shift does to a drawing drag: directional tools are pulled onto
/// the nearest 45° ray from where the drag began, rectangular ones become
/// square. Pure functions of the drag's two ends and nothing else, so the
/// overlay can re-run them the instant Shift goes down or up mid-drag.
enum ShiftConstraint {
    /// `point` projected onto the nearest 45° ray through `anchor`. Projection
    /// rather than rotation, so a mostly-horizontal drag ends under the cursor's
    /// x — the same feel as the measure tool's own tolerance snap.
    static func angleSnapped(_ point: CGPoint, anchoredAt anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        guard dx != 0 || dy != 0 else { return anchor }

        let step = CGFloat.pi / 4
        let ray = (atan2(dy, dx) / step).rounded() * step
        let unit = CGPoint(x: cos(ray), y: sin(ray))
        let along = dx * unit.x + dy * unit.y
        return CGPoint(x: anchor.x + unit.x * along, y: anchor.y + unit.y * along)
    }

    /// The furthest point along the `anchor` → `point` ray that still lies
    /// inside `bounds`. Clamping x and y independently would pull the endpoint
    /// off the ray — which, for a constrained drag, means silently drawing a
    /// stroke that is no longer at 45°.
    static func clamped(_ point: CGPoint, from anchor: CGPoint, within bounds: CGRect) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        var scale: CGFloat = 1
        if dx > 0 { scale = min(scale, (bounds.maxX - anchor.x) / dx) }
        if dx < 0 { scale = min(scale, (bounds.minX - anchor.x) / dx) }
        if dy > 0 { scale = min(scale, (bounds.maxY - anchor.y) / dy) }
        if dy < 0 { scale = min(scale, (bounds.minY - anchor.y) / dy) }
        scale = max(0, scale)
        return CGPoint(x: anchor.x + dx * scale, y: anchor.y + dy * scale)
    }

    /// The square a drag from `anchor` to `point` makes: the longer of the two
    /// spans on both sides, growing in the direction dragged so the shape never
    /// flips across the anchor. Same convention as the Selection's own
    /// shift-square (`SelectionGeometry.ratioRect`), deliberately without its
    /// minimum size and display-fit clamps — an annotation may hang off the
    /// edge and be cropped, a Selection may not.
    static func squared(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let side = max(abs(dx), abs(dy))
        return CGRect(
            x: dx < 0 ? anchor.x - side : anchor.x,
            y: dy < 0 ? anchor.y - side : anchor.y,
            width: side,
            height: side
        )
    }
}
