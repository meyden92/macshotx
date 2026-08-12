import CoreGraphics

/// Which Selection edges a gesture is actually driving. Boundary snap, aspect
/// locks and Shift-square all key off this: only driven edges may move.
struct DrivenEdges: OptionSet, Sendable {
    let rawValue: Int
    static let left = DrivenEdges(rawValue: 1 << 0)
    static let right = DrivenEdges(rawValue: 1 << 1)
    static let top = DrivenEdges(rawValue: 1 << 2)
    static let bottom = DrivenEdges(rawValue: 1 << 3)
    static let all: DrivenEdges = [.left, .right, .top, .bottom]
}

/// Per-edge snap positions (view points) with hysteresis: an edge stays
/// snapped until it clearly pulls away. Lives on the gesture value.
struct EdgeSnapState: Equatable {
    var left: CGFloat?
    var right: CGFloat?
    var top: CGFloat?
    var bottom: CGFloat?

    static let none = EdgeSnapState()
}

/// The one in-flight Selection gesture: its kind, its fixed anchor, and the
/// active constraints. Every mouse or modifier event produces a new gesture
/// value; `SelectionGeometry` turns the value plus a cursor point into a
/// rectangle. Coordinates are flipped view points (top-left origin).
struct SelectionGesture {
    enum Kind {
        case drawing(origin: CGPoint)
        case moving(original: CGRect, grab: CGPoint)
        case resizing(handle: ResizeHandle, original: CGRect)
        /// Hands-free tracking: the pinned corner, opposite corner follows.
        case anchored(anchor: CGPoint)
        /// An armed exact size: a fixed-size frame following the cursor.
        case placingFixedSize(CGSize)
    }

    var kind: Kind
    /// Transient 1:1 constraint; beats `lockedRatio`.
    var shiftHeld = false
    /// Bypasses boundary snap while held.
    var optionHeld = false
    /// Armed aspect lock as width/height, nil for freeform.
    var lockedRatio: CGFloat?
    /// Last evaluated cursor point, kept so a modifier change can re-evaluate
    /// the rectangle without cursor movement.
    fileprivate(set) var lastPoint: CGPoint
    /// Cursor position when Space went down; non-nil while Space is held.
    private(set) var spaceOrigin: CGPoint?
    /// Which edges are currently snapped to a colour edge, and where.
    var snapState = EdgeSnapState.none

    init(kind: Kind, at point: CGPoint) {
        self.kind = kind
        self.lastPoint = point
    }

    var activeRatio: CGFloat? { shiftHeld ? 1 : lockedRatio }

    var drivenEdges: DrivenEdges {
        switch kind {
        case let .drawing(origin), let .anchored(anchor: origin):
            var edges: DrivenEdges = []
            edges.insert(lastPoint.x < origin.x ? .left : .right)
            edges.insert(lastPoint.y < origin.y ? .top : .bottom)
            return edges
        case .moving, .placingFixedSize:
            // All four edges move, but only by translation.
            return .all
        case let .resizing(handle, original):
            // The cursor can cross the fixed anchor mid-drag, flipping which
            // edge is actually moving — driven edges follow the cursor, not
            // the handle's original name.
            var edges: DrivenEdges = []
            switch handle {
            case .topLeft, .left, .bottomLeft:
                edges.insert(lastPoint.x < original.maxX ? .left : .right)
            case .topRight, .right, .bottomRight:
                edges.insert(lastPoint.x < original.minX ? .left : .right)
            case .top, .bottom, .lineStart, .lineEnd,
                 .loupeSource, .loupeLens, .loupeSourceRadius, .loupeLensRadius:
                break
            }
            switch handle {
            case .topLeft, .top, .topRight:
                edges.insert(lastPoint.y < original.maxY ? .top : .bottom)
            case .bottomLeft, .bottom, .bottomRight:
                edges.insert(lastPoint.y < original.minY ? .top : .bottom)
            case .left, .right, .lineStart, .lineEnd,
                 .loupeSource, .loupeLens, .loupeSourceRadius, .loupeLensRadius:
                break
            }
            return edges
        }
    }

    /// Space freezes the rectangle's size and slides it with the cursor.
    mutating func pressSpace() {
        guard spaceOrigin == nil else { return }
        spaceOrigin = lastPoint
    }

