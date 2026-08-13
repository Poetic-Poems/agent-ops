#!/usr/bin/env bash
#
# gather-workflow-basenames.sh — map a repository's workflow ids to the
# basename the Co-Ordinator mints a `failed-runs` item id from (requirement
# 19: "`item` is `failed-run-` plus the workflow file's basename without
# extension").
#
# Given a repo slug, print one JSON object:
#
#   {"ok": true, "basenames": {"123": "ci", "456": "sync-framework"}}
#
# `gather-source-state.sh`'s own `workflows` digest carries each workflow's
# *id* and its latest conclusion (`{"w": 123, "c": "failure"}`) — the id, not
# the file it came from, because the id is all the no-op fingerprint needs.
# Requirement 34n's liveness retirement needs the other half: which basename a
# still-failing id names, so a void `failed-run-<basename>` can be tested for
# whether that basename's workflow is still failing this cycle. This is the
# one read that answers it, kept separate from gather-source-state.sh because
# it is needed only for the (usually empty) residue of still-unretired
# `failed-run-` void entries — see requirement 34n in
# docs/IMPLEMENTATION-PIPELINE-SPEC.md.
#
# Usage: gather-workflow-basenames.sh <owner/repo>
#
# `ok: false` on any API failure — auth, rate limit, network, an unparseable
# body — never on a legitimately empty workflow list, which is `ok: true` with
# an empty `basenames`. Requirement 34n's own "unknown is not gone" rule reads
# `ok` before trusting the map for anything: an unsampled repo must decide no
# retirement, not "no workflows".
#
# Never exits non-zero: it always prints a valid object. A gatherer that
# aborted the cycle would make a tidy-up a reliability risk.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-workflow-basenames.sh <owner/repo>" >&2
  printf '{"ok":false,"basenames":{}}'
  exit 0
fi

out=""
if out="$(gh api --paginate "repos/$slug/actions/workflows" \
          --jq '[.workflows[] | {id: (.id | tostring), path}]' 2>/dev/null)" \
   && [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
  jq -nc --argjson w "$out" \
    '{ok: true, basenames: (reduce $w[] as $e ({}; .[$e.id] = ($e.path | sub("^.*/"; "") | sub("\\.ya?ml$"; ""))))}'
else
  printf '{"ok":false,"basenames":{}}'
fi
