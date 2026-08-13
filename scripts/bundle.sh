#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 1
        ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

bin_path="$(swift build -c "$configuration" --show-bin-path)"
app_path="$repo_root/dist/macshot.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
install -m 755 "$bin_path/macshot" "$app_path/Contents/MacOS/macshot"
install -m 644 "$repo_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
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
    <string>0.0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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
