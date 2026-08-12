# macshot — Product Requirements Document

**Status:** Draft v0.1
**Last updated:** 2026-05-22
**Owner:** @crysis992

---

## 1. Overview

**macshot** is a free and open-source screenshot utility for macOS, built for power users and developers. It fills the gap between macOS's minimal built-in screenshot tool (`Cmd+Shift+5`) and the deep, automation-heavy workflows familiar to ShareX users on Windows.

The core thesis: take a great screenshot, annotate it before you take it, and pipe the result through a configurable chain of actions (copy, save, upload, run a script) without ever leaving the keyboard.

### One-sentence pitch

> A native macOS screenshot tool with ShareX-grade automation: overlay annotation, token-based filenames, S3/SFTP/WebDAV/custom uploaders, and a chainable action pipeline — all keyboard-driven, all open source.

---

## 2. Goals and Non-Goals

### Goals (v1)

- Fast, keyboard-first still-image capture (region, window, fullscreen).
- ShareX-style overlay annotation: draw on the live screen, then select the region.
- Token-templated filenames and a chainable post-capture pipeline (copy → save → upload → shell).
- Self-hosted upload destinations: S3-compatible, SFTP/FTP/WebDAV, plus a custom HTTP uploader compatible with ShareX `.sxcu` files.
- Built-in utilities: OCR (Apple Vision) and color picker / magnifier loupe.
- Zero telemetry. No network calls except those the user explicitly configured.
- MIT-licensed, hosted on self-managed GitLab, distributed as a signed and notarized direct download with Sparkle auto-update.

### Non-goals (v1)

- Video and GIF recording (deferred to a later release).
- Scrolling capture, freeform/lasso, timed capture, repeat-last, menu capture.
- Image effects, watermarks, stylized export (rounded corners / drop shadow / wallpaper background).
- Cloud sync of settings.
- Imgur and other public anonymous hosts as built-in destinations (users can configure via custom uploader if they want one).
- Telemetry, analytics, or any form of usage tracking.
- Mac App Store distribution.
- Intel x86_64 support.
- Localization beyond English (architecture is i18n-ready; translations come later).
- Accessibility polish (VoiceOver/keyboard nav) — deferred to post-v1 with explicit acknowledgement that retrofit is harder. See §13.

---

## 3. Target User

**Primary persona — "Senior developer / SRE / designer who lives in their terminal."**

- Comfortable configuring hotkeys, editing JSON, and pasting an S3 bucket policy.
- Already uses `~/.config/`-style dotfiles, runs their own infrastructure where possible, distrusts SaaS analytics.
- Wants a screenshot tool that respects their setup: hosts uploads on infrastructure they control, automates around their existing tooling (shell commands, internal upload endpoints), and doesn't phone home.
- Has used ShareX on Windows or misses it; the macOS built-in tool is too shallow for their workflow.

**Anti-persona — "Casual user who wants a polished, zero-config CleanShot experience."** macshot is not optimizing for them. They have CleanShot X, Shottr, and the built-in tool. We don't compete on first-launch polish.

---

## 4. Core Concepts

A small vocabulary used throughout this document and the app itself.

### 4.1 Capture mode

The kind of capture being taken. v1 ships three:

- **Region** — drag a rectangle on screen. Uses the overlay annotation flow (§6.1).
- **Window** — hover-to-highlight, click to capture a single window.
- **Fullscreen** — capture the entire display the cursor is on. (Multi-display: per-display only; no all-displays-stitched mode in v1.)

### 4.2 Pipeline

The ordered list of actions executed after a capture is taken. A single **global pipeline** is configured in settings; each capture mode may **override** specific steps (e.g., region opens the overlay annotator, window skips straight to upload).

### 4.3 Pipeline action

A unit of work in the pipeline. v1 ships:

- **Open in editor** (annotation; only meaningful for non-region modes — see §6.5).
- **Copy image to clipboard**
- **Save to disk** (with filename template)
- **Upload to destination** (selects one configured destination)
- **Copy URL to clipboard** (uses URL returned by the most recent upload step)
- **Run shell command** (path + URL passed as `$1` / `$2` or env vars)
- **Open in app** (open the file with a chosen application)

