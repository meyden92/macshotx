#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

swift build
"$script_dir/bundle.sh" debug
pkill -x macshot || true
open "$repo_root/dist/macshot-debug.app"

# `open` detaches the app, so Ctrl+C on the tail below would otherwise leave it
# running. Installed only after the launch so a failed build never kills an
# instance this run didn't start.
trap 'pkill -x macshot || true' EXIT

log_file="$HOME/Library/Logs/macshot/macshot.log"
mkdir -p "$(dirname "$log_file")"
touch "$log_file"
tail -f "$log_file"
