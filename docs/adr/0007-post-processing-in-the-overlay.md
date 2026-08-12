# Post-processing is composited in the capture overlay, not in the Pipeline

Beautify (backdrop, padding, corner radius, shadow, window frame), image effects (brightness, contrast, saturation, sharpness) and background removal are capture-overlay state, previewed live over the frozen screen and composited once when the capture is confirmed. The Pipeline's contract is unchanged: it receives one finished image and runs the configured actions on it. There is no new `Pipeline action`, no new per-mode override, and no Settings switch that turns any of it on.

## Considered Options

- **A "beautify" Pipeline action** — rejected. The moment these decisions are worth making is while the Selection is still live: that is when the user knows what the shot is for. An action configured in Settings is blind — no preview, no chance to try a different backdrop, no chance to back out — so the user would be configuring in advance something they can only judge afterwards.
- **A separate post-capture step, between the overlay and the Pipeline** — rejected for the same reason plus a second one: it would need its own window, its own chrome and its own cancel semantics, all of which the overlay already has.
- **Baking post-processing into the annotation renderer** — rejected. Effects must not touch annotations and beautify must not be affected by them; a single renderer would have to know the composition order anyway, which is what the compositor is.

## Consequences

- The detached editor inherits all three features for free, because it hosts the same `RegionPickerView`. Its "no Selection means the whole image" rule is the only difference.
- The Pipeline stays a dumb consumer of one image. The single exception is the alpha-safe output format: the artifact carries a may-contain-transparency flag set from composition state, and the Pipeline resolves the effective format in one place so encoding and the filename extension can never disagree.
- Nothing is destroyed until the user confirms. Cancelling produces no image at all, whatever the preview was showing.
- Beautify settings and effect values are not undo entries — they have their own toggle and their own reset, and a slider drag would flood the stack. Background removal is one image-transform entry in the phase-1 model (ADR 0006), which that model was written to allow.
