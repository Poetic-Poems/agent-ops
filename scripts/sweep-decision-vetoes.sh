#!/usr/bin/env bash
#
# scripts/sweep-decision-vetoes.sh — find a `pw::decision` decision-log issue
# a human reopened (a veto, agent-ops#937) and act on it, for one repository.
#
# `decide-tactical` (agent-ops#936) lets the pipeline take a tactical decision
# on its own authority rather than paging a human. `lib/enabler.sh`'s `decide`
# verdict files the decision's own durable record as a closed `pw::decision`
# issue (`create_decision_log_issue`) — a log, not an ask. Reopening that
# issue is the veto this sweep watches for: the human's one-click way to undo
# a decision after the fact, the D18 pattern (a log a human can scan, a lever
# they can pull) applied to decisions the way requirement 36a already applies
# it to escalations.
#
# For each open `pw::decision` issue this repository carries that this sweep
# has not already processed (the caller pre-filters stdin against
# `decision_vetoes_processed_items`, lib/cycle-state.sh — the `decision-vetoed`
# events already on the log, keyed on the log issue's own number so a later
# decision under a fresh log issue is never mistaken for one already
# answered):
#
#   - the original item is not terminal (still open, or its implementing pull
#     request is still open): a `needs-refinement` action is reported (the
#     caller records the block — `record_needs_refinement_block` reads and
#     writes cycle globals no standalone script has), a comment is posted on
#     the item's own thread (issue-shaped items only) naming the veto and the
#     log issue, and any open pull request for the item is commented on and
#     flipped back to draft;
#   - the original item is terminal (merged or closed): a fresh
#     "revisit: <decision title>" issue is filed, labelled `bug`, quoting the
#     log issue's own veto comment, and the log issue itself gets one comment
#     saying so.
#
# Either way, one `vetoed` action is always reported first — this is what the
# caller logs `decision-vetoed` from, and what future calls' own exclusion set
# is built from.
#
# The original item's repo/ref are read from the log issue body's own
# machine marker (`enabler_decision_log_body`, lib/enabler.sh):
#   <!-- agent-ops:decision-log item=<item> repo=<repo> -->
# A log issue missing this marker is not one this pipeline filed — reported
# as a warning, left alone.
#
# Output: one JSON object per action on stdout —
#   {"action":"vetoed","repo":…,"item":…,"issue_number":…,"issue_url":…,"by":…,"terminal":true|false}
#   {"action":"needs-refinement","repo":…,"item":…,"reason":…,"missing":…,"evidence":…}
#   {"action":"comment-posted","repo":…,"item":…,"url":…}
#   {"action":"pr-flipped-to-draft","repo":…,"item":…,"pr_url":…}
#   {"action":"revisit-filed","repo":…,"item":…,"number":…,"url":…}
#   {"action":"warning","detail":…}
#   {"action":"deferred","remaining":N}
# The caller logs them; this script logs nothing itself. Exit 0 unless the
# arguments are unusable.
#
# Usage: sweep-decision-vetoes.sh <owner/repo> <node-name> <cycle-id>
# Stdin: a JSON array of this repo's already-processed vetoes, the shape
#   `decision_vetoes_processed_items` (lib/cycle-state.sh) produces, filtered
#   by the caller to this repo — [{"repo":"acme/widgets","item":"501"}], where
#   `item` is the *log issue's own number*, not the original work item's ref.
# Environment: SWEEP_GH overrides `gh` (tests stub it); AGENT_OPS_CONFIG
# overrides the config path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
GH="${SWEEP_GH:-gh}"

# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

slug="${1:-}"
node_name="${2:-}"
cycle_id="${3:-}"
if [[ -z "$slug" || -z "$node_name" || -z "$cycle_id" ]]; then
  echo "usage: sweep-decision-vetoes.sh <owner/repo> <node-name> <cycle-id>" >&2
  exit 64
fi

processed_json="$(cat)"
jq -e 'type == "array"' <<<"$processed_json" >/dev/null 2>&1 || processed_json='[]'

# The per-run action cap, for the same reason every other sweep here caps
# itself: a backlog surfaces a few per cycle, never as a flood of re-blocks.
max_actions=3
actions=0
deferred=0

