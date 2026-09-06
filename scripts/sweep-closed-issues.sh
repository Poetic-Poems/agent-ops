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
# For every merged pull request labelled `pr_label` that names an issue `N`
# still open, this closes issue `N` with a comment carrying the merge
# evidence — the PR number, its merge commit, and when it merged — instead
# of leaving the tombstone that keeps a finished item selectable forever
# (issue #240). A PR names its issue two ways, either sufficing:
#
#   - the `<!-- agent-ops:closes-issue item=N -->` marker
#     (`prompts/implementer.md` Procedure step 2; requirement 23b);
#   - failing that, a head branch of exactly `agent/<N>` — the name the
#     Script itself mints for a work order whose item is a bare issue number
#     (`claim_branch_for`, agent-cycle.sh), the `issues` and `tech-debt`
#     sources alike since D15 as revised (#869/#875/#879), and for nothing
#     else, so it needs no model to have
#     remembered anything. Without this fallback, the Implementer forgetting
#     the marker blinded the sweep and the CI check together — the two
#     defences failing on the same omission they exist to catch.
#
# One thing it deliberately will not touch: an issue GitHub reports
# `state_reason: "reopened"`. Somebody reopened that issue after it was
# closed, which is the same answer requirement 34k's `void-object-closed`
# record protects on the other sweep — a human's re-open must win, and must
# not be undone on the hour, every hour, with a comment each time.
#
# Bounded, deliberately: only the `pr_search_limit` most recently updated
# merged, labelled pull requests are examined per call. Older strays are the
# ordinary case requirement 25a now prevents from recurring, and a fleet
# running this every cycle catches a fresh miss within the hour regardless —
# an unbounded historical scan would cost every cycle to protect against a
# defect this same change makes rare.
#
# This same listing is also one of the item-lifecycle record's two merge
# observation points (requirement 49, issue #595) — the other is
# `lib/landing.sh`'s own arm site, which only ever sees a landing this
# pipeline itself armed. A pull request a human merged by hand, or one
# GitHub's merge queue resolved well after `lib/landing.sh` last looked, has
# no other site that ever notices — this sweep already lists every merged,
# labelled pull request fleet-wide, every stand-down, and already resolves
# each back to its item (marker or branch), so it costs nothing further to
# emit a `merge-observed` action for every one it can identify. Bounded the
# same way the close action already is by `pr_search_limit`, and de-duplicated
# per node against `<state-dir>/sweep-closed-issues-merge-observed-seen.json`
# — a small, self-pruning list of `repo#number` keys this call has already
# reported, replaced wholesale each run with exactly the current window's own
# keys, so a pull request re-emits nothing once it ages out of
# `pr_search_limit` and nothing is retained past what could ever be re-seen.
# Cross-node duplication is not de-duplicated here — several nodes each
# noticing the same merge is the ordinary fleet-wide shape every other record
# in `docs/FLOW-SCHEMA.md` already tolerates, reduced first-wins-by-`ts` by
# whatever reads the union log.
#
# Output: one JSON object per action on stdout —
#   {"action":"closed","issue":198,"pr_number":206,"pr_url":…}
#   {"action":"merge-observed","pr_number":206,"pr_url":…,"item":"198","merge_sha":…}
#   {"action":"warning","detail":…}
#   {"action":"deferred","remaining":N}
# The caller logs them; this script logs nothing itself. Exit 0 unless the
# arguments are unusable.
#
# Usage: sweep-closed-issues.sh <owner/repo> <node-name> <cycle-id> [state-dir]
# STATE-DIR defaults to this repository's own `config.json`'s `state_dir`;
# pass it explicitly to keep a test hermetic against a real home directory.
# Environment: SWEEP_GH overrides `gh` (tests stub it); AGENT_OPS_CONFIG
# overrides the config path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
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
state_dir_override="${4:-}"
if [[ -z "$slug" || -z "$node_name" || -z "$cycle_id" ]]; then
  echo "usage: sweep-closed-issues.sh <owner/repo> <node-name> <cycle-id> [state-dir]" >&2
  exit 64
fi

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

pr_label="$(cfg '.pr_label')"

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

if [[ -n "$state_dir_override" ]]; then
  state_dir="$state_dir_override"
else
  state_dir="$(expand_home "$(cfg '.state_dir')")"
fi
merge_observed_seen_file="$state_dir/sweep-closed-issues-merge-observed-seen.json"

# The bounded window (see header): recently-updated merged PRs only.
pr_search_limit=30
# The per-run action cap, for the same reason sweep-orphan-branches.sh caps
# itself: a backlog surfaces a few per cycle rather than as a comment flood.
max_actions=3

actions=0
deferred=0

merge_observed_seen='[]'
[[ -n "$state_dir" && -s "$merge_observed_seen_file" ]] && \
  merge_observed_seen="$(jq -c 'if type == "array" then . else [] end' "$merge_observed_seen_file" 2>/dev/null || echo '[]')"
merge_observed_window=()

warn() { jq -nc --arg d "$1" '{action: "warning", detail: $d}'; }  # warn DETAIL

[[ -n "$pr_label" ]] || { warn "no pr_label configured — nothing to sweep"; exit 0; }

