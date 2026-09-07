#!/usr/bin/env bash
#
# scripts/tech-debt-close-guard.sh — advisory check that a closed
# `pw::type:tech-debt` issue carries some evidence of its resolution (issue
# #877; D15 as revised, #869/#875/#879's "close-guard", the resolution-
# discipline mitigation for a tech-debt issue closed without a pull request).
#
# Since D15's revision, tech debt is a GitHub issue and its permanent record
# is the resolving pull request's `td-record` body block (requirement 25),
# written the moment the issue closes with a real closing keyword. That path
# is enforced deterministically by `.github/workflows/closing-keyword.yml`.
# This is the other path: an issue closed some other way — by hand, or
# `not_planned` — has no pull request to carry a record, so the only trace
# left is whatever the closer wrote at the time. This posts one comment
# naming what is missing when nothing was; it never reopens the issue,
# never relabels it, and never blocks anything — the check that follows a
# closed issue, not one that gates a merge.
#
# Two kinds of evidence, by `state_reason`:
#   - `completed` (or unset — GitHub's own default): a closing pull request
#     or commit the issue's own timeline names (its most recent
#     `ClosedEvent.closer`), or a comment already on the issue.
#   - `not_planned`: a comment already on the issue, stating why.
# Either requirement is satisfied by *any* comment already present — this
# does not read a comment's content, the same simplification
# `check-closing-keyword.sh` makes about a closing keyword's own wording.
# The guard's own past comments on the same issue never count as that
# comment: without excluding them, the first guarded close would leave a
# comment that silently satisfied every later close of the same issue.
#
# Idempotent per close: the comment it posts carries
# `<!-- agent-ops:td-close-guard closed_at=<issue's own closed_at> -->`, and a
# comment with that exact marker already present skips posting a second one —
# a workflow re-run must not double-comment on the same close. A later close
# of the same issue carries a different `closed_at` and is judged fresh.
#
# Usage:
#   tech-debt-close-guard.sh <repo-slug> <issue-number> <state-reason> <labels-csv> <closed-at>
#
# <state-reason>: "completed", "not_planned", or empty (treated as
#   "completed", GitHub's own default when a closer states none).
# <labels-csv>: the issue's label names, comma-separated; a labels list not
#   carrying `pw::type:tech-debt` is not this guard's concern and exits 0
#   without calling GitHub at all.
# <closed-at>: the issue's own `closed_at`, ISO-8601 — used only for the
#   idempotency marker above.
#
# GH_TOKEN (or gh's own login) needs `issues:write` on <repo-slug>. `GH`
# overrides the `gh` binary, for tests.
#
# Prints one JSON object on success and always exits 0 — a guard comment this
# script fails to post is not a broken close, the same "advisory, never
# fails its caller" contract scripts/release-td-branch.sh's own header states
# for the same reason:
#   {"issue": N, "action": "none", "reason": "<why nothing was needed>"}
#   {"issue": N, "action": "commented", "reason": "<what was missing>"}
#   {"issue": N, "action": "skipped", "reason": "guard already commented on this close"}
#   {"issue": N, "action": "warning", "reason": "<what was missing> (comment post failed)"}
# Exit 2 (usage) on missing/malformed arguments only.

set -uo pipefail

GH="${GH:-gh}"
MARKER_PREFIX='<!-- agent-ops:td-close-guard'

usage() {
  echo "usage: $(basename "$0") <repo-slug> <issue-number> <state-reason> <labels-csv> <closed-at>" >&2
  exit 2
}

