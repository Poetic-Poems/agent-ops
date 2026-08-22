#!/usr/bin/env bash
#
# test/landing-wiring.test.sh — regression test for `run_landing_stage` and
# `_landing_refuse`, the code in agent-cycle.sh that turns lib/landing.sh's
# classifier and arming primitives into the one place a pull request lands
# without a human click (requirement 8d, "## The Landing Gate"; D18 WI-7,
# agent-ops#410).
#
# `test/landing.test.sh` covers lib/landing.sh's own primitives — the
# protected-path classifier, `landing_eligible`, `landing_arm`. None of that
# says anything about the six-gate sequence those primitives hang off, which
# is where this stage's decisions actually live, and every one of the issue's
# own acceptance criteria is a statement about *that* sequence:
#
#   - **Nothing this round's Approver did not explicitly approve arms
#     anything** — a refusal, an unparseable verdict, a stage that never ran,
#     and an adjudication's own `land` all leave the stage silent (not even a
#     `landing-refused`: there was no landing decision to refuse).
#   - **Every gate that refuses costs exactly one `landing-refused` event** —
#     never a blocked pull request, never a withheld claim, and never a
#     non-zero return, the same contract 8b establishes for the Approver.
#   - **Every gate that cannot be *read* refuses too**, never passes.
#
# The harness runs under `set -euo pipefail`, the shell options agent-cycle.sh
# itself sets (line 6) — not the `set -uo pipefail` the library tests use.
# That is the point of this file rather than an incidental detail: under
# `errexit` a bare `var="$(helper)"` assignment does not merely discard a
# non-zero status, it aborts the cycle mid-stage, so a gate helper that
# reports its refusal *in its exit status* (`review_gate_verdict` returns 1
# for `dirty` and 2 for an unreadable required-check list) can only be
# regression-tested for "refuses cleanly" under the options production runs
# with. Assertions below check the stage's own exit status as carefully as
# its events for exactly that reason.
#
# `run_landing_stage` and `_landing_refuse` are lifted verbatim out of
# agent-cycle.sh, the same way test/approver-wiring.test.sh and
# test/closing-keyword-wiring.test.sh lift their own blocks, so the
# assertions are about the shipped code rather than a copy of its logic.
# Everything that reaches outside the process — every gate helper, the
# arming write, the log — is stubbed and recorded.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/landing-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# assembled file unexpanded; the single-quoted here-doc and `printf` lines
# below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

# --- Extraction ---------------------------------------------------------------

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$CYCLE"
}

refuse_block="$(extract _landing_refuse)"
# `run_landing_stage` is gate 0 alone since TD-PPagop-26081701 split the
# other six gates out into `_landing_stage_attempt` (so the landing-retry
# sweep, requirement 8u, can reuse them for a pull request outside the
# round that first approved it) — both are extracted and sourced together so
# a call to `run_landing_stage` below still exercises the whole sequence,
# unchanged from what this file asserted before the split.
wrapper_block="$(extract run_landing_stage)"
stage_block="$(extract _landing_stage_attempt)"
if [[ -z "$refuse_block" || "$refuse_block" != *"landing-refused"* ]]; then
  echo "FAIL - could not extract _landing_refuse from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if [[ -z "$wrapper_block" || "$wrapper_block" != *"_landing_stage_attempt"* ]]; then
  echo "FAIL - could not extract run_landing_stage from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if [[ -z "$stage_block" || "$stage_block" != *"landing_arm"* ]]; then
  echo "FAIL - could not extract _landing_stage_attempt from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# --- Assembly -----------------------------------------------------------------
# Case inputs arrive as environment variables, so one harness serves every
# case: VERDICT/ADJUDICATING (what run_approver_stage left behind), LEVEL,
# ELIGIBLE, GATE_WORD/GATE_REASON/GATE_RC, LOGIN_RC, STANDING/STANDING_RC,
# BLOCKING/BLOCKING_RC, BUDGET, QUEUED/QUEUE_RC, TOKEN_RC, ARM_METHOD/ARM_RC.

cat >"$tmp_dir/harness.sh" <<'HARNESS'
# The shell options agent-cycle.sh itself runs under — see this file's header
# for why the whole point of this harness is that they are not relaxed.
set -euo pipefail

# `run_landing_stage` calls `_landing_arm_failure_reason` (agent-ops#532) to
# turn a failed `landing_arm`'s exit status into text for the
# `landing-refused` reason — the real function, not a stub, since it is a
# small pure mapping test/landing.test.sh already pins directly and this
# harness only needs it present, not faked. `landing_arm` itself is stubbed
# below, overriding lib/landing.sh's own definition.
# shellcheck source=lib/landing.sh
source "$SCRIPT_DIR/lib/landing.sh"
# `merge_queue_dequeue_actionable` (PR #557 review round 2), the same real,
# small pure mapping — `merge_queue_probe` itself is stubbed below,
# overriding lib/merge-queue.sh's own definition.
# shellcheck source=lib/merge-queue.sh
source "$SCRIPT_DIR/lib/merge-queue.sh"

