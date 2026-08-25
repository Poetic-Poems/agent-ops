#!/usr/bin/env bash
#
# test/approver-restale-sweep.test.sh — regression test for
# `_approver_restale_sweep_repo`, the requirement-46 sweep (agent-ops#682)
# that keeps a fixed pull request from sitting silently behind the Approver's
# own stale `CHANGES_REQUESTED` — the gap PR #621 fell into for 13.5 hours.
#
# `_approver_restale_review`, `_approver_restale_dismiss` and
# `_approver_restale_escalate` are stubbed here — this file is about which of
# them the sweep reaches for and with what arguments, never about what any of
# them does with the call, the same split test/landing-retry-sweep.test.sh
# already draws around `_landing_stage_attempt`. `_approver_restale_sweep_repo`
# is lifted verbatim out of lib/approver.sh, the same technique that file and
# its siblings use, so the assertions are about the shipped code rather than a
# copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/approver-restale-sweep.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# assembled file unexpanded; the single-quoted here-doc and `printf` lines
# below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/lib/approver.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$CYCLE"
}

sweep_block="$(extract _approver_restale_sweep_repo)"
if [[ -z "$sweep_block" || "$sweep_block" != *"approver_review_stale"* ]]; then
  echo "FAIL - could not extract _approver_restale_sweep_repo from lib/approver.sh — has it moved?" >&2
  exit 1
fi

# --- Timestamps, real ones, computed against the actual clock ------------------
# `_approver_restale_sweep_repo` computes its own escalation cutoff with the
# real `date` command — nothing here fakes "now", so a "recent" fixture and an
# "old" one are built relative to it instead.
recent_at="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
old_at="$(date -u -d '-30 hours' +%Y-%m-%dT%H:%M:%SZ)"
older_at="$(date -u -d '-35 hours' +%Y-%m-%dT%H:%M:%SZ)"
progressed_at="$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)"

# --- Assembly -----------------------------------------------------------------

cat >"$tmp_dir/harness.sh" <<'HARNESS'
set -euo pipefail

# shellcheck source=lib/github-limit.sh
source "$SCRIPT_DIR/lib/github-limit.sh"

pr_label="autonomous-agent"
DEFAULTED_CONFIG='{}'
state_repo="acme/widgets"
state_dir="$T/state"
approver_restale_escalate_after_hours="${APPROVER_RESTALE_ESCALATE_AFTER_HOURS:-24}"
mkdir -p "$state_dir"

log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

merge_autonomy_effective_level() { printf '%s' "${LEVEL:-agent-merges-routine}"; }

if [[ "${FORCE_TRUNCATED:-0}" == "1" ]]; then
  github_pr_list_truncated() { return 0; }
fi

gh() {
  if [[ "$1 $2" == "pr list" ]]; then
    printf '%s' "$PR_LIST_JSON"
    return 0
  fi
  if [[ "$1" == "api" ]]; then
    local path="$2" number var
    number="$(sed -E 's#.*/pulls/([0-9]+)/reviews#\1#' <<<"$path")"
    var="REVIEWS_$number"
    [[ -n "${!var:-}" ]] || { printf '[]' | jq -c '.[]?'; return 0; }
    printf '%s' "${!var}" | jq -c '.[]?'
    return 0
  fi
  return 1
}

landing_approver_standing_review_at() {
  local number="$2" svar avar cvar
  svar="STANDING_STATE_$number"; avar="STANDING_AT_$number"; cvar="STANDING_COMMIT_$number"
  [[ "${!svar:-}" != "RC1" ]] || return 1
  printf '%s\t%s\t%s' "${!svar:-}" "${!avar:-}" "${!cvar:-}"
}

approver_review_stale() {
  local state="${1:-}" commit="${2:-}" head="${3:-}"
  [[ "$state" == "CHANGES_REQUESTED" && -n "$commit" && -n "$head" && "$commit" != "$head" ]]
}

approver_newest_commit_authored_at() {
  local url="${1:-}" number var
  number="${url##*/}"
  var="NEWEST_$number"
  [[ -n "${!var:-}" ]] || return 1
  printf '%s' "${!var}"
}

_approver_restale_review() {
  printf 'slug=%s\tpr_url=%s\tnumber=%s\tbranch=%s\tcomplexity=%s\ttitle=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" >>"$T/review-calls"
  local num="$3" var
  var="REVIEW_ACTION_$num"
  # The real function's own contract: the outcome comes back in a global, not
  # on stdout — see its header, and the second harness at the foot of this
  # file, which pins that the shipped one really does set it.
  _approver_restale_review_result="${!var:-unavailable}"
}

