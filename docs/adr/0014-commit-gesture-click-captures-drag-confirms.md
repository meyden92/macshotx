# The commit gesture decides: a click captures, a drag confirms

> **Amended 2026-09-02, after testing #57.** A drag now captures on release too. Having used annotate-first, the reporter found a dragged region that then waits for `Return` to be the wrong feel: the drag *is* the decision. Every capture gesture in the overlay is therefore instant — click a window, click the display, drag a region, or press `Return` for the display — and no adjustable Selection ever exists in the capture overlay. What the option below was kept for survives where it still applies: the aspect lock and an armed size preset still shape the drag itself, and the Resolution box, corner handles, arrow-key nudge and typed sizes live on in the post-capture editor, whose crop Selection is still confirmed. The rest of this record stands as the reasoning at the time.

Once the Selection is made last (ADR 0013), it is made by one of two gestures, and they carry different amounts of precision. A **click** captures immediately — on a window, with window snap armed by default, or on empty space — running the pipeline with no confirmation. A **drag** seeds a live, adjustable Selection that `Enter` commits. `Enter` with no Selection captures the display under the cursor.

This supersedes [ADR 0011](0011-every-route-seeds-a-selection.md)'s rule that confirming a Selection is the single commit path. That rule existed so that every route could be annotated; under annotate-first the annotating is already done before any route is taken, so the rule has spent its reason.

## Considered Options

- **Every gesture captures instantly, including the drag** — rejected, and it is the more literal reading of the ShareX feel that prompted this. It would delete the Resolution box (editable W×H, aspect-ratio locks, size presets), the selection handles and arrow-key nudge, all of which exist to fix a rectangle that came out slightly wrong. A drag is the imprecise gesture; a window rect is already exact. Splitting by gesture puts the adjustment where it is needed and the speed where it is earned.
- **Every gesture seeds and waits for `Enter`** — rejected. It costs the point-at-a-window-and-click grab, which is the gesture this change exists for.
- **A setting to choose between them** — rejected. The Resolution box would have to exist or not depending on configuration, which is a worse fork than the one ADR 0013 deleted.

## Consequences

- **A click on empty space captures the whole display immediately, with no confirmation and no undo.** This is a known sharp edge, accepted deliberately; seeding an adjustable Selection instead was considered and declined. What keeps it survivable is the click ladder below: the capturing click is only reachable from a clean canvas state.
- **Select-tool click precedence, first match wins:** hits an annotation → select it; a selected set or an active text edit exists → clear it and capture nothing; a Selection exists → a click outside it dismisses it, a click inside it does nothing, and neither captures; a window is under the cursor with snap armed → capture it; otherwise → capture the display under the cursor. The Selection rung is what stops a click beside an adjustable Selection from firing the shutter.
- `Enter` with no Selection captures the display under the cursor — unless another display holds the Selection, in which case `Enter` confirms that one: the cross-display guard would otherwise swallow the keypress silently.
- While the beautify preview is up (ADR 0007, amended by ADR 0013) the capture stays read-only for annotating, but the click ladder still runs from a clean canvas: window snap hovers and clicks through the scaled preview, with the window resolved where it appears in it, and a click on the backdrop around the shrunk display captures the display, as any empty-space click does.
- **Select-tool drag precedence:** Command-drag → marquee; drag starting on a selected annotation → move it; otherwise → draw a Selection.
- The Marquee is no longer confined to the inside of a Selection, because during the annotate phase there is none. A Command-drag marquees anywhere on the canvas.
- **Window snap starts armed on every capture**, reversing [ADR 0010](0010-one-capture-hotkey.md)'s consequence that the overlay always starts with snap off. Its highlight draws only while the select tool is active, so it does not chase the cursor while a drawing tool is in hand. `Tab` still disarms it — after which clicks capture the display rather than the window under them, so disarming snap does not make clicking safer.
- A click with a drawing tool in hand still captures nothing, which the bare-click path already enforced for seeding.
- A snap click is the one commit that knows exactly which window it captured. ADR 0012 is amended rather than reversed on the strength of that; see it for what reopens and what does not.
