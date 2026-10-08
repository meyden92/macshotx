# Pipelines are named and reusable, and referenced by id

Supersedes the "one pipeline runs after every capture" half of [ADR 0012](0012-no-capture-modes.md). The config no longer holds one action list; it holds a list of **pipelines**, each with a stable `id`, a `name` and an ordered action list, defined once in Settings → Pipelines the way Destinations are. Whatever starts a capture names the pipeline to run by its `id` — capture hotkeys will (#71) — and `PipelineRunner` runs the pipeline it is handed rather than reading the config. There is always at least one pipeline. Until capture hotkeys land, a capture runs the first one.

## Considered Options

- **Each capture hotkey owns its own action list** — rejected. It needs no management UI, but two hotkeys that should do the same thing would each carry a copy, and changing "what my shortcuts do" would mean editing every copy in step. Named pipelines cost a list-and-editor tab; in exchange a pipeline is edited once and every hotkey that references it follows.
- **One pipeline plus per-hotkey overrides** — rejected. It is the per-mode `PipelineOverride` that ADR 0012 deleted, keyed by hotkey instead of mode: a global list, a replace-or-extend switch per entry, and the question of which one actually ran.
- **Reference by name, like an Upload action references a Destination** — rejected. Renaming a pipeline would silently break every hotkey pointing at it. The `id` survives renames; the name is only a label.

## Consequences

- **Configs are migrated, not discarded.** v1.0.0–v1.1.0 stored the one action list at `pipeline.global`. A config with that key and no `pipelines` loads as a single pipeline named "Default" holding the same actions; a fresh config gets "Default" with copy image and save to disk. Unlike ADR 0010, these are released versions, so there is configuration in the world worth carrying forward. The legacy key is only read, never written.
- "Default" has a fixed `id`, so a fresh or migrated config decodes to the same value every time. Pipelines added or duplicated in Settings get a random one.
- The last pipeline cannot be removed, and an empty `pipelines` list in a hand-edited file decodes to the default. There is always something to run.
- Config export and import carry every pipeline, and the shell commands an imported config would run are gathered from all of them.
- A failed run's Retry still carries the remaining actions rather than a pipeline reference, so editing or deleting the pipeline afterwards does not change what Retry reruns.