[[ $# -eq 5 ]] || usage
slug="$1" number="$2" state_reason="$3" labels_csv="$4" closed_at="$5"
[[ -n "$slug" && "$number" =~ ^[0-9]+$ ]] || usage

emit() {  # emit ACTION REASON
  jq -nc --argjson n "$number" --arg a "$1" --arg r "$2" '{issue: $n, action: $a, reason: $r}'
}

# --- label filter: this guard has nothing to say about any other issue -----
is_tech_debt=0
IFS=',' read -ra labels <<<"$labels_csv"
for label in "${labels[@]}"; do
  [[ "$label" == "pw::type:tech-debt" ]] && { is_tech_debt=1; break; }
done
if (( ! is_tech_debt )); then
  emit "none" "not labelled pw::type:tech-debt"
  exit 0
fi

owner="${slug%%/*}" repo_name="${slug#*/}"

# --- every comment already on the issue, minus the guard's own past ones ---
# `--paginate --slurp` wraps every page (each itself an array) in one outer
# array; `add` (empty-safe) concatenates them into a single flat array of
# comment objects, never an error on zero pages.
#
# The `add` runs in a *separate* `jq`, never `gh`'s own `--jq`: gh refuses the
# two flags together ("the `--slurp` option is not supported with `--jq` or
# `--template`", gh 2.98.0), exiting 1 with empty stdout, which this call's own
# `[]` fallback would then read as "this issue has no comments at all" — issue
# #1116, where the same pairing had been silently disarming `lib/claim.sh`'s
# branch-claim listing. Here it would have cost both of requirement 25b's
# guarantees at once: a close carrying a perfectly good resolution comment
# would draw a guard comment anyway, and the idempotency check below, reading
# the same empty list, would post a second one on every workflow re-run.
comments_json="$("$GH" api "repos/$slug/issues/$number/comments" --paginate --slurp \
  2>/dev/null | jq -c 'add // []' 2>/dev/null)"
[[ -n "$comments_json" ]] || comments_json='[]'
real_comment_count="$(jq --arg m "$MARKER_PREFIX" \
  '[.[] | select(((.body // "") | startswith($m)) | not)] | length' \
  <<<"$comments_json" 2>/dev/null || echo 0)"
[[ "$real_comment_count" =~ ^[0-9]+$ ]] || real_comment_count=0
has_comment=0
(( real_comment_count > 0 )) && has_comment=1

# --- the not_planned path: a comment is the whole requirement --------------
if [[ "$state_reason" == "not_planned" ]]; then
  if (( has_comment )); then
    emit "none" "closed not planned with a reason comment present"
    exit 0
  fi
  missing_reason="closed as not planned with no comment explaining why"
else
  # --- the completed (or unset) path: a linked closer or a comment ---------
  # `closedByPullRequestsReferences` (`includeClosedPrs: true`, so a merged —
  # not just still-open — PR still counts) is the field GitHub itself keeps
  # for "what pull request's closing keyword closed this issue", and is what
  # this reads first: verified live against agent-ops#1226 (closed by the
  # squash-merge of #1227) that the seemingly more direct
  # `timelineItems(itemTypes:[CLOSED_EVENT]) { closer }` this used originally
  # reports `closer: null` for a squash-merged closing pull request — GitHub
  # does not always populate it — while `closedByPullRequestsReferences`
  # correctly named #1227 for the same issue. The `ClosedEvent.closer` read
  # stays as a fallback for the one shape the pull-request field cannot see:
  # a closing keyword in a plain commit, never routed through a pull request
  # at all — this repository's own branch protection rules it out, but not
  # every repository this guard may run in protects `main` the same way.
  # shellcheck disable=SC2016  # GraphQL's own $owner/$repo/$number, not the shell's.
  closer="$("$GH" api graphql -f query='
    query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){
        issue(number:$number){
          closedByPullRequestsReferences(first:1, includeClosedPrs:true){
            totalCount
          }
          timelineItems(last:1, itemTypes:[CLOSED_EVENT]){
            nodes{
              ... on ClosedEvent{
                closer{ __typename }
              }
            }
          }
        }
      }
    }' -f owner="$owner" -f repo="$repo_name" -F number="$number" \
    --jq '{pr: (.data.repository.issue.closedByPullRequestsReferences.totalCount // 0),
            commit: (.data.repository.issue.timelineItems.nodes[-1].closer.__typename == "Commit")}' \
    2>/dev/null || true)"

  linked_pr_count="$(jq -r '.pr // 0' <<<"${closer:-null}" 2>/dev/null || echo 0)"
  [[ "$linked_pr_count" =~ ^[0-9]+$ ]] || linked_pr_count=0
  linked_commit="$(jq -r '.commit // false' <<<"${closer:-null}" 2>/dev/null || echo false)"

  if (( linked_pr_count > 0 )); then
    emit "none" "closed via a linked pull request"
    exit 0
  fi
  if [[ "$linked_commit" == "true" ]]; then
    emit "none" "closed via a linked commit"
    exit 0
  fi
  if (( has_comment )); then
    emit "none" "closed completed with a resolution comment present"
    exit 0
  fi
  missing_reason="closed as completed with neither a linked pull request/commit nor a comment explaining the resolution"
fi

# --- guarded: post once per close, never twice for the same one ------------
marker="$MARKER_PREFIX closed_at=$closed_at -->"
if jq -e --arg m "$marker" 'any(.[]; (.body // "") | startswith($m))' \
  <<<"$comments_json" >/dev/null 2>&1; then
  emit "skipped" "guard already commented on this close"
  exit 0
fi

body_file="$(mktemp)" || { emit "warning" "$missing_reason (comment not posted: mktemp failed)"; exit 0; }
trap 'rm -f "$body_file"' EXIT
{
  printf '%s\n' "$marker"
  printf 'This tech-debt issue was %s.\n\n' "$missing_reason"
  printf 'A comment here (or, for a completed close, a pull request that names this issue with a real closing keyword) helps whoever finds this issue later.\n\n'
  printf 'This is an advisory notice only — nothing else happens because of it.\n'
} > "$body_file"

if "$GH" api "repos/$slug/issues/$number/comments" -F body="@$body_file" >/dev/null 2>&1; then
  emit "commented" "$missing_reason"
else
  emit "warning" "$missing_reason (comment post failed)"
fi
exit 0
