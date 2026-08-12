# Contributing to macshot

Contributions are welcome via merge request. There is no CLA — you retain
copyright and license your contribution under the project's [MIT license](LICENSE).

## Running locally

```sh
swift build
scripts/run.sh
```

`scripts/run.sh` builds and bundles the app, launches it, and tails its local
log. The app needs the **Screen Recording** permission the first time it
captures.

## Running the test suite

```sh
swift test
```

Tests use Swift Testing (`@Test` / `#expect`). UI behavior in the region
picker is tested by synthesizing `NSEvent`s against a hosted view — follow
the patterns in `Tests/macshotTests/MacshotTests.swift`.

## Creating a release

```sh
scripts/release.sh
```

The release script requires a Developer ID Application certificate and the
`macshot-notary` notarytool keychain profile.

## Code style

- Swift 6, strict concurrency. Most UI types are `@MainActor`.
- Match the style of the file you are editing.
- No new third-party dependencies without prior discussion in an issue.
- Pure logic (template expansion, request building, response parsing) should
  be testable without network or UI — keep it separated from I/O.

## Commit messages

Short imperative summary line (≤ 72 chars), optional body explaining *why*.

## Project structure

- `Package.swift` defines the SwiftPM library, executable, and test targets.
- `scripts/bundle.sh` assembles and signs the app bundle; `scripts/run.sh` and
  `scripts/release.sh` provide the development and release workflows.
- Configuration model lives in `AppConfig.swift`; every field decodes with a
  default so hand-edited configs never fail wholesale.
- Capture flow: `CaptureService` → (`RegionPicker` / `WindowPicker` /
  `EditorWindow`) → `PipelineRunner` → actions (`ImageEncoder`,
  `UploadService`, `OCRService`, …) → `Notifier`.
