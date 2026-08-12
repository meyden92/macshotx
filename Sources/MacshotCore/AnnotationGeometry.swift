import AppKit

/// Which handle of a selection box a drag is driving. Rect-like annotations —
/// and the Selection itself — use the eight box handles; line-like ones use
/// their two endpoints.
enum ResizeHandle {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
    case lineStart, lineEnd
    /// The loupe's two circles: a handle at each centre to move it, and one on
    /// each edge to resize it.
    case loupeSource, loupeLens, loupeSourceRadius, loupeLensRadius
}

/// Which of a loupe's circles a gesture is addressing.
enum LoupeCircle { case source, lens }

extension CGPoint {
    /// This point turned by `angle` radians about `center`. View coordinates are
    /// flipped (y down) and the renderer rotates that same space, so a positive
    /// angle turns the same way here as it does on screen.
    func rotated(by angle: CGFloat, about center: CGPoint) -> CGPoint {
        guard angle != 0 else { return self }
        let s = sin(angle), c = cos(angle)
        let dx = x - center.x, dy = y - center.y
        return CGPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }
}

extension CGPoint {
    fileprivate func offset(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}

/// Annotation geometry: bounds, hit-testing, handle positions, translation and
/// resize, as values in and values out. This lived as private methods on the
/// capture overlay view, reachable only by synthesizing mouse events; it is out
/// here so the math is directly testable and so the overlay and the detached
/// editor share one implementation. Coordinates are flipped view points
/// (top-left origin), matching the overlay.
enum AnnotationGeometry {
    /// How far off an annotation a click may land and still count as hitting it.
    static let hitTolerance: CGFloat = 4

    // MARK: Hit-testing

    /// Index of the topmost annotation under `point`, or nil. The list is in
    /// z-order, so the search runs back to front.
    static func hitIndex(in annotations: [Annotation], at point: CGPoint) -> Int? {
        annotations.lastIndex { hitTest($0, at: point) }
    }

    /// Stroke-path kinds are tested against their segments so a click inside a
    /// diagonal line's bounding box but away from the ink misses; everything
    /// else is tested against its bounding box.
    static func hitTest(_ annotation: Annotation, at point: CGPoint) -> Bool {
        switch annotation {
        case let .line(from, to, _), let .arrow(from, to, _), let .measure(from, to, _):
            return distance(from: point, toSegment: (from, to)) <= hitTolerance
        case let .freehand(points, _), let .highlighter(points, _):
            guard points.count >= 2 else { return false }
            for i in 0..<(points.count - 1) {
                if distance(from: point, toSegment: (points[i], points[i + 1])) <= hitTolerance {
                    return true
                }
            }
            return false
        default:
            // A rotated annotation is clicked where it is drawn: bring the point
            // back into the annotation's own unrotated frame and test there.
            return boundingBox(of: annotation)
                .insetBy(dx: -hitTolerance, dy: -hitTolerance)
                .contains(unrotated(point, of: annotation))
        }
    }

    /// `point` expressed in `annotation`'s own unrotated frame.
    static func unrotated(_ point: CGPoint, of annotation: Annotation) -> CGPoint {
        point.rotated(by: -annotation.rotation, about: rotationCenter(of: annotation))
    }

    // MARK: Bounds

    /// The annotation's box in its own unrotated frame. Callers that need where
    /// it actually sits on screen want `rotatedCorners(of:)`.
    static func boundingBox(of annotation: Annotation) -> CGRect {
        switch annotation {
        case let .rectangle(rect, _), let .ellipse(rect, _), let .fillRect(rect, _),
             let .spotlight(rect, _), let .blur(rect), let .pixelate(rect):
            return rect
        case let .line(from, to, _), let .arrow(from, to, _), let .measure(from, to, _):
            return CGRect(
                x: min(from.x, to.x),
                y: min(from.y, to.y),
                width: abs(to.x - from.x),
                height: abs(to.y - from.y)
            )
        case let .freehand(points, _),
             let .highlighter(points, _),
             let .fillFreehand(points, _):
            guard !points.isEmpty else { return .zero }
            var minX = CGFloat.infinity, minY = CGFloat.infinity
            var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for p in points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case let .text(box, content, style):
            return TextLayout.fittedBox(box, content: content, style: style)
        case let .callout(anchor, box, content, style):
            let bubbleRect = CalloutGeometry.bubbleRect(box: box, content: content, style: style)
            return bubbleRect.union(CGRect(x: anchor.x - 2, y: anchor.y - 2, width: 4, height: 4))
        case let .stepMarker(center, _, _):
            let r: CGFloat = 14
            return CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        case let .loupe(source, sourceRadius, lens, lensRadius, _):
            return LoupeGeometry.bounds(
                source: source, sourceRadius: sourceRadius,
                lens: lens, lensRadius: lensRadius
            )
        }
    }