prs_json="$("$GH" pr list -R "$slug" --state merged --label "$pr_label" \
  --json number,body,url,mergeCommit,headRefName --limit "$pr_search_limit" 2>/dev/null)" || prs_json=""
if [[ -z "$prs_json" ]]; then
  warn "could not list merged, $pr_label-labelled pull requests — skipping this pass"
  exit 0
fi

while IFS=$'\t' read -r pr_number pr_url item merge_sha named_by; do
  # bash's `read` collapses consecutive IFS-whitespace delimiters (tab
  # included) even when IFS is narrowed to just "\t", so a genuinely empty
  # middle field shifts every field after it — jq emits "-" rather than ""
  # for "no marker" specifically to keep the five columns aligned.
  [[ "$item" == "-" ]] && item=""
  [[ -n "$pr_number" && -n "$item" ]] || continue

  # The item-lifecycle record's merge instant (requirement 49, issue #595) —
  # see this script's own header. Never subject to `max_actions`: it costs no
  # GitHub call (everything it needs is already in `prs_json`), and gating it
  # on the same cap as the close action would silently drop merge evidence
  # behind whatever backlog of issue-closes this pass is also working through.
  merge_key="$slug#$pr_number"
  merge_observed_window+=("$merge_key")
  if ! jq -e --arg k "$merge_key" 'index($k) != null' <<<"$merge_observed_seen" >/dev/null 2>&1; then
    jq -nc --argjson n "$pr_number" --arg url "$pr_url" --arg item "$item" --arg sha "$merge_sha" \
      '{action: "merge-observed", pr_number: $n, pr_url: $url, item: $item}
       + (if $sha == "" or $sha == "-" then {} else {merge_sha: $sha} end)'
  fi

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

  # Open *because a human reopened it* is not the state this sweep is for.
  # GitHub sets `state_reason: "reopened"` on an issue reopened after a close,
  # and "still open" alone cannot tell that apart from "never closed" — so
  # without this the sweep would close, every hour, exactly the issue somebody
  # deliberately reopened, and comment each time. That is the failure
  # requirement 34k's own one-shot rule (`void-object-closed`) exists to
  # prevent on the other sweep; the same principle applies here, and this is
  # how it is spelled with no per-item record to keep: the reopen *is* the
  # record, and it is GitHub's, not ours.
  state_reason="$(jq -r '.state_reason // ""' <<<"$issue_json" 2>/dev/null)"
  if [[ "$state_reason" == "reopened" ]]; then
    warn "issue #$item (named by PR #$pr_number) was reopened after a close — leaving it to whoever reopened it"
    continue
  fi

  if [[ "$named_by" == "branch" ]]; then
    evidence="pull request #$pr_number ($pr_url) is the merged work order for \
this issue — its head branch is \`agent/$item\`, the name this pipeline mints \
only for issue-sourced work\
$( [[ -n "$merge_sha" && "$merge_sha" != "-" ]] && printf ' (merged as %s)' "$merge_sha" )\
 — but its body carried neither the \`agent-ops:closes-issue\` marker nor a \
closing keyword, so GitHub never auto-closed it."
  else
    evidence="pull request #$pr_number ($pr_url) carries the \
\`agent-ops:closes-issue item=$item\` marker and is merged\
$( [[ -n "$merge_sha" && "$merge_sha" != "-" ]] && printf ' (%s)' "$merge_sha" )\
, but never triggered GitHub's own closing-keyword auto-close."
  fi

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
done < <(jq -r '.[]
  | ((.body // "") | capture("<!-- agent-ops:closes-issue item=(?<n>[0-9]+) -->")? // null) as $marker
  | ((.headRefName // "") | capture("^agent/(?<n>[0-9]+)$")? // null) as $branch
  | [
    (.number|tostring),
    .url,
    (if $marker then $marker.n elif $branch then $branch.n else "-" end),
    (.mergeCommit.oid // "-"),
    (if $marker then "marker" elif $branch then "branch" else "-" end)
  ] | @tsv' <<<"$prs_json" 2>/dev/null || true)

if (( deferred > 0 )); then
  jq -nc --argjson n "$deferred" '{action: "deferred", remaining: $n}'
fi

# Replace the seen-file wholesale with exactly this run's own window (see
# this script's own header) — self-pruning, and small: bounded by
# `pr_search_limit` regardless of how long the sweep has run. An unwritable
# state_dir must not fail the sweep — the caller still gets this run's
# actions — but it must not go unnoticed either: silently losing the write
# means every merge-observed key re-emits, up to `pr_search_limit` of them,
# on every future stand-down until the directory is writable again.
if [[ -n "$state_dir" ]]; then
  if ! { mkdir -p "$state_dir" 2>/dev/null && \
      printf '%s\n' "${merge_observed_window[@]:-}" | jq -R 'select(length > 0)' | jq -sc 'unique' \
        > "$merge_observed_seen_file.tmp" 2>/dev/null && \
      mv "$merge_observed_seen_file.tmp" "$merge_observed_seen_file" 2>/dev/null; }; then
    warn "failed to write merge-observed seen-file $merge_observed_seen_file — merge-observed events may re-emit on future runs"
  fi
fi

exit 0
