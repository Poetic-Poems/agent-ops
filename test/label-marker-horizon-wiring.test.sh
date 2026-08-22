#!/usr/bin/env bash
#
# test/label-marker-horizon-wiring.test.sh — regression test for *where* in
# agent-cycle.sh requirement 39f's `union_log_horizon` is captured, and for the
# two read-back call sites that have to be handed it (agent-ops#670).
#
# `test/label-marker.test.sh` covers the halves either side of this wiring —
# `log_latest_ts` itself, and `own_class`'s grace test against a `NOW` the
# fixture hands it — and every one of those assertions passes with the wiring
# between them broken, because they drive
# `label_filter_own_applications`/`label_own_stale_applications` directly
# rather than through the cycle script. That is exactly the gap this file
# closes, and the spec's own gotchas row ("A 'snapshot' horizon captured too
# late is wall clock wearing a disguise") names the two ways it opens:
#
#   - **The capture moves after an append.** `$union_log` is not immutable
#     after it is snapshotted: the cycle appends its own fresh local log lines
#     into it three times before the requirement-39f read-back runs. A capture
#     that lands after any of them reads this node's own just-written events,
#     so the horizon tracks wall clock again and the fix evaporates silently —
#     with every fixture in `test/label-marker.test.sh` still green.
#   - **A call site stops passing it.** Both readers share
#     `_label_own_class_jq_def` precisely so they cannot disagree about a
#     candidate's class; one of them falling back to the `date -u` default
#     reintroduces that disagreement, and again changes nothing any unit
#     fixture can see.
#
# Both are textual facts about the shipped script, so this file asserts them by
# reading agent-cycle.sh rather than by executing it: there is no way to
# observe the capture's *position* from inside a stubbed run of the block, and
# lifting the block verbatim (as the other `*-wiring` tests do) would lift the
# ordering along with it and assert nothing.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/label-marker-horizon-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

# --- Where the horizon is captured -------------------------------------------
# Three line numbers, in the order they must appear: the snapshot that
# materialises `$union_log`, the horizon captured from it, and the first of the
# appends that go on to mutate it.
first_line_matching() { grep -n -m1 -- "$1" "$CYCLE" | cut -d: -f1; }

# shellcheck disable=SC2016  # grep patterns: the `$` is agent-cycle.sh's own
# variable reference, matched literally, not one to expand here.
snapshot_line="$(first_line_matching 'fleet_logs .* > "\$union_log"')"
horizon_line="$(first_line_matching '^union_log_horizon=')"
# shellcheck disable=SC2016  # ditto — agent-cycle.sh's `$union_log`, literal.
append_line="$(first_line_matching '>> "\$union_log"')"

assert_eq "the union-log snapshot is still where this test expects to find it" \
  "yes" "$([[ -n "$snapshot_line" ]] && echo yes || echo no)"
assert_eq "the horizon is captured from the snapshot at all" \
  "yes" "$([[ -n "$horizon_line" ]] && echo yes || echo no)"
assert_eq "the cycle still appends its own log lines into the snapshot" \
  "yes" "$([[ -n "$append_line" ]] && echo yes || echo no)"

if [[ -z "$snapshot_line" || -z "$horizon_line" || -z "$append_line" ]]; then
  printf '\n%d assertion(s) failed\n' "$(( failures + 1 ))" >&2
  echo "FAIL - could not locate the union-log snapshot wiring in agent-cycle.sh — has it moved?" >&2
  exit 1
fi

assert_eq "the horizon is captured after the snapshot that materialises \$union_log" \
  "yes" "$([[ "$horizon_line" -gt "$snapshot_line" ]] && echo yes || echo no)"
assert_eq "the horizon is captured before the first append into \$union_log" \
  "yes" "$([[ "$horizon_line" -lt "$append_line" ]] && echo yes || echo no)"

# --- What the read-back call sites are handed --------------------------------
# Both calls are wrapped across two lines with a trailing backslash, so join
# continuations before looking for the argument.
joined="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$CYCLE")"

call_passes_horizon() {
  local fn="$1" call
  call="$(grep -m1 -- "$fn \"" <<<"$joined")"
  # shellcheck disable=SC2016  # the literal text sought in agent-cycle.sh.
  [[ "$call" == *'"$union_log_horizon"'* ]] && echo yes || echo no
}

assert_eq "label_filter_own_applications is passed the horizon as its NOW" \
  "yes" "$(call_passes_horizon label_filter_own_applications)"
assert_eq "label_own_stale_applications is passed the same horizon" \
  "yes" "$(call_passes_horizon label_own_stale_applications)"

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
