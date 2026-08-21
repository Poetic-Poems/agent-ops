#!/usr/bin/env bash
#
# scripts/close-void-github-items.sh — act on a corroborated void by closing
# the GitHub object it names, instead of leaving a tombstone only this
# pipeline's own log can see (requirement 34k).
#
# A void (requirement 34c) already stops the item being selected again — but
# nothing before this closed the *object* the void is about, so an obsolete
# draft pull request or a superseded issue stayed open, visible to every
# human and every other tool that reads GitHub rather than this pipeline's
# log, and kept being re-derived void by cycle after cycle (issue #240:
# poetic-fiddle #190/#214 were re-derived void on 7+ separate cycles, never
# closed). This closes it, with the void's own reason and evidence as the
# comment, the moment the void exists — and never touches it again
# (`void-object-closed`, logged by the caller from this script's output, is
# how a later cycle knows not to re-check an item this already settled, even
# if a human reopens the object directly rather than through the
# `unvoid_label` this pipeline actually watches). When a pull request being
# closed this way already carries the human-applied `obsolete` label — the
# corroboration lib/void-guard.sh's `void_finishing_pr_reason` accepts in
# place of an empty diff for the `-abandoned-`/`-review-` shapes
# (TD-PPagop-26081308) — the close comment names it, re-checked live here
# rather than trusted from the void's own claim, so the close is auditable
# from the comment alone.
#
# Only the two id shapes that name a GitHub object at all (`lib/work-gone.sh`'s
# own definitions, reused rather than re-derived — requirement 34a):
#   a bare issue number       closes the issue, iff GitHub still reports it open
#   `pr-<n>-…`                closes the pull request, iff still open —
#                             *except* `pr-<n>-conflict-<head-sha>` and
#                             `pr-<n>-dequeued-<head-sha>`: those shapes say
#                             the *conflict* (or the dequeue) is gone, not the
#                             pull request, which stays a live PR of
#                             ours (requirement 34k). Closing it on this void
#                             would discard live work — it did, for real, to
#                             pull request #264 — so these two shapes are left
#                             alone exactly like a non-GitHub-object void
#                             (TD-PPagop-26080901, extended to `dequeued` by
#                             TD-PPagop-26081409). Its sibling shape,
#                             `pr-<n>-superseded-<head-sha>` (a Dependabot bump
#                             a newer open bump has made moot, requirement 3s),
#                             makes the opposite claim — the pull request
#                             itself is moot, not merely its conflict — so it
#                             is *not* excluded: it closes through the ordinary
#                             `pr-<n>-…` branch above like any other pull
#                             request void (TD-PPagop-26081304). No logic in
#                             this file distinguishes these shapes; the
#                             exclusion below matches `-conflict-` and
#                             `-dequeued-` alone.
# Every other void shape (a tech-debt register id, a review ref, a plan task
# id) names something that is not a GitHub object to close and is left alone
# here entirely.
#
# And only a void whose writer's verdict passes requirement 34d's
# corroboration guard — every stage, now that issue #243 made
# `void_guard_reason` the one path all three (`coordinator`, `enabler`,
# `implementer`) write `item-void` through. Before #243 the Implementer's and
# the Enabler's voids were the model's own unexamined claim — issue #240
# scoped this action to a void that "survives corroboration (WI-7)", and
# until #243 corroborated those two writers, acting on them would have let an
# unexamined "already done" close a live issue. The gate was on corroboration,
# not on the stage name, so once every writer earned it the gate simply opened
# to all three — a stage this script has never heard of (a future writer that
# does not go through the guard) still stops here, unrecognised.
#
# Usage: close-void-github-items.sh <owner/repo> <node-name> <cycle-id>
# Stdin: a JSON array of this repo's void candidates, each
#   {"item": "198", "detail": "…", "evidence": "…", "stage": "coordinator"}
# (the shape `void_items` in lib/cycle-state.sh already produces, filtered by
# the caller to this repo and to items requirement 34k's exclusion set —
# `void_object_closed_items` — has not already processed).
#
# Output: one JSON object per action on stdout —
#   {"action":"closed","item":"198","kind":"issue","closed_by":"sweep"}
#   {"action":"closed","item":"pr-205-abandoned-…","kind":"pull-request","number":205,"closed_by":"already"}
#   {"action":"warning","item":"198","detail":…}
#   {"action":"deferred","remaining":N}
# `closed_by: "already"` means the object was found already closed (by a
# human, or some other route) — still reported, so the caller logs
# `void-object-closed` and this item is never checked again. The caller logs
# every action; this script logs nothing itself. Exit 0 unless the arguments
# are unusable.
#
# Environment: SWEEP_GH overrides `gh` (tests stub it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
GH="${SWEEP_GH:-gh}"

# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/work-gone.sh
. "$SCRIPT_DIR/lib/work-gone.sh"

slug="${1:-}"
node_name="${2:-}"
cycle_id="${3:-}"
if [[ -z "$slug" || -z "$node_name" || -z "$cycle_id" ]]; then
  echo "usage: close-void-github-items.sh <owner/repo> <node-name> <cycle-id>" >&2
  exit 64
fi

candidates_json="$(cat)"
jq -e 'type == "array"' <<<"$candidates_json" >/dev/null 2>&1 || candidates_json='[]'

# The per-run action cap, for the same reason every other sweep here caps
# itself: a backlog surfaces a few per cycle, never as a flood of closes.
max_actions=3
actions=0
deferred=0

warn() { jq -nc --arg i "$1" --arg d "$2" '{action: "warning", item: $i, detail: $d}'; }

close_comment() {  # close_comment REASON EVIDENCE OBSOLETE_LABELLED
  local reason="$1" evidence="$2" obsolete_labelled="${3:-false}"
  printf '%s\n\n' "$(pipeline_comment_header script "$node_name")"
  printf 'This pipeline recorded this as void — there is no work here, because:\n\n'
  printf '%s\n' "$reason"
  if [[ -n "$evidence" && "$evidence" != "$reason" ]]; then
    printf '\n%s\n' "$evidence"
  fi
  if [[ "$obsolete_labelled" == "true" ]]; then
    # shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
    printf '\nThis pull request also carries the human-applied `obsolete` label — the mark that lets the pipeline close a draft even while it still changes files (TD-PPagop-26081308).\n'
  fi
  printf '\nClosing it so it stops being re-derived void by every cycle that reaches it.\n\n'
  printf '%s' "$(pipeline_comment_marker "$cycle_id" script)"
}

