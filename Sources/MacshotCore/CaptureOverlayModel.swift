import CoreGraphics

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

    /// A confirmed Selection waiting for its display's frozen image. Confirming
    /// a Selection is the only way to commit, so a rectangle is the whole of it
    /// (ADR 0011).
    struct HeldCommit: Equatable {
        var display: Int
        /// The Selection, in the owning display's view points.
        var rect: CGRect
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

    mutating func requestCommit(on display: Int, rect: CGRect) -> CommitDisposition {
        guard resolution == .pending, heldCommit == nil,
              imageReady.indices.contains(display)
        else { return .ignored }
        if imageReady[display] {
            resolution = .committed
            return .perform
        }
        heldCommit = HeldCommit(display: display, rect: rect)
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

    /// Every route seeds the Selection, so the card says "select", never
    /// "capture": nothing here takes a screenshot on its own (ADR 0011).
    static func content(snapArmed: Bool, suppressed: Bool) -> Content? {
        guard !suppressed else { return nil }
        if snapArmed {
            return Content(
                instruction: "Click a window to select it · drag an area · F for fullscreen",
                status: "Window snap: ON (Tab)"
            )
        }
        return Content(
            instruction: "Drag to select · F for fullscreen · Tab for window selection",
            status: "Window snap: OFF (Tab)"
        )
    }
}
