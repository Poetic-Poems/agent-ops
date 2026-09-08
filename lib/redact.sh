#!/usr/bin/env bash
#
# lib/redact.sh — the token/home-path patterns scripts/publish-dashboard.sh
# and scripts/state-sync.sh both need before they hand content to a
# less-trusted destination: the dashboard's own published payload (a
# semi-public, Tailscale-exposed surface) and whatever this node pushes to
# the private state-mirror repository (agent-ops#966) — the second
# destination is lower-risk than the first, but carries far more raw
# content (whole transcripts, never rotated), so it gets the same pass
# rather than none at all.
#
# One pattern set in one place: a shape added here to catch a new secret
# reaches both call sites the same day, instead of whichever one someone
# remembers to edit.

REDACT_SED_ARGS=(
  -E
  -e "s#/home/[A-Za-z0-9._-]+#~#g"
  -e "s#/Users/[A-Za-z0-9._-]+#~#g"
  -e "s#gh[pousr]_[A-Za-z0-9]{16,}#[REDACTED-TOKEN]#g"
  -e "s#github_pat_[A-Za-z0-9_]{20,}#[REDACTED-TOKEN]#g"
  -e "s#sk-(ant-|proj-)?[A-Za-z0-9_-]{16,}#[REDACTED-TOKEN]#g"
  -e "s#(Bearer|token) [A-Za-z0-9._~+/-]{16,}#\1 [REDACTED-TOKEN]#g"
)

# redact — filter stdin to stdout, applying the pattern set above.
redact() {
  sed "${REDACT_SED_ARGS[@]}"
}

# redact_file <path> — apply the same pattern set to a file in place. The
# patterns only ever touch path- and token-shaped substrings, never JSON
# syntax, so a JSON/JSON-Lines file staying parseable after this holds for
# every shape these patterns match.
redact_file() {
  sed -i "${REDACT_SED_ARGS[@]}" "$1"
}
