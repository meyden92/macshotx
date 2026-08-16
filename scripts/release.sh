#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

# The release version, normally the git tag without its leading "v".
version="${1:-0.0.0}"

identities="$(security find-identity -v -p codesigning 2>&1 || true)"
developer_id="$(printf '%s\n' "$identities" | awk '/"Developer ID Application/{print $2; exit}')"
if [[ -z "$developer_id" ]]; then
    cat >&2 <<'INSTRUCTIONS'
error: no "Developer ID Application" signing identity was found.
One-time setup: install a Developer ID Application certificate from Xcode's Accounts settings, then rerun this script.
INSTRUCTIONS
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "error: create-dmg is not installed. Run: brew install create-dmg" >&2
    exit 1
fi

# Notarization credentials. CI hands us an App Store Connect API key through the
# environment; local runs fall back to the keychain profile that
# `notarytool store-credentials` writes.
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
    notary_args=(--keychain-profile macshot-notary)
    if ! xcrun notarytool history "${notary_args[@]}" >/dev/null 2>&1; then
        cat >&2 <<'INSTRUCTIONS'
error: the notarytool keychain profile "macshot-notary" is not configured.
One-time setup: create an app-specific password, then run:
xcrun notarytool store-credentials macshot-notary --apple-id <your-apple-id> --team-id P3VNJ55K48 --password <app-specific-password>
INSTRUCTIONS
        exit 1
    fi
fi

swift build -c release
"$script_dir/bundle.sh" release "$version"

app_path="$repo_root/dist/macshot.app"
dmg_path="$repo_root/dist/macshot.dmg"
codesign --force --deep --options runtime --sign "$developer_id" \
    --entitlements "$script_dir/macshot.entitlements" "$app_path"

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

# Notarize and staple the app itself before packaging it. Stapling needs a
# ticket issued for this exact bundle, so the app gets its own submission; the
# ticket is then a plain file inside the bundle that survives being copied into
# the image. Without it, first launch depends on Gatekeeper reaching Apple to
# look the ticket up, which fails offline.
ditto -c -k --keepParent "$app_path" "$work_dir/macshot.zip"
xcrun notarytool submit "$work_dir/macshot.zip" "${notary_args[@]}" --wait
xcrun stapler staple "$app_path"

# create-dmg copies everything in the source folder into the image and adds the
# Applications drop link itself, so the staging folder holds only the app.
dmg_staging="$work_dir/dmg"
mkdir -p "$dmg_staging"
cp -R "$app_path" "$dmg_staging/macshot.app"

# Finder picks the matching representation out of a multi-image TIFF, which is
# how the background stays sharp on Retina displays.
background="$work_dir/background.tiff"
tiffutil -cathidpicheck "$repo_root/Resources/dmg/background.png" \
    "$repo_root/Resources/dmg/background@2x.png" -out "$background"

# Icon positions must match the empty zones the background art leaves for them.
# --codesign signs the image; an unsigned DMG is rejected by Gatekeeper
# assessment (`spctl -a -t open`) even once a ticket has been stapled to it.
rm -f "$dmg_path"
create-dmg \
    --volname macshot \
    --background "$background" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon macshot.app 150 185 \
    --app-drop-link 450 185 \
    --hide-extension macshot.app \
    --no-internet-enable \
    --codesign "$developer_id" \
    "$dmg_path" "$dmg_staging"

xcrun notarytool submit "$dmg_path" "${notary_args[@]}" --wait
xcrun stapler staple "$dmg_path"