# --- Cycle globals the block reads -------------------------------------------
selected_repo="Poetic-Poems/agent-ops"
selected_source="tech-debt"
state_repo="Poetic-Poems/agent-ops"
state_dir="$T/state"
DEFAULTED_CONFIG='{}'
gate_default_branch="main"
pr_label="autonomous-agent"
enabler_escalation_label="agent-escalation"
enabler_assignee="warwickallen"
approver_stage_verdict="$VERDICT"
approver_stage_adjudicating="$ADJUDICATING"
approver_stage_tier="${APPROVER_STAGE_TIER:-critical}"
union_log="$T/union.jsonl"
mkdir -p "$state_dir"
: > "$union_log"

# The cycle-scoped tally `run_landing_stage`'s own gate 0 now reads and grows
# (PR #557 review round 2 of TD-PPagop-26081701) — declared here exactly as
# agent-cycle.sh itself declares it ahead of both call sites, so the block
# below never reads an unset array under this harness's own `set -u`.
# ALREADY_ARMED_SEED, when given, pre-seeds this repository's own entry, the
# same way a landing-retry sweep pass earlier in the same cycle would have.
declare -A landing_armed_by_repo=()
[[ -z "${ALREADY_ARMED_SEED:-}" ]] || landing_armed_by_repo["$selected_repo"]="$ALREADY_ARMED_SEED"

# --- Stubs: everything that reaches outside this process ----------------------
log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

# Records its own argv (issue #513, PR #506 review follow-up) so a test can
# confirm run_landing_stage asks for a FRESH read of the level rather than
# the process-lifetime memo every advisory reader uses — this stage arms a
# real merge/enqueue under the answer, so a kill set mid-cycle must stop it
# at this stage boundary, not wait for the next cycle's process. The same
# discipline test/approver-wiring.test.sh already pins for run_approver_stage.
merge_autonomy_effective_level() { printf '%s\n' "$*" >>"$T/mal_calls"; printf '%s' "$LEVEL"; }

# The real `landing_autonomy_refusal_reason` (lib/landing.sh, D18 issue #576)
# reads this directly when gate 1 refuses, to tell a fleet-wide kill switch
# apart from a level simply never raised — stubbed here since
# lib/merge-autonomy.sh's own network-backed `merge_autonomy_kill_state` has
# no place in a stage-wiring test; test/merge-autonomy.test.sh already covers
# it directly, and test/landing-kill-switch-wiring.test.sh exercises the real
# collapse end to end. Defaults to "enabled" (not engaged) so every gate-1
# case above keeps the plain "effective level is …" wording unless a case
# opts into KILL_STATE=disabled.
merge_autonomy_kill_state() {
  printf '%s\n' "$*" >>"$T/kill_state_calls"
  if [[ "${KILL_STATE:-enabled}" == "enabled" ]]; then
    printf '{"state":"enabled"}'
  else
    printf '{"state":"disabled","record":{"reason":"drill","by":"test-operator","expires_at":null,"disabled_at":"2026-08-22T00:00:00Z","kind":"manual"}}'
  fi
}

landing_eligible() {
  printf '%s\n' "$*" >>"$T/eligible_args"
  printf '%s' "$ELIGIBLE"
}

# The one gate helper that speaks in its exit status as well as its word.
review_gate_verdict() {
  if [[ -n "${GATE_REASON:-}" ]]; then
    printf '%s\t%s' "$GATE_WORD" "$GATE_REASON"
  else
    printf '%s' "$GATE_WORD"
  fi
  return "${GATE_RC:-0}"
}

approver_token_identity_login() {
  [[ "${LOGIN_RC:-0}" == "0" ]] || return "$LOGIN_RC"
  printf 'pullwright-approver[bot]'
}

# Three tab-separated fields, exactly as lib/landing.sh's own
# `landing_approver_standing_review_at` prints them (agent-ops#658): STATE,
# `submitted_at`, and the standing review's own `commit_id`. A two-field stub
# would still satisfy `_landing_stage_attempt`'s parsing without failing —
# `${rest#*<TAB>}` on a tab-less string is the string itself — and would
# silently hand gate 4.5 the timestamp where the commit belongs.
landing_approver_standing_review_at() {
  printf '%s\n' "$*" >>"$T/standing_args"
  [[ "${STANDING_RC:-0}" == "0" ]] || return "$STANDING_RC"
  printf '%s\t%s\t%s' "${STANDING:-}" "${SUBMITTED_AT:-2026-08-17T10:00:00Z}" \
    "${REVIEW_COMMIT:-sha-approved-head}"
}

_handoff_blocking_reviewers() {
  [[ "${BLOCKING_RC:-0}" == "0" ]] || return "$BLOCKING_RC"
  [[ -z "${BLOCKING:-}" ]] || printf '%s\n' "$BLOCKING"
  return 0
}

landing_protected_path_controls_ok() {
  printf '%s\n' "$*" >>"$T/pp_ctl_args"
  printf '%s' "${PP_CTL:-ok}"
}

landing_retry_tier() {
  printf '%s\n' "$*" >>"$T/retry_tier_args"
  printf '%s' "${RETRY_TIER:-critical}"
}

merge_budget_decide() {
  printf '%s\n' "$*" >>"$T/budget_decide_args"
  printf '{"decision":"%s","cap":8,"count":8,"anomaly":false,"waiting_backlog":null}' "$BUDGET"
}
merge_budget_apply_decision() { printf '%s\n' "$1" >>"$T/budget_applied"; }

