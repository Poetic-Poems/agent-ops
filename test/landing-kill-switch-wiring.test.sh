#!/usr/bin/env bash
#
# test/landing-kill-switch-wiring.test.sh — D18 issue #576: the autonomy
# kill-switch drill. Proves that with the fleet-wide kill switch
# (lib/merge-autonomy.sh, WI-2) engaged, a repository configured at each
# `merge_autonomy` rung above `human` collapses to `human` *through the real
# landing path* — `run_landing_stage`/`_landing_stage_attempt`, lifted
# verbatim out of agent-cycle.sh exactly as test/landing-wiring.test.sh
# already lifts them — and arms nothing, one case per rung (acceptance
# criterion 1).
#
# This is deliberately not the same proof test/merge-autonomy.test.sh already
# gives (issue #576's own "Don't redo": :154-206 there already proves the
# collapse at `merge_autonomy_effective_level` alone, including the
# per-repo-override case at :174-179, and restoration on clear). The only
# thing stubbed here is `merge_autonomy_kill_state` — the one external
# (fleet-flag) read `merge_autonomy_effective_level` makes — so
# `merge_autonomy_rank`, `merge_autonomy_configured_level` and
# `merge_autonomy_effective_level` itself all run for real, reading a real
# `DEFAULTED_CONFIG` that names each rung. Gate 1 always refuses in every
# case here (the whole point of the drill), so nothing past it in
# `_landing_stage_attempt` is ever reached and no other gate helper needs a
# stub at all.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/landing-kill-switch-wiring.test.sh
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
# Same technique test/landing-wiring.test.sh already uses: lift the real
# blocks out of agent-cycle.sh so assertions are about the shipped code.

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

# --- Assembly -------------------------------------------------------------------
# CONFIG_JSON names the rung under test; KILL_STATE controls the one stub.

cat >"$tmp_dir/harness.sh" <<'HARNESS'
# The shell options agent-cycle.sh itself runs under.
set -euo pipefail

# The real level-resolution machinery — merge_autonomy_rank,
# merge_autonomy_configured_level, merge_autonomy_effective_level — runs
# unstubbed, off the real DEFAULTED_CONFIG below.
# shellcheck source=lib/toggle.sh
source "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/github-limit.sh
source "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/merge-budget.sh
source "$SCRIPT_DIR/lib/merge-budget.sh"
# shellcheck source=lib/merge-autonomy.sh
source "$SCRIPT_DIR/lib/merge-autonomy.sh"
# shellcheck source=lib/landing.sh
source "$SCRIPT_DIR/lib/landing.sh"

# --- Cycle globals the block reads -------------------------------------------
selected_repo="Poetic-Poems/agent-ops"
selected_source="tech-debt"
state_repo="Poetic-Poems/agent-ops"
state_dir="$T/state"
DEFAULTED_CONFIG="$CONFIG_JSON"
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

# --- Stubs: the one external (fleet-flag) read in the whole chain -----------
log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

# merge_autonomy_effective_level's own one network read (lib/merge-autonomy.sh
# never calls fleet_flag_fetch_status directly for anything else this test
# reaches) — everything downstream of it in this file (merge_autonomy_rank,
# merge_autonomy_configured_level, the collapse logic itself, and gate 1's
# own landing_autonomy_refusal_reason, lib/landing.sh) runs for real.
merge_autonomy_kill_state() {
  printf '%s\n' "$*" >>"$T/kill_state_calls"
  if [[ "${KILL_STATE:-enabled}" == "enabled" ]]; then
    printf '{"state":"enabled"}'
  else
    printf '{"state":"disabled","record":{"reason":"drill","by":"test-operator","expires_at":null,"disabled_at":"2026-08-22T00:00:00Z","kind":"manual"}}'
  fi
}

# Gate 1 always refuses in every case this file runs (the kill switch is
# engaged in every one of them), so nothing past it is ever reached: no other
# gate helper — landing_eligible, review_gate_verdict, landing_arm, and so
# on — needs a stub, or even a definition, here.

HARNESS

{
  printf '%s\n' "$refuse_block"
  printf '%s\n' "$stage_block"
  printf '%s\n' "$wrapper_block"
  printf 'run_landing_stage "$PR_URL" "$COMPLEXITY"\n'
  printf '%s\n' 'printf "%s" "${_landing_stage_attempt_armed:-0}" >"$T/armed_flag"'
} >>"$tmp_dir/harness.sh"

URL="https://github.com/Poetic-Poems/agent-ops/pull/512"

# run_case CONFIG_JSON=... KILL_STATE=...
run_case() {
  : >"$tmp_dir/events"; : >"$tmp_dir/kill_state_calls"; rm -f "$tmp_dir/armed_flag"
  rm -rf "${tmp_dir:?}/state"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" PR_URL="$URL" COMPLEXITY="medium" \
    KILL_STATE="enabled" \
    "$@" \
    bash "$tmp_dir/harness.sh" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
  printf '%s' "$?"
}

events() { cat "$tmp_dir/events"; }
count() { local f="$tmp_dir/$1"; [[ -s "$f" ]] && wc -l <"$f" | tr -d ' ' || printf '0'; }
event_of() { grep -m1 "^$1"$'\t' "$tmp_dir/events" | cut -f2- || true; }
refusal() { jq -r '.reason' <<<"$(event_of landing-refused)" 2>/dev/null || true; }
armed_flag() { cat "$tmp_dir/armed_flag" 2>/dev/null || true; }
kill_state_calls() { cat "$tmp_dir/kill_state_calls" 2>/dev/null || true; }

# --- One case per rung (acceptance criterion 1) ------------------------------
# A repository configured at each rung above `human`, with the switch
# engaged, collapses to `human` through the real landing path and arms
# nothing — proof at the level `_landing_stage_attempt`/`landing_arm`
# actually run at, not merely at `merge_autonomy_effective_level` alone.

for rung in agent-approves agent-merges-routine agent-merges-all; do
  cfg="$(jq -nc --arg l "$rung" '{merge_autonomy: $l}')"
  rc="$(run_case CONFIG_JSON="$cfg" KILL_STATE="disabled")"
  assert_eq "configured at $rung, the engaged switch arms nothing" "0" "$rc"
  assert_eq "  ... logs exactly one event" "1" "$(count events)"
  assert_eq "  ... a landing-refused, never a landing-armed" "" \
    "$(event_of landing-armed)"
  assert_eq "  ... _landing_stage_attempt_armed stays 0" "0" "$(armed_flag)"
  assert_contains "  ... and the refusal names the kill switch" \
    "merge_autonomy kill switch is engaged fleet-wide" "$(refusal)"
  assert_contains "  ... asking merge_autonomy_kill_state for a FRESH read (issue #513)" \
    "fresh" "$(kill_state_calls)"
done

# --- Distinguishable from a level simply never raised (criterion 2, 4) ------
# The same rung — agent-approves — with the switch clear keeps the plain
# "effective level is …" wording, and never mentions the switch: a human
# reading the fleet log can tell the two refusal classes apart.

cfg_low="$(jq -nc '{merge_autonomy: "agent-approves"}')"
rc="$(run_case CONFIG_JSON="$cfg_low" KILL_STATE="enabled")"
assert_eq "with the switch clear, agent-approves refuses on the plain level wording" "0" "$rc"
assert_contains "  ... naming the level, not the switch" \
  "merge_autonomy effective level is agent-approves, not agent-merges-routine or agent-merges-all" \
  "$(refusal)"
assert_eq "  ... and never mentions the kill switch" "" \
  "$(refusal | grep -o 'kill switch' || true)"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "All assertions passed"
