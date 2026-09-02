#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

app_path="$repo_root/dist/macshot-debug.app"

swift build
"$script_dir/bundle.sh" debug

# `pkill` only sends the signal; the old instance can still be alive (and hold
# its LaunchServices registration) when `open` runs, which then fails with
# error -600. Wait for it to actually be gone.
pkill -x macshot || true
for _ in $(seq 50); do
    if ! pgrep -x macshot >/dev/null; then break; fi
    sleep 0.1
done
if pgrep -x macshot >/dev/null; then
    echo "run.sh: a macshot instance is still running 5s after pkill; not launching" >&2
    exit 1
fi

# `open` detaches, and has been seen to exit 0 on a launch that never produced a
# process, so check both its status and that the app is actually up. Otherwise
# the tail below looks like a normal run with no app behind it.
if ! open "$app_path"; then
    echo "run.sh: open failed for $app_path" >&2
    exit 1
fi
for _ in $(seq 50); do
    if pgrep -x macshot >/dev/null; then break; fi
    sleep 0.1
done
if ! pgrep -x macshot >/dev/null; then
    echo "run.sh: $app_path did not start" >&2
    exit 1
fi

# `open` detaches the app, so Ctrl+C on the tail below would otherwise leave it
# running. Installed only after the launch so a failed build never kills an
# instance this run didn't start.
trap 'pkill -x macshot || true' EXIT

log_file="$HOME/Library/Logs/macshot/macshot.log"
mkdir -p "$(dirname "$log_file")"
touch "$log_file"
tail -f "$log_file"