merge_queue_probe() {
  [[ "${QUEUE_RC:-0}" == "0" ]] || return "$QUEUE_RC"
  if [[ -n "${DEQUEUE_REASON:-}" ]]; then
    printf '{"queued":%s,"dequeue_reason":"%s"}' "${QUEUED:-false}" "$DEQUEUE_REASON"
  else
    printf '{"queued":%s}' "${QUEUED:-false}"
  fi
}

approver_token_get() {
  [[ "${TOKEN_RC:-0}" == "0" ]] || return "$TOKEN_RC"
  printf 'a-minted-token'
}

landing_arm() {
  printf 'slug=%s\tnumber=%s\ttoken=%s\n' "$1" "$2" "$3" >>"$T/arms"
  [[ "${ARM_RC:-0}" == "0" ]] || return "$ARM_RC"
  # `-` rather than `:-`: an ARM_METHOD deliberately set empty is a case
  # (an arm that reported success while printing no method at all).
  printf '%s' "${ARM_METHOD-enqueued}"
}

HARNESS

{
  printf '%s\n' "$refuse_block"
  printf '%s\n' "$stage_block"
  printf '%s\n' "$wrapper_block"
  printf 'run_landing_stage "$PR_URL" "$COMPLEXITY"\n'
  # Reached only if the stage returned rather than aborting the cycle — the
  # difference this file exists to pin (see header).
  printf '%s\n' 'printf "stage-returned\n" >>"$T/reached"'
  # `_landing_stage_attempt_armed` (PR #557 review of TD-PPagop-26081701) is
  # the one global a caller of `_landing_stage_attempt` reads to grow its own
  # ALREADY_ARMED tally — recorded here so a test can pin it directly. Read
  # with a `:-0` default: gate 0 above can return without ever calling
  # `_landing_stage_attempt`, which never sets the global at all, and this
  # harness runs under the same `errexit`/`nounset` agent-cycle.sh itself
  # does.
  printf '%s\n' 'printf "%s" "${_landing_stage_attempt_armed:-0}" >"$T/armed_flag"'
  # `landing_armed_by_repo[$selected_repo]` after the call (PR #557 review
  # round 2) — so a test can confirm gate 0 both reads and grows the same
  # cycle-scoped tally the 2.1e sweep does, rather than a tally of its own.
  printf '%s\n' 'printf "%s" "${landing_armed_by_repo[$selected_repo]:-0}" >"$T/armed_by_repo_flag"'
} >>"$tmp_dir/harness.sh"

URL="https://github.com/Poetic-Poems/agent-ops/pull/512"

# run_case [KEY=VALUE ...]
# Runs the block once against a clean happy-path default, overridden by the
# environment assignments given, and leaves $tmp_dir/{events,arms,...} holding
# what it did. Prints the block's own exit status.
run_case() {
  : >"$tmp_dir/events"; : >"$tmp_dir/arms"; : >"$tmp_dir/budget_applied"
  : >"$tmp_dir/reached"; : >"$tmp_dir/eligible_args"; : >"$tmp_dir/standing_args"
  : >"$tmp_dir/mal_calls"; : >"$tmp_dir/budget_decide_args"; rm -f "$tmp_dir/armed_flag"
  rm -f "$tmp_dir/armed_by_repo_flag"
  : >"$tmp_dir/pp_ctl_args"; : >"$tmp_dir/retry_tier_args"; : >"$tmp_dir/kill_state_calls"
  rm -rf "${tmp_dir:?}/state"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" PR_URL="$URL" COMPLEXITY="medium" \
    VERDICT="approve" ADJUDICATING="0" LEVEL="agent-merges-routine" \
    ELIGIBLE="eligible" GATE_WORD="clean" GATE_REASON="" GATE_RC="0" \
    STANDING="APPROVED" BUDGET="arm" QUEUED="false" ARM_METHOD="enqueued" \
    PP_CTL="ok" APPROVER_STAGE_TIER="critical" KILL_STATE="enabled" \
    "$@" \
    bash "$tmp_dir/harness.sh" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
  printf '%s' "$?"
}

events() { cat "$tmp_dir/events"; }
arms() { cat "$tmp_dir/arms"; }
mal_calls() { cat "$tmp_dir/mal_calls"; }
reached() { [[ -s "$tmp_dir/reached" ]] && printf 'yes' || printf 'no'; }
count() { local f="$tmp_dir/$1"; [[ -s "$f" ]] && wc -l <"$f" | tr -d ' ' || printf '0'; }
event_of() { grep -m1 "^$1"$'\t' "$tmp_dir/events" | cut -f2- || true; }
refusal() { jq -r '.reason' <<<"$(event_of landing-refused)" 2>/dev/null || true; }
budget_decide_args() { cat "$tmp_dir/budget_decide_args" 2>/dev/null || true; }
armed_flag() { cat "$tmp_dir/armed_flag" 2>/dev/null || true; }
armed_by_repo_flag() { cat "$tmp_dir/armed_by_repo_flag" 2>/dev/null || true; }
pp_ctl_args() { cat "$tmp_dir/pp_ctl_args" 2>/dev/null || true; }
retry_tier_args() { cat "$tmp_dir/retry_tier_args" 2>/dev/null || true; }
kill_state_calls() { cat "$tmp_dir/kill_state_calls" 2>/dev/null || true; }