    /// Releasing Space carries the gesture's anchor along by the accumulated
    /// cursor delta, which is what makes the resume jump-free: the resumed
    /// evaluation is the frozen base plus the same delta, run through the
    /// same containment clamp, so it reproduces the displayed rectangle even
    /// when the slide was stopped by the display edge.
    mutating func releaseSpace() {
        guard let origin = spaceOrigin else { return }
        let dx = lastPoint.x - origin.x
        let dy = lastPoint.y - origin.y
        switch kind {
        case let .drawing(o):
            kind = .drawing(origin: CGPoint(x: o.x + dx, y: o.y + dy))
        case let .moving(original, grab):
            kind = .moving(
                original: original.offsetBy(dx: dx, dy: dy),
                grab: CGPoint(x: grab.x + dx, y: grab.y + dy)
            )
        case let .resizing(handle, original):
            kind = .resizing(handle: handle, original: original.offsetBy(dx: dx, dy: dy))
        case let .anchored(anchor):
            kind = .anchored(anchor: CGPoint(x: anchor.x + dx, y: anchor.y + dy))
        case .placingFixedSize:
            break
        }
        spaceOrigin = nil
    }
}

/// All Selection rectangle math: pure functions from values to values. The
/// overlay does no Selection arithmetic of its own.
enum SelectionGeometry {
    /// A Selection can never be smaller than this, in points.
    static let minimumSelectionSize: CGFloat = 8
    /// Snap attraction radius in points; a snapped edge releases at 1.5×.
    static let snapRadius: CGFloat = 8
    static let snapReleaseRadius: CGFloat = 12

    /// The rectangle a gesture produces for a cursor point, with boundary snap
    /// applied to the driven edges and the minimum size and display
    /// containment invariants applied — as ratio-preserving scales while a
    /// ratio constraint is active.
    static func rectangle(
        for gesture: inout SelectionGesture,
        at point: CGPoint,
        in bounds: CGRect,
        snapping index: EdgeIndex? = nil,
        pixelScale: CGFloat = 1
    ) -> CGRect {
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        gesture.lastPoint = clamped

        if let spaceOrigin = gesture.spaceOrigin {
            var frozen = resolved(gesture.kind, at: spaceOrigin, ratio: gesture.activeRatio, in: bounds)
            // The frozen rectangle keeps any edges that were snapped when
            // Space went down — pressing Space must not move the Selection.
            if index != nil, !gesture.optionHeld, gesture.activeRatio == nil {
                frozen = applying(gesture.snapState, to: frozen)
            } else {
                gesture.snapState = .none
            }
            let slid = frozen.offsetBy(
                dx: clamped.x - spaceOrigin.x,
                dy: clamped.y - spaceOrigin.y
            )
            return translated(slid, into: bounds)
        }

        let base = resolved(gesture.kind, at: clamped, ratio: gesture.activeRatio, in: bounds)
        let translationOnly: Bool
        switch gesture.kind {
        case .moving, .placingFixedSize: translationOnly = true
        case .drawing, .anchored, .resizing: translationOnly = false
        }

        // Snapping stands down for Option and for any exact ratio constraint.
        guard let index, !index.isEmpty, !gesture.optionHeld, gesture.activeRatio == nil else {
            gesture.snapState = .none
            return base
        }
        return translationOnly
            ? snappedTranslating(base, gesture: &gesture, index: index, scale: pixelScale, in: bounds)
            : snappedEdges(base, gesture: &gesture, index: index, scale: pixelScale)
    }

    // MARK: Boundary snap

