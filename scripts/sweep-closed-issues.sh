#!/usr/bin/env bash
#
# scripts/sweep-closed-issues.sh — close an issue whose implementing PR
# already merged but never triggered GitHub's own auto-close (requirement
# 17c), for one repository.
#
# requirement 25a's CI check stops a *new* PR from merging without a real
# closing keyword. This is the sweep for what already got through before
# that check existed, and the defence-in-depth backstop for whatever gets
# through some way this check does not cover (a body edited after the check
# ran and before merge, a squash-merge commit message that drops the body
# entirely on some other host, …): PR #206 said "Implements #198" instead of
# "Closes #198", #198's own fix merged in 8h37m, and the issue then sat open
# for three more days — selected and voided twice — before a human closed it
# by hand. Nothing but a human noticing ever would have.
#
# For every merged pull request labelled `pr_label` that carries the
# `<!-- agent-ops:closes-issue item=N -->` marker (`prompts/implementor.md`
# Procedure step 2; requirement 23b) whose issue `N` is still open, this
# closes issue `N` with a comment carrying the merge evidence — the PR
# number, its merge commit, and when it merged — instead of leaving the
# tombstone that keeps a finished item selectable forever (issue #240).
#
# Bounded, deliberately: only the `pr_search_limit` most recently updated
# merged, labelled pull requests are examined per call. Older strays are the
# ordinary case requirement 25a now prevents from recurring, and a fleet
# running this every cycle catches a fresh miss within the hour regardless —
# an unbounded historical scan would cost every cycle to protect against a
# defect this same change makes rare.
#
# Output: one JSON object per action on stdout —
#   {"action":"closed","issue":198,"pr_number":206,"pr_url":…}
#   {"action":"warning","detail":…}
#   {"action":"deferred","remaining":N}
# The caller logs them; this script logs nothing itself. Exit 0 unless the
# arguments are unusable.
#
# Usage: sweep-closed-issues.sh <owner/repo> <node-name> <cycle-id>
# Environment: SWEEP_GH overrides `gh` (tests stub it); AGENT_OPS_CONFIG
# overrides the config path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
GH="${SWEEP_GH:-gh}"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

slug="${1:-}"
node_name="${2:-}"
cycle_id="${3:-}"
if [[ -z "$slug" || -z "$node_name" || -z "$cycle_id" ]]; then
  echo "usage: sweep-closed-issues.sh <owner/repo> <node-name> <cycle-id>" >&2
  exit 64
fi

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

pr_label="$(cfg '.pr_label')"

# The bounded window (see header): recently-updated merged PRs only.
pr_search_limit=30
# The per-run action cap, for the same reason sweep-orphan-branches.sh caps
# itself: a backlog surfaces a few per cycle rather than as a comment flood.
max_actions=3

actions=0
deferred=0

warn() { jq -nc --arg d "$1" '{action: "warning", detail: $d}'; }  # warn DETAIL

[[ -n "$pr_label" ]] || { warn "no pr_label configured — nothing to sweep"; exit 0; }

prs_json="$("$GH" pr list -R "$slug" --state merged --label "$pr_label" \
  --json number,body,url,mergeCommit --limit "$pr_search_limit" 2>/dev/null)" || prs_json=""
if [[ -z "$prs_json" ]]; then
  warn "could not list merged, $pr_label-labelled pull requests — skipping this pass"
  exit 0
fi

while IFS=$'\t' read -r pr_number pr_url item merge_sha; do
  # bash's `read` collapses consecutive IFS-whitespace delimiters (tab
  # included) even when IFS is narrowed to just "\t", so a genuinely empty
  # middle field shifts every field after it — jq emits "-" rather than ""
  # for "no marker" specifically to keep the four columns aligned.
  [[ "$item" == "-" ]] && item=""
  [[ -n "$pr_number" && -n "$item" ]] || continue

  if (( actions >= max_actions )); then
    deferred=$(( deferred + 1 ))
    continue
  fi

  issue_json="$("$GH" api "repos/$slug/issues/$item" 2>/dev/null)" || issue_json=""
  if [[ -z "$issue_json" ]]; then
    warn "could not read issue #$item (named by PR #$pr_number) — leaving it alone"
    continue
  fi
  state="$(jq -r '.state // ""' <<<"$issue_json" 2>/dev/null)"
  [[ "$state" == "open" ]] || continue

  evidence="pull request #$pr_number ($pr_url) carries the \
\`agent-ops:closes-issue item=$item\` marker and is merged\
$( [[ -n "$merge_sha" ]] && printf ' (%s)' "$merge_sha" )\
, but never triggered GitHub's own closing-keyword auto-close."

  comment_body="$(pipeline_comment_header script "$node_name")

This issue's implementing pull request has merged, but its body never
carried a GitHub closing keyword, so GitHub never auto-closed it. $evidence

Closing it now so it stops being offered as open work.

$(pipeline_comment_marker "$cycle_id" script)"

  if "$GH" issue close "$item" -R "$slug" --comment "$comment_body" >/dev/null 2>&1; then
    jq -nc --argjson issue "$item" --argjson pr "$pr_number" --arg url "$pr_url" \
      '{action: "closed", issue: $issue, pr_number: $pr, pr_url: $url}'
    actions=$(( actions + 1 ))
  else
    warn "could not close issue #$item (named by PR #$pr_number)"
  fi
done < <(jq -r '.[] | [
    (.number|tostring),
    .url,
    ((.body // "") | (capture("<!-- agent-ops:closes-issue item=(?<n>[0-9]+) -->")? // {n:"-"}) | .n),
    (.mergeCommit.oid // "-")
  ] | @tsv' <<<"$prs_json" 2>/dev/null || true)

if (( deferred > 0 )); then
  jq -nc --argjson n "$deferred" '{action: "deferred", remaining: $n}'
fi

exit 0
