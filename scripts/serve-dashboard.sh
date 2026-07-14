#!/usr/bin/env bash
#
# serve-dashboard.sh — optional loopback-only web server for the dashboard.
# Use this only if your browser refuses to load data.js over a file:// URL;
# otherwise scripts/open-dashboard.sh (file://) needs no server at all.
#
# Binds to 127.0.0.1 only — never exposed to the network. Usage: serve-dashboard.sh [port]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
port="${1:-8787}"

expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
state_dir="$(expand_home "$(jq -r '.state_dir' "$SCRIPT_DIR/config.json")")"
dir="$state_dir/dashboard"

[[ -f "$dir/index.html" ]] || "$SCRIPT_DIR/scripts/publish-dashboard.sh" || true
[[ -d "$dir" ]] || { echo "serve-dashboard: nothing to serve at $dir" >&2; exit 1; }

echo "Serving $dir at http://127.0.0.1:$port  (Ctrl-C to stop)"
cd "$dir" && exec python3 -m http.server "$port" --bind 127.0.0.1
