import CoreGraphics

/// A snap candidate: one on-screen window as a plain value, free of
/// ScreenCaptureKit types. Frames are in global Quartz coordinates (top-left
/// origin at the primary display's top-left, y increasing downward), points.
/// Candidate lists are ordered front-to-back.
struct WindowCandidate: Equatable, Sendable {
    var id: UInt32
    var frame: CGRect
    var bundleIdentifier: String?
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

    /// Hit-tests a pointer on one display against an already-eligible list.
    /// `localPoint` is in that display's overlay view space (top-left origin,
    /// points) and `displayFrame` is the display's global Quartz frame, so the
    /// mapping never depends on the overlay window's position or on which
    /// display is primary. The winning frame comes back in the same view
    /// space, ready to draw.
    static func target(
        in eligible: [WindowCandidate],
        displayFrame: CGRect,
        localPoint: CGPoint
    ) -> (candidate: WindowCandidate, rect: CGRect)? {
        let quartzPoint = CGPoint(
            x: displayFrame.minX + localPoint.x, y: displayFrame.minY + localPoint.y
        )
        guard let candidate = eligible.first(where: { $0.frame.contains(quartzPoint) })
        else { return nil }
        let local = candidate.frame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        return (candidate, local)
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
