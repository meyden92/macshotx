## Coding preferences - general
- Keep things simple. Channel "yagni" energy unless told otherwise
- Typesafety is useful, take advantage of it.
- Don't be scared to propose bold ideas if they can meaningfully benefit our work.
- Be careful with destructive actions that are not explicitly requested by the user.
- Tests are good! Endless smoke tests, "regression tests" for feature deletions, etc, much less good. Tests should be focused, not slop.
- Comments are a great way to clarify functionality and how code is used. Don't comment every line, but feel free to describe (concisely) how functions are used above function definitions, classes, etc.
- Keep comments up to date! When making changes, it's important to keep things in sync.

## Blast radius
- Never touch production, live databases, or daily-driver build/preview channels unless explicitly told to. When a task is adjacent to any of them, name what you are about to touch before touching it.

## Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## Toolchain

Pure SwiftPM — there is no Xcode project (`docs/adr/0004-swiftpm-no-xcode.md`). The dev loop is editor + CLI: `swift build`, `swift test`, and `scripts/`. Point the user at those for every build/run/signing task — never at Xcode.

- `scripts/run.sh` — build → bundle → relaunch the app, tailing its log.
- Info.plist keys live in `scripts/bundle.sh`; the version is an argument, passed down from the git tag by the release workflow.
- Dev builds sign with the local "Apple Development" cert via raw `codesign` — this works from the CLI (xcodebuild's automatic-signing auth failure no longer applies). Ad-hoc fallback makes macOS re-prompt for Screen Recording after rebuilds.
- `scripts/release.sh <version>` — Developer ID + notarization + styled `.dmg`. Needs `brew install create-dmg`. Notarizes locally via the `macshot-notary` keychain profile, or with an App Store Connect key when `NOTARY_KEY_PATH` is set.
- Releases publish from `.github/workflows/release.yml` on pushing a `v*` tag; it runs the same `release.sh`. Team ID is `P3VNJ55K48`.

## Workflow

### General Rules
When working on something, no matter what, we need to always reference a github issue. So everything that has been done remains traceable

### Working on issues
When working on a implementation for an issue - Read the full epic on github, change the label to "Doing" and work on it on a separate branch.
When done: Create a Pull Request and change the label to "testing" and instruct the user on how to test out the changes.

### Bug reports
When the user reports a bug that is not relevant to the current implementation task, you should create a issue on github for it and not start on a fix.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context — `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.