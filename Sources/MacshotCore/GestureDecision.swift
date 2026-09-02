import CoreGraphics

/// The select tool's click and drag precedence as pure decisions (ADR 0014).
///
/// The overlay view builds a `Facts` from what it can observe at mouse-down —
/// which tool is active, what the point hit, what is already selected — and
/// dispatches over the outcome. Gestures that are genuinely stateful (an
/// in-flight Selection gesture, an armed fixed-size frame, anchored mode,
/// auto-measure) are handled before the view consults this; it decides only
/// what an otherwise-unclaimed click or drag means.
///
/// Naming follows the glossary: the *selected set* is the annotations chosen
/// for group editing, the *Selection* is the capture rectangle.
enum SelectGesture {
    struct Facts: Equatable {
        var tool: Tool = .select
        var commandHeld = false
        var shiftHeld = false
        /// The point is on the single selected annotation's resize or
        /// rotation handle.
        var onSelectedHandle = false
        /// A set of several is selected and the point is inside its combined
        /// outline.
        var insideSelectedSet = false
        var hitsAnnotation = false
        var hasSelectedSet = false
        var isEditingText = false
        var snapArmed = false
        var windowUnderCursor = false
        var hasSelection = false
        var insideSelection = false
        var selectionHandle: ResizeHandle?
        /// No Selection, no annotations, no draft, no text edit — the state in
        /// which a bare click seeds the display.
        var isIdle = false
    }

    /// What a mouse-down primes. Only `drawSelection` and `draw` can turn out
    /// to be bare clicks, which is when the click ladder is consulted.
    enum DragOutcome: Equatable {
        /// Command-drag: sweep the annotation marquee.
        case marquee
        /// Shift-click on an annotation toggles its membership of the set.
        case toggleMembership
        /// Rotate, resize or move what is already selected.
        case manipulateSelected
        /// Select the annotation under the point and move it.
        case grabAnnotation
        case resizeSelection(ResizeHandle)
        case moveSelection
        case drawSelection
        /// The active drawing tool runs.
        case draw
    }

    /// What a click that never dragged means.
    enum ClickOutcome: Equatable {
        case selectAnnotation
        /// Seed the Selection to the window under the cursor.
        case seedWindow
        /// Seed the Selection to the whole display.
        case seedDisplay
        case nothing
    }

    static func drag(_ f: Facts) -> DragOutcome {
        // Grabbing a placed element belongs to the select tool; Command grabs
        // without switching tools, so a drawing tool can still draw on top of
        // an existing element.
        let manipulates = f.tool == .select || f.commandHeld
        if manipulates {
            if f.onSelectedHandle { return .manipulateSelected }
            // Shift is reserved for changing who is in the set.
            if !f.shiftHeld, f.insideSelectedSet { return .manipulateSelected }
            if f.hitsAnnotation { return f.shiftHeld ? .toggleMembership : .grabAnnotation }
        }
        if f.tool == .select, f.hasSelection {
            if let handle = f.selectionHandle { return .resizeSelection(handle) }
            if f.insideSelection { return f.commandHeld ? .marquee : .moveSelection }
        }
        return f.tool == .select ? .drawSelection : .draw
    }

    static func click(_ f: Facts) -> ClickOutcome {
        if f.hitsAnnotation { return .selectAnnotation }
        if f.snapArmed { return f.windowUnderCursor ? .seedWindow : .nothing }
        // A misclick with a drawing tool must not seed anything.
        return f.tool == .select && f.isIdle ? .seedDisplay : .nothing
    }
}
