#!/usr/bin/env bash
#
# serve-dashboard.sh — optional loopback-only web server for the dashboard.
# Use this only if your browser refuses to load data.js over a file:// URL;
# otherwise scripts/open-dashboard.sh (file://) needs no server at all.
#
# Usage: serve-dashboard.sh [port] [bind-address]
#
# Binds 127.0.0.1 by default: the page answers on this machine's loopback and on
# no network. The bind address is a setting only so that a container can keep
# that same guarantee — a server bound to the *container's* loopback is
# reachable from nothing, so deploy/docker/compose.yaml's `local` profile binds
# 0.0.0.0 inside the container and publishes the port on the host's loopback
# alone (127.0.0.1:<port>:8787). Widening the bind on a host is a different
# thing entirely, and is never what this script is for.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
port="${1:-8787}"
bind="${2:-127.0.0.1}"

expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
state_dir="$(expand_home "$(jq -r '.state_dir' "$SCRIPT_DIR/config.json")")"
dir="$state_dir/dashboard"

[[ -f "$dir/index.html" ]] || "$SCRIPT_DIR/scripts/publish-dashboard.sh" || true
[[ -d "$dir" ]] || { echo "serve-dashboard: nothing to serve at $dir" >&2; exit 1; }

echo "Serving $dir at http://$bind:$port  (Ctrl-C to stop)"
cd "$dir" && exec python3 -m http.server "$port" --bind "$bind"