# --- The happy path: one landing-armed, naming the method --------------------

rc="$(run_case)"
assert_eq "an eligible, fully-cleared PR returns 0" "0" "$rc"
assert_eq "  ... arms exactly once" "1" "$(count arms)"
assert_contains "  ... under the Approver's own minted token" "token=a-minted-token" "$(arms)"
assert_contains "  ... naming the pull request's own number" "number=512" "$(arms)"
assert_eq "  ... logs exactly one event" "1" "$(count events)"
assert_eq "  ... a landing-armed" '"enqueued"' "$(jq -c '.method' <<<"$(event_of landing-armed)")"
assert_eq "  ... naming the source" '"tech-debt"' "$(jq -c '.source' <<<"$(event_of landing-armed)")"
assert_eq "  ... and the complexity it was armed at" '"medium"' "$(jq -c '.complexity' <<<"$(event_of landing-armed)")"
# D18 issue #574: the arm is the only outcome of gate 5 that would otherwise
# leave no trace of the cap and count `merge_budget_decide` read, and the
# dashboard's budget row sources a repository's consumption from exactly these
# two fields — so they must be that decision's own values, never a second read.
assert_eq "  ... and the cap/count gate 5's own merge_budget_decide read (D18 issue #574)" \
  "8 8" "$(jq -r '"\(.cap) \(.count)"' <<<"$(event_of landing-armed)")"
# The *effective* level gate 1 judged this arm against, recorded because
# requirement 8e's post-hoc audit has no other way to learn it — see the
# comment on the log_event call itself.
assert_eq "  ... and the effective merge_autonomy level it was armed under" \
  '"agent-merges-routine"' "$(jq -c '.level' <<<"$(event_of landing-armed)")"
assert_eq "  ... and marks _landing_stage_attempt_armed for its caller" "1" "$(armed_flag)"
assert_eq "  ... gate 0's own call site reads an empty landing_armed_by_repo as 0" \
  "0" "$(budget_decide_args | awk '{print $NF}')"
assert_eq "  ... and grows landing_armed_by_repo[selected_repo] to 1 after arming" \
  "1" "$(armed_by_repo_flag)"

# --- The cycle-scoped tally: gate 0 discounts what the 2.1e sweep already
# armed earlier this same cycle, not just its own count (PR #557 review
# round 2) — the gap the first review round's own per-pass bound left, since
# that bound was private to `_landing_retry_sweep_repo` and this call site
# threaded no ALREADY_ARMED at all.

rc="$(run_case ALREADY_ARMED_SEED="3")"
assert_eq "a repository the sweep already armed 3 for this cycle still arms" "0" "$rc"
assert_eq "  ... reading merge_budget_decide's own ALREADY_ARMED as 3, not 0" \
  "3" "$(budget_decide_args | awk '{print $NF}')"
assert_eq "  ... and grows landing_armed_by_repo[selected_repo] to 4" \
  "4" "$(armed_by_repo_flag)"

rc="$(run_case ARM_METHOD="auto-merge")"
assert_eq "the method landing_arm actually used is what is logged" \
  '"auto-merge"' "$(jq -c '.method' <<<"$(event_of landing-armed)")"
assert_eq "  ... and the stage still returns 0" "0" "$rc"

# --- Gate 0: only this round's own explicit, non-adjudicating approve --------
# Not even a `landing-refused`: no landing decision was reached to refuse.

for v in refuse "" land; do
  rc="$(run_case VERDICT="$v")"
  assert_eq "a verdict of '${v:-none}' arms nothing" "0" "$(count arms)"
  assert_eq "  ... and logs nothing at all" "0" "$(count events)"
  assert_eq "  ... returning 0" "0" "$rc"
  assert_eq "  ... never reaching _landing_stage_attempt at all" "0" "$(armed_flag)"
done

rc="$(run_case ADJUDICATING="1")"
assert_eq "an adjudication's own approve arms nothing" "0" "$(count arms)"
assert_eq "  ... and logs nothing at all" "0" "$(count events)"
assert_eq "  ... returning 0" "0" "$rc"

# --- Gate 1: the effective level, re-read fresh ------------------------------

rc="$(run_case)"
assert_eq "  ... asks merge_autonomy_effective_level for a FRESH read (issue #513)" \
  "fresh" "$(mal_calls | awk '{print $NF}')"

for level in human agent-approves; do
  rc="$(run_case LEVEL="$level")"
  assert_eq "at $level nothing is armed" "0" "$(count arms)"
  assert_contains "  ... and the refusal names the level" \
    "effective level is $level" "$(refusal)"
  assert_eq "  ... never mentions the kill switch (it is clear)" "" \
    "$(refusal | grep -o 'kill switch' || true)"
  assert_eq "  ... returning 0" "0" "$rc"
done

# --- Gate 1, the kill switch (D18 issue #576): distinguishable in the log
# from a level that was simply never raised. The kill switch collapsing an
# arbitrary configured rung to `human` in the first place is
# merge_autonomy_effective_level's own job (test/merge-autonomy.test.sh,
# including the per-repo-override case at :174-179) — not repeated here.
# What is new here is that gate 1's own refusal, run through the real
# landing path, names the switch rather than the generic wording above.