_approver_restale_dismiss() {
  printf 'slug=%s\tpr_url=%s\treview_id=%s\treason=%s\n' "$1" "$2" "$3" "$4" >>"$T/dismiss-calls"
  return 0
}

_approver_restale_escalate() {
  printf 'slug=%s\tpr_url=%s\tnumber=%s\titem_ref=%s\treview_at=%s\n' "$1" "$2" "$3" "$4" "$5" >>"$T/escalate-calls"
}

HARNESS

{
  printf '%s\n' "$sweep_block"
  printf '_approver_restale_sweep_repo "acme/widgets" "pullwright-approver[bot]"\n'
} >>"$tmp_dir/harness.sh"

# --- Fixtures -----------------------------------------------------------------

pr_row() {  # number url branch head draft reviewDecision title complexity_label
  jq -nc --argjson n "$1" --arg u "$2" --arg b "$3" --arg h "$4" --argjson d "$5" \
    --arg rd "$6" --arg t "$7" --arg c "$8" \
    '{number: $n, url: $u, headRefName: $b, headRefOid: $h, isDraft: $d, reviewDecision: $rd,
      title: $t, labels: (if $c == "" then [] else [{name: $c}] end)}'
}

review_row() {  # id login at
  jq -nc --argjson id "$1" --arg l "$2" --arg a "$3" '{id: $id, login: $l, at: $a}'
}

run_case() {  # PR_LIST_JSON=... plus any stub-steering env
  : >"$tmp_dir/events"; : >"$tmp_dir/review-calls"; : >"$tmp_dir/dismiss-calls"; : >"$tmp_dir/escalate-calls"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" \
    LEVEL="agent-merges-routine" \
    "$@" \
    bash "$tmp_dir/harness.sh" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
  printf '%s' "$?"
}

review_calls() { cat "$tmp_dir/review-calls" 2>/dev/null || true; }
dismiss_calls() { cat "$tmp_dir/dismiss-calls" 2>/dev/null || true; }
escalate_calls() { cat "$tmp_dir/escalate-calls" 2>/dev/null || true; }
events() { cat "$tmp_dir/events" 2>/dev/null || true; }
count() { [[ -s "$1" ]] && wc -l <"$1" | tr -d ' ' || printf '0'; }

# --- The happy path: a stale, progressed review reaches a real re-review -----

stale_progressed_list="$(jq -sc '.' <(
  pr_row 7 "https://github.com/acme/widgets/pull/7" "agent/td-7" "newsha7" false "CHANGES_REQUESTED" "fix: thing" "complexity:medium"
))"

rc="$(run_case PR_LIST_JSON="$stale_progressed_list" \
  STANDING_STATE_7="CHANGES_REQUESTED" STANDING_AT_7="$recent_at" STANDING_COMMIT_7="oldsha7" \
  REVIEWS_7="[$(review_row 555 "pullwright-approver[bot]" "$recent_at")]" \
  NEWEST_7="$progressed_at" \
  REVIEW_ACTION_7="posted")"
assert_eq "a well-formed sweep returns 0" "0" "$rc"
assert_eq "a stale, progressed review reaches _approver_restale_review exactly once" \
  "1" "$(count "$tmp_dir/review-calls")"
assert_contains "  ... with its own slug" "slug=acme/widgets" "$(review_calls)"
assert_contains "  ... its own pull request url" "pr_url=https://github.com/acme/widgets/pull/7" "$(review_calls)"
assert_contains "  ... its own branch" "branch=agent/td-7" "$(review_calls)"
assert_contains "  ... the complexity read off its own label" "complexity=medium" "$(review_calls)"
assert_eq "a review that posts never falls back to dismissal" "0" "$(count "$tmp_dir/dismiss-calls")"
assert_eq "  ... nor to escalation" "0" "$(count "$tmp_dir/escalate-calls")"

# --- A re-review that could not be attempted falls back to dismissal ----------

rc="$(run_case PR_LIST_JSON="$stale_progressed_list" \
  STANDING_STATE_7="CHANGES_REQUESTED" STANDING_AT_7="$recent_at" STANDING_COMMIT_7="oldsha7" \
  REVIEWS_7="[$(review_row 555 "pullwright-approver[bot]" "$recent_at")]" \
  NEWEST_7="$progressed_at" \
  REVIEW_ACTION_7="unavailable")"
assert_eq "an unavailable re-review falls back to dismissal" "1" "$(count "$tmp_dir/dismiss-calls")"
assert_contains "  ... naming the review id resolved from the reviews list" "review_id=555" "$(dismiss_calls)"
assert_eq "  ... and never escalates on the same pass" "0" "$(count "$tmp_dir/escalate-calls")"

