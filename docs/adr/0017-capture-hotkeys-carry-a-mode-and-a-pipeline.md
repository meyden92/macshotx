# Capture hotkeys carry a starting mode and a pipeline

Supersedes [ADR 0010](0010-one-capture-hotkey.md) and the "no capture modes" half of [ADR 0012](0012-no-capture-modes.md). There is no longer one capture hotkey. The user keeps a list of **capture hotkeys**, as many as they want, and the list may be empty. Each entry has a stable `id`, a name, an optional key binding, a **capture mode** (Area, Window or Fullscreen) and the `id` of the [named pipeline](0015-named-reusable-pipelines.md) it runs. The colour picker and magnifier stay two fixed hotkeys beside the list. The menu bar shows one item per entry, in list order, with the entry's shortcut.

The mode is only where the overlay *starts*. Area starts with a drag, Window with window snap armed, Fullscreen with the display already selected, and inside the overlay `Tab` and `F` still switch as before. Every capture still goes through the overlay and is confirmed with `Return` ([ADR 0016](0016-selection-first-is-the-capture-order.md)). ADR 0010's main point holds: nobody has to commit to what they capture before they can see the screen. What comes back is a way to say "this shortcut copies, that one uploads", which one hotkey and one pipeline could not express.

## Considered Options

- **Keep one capture hotkey and choose the pipeline in the overlay** — rejected. It adds a decision to every capture, and the decision is usually the same for a given habit. Binding it to a shortcut once is cheaper.
- **The hotkey locks the overlay to its mode** — rejected. A Window shortcut that cannot fall back to a drag when snap finds nothing useful is a trap. A starting mode costs nothing, because the overlay already had to support switching.
- **A Fullscreen hotkey that captures in one keystroke without the overlay** — rejected for ADR 0010's reasons. It is a second capture path, it captures the cursor, and it skips annotation.

## Consequences

- **Configs are migrated, not discarded.** v1.0.0–v1.1.0 are released. A config with `hotkeys.capture` and no `hotkeys.captures` loads as one entry, "Capture area", in Area mode, with the old binding and the "Default" pipeline that the same migration produces ([ADR 0015](0015-named-reusable-pipelines.md)). A fresh config gets the same entry on ⌃⇧4. The migrated entry has a fixed `id`, so decoding is stable. The legacy key is only read, never written.
- **A deleted pipeline does not delete or rewrite the entries that reference it.** Such an entry runs the first pipeline, and Settings → Hotkeys shows a warning on its row until the user picks another pipeline.
- Registration is keyed by `HotkeyAction`: `.capture(id)` for each entry, plus `.colorPicker` and `.magnifier`. Conflict detection checks every pair across the whole set, and the warning names both entries. A hotkey that fires looks its entry up by `id` at that moment, so renames and pipeline changes apply without re-registering. Every edit in Settings re-registers anyway, so rebinding never needs a restart.
- An unbound entry is still reachable from the menu bar. With no entries, the menu bar has no capture items at all.
- The stored mode does not change the overlay yet. That is #72. `CaptureService.captureOverlay` already takes the entry, so #72 only has to pass the mode through.
- Window provenance returns with Window-mode captures in #64. Until then, `%app` and `%window` still name the frontmost app (ADR 0012).