rc="$(run_case LEVEL="human" KILL_STATE="disabled")"
assert_eq "with the switch engaged, nothing is armed" "0" "$(count arms)"
assert_contains "  ... and the refusal names the kill switch" \
  "merge_autonomy kill switch is engaged" "$(refusal)"
assert_eq "  ... never falling back to the generic 'effective level is' wording" "" \
  "$(refusal | grep -o 'effective level is' || true)"
assert_eq "  ... returning 0" "0" "$rc"
assert_contains "  ... and asks merge_autonomy_kill_state for a FRESH read too (issue #513)" \
  "fresh" "$(kill_state_calls)"

rc="$(run_case LEVEL="agent-merges-all")"
assert_eq "agent-merges-all arms on the same terms" "1" "$(count arms)"
assert_eq "  ... returning 0" "0" "$rc"

# --- Gate 4.5: the D18 WI-12 protected-path compensating controls -----------
# Only ever consulted at agent-merges-all, and never at a lower level — the
# same "landing_eligible already refuses a protected path below Stage 4"
# invariant means gate 4.5 has nothing to add there.

rc="$(run_case LEVEL="agent-merges-routine")"
assert_eq "below agent-merges-all, gate 4.5 is never even consulted" "" "$(pp_ctl_args)"
assert_eq "  ... and the PR still arms (its own protected-path refusal, if any, is gate 2's job)" \
  "1" "$(count arms)"

rc="$(run_case LEVEL="agent-merges-all" PP_CTL="ineligible:protected-path cool-off has 3.2h remaining (approved 2026-08-17T10:00:00Z, landing_cool_off_hours=24)")"
assert_eq "gate 4.5 refusing a live cool-off arms nothing" "0" "$(count arms)"
assert_contains "  ... naming the remaining time" "cool-off has 3.2h remaining" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case LEVEL="agent-merges-all" PP_CTL="ineligible:touches a protected path at agent-merges-all but the approving engagement did not run at the critical tier (tier: standard)")"
assert_eq "gate 4.5 refusing a non-critical-tier approval arms nothing" "0" "$(count arms)"
assert_contains "  ... naming the tier it actually found" "did not run at the critical tier (tier: standard)" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case LEVEL="agent-merges-all" PP_CTL="unknown:could not re-establish acme/widgets#512's changed-file list for the protected-path controls")"
assert_eq "gate 4.5's own unknown is never a pass" "0" "$(count arms)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case LEVEL="agent-merges-all" PP_CTL="ok")"
assert_eq "gate 4.5 clearing (cool-off elapsed, critical tier confirmed) arms normally" "1" "$(count arms)"
assert_contains "  ... consulted with this round's own approver_stage_tier" "critical" "$(pp_ctl_args)"
assert_eq "  ... and never asked the fleet log for a tier (this is the original round, not a retry)" \
  "" "$(retry_tier_args)"
# TIER, SUBMITTED_AT and REVIEW_COMMIT, in that order and in those positions —
# a containment check on each alone would still pass if the last two were
# transposed, which is exactly how `landing_approver_standing_review_at`'s
# three-field return gets mis-parsed (agent-ops#658).
assert_contains "  ... and with the standing review's own submitted_at and commit_id, in that order" \
  "critical 2026-08-17T10:00:00Z sha-approved-head" "$(pp_ctl_args)"

rc="$(run_case LEVEL="agent-merges-all" PP_CTL="ok" REVIEW_COMMIT="sha-some-other-commit")"
assert_contains "gate 4.5 is consulted with whatever commit the standing review actually carries" \
  "sha-some-other-commit" "$(pp_ctl_args)"

rc="$(run_case LEVEL="agent-merges-all" APPROVER_STAGE_TIER="standard" PP_CTL="ok")"
assert_contains "gate 4.5 is consulted with whatever tier this round actually ran at" \
  "standard" "$(pp_ctl_args)"

# --- Gate 2: the classifier's own verdict, passed through verbatim -----------

rc="$(run_case ELIGIBLE="ineligible:touches protected path(s): lib/landing.sh")"
assert_eq "a protected-path PR is never armed" "0" "$(count arms)"
assert_contains "  ... and the classifier's reason is the refusal's" \
  "touches protected path(s): lib/landing.sh" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case ELIGIBLE="unknown:could not establish the changed-file list")"
assert_eq "an unreadable changed-file list is never a pass" "0" "$(count arms)"
assert_contains "  ... and refuses with the classifier's own word" \
  "unknown:could not establish" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

assert_contains "the classifier is asked about this round's own source" \
  "tech-debt" "$(cat "$tmp_dir/eligible_args")"

# --- Gate 3: the review gate, whose refusal travels in its exit status -------
# `review_gate_verdict` returns 1 for `dirty` and 2 when the required-check
# list could not be read. Under agent-cycle.sh's own `errexit` a bare
# assignment would abort the cycle here rather than refuse — which is why
# every case below asserts the stage *returned* as well as what it logged.

