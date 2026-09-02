# Annotate-first is the only capture order

The capture overlay used to require a Selection before its tools appeared: seed a Selection, then annotate, then confirm. That order is inverted and the old one is deleted. The annotation tools are live from the first frame over the frozen screen image, the whole display is the canvas, and the Selection is made last — it crops what was already drawn. There is no setting: annotate-first is the only order the overlay runs in.

## Considered Options

- **Ship it as a setting, defaulting off** — rejected, and it is what was originally asked for. Two orders means two meanings for a bare click, two helper cards, and a standing question hanging off every future overlay feature: "what does this do in the other order?" The fork was judged more expensive than committing to one order and deleting the other.
- **Keep the old order for captures with no annotations** — rejected for the same reason, and unnecessary: the plain region grab is unharmed, because the select tool is active from the first frame and a drag still draws a Selection. Annotate-first taxes it by nothing.

## Consequences

- **The idle state is gone.** `isIdle` gated the helper card, the bare-click seed and `F`-as-fullscreen. None of the three survives, because "no Selection yet" is now the normal working state rather than a transient one on the way to a capture.
- `F` is the fill-rect tool shortcut and nothing else. The fullscreen route is `Enter` with no Selection, which captures the display under the cursor.
- The tool strip cannot be placed relative to a Selection that does not exist. It sits at the bottom of the display under the cursor and follows the cursor across displays; once a Selection exists, the existing placement solver takes over. A strip that relocates mid-capture is the accepted cost.
- **The helper card is deleted rather than rewritten.** Every clause of it was false under the new order, and a card that reappears whenever the canvas empties is noise once the flow is known. The "Show overlay hints" setting survives, now governing only the selecting-hint chip.
- Annotations falling outside the final Selection are clipped silently — the bake-then-crop the compositor already does. Annotations on displays other than the one the Selection lands on are discarded with no warning, the same way a cross-display Selection already clears.
- `Esc` still cancels the whole capture in one press, which is now considerably more destructive: it can discard a minute of annotation work. An escalating `Esc` — clear the selected set first, cancel only from an empty state — was considered and declined.
- `requiresSelection` stops being a meaningful fork between the capture overlay and the detached editor. Both now annotate without a crop; what remains different is that only the overlay has windows to snap to and a gesture that captures.
