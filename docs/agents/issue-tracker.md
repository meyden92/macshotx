# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues.

**If the `ncon-tools:github` skill is available, invoke it before any tracker operation and follow its rules** — it carries the organisation's issue lifecycle, pull-request conventions, and non-interactive `gh` usage, and it overrides the conventions below wherever they disagree. The conventions below are the fallback for when that skill is not installed.

Use the [`gh`](https://cli.github.com/) CLI (2.94+ for sub-issue and dependency flags) for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body-file <file>`. Always pass title and body explicitly — `gh` prompts interactively when they are missing, which hangs an agent session.
- **Read an issue**: `gh issue view <number> --comments`. Use `--json <fields>` for machine-readable output.
- **List issues**: `gh issue list --json number,title,labels,assignees` with appropriate `--label` filters. The default `--limit` is 30 and truncates silently — raise it.
- **Comment on an issue**: `gh issue comment <number> --body "..."` or `--body-file <file>`.
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`. Comma-separate multiple labels; add and remove combine in one call.
- **Close**: `gh issue close <number> --comment "<solution>" --reason completed` — the closing comment and the close are one call.
- **Pull requests**: `gh pr create`, `gh pr view`, `gh pr comment`, etc. Issues and PRs share one number space, so `#42` may be either; `gh issue view` on a PR fails with a hint rather than answering.

Infer the repo from `git remote -v` — `gh` does this automatically when run inside a clone.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Epics

Planned work that breaks into several tickets is an **epic**: one umbrella issue that owns them, titled `[Epic] <what it delivers>`. Create it before the tickets so each can be attached. Work that is not a body of work — a lone bug report, a single improvement — stays standalone unless the user says otherwise.

The epic is an **ordinary issue**, and its tickets are its **native sub-issues** — GitHub parents issue→issue directly. Attach at creation (`gh issue create --parent <epic>`) or after the fact (`gh issue edit <epic> --add-sub-issue <ticket>`). The epic renders its sub-issue list with a progress bar by itself; don't mirror the children into its body, and don't encode membership in titles.

Blocking is a separate relation from membership — a native dependency, written explicitly (`gh issue edit <ticket> --add-blocked-by <blocker>`), and free to cross repositories (`owner/repo#N`). Use both; neither substitutes for the other.

## Wayfinding operations

Used by `/ncon-engineering:wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create --label wayfinder:map ...`. Its tickets are its native sub-issues (`gh issue create --parent <map>`).
- **Child ticket**: a sub-issue of the map, labelled `wayfinder:<type>` (`research`/`prototype`/`interview`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependency** — the canonical, UI-visible representation: `gh issue edit <child> --add-blocked-by <blocker>`. A ticket is unblocked when every blocker is closed.
- **Frontier query**: the map's open sub-issues without an open blocker or an assignee — `gh issue view <map> --json subIssues`, then check each candidate's `blockedBy` (or search with `is:open is:blocked` to exclude); first in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me` — the session's first write.
- **Resolve**: `gh issue close <n> --comment "<answer>" --reason completed`, then append a context pointer (gist + link) to the map's Decisions-so-far.
