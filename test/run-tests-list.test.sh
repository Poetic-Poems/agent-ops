#!/usr/bin/env bash
#
# test/run-tests-list.test.sh — scripts/run-tests.sh's `--list` mode
# (agent-ops#734): printing the selected test basenames without Docker, so a
# caller bound by a hard per-command wall (the Reviewer stage's own 10-minute
# Bash-tool ceiling) can list the suite once and split it into groups that
# each finish comfortably inside it, instead of risking one unbounded
# invocation over the whole thing.
#
# The properties that matter:
#   - with no filter, it lists every test/*.test.sh basename, one per line;
#   - a filter narrows the list the same way the container's own loop would
#     (a substring match against the basename, OR'd across filters);
#   - a filter matching nothing exits 2 with a message, and prints nothing to
#     stdout — never a false empty "pass";
#   - it needs no `docker` on PATH at all — the entire point is to work in the
#     environment (this suite's own) that has none.
#
# Run directly: ./test/run-tests-list.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_TESTS="$SCRIPT_DIR/scripts/run-tests.sh"

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

# --- No filter: lists every test/*.test.sh basename, matching a plain glob,
# with no Docker on PATH at all. ---------------------------------------------
no_docker_path="$(printf '%s\n' "$PATH" | tr ':' '\n' | while read -r d; do
  [[ -x "$d/docker" ]] || printf '%s\n' "$d"
done | paste -sd: -)"

all_tests=( "$SCRIPT_DIR"/test/*.test.sh )
expected_count="${#all_tests[@]}"

out="$(PATH="$no_docker_path" "$RUN_TESTS" --list)"
rc=$?
assert_eq "--list exits 0 with no filter" "0" "$rc"
assert_eq "--list with no filter lists every test/*.test.sh" "$expected_count" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_contains "--list's output names this very test file" "run-tests-list.test.sh" "$out"

# --- A filter narrows the list the same way the container loop would: a
# substring match against the basename. --------------------------------------
filtered="$(PATH="$no_docker_path" "$RUN_TESTS" --list doctor)"
assert_eq "--list <filter> selects only matching basenames" "doctor.test.sh" "$filtered"

# --- Multiple filters OR together, exactly as the container's own loop does.
multi="$(PATH="$no_docker_path" "$RUN_TESTS" --list doctor run-tests-list)"
assert_contains "--list with two filters includes the first match" "doctor.test.sh" "$multi"
assert_contains "--list with two filters includes the second match" "run-tests-list.test.sh" "$multi"

# --- No match: exit 2, nothing on stdout. -----------------------------------
no_match_out="$(PATH="$no_docker_path" "$RUN_TESTS" --list no-such-test-exists 2>/dev/null)"
no_match_rc=0
PATH="$no_docker_path" "$RUN_TESTS" --list no-such-test-exists >/dev/null 2>&1 || no_match_rc=$?
assert_eq "--list with no match exits 2" "2" "$no_match_rc"
assert_eq "--list with no match prints nothing to stdout" "" "$no_match_out"

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
