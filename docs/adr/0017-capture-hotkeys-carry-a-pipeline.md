# Capture hotkeys carry a pipeline, not a capture mode

Supersedes [ADR 0010](0010-one-capture-hotkey.md). There is no longer one capture hotkey. The user keeps a list of **capture hotkeys**, as many as they want, and the list may be empty. Each entry has a stable `id`, a name, an optional key binding and the `id` of the [named pipeline](0015-named-reusable-pipelines.md) it runs. The colour picker and magnifier stay two fixed hotkeys beside the list. The menu bar shows one item per entry, in list order, with the entry's shortcut.

Every entry opens the same overlay, idle with window snap armed ([ADR 0016](0016-selection-first-is-the-capture-order.md)). What to capture — a dragged area, a snapped window, the whole display with `F` — is chosen there, and `Return` confirms. ADR 0010's main point holds: nobody has to commit to what they capture before they can see the screen. What comes back is a way to say "this shortcut copies, that one uploads", which one hotkey and one pipeline could not express. The "no capture modes" half of [ADR 0012](0012-no-capture-modes.md) stands.

## Considered Options

- **Keep one capture hotkey and choose the pipeline in the overlay** — rejected. It adds a decision to every capture, and the decision is usually the same for a given habit. Binding it to a shortcut once is cheaper.
- **Each hotkey also carries a starting capture mode (Area, Window, Fullscreen)** — built during epic #68, then removed before release. The Selection-first overlay already offers all three routes from its first frame, so a starting mode only pre-armed or pre-seeded what one click, drag or `F` does anyway. It cost a picker on every Settings row and a second way to say the same thing, for no new capability.
- **A Fullscreen hotkey that captures in one keystroke without the overlay** — rejected for ADR 0010's reasons. It is a second capture path, it captures the cursor, and it skips annotation.

## Consequences

- **Configs are migrated, not discarded.** v1.0.0–v1.1.0 are released. A config with `hotkeys.capture` and no `hotkeys.captures` loads as one entry, "Capture", with the old binding and the "Default" pipeline that the same migration produces ([ADR 0015](0015-named-reusable-pipelines.md)). A fresh config gets the same entry on ⌃⇧4. The migrated entry has a fixed `id`, so decoding is stable. The legacy key is only read, never written.
- **A deleted pipeline does not delete or rewrite the entries that reference it.** Such an entry runs the first pipeline, and Settings → Hotkeys shows a warning on its row until the user picks another pipeline.
- Registration is keyed by `HotkeyAction`: `.capture(id)` for each entry, plus `.colorPicker` and `.magnifier`. Conflict detection checks every pair across the whole set, and the warning names both entries. A hotkey that fires looks its entry up by `id` at that moment, so renames and pipeline changes apply without re-registering. Every edit in Settings re-registers anyway, so rebinding never needs a restart.
- An unbound entry is still reachable from the menu bar. With no entries, the menu bar has no capture items at all.
- Window provenance returns with window-snap seeding ([ADR 0018](0018-window-provenance-is-visible-and-drops-on-edit.md)): the companion image and `%app`/`%window` naming the captured window.
