# Hand-rolled annotation undo, snapshotting whole annotations

The capture overlay's undo history lives in `AnnotationDocument` (`AnnotationDocument.swift`): a main-actor value type owning the ordered annotations (order is z-order) plus a stack of steps, each step one or more entries of three kinds — insert, remove, and change. A change entry is a before/after snapshot of the whole annotation, never a per-property record. The capture overlay and the detached editor window both host `RegionPickerView`, which holds one document per capture session and performs every annotation mutation through it.

## Considered Options

- **AppKit's `NSUndoManager`** — rejected. Its selling point is responder-chain and Edit-menu integration, which a borderless screen-saver-level overlay with its own key handling never uses. It registers closures rather than data, so restoring z-order on undelete and grouping multi-annotation operations would have to be hand-rolled on top of it anyway — and closures can't be unit-tested as a value type. The hand-rolled history is a few dozen lines and is exercised directly in `AnnotationDocumentTests`.
- **Per-property change records** — rejected. Every style property (and every property added by later overhaul phases) would need its own entry case, inverse, and tests. Whole-annotation snapshots make a new style property undoable the day it is added, with zero history work.
- **Whole-document snapshots per step** — rejected. Simplest possible model, but it duplicates every freehand point array on every stroke and gives no place to hang group semantics or future non-annotation entries.

## Consequences

- Every annotation mutation must go through the document (`insert`/`remove`/`replace`, or `updateLive` + `commitChange` for drags). Mutating the annotation list any other way is the failure mode that would quietly reintroduce unrecorded, un-undoable edits — the exact problem this rework removed.
- Redo invalidation is owned by the document (recording any step clears the redo stack); no call site manages it.
- Nothing outside the entry kinds inspects an entry's annotation identifier, so a later whole-image entry kind (phase 6's flips and background removal) joins the same step/stack/grouping machinery without redesign. _Amended by #8 (2026-08-13): background removal was dropped and its `imageTransform` entry kind with it, so no whole-image entry kind exists today. The property this claims — that one can be added without redesign — is untested until the next one arrives._
- Annotations gained a stable identity assigned at insertion and `Annotation` gained `Equatable` — identity so history entries and the overlay's selection survive undo reordering the list, equality so a drag that ends where it started records nothing.
- Step marker numbering derives from the annotations currently in the document, so undo frees a marker's number and redo takes it back.
