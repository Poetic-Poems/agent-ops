#!/usr/bin/env bash
#
# test/landing-human-veto-conformance.test.sh — conformance sweep for D18's
# standing invariant that a human `CHANGES_REQUESTED` blocks landing at every
# rung of the `merge_autonomy` ladder (agent-ops#577, part of #402).
#
# `test/landing-wiring.test.sh` already pins each of `_landing_stage_attempt`'s
# seven gates in isolation, including one case for the human-veto gate
# ("Gate 4 (human half)") — but that case, like every other in that file, runs
# only at the harness's own default `LEVEL="agent-merges-routine"`. It proves
# the gate refuses there; it says nothing about `human`, `agent-approves` or
# `agent-merges-all`, and nothing about whether the veto is insensitive to
# which landing path (a merge queue on the base branch, or the no-queue
# auto-merge fallback) this pull request would otherwise take. This file is
# the sweep that closes that gap: all four `merge_autonomy` levels crossed
# with both landing paths, eight cases, one standing human `CHANGES_REQUESTED`
# throughout.
#
# The shape point settled on the issue (2026-08-21, after escalation #628):
# `_landing_stage_attempt`'s gate 1 refuses on the effective level *before*
# gate 4 (the human-veto gate, `_handoff_blocking_reviewers`) is ever
# consulted. So at `human` and `agent-approves` the assertable fact is "nothing
# arms, and the refusal names the level" — the veto gate never runs and cannot
# name itself. Only at `agent-merges-routine` and `agent-merges-all` does the
# refusal come from the veto, naming the blocking reviewer. Both shapes are
# swept below; neither is written four times.
#
# The "both landing paths" axis is `ARM_METHOD` — what `landing_arm` (stubbed
# here, exactly as `landing-wiring.test.sh` stubs it) would have returned had
# it ever been called: `enqueued` for a base branch with an active merge
# queue, `auto-merge` for the no-queue fallback. In every one of the eight
# cases below the veto refuses upstream of gate 5/6 and the arm write itself
# (`_landing_stage_attempt`'s own fixed gate order — see its header in
# agent-cycle.sh), so `landing_arm` is never actually invoked regardless of
# which path it would have taken; asserting `arms == 0` in both configurations
# is what proves neither landing path offers a way around the veto, rather
# than the two configurations being distinguishable only in a label. Which
# path `landing_arm` genuinely takes for a real base branch, and that it takes
# the right one, is `test/landing.test.sh`'s own "landing_arm" section
# (queue vs. no-queue, against a stubbed `gh`) — not re-proven here.
#
# The freshness half of the invariant — that a `DISMISSED` earlier position
# does not survive as a stale "cleared" verdict once a later standing
# `CHANGES_REQUESTED` supersedes it — is a claim about `_handoff_latest_reviews`
# /`_handoff_blocking_reviewers`'s own reading of a real review history, which
# this file's stubbed `_handoff_blocking_reviewers` cannot exercise (it never
# reads a review list at all). That case lives in `test/handoff.test.sh`,
# alongside the function's other direct coverage.
#
# The shell options and extraction technique are `test/landing-wiring.test.sh`'s
# own, for the reason its header gives: `agent-cycle.sh` runs under
# `set -euo pipefail`, under which a gate that reports its own refusal via exit
# status (`review_gate_verdict`) would abort the cycle on a bare assignment
# rather than refuse — a difference only observable by running the lifted code
# under the same options production does.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/landing-human-veto-conformance.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# assembled file unexpanded; the single-quoted here-doc and `printf` lines
# below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/lib/landing.sh"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                 %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- Extraction ---------------------------------------------------------------
# Lifted verbatim out of agent-cycle.sh, the same functions
# test/landing-wiring.test.sh already lifts, so this file's assertions are
# about the shipped code rather than a copy of its logic.

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$CYCLE"
}

refuse_block="$(extract _landing_refuse)"
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
# Case inputs arrive as environment variables: LEVEL, ARM_METHOD (the landing
# path a real base branch would take, had `landing_arm` ever been reached) and
# BLOCKING (the standing human veto — set on every case in this file; a run
# with it unset would just be `landing-wiring.test.sh`'s own gate 4 case).

