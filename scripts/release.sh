#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

identities="$(security find-identity -v -p codesigning 2>&1 || true)"
developer_id="$(printf '%s\n' "$identities" | awk '/"Developer ID Application/{print $2; exit}')"
if [[ -z "$developer_id" ]]; then
    cat >&2 <<'INSTRUCTIONS'
error: no "Developer ID Application" signing identity was found.
One-time setup: install a Developer ID Application certificate from Xcode's Accounts settings, then rerun this script.
INSTRUCTIONS
    exit 1
fi

if ! xcrun notarytool history --keychain-profile macshot-notary >/dev/null 2>&1; then
    cat >&2 <<'INSTRUCTIONS'
error: the notarytool keychain profile "macshot-notary" is not configured.
One-time setup: create an app-specific password, then run:
xcrun notarytool store-credentials macshot-notary --apple-id <your-apple-id> --team-id 6WRJ3A3ZM8 --password <app-specific-password>
INSTRUCTIONS
    exit 1
fi

swift build -c release
"$script_dir/bundle.sh" release

app_path="$repo_root/dist/macshot.app"
dmg_path="$repo_root/dist/macshot.dmg"
codesign --force --deep --options runtime --sign "$developer_id" \
    --entitlements "$script_dir/macshot.entitlements" "$app_path"

dmg_staging="$(mktemp -d)"
trap 'rm -rf -- "$dmg_staging"' EXIT
cp -R "$app_path" "$dmg_staging/macshot.app"
hdiutil create -volname macshot -srcfolder "$dmg_staging" -ov -format UDZO "$dmg_path"
xcrun notarytool submit dist/macshot.dmg --keychain-profile macshot-notary --wait
xcrun stapler staple dist/macshot.dmg
