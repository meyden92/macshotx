#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release] [version]" >&2
        exit 1
        ;;
esac

# Releases pass the version from the git tag; local dev builds get a placeholder.
version="${2:-0.0.0}"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "error: version must be dot-separated digits, got '$version'" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

bin_path="$(swift build -c "$configuration" --show-bin-path)"

# What separates a dev bundle from a release one:
#
# - Sparkle checks in the background only in release bundles; dev builds carry
#   the placeholder version 0.0.0 and would otherwise nag about every release.
#   The manual "Check for Updates…" menu item works in both.
# - Dev builds get their own bundle identifier. TCC keeps one grant per
#   identifier and pins it to the code signature, and dev builds are signed with
#   the local Apple Development cert while releases are signed with Developer ID
#   — under a shared identifier every switch between the two invalidates the
#   other's Screen Recording grant, and it can only be repaired by removing and
#   re-adding the app in System Settings by hand. Separate identifiers means one
#   grant per channel, each stable for as long as its own signature is.
#   Everything the two deliberately share — the config, the log, the keychain
#   service, the annotation pasteboard type — is addressed by a fixed path or
#   string, not by the bundle identifier, so it stays shared.
# - The dev bundle is a differently named file, macshot-debug.app. macOS names
#   an app in the Screen Recording list after its file name — neither
#   CFBundleName nor CFBundleDisplayName is consulted, verified with Finder and
#   LaunchServices — so two bundles both called macshot.app show up as two
#   identical "macshot" rows with no way to tell which grant belongs to which
#   build. The names inside the plist still set what notifications and menus
#   call it.
if [[ "$configuration" == release ]]; then
    auto_update_check="<true/>"
    bundle_id="dev.macshot.app"
    bundle_name="macshot"
    app_name="macshot"
else
    auto_update_check="<false/>"
    bundle_id="dev.macshot.app.debug"
    bundle_name="macshot (Debug)"
    app_name="macshot-debug"
fi

app_path="$repo_root/dist/$app_name.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
install -m 755 "$bin_path/macshot" "$app_path/Contents/MacOS/macshot"
install -m 644 "$repo_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"

# Sparkle is a binary SwiftPM dependency; SwiftPM stages the framework next to
# the built executable, the bundle carries it in Contents/Frameworks. The extra
# rpath makes the @rpath install name resolve there (the build's @loader_path
# rpath finds nothing inside the bundle).
rm -rf "$app_path/Contents/Frameworks"
mkdir -p "$app_path/Contents/Frameworks"
ditto "$bin_path/Sparkle.framework" "$app_path/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$app_path/Contents/MacOS/macshot"

cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>macshot</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$bundle_name</string>
    <key>CFBundleDisplayName</key>
    <string>$bundle_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 macshot contributors</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>macshot needs Screen Recording permission to capture screenshots and screen contents.</string>
    <key>SUFeedURL</key>
    <string>https://github.com/meyden92/macshotx/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>ao+uR1w5RYBatqQnXZXiWt/UtCsU8QIcvGytxSDOlds=</string>
    <key>SUEnableAutomaticChecks</key>
    $auto_update_check
</dict>
</plist>
PLIST

identities="$(security find-identity -v -p codesigning 2>&1 || true)"
printf '%s\n' "$identities"
if printf '%s\n' "$identities" | grep -q '"Apple Development'; then
    codesign --force --deep --sign "Apple Development" \
        --entitlements "$script_dir/macshot.entitlements" "$app_path"
else
    codesign --force --deep --sign - "$app_path"
    echo "warning: no Apple Development signing identity found; Screen Recording permission may re-prompt after rebuilds because TCC ties the grant to the signing identity." >&2
fi
