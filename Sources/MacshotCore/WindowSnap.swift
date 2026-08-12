import CoreGraphics

/// A snap candidate: one on-screen window as a plain value, free of
/// ScreenCaptureKit types. Frames are in global Quartz coordinates (top-left
/// origin at the primary display's top-left, y increasing downward), points.
/// Candidate lists are ordered front-to-back.
struct WindowCandidate: Equatable, Sendable {
    var id: UInt32
    var frame: CGRect
    var bundleIdentifier: String?
    var applicationName: String?
    var title: String?
    /// CGWindow layer; 0 is the normal window layer.
    var layer: Int
    var isOnScreen: Bool
}

/// Picks the window that should snap-highlight for a point.
enum WindowSnapResolver {
    /// Eligibility and occlusion, applied once per capture: drop windows that
    /// are off-screen, zero-area, owned by `ownBundleID`, or not in the
    /// normal window layer (which covers desktop elements); drop windows
    /// fully contained in the frame of any window ahead of them in z-order.
    /// Order is preserved, front-to-back.
    static func eligible(
        _ candidates: [WindowCandidate],
        ownBundleID: String?
    ) -> [WindowCandidate] {
        var kept: [WindowCandidate] = []
        outer: for candidate in candidates {
            guard candidate.isOnScreen,
                  candidate.frame.width >= 1,
                  candidate.frame.height >= 1,
                  candidate.layer == 0
            else { continue }
            if let own = ownBundleID, candidate.bundleIdentifier == own { continue }
            for front in kept where front.frame.contains(candidate.frame) { continue outer }
            kept.append(candidate)
        }
        return kept
    }

    /// The first eligible window in z-order whose frame contains the point
    /// wins. The list is front-to-back, so "first" means "topmost"; exactly
    /// overlapping frames resolve to the front one.
    static func resolve(
        _ candidates: [WindowCandidate],
        at point: CGPoint,
        ownBundleID: String?
    ) -> WindowCandidate? {
        eligible(candidates, ownBundleID: ownBundleID)
            .first { $0.frame.contains(point) }
    }
}

/// Pure crop arithmetic for the flat window-snap capture: converts a window
/// frame in global Quartz coordinates into a crop rectangle in the owning
/// display's overlay view space (flipped, top-left origin, points).
enum WindowCropGeometry {
    /// - Parameters:
    ///   - windowFrame: the snapped window's frame, global Quartz coordinates.
    ///   - shadowedBounds: the window's shadowed bounds as they appear on
    ///     screen, same space, or nil when they could not be determined.
    ///   - includeShadow: the "include window shadow" capture setting; only
    ///     when on does the crop expand to the shadowed bounds.
    ///   - displayQuartzFrame: the owning display's frame, same space.
    /// - Returns: the crop rectangle in the display's view space, clamped to
    ///   the display, or nil when the window lies outside it.
    static func flatCropRect(
        windowFrame: CGRect,
        shadowedBounds: CGRect?,
        includeShadow: Bool,
        displayQuartzFrame: CGRect
    ) -> CGRect? {
        var target = windowFrame
        // The shadowed bounds must enclose the frame; anything else means the
        // probe produced nonsense, and the crop falls back to the frame.
        if includeShadow, let shadowed = shadowedBounds, shadowed.contains(windowFrame) {
            target = shadowed
        }
        let local = target.offsetBy(
            dx: -displayQuartzFrame.minX,
            dy: -displayQuartzFrame.minY
        )
        let clamped = local.intersection(
            CGRect(origin: .zero, size: displayQuartzFrame.size)
        )
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }

    /// Shadowed bounds from a with-shadow and a shadow-free capture of the
    /// same window at identical size: the difference between their opaque
    /// bounding boxes (raster pixels, row 0 = top), scaled to points against
    /// the window frame, expands the frame per edge. Nil when the margins are
    /// zero or don't make sense — the crop then falls back to the frame.
    static func shadowedBounds(
        windowBox: CGRect,
        shadowBox: CGRect,
        frame: CGRect
    ) -> CGRect? {
        guard windowBox.width > 0, frame.width > 0 else { return nil }
        let pxPerPoint = windowBox.width / frame.width
        guard pxPerPoint > 0 else { return nil }
        let left = (windowBox.minX - shadowBox.minX) / pxPerPoint
        let top = (windowBox.minY - shadowBox.minY) / pxPerPoint
        let right = (shadowBox.maxX - windowBox.maxX) / pxPerPoint
        let bottom = (shadowBox.maxY - windowBox.maxY) / pxPerPoint
        guard left >= 0, top >= 0, right >= 0, bottom >= 0,
              left + top + right + bottom > 0
        else { return nil }
        return CGRect(
            x: frame.minX - left,
            y: frame.minY - top,
            width: frame.width + left + right,
            height: frame.height + top + bottom
        )
    }

    /// Bounding box of pixels with non-negligible alpha in raster coordinates
    /// (row 0 = top scanline), or nil for a fully transparent image.
    static func opaqueBoundingBox(of snapshot: PixelSnapshot) -> CGRect? {
        let width = snapshot.width
        let height = snapshot.height
        var minX = width, minY = height, maxX = -1, maxY = -1
        snapshot.rgba.withUnsafeBufferPointer { rgba in
            for y in 0..<height {
                let row = y * width * 4
                var first = -1
                for x in 0..<width where rgba[row + 4 * x + 3] > 8 {
                    first = x
                    break
                }
                guard first >= 0 else { continue }
                var last = first
                for x in stride(from: width - 1, through: first, by: -1)
                where rgba[row + 4 * x + 3] > 8 {
                    last = x
                    break
                }
                if first < minX { minX = first }
                if last > maxX { maxX = last }
                if y < minY { minY = y }
                maxY = y
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
        )
    }
}