rc="$(run_case GATE_WORD="dirty" GATE_REASON="Build and test (linux/amd64) is failing" GATE_RC="1")"
assert_eq "a dirty review gate refuses rather than aborting the cycle" "yes" "$(reached)"
assert_eq "  ... returning 0" "0" "$rc"
assert_eq "  ... arming nothing" "0" "$(count arms)"
assert_contains "  ... and naming what is red" "Build and test" "$(refusal)"

rc="$(run_case GATE_WORD="unknown" GATE_REASON="could not read the required checks" GATE_RC="2")"
assert_eq "an unreadable required-check list refuses rather than aborting" "yes" "$(reached)"
assert_eq "  ... returning 0" "0" "$rc"
assert_eq "  ... arming nothing" "0" "$(count arms)"
assert_contains "  ... and naming the unreadable gate" "could not read the required checks" "$(refusal)"

# The alerts-only `unknown` exits 0 — a warning at the ready-gate handoff
# (requirement 31a), a refusal here (requirement 8d, gate 3 is stricter).
rc="$(run_case GATE_WORD="unknown" GATE_REASON="could not read the alert list" GATE_RC="0")"
assert_eq "an alerts-only unknown refuses arming even though it only warns at handoff" \
  "0" "$(count arms)"
assert_contains "  ... naming the alert list" "could not read the alert list" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

# --- Gate 4: the Approver's review must be standing on GitHub ----------------

rc="$(run_case LOGIN_RC="2")"
assert_eq "an unreadable Approver login arms nothing" "0" "$(count arms)"
assert_contains "  ... refusing by name" "could not read the Approver App's own login" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case STANDING="")"
assert_eq "an Approver review that never landed on GitHub arms nothing" "0" "$(count arms)"
assert_contains "  ... even though this round's own verdict said approve" \
  "not standing APPROVED" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case STANDING="CHANGES_REQUESTED")"
assert_eq "an Approver review since superseded arms nothing" "0" "$(count arms)"
assert_contains "  ... naming the state it actually found" "CHANGES_REQUESTED" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case STANDING_RC="1")"
assert_eq "an unreadable reviews list is never a pass" "0" "$(count arms)"
assert_contains "  ... refusing by name" "could not read" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

assert_contains "the standing-review read is filtered to the App's own login" \
  "pullwright-approver[bot]" "$(cat "$tmp_dir/standing_args")"

# --- Gate 4 (human half): a standing CHANGES_REQUESTED blocks at every level -

rc="$(run_case BLOCKING="warwickallen")"
assert_eq "a human CHANGES_REQUESTED prevents arming" "0" "$(count arms)"
assert_contains "  ... naming who" "warwickallen" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case BLOCKING_RC="1")"
assert_eq "a reviews list that could not be read prevents arming" "0" "$(count arms)"
assert_eq "  ... returning 0" "0" "$rc"

# --- Gate 5: the merge budget ------------------------------------------------

for decision in hold refuse; do
  rc="$(run_case BUDGET="$decision")"
  assert_eq "a budget $decision arms nothing" "0" "$(count arms)"
  assert_eq "  ... and applies the decision (its own event, not landing-refused)" \
    "1" "$(count budget_applied)"
  assert_eq "  ... returning 0" "0" "$rc"
  assert_eq "  ... and never marks _landing_stage_attempt_armed" "0" "$(armed_flag)"
done

# --- Gate 6: the merge queue -------------------------------------------------

rc="$(run_case QUEUED="true")"
assert_eq "an already-queued pull request is not re-armed" "0" "$(count arms)"
assert_contains "  ... refusing by name" "already in the merge queue" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case QUEUE_RC="1")"
assert_eq "a queue status that could not be read is possibly queued, so it refuses" \
  "0" "$(count arms)"
assert_contains "  ... refusing by name" "could not read" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

# --- Gate 6, continued: a pull request the merge queue already dequeued -----
# PR #557 review round 2 of TD-PPagop-26081701: `queued: false` alone cannot
# tell "never queued" apart from "queued and removed, not since re-queued",
# and only the second calls for a refusal here — re-arming it would either
# reverse a maintainer's own manual removal or blindly re-run the same
# failing merge group `scripts/gather-dequeued.sh`'s own `dequeued` source
# exists to diagnose instead.

rc="$(run_case QUEUED="false" DEQUEUE_REASON="manual")"
assert_eq "a manually-dequeued pull request is never re-armed" "0" "$(count arms)"
assert_contains "  ... refusing by name" "deliberate removal" "$(refusal)"
assert_contains "  ... naming the reason" "manual" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case QUEUED="false" DEQUEUE_REASON="failed_checks")"
assert_eq "a checks-failure-dequeued pull request is never blindly re-armed" "0" "$(count arms)"
assert_contains "  ... refusing by name" "dequeued source" "$(refusal)"
assert_contains "  ... naming the reason" "failed_checks" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case QUEUED="false" DEQUEUE_REASON="")"
assert_eq "a pull request never dequeued (empty reason) still arms normally" "1" "$(count arms)"

# --- The write itself, and its failures --------------------------------------

rc="$(run_case TOKEN_RC="2")"
assert_eq "a token that could not be minted arms nothing" "0" "$(count arms)"
assert_contains "  ... refusing by name" "could not mint" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case ARM_RC="1")"
assert_eq "a refused enqueue logs no landing-armed" "" "$(event_of landing-armed)"
assert_contains "  ... refusing by name" "could not enqueue or auto-merge" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

