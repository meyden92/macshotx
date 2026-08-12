#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

swift build
"$script_dir/bundle.sh" debug
pkill -x macshot || true
open "$repo_root/dist/macshot.app"

log_file="$HOME/Library/Logs/macshot/macshot.log"
mkdir -p "$(dirname "$log_file")"
touch "$log_file"
tail -f "$log_file"