    static func textSize(content: String, style: TextStyle) -> CGSize {
        (content as NSString).size(withAttributes: [.font: TextLayout.font(for: style)])
    }

    // MARK: Corner radius

    /// A rounded rect cannot round more than half its shorter side without
    /// turning into a blob, so the radius is clamped rather than the rectangle
    /// being prevented from shrinking.
    static func clampedCornerRadius(_ radius: CGFloat, in rect: CGRect) -> CGFloat {
        max(0, min(radius, min(rect.width, rect.height) / 2))
    }

    // MARK: Dashes

    /// The dash lengths for a stroke of `length`, chosen so the pattern divides
    /// the path evenly: a dashed stroke starts and ends on a dash, and a dotted
    /// one starts and ends on a dot, at any length or width. Solid returns an
    /// empty pattern, which is how CoreGraphics spells "no dash".
    ///
    /// Dashed: n dashes and n-1 gaps span the length, with a dash half again as
    /// long as a gap. Dotted: n dots at even centres, drawn as zero-length
    /// dashes under a round cap, so each dot is one line-width across.
    static func dashPattern(
        _ dash: DashStyle, length: CGFloat, lineWidth: CGFloat
    ) -> [CGFloat] {
        let width = max(lineWidth, 0.5)
        guard dash != .solid, length > width else { return [] }
        switch dash {
        case .solid:
            return []
        case .dashed:
            let count = max(1, Int((length / (width * 5)).rounded()))
            let gap = length / (2.5 * CGFloat(count) - 1)
            return [gap * 1.5, gap]
        case .dotted:
            let count = max(2, Int((length / (width * 2)).rounded()) + 1)
            return [0, length / CGFloat(count - 1)]
        }
    }

    /// Swaps a line or arrow's endpoints. The geometry is otherwise untouched,
    /// so a flipped arrow is the same arrow drawn the other way round.
    static func flipped(_ annotation: Annotation) -> Annotation {
        switch annotation {
        case let .line(from, to, style):
            return .line(from: to, to: from, style)
        // Measure is deliberately absent: swapping a dimension line's ends is
        // invisible, and flip is only offered on an arrow.
        case let .arrow(from, to, style):
            return .arrow(from: to, to: from, style)
        default:
            return annotation
        }
    }

    // MARK: Marquee

    /// Whether a marquee touches this annotation. Membership is by intersection,
    /// not containment, and goes through the same geometry the hit test uses:
    /// stroke-path kinds by their segments, so a marquee near but not on a long
    /// diagonal misses it, and everything else by its oriented — possibly
    /// rotated — box.
    static func intersects(_ annotation: Annotation, marquee rect: CGRect) -> Bool {
        switch annotation {
        case let .line(from, to, _), let .arrow(from, to, _), let .measure(from, to, _):
            return polyline([from, to], intersects: rect)
        case let .freehand(points, _), let .highlighter(points, _):
            return polyline(points, intersects: rect)
        default:
            return convexPolygon(rotatedCorners(of: annotation), intersects: rect)
        }
    }

    /// Indices of every annotation the marquee touches, in z-order.
    static func indices(in annotations: [Annotation], touching rect: CGRect) -> [Int] {
        annotations.indices.filter { intersects(annotations[$0], marquee: rect) }
    }

