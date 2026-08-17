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
app_path="$repo_root/dist/macshot.app"
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

# Sparkle checks in the background only in release bundles; dev builds carry
# the placeholder version 0.0.0 and would otherwise nag about every release.
# The manual "Check for Updates…" menu item works in both.
if [[ "$configuration" == release ]]; then
    auto_update_check="<true/>"
else
    auto_update_check="<false/>"
fi

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
    <string>dev.macshot.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>macshot</string>
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