Actions execute in order. If one fails, the pipeline halts and surfaces an error notification (§9.4).

### 4.4 Destination

A configured upload target. Types in v1:

- **S3-compatible** (AWS S3, Cloudflare R2, Backblaze B2, MinIO, Wasabi, any S3 API)
- **SFTP / FTP / WebDAV**
- **Custom HTTP uploader** (ShareX `.sxcu`–compatible: request template + response parser)

Destinations are reusable: any pipeline `Upload to destination` action picks one by name.

### 4.5 Filename template

A ShareX-style token string used by the `Save to disk` action and as the local filename for any temporary file an `Upload` action uploads. Tokens listed in §6.7.

---

## 5. User Stories

- As a developer filing a bug report, I press `⌃⇧4`, drag over the broken UI, scribble a red circle and the word "wat", release, and have a URL on my clipboard pointing to my own R2 bucket — in under three seconds, with no app window ever opening.
- As an SRE writing a runbook, I capture five windows in sequence; each save lands in `~/Pictures/macshot/runbook/` with filenames like `2026-05-22_14-31-08_Grafana.png`, and a shell action stages them into the runbook's image directory.
- As a designer pulling color from a Figma export, I hit `⌃⇧C`, click a pixel, and `#3A7BD5` lands on my clipboard.
- As a user who got a screenshot from someone with text in it, I right-click the file in Finder, choose Services → "Extract Text with macshot" (post-v1; see §13), and get the text in my clipboard.
- As a self-hoster, I import a friend's ShareX `.sxcu` config and immediately upload to their personal Zipline instance.

---

## 6. Functional Requirements

### 6.1 Region capture — the overlay annotation flow

**This is the headline UX of v1 and the primary differentiator from the built-in tool.**

Sequence:

1. User triggers the Region capture hotkey.
2. A full-screen, semi-transparent overlay appears on the display under the cursor. The screen behind the overlay is frozen (snapshot taken at trigger time) to prevent UI animation flicker during annotation.
3. A floating toolbar appears with the editor tools (§6.5). Default tool is the region selector.
4. User can draw annotations directly on the frozen screen (arrows, rectangles, text, redaction, step markers, etc.) **before** selecting the capture area.
5. User drags a rectangle to define the capture region. The rectangle can be resized after drawing.
6. On confirm (Enter, double-click, or "Capture" button), the bitmap = the frozen screen pixels + the annotations within the selected rectangle, rasterized at native (Retina) resolution.
7. The overlay dismisses and the pipeline runs.

Cancellation: `Esc` dismisses the overlay with no capture.

Notes:
- Annotations drawn outside the selected rectangle are discarded.
- The frozen snapshot is taken via ScreenCaptureKit at the moment the hotkey fires, so it captures whatever was on screen, including dropdown menus, hover states, and animations mid-frame.
- The region picker is constrained to a single display. Dragging cannot cross display boundaries in v1.

### 6.2 Window capture

1. User triggers Window capture hotkey.
2. Cursor enters a "pick a window" mode. As the cursor hovers, the window beneath it is highlighted (border + slight tint).
3. Single-click captures that window. `Esc` cancels.
4. The capture is taken via ScreenCaptureKit window-content streaming, including the window shadow by default (configurable per-pipeline-execution? — see Open Design Questions).
5. Pipeline runs. If the pipeline contains an `Open in editor` action, a post-capture editor window opens (§6.5.2).

### 6.3 Fullscreen capture

1. User triggers Fullscreen capture hotkey.
2. The display under the cursor at trigger time is captured immediately (no overlay, no picker).
3. Pipeline runs. If the pipeline contains an `Open in editor` action, a post-capture editor window opens.

### 6.4 Utility tools

#### 6.4.1 OCR

- Triggered as a pipeline action (`Extract text` — Open Design Question: is this a pipeline action, a standalone hotkey, or both?) or via the post-capture editor's "Extract Text" button.
- Runs Apple Vision (`VNRecognizeTextRequest`) on the capture.
- Output: full recognized text, copied to clipboard. Optional: a notification preview of the first ~80 chars.
- No network calls. Vision runs on-device.

#### 6.4.2 Color picker

