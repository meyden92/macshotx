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

    /// A capture waiting for its display's frozen image: a confirmed
    /// Selection, or the window or display a click captured (ADR 0014). Every
    /// route comes down to a rectangle, so a rectangle is the whole of it.
    struct HeldCommit: Equatable {
        var display: Int
        /// The captured rectangle, in the owning display's view points.
        var rect: CGRect
    }

    private(set) var snapArmed: Bool
    private(set) var imageReady: [Bool]
    /// Display currently owning selection activity; exactly one at a time.
    private(set) var selectionOwner: Int?
    /// A commit issued before its display's frozen image arrived, waiting.
    private(set) var heldCommit: HeldCommit?
    private(set) var resolution: Resolution = .pending

    /// Window snap starts armed on every capture (ADR 0014): pointing at a
    /// window and clicking is the most common capture, and it must not need a
    /// `Tab` first.
    init(displayCount: Int, snapArmed: Bool = true) {
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

    /// Tab. Accepted at any point while the session is pending: "no Selection"
    /// is the normal working state under annotate-first, and a Selection only
    /// hides the highlight, it does not lock the mode. Returns true when the
    /// snap state changed.
    mutating func toggleSnap() -> Bool {
        guard resolution == .pending else { return false }
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

    /// A capture requested on a display. Refused while another display owns
    /// the Selection: a click capture is a single event and can be a slip,
    /// and a slip must not discard the Selection another display holds along
    /// with the work drawn on it. A drag is the one route that takes the
    /// Selection over (see `startSelection`): sustained, and unmistakably
    /// meant.
    mutating func requestCommit(on display: Int, rect: CGRect) -> CommitDisposition {
        guard resolution == .pending, heldCommit == nil,
              imageReady.indices.contains(display),
              selectionOwner == nil || selectionOwner == display
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
