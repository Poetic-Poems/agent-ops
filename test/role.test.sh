#!/usr/bin/env bash
#
# test/role.test.sh — regression test for lib/role.sh and the role guard in
# both pipeline entry points.
#
# The guard has one job (stop a node that is not the active one from spending)
# and one way to fail badly: to resolve toward "active" when it shouldn't. That
# failure is not silent — it opens duplicate pull requests and pays for them —
# but it is only visible after the money is gone, so the assertions below are
# mostly about the fail-closed direction: every value that is not exactly
# `active` must stand the node down, and a standby tick must leave no trace in
# state_dir for the next snapshot restore to disagree with.
#
# The two end-to-end cases drive the real scripts with a stubbed `claude` and a
# throwaway HOME, because the guard's placement (before the config is read,
# after the flags are parsed) is as much the requirement as its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/role.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- role_current / role_is_active ---

unset AGENT_OPS_ROLE
assert_eq "unset is standby" "standby" "$(role_current)"
assert_eq "unset is not active" "no" "$(role_is_active && echo yes || echo no)"

export AGENT_OPS_ROLE=""
assert_eq "empty is standby" "standby" "$(role_current)"

export AGENT_OPS_ROLE="active"
assert_eq "active is active" "yes" "$(role_is_active && echo yes || echo no)"

export AGENT_OPS_ROLE="  Active
"
assert_eq "case and surrounding whitespace are tolerated" "yes" "$(role_is_active && echo yes || echo no)"

# The fail-closed cases: a typo, a near-miss and a value from some other
# vocabulary must all stand down rather than being generously interpreted.
for bad in activ ACTIV3 "active,standby" primary leader true 1 yes; do
  export AGENT_OPS_ROLE="$bad"
  assert_eq "'$bad' is not active" "no" "$(role_is_active && echo yes || echo no)"
done

export AGENT_OPS_ROLE="standby"
assert_contains "standby skip message names the role" "this node is standby" "$(role_skip_message agent-cycle)"
export AGENT_OPS_ROLE="activ"
assert_contains "an unrecognised value diagnoses itself" "AGENT_OPS_ROLE=activ is not a role" "$(role_skip_message agent-cycle)"

# --- End to end, against the real entry points ---
#
# A throwaway HOME makes config.json's ~-relative state_dir land in the temp
# tree, so "the tick left nothing behind" is an assertion about a directory
# this test owns. The stub `claude` (and a stub `gh` for review-cycle.sh, whose
# PATH check runs before the guard) satisfies each script's required-binary
# check without any risk of a real invocation: if the guard ever let a cycle
# through, the stub would fail the cycle rather than spend.
fake_home="$tmp_dir/home"
mkdir -p "$fake_home/.local/bin"
for stub in claude gh; do
  printf '#!/bin/sh\necho "%s stub: the role guard should have prevented this" >&2\nexit 1\n' "$stub" \
    > "$fake_home/.local/bin/$stub"
  chmod +x "$fake_home/.local/bin/$stub"
done

run_guarded() {  # run_guarded <role|-> <script> [args…]
  local role="$1" script="$2"; shift 2
  if [[ "$role" == "-" ]]; then
    env -u AGENT_OPS_ROLE HOME="$fake_home" "$SCRIPT_DIR/$script" "$@" 2>&1
  else
    env AGENT_OPS_ROLE="$role" HOME="$fake_home" "$SCRIPT_DIR/$script" "$@" 2>&1
  fi
}

out="$(run_guarded - agent-cycle.sh)"; rc=$?
assert_eq "agent-cycle: no role exits 0" "0" "$rc"
assert_contains "agent-cycle: no role logs a skip" "skipped — this node is standby" "$out"

out="$(run_guarded standby review-cycle.sh)"; rc=$?
assert_eq "review-cycle: standby exits 0" "0" "$rc"
assert_contains "review-cycle: standby logs a skip" "skipped — this node is standby" "$out"

assert_eq "a skipped tick writes no state" "" "$(ls -A "$fake_home/.local/state" 2>/dev/null)"

# The guard must not be the *only* thing standing a node down, and it must not
# stand down a human. Both are checked with the pipeline disabled, which is the
# next stand-down after the guard: reaching it proves the guard let the run
# past, and stops the run before it costs anything.
mkdir -p "$fake_home/.local/state/poetic-agents"
cat > "$fake_home/.local/state/poetic-agents/disabled.json" <<'EOF'
{"reason":"role.test.sh","disabled_at":"2026-07-20T00:00:00Z","expires_at":"forever","by":"test"}
EOF

out="$(run_guarded active agent-cycle.sh --repo Poetic-Poems/poetic)"; rc=$?
assert_eq "agent-cycle: active runs the cycle (reaching the switch)" "0" "$rc"
assert_contains "agent-cycle: active stood down on the switch, not the role" \
  "stand-down" "$(cat "$fake_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"

out="$(run_guarded - agent-cycle.sh --once)"; rc=$?
assert_eq "agent-cycle: --once bypasses the guard" "0" "$rc"
assert_contains "agent-cycle: --once reached the switch" "the pipeline is disabled" "$out"

out="$(run_guarded - review-cycle.sh --dry-run)"; rc=$?
assert_eq "review-cycle: --dry-run bypasses the guard" "0" "$rc"
assert_contains "review-cycle: --dry-run reached the switch" "review-stand-down" \
  "$(cat "$fake_home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null)"

# The switch commands answer on any node: an operator on a standby must still
# be able to ask what the pipeline is doing.
out="$(run_guarded standby agent-cycle.sh --status)"; rc=$?
assert_eq "--status works on a standby node" "0" "$rc"
assert_contains "--status reports the switch" "role.test.sh" "$out"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
