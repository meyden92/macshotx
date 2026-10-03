# A window-snapped Selection carries its window, visibly, until it is edited

Supersedes the provenance half of [ADR 0012](0012-no-capture-modes.md). When window snap seeds the Selection, the Selection carries that window as its **window provenance**: its window ID, app name, title and frame. Only a window snap gives it one, and only when the whole window lies on that display. A drag, `F` and a Fullscreen start give none, and neither does a snap that had to be clamped to the display, because that Selection is part of a window. The provenance lasts exactly as long as the rectangle is still that window. Any change drops it: move, resize, arrow-key nudge, a typed size, an aspect lock that reshapes it, dismissing it, or a new drag or seed. Once it is dropped, the capture is a plain area. A click inside the Selection changes nothing and keeps it.

While the provenance holds, the Resolution box names the window ("Xcode — Main.swift"), and the name disappears the moment it is dropped. A gesture in flight hides it too, because releasing that gesture is about to drop it.

## Why the ADR 0012 objection no longer applies

ADR 0012 rejected provenance on the Selection because it would ride **invisibly** on an editable rectangle: the user could not see that the Selection remembered a window, and could not see the moment it forgot. Both halves are answered here:

- **It is visible.** The overlay shows the provenance for as long as it applies, next to the size it applies to. What the capture will be named, and whether beautify will use the window's own corners, is on screen before `Return`.
- **It is honest.** It is dropped on any change rather than kept while the rectangle "still roughly contains" the window. Provenance only ever describes a rectangle that is exactly the window, so nothing derived from it can be wrong about what was captured. Moving the Selection away and back still drops it: a rule about edits is easier to predict than a rule about rectangles.

## What it brings back

- **The window companion image.** As soon as the snap seeds the Selection, the session captures that window on its own, shadow-free, through ScreenCaptureKit's desktop-independent window filter. That gives the window with transparent rounded corners. The image is installed on the overlay when it lands, so beautify's preview shows it. A commit carrying the window waits for it if it is still in flight, so a fast `Return` composes the same as a slow one. If the capture fails, the commit composes from the frozen screen like any other. Beautify composes the companion instead of the frozen crop, so the backdrop shows through the window's real corners. The corner-radius and window-frame stages are skipped, and their controls are disabled with a tooltip saying why, because the window already has both. With beautify off, the frozen crop is still what a window capture produces.
- **Honest `%app` and `%window`.** A commit carrying a window resolves both tokens from it, including a background window that was never frontmost. Every other capture falls back to the frontmost-app snapshot taken when the overlay opens. The two sources are never mixed: an untitled window gets an empty `%window`, not the frontmost window's title.
- **The held commit keeps it.** A `Return` before the display's frozen image lands is held by `CaptureSessionModel` with the window alongside the rectangle.

## Transparency stays inside the compositor

ADR 0007's amendment removed the artifact's may-contain-transparency flag together with background removal. It is not brought back. The companion is the only transparent source, and only beautify composes it. Beautify always paints an opaque backdrop over the whole canvas before the capture is composited onto it. So the transparent corners show the backdrop and never reach the Composition: the pipeline still receives an opaque image, and the configured output format, JPEG included, applies unchanged. If a window capture is ever exported *without* a backdrop, for example a transparent PNG of just the window, the flag has to come back with it.

## Considered Options

- **Keep provenance while the edited Selection still contains the window** — rejected. It is exactly the invisible rule ADR 0012 objected to: the user cannot tell which edits keep the window and which do not.
- **Lock a snapped Selection against edits** — rejected. ADR 0016's Selection is adjustable however it was seeded, and a window capture is the one most likely to want a nudge.
- **Capture the companion only at commit**, as the pre-ADR 0011 window commit did — rejected. Beautify's preview would show square corners over the frozen desktop while the bake showed rounded ones, breaking ADR 0008's rule that preview and bake are the same composition.
- **Keep provenance for a window that is partly off the display** — rejected. The Selection would be part of the window while the companion is all of it.

## Consequences

- `WindowCandidate` carries the app name and title again. Their only consumers are the provenance indicator and the commit's `%app`/`%window`.
- The companion is captured live after macshot has activated, while the frozen screen was captured before. The window's appearance in the companion (inactive title bar, content that changed since the freeze) can therefore differ from what the frozen screen shows. Only beautify shows it.
- A `Return` straight after the snap click can wait briefly for the companion capture before the overlay closes.
- Window mode ([ADR 0017](0017-capture-hotkeys-carry-a-mode-and-a-pipeline.md)) is the usual way in, but provenance belongs to the seed, not the mode. A snap click in any mode gives it, once `Tab` has armed snap.