# --- A stale but rebase-only review (no commit authored since) is left alone
#     under the escalation threshold, and escalated once past it -------------

rebase_only_list="$(jq -sc '.' <(
  pr_row 8 "https://github.com/acme/widgets/pull/8" "agent/td-8" "newsha8" false "CHANGES_REQUESTED" "fix: other thing" "complexity:low"
))"

rc="$(run_case PR_LIST_JSON="$rebase_only_list" \
  STANDING_STATE_8="CHANGES_REQUESTED" STANDING_AT_8="$recent_at" STANDING_COMMIT_8="oldsha8" \
  REVIEWS_8="[$(review_row 556 "pullwright-approver[bot]" "$recent_at")]" \
  NEWEST_8="$old_at")"
assert_eq "no commit authored since the review means no re-review is attempted" \
  "0" "$(count "$tmp_dir/review-calls")"
assert_eq "  ... and, under the threshold, no escalation either" "0" "$(count "$tmp_dir/escalate-calls")"
assert_eq "  ... and no dismissal — nothing has actually changed to judge" "0" "$(count "$tmp_dir/dismiss-calls")"

rc="$(run_case PR_LIST_JSON="$rebase_only_list" \
  STANDING_STATE_8="CHANGES_REQUESTED" STANDING_AT_8="$old_at" STANDING_COMMIT_8="oldsha8" \
  REVIEWS_8="[$(review_row 556 "pullwright-approver[bot]" "$old_at")]" \
  NEWEST_8="$older_at")"
assert_eq "a rebase-only review past the threshold escalates" "1" "$(count "$tmp_dir/escalate-calls")"
assert_contains "  ... naming a review-scoped item ref" "item_ref=pr-8-approver-restale-556" "$(escalate_calls)"
assert_contains "  ... and the review's own submitted_at" "review_at=$old_at" "$(escalate_calls)"
assert_eq "  ... never a re-review" "0" "$(count "$tmp_dir/review-calls")"
assert_eq "  ... never a dismissal" "0" "$(count "$tmp_dir/dismiss-calls")"

rc="$(run_case PR_LIST_JSON="$rebase_only_list" \
  STANDING_STATE_8="CHANGES_REQUESTED" STANDING_AT_8="$old_at" STANDING_COMMIT_8="oldsha8" \
  REVIEWS_8="[$(review_row 556 "pullwright-approver[bot]" "$old_at")]" \
  NEWEST_8="$older_at" APPROVER_RESTALE_ESCALATE_AFTER_HOURS="1000")"
assert_eq "a configured-longer threshold holds the same review back from escalation" \
  "0" "$(count "$tmp_dir/escalate-calls")"

# --- Non-stale and non-candidate pull requests are skipped up front -----------

fresh_list="$(jq -sc '.' <(
  pr_row 20 "https://github.com/acme/widgets/pull/20" "agent/td-20" "samesha" false "CHANGES_REQUESTED" "x" "complexity:low"
  pr_row 21 "https://github.com/acme/widgets/pull/21" "agent/td-21" "sha21" true "CHANGES_REQUESTED" "x" "complexity:low"
  pr_row 22 "https://github.com/acme/widgets/pull/22" "agent/td-22" "sha22" false "APPROVED" "x" "complexity:low"
  pr_row 23 "https://github.com/acme/widgets/pull/23" "agent/td-23" "" false "CHANGES_REQUESTED" "x" "complexity:low"
))"

rc="$(run_case PR_LIST_JSON="$fresh_list" \
  STANDING_STATE_20="CHANGES_REQUESTED" STANDING_AT_20="$recent_at" STANDING_COMMIT_20="samesha" \
  STANDING_STATE_21="CHANGES_REQUESTED" STANDING_AT_21="$recent_at" STANDING_COMMIT_21="oldsha21" \
  REVIEWS_21="[$(review_row 1 "pullwright-approver[bot]" "$recent_at")]" NEWEST_21="$progressed_at" \
  STANDING_STATE_22="APPROVED" STANDING_AT_22="$recent_at" STANDING_COMMIT_22="sha22" \
  STANDING_STATE_23="CHANGES_REQUESTED" STANDING_AT_23="$recent_at" STANDING_COMMIT_23="oldsha23")"
assert_eq "a review whose commit still matches head (#20) is not stale, never offered" \
  "" "$(grep 'pull/20' <(review_calls) <(dismiss_calls) || true)"