warn() { jq -nc --arg d "$1" '{action: "warning", detail: $d}'; }  # warn DETAIL

decision_issues_json="$("$GH" issue list -R "$slug" --label "pw::decision" --state open \
  --json number,url,title,body 2>/dev/null)" || decision_issues_json=""
if [[ -z "$decision_issues_json" ]]; then
  exit 0
fi

already_json="$(jq -c --arg r "$slug" '[.[] | select(.repo == $r) | .item]' <<<"$processed_json" 2>/dev/null || printf '[]')"

while IFS=$'\t' read -r number url title marker_item marker_repo; do
  [[ -n "$number" ]] || continue

  if jq -e --arg n "$number" 'index($n)' <<<"$already_json" >/dev/null 2>&1; then
    continue
  fi

  if [[ -z "$marker_item" || "$marker_item" == "-" || -z "$marker_repo" || "$marker_repo" == "-" ]]; then
    warn "decision-log issue #$number in $slug carries no agent-ops:decision-log marker — leaving it alone"
    continue
  fi
  if [[ "$marker_repo" != "$slug" ]]; then
    warn "decision-log issue #$number in $slug names repo $marker_repo in its own marker — leaving it alone"
    continue
  fi

  if (( actions >= max_actions )); then
    deferred=$(( deferred + 1 ))
    continue
  fi

  by="$("$GH" api "repos/$slug/issues/$number/events" --paginate 2>/dev/null \
    | jq -rs '[.[][] | select(.event == "reopened")] | last | .actor.login // ""' 2>/dev/null || true)"

  # Terminal iff the original item's own GitHub object (an issue) is closed,
  # or (a non-issue item) its implementing pull request has merged or closed.
  # An item this cannot classify at all — non-numeric, no matching pull
  # request found either — fails open toward "not terminal": a needless
  # re-block costs one wasted needs-refinement cycle, where mis-calling an
  # active item terminal would silently drop the veto's own effect on it.
  terminal="false"
  if [[ "$marker_item" =~ ^[0-9]+$ ]]; then
    item_state="$("$GH" issue view "$marker_item" -R "$slug" --json state --jq '.state' 2>/dev/null || true)"
    [[ "$item_state" == "CLOSED" ]] && terminal="true"
  fi

  prs_json="$("$GH" pr list -R "$slug" --state open --json number,url,body,headRefName 2>/dev/null || printf '[]')"
  pr_url="$(jq -r --arg item "$marker_item" '
    [ .[] | select(((.body // "") | test("agent-ops:closes-issue item=" + $item + "([^0-9]|$)"))
                   or (.headRefName == ("agent/" + $item))) ] | first.url // empty' \
    <<<"$prs_json" 2>/dev/null || true)"

  if [[ "$terminal" != "true" && -z "$pr_url" && ! "$marker_item" =~ ^[0-9]+$ ]]; then
    merged_prs_json="$("$GH" pr list -R "$slug" --state merged --json number,url,body,headRefName --limit 30 2>/dev/null || printf '[]')"
    if jq -e --arg item "$marker_item" '
         any(.[]; ((.body // "") | test("agent-ops:closes-issue item=" + $item + "([^0-9]|$)"))
                   or (.headRefName == ("agent/" + $item)))' \
         <<<"$merged_prs_json" >/dev/null 2>&1; then
      terminal="true"
    fi
  fi

  jq -nc --arg r "$slug" --arg i "$marker_item" --argjson n "$number" --arg u "$url" \
    --arg by "$by" --argjson t "$terminal" \
    '{action: "vetoed", repo: $r, item: $i, issue_number: $n, issue_url: $u, by: $by, terminal: $t}'
  actions=$(( actions + 1 ))

  if [[ "$terminal" != "true" ]]; then
    jq -nc --arg r "$slug" --arg i "$marker_item" \
      --arg reason "a human vetoed the pipeline's decision by reopening $url" \
      --arg missing "the owner's own decision, posted as a comment on $url before it is closed again" \
      --arg evidence "decision-log issue $url was reopened" \
      '{action: "needs-refinement", repo: $r, item: $i, reason: $reason, missing: $missing, evidence: $evidence}'

    if [[ "$marker_item" =~ ^[0-9]+$ ]]; then
      comment_body="$(pipeline_comment_header script "$node_name")

The pipeline's own tactical decision for this item was vetoed: $url was
reopened. The item is blocked again until the owner's own decision, posted as
a comment there, is the decision of record — closing that issue again is what
releases it.

$(pipeline_comment_marker "$cycle_id" script)"
      if item_comment_url="$("$GH" issue comment "$marker_item" -R "$slug" --body "$comment_body" 2>/dev/null)" \
           && [[ -n "$item_comment_url" ]]; then
        jq -nc --arg r "$slug" --arg i "$marker_item" --arg u "$item_comment_url" \
          '{action: "comment-posted", repo: $r, item: $i, url: $u}'
      else
        warn "could not post the veto comment on $slug#$marker_item (decision-log issue $url)"
      fi
    fi

    if [[ -n "$pr_url" ]]; then
      pr_comment_body="$(pipeline_comment_header script "$node_name")

The pipeline's own tactical decision behind this pull request was vetoed:
$url was reopened. Flipping this back to draft so nothing lands on a vetoed
decision — the owner's own decision, posted as a comment on $url, is what
should guide what happens here next.

$(pipeline_comment_marker "$cycle_id" script)"
      "$GH" pr comment "$pr_url" --body "$pr_comment_body" >/dev/null 2>&1 \
        || warn "could not post the veto comment on pull request $pr_url"
      "$GH" pr ready "$pr_url" --undo >/dev/null 2>&1 || true
      pr_draft_flag="$("$GH" pr view "$pr_url" --json isDraft --jq '.isDraft' 2>/dev/null || true)"
      if [[ "$pr_draft_flag" == "true" ]]; then
        jq -nc --arg r "$slug" --arg i "$marker_item" --arg u "$pr_url" \
          '{action: "pr-flipped-to-draft", repo: $r, item: $i, pr_url: $u}'
      else
        warn "could not flip pull request $pr_url back to draft after the veto of decision-log issue $url"
      fi
    fi
  else
    veto_comment="$("$GH" issue view "$number" -R "$slug" --json comments \
      --jq '.comments[-1].body // ""' 2>/dev/null || true)"
    [[ -n "$veto_comment" ]] || veto_comment="(no comment was given when this issue was reopened)"

    revisit_title="revisit: $title"
    revisit_body="$(pipeline_comment_header script "$node_name")

The pipeline's own tactical decision for this item was vetoed after the item
had already gone terminal (merged or closed): $url was reopened, but there is
no open work left to re-block. The veto's own comment:

> $veto_comment

$(pipeline_comment_marker "$cycle_id" script)"
    revisit_raw="$("$GH" issue create -R "$slug" --title "$revisit_title" --body "$revisit_body" \
      --label bug 2>/dev/null || true)"
    revisit_url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$revisit_raw" | tail -n1 || true)"
    if [[ -n "$revisit_url" ]]; then
      revisit_number="${revisit_url##*/}"
      jq -nc --arg r "$slug" --arg i "$marker_item" --argjson n "$revisit_number" --arg u "$revisit_url" \
        '{action: "revisit-filed", repo: $r, item: $i, number: $n, url: $u}'
      log_comment="$(pipeline_comment_header script "$node_name")

This decision's own item had already gone terminal by the time this veto was
noticed, so there is nothing left to re-block. Filed $revisit_url to revisit
the decision instead.

$(pipeline_comment_marker "$cycle_id" script)"
      "$GH" issue comment "$number" -R "$slug" --body "$log_comment" >/dev/null 2>&1 \
        || warn "could not comment on decision-log issue $url naming its revisit issue $revisit_url"
    else
      warn "could not file a revisit issue for the vetoed, terminal decision-log issue $url"
    fi
  fi
done < <(jq -r '.[]
  | ((.body // "") | capture("<!-- agent-ops:decision-log item=(?<i>[^ ]+) repo=(?<r>[^ ]+) -->")? // null) as $m
  | [ (.number|tostring), .url, .title, ($m.i // "-"), ($m.r // "-") ] | @tsv' \
  <<<"$decision_issues_json" 2>/dev/null || true)

if (( deferred > 0 )); then
  jq -nc --argjson n "$deferred" '{action: "deferred", remaining: $n}'
fi

exit 0