- Standalone hotkey. Opens a small floating magnifier loupe under the cursor showing the pixel grid at high zoom and the current pixel color in hex.
- Click to commit; copies hex (default), RGB, or HSL (configurable) to clipboard.
- `Esc` cancels.
- The loupe is also reusable as part of the region picker for pixel-precise edge selection.

#### 6.4.3 Magnifier loupe

- Standalone hotkey for general-purpose pixel inspection (no capture taken).
- Floating window follows the cursor, dismissed with `Esc` or clicking elsewhere.

### 6.5 Editor / annotation

#### 6.5.1 Tools

- **Core annotations:** arrow, line, rectangle, ellipse, freehand pen, text, highlighter.
- **Redaction:** blur, pixelate, solid-fill redact (rectangle and freehand).
- **Step markers:** auto-incrementing numbered circles (1, 2, 3…) with configurable color.
- **Callouts:** speech-bubble–style label with tail pointing at a chosen pixel.
- **Crop:** rectangular crop. **No rotate** in v1.

For each tool: stroke color, fill, line width, font size where applicable. Styles persist across sessions per-tool.

Out of editor scope for v1: rotate, resize, drop shadow, rounded corners, background fills, image filters, watermarks.

#### 6.5.2 When the editor opens

- **Region mode:** the editor is the overlay (§6.1). Annotations are drawn live before/during region selection. The pipeline's `Open in editor` action, if present, is implicitly satisfied by the overlay step. The capture is already-annotated when the pipeline continues.
- **Window / fullscreen modes:** the editor is a post-capture window. The pipeline pauses on the `Open in editor` action; the editor opens with the captured bitmap, the user annotates and crops, and "Done" closes the editor and resumes the pipeline. The window provides the same toolset as the overlay.

#### 6.5.3 Editor controls

- Toolbar with all tools.
- Undo / redo (`⌘Z` / `⇧⌘Z`).
- Done / Cancel buttons. Cancel halts the pipeline; Done resumes it.
- Keyboard shortcuts for each tool (single-letter: `A` arrow, `R` rectangle, `T` text, `B` blur, `C` crop, `N` numbered marker, etc. — final assignments TBD in design).

### 6.6 Pipeline (post-capture actions)

#### 6.6.1 Configuration

- One **global pipeline** in settings, edited as an ordered list of actions.
- Each capture mode (region / window / fullscreen) may override the global pipeline. Override modes:
  - **Use global** (default).
  - **Replace** with a mode-specific pipeline.
  - **Insert/skip specific actions** (e.g., window mode skips `Open in editor`).

#### 6.6.2 Action catalogue

| Action | Inputs | Output |
|---|---|---|
| Open in editor | bitmap | edited bitmap |
| Copy image to clipboard | bitmap | — |
| Save to disk | bitmap, filename template, target directory, format | local file path |
| Upload to destination | bitmap or file path, destination ref | URL |
| Copy URL to clipboard | URL (from previous upload) | — |
| Run shell command | command template, file path, URL | exit code |
| Open in app | file path, app bundle ID | — |

#### 6.6.3 Execution semantics

- Pipeline runs synchronously in user-action order.
- The image is held in memory as the canonical artifact between steps. `Save to disk` produces a file path that subsequent steps can reference. `Upload` produces a URL.
- A failed action halts the pipeline and shows a failure notification (§9.4).
- The `Run shell command` action receives the latest file path as `$1` (or `$MACSHOT_PATH`) and the latest URL (if any) as `$2` (or `$MACSHOT_URL`). Standard output is logged to the macshot log; exit codes other than 0 are treated as failure.

### 6.7 Filename templates

ShareX-style token syntax. Tokens supported in v1:

| Token | Expansion |
|---|---|
| `%y` | 4-digit year |
| `%mo` | 2-digit month |
| `%d` | 2-digit day |
| `%h` | 2-digit hour (24h) |
| `%mi` | 2-digit minute |
| `%s` | 2-digit second |
| `%ms` | 3-digit millisecond |
| `%counter` | per-folder auto-incrementing counter, zero-padded to N digits (N configurable) |
| `%window` | active window's title (sanitized: alphanumerics and `-_`, others replaced with `_`) |
| `%app` | active window's application name |
| `%mode` | `region` / `window` / `fullscreen` |
| `%host` | machine hostname |
| `%user` | logged-in user shortname |
| `%uuid` | UUIDv4 |
| `%rand:N` | N-character random alphanumeric |

