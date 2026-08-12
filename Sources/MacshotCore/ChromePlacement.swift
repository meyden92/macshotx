import CoreGraphics

/// Pure placement solver for the capture overlay's chrome: the tool strip
/// (which carries the style strip), the Resolution box, and the selecting-state
/// hint. Coordinates are flipped view points (top-left origin). Deterministic:
/// identical inputs always produce identical placements.
enum ChromePlacement {
    static let gap: CGFloat = 8
    static let margin: CGFloat = 8

    struct Boxes {
        var toolStrip: CGSize?
        var resolutionBox: CGSize?
        var hint: CGSize?

        init(toolStrip: CGSize? = nil, resolutionBox: CGSize? = nil, hint: CGSize? = nil) {
            self.toolStrip = toolStrip
            self.resolutionBox = resolutionBox
            self.hint = hint
        }
    }

    struct Placements: Equatable {
        var toolStrip: CGRect?
        var resolutionBox: CGRect?
        var hint: CGRect?
    }

    /// Places every chrome box: the tool strip (hint stacked next to it)
    /// prefers sitting just below the Selection and flips above when there is
    /// no room; the Resolution box rides beside the Selection, moving to the
    /// opposite side when its preferred side is full. No box intersects
    /// another, the safe-area inset, or the display margin.
    static func solve(
        bounds: CGRect,
        safeAreaTop: CGFloat,
        selection: CGRect,
        boxes: Boxes
    ) -> Placements {
        let minY = bounds.minY + max(margin, safeAreaTop)
        let maxY = bounds.maxY - margin
        var result = Placements()

        // Tool strip and hint stack below the Selection (strip closest), or
        // above it when the stack would spill off the bottom.
        let stack = [boxes.toolStrip, boxes.hint].compactMap { $0 }
        let stackHeight = stack.reduce(0) { $0 + $1.height } + CGFloat(max(0, stack.count - 1)) * gap
        let fitsBelow = selection.maxY + gap + stackHeight <= maxY
        var y = fitsBelow
            ? selection.maxY + gap
            : selection.minY - gap - stackHeight
        y = min(max(y, minY), maxY - stackHeight)

        func place(_ size: CGSize) -> CGRect {
            let x = min(
                max(selection.midX - size.width / 2, bounds.minX + margin),
                bounds.maxX - margin - size.width
            )
            let rect = CGRect(origin: CGPoint(x: x, y: y), size: size)
            y = rect.maxY + gap
            return rect
        }
        if let size = boxes.toolStrip { result.toolStrip = place(size) }
        if let size = boxes.hint { result.hint = place(size) }

        // Resolution box: beside the Selection, top-aligned; opposite side,
        // then vertical nudging, when its preferred spot is taken.
        if let size = boxes.resolutionBox {
            let others = [result.toolStrip, result.hint].compactMap { $0 }
            let right = CGPoint(x: selection.maxX + gap, y: selection.minY)
            let left = CGPoint(x: selection.minX - gap - size.width, y: selection.minY)
            let candidates = [
                right, left,
                CGPoint(x: right.x, y: selection.maxY - size.height),
                CGPoint(x: left.x, y: selection.maxY - size.height)
            ]
            let clamp = { (origin: CGPoint) -> CGRect in
                CGRect(
                    origin: CGPoint(
                        x: min(max(origin.x, bounds.minX + margin), bounds.maxX - margin - size.width),
                        y: min(max(origin.y, minY), maxY - size.height)
                    ),
                    size: size
                )
            }
            let obstacles = others + [selection]
            let unclamped = candidates.first { origin in
                let rect = CGRect(origin: origin, size: size)
                return rect == clamp(origin) && !obstacles.contains { $0.intersects(rect) }
            }
            var rect = clamp(unclamped ?? right)
            // Last resort: walk down past whatever it clipped into.
            while others.contains(where: { $0.intersects(rect) }), rect.maxY < maxY {
                let blocker = others.first { $0.intersects(rect) }!
                rect.origin.y = min(blocker.maxY + gap, maxY - size.height)
                if rect.origin.y == maxY - size.height { break }
            }
            result.resolutionBox = rect
        }
        return result
    }
}