assert_eq "a draft pull request (#21) is skipped before any staleness read" \
  "" "$(grep 'pull/21' <(review_calls) <(dismiss_calls) <(escalate_calls) || true)"
assert_eq "a currently-approved pull request (#22) is not a CHANGES_REQUESTED candidate at all" \
  "" "$(grep 'pull/22' <(review_calls) <(dismiss_calls) <(escalate_calls) || true)"
assert_eq "a pull request with no readable head sha (#23) is skipped" \
  "" "$(grep 'pull/23' <(review_calls) <(dismiss_calls) <(escalate_calls) || true)"

# --- The standing-review read itself ------------------------------------------

rc="$(run_case PR_LIST_JSON="$stale_progressed_list" \
  STANDING_STATE_7="RC1" STANDING_AT_7="" STANDING_COMMIT_7="")"
assert_eq "an unreadable standing-review read is skipped, never guessed at" \
  "0" "$(count "$tmp_dir/review-calls")"
assert_eq "  ... and nothing is logged for it (ordinary in-flight work, not a stall)" "" "$(events)"

# --- The review id resolved must match this login and this exact timestamp --

rc="$(run_case PR_LIST_JSON="$stale_progressed_list" \
  STANDING_STATE_7="CHANGES_REQUESTED" STANDING_AT_7="$recent_at" STANDING_COMMIT_7="oldsha7" \
  REVIEWS_7="[$(review_row 900 "a-human" "$recent_at"), $(review_row 901 "pullwright-approver[bot]" "$old_at")]" \
  NEWEST_7="$progressed_at")"
assert_eq "no review by this login at this exact timestamp means no id resolves, so nothing runs" \
  "0" "$(count "$tmp_dir/review-calls")"
assert_eq "  ... nor dismissal" "0" "$(count "$tmp_dir/dismiss-calls")"

# --- Level pre-check: nothing runs at merge_autonomy: human --------------------
# The Approver itself never engages at `human` (run_approver_stage's own
# `[[ "$level" != "human" ]] || return 0`) — every level above it is fair game
# for this sweep, so `human` is the one level worth pinning here.

rc="$(run_case PR_LIST_JSON="$stale_progressed_list" \
  STANDING_STATE_7="CHANGES_REQUESTED" STANDING_AT_7="$recent_at" STANDING_COMMIT_7="oldsha7" \
  REVIEWS_7="[$(review_row 555 "pullwright-approver[bot]" "$recent_at")]" \
  NEWEST_7="$progressed_at" LEVEL="human")"
assert_eq "at human nothing is offered" "0" "$(count "$tmp_dir/review-calls")"
assert_eq "  ... returning 0" "0" "$rc"

# --- The truncated-listing warning ---------------------------------------------

rc="$(run_case PR_LIST_JSON="$stale_progressed_list" \
  STANDING_STATE_7="CHANGES_REQUESTED" STANDING_AT_7="$recent_at" STANDING_COMMIT_7="oldsha7" \
  REVIEWS_7="[$(review_row 555 "pullwright-approver[bot]" "$recent_at")]" \
  NEWEST_7="$progressed_at" FORCE_TRUNCATED="1")"
assert_contains "a truncated pull-request listing logs a warning naming the repo" \
  "acme/widgets" "$(events)"
assert_contains "  ... and says a stale review beyond it is not swept this cycle" \
  "not swept this cycle" "$(events)"

# --- `_approver_restale_review` itself, lifted verbatim -----------------------
# The sweep harness above stubs it out, which is the right split for asking
# *which* helper the sweep reaches for — and is exactly why the function's own
# two hazards need their own harness here. Both are about the context it runs
# in rather than anything it does:
#
#   - It runs from the sweep, which runs before the cycle has selected any work
#     of its own, so `work_order_json`, `impl_status_json` and `rev_status_json`
#     — the globals it saves and restores around `run_approver_stage` — are
#     genuinely unset at that point. Under `set -euo pipefail` (agent-cycle.sh
#     line 6) reading one bare is fatal, and a fatal read here looks exactly
#     like "the re-review could not be attempted", which routes a pull request
#     with a real fix straight into the dismissal fallback instead of the
#     re-review requirement 46 exists to give it. So this harness deliberately
#     defines none of the five.
#   - `run_approver_stage` writes to stdout itself under `--once`
#     (`dump_stage_output`), so the outcome travels in a global rather than in
#     what the function printed. The stub below prints, and the assertion is
#     that the outcome survives it.

cat >"$tmp_dir/review-harness.sh" <<'RHARNESS'
set -euo pipefail