Default template: `Screenshot_%y-%mo-%d_%h-%mi-%s.png`

Validation: the settings UI live-previews the template against synthetic values and rejects templates that would yield empty strings.

### 6.8 File format

- **PNG** is the default output for all pipeline actions that need a bitmap.
- Per-pipeline override to **JPEG** (quality 1–100) or **HEIC** (quality 1–100).
- WebP is **not** in v1.
- Captures are always taken and held in memory in a lossless format; encoding happens at the `Save to disk` / `Upload` step.

### 6.9 Upload destinations

#### 6.9.1 S3-compatible

- Endpoint URL, region, bucket, access key, secret key, optional path prefix.
- Public-read ACL toggle.
- Custom CDN/public URL template (e.g., `https://cdn.example.com/{key}`) — substituted for the S3 endpoint when forming the returned URL.
- Optional server-side encryption header.

#### 6.9.2 SFTP / FTP / WebDAV

- Host, port, username, password or SSH key path (SFTP only), remote directory.
- Custom public URL template (typically the HTTP-facing URL of the same server).
- For SFTP: known-hosts handling (auto-accept on first connect with a confirmation prompt; reject on mismatch thereafter).

#### 6.9.3 Custom HTTP uploader (ShareX-compatible)

- Imports ShareX `.sxcu` JSON files directly (drag onto settings, file picker, or paste JSON).
- Supports the ShareX subset:
  - `RequestMethod` (POST / PUT)
  - `RequestURL`
  - `Headers`
  - `Parameters`
  - `Body` (`MultipartFormData`, `Binary`, `JSON`, `FormURLEncoded`)
  - `FileFormName`
  - `URL` / `ThumbnailURL` / `DeletionURL` response templates
  - JSON response parsing via `{json:path.to.field}` and regex via `{regex:0|1}`
- Token expansion in URLs / headers / bodies using the same filename template tokens (§6.7) plus `{response}` / `{json:...}` for response references in nested template positions.

Compatibility tested against a representative set of community `.sxcu` files (Zipline, Chibisafe, Lolisafe, Pomf, Bunny Storage). A list of known-compatible servers ships in the docs.

#### 6.9.4 Destination management

- Destinations live in settings as a named list.
- Secrets (access keys, passwords) are stored in the macOS Keychain, not in the JSON config file. Export-config (§7.4) excludes secrets by default and offers an opt-in for an encrypted bundle.

---

## 7. Settings, Storage, and Configuration

### 7.1 Settings UI

- Opened from the menu bar item's "Settings…" option.
- Sections: General, Hotkeys, Capture, Editor, Pipeline, Destinations, Filenames, Advanced.
- Live preview where applicable (filename template, color picker output format).

### 7.2 Storage location

- Config file: `~/Library/Application Support/macshot/config.json` (plain JSON, human-editable).
- Secrets: macOS Keychain under service `dev.macshot.app` (Open Design Question: final bundle ID).
- Logs: `~/Library/Logs/macshot/macshot.log` (rotated; 5MB × 5 files).

### 7.3 No history index

- Captured images are written to disk by the `Save to disk` pipeline action. macshot does **not** maintain a separate history database.
- Find past captures via Finder / Spotlight on the configured save directory.
- The menu bar dropdown shows recent **file paths** of the last ~10 saved captures as a convenience (read from a small recents list in config, not a full DB).

### 7.4 Export and import

- "Export config…" writes a JSON bundle (optionally with secrets, optionally encrypted with a passphrase) for backup or move to another Mac.
- "Import config…" reads the bundle and replaces current settings, with a confirmation diff.

### 7.5 No cloud sync in v1

- Settings live locally. Users who want sync use a dotfile manager pointing at the config file.

---

## 8. Invocation Surface

### 8.1 Global hotkeys

- Each capture mode and utility has a user-rebindable system-wide hotkey.
- Conflict detection: settings UI warns if a chosen hotkey is in use by another macshot binding or a known macOS system shortcut.
- Default bindings TBD in design pass. (Open Design Question.)
- Hotkeys registered via Carbon `RegisterEventHotKey` or `MASShortcut`-style abstraction over the modern Symbolic Hotkeys API.

