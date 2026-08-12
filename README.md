# macshot

A free and open-source screenshot utility for macOS power users — ShareX-grade
automation, native and keyboard-driven. See [PRD.md](PRD.md) for the full
product specification.

> **Status:** Alpha. The v1 feature set from the PRD is implemented; release
> engineering (signing, notarization, Sparkle updates, CI) is still pending.

## Features

- **Region capture with overlay annotation** — the screen freezes, you draw
  arrows, shapes, text, callouts, step markers, blur/pixelate/solid redactions
  *before* selecting the region, then crop and go. Undo/redo, per-annotation
  move/resize, per-tool styles that persist across sessions.
- **Window capture** (hover-to-pick, optional shadow) and **fullscreen capture**.
- **Post-capture editor** for window/fullscreen modes with the same toolset
  plus rectangular crop.
- **Pipeline automation** — an ordered, per-mode-overridable action list runs
  after every capture: open in editor, copy image, save to disk, upload,
  copy URL, run shell command, open in app, extract text (OCR). Failures halt
  the pipeline with a Retry notification (bitmap held for 60 s).
- **Filename templates** — ShareX-style tokens: `%y %mo %d %h %mi %s %ms
  %counter %window %app %mode %host %user %uuid %rand:N`, with live preview
  and per-folder counters.
- **Upload destinations** — S3-compatible (AWS, R2, B2, MinIO, Wasabi; SigV4
  signed, no SDK), WebDAV, SFTP (SSH-key auth), FTP, and ShareX-compatible
  custom HTTP uploaders with `.sxcu` import (`{json:…}`, `{regex:…}`,
  `{response}` response parsing). Secrets live in the macOS Keychain.
- **Utilities** — on-device OCR (Apple Vision), color picker with magnifier
  loupe (hex/RGB/HSL), standalone magnifier.
- **Global hotkeys** for every capture mode and utility, rebindable in
  Settings (no Accessibility permission needed).
- **Zero telemetry.** The only network calls are uploads you configure.
- Config is plain JSON at `~/Library/Application Support/macshot/config.json`;
  export/import as a bundle, optionally with secrets and passphrase encryption.
  Logs rotate at `~/Library/Logs/macshot/`.

### Default hotkeys

| Action | Hotkey |
|---|---|
| Capture region | ⌃⇧4 |
| Capture window | ⌃⇧5 |
| Capture fullscreen | ⌃⇧3 |
| Pick color | ⌃⇧C |
| Magnifier | ⌃⇧M |

## Requirements

- macOS Tahoe (26) or later
- Apple Silicon (arm64) only
- [Xcode 16](https://developer.apple.com/xcode/) or newer
- [SwiftLint](https://github.com/realm/SwiftLint) (optional) — `brew install swiftlint`

## Building

```sh
swift build

# Build, bundle, launch, and tail the app log
scripts/run.sh
```

## Running tests

```sh
swift test
```

## Creating a release

```sh
scripts/release.sh
```

## Permissions

| Permission | Needed for |
|---|---|
| Screen Recording | all captures, color picker, magnifier |
| Notifications | success/failure banners with actions |

Global hotkeys use the system hotkey API and need no Accessibility grant.

## Repository layout

```
.
├── PRD.md                  # Product requirements document
├── Package.swift           # SwiftPM package definition
├── Sources/MacshotCore/    # Application library source
├── Sources/macshot/        # Executable entry point
├── scripts/                # Bundle, run, and release workflows
└── Tests/macshotTests/     # Unit tests
```

## Not yet implemented (release engineering)

Sparkle auto-update and the GitLab CI release pipeline (PRD §10/§12.3)
require release infrastructure (appcast hosting and CI runners) and are
tracked separately. Local signing and notarization use `scripts/release.sh`.

## License

[MIT](LICENSE)