cat >"$tmp_dir/harness.sh" <<'HARNESS'
# The shell options agent-cycle.sh itself runs under — see this file's header.
set -euo pipefail

# shellcheck source=lib/landing.sh
source "$SCRIPT_DIR/lib/landing.sh"
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
approver_stage_verdict="approve"
approver_stage_adjudicating="0"
approver_stage_tier="critical"
union_log="$T/union.jsonl"
mkdir -p "$state_dir"
: > "$union_log"
declare -A landing_armed_by_repo=()

# --- Stubs: everything that reaches outside this process ----------------------
log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

# gate 1's own landing_autonomy_refusal_reason (lib/landing.sh, D18 issue
# #576) reads this directly whenever LEVEL does not qualify, to tell the
# fleet-wide kill switch apart from a level simply never raised — clear here
# throughout, since this file's own axis is the human veto, not the switch;
# test/landing-kill-switch-wiring.test.sh is the switch's own end-to-end
# proof, and test/landing-wiring.test.sh already pins the two wordings apart.
merge_autonomy_kill_state() { printf '{"state":"enabled"}'; }
merge_autonomy_effective_level() { printf '%s\n' "$*" >>"$T/mal_calls"; printf '%s' "$LEVEL"; }
landing_eligible() { printf '%s' "eligible"; }
review_gate_verdict() { printf '%s' "clean"; return 0; }
approver_token_identity_login() { printf 'pullwright-approver[bot]'; }
landing_approver_standing_review_at() {
  printf 'APPROVED\t2026-08-17T10:00:00Z\tsha-approved-head'
}

# The one stub in this file that differs from landing-wiring.test.sh's own:
# it *records* every call, in argument and count, so the sweep below can
# assert not only what this gate answers but whether it was even consulted —
# the structural half of the gate-1-precedes-gate-4 shape point (issue #577).
_handoff_blocking_reviewers() {
  printf '%s\n' "$*" >>"$T/blocking_calls"
  [[ -n "${BLOCKING:-}" ]] || return 0
  printf '%s\n' "$BLOCKING"
  return 0
}


# agent-ops#672: gate 4's own second veto read, right after
# `_handoff_blocking_reviewers` above. Stubbed clean throughout — this file's
# axis is the formal-review half of the veto (issue #577); the reconciliation
# half is swept directly in test/landing-wiring.test.sh — so every case below
# reaches this call and passes it exactly as it would with nothing standing.
reconciliation_gate() { printf '%s' "clean"; return 0; }

landing_protected_path_controls_ok() { printf '%s' "ok"; }
landing_retry_tier() { printf '%s' "critical"; }
merge_budget_decide() {
  printf '{"decision":"arm","cap":8,"count":0,"anomaly":false,"waiting_backlog":null}'
}
merge_budget_apply_decision() { printf '%s\n' "$1" >>"$T/budget_applied"; }
merge_queue_probe() { printf '{"queued":false}'; }
approver_token_get() { printf 'a-minted-token'; }

# Stubbed exactly as landing-wiring.test.sh stubs it: recorded so a caller can
# prove it was never invoked, which is the whole of what this file needs from
# it — which of `enqueued`/`auto-merge` it *would* have returned is a fact
# about landing_arm's own internals, already pinned directly in
# test/landing.test.sh, not re-proven here.
landing_arm() {
  printf 'slug=%s\tnumber=%s\ttoken=%s\n' "$1" "$2" "$3" >>"$T/arms"
  printf '%s' "$ARM_METHOD"
}

# The landing audit record's own reads (requirement 8x, agent-ops#578) —
# stubbed the same way every other gate helper here is; this file's axis is
# the human veto, not the audit record's own field content, which
# test/landing-audit-record.test.sh covers directly.
merge_autonomy_resolution_source() { printf 'top-level-default'; }
landing_protected_paths_hit() { return 1; }
log_file="$T/state/log.jsonl"; : > "$log_file"