### 8.2 Menu bar item

- Always-visible monochrome template icon that adapts to light/dark menu bar.
- Click reveals dropdown:
  - Capture Region, Capture Window, Capture Fullscreen
  - Pick Color, Magnifier
  - Extract Text from Clipboard (post-v1; see §13)
  - Recent saves (last ~10, each opens the file in Finder; "Reveal" submenu for parent directory)
  - Settings…
  - Quit macshot
- No floating thumbnail / shelf in v1.

### 8.3 No dock-only mode

- The app keeps a dock icon. Menu bar item is the primary invocation surface; dock icon provides the main window when needed.
- `LSUIElement` is `false`.

### 8.4 No CLI, no URL scheme, no Shortcuts integration in v1

- Deferred. (See §13.)

---

## 9. UX Specifics

### 9.1 Onboarding (first launch)

A guided wizard that the user can skip but should not need to:

1. Welcome screen — what macshot is, link to docs.
2. Permission grants, one per screen, with "Open System Settings" button and a live status indicator:
   - **Screen Recording** (required for capture)
   - **Accessibility** (required for global hotkeys)
3. Default save folder picker (defaults to `~/Pictures/macshot/`).
4. Quick hotkey setup — accept defaults or rebind the three capture-mode hotkeys.
5. Optional: configure first upload destination (with skip).
6. Optional: enable Launch at Login.
7. Done — "Try it now" button triggers the Region capture.

### 9.2 Launch at login

- Toggle in settings (default: off).
- Implemented via `SMAppService` (macOS 13+).

### 9.3 Menu bar icon behavior

- Template image, auto-adapts to light/dark menu bar.
- No animation, no badge counts. Static.

### 9.4 Notifications

- Native macOS notifications (`UNUserNotificationCenter`) on **both success and failure**.
- Success notification: thumbnail of the capture, "Reveal in Finder" and "Copy URL" actions.
- Failure notification: error summary, "Show Details" action that opens the log viewer.
- Notifications can be disabled globally in Settings → General; no per-action toggle in v1.

### 9.5 Capture feedback

- On a successful capture, macshot plays a subtle system sound and briefly flashes the captured display (white overlay fading over ~180 ms).
- Both fire-and-forget immediately after the capture is taken; they do not block save or upload.
- v1 ships with the macOS system "Tink" sound. A custom shutter sound bundled with the app is a candidate for a later release.
- A toggle to disable feedback lives in Settings → General (TBD; not in the very first slice).

---

## 10. Platform, Distribution, and Operations

### 10.1 Target platform

- **macOS Tahoe (latest) only.**
- **Apple Silicon (arm64) only.** No Intel build, no universal binary.
- This excludes a non-trivial slice of installed Macs by design. Tradeoff: smaller binary, fewer code paths, full access to the newest ScreenCaptureKit and SwiftUI APIs without legacy fallbacks.

### 10.2 Tech stack

- **Swift** + **SwiftUI** for settings, onboarding, and editor chrome.
- **AppKit** where SwiftUI gaps require it (menu bar item, overlay window, drag-to-select region).
- **ScreenCaptureKit** for all screen and window capture.
- **Vision** for OCR.
- **Combine / async-await** for pipeline orchestration.
- **CryptoKit** + **Keychain Services** for secret storage and Sparkle EdDSA verification.
- Third-party Swift packages allowed via SwiftPM. Initial expected list: Sparkle (updates), an S3 client, an SFTP client, optionally `swift-log`.

### 10.3 Signing and notarization

- **Apple Developer ID** signing.
- **Notarized** via `xcrun notarytool` in CI.
- **Hardened runtime** enabled.
- **Unsandboxed.** The "Run shell command" pipeline action and arbitrary save destinations require this.

### 10.4 Distribution

- Direct download as a notarized `.dmg` from the project's release page.
- Releases hosted on the self-hosted GitLab instance's Releases feature.
- Optional: a Homebrew tap (post-v1).

### 10.5 Updates