    /// The axis-aligned box around a whole set, taking each annotation where it
    /// is drawn. Nil for an empty set.
    static func combinedBounds(of annotations: [Annotation]) -> CGRect? {
        guard !annotations.isEmpty else { return nil }
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for annotation in annotations {
            for corner in rotatedCorners(of: annotation) {
                minX = min(minX, corner.x); minY = min(minY, corner.y)
                maxX = max(maxX, corner.x); maxY = max(maxY, corner.y)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func polyline(_ points: [CGPoint], intersects rect: CGRect) -> Bool {
        if points.contains(where: { rect.contains($0) }) { return true }
        guard points.count >= 2 else { return false }
        for i in 0..<(points.count - 1) {
            if segment(points[i], points[i + 1], crosses: rect) { return true }
        }
        return false
    }

    /// Only called once both endpoints are known to be outside, so crossing an
    /// edge is the only way left in.
    private static func segment(_ a: CGPoint, _ b: CGPoint, crosses rect: CGRect) -> Bool {
        let corners = boxCorners(rect)
        for i in 0..<4 {
            if segmentsCross(a, b, corners[i], corners[(i + 1) % 4]) { return true }
        }
        return false
    }

    private static func segmentsCross(
        _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint
    ) -> Bool {
        func side(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat {
            (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
        }
        return (side(a, b, c) > 0) != (side(a, b, d) > 0)
            && (side(c, d, a) > 0) != (side(c, d, b) > 0)
    }

    /// Separating-axis test. Two convex shapes miss each other exactly when some
    /// edge normal of one of them separates their projections.
    private static func convexPolygon(_ corners: [CGPoint], intersects rect: CGRect) -> Bool {
        var axes = [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        for i in corners.indices {
            let next = corners[(i + 1) % corners.count]
            axes.append(CGPoint(x: corners[i].y - next.y, y: next.x - corners[i].x))
        }
        let box = boxCorners(rect)
        for axis in axes {
            let shape = span(corners, along: axis)
            let marquee = span(box, along: axis)
            if shape.1 < marquee.0 || marquee.1 < shape.0 { return false }
        }
        return true
    }

    private static func span(_ points: [CGPoint], along axis: CGPoint) -> (CGFloat, CGFloat) {
        var low = CGFloat.infinity, high = -CGFloat.infinity
        for point in points {
            let value = point.x * axis.x + point.y * axis.y
            low = min(low, value); high = max(high, value)
        }
        return (low, high)
    }

    private static func boxCorners(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    // MARK: Rotation

    /// How far above the top edge of the selection box the rotation handle floats.
    static let rotationHandleOffset: CGFloat = 22

    /// The point an annotation turns about: the centre of its unrotated bounds.
    static func rotationCenter(of annotation: Annotation) -> CGPoint {
        let box = boundingBox(of: annotation)
        return CGPoint(x: box.midX, y: box.midY)
    }

    /// The annotation's box where it is drawn — corners clockwise from the one
    /// that is top-left before rotation. `outset` grows the box first, so the
    /// selection outline can sit clear of the ink.
    static func rotatedCorners(of annotation: Annotation, outset: CGFloat = 0) -> [CGPoint] {
        let box = boundingBox(of: annotation).insetBy(dx: -outset, dy: -outset)
        let center = rotationCenter(of: annotation)
        let angle = annotation.rotation
        return boxCorners(box).map { $0.rotated(by: angle, about: center) }
    }

    /// Where the rotation handle sits, or nil for a kind that does not rotate.
    static func rotationHandlePosition(for annotation: Annotation) -> CGPoint? {
        guard annotation.supportsRotation else { return nil }
        let box = boundingBox(of: annotation)
        let center = rotationCenter(of: annotation)
        return CGPoint(x: box.midX, y: box.minY - rotationHandleOffset)
            .rotated(by: annotation.rotation, about: center)
    }

    static func isOnRotationHandle(
        _ point: CGPoint, of annotation: Annotation, handleSize: CGFloat
    ) -> Bool {
        guard let position = rotationHandlePosition(for: annotation) else { return false }
        let half = handleSize / 2 + 2
        return abs(point.x - position.x) <= half && abs(point.y - position.y) <= half
    }

    /// The angle that puts the rotation handle under `point`. The handle starts
    /// straight above the centre, so the pointer's bearing runs a quarter turn
    /// ahead of the angle it means. Snapping rounds to the nearest quarter turn.
    static func rotation(
        of annotation: Annotation, towards point: CGPoint, snapping: Bool
    ) -> CGFloat {
        let center = rotationCenter(of: annotation)
        let angle = atan2(point.y - center.y, point.x - center.x) + .pi / 2
        guard snapping else { return angle }
        let quarter = CGFloat.pi / 2
        return (angle / quarter).rounded() * quarter
    }

    static func rotate(
        _ annotation: Annotation, towards point: CGPoint, snapping: Bool
    ) -> Annotation {
        guard annotation.supportsRotation else { return annotation }
        return annotation.rotated(to: rotation(of: annotation, towards: point, snapping: snapping))
    }

    // MARK: Handles

    /// Resize handles where they are drawn — computed on the unrotated box and
    /// then turned, so they ride the rotation.
    static func handlePositions(for annotation: Annotation) -> [(ResizeHandle, CGPoint)] {
        let positions = unrotatedHandlePositions(for: annotation)
        let angle = annotation.rotation
        guard angle != 0 else { return positions }
        let center = rotationCenter(of: annotation)
        return positions.map { ($0.0, $0.1.rotated(by: angle, about: center)) }
    }

    private static func unrotatedHandlePositions(
        for annotation: Annotation
    ) -> [(ResizeHandle, CGPoint)] {
        switch annotation {
        case let .rectangle(rect, _), let .ellipse(rect, _), let .fillRect(rect, _),
             let .spotlight(rect, _), let .blur(rect), let .pixelate(rect):
            return rectHandlePositions(rect)
        case let .line(from, to, _), let .arrow(from, to, _), let .measure(from, to, _):
            return [(.lineStart, from), (.lineEnd, to)]
        case let .callout(anchor, box, content, style):
            let rect = CalloutGeometry.bubbleRect(box: box, content: content, style: style)
            return [(.lineStart, anchor), (.lineEnd, CGPoint(x: rect.midX, y: rect.midY))]
        case let .text(box, content, style):
            // The text box is resizable, and re-wraps as it is dragged.
            return rectHandlePositions(TextLayout.fittedBox(box, content: content, style: style))
        case let .loupe(source, sourceRadius, lens, lensRadius, _):
            return [
                (.loupeSource, source),
                (.loupeSourceRadius, CGPoint(x: source.x + sourceRadius, y: source.y)),
                (.loupeLens, lens),
                (.loupeLensRadius, CGPoint(x: lens.x + lensRadius, y: lens.y))
            ]
        case .stepMarker, .freehand, .highlighter, .fillFreehand:
            return []
        }
    }

    static func rectHandlePositions(_ rect: CGRect) -> [(ResizeHandle, CGPoint)] {
        let cx = rect.midX
        let cy = rect.midY
        return [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: cx, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.left, CGPoint(x: rect.minX, y: cy)),
            (.right, CGPoint(x: rect.maxX, y: cy)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottom, CGPoint(x: cx, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
    }

    static func handle(
        at point: CGPoint, on annotation: Annotation, handleSize: CGFloat
    ) -> ResizeHandle? {
        handle(at: point, among: handlePositions(for: annotation), handleSize: handleSize)
    }

    static func rectHandle(
        at point: CGPoint, in rect: CGRect, handleSize: CGFloat
    ) -> ResizeHandle? {
        handle(at: point, among: rectHandlePositions(rect), handleSize: handleSize)
    }

    /// A handle grabs slightly wider than it draws, so it stays catchable.
    private static func handle(
        at point: CGPoint, among positions: [(ResizeHandle, CGPoint)], handleSize: CGFloat
    ) -> ResizeHandle? {
        let half = handleSize / 2 + 2
        for (handle, center) in positions {
            if abs(point.x - center.x) <= half && abs(point.y - center.y) <= half {
                return handle
            }
        }
        return nil
    }

    // MARK: Mutation

    static func resize(
        _ annotation: Annotation, handle: ResizeHandle, to point: CGPoint
    ) -> Annotation {
        let angle = annotation.rotation
        guard angle != 0 else { return resizedInPlace(annotation, handle: handle, to: point) }
        // Drive the resize in the annotation's own unrotated frame, then slide
        // the result back: rendering turns about the box's centre, and resizing
        // just moved that centre, which would otherwise swing the whole shape.
        let center = rotationCenter(of: annotation)
        let resized = resizedInPlace(
            annotation, handle: handle, to: point.rotated(by: -angle, about: center)
        )
        let moved = rotationCenter(of: resized)
        let turned = moved.rotated(by: angle, about: center)
        return translate(resized, dx: turned.x - moved.x, dy: turned.y - moved.y)
    }

    private static func resizedInPlace(
        _ annotation: Annotation, handle: ResizeHandle, to point: CGPoint
    ) -> Annotation {
        switch annotation {
        case let .rectangle(rect, style):
            return .rectangle(resizedRect(rect, handle: handle, to: point), style)
        case let .ellipse(rect, style):
            return .ellipse(resizedRect(rect, handle: handle, to: point), style)
        case let .fillRect(rect, style):
            return .fillRect(resizedRect(rect, handle: handle, to: point), style)
        case let .spotlight(rect, style):
            return .spotlight(resizedRect(rect, handle: handle, to: point), style)
        case let .blur(rect):
            return .blur(resizedRect(rect, handle: handle, to: point))
        case let .pixelate(rect):
            return .pixelate(resizedRect(rect, handle: handle, to: point))
        case let .line(from, to, style):
            return .line(
                from: handle == .lineStart ? point : from,
                to: handle == .lineEnd ? point : to,
                style
            )
        case let .arrow(from, to, style):
            return .arrow(
                from: handle == .lineStart ? point : from,
                to: handle == .lineEnd ? point : to,
                style
            )
        case let .loupe(source, sourceRadius, lens, lensRadius, style):
            return resizedLoupe(
                source: source, sourceRadius: sourceRadius,
                lens: lens, lensRadius: lensRadius, style: style,
                handle: handle, to: point
            )
        case let .measure(from, to, style):
            // The snap is re-applied against whichever end is standing still, so
            // an axis-aligned measurement stays axis-aligned after an edit.
            if handle == .lineStart {
                return .measure(from: MeasureGeometry.snapped(point, anchoredAt: to), to: to, style)
            }
            return .measure(from: from, to: MeasureGeometry.snapped(point, anchoredAt: from), style)
        case let .text(box, content, style):
            // Only the width is the user's to choose; the height follows the
            // wrapped content, so a resize re-wraps rather than clipping.
            let resized = resizedRect(box, handle: handle, to: point)
            return .text(
                box: TextLayout.fittedBox(resized, content: content, style: style),
                content: content,
                style
            )
        case let .callout(anchor, box, content, style):
            if handle == .lineStart {
                return .callout(anchor: point, box: box, content: content, style)
            }
            // Bubble handle sits at the bubble's center — keep it there.
            let rect = CalloutGeometry.bubbleRect(box: box, content: content, style: style)
            return .callout(
                anchor: anchor,
                box: box.offsetBy(dx: point.x - rect.midX, dy: point.y - rect.midY),
                content: content,
                style
            )
        default:
            return annotation
        }
    }

    /// Each circle answers to its own two handles. Growing the source pulls in
    /// more context and takes the lens with it, so the magnification the user
    /// chose survives; growing the lens is how the magnification is changed by
    /// hand.
    private static func resizedLoupe(
        source: CGPoint, sourceRadius: CGFloat,
        lens: CGPoint, lensRadius: CGFloat, style: LoupeStyle,
        handle: ResizeHandle, to point: CGPoint
    ) -> Annotation {
        func radius(from center: CGPoint) -> CGFloat {
            max(LoupeGeometry.minimumRadius, hypot(point.x - center.x, point.y - center.y))
        }
        switch handle {
        case .loupeSource:
            return .loupe(
                source: point, sourceRadius: sourceRadius,
                lens: lens, lensRadius: lensRadius, style
            )
        case .loupeLens:
            return .loupe(
                source: source, sourceRadius: sourceRadius,
                lens: point, lensRadius: lensRadius, style
            )
        case .loupeSourceRadius:
            let grown = radius(from: source)
            let magnification = LoupeGeometry.magnification(
                sourceRadius: sourceRadius, lensRadius: lensRadius
            )
            return .loupe(
                source: source, sourceRadius: grown,
                lens: lens,
                lensRadius: LoupeGeometry.lensRadius(
                    sourceRadius: grown, magnification: magnification
                ),
                style
            )
        case .loupeLensRadius:
            return .loupe(
                source: source, sourceRadius: sourceRadius,
                lens: lens, lensRadius: radius(from: lens), style
            )
        default:
            return .loupe(
                source: source, sourceRadius: sourceRadius,
                lens: lens, lensRadius: lensRadius, style
            )
        }
    }

    /// Which circle a point is inside, so a drag on a loupe's body moves the one
    /// the user actually grabbed. The lens wins where they overlap: it is what
    /// is drawn on top.
    static func loupeCircle(of annotation: Annotation, at point: CGPoint) -> LoupeCircle? {
        guard case let .loupe(source, sourceRadius, lens, lensRadius, _) = annotation else {
            return nil
        }
        if hypot(point.x - lens.x, point.y - lens.y) <= lensRadius { return .lens }
        if hypot(point.x - source.x, point.y - source.y) <= sourceRadius { return .source }
        return nil
    }

    /// Moves one circle of a loupe and leaves the other where it is. Anything
    /// else comes back untouched.
    static func translate(
        _ annotation: Annotation, circle: LoupeCircle, dx: CGFloat, dy: CGFloat
    ) -> Annotation {
        guard case let .loupe(source, sourceRadius, lens, lensRadius, style) = annotation else {
            return annotation
        }
        return .loupe(
            source: circle == .source ? source.offset(dx, dy) : source,
            sourceRadius: sourceRadius,
            lens: circle == .lens ? lens.offset(dx, dy) : lens,
            lensRadius: lensRadius,
            style
        )
    }

    /// Dragging a handle past the opposite edge flips the rect rather than
    /// producing a negative size.
    static func resizedRect(_ rect: CGRect, handle: ResizeHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch handle {
        case .topLeft:    minX = point.x; minY = point.y
        case .top:                        minY = point.y
        case .topRight:   maxX = point.x; minY = point.y
        case .left:       minX = point.x
        case .right:      maxX = point.x
        case .bottomLeft: minX = point.x; maxY = point.y
        case .bottom:                     maxY = point.y
        case .bottomRight: maxX = point.x; maxY = point.y
        case .lineStart, .lineEnd,
             .loupeSource, .loupeLens, .loupeSourceRadius, .loupeLensRadius:
            break
        }
        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }

    static func translate(_ annotation: Annotation, dx: CGFloat, dy: CGFloat) -> Annotation {
        switch annotation {
        case let .rectangle(rect, style):
            return .rectangle(rect.offsetBy(dx: dx, dy: dy), style)
        case let .ellipse(rect, style):
            return .ellipse(rect.offsetBy(dx: dx, dy: dy), style)
        case let .line(from, to, style):
            return .line(from: from.offset(dx, dy), to: to.offset(dx, dy), style)
        case let .arrow(from, to, style):
            return .arrow(from: from.offset(dx, dy), to: to.offset(dx, dy), style)
        case let .measure(from, to, style):
            return .measure(from: from.offset(dx, dy), to: to.offset(dx, dy), style)
        case let .freehand(points, style):
            return .freehand(points: points.map { $0.offset(dx, dy) }, style)
        case let .highlighter(points, style):
            return .highlighter(points: points.map { $0.offset(dx, dy) }, style)
        case let .text(box, content, style):
            return .text(box: box.offsetBy(dx: dx, dy: dy), content: content, style)
        case let .callout(anchor, box, content, style):
            return .callout(
                anchor: anchor.offset(dx, dy),
                box: box.offsetBy(dx: dx, dy: dy),
                content: content,
                style
            )
        case let .stepMarker(center, number, style):
            return .stepMarker(center: center.offset(dx, dy), number: number, style)
        case let .loupe(source, sourceRadius, lens, lensRadius, style):
            return .loupe(
                source: source.offset(dx, dy), sourceRadius: sourceRadius,
                lens: lens.offset(dx, dy), lensRadius: lensRadius, style
            )
        case let .fillRect(rect, style):
            return .fillRect(rect.offsetBy(dx: dx, dy: dy), style)
        case let .spotlight(rect, style):
            return .spotlight(rect.offsetBy(dx: dx, dy: dy), style)
        case let .fillFreehand(points, style):
            return .fillFreehand(points: points.map { $0.offset(dx, dy) }, style)
        case let .blur(rect):
            return .blur(rect.offsetBy(dx: dx, dy: dy))
        case let .pixelate(rect):
            return .pixelate(rect.offsetBy(dx: dx, dy: dy))
        }
    }

    // MARK: Math

    static func distance(from point: CGPoint, toSegment seg: (CGPoint, CGPoint)) -> CGFloat {
        let dx = seg.1.x - seg.0.x
        let dy = seg.1.y - seg.0.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 { return hypot(point.x - seg.0.x, point.y - seg.0.y) }
        let t = max(0, min(1, ((point.x - seg.0.x) * dx + (point.y - seg.0.y) * dy) / lengthSquared))
        let projX = seg.0.x + t * dx
        let projY = seg.0.y + t * dy
        return hypot(point.x - projX, point.y - projY)
    }
}
