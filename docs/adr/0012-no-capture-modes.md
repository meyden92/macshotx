# There are no capture modes; one pipeline runs after every capture

> **Amended by ADR 0014 (2026-09-02).** One pipeline after every capture still stands, and a dragged Selection is still a plain rectangle with no provenance. What reopened is narrower: a **snap click now captures immediately**, so the window it captured is known at the moment of commit and there is no editable rectangle for provenance to silently fall off — which was the objection below. Provenance is therefore restored for that one route, bringing back the window companion image and honest `%app`/`%window` tokens for snap-click captures. Tracked separately from ADR 0013/0014; it revives a deleted compositor path and is not part of the annotate-first change itself.

Once every route seeds a Selection rather than committing one (ADR 0011), a Selection filled to the display is indistinguishable from a drag that reached the screen edges, and a Selection snapped to a window is indistinguishable from a drag around that window. Rather than carry provenance so the distinction could survive, the distinction is dropped. `CaptureMode` is gone, the per-mode `PipelineOverride` for Region, Window and Fullscreen is gone, and one pipeline runs after every capture.

## Considered Options

- **Keep provenance on the Selection** — rejected. The Selection would have remembered that it was seeded by `F` or from a particular window, invisibly to the user, so the commit could still pick a per-mode override and bake the window companion image; editing the Selection by hand would drop it back to a plain rectangle. It preserves two features at the cost of a concept the interface no longer exposes anywhere. Judged not worth it for now — a single pipeline is enough.

## Consequences

- **The window companion image is removed.** It was the clean single-window image with transparent rounded corners baked alongside a window-snap commit, so post-processing backdrops could show through the corners. It was produced by the window commit path, which no longer exists — without provenance there is nothing to tell the commit which window a rectangle came from. Beautify on a window capture therefore gets square corners over the frozen screen behind them.
- **`%app` and `%window` name the frontmost app, never the snapped window.** Both are snapshotted once when the overlay opens, because without provenance the commit cannot tell which window a rectangle came from — the same reason the companion image goes. A window-snap capture of a background window is therefore filed under whatever was frontmost when the capture began.
- Per-mode pipeline configuration disappears from Settings and from the config file. Anyone who wanted "window captures upload, region captures copy" no longer has a way to express it.
- Reversing this means reinstating provenance, which is the rejected option above and is where to start.
- This deletion is wider than the issue that prompted it ([#3](https://github.com/meyden92/macshotx/issues/3), unifying the capture hotkeys) and was taken deliberately on top of it, not as a side effect.