- **Sparkle** integrated, EdDSA-signed appcasts.
- Appcast XML and `.dmg` artifacts served from the self-hosted GitLab Releases endpoint.
- Update channels: stable only in v1. (Beta channel post-v1.)
- Updates default to "check automatically, prompt before download" — fully user-controllable.

### 10.6 macOS permissions required

| Permission | Required for | Granted via |
|---|---|---|
| Screen Recording | All captures | System Settings → Privacy & Security |
| Accessibility | Global hotkey listening | System Settings → Privacy & Security |
| Input Monitoring | (Not required in v1 — hotkeys use the Accessibility-gated API) | — |
| Notifications | Capture success/failure notifications | First-run prompt |

The onboarding wizard surfaces each grant explicitly.

---

## 11. Non-Functional Requirements

### 11.1 Performance

- Region capture overlay must appear within **100 ms** of the hotkey firing on an M2-class machine — anything slower defeats the keyboard-driven workflow.
- Fullscreen capture (single 5K display) → bitmap-in-memory within **150 ms**.
- The frozen-screen snapshot used in the region overlay must be visually indistinguishable from the live screen (no scaling artifacts, full Retina resolution).
- Idle CPU and memory: the menu bar app should sit at < 0.1% CPU and < 50 MB resident memory when no capture is in progress.

### 11.2 Privacy

- **Zero telemetry.** No analytics, no crash reporting service, no usage stats, no opt-in.
- The only network calls the app makes are:
  1. Sparkle update checks against the configured appcast URL.
  2. Uploads to destinations the user has configured.
- Logs are local-only and never transmitted.
- A "Privacy" section in the Settings UI and README explicitly lists every network endpoint the app contacts.

### 11.3 Accessibility (v1 minimum, deferred polish)

v1 explicitly **defers full accessibility support**. This is a known tradeoff. v1 commits to:

- Standard SwiftUI controls (which inherit baseline VoiceOver labels).
- No reliance on custom-drawn controls without labels for primary actions.

Not in v1:

- Audited VoiceOver labels.
- Editor keyboard navigation parity.
- Reduce Motion / Increase Contrast honoring throughout the editor.

These are tracked as post-v1 work. The team acknowledges that retrofitting accessibility is harder than baking it in; this is an accepted risk for shipping speed.

### 11.4 Localization

- **English-only at launch.**
- All user-facing strings routed through `NSLocalizedString` / SwiftUI `LocalizedStringKey` so future contributions can add languages without touching call sites.
- A `Localizable.xcstrings` catalog is part of the repo from day one.

### 11.5 Reliability

- The pipeline executes in a transaction-like manner: if any action fails, the user is notified with enough context to retry or diagnose.
- A capture that succeeds but whose pipeline fails on `Upload` leaves the bitmap available — clicking "Retry" in the failure notification reruns the failing action with the same bitmap (held in memory for ~60s after capture for this purpose).
- All filesystem writes use safe-write patterns (write to `.tmp` adjacent file, rename on success).

---

## 12. Open-Source and Project

### 12.1 License

- **MIT** for application code.
- Third-party packages retain their own licenses; a `THIRD_PARTY_LICENSES.md` ships with each release.

### 12.2 Repository

- Self-hosted **GitLab** instance.
- Code, issues, MRs, CI, container registry, and releases all on the same instance.
- Public-read access; contributions via merge request from forks.

### 12.3 CI / release pipeline

- GitLab CI runners on Apple Silicon hardware (self-hosted or macOS-cloud runners).
- Per-MR: build + unit tests + SwiftLint.
- Per-tag: build + sign + notarize + staple + generate Sparkle appcast entry + upload to GitLab Releases.
- Signing secrets (Developer ID certificate, notarytool API key, Sparkle EdDSA private key) live in GitLab CI variables, scoped to protected branches/tags.

### 12.4 Contribution model

- Open contributions via merge request.
- No CLA in v1; contributors retain copyright, license to project under MIT.
- A `CONTRIBUTING.md` lays out: code style, commit message conventions, how to run the app locally, how to run the test suite.

### 12.5 Versioning

- Semantic versioning (`MAJOR.MINOR.PATCH`).
- v1.0.0 ships when the §6 functional requirements are complete and §11 NFRs are met.

