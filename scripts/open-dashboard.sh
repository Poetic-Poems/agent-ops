#!/usr/bin/env bash
#
# open-dashboard.sh — regenerate the dashboard and open it in your browser.
# Pass --no-github to skip the (slower) live GitHub fetch.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$SCRIPT_DIR/scripts/publish-dashboard.sh" "$@" || true

expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
state_dir="$(expand_home "$(jq -r '.state_dir' "$SCRIPT_DIR/config.json")")"
html="$state_dir/dashboard/index.html"
[[ -f "$html" ]] || { echo "open-dashboard: not generated yet: $html" >&2; exit 1; }

echo "Dashboard: $html"
if command -v wslview >/dev/null 2>&1; then
  wslview "$html"
elif command -v explorer.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
  explorer.exe "$(wslpath -w "$html")" || true   # explorer.exe often returns non-zero even on success
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$html"
else
  echo "Open this file in your browser:  file://$html"
fi