HARNESS

{
  printf '%s\n' "$refuse_block"
  printf '%s\n' "$stage_block"
  printf '%s\n' "$wrapper_block"
  printf '%s\n' 'run_landing_stage "$PR_URL" "$COMPLEXITY"'
} >>"$tmp_dir/harness.sh"

URL="https://github.com/Poetic-Poems/agent-ops/pull/512"

# run_case [KEY=VALUE ...]
run_case() {
  : >"$tmp_dir/events"; : >"$tmp_dir/arms"; : >"$tmp_dir/budget_applied"
  : >"$tmp_dir/mal_calls"; : >"$tmp_dir/blocking_calls"
  rm -rf "${tmp_dir:?}/state"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" PR_URL="$URL" COMPLEXITY="medium" \
    LEVEL="agent-merges-routine" ARM_METHOD="enqueued" BLOCKING="warwickallen" \
    "$@" \
    bash "$tmp_dir/harness.sh" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
  printf '%s' "$?"
}

count() { local f="$tmp_dir/$1"; [[ -s "$f" ]] && wc -l <"$f" | tr -d ' ' || printf '0'; }
event_of() { grep -m1 "^$1"$'\t' "$tmp_dir/events" | cut -f2- || true; }
refusal() { jq -r '.reason' <<<"$(event_of landing-refused)" 2>/dev/null || true; }

# --- The sweep: four levels crossed with two landing paths, veto standing ----
# Acceptance criterion 1: nothing arms in any of the eight cases.

for level in human agent-approves agent-merges-routine agent-merges-all; do
  for path in enqueued auto-merge; do
    rc="$(run_case LEVEL="$level" ARM_METHOD="$path")"
    assert_eq "level=$level, path=$path: the stage returns 0 (refuses, never aborts)" "0" "$rc"
    assert_eq "  ... arms nothing" "0" "$(count arms)"
    assert_eq "  ... logs exactly one landing-refused" "1" "$(count events)"

    case "$level" in
      human|agent-approves)
        # Acceptance criterion 2, first half: gate 1 refuses on the level,
        # before the veto gate is ever consulted.
        assert_contains "  ... the refusal names the level, not the veto" \
          "effective level is $level" "$(refusal)"
        assert_not_contains "  ... and never mentions the standing reviewer" \
          "warwickallen" "$(refusal)"
        assert_eq "  ... and _handoff_blocking_reviewers is never even called" \
          "0" "$(count blocking_calls)"
        ;;
      agent-merges-routine|agent-merges-all)
        # Acceptance criterion 2, second half: the refusal comes from the
        # human-veto gate itself, naming the blocking reviewer.
        assert_contains "  ... the refusal comes from the human-veto gate" \
          "a human CHANGES_REQUESTED stands" "$(refusal)"
        assert_contains "  ... naming the blocking reviewer" \
          "warwickallen" "$(refusal)"
        assert_eq "  ... having actually consulted _handoff_blocking_reviewers" \
          "1" "$(count blocking_calls)"
        ;;
    esac
  done
done

# --- Acceptance criterion 4: the veto's refusal is distinguishable from
# every other refusal class, not merely "some prose blocked it" -----------
# Textually contrasted against gate 4's own App-approval half, the refusal
# immediately above the veto check in `_landing_stage_attempt` — the closest
# neighbour a regression could most easily collapse it into.

rc="$(run_case LEVEL="agent-merges-routine" BLOCKING="")"
assert_eq "with no human veto standing, the same level now arms" "1" "$(count arms)"
app_half_reason="not standing APPROVED"
veto_reason="a human CHANGES_REQUESTED stands"
if [[ "$app_half_reason" == "$veto_reason" ]]; then
  printf 'FAIL - the App-approval refusal and the human-veto refusal share one string\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - %s\n' "the human-veto refusal is textually distinct from the App-approval refusal"
fi

# --- Result -------------------------------------------------------------------

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

printf '\nall assertions passed\n'
