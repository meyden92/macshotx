# One capture hotkey; what to capture is chosen inside the overlay

macshot had three global capture hotkeys — Region, Window and Fullscreen — from a time when each one led somewhere different. Region and Window had already collapsed into the same overlay, differing only in whether window snap started armed, while Fullscreen was the one path that never presented the overlay at all. There is now a single capture hotkey, which always presents the capture overlay; what gets captured is decided inside it and nowhere else.

## Considered Options

- **Unify Region and Window, keep Fullscreen as its own hotkey** — rejected. It is the conservative reading: Region and Window were genuinely redundant with each other, whereas the Fullscreen hotkey captured in a single keystroke with no UI at all. Keeping it would have preserved that, at the cost of the thing the change is for — a user still has to know which of two hotkeys they want *before* they can see the screen they are capturing. One entry point was judged worth more than the one-keystroke grab.
- **One hotkey, with a modifier or double-tap that commits fullscreen instantly** — rejected. It buys back the keystroke by inventing a gesture nothing advertises, and reintroduces the direct capture path this decision exists to delete.
- **A visible mode control in the overlay chrome** — deferred, not rejected. The overlay teaches its routes through the idle helper card and the keyboard. A segmented control is a real design question — where it sits against the toolbar strip and the tool-options row — and does not belong to this change.

## Consequences

- **Fullscreen captures no longer contain the mouse cursor.** The direct path grabbed the display with the cursor drawn; the overlay composites the frozen screen image, which is captured without it. Consistency across every capture is the accepted trade, not an oversight.
- Fullscreen costs an overlay presentation and a confirmation where it used to cost one keystroke. In exchange it gains everything the overlay offers, which it previously could not reach at all (ADR 0011).
- The overlay's entry no longer carries intent: `initialSnapArmed` is gone and the overlay always starts with window snap off.
- The colour picker and magnifier hotkeys are untouched. They are not captures and have no overlay path.
- Bindings users had already configured are discarded rather than migrated, and the stored key is renamed with no read of the legacy keys. macshot has no released version, so there is no configuration in the world worth carrying forward; this is not a precedent for post-release schema changes.
- The menu bar offers a single "Capture" item, with no keyboard equivalent. The old per-mode items carried hardcoded ⌘⇧1/2/3 equivalents that never matched the configured global hotkeys and never reflected rebinds; the Hotkeys settings tab is where combinations belong.
