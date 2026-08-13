# Preview and bake share one compositor

`PostProcessingCompositor` (`PostProcessing.swift`) exposes a pure `layout` function — pixel sizes in, an integral canvas size and capture rect out — and a `render` function that composites a source image according to `BeautifySettings`. The capture overlay's live preview and its confirmed bake both call the same two functions, differing only in the pixel scale passed in.

## Considered Options

- **A bespoke fast preview path** — rejected. It is the obvious optimisation and it silently breaks the only property that makes the compositor's unit tests worth anything: that what the user sees and what is exported are the same computation. A preview that drifts from the bake is a bug the tests cannot see.
- **Rendering the preview at full capture resolution** — rejected. Composing a Retina fullscreen capture on every slider tick is not affordable. The preview instead composes from a *bounded downscaled crop* and passes the pixel scale of that crop, so every setting expressed in points or in fractions resolves proportionally and the result is the same composition at a smaller size.

## Consequences

- A unit test of `layout` or `render` is simultaneously a statement about the on-screen preview and about the exported file. Most of this feature's coverage is therefore fast, view-free, and pixel-exact.
- Any code path that renders a preview without the compositor is a defect, not a shortcut.
- The composition order is fixed and shared: source pixels, background removal, image effects, annotations, corner radius and window frame, drop shadow, backdrop. That order is why effects never touch the backdrop or an annotation's colour, and why annotations are clipped by the corner radius.
- Padding is a fraction of the capture's longer side and the shadow is a set of intensity steps in points, so both scale with the pixel scale rather than being stored as pixels.