---

## 13. Out of Scope for v1 / Roadmap

Explicitly **not** in v1, but tracked as candidates for future releases:

### High likelihood post-v1

- **Video and GIF recording** (with system audio and microphone).
- **Scrolling capture.**
- **Timed capture** and **repeat last capture.**
- **Pin to screen** (floating always-on-top capture preview).
- **CLI** (`macshot capture region --output ...`).
- **URL scheme** (`macshot://capture/region`).
- **Shortcuts.app actions** and **Services menu** integration.
- **Accessibility polish** — VoiceOver audit, full keyboard navigation, Reduce Motion compliance.
- **Additional editor tools:** rotate, resize, drop shadow / rounded corners / wallpaper export.
- **Localization** beyond English.

### Lower likelihood / speculative

- **Imgur / public anonymous hosts** as built-in destinations.
- **Webcam overlay**, **keystroke overlay**, **click animations** during recording.
- **Cloud sync** of settings.
- **Homebrew Cask** distribution.
- **iCloud / cross-Mac config sync.**
- **Plugin system** for custom pipeline actions written in Swift / shell / external binaries (the `Run shell command` action already covers most cases).

---

## 14. Open Design Questions

These need answers during the design pass before implementation begins:

1. **Default hotkey assignments** for the three capture modes, color picker, and magnifier. Need to pick keys that don't clash with macOS defaults or common app shortcuts.
2. **Bundle identifier** — `dev.macshot.app`? `com.macshot.app`? Affects Keychain access groups and Sparkle update identity. Bikeshed-worthy but needs a decision before first release.
3. **OCR invocation:** standalone hotkey, pipeline action, post-capture editor button, or all three?
4. **Window shadow inclusion** in window-mode captures — per-capture toggle, global setting, or always-include?
5. **Editor cancel semantics in region mode** — `Esc` cancels the entire capture, but what about a separate "discard annotations, keep region" affordance?
6. **Per-display Retina scale handling** in the filename template — separate `%scale` token, or implicit in `%mode`?
7. **Where to draw the line on `.sxcu` compatibility** — full ShareX feature parity is large; need a "v1 compatible subset" formal spec and a published test vector list.

---

## 15. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| ScreenCaptureKit performance regression in a future Tahoe point release breaks the 100 ms overlay target | Low–Med | Profile each macOS release; fallback path to `CGDisplayStream` if needed (already deprecated, but works). |
| `.sxcu` ecosystem ambiguities cause user-visible breakage | Med | Publish a "supported subset" spec; ship test vectors; explicit error messages on unsupported features. |
| Deferring accessibility makes later retrofit expensive | Med–High | Use stock SwiftUI controls where possible; avoid custom-drawn primary actions; keep the editor's tool surface small in v1. |
| Self-hosted GitLab availability is a single point of failure for releases | Med | Mirror release artifacts to a second static host (Cloudflare R2 / S3) for failover; document the failover URL in Sparkle appcast as a backup. |
| Power-user-only positioning yields a small audience | Accepted | Goal is depth over breadth; not optimizing for download counts. |
| Unsandboxed + `Run shell command` action is a vector for malicious config sharing | Med | Importing a config that contains `Run shell command` actions surfaces a clear confirmation dialog showing every command before activation. |

---

## 16. Success Criteria for v1

v1 ships when **all** of the following are true:

1. Region, window, and fullscreen captures work on a fresh macOS Tahoe install.
2. The region overlay annotation flow (§6.1) is implemented and meets the 100 ms appearance target.
3. The seven pipeline actions (§4.3) are implemented and configurable via the Settings UI.
4. All three destination types (S3-compatible, SFTP/FTP/WebDAV, custom HTTP) work end-to-end against at least one real server each, verified by integration tests.
5. ShareX `.sxcu` import works for the published "supported subset" test vector set.
6. OCR and color picker utilities work.
7. The app is signed, notarized, and updates via Sparkle from the self-hosted GitLab Releases endpoint.
8. Zero network calls are made from the running app except (a) Sparkle update checks and (b) user-initiated uploads. Verified by traffic capture.
9. The repository has a CONTRIBUTING.md, README, license file, and CI pipeline that produces a notarized artifact on tag.
