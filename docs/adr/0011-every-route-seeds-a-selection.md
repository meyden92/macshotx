# Every route seeds a Selection; confirming is the only way to commit

> **Superseded by ADR 0014 (2026-09-02).** Confirming is no longer the only commit path: a click captures immediately, a drag still seeds and confirms. The reasoning below is why every route could be annotated in the first place, which ADR 0013 achieves by a different means — the tools are live before any route is taken.

The capture overlay used to have four commit routes, three of which fired immediately: `F` captured the display, a click on an idle overlay captured its display, and a snap click captured the window under the cursor. Only a dragged Selection waited for confirmation. Now all three seed the Selection instead — `F` fills it to the whole display exactly as a drag across the display would, a snap click sets it to the clicked window — and the tools come up in every case. Confirming a Selection is the single commit path.

The instant routes were fast, but they meant two of the three ways to capture could never be annotated, beautified or adjusted in the overlay: the machinery was all there and reachable only from the detached editor after the fact. The gate was the `isIdle` check in front of each instant commit, not the bake path, which already handled annotations.

## Considered Options

- **Keep the snap click instant** — rejected. It is the one gesture the helper card actively teaches, so the muscle memory is real, and it was the strongest case for keeping a fast path. It lost anyway: a window screenshot is the capture most likely to want a backdrop or an arrow on it, so it is the worst one to make un-annotatable.
- **Keep the bare display click instant while `F` seeds a Selection** — rejected. Both produce the same result, and two routes to one outcome behaving differently is a bug report waiting to happen.

## Consequences

- Every capture now costs a confirmation. That is the price of the overlay's tools applying uniformly.
- `F` keeps meaning fullscreen only while the overlay is idle; with a Selection up it still selects the fill-rect tool, whose shortcut it is.
- The helper card must describe seeding rather than capturing — "click a window to capture it" would be false.
- A future contributor looking at a two-step window capture will be tempted to re-add the instant path. This ADR is the reason not to.
