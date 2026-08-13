import AppKit

/// The annotation document: the ordered annotations of one capture session
/// (order is z-order) plus its undo/redo history. The capture overlay owns one
/// per session, renders and bakes from it, and performs every annotation
/// mutation through it — mutating the list any other way would bypass the
/// history (see docs/adr/0006-hand-rolled-annotation-undo.md).
@MainActor
struct AnnotationDocument {
    /// Opaque stable identity, assigned by the document at insertion. History
    /// entries and the overlay's selection refer to annotations by identity;
    /// z-order stays positional.
    struct ID: Hashable {
        fileprivate let raw: Int
    }

    struct Placed {
        let id: ID
        var annotation: Annotation
    }

    /// One undoable step: a group identifier plus the entries recorded while
    /// it was open. Ordinary mutations are one-entry steps.
    private struct Step {
        let groupID: UUID
        var entries: [Entry]
    }

    /// The history entry kinds. Everything a step, stack, or the undo/redo
    /// logic needs to do happens through `apply`/`revert` — nothing outside this
    /// enum inspects an entry's annotation identifier, which is what let the
    /// image-transform kind, which names no annotation at all, slot in without
    /// redesign.
    private enum Entry {
        case insert(index: Int, placed: Placed)
        case remove(index: Int, placed: Placed)
        case change(id: ID, before: Annotation, after: Annotation)

        func apply(to document: inout AnnotationDocument) {
            switch self {
            case let .insert(index, placed): document.placed.insert(placed, at: index)
            case let .remove(index, _): document.placed.remove(at: index)
            case let .change(id, _, after): Self.set(id, to: after, in: &document.placed)
            }
        }

        func revert(to document: inout AnnotationDocument) {
            switch self {
            case let .insert(index, _): document.placed.remove(at: index)
            case let .remove(index, placed): document.placed.insert(placed, at: index)
            case let .change(id, before, _): Self.set(id, to: before, in: &document.placed)
            }
        }

        private static func set(_ id: ID, to annotation: Annotation, in list: inout [Placed]) {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].annotation = annotation
        }
    }

    private(set) var placed: [Placed] = []
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private var nextRawID = 0
    private var openGroupEntries: [Entry]?

    var annotations: [Annotation] { placed.map(\.annotation) }

    private func index(of id: ID) -> Int? {
        placed.firstIndex { $0.id == id }
    }

    func annotation(for id: ID) -> Annotation? {
        index(of: id).map { placed[$0].annotation }
    }

    func contains(_ id: ID) -> Bool {
        index(of: id) != nil
    }

    /// Derived from the annotations currently present, so undoing a marker
    /// frees its number and redoing it takes it back.
    var nextStepMarkerNumber: Int {
        let highest = annotations.compactMap { annotation -> Int? in
            if case let .stepMarker(_, number, _) = annotation { return number }
            return nil
        }.max() ?? 0
        return highest + 1
    }

    // MARK: Recorded mutations

    @discardableResult
    mutating func insert(_ annotation: Annotation) -> ID {
        let id = ID(raw: nextRawID)
        nextRawID += 1
        let entry = Placed(id: id, annotation: annotation)
        placed.append(entry)
        record(.insert(index: placed.count - 1, placed: entry))
        return id
    }

    mutating func remove(_ id: ID) {
        guard let index = index(of: id) else { return }
        let removed = placed.remove(at: index)
        record(.remove(index: index, placed: removed))
    }

    /// Replace an annotation in place as one step. Replacing with an equal
    /// value records nothing.
    mutating func replace(_ id: ID, with annotation: Annotation) {
        guard let index = index(of: id),
              placed[index].annotation != annotation
        else { return }
        let before = placed[index].annotation
        placed[index].annotation = annotation
        record(.change(id: id, before: before, after: annotation))
    }

    // MARK: Drag support

    /// Live-preview update during a drag: mutates without recording. The
    /// caller records the whole gesture at mouse-up via `commitChange`.
    mutating func updateLive(_ id: ID, to annotation: Annotation) {
        guard let index = index(of: id) else { return }
        placed[index].annotation = annotation
    }

    /// Record a completed drag as one step, with `before` (snapshotted at
    /// drag start) as the prior state. A drag that ended where it started
    /// records nothing.
    mutating func commitChange(_ id: ID, from before: Annotation) {
        guard let current = annotation(for: id), current != before else { return }
        record(.change(id: id, before: before, after: current))
    }

    // MARK: Grouping

    /// Mutations between `beginGroup` and `endGroup` land in one step, so the
    /// whole group undoes and redoes as a single action.
    mutating func beginGroup() {
        guard openGroupEntries == nil else { return }
        openGroupEntries = []
    }

    mutating func endGroup() {
        guard let entries = openGroupEntries else { return }
        openGroupEntries = nil
        guard !entries.isEmpty else { return }
        push(Step(groupID: UUID(), entries: entries))
    }

    // MARK: Undo / redo

    mutating func undo() {
        guard openGroupEntries == nil, let step = undoStack.popLast() else { return }
        for entry in step.entries.reversed() {
            entry.revert(to: &self)
        }
        redoStack.append(step)
    }

    mutating func redo() {
        guard openGroupEntries == nil, let step = redoStack.popLast() else { return }
        for entry in step.entries {
            entry.apply(to: &self)
        }
        undoStack.append(step)
    }

    // MARK: History plumbing

    private mutating func record(_ entry: Entry) {
        if openGroupEntries != nil {
            openGroupEntries?.append(entry)
        } else {
            push(Step(groupID: UUID(), entries: [entry]))
        }
    }

    /// Every recorded step clears the redo path — here and nowhere else.
    private mutating func push(_ step: Step) {
        undoStack.append(step)
        redoStack.removeAll()
    }
}
