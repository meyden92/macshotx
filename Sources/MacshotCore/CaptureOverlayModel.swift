import CoreGraphics

/// How a capture overlay commit was produced. The route — never the hotkey
/// that opened the overlay — determines the capture mode recorded on the
/// artifact, so per-mode pipeline overrides follow what the user did.
enum OverlayCommitRoute: Equatable, Sendable {
    /// A dragged (or anchored) selection rectangle.
    case dragSelection
    /// A click on a snap-highlighted window.
    case windowSnap
    /// A click with no drag while snap is off: that whole display.
    case displayClick
    /// `F` on an idle overlay: the display under the cursor.
    case fullscreenKey

    var captureMode: CaptureMode {
        switch self {
        case .dragSelection: return .region
        case .windowSnap: return .window
        case .displayClick, .fullscreenKey: return .fullscreen
        }
    }
}

/// What a commit route needs at bake time. Carried through the model so a
/// commit held for a pending image keeps its payload in one place.
enum OverlayCommitPayload: Equatable {
    /// The selection rectangle, in the owning display's view points.
    case drag(CGRect)
    /// The snapped window.
    case window(WindowCandidate)
    /// The owning display's whole surface (click with snap off, or `F`).
    case wholeDisplay
}

/// Cross-display state of one capture overlay session, expressed as a value
/// with transition functions so the rules can be exercised without presenting
/// a window. Displays are identified by index. The session resolves exactly
/// once: transitions after resolution are no-ops.
struct CaptureSessionModel: Equatable {
    enum Resolution: Equatable {
        case pending
        case committed
        case cancelled
    }

    struct HeldCommit: Equatable {
        var display: Int
        var route: OverlayCommitRoute
        var payload: OverlayCommitPayload
    }

    private(set) var snapArmed: Bool
    private(set) var imageReady: [Bool]
    /// Display currently owning selection activity; exactly one at a time.
    private(set) var selectionOwner: Int?
    /// A commit issued before its display's frozen image arrived, waiting.
    private(set) var heldCommit: HeldCommit?
    private(set) var resolution: Resolution = .pending

    init(displayCount: Int, snapArmed: Bool) {
        self.snapArmed = snapArmed
        self.imageReady = Array(repeating: false, count: displayCount)
    }

    /// Selection activity began on a display. Returns the displays whose
    /// selection must be cleared so exactly one display owns the capture.
    mutating func startSelection(on display: Int) -> [Int] {
        guard resolution == .pending else { return [] }
        defer { selectionOwner = display }
        guard let owner = selectionOwner, owner != display else { return [] }
        return [owner]
    }

    /// A display's selection ended empty.
    mutating func clearSelection(on display: Int) {
        guard resolution == .pending else { return }
        if selectionOwner == display { selectionOwner = nil }
    }

    /// Tab. Only accepted while no selection exists. Returns true when the
    /// snap state changed.
    mutating func toggleSnap() -> Bool {
        guard resolution == .pending, selectionOwner == nil else { return false }
        snapArmed.toggle()
        return true
    }

    enum CommitDisposition: Equatable {
        /// The display's image is ready — bake and resolve now.
        case perform
        /// The image is still in flight — the commit waits for it.
        case held
        case ignored
    }

    mutating func requestCommit(
        on display: Int, route: OverlayCommitRoute, payload: OverlayCommitPayload
    ) -> CommitDisposition {
        guard resolution == .pending, heldCommit == nil,
              imageReady.indices.contains(display)
        else { return .ignored }
        if imageReady[display] {
            resolution = .committed
            return .perform
        }
        heldCommit = HeldCommit(display: display, route: route, payload: payload)
        return .held
    }

    /// A display's frozen image landed. Returns a commit that was waiting on
    /// it and must be performed now.
    mutating func imageArrived(on display: Int) -> HeldCommit? {
        guard resolution == .pending, imageReady.indices.contains(display) else { return nil }
        imageReady[display] = true
        guard let held = heldCommit, held.display == display else { return nil }
        heldCommit = nil
        resolution = .committed
        return held
    }

    /// Cancel is never held. A screenshot failure routes here too: the whole
    /// session cancels. Returns true when this call resolved the session.
    @discardableResult
    mutating func cancel() -> Bool {
        guard resolution == .pending else { return false }
        resolution = .cancelled
        return true
    }
}

/// Content of the idle helper card, produced purely from the snap state and
/// the suppression setting so it can be asserted without presenting a window.
enum HelperCard {
    struct Content: Equatable {
        let instruction: String
        let status: String
    }

    static func content(snapArmed: Bool, suppressed: Bool) -> Content? {
        guard !suppressed else { return nil }
        if snapArmed {
            return Content(
                instruction: "Click a window to capture it · drag an area · F for fullscreen",
                status: "Window snap: ON (Tab)"
            )
        }
        return Content(
            instruction: "Drag an area to capture it · F for fullscreen",
            status: "Window snap: OFF (Tab)"
        )
    }
}
