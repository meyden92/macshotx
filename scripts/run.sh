#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

app_path="$repo_root/dist/macshot-debug.app"
# Both channels install their executable as Contents/MacOS/macshot, so `pgrep -x
# macshot` would also match a release instance. Match the full path instead, to
# keep the checks below about this bundle only.
debug_proc="$app_path/Contents/MacOS/macshot"

swift build
"$script_dir/bundle.sh" debug

# `pkill` only sends the signal; the old instance can still be alive (and hold
# its LaunchServices registration) when `open` runs, which then fails with
# error -600. Wait for it to actually be gone.
pkill -x macshot || true
for _ in $(seq 50); do
    if ! pgrep -f "$debug_proc" >/dev/null; then break; fi
    sleep 0.1
done
if pgrep -f "$debug_proc" >/dev/null; then
    echo "run.sh: the previous debug instance did not exit; not launching" >&2
    exit 1
fi

# `open` detaches and returns before the app is up, so its exit status alone
# doesn't prove a process exists. Check both, or the tail below looks like a
# normal run with no app behind it.
if ! open "$app_path"; then
    echo "run.sh: open failed for $app_path" >&2
    exit 1
fi
for _ in $(seq 100); do
    if pgrep -f "$debug_proc" >/dev/null; then break; fi
    sleep 0.1
done
if ! pgrep -f "$debug_proc" >/dev/null; then
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