# landing_arm's own exit status distinguishes which step failed
# (agent-ops#532) — the refusal must carry that specific reason, not only the
# generic "could not enqueue or auto-merge" every code shares.
rc="$(run_case ARM_RC="6")"
assert_contains "  ... naming the specific step landing_arm's own exit status identifies" \
  "the enqueue mutation reported no merge-queue entry (a partial write)" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case ARM_METHOD="")"
assert_contains "an arm that printed no method is not read as a landing" \
  "could not enqueue or auto-merge" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

# --- A pull request URL that carries no number -------------------------------

rc="$(run_case PR_URL="https://github.com/Poetic-Poems/agent-ops/pull/not-a-number")"
assert_eq "an unparseable pull request URL arms nothing" "0" "$(count arms)"
assert_contains "  ... refusing by name" "could not parse a pull request number" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

# --- The happy path through run_landing_stage never marks retry -------------
# Gate 0 always calls `_landing_stage_attempt` with no sixth argument, so the
# ordinary round-of-approval path stays byte-identical to before the split.

rc="$(run_case)"
assert_eq "the ordinary path's landing-armed carries no retry field" \
  "null" "$(jq -c '.retry // null' <<<"$(event_of landing-armed)")"

# --- `_landing_stage_attempt`, called directly with RETRY set (2.1e) --------
# TD-PPagop-26081701: the landing-retry sweep calls this function directly,
# for a pull request outside the round that first approved it, passing a
# non-empty sixth argument. Same stubs and defaults as above, but the block
# is invoked without `run_landing_stage`'s own gate 0 (there is no "this
# round's Approver verdict" for a retry attempt to read).

# run_case_direct [KEY=VALUE ...]
# Assembles its own minimal harness — a fresh preamble plus `_refuse_block`/
# `$stage_block` — and calls `_landing_stage_attempt` directly with a
# non-empty RETRY, the way the 2.1e landing-retry sweep does. Deliberately
# not `run_case`'s own harness.sh: that one ends with `run_landing_stage`,
# gate 0's own entry point, which has no RETRY argument to pass through.
run_case_direct() {
  : >"$tmp_dir/events"; : >"$tmp_dir/arms"; : >"$tmp_dir/budget_applied"
  : >"$tmp_dir/budget_decide_args"; rm -f "$tmp_dir/armed_flag"
  : >"$tmp_dir/pp_ctl_args"; : >"$tmp_dir/retry_tier_args"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" PR_URL="$URL" COMPLEXITY="medium" \
    LEVEL="agent-merges-routine" ELIGIBLE="eligible" GATE_WORD="clean" GATE_REASON="" GATE_RC="0" \
    STANDING="APPROVED" BUDGET="arm" QUEUED="false" ARM_METHOD="enqueued" ALREADY_ARMED="0" \
    PP_CTL="ok" RETRY_TIER="critical" \
    "$@" \
    bash -c '
      set -euo pipefail
      source "$SCRIPT_DIR/lib/landing.sh"
      source "$SCRIPT_DIR/lib/merge-queue.sh"
      selected_repo="Poetic-Poems/agent-ops"; selected_source="tech-debt"
      state_repo="Poetic-Poems/agent-ops"; state_dir="$T/state"
      DEFAULTED_CONFIG="{}"; gate_default_branch="main"; pr_label="autonomous-agent"
      enabler_escalation_label="agent-escalation"; enabler_assignee="warwickallen"
      union_log="$T/union.jsonl"
      mkdir -p "$state_dir"; : > "$union_log"
      log_event() { printf "%s\t%s\n" "$1" "$2" >>"$T/events"; }
      merge_autonomy_effective_level() { printf "%s" "$LEVEL"; }
      landing_eligible() { printf "%s" "$ELIGIBLE"; }
      review_gate_verdict() { printf "%s" "$GATE_WORD"; return "${GATE_RC:-0}"; }
      approver_token_identity_login() { printf "pullwright-approver[bot]"; }
      landing_approver_standing_review_at() {
        printf "%s" "${STANDING:-}"; printf "\t%s" "${SUBMITTED_AT:-2026-08-17T10:00:00Z}"
        printf "\t%s" "${REVIEW_COMMIT:-sha-approved-head}"
        return "${STANDING_RC:-0}"
      }
      landing_protected_path_controls_ok() { printf "%s\n" "$*" >>"$T/pp_ctl_args"; printf "%s" "${PP_CTL:-ok}"; }
      landing_retry_tier() { printf "%s\n" "$*" >>"$T/retry_tier_args"; printf "%s" "${RETRY_TIER:-critical}"; }
      _handoff_blocking_reviewers() { return 0; }
      merge_budget_decide() {
        printf "%s\n" "$*" >>"$T/budget_decide_args"
        printf "{\"decision\":\"%s\",\"cap\":8,\"count\":8,\"anomaly\":false,\"waiting_backlog\":null}" "$BUDGET"
      }
      merge_budget_apply_decision() { printf "%s\n" "$1" >>"$T/budget_applied"; }
      merge_queue_probe() {
        if [[ -n "${DEQUEUE_REASON:-}" ]]; then
          printf "{\"queued\":%s,\"dequeue_reason\":\"%s\"}" "${QUEUED:-false}" "$DEQUEUE_REASON"
        else
          printf "{\"queued\":%s}" "${QUEUED:-false}"
        fi
      }
      approver_token_get() { printf "a-minted-token"; }
      landing_arm() { printf "slug=%s\tnumber=%s\ttoken=%s\n" "$1" "$2" "$3" >>"$T/arms"; printf "%s" "${ARM_METHOD-enqueued}"; }
      '"$refuse_block"'
      '"$stage_block"'
      _landing_stage_attempt "$selected_repo" "$PR_URL" "$COMPLEXITY" "$selected_source" "$gate_default_branch" "retry" "$ALREADY_ARMED"
      printf "%s" "$_landing_stage_attempt_armed" >"$T/armed_flag"
    ' >"$tmp_dir/stdout2" 2>"$tmp_dir/stderr2"
  printf '%s' "$?"
}