while IFS=$'\t' read -r item detail evidence stage; do
  # bash's `read` collapses consecutive IFS-whitespace delimiters (tab
  # included) even when IFS is narrowed to just "\t", so an empty `detail`
  # (or, now that a column follows it, an empty `evidence`) would shift the
  # later fields into the earlier places. jq emits "-" for an empty middle
  # field specifically to keep the four columns aligned — the same guard
  # scripts/sweep-closed-issues.sh keeps over its own five.
  [[ "$detail" == "-" ]] && detail=""
  [[ "$evidence" == "-" ]] && evidence=""
  [[ -n "$item" ]] || continue

  # The corroboration gate (see header): every stage's voids pass requirement
  # 34d's guard (issue #243), so all three writers are eligible here. Anything
  # else — a stageless entry, or a stage this script does not recognise — is
  # skipped before the action cap: an ineligible item must not eat a slot, nor
  # count as deferred work that a later pass could do.
  case "$stage" in
    coordinator|enabler|implementer) ;;
    *) continue ;;
  esac

  # A `pr-<n>-conflict-…` or `pr-<n>-dequeued-…` void names the pull request
  # only to say the *conflict* (or the dequeue) on it resolved — the PR itself
  # is not the work that is gone, and closing it here would discard a live PR
  # of ours (requirement 34k, TD-PPagop-26080901, extended to `dequeued` by
  # TD-PPagop-26081409). Left unprocessed, exactly like a
  # void shape that names no GitHub object at all — and skipped here, before
  # the action cap, for the same reason the stage gate above is: this script
  # will never action these shapes on any cycle, so they must not eat a slot,
  # nor count as deferred work a later pass could do. Counting it would report
  # `remaining: N` for items nothing will ever do, every cycle forever, since
  # a shape this never closes never earns the `void-object-closed` that would
  # retire it (requirement 34n). This exclusion matches `-conflict-` and
  # `-dequeued-` alone — their sibling shape `pr-<n>-superseded-…` makes the
  # opposite claim (the pull request itself is moot) and falls through to the
  # ordinary `pr-<n>-…` close branch below (TD-PPagop-26081304).
  if grep -qE '^pr-[0-9]+-(conflict|dequeued)-' <<<"$item"; then
    continue
  fi

  if (( actions >= max_actions )); then
    deferred=$(( deferred + 1 ))
    continue
  fi

  # bash's `[[ =~ ]]` is POSIX ERE and cannot compile WORK_GONE_PR_RE's named
  # group (it is written for jq's Oniguruma engine); `grep -P` understands the
  # same syntax bash cannot, so the shape test below reuses the constants
  # verbatim rather than keeping a second, bash-flavoured copy of either.
  if grep -qE "$WORK_GONE_ISSUE_RE" <<<"$item"; then
    state="$("$GH" api "repos/$slug/issues/$item" --jq '.state' 2>/dev/null)" || state=""
    if [[ -z "$state" ]]; then
      warn "$item" "could not read issue #$item — leaving it alone"
      continue
    fi
    if [[ "$state" != "open" ]]; then
      jq -nc --arg i "$item" '{action: "closed", item: $i, kind: "issue", closed_by: "already"}'
      actions=$(( actions + 1 ))
      continue
    fi
    if "$GH" issue close "$item" -R "$slug" \
        --comment "$(close_comment "$detail" "$evidence")" >/dev/null 2>&1; then
      jq -nc --arg i "$item" '{action: "closed", item: $i, kind: "issue", closed_by: "sweep"}'
      actions=$(( actions + 1 ))
    else
      warn "$item" "could not close issue #$item"
    fi

  elif grep -qP "$WORK_GONE_PR_RE" <<<"$item"; then
    n="$(grep -oE '^pr-[0-9]+' <<<"$item" | grep -oE '[0-9]+')"
    if [[ -z "$n" ]]; then
      warn "$item" "could not extract a pull request number from this item id"
      continue
    fi
    # One fetch answers both `state` and whether the pull request already
    # carries the human-applied `obsolete` label — named in the close comment
    # below when present, so it must be read live rather than trusted from
    # the void's own `evidence` text.
    pr_json="$("$GH" api "repos/$slug/pulls/$n" 2>/dev/null)" || pr_json=""
    if [[ -z "$pr_json" ]]; then
      warn "$item" "could not read pull request #$n — leaving it alone"
      continue
    fi
    state="$(jq -r '.state // ""' <<<"$pr_json" 2>/dev/null || true)"
    obsolete_labelled="$(jq -r \
      '[(.labels // [])[].name // "" | ascii_downcase] | index("obsolete") != null' \
      <<<"$pr_json" 2>/dev/null || echo false)"
    if [[ "$state" != "open" ]]; then
      jq -nc --arg i "$item" --argjson n "$n" \
        '{action: "closed", item: $i, kind: "pull-request", number: $n, closed_by: "already"}'
      actions=$(( actions + 1 ))
      continue
    fi
    if "$GH" pr close "$n" -R "$slug" \
        --comment "$(close_comment "$detail" "$evidence" "$obsolete_labelled")" >/dev/null 2>&1; then
      jq -nc --arg i "$item" --argjson n "$n" \
        '{action: "closed", item: $i, kind: "pull-request", number: $n, closed_by: "sweep"}'
      actions=$(( actions + 1 ))
    else
      warn "$item" "could not close pull request #$n"
    fi
  fi
  # Every other shape — a register id, a review ref, a plan task id, or the
  # `-conflict-` shape handled above — names something that is not a pull
  # request or issue to close here (or, for `-conflict-`, names one but is
  # not about closing it) — silently out of scope for this script, never
  # processed and never marked closed, so a later, purpose-built reader can
  # still act on it.
done < <(jq -r '.[] | [.item,
                       ((.detail // "") | if . == "" then "-" else . end),
                       ((.evidence // "") | if . == "" then "-" else . end),
                       (.stage // "-")] | @tsv' \
         <<<"$candidates_json" 2>/dev/null || true)

if (( deferred > 0 )); then
  jq -nc --argjson n "$deferred" '{action: "deferred", remaining: $n}'
fi

exit 0
