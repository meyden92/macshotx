# Pure SwiftPM toolchain — no Xcode project

macshot is built with SwiftPM (`Package.swift`) and shell scripts (`scripts/bundle.sh`, `run.sh`, `release.sh`); there is no `.xcodeproj` and Xcode is never opened. The app bundle is assembled by hand: `swift build` output + a handwritten Info.plist + `codesign`. Development happens in any editor via sourcekit-lsp.

## Considered Options

- **Rewrite in Rust/Go** — rejected. The dissatisfaction was with the Xcode toolchain, not Swift: there was no pull toward another language, and a rewrite wouldn't remove Apple's machinery (SDK, codesign, TCC, bundling) anyway. ~52% of the codebase is AppKit/SwiftUI UI that would need FFI bindings, and capture (ScreenCaptureKit async), OCR (macOS 15+ Vision), and launch-at-login are Swift-only APIs requiring a Swift shim regardless — so "no Swift" was never actually achievable, and native feel is non-negotiable.
- **Keep XcodeGen + xcodebuild** — rejected; the project-generation dance and xcodebuild opacity were the pain being cured.

## Consequences

- The split into `MacshotCore` (library, testable) + `macshot` (thin executable calling `MacshotApp.main()`) exists because SwiftPM tests import a library; `@main` was replaced by an explicit `main.swift`.
- Info.plist keys live in `scripts/bundle.sh` — version bumps happen there, not in a project file.
- Dev builds sign with the "Apple Development" identity when present (ad-hoc fallback) because TCC ties the Screen Recording grant to the signing identity; releases sign with Developer ID + hardened runtime and are notarized locally (`scripts/release.sh`) — no CI, distribution via personal website as a `.dmg`, not the App Store.