workspace_root="$T/ws"
cycle_id="cyc1"
cycle_dir="$T/cycdir"
mkdir -p "$workspace_root" "$cycle_dir"

assert_in_workspace() { case "$1" in "$workspace_root"/*) return 0 ;; *) exit 1 ;; esac; }
clone_repo() { [[ "${CLONE_FAILS:-0}" == "1" ]] && return 1; mkdir -p "$2"; return 0; }
git() { return 0; }

approver_stage_verdict=""
run_approver_stage() {
  # Records what the swapped-in globals looked like from inside the call, and
  # writes to stdout exactly as a `--once` run's own `dump_stage_output` does.
  printf 'repo=%s\tclone=%s\two_item=%s\timpl_status=%s\trev_status=%s\n' \
    "$selected_repo" "$clone_dir" \
    "$(jq -r '.item' <<<"$work_order_json")" \
    "$(jq -r '.status' <<<"$impl_status_json")" \
    "$(jq -r '.status' <<<"$rev_status_json")" >>"$T/stage-calls"
  printf 'the whole stage transcript, as --once dumps it\n'
  # `${…-…}`, not `${…:-…}`: an explicitly empty VERDICT is the case being
  # steered — a stage that ran and reached no verdict of its own.
  approver_stage_verdict="${VERDICT-approve}"
}
RHARNESS
{
  printf '%s\n' "$(extract _approver_restale_review)"
  cat <<'RTAIL'
_approver_restale_review "acme/widgets" "https://github.com/acme/widgets/pull/7" 7 "agent/682" "high" "feat: thing"
printf 'result=%s\n' "$_approver_restale_review_result"
printf 'restored_wo=[%s] restored_impl=[%s] restored_rev=[%s] restored_repo=[%s] restored_clone=[%s]\n' \
  "$work_order_json" "$impl_status_json" "$rev_status_json" "$selected_repo" "$clone_dir"
printf 'clone_left=%s\n' "$([[ -d "$workspace_root/cyc1-restale-7" ]] && printf 'yes' || printf 'no')"
RTAIL
} >>"$tmp_dir/review-harness.sh"

run_review_case() {
  : >"$tmp_dir/stage-calls"
  env -i PATH="$PATH" HOME="$HOME" T="$tmp_dir" "$@" \
    bash "$tmp_dir/review-harness.sh" >"$tmp_dir/review-stdout" 2>"$tmp_dir/review-stderr"
  printf '%s' "$?"
}

rc="$(run_review_case)"
review_out="$(cat "$tmp_dir/review-stdout")"
assert_eq "the function survives the globals it saves being unset — the sweep's own context" "0" "$rc"
assert_eq "  ... with no unbound-variable death on the way" "" "$(cat "$tmp_dir/review-stderr")"
assert_contains "a verdict reached is reported as posted" "result=posted" "$review_out"
assert_contains "  ... even though the stage wrote its own transcript to stdout (--once)" \
  "result=posted" "$review_out"
assert_contains "the stage really was engaged, under the pull request's own repo" \
  "repo=acme/widgets" "$(cat "$tmp_dir/stage-calls")"
assert_contains "  ... its own fresh clone" "clone=$tmp_dir/ws/cyc1-restale-7" "$(cat "$tmp_dir/stage-calls")"
assert_contains "  ... and a synthetic work order naming the pull request" \
  "wo_item=pr-7-approver-restale" "$(cat "$tmp_dir/stage-calls")"
assert_contains "  ... a complete Implementer summary" "impl_status=complete" "$(cat "$tmp_dir/stage-calls")"
assert_contains "  ... and a ready Reviewer summary" "rev_status=ready" "$(cat "$tmp_dir/stage-calls")"
assert_contains "the borrowed globals are restored, never left mutated" \
  "restored_wo=[] restored_impl=[] restored_rev=[] restored_repo=[] restored_clone=[]" "$review_out"
assert_contains "the recovery clone is torn down" "clone_left=no" "$review_out"

rc="$(run_review_case VERDICT="")"
assert_contains "a stage that reached no verdict at all is unavailable" \
  "result=unavailable" "$(cat "$tmp_dir/review-stdout")"

rc="$(run_review_case CLONE_FAILS=1)"
assert_eq "a failed clone is not a failed cycle" "0" "$rc"
assert_contains "  ... it is reported as unavailable, for the dismissal fallback" \
  "result=unavailable" "$(cat "$tmp_dir/review-stdout")"
assert_eq "  ... and the stage is never engaged" "" "$(cat "$tmp_dir/stage-calls")"

# --- Result -------------------------------------------------------------------

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
echo
echo "all assertions passed"