    /// Per-driven-edge snap for drawing and handle resizes: each driven edge
    /// attracts independently; undriven edges never move.
    private static func snappedEdges(
        _ rect: CGRect,
        gesture: inout SelectionGesture,
        index: EdgeIndex,
        scale: CGFloat
    ) -> CGRect {
        let edges = gesture.drivenEdges
        let ySpan = (rect.minY * scale)...(rect.maxY * scale)
        let xSpan = (rect.minX * scale)...(rect.maxX * scale)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

        func columnTarget(_ position: CGFloat) -> CGFloat? {
            index.column(near: position * scale, spanning: ySpan, radius: snapRadius * scale)
                .map { CGFloat($0) / scale }
        }
        func rowTarget(_ position: CGFloat) -> CGFloat? {
            index.row(near: position * scale, spanning: xSpan, radius: snapRadius * scale)
                .map { CGFloat($0) / scale }
        }

        if edges.contains(.left) {
            minX = resolveEdge(current: rect.minX, state: &gesture.snapState.left, query: columnTarget)
        } else { gesture.snapState.left = nil }
        if edges.contains(.right) {
            maxX = resolveEdge(current: rect.maxX, state: &gesture.snapState.right, query: columnTarget)
        } else { gesture.snapState.right = nil }
        if edges.contains(.top) {
            minY = resolveEdge(current: rect.minY, state: &gesture.snapState.top, query: rowTarget)
        } else { gesture.snapState.top = nil }
        if edges.contains(.bottom) {
            maxY = resolveEdge(current: rect.maxY, state: &gesture.snapState.bottom, query: rowTarget)
        } else { gesture.snapState.bottom = nil }

        // A snap may never squeeze the Selection under its minimum.
        if maxX - minX < minimumSelectionSize {
            minX = rect.minX; maxX = rect.maxX
            gesture.snapState.left = nil; gesture.snapState.right = nil
        }
        if maxY - minY < minimumSelectionSize {
            minY = rect.minY; maxY = rect.maxY
            gesture.snapState.top = nil; gesture.snapState.bottom = nil
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Snap for whole-rectangle translation: at most one edge per axis wins
    /// and the rectangle translates rigidly — it never deforms.
    private static func snappedTranslating(
        _ rect: CGRect,
        gesture: inout SelectionGesture,
        index: EdgeIndex,
        scale: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        let dx = translationSnapDelta(
            lo: rect.minX, hi: rect.maxX,
            loState: &gesture.snapState.left, hiState: &gesture.snapState.right
        ) { position in
            index.column(
                near: position * scale,
                spanning: (rect.minY * scale)...(rect.maxY * scale),
                radius: snapRadius * scale
            ).map { CGFloat($0) / scale }
        }
        let dy = translationSnapDelta(
            lo: rect.minY, hi: rect.maxY,
            loState: &gesture.snapState.top, hiState: &gesture.snapState.bottom
        ) { position in
            index.row(
                near: position * scale,
                spanning: (rect.minX * scale)...(rect.maxX * scale),
                radius: snapRadius * scale
            ).map { CGFloat($0) / scale }
        }
        let result = translated(rect.offsetBy(dx: dx, dy: dy), into: bounds)
        // Containment may have undone the snap at the display edge; a state
        // claiming a lock the rectangle doesn't have would mislead both the
        // guide lines and the hysteresis.
        if let left = gesture.snapState.left, abs(result.minX - left) > 0.5 {
            gesture.snapState.left = nil
        }
        if let right = gesture.snapState.right, abs(result.maxX - right) > 0.5 {
            gesture.snapState.right = nil
        }
        if let top = gesture.snapState.top, abs(result.minY - top) > 0.5 {
            gesture.snapState.top = nil
        }
        if let bottom = gesture.snapState.bottom, abs(result.maxY - bottom) > 0.5 {
            gesture.snapState.bottom = nil
        }
        return result
    }

    /// One axis of translation snap: hysteresis first, else query both edges
    /// and let the nearer candidate win — at most one edge per axis.
    private static func translationSnapDelta(
        lo: CGFloat,
        hi: CGFloat,
        loState: inout CGFloat?,
        hiState: inout CGFloat?,
        query: (CGFloat) -> CGFloat?
    ) -> CGFloat {
        if let held = loState, abs(lo - held) <= snapReleaseRadius {
            return held - lo
        }
        if let held = hiState, abs(hi - held) <= snapReleaseRadius {
            loState = nil
            return held - hi
        }
        loState = nil
        hiState = nil
        let loTarget = query(lo)
        let hiTarget = query(hi)
        let loDistance = loTarget.map { abs($0 - lo) } ?? .infinity
        let hiDistance = hiTarget.map { abs($0 - hi) } ?? .infinity
        if let loTarget, loDistance <= hiDistance {
            loState = loTarget
            return loTarget - lo
        }
        if let hiTarget {
            hiState = hiTarget
            return hiTarget - hi
        }
        return 0
    }

    /// Re-applies stored snap positions to a rectangle without querying —
    /// used to keep a Space-frozen rectangle exactly where it was displayed.
    private static func applying(_ state: EdgeSnapState, to rect: CGRect) -> CGRect {
        var minX = state.left ?? rect.minX
        var maxX = state.right ?? rect.maxX
        var minY = state.top ?? rect.minY
        var maxY = state.bottom ?? rect.maxY
        if maxX - minX < minimumSelectionSize { minX = rect.minX; maxX = rect.maxX }
        if maxY - minY < minimumSelectionSize { minY = rect.minY; maxY = rect.maxY }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Hysteresis per edge: stay snapped until the unsnapped position clearly
    /// pulls past the release radius, then re-query.
    private static func resolveEdge(
        current: CGFloat,
        state: inout CGFloat?,
        query: (CGFloat) -> CGFloat?
    ) -> CGFloat {
        if let snapped = state {
            if abs(current - snapped) <= snapReleaseRadius { return snapped }
            state = nil
        }
        if let target = query(current) {
            state = target
            return target
        }
        return current
    }

    // MARK: Kind evaluation

    private static func resolved(
        _ kind: SelectionGesture.Kind,
        at point: CGPoint,
        ratio: CGFloat?,
        in bounds: CGRect
    ) -> CGRect {
        switch kind {
        case let .drawing(origin), let .anchored(anchor: origin):
            if let ratio {
                return ratioRect(anchor: origin, toward: point, ratio: ratio, in: bounds)
            }
            let (x, w) = span(from: origin.x, delta: point.x - origin.x)
            let (y, h) = span(from: origin.y, delta: point.y - origin.y)
            return translated(CGRect(x: x, y: y, width: w, height: h), into: bounds)

        case let .moving(original, grab):
            let moved = original.offsetBy(dx: point.x - grab.x, dy: point.y - grab.y)
            return translated(moved, into: bounds)

        case let .resizing(handle, original):
            return resized(original, handle: handle, to: point, ratio: ratio, in: bounds)

        case let .placingFixedSize(size):
            // A frame larger than the display fits uniformly — never a
            // per-axis squash that would distort its aspect.
            var fitted = size
            if size.width > bounds.width || size.height > bounds.height {
                let fit = min(bounds.width / size.width, bounds.height / size.height)
                fitted = CGSize(width: size.width * fit, height: size.height * fit)
            }
            let centered = CGRect(
                x: point.x - fitted.width / 2,
                y: point.y - fitted.height / 2,
                width: fitted.width,
                height: fitted.height
            )
            return translated(centered, into: bounds)
        }
    }

    private static func resized(
        _ original: CGRect,
        handle: ResizeHandle,
        to point: CGPoint,
        ratio: CGFloat?,
        in bounds: CGRect
    ) -> CGRect {
        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let anchor = CGPoint(
                x: (handle == .topLeft || handle == .bottomLeft) ? original.maxX : original.minX,
                y: (handle == .topLeft || handle == .topRight) ? original.maxY : original.minY
            )
            if let ratio {
                return ratioRect(anchor: anchor, toward: point, ratio: ratio, in: bounds)
            }
            let (x, w) = span(from: anchor.x, delta: point.x - anchor.x)
            let (y, h) = span(from: anchor.y, delta: point.y - anchor.y)
            return translated(CGRect(x: x, y: y, width: w, height: h), into: bounds)

        case .left, .right:
            let anchorX = handle == .left ? original.maxX : original.minX
            if let ratio {
                return edgeRatioRect(
                    drivenDelta: point.x - anchorX, drivenAnchor: anchorX,
                    perpendicularCenter: original.midY, ratio: ratio,
                    horizontalDriven: true, in: bounds
                )
            }
            let (x, w) = span(from: anchorX, delta: point.x - anchorX)
            return translated(
                CGRect(x: x, y: original.minY, width: w, height: original.height),
                into: bounds
            )

        case .top, .bottom:
            let anchorY = handle == .top ? original.maxY : original.minY
            if let ratio {
                return edgeRatioRect(
                    drivenDelta: point.y - anchorY, drivenAnchor: anchorY,
                    perpendicularCenter: original.midX, ratio: ratio,
                    horizontalDriven: false, in: bounds
                )
            }
            let (y, h) = span(from: anchorY, delta: point.y - anchorY)
            return translated(
                CGRect(x: original.minX, y: y, width: original.width, height: h),
                into: bounds
            )

        case .lineStart, .lineEnd,
             .loupeSource, .loupeLens, .loupeSourceRadius, .loupeLensRadius:
            return original
        }
    }

    // MARK: Ratio-preserving construction

    /// Rectangle of the given ratio extending from a fixed anchor corner
    /// toward the cursor: the constrained size comes from the larger cursor
    /// delta, the drag direction is preserved per axis, and both the minimum
    /// size and the display fit are applied as scales of the whole rectangle.
    private static func ratioRect(
        anchor: CGPoint,
        toward point: CGPoint,
        ratio: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        var width = max(abs(dx), abs(dy) * ratio)
        width = max(width, minimumSelectionSize, minimumSelectionSize * ratio)
        let availableW = dx < 0 ? anchor.x - bounds.minX : bounds.maxX - anchor.x
        let availableH = dy < 0 ? anchor.y - bounds.minY : bounds.maxY - anchor.y
        // The fit clamp wins over the minimum: near the display edge the
        // rectangle may fall under 8pt, but it must never leave the display —
        // so the spans get no minimum of their own re-applied.
        width = max(0, min(width, availableW, availableH * ratio))
        let (x, w) = span(from: anchor.x, delta: dx < 0 ? -width : width, minimum: 0)
        let (y, h) = span(from: anchor.y, delta: (dy < 0 ? -1 : 1) * width / ratio, minimum: 0)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Ratio-preserving edge-handle resize: the driven dimension follows the
    /// cursor, the other is derived, the opposite edge stays fixed and the
    /// rectangle stays centred on the perpendicular axis.
    private static func edgeRatioRect(
        drivenDelta: CGFloat,
        drivenAnchor: CGFloat,
        perpendicularCenter: CGFloat,
        ratio: CGFloat,
        horizontalDriven: Bool,
        in bounds: CGRect
    ) -> CGRect {
        // Work in width terms regardless of which axis is driven.
        var width = horizontalDriven ? abs(drivenDelta) : abs(drivenDelta) * ratio
        width = max(width, minimumSelectionSize, minimumSelectionSize * ratio)

        let drivenAvailable = drivenDelta < 0
            ? drivenAnchor - (horizontalDriven ? bounds.minX : bounds.minY)
            : (horizontalDriven ? bounds.maxX : bounds.maxY) - drivenAnchor
        let perpendicularAvailable = 2 * min(
            perpendicularCenter - (horizontalDriven ? bounds.minY : bounds.minX),
            (horizontalDriven ? bounds.maxY : bounds.maxX) - perpendicularCenter
        )
        if horizontalDriven {
            width = max(0, min(width, drivenAvailable, perpendicularAvailable * ratio))
        } else {
            width = max(0, min(width, drivenAvailable * ratio, perpendicularAvailable))
        }
        let height = width / ratio

        if horizontalDriven {
            let (x, w) = span(from: drivenAnchor, delta: drivenDelta < 0 ? -width : width, minimum: 0)
            return CGRect(x: x, y: perpendicularCenter - height / 2, width: w, height: height)
        }
        let (y, h) = span(from: drivenAnchor, delta: drivenDelta < 0 ? -height : height, minimum: 0)
        return CGRect(x: perpendicularCenter - width / 2, y: y, width: width, height: h)
    }

    // MARK: Typed resize

    /// Resize about the rectangle's own centre — a typed size never moves the
    /// frame. Clamps: never below the minimum, translated minimally back
    /// inside the display, and scaled down only when the requested size
    /// genuinely cannot fit (ratio-preserving when a ratio is active).
    static func resizedAboutCenter(
        _ rect: CGRect,
        to size: CGSize,
        ratio: CGFloat?,
        in bounds: CGRect
    ) -> CGRect {
        var width = size.width
        var height = size.height
        if let ratio {
            let minScale = max(
                minimumSelectionSize / max(width, 1),
                minimumSelectionSize / max(height, 1),
                1
            )
            width *= minScale
            height *= minScale
            if width > bounds.width || height > bounds.height {
                let fit = min(bounds.width / width, bounds.height / height)
                width *= fit
                height *= fit
            }
        } else {
            width = min(max(width, minimumSelectionSize), bounds.width)
            height = min(max(height, minimumSelectionSize), bounds.height)
        }
        let centered = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
        return translated(centered, into: bounds)
    }

    // MARK: Primitives

    /// One axis of a rectangle extending from a fixed anchor by a signed
    /// delta, at least the minimum long. Zero delta counts as positive.
    private static func span(
        from anchor: CGFloat,
        delta: CGFloat,
        minimum: CGFloat = SelectionGeometry.minimumSelectionSize
    ) -> (origin: CGFloat, length: CGFloat) {
        let length = max(abs(delta), minimum)
        return (delta < 0 ? anchor - length : anchor, length)
    }

    /// Rigid containment: translate into bounds, shrinking only when the
    /// rectangle genuinely cannot fit.
    static func translated(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }
}
