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
stage_block="$(extract run_landing_stage)"
if [[ -z "$refuse_block" || "$refuse_block" != *"landing-refused"* ]]; then
  echo "FAIL - could not extract _landing_refuse from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if [[ -z "$stage_block" || "$stage_block" != *"landing_arm"* ]]; then
  echo "FAIL - could not extract run_landing_stage from agent-cycle.sh — has it moved?" >&2
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
mkdir -p "$state_dir"

# --- Stubs: everything that reaches outside this process ----------------------
log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

# Records its own argv (issue #513, PR #506 review follow-up) so a test can
# confirm run_landing_stage asks for a FRESH read of the level rather than
# the process-lifetime memo every advisory reader uses — this stage arms a
# real merge/enqueue under the answer, so a kill set mid-cycle must stop it
# at this stage boundary, not wait for the next cycle's process. The same
# discipline test/approver-wiring.test.sh already pins for run_approver_stage.
merge_autonomy_effective_level() { printf '%s\n' "$*" >>"$T/mal_calls"; printf '%s' "$LEVEL"; }

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

landing_approver_standing_review() {
  printf '%s\n' "$*" >>"$T/standing_args"
  [[ "${STANDING_RC:-0}" == "0" ]] || return "$STANDING_RC"
  printf '%s' "${STANDING:-}"
}

_handoff_blocking_reviewers() {
  [[ "${BLOCKING_RC:-0}" == "0" ]] || return "$BLOCKING_RC"
  [[ -z "${BLOCKING:-}" ]] || printf '%s\n' "$BLOCKING"
  return 0
}

merge_budget_decide() { printf '{"decision":"%s","cap":8,"count":8,"anomaly":false,"waiting_backlog":null}' "$BUDGET"; }
merge_budget_apply_decision() { printf '%s\n' "$1" >>"$T/budget_applied"; }

merge_queue_probe() {
  [[ "${QUEUE_RC:-0}" == "0" ]] || return "$QUEUE_RC"
  printf '{"queued":%s}' "${QUEUED:-false}"
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
  printf 'run_landing_stage "$PR_URL" "$COMPLEXITY"\n'
  # Reached only if the stage returned rather than aborting the cycle — the
  # difference this file exists to pin (see header).
  printf '%s\n' 'printf "stage-returned\n" >>"$T/reached"'
} >>"$tmp_dir/harness.sh"

URL="https://github.com/Poetic-Poems/agent-ops/pull/512"

# run_case [KEY=VALUE ...]
# Runs the block once against a clean happy-path default, overridden by the
# environment assignments given, and leaves $tmp_dir/{events,arms,...} holding
# what it did. Prints the block's own exit status.
run_case() {
  : >"$tmp_dir/events"; : >"$tmp_dir/arms"; : >"$tmp_dir/budget_applied"
  : >"$tmp_dir/reached"; : >"$tmp_dir/eligible_args"; : >"$tmp_dir/standing_args"
  : >"$tmp_dir/mal_calls"
  rm -rf "${tmp_dir:?}/state"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" PR_URL="$URL" COMPLEXITY="medium" \
    VERDICT="approve" ADJUDICATING="0" LEVEL="agent-merges-routine" \
    ELIGIBLE="eligible" GATE_WORD="clean" GATE_REASON="" GATE_RC="0" \
    STANDING="APPROVED" BUDGET="arm" QUEUED="false" ARM_METHOD="enqueued" \
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
  assert_eq "  ... returning 0" "0" "$rc"
done

rc="$(run_case LEVEL="agent-merges-all")"
assert_eq "agent-merges-all arms on the same terms" "1" "$(count arms)"
assert_eq "  ... returning 0" "0" "$rc"

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

# --- The write itself, and its failures --------------------------------------

rc="$(run_case TOKEN_RC="2")"
assert_eq "a token that could not be minted arms nothing" "0" "$(count arms)"
assert_contains "  ... refusing by name" "could not mint" "$(refusal)"
assert_eq "  ... returning 0" "0" "$rc"

rc="$(run_case ARM_RC="1")"
assert_eq "a refused enqueue logs no landing-armed" "" "$(event_of landing-armed)"
assert_contains "  ... refusing by name" "could not enqueue or auto-merge" "$(refusal)"
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

# --- Result -------------------------------------------------------------------

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