rc="$(run_case_direct)"
assert_eq "a direct retry attempt still arms an eligible, cleared PR" "0" "$rc"
assert_eq "  ... exactly once" "1" "$(count arms)"
assert_eq "  ... and marks the landing-armed event retry:true" \
  "true" "$(jq -c '.retry' <<<"$(event_of landing-armed)")"
assert_eq "  ... with no ALREADY_ARMED passed, merge_budget_decide sees 0" \
  "0" "$(budget_decide_args | awk '{print $NF}')"
assert_eq "  ... and marks _landing_stage_attempt_armed" "1" "$(armed_flag)"

rc="$(run_case_direct ELIGIBLE="ineligible:complexity is high, not low or medium")"
assert_eq "a retry attempt never arms complexity:high" "0" "$(count arms)"
assert_eq "  ... and marks the landing-refused event retry:true" \
  "true" "$(jq -c '.retry' <<<"$(event_of landing-refused)")"
assert_eq "  ... and never marks _landing_stage_attempt_armed" "0" "$(armed_flag)"

# --- Gate 6's dequeue check applies to a retry attempt too (PR #557 review
# round 2) — the sweep is exactly the caller the review's own concern was
# about: re-arming a checks-failure dequeue here is what turned into an
# unbounded, once-per-cycle merge-group CI burn.

rc="$(run_case_direct DEQUEUE_REASON="manual")"
assert_eq "a retry attempt never re-arms a manually-dequeued pull request" "0" "$(count arms)"
assert_contains "  ... refusing by name" "deliberate removal" "$(refusal)"
assert_eq "  ... and marks the landing-refused event retry:true" \
  "true" "$(jq -c '.retry' <<<"$(event_of landing-refused)")"
assert_eq "  ... and never marks _landing_stage_attempt_armed" "0" "$(armed_flag)"

rc="$(run_case_direct DEQUEUE_REASON="failed_checks")"
assert_eq "a retry attempt never blindly re-arms a checks-failure dequeue" "0" "$(count arms)"
assert_contains "  ... refusing by name" "dequeued source" "$(refusal)"

# --- ALREADY_ARMED is forwarded to merge_budget_decide verbatim (PR #557) ---
# TD-PPagop-26081701: the landing-retry sweep's own running per-pass tally —
# `_landing_retry_sweep_repo`'s `armed_this_pass` — reaches `merge_budget_decide`
# through this one parameter, so a candidate offered later in the same pass is
# judged against a budget that already accounts for what this pass itself has
# armed, not just what GitHub's own (necessarily lagging) merged-PR count shows.

rc="$(run_case_direct ALREADY_ARMED="5")"
assert_eq "a non-zero ALREADY_ARMED reaches merge_budget_decide as its own argument" \
  "5" "$(budget_decide_args | awk '{print $NF}')"
assert_eq "  ... and still arms when the stubbed decision itself says arm" "0" "$rc"

# --- Gate 4.5 on a retry attempt: TIER comes from the fleet log, never from
# an in-process fact this process never set (D18 WI-12, agent-ops#415) ------

rc="$(run_case_direct LEVEL="agent-merges-routine")"
assert_eq "below agent-merges-all, a retry attempt never consults gate 4.5 either" \
  "" "$(pp_ctl_args)"

rc="$(run_case_direct LEVEL="agent-merges-all")"
assert_eq "a retry attempt at agent-merges-all still arms when gate 4.5 clears" "0" "$rc"
assert_eq "  ... exactly once" "1" "$(count arms)"
assert_contains "  ... having resolved TIER via landing_retry_tier, from the fleet log" \
  "$URL" "$(retry_tier_args)"
assert_contains "  ... and consulting gate 4.5 with the standing review's own submitted_at and commit_id" \
  "critical 2026-08-17T10:00:00Z sha-approved-head" "$(pp_ctl_args)"

rc="$(run_case_direct LEVEL="agent-merges-all" PP_CTL="ineligible:touches a protected path at agent-merges-all but the approving engagement did not run at the critical tier (tier: standard)")"
assert_eq "a retry attempt gate 4.5 refuses is never armed" "0" "$(count arms)"
assert_contains "  ... naming the reason" "did not run at the critical tier" "$(refusal)"
assert_eq "  ... and marks the landing-refused event retry:true" \
  "true" "$(jq -c '.retry' <<<"$(event_of landing-refused)")"

# --- Result -------------------------------------------------------------------

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
