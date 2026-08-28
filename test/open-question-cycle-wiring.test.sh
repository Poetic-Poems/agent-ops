#!/usr/bin/env bash
#
# test/open-question-cycle-wiring.test.sh — regression test for the
# open-question label-projection block in agent-cycle.sh (requirement 8f,
# agent-ops#668), guarding against agent-ops#889: `landing_open_question_
# label_project` (lib/landing.sh) documents exit 1 for its own `unrecorded`
# and `failed` words as ordinary, non-fatal outcomes — a repository this
# pipeline has not created the label in yet is the practical case, not a
# fault. Under this script's `set -euo pipefail`, an unguarded `var=$(cmd)`
# assignment takes on that exit status, and bash treats it exactly like any
# other failed command: the whole cycle exits before `run_approver_stage` or
# `run_landing_stage` ever run, stranding a green, ready pull request with
# no Approver review and no landing arming. Six fleet cycles hit this for
# real inside one week (see #889's own evidence table) before both
# `landing_open_question_label_project` call sites were guarded with
# `|| true`.
#
# The block is lifted verbatim out of agent-cycle.sh, the same way
# test/closing-keyword-wiring.test.sh and test/approver-wiring.test.sh lift
# their own blocks, so the assertions are about the shipped code rather than
# a copy of its logic. `jq` runs for real; everything that talks to GitHub,
# launches a model, self-heals a label or writes the log is stubbed and
# recorded.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/open-question-cycle-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

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
# From the open_questions read through the landing arming call at the end of
# requirement 8d — the whole span the two label-projection assignments sit
# ahead of, and exactly what an unguarded failure there would skip.
block="$(awk '
  /^  oq_json="\$\(jq -c/        { on = 1 }
  on                             { print }
  on && /^  run_landing_stage /  { exit }
' "$CYCLE")"

if [[ -z "$block" || "$block" != *"run_approver_stage"* || "$block" != *"run_landing_stage"* \
      || "$block" != *"landing_open_question_label_project"* ]]; then
  echo "FAIL - could not extract the open-question block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# --- Harness -------------------------------------------------------------------
# run_block WORD RC — stubs `landing_open_question_label_project` to print
# WORD and exit RC on every call, including the self-heal retry, and records
# whether the block's own tail actually ran. Prints every recorded call as
# `<name><TAB><args-or-detail>`, one per line, then a final `--` line iff the
# block reached its last statement; a block that dies partway through (the
# regression this test exists to catch) prints no `--` at all.
# shellcheck disable=SC2016  # The harness's own `$1`/`$2`/`$*`, written out literally for it to expand, not this shell's.
run_block() {
  local word="$1" rc="$2" harness="$tmp_dir/harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'impl_pr_url=%q\n' "https://github.com/Poetic-Poems/agent-ops/pull/889"
    printf 'selected_repo=%q\n' "Poetic-Poems/agent-ops"
    printf 'rev_status_json=%q\n' '{"open_questions":[{"question":"which repo owns this?"}]}'
    printf 'rev_complexity=%q\n' "medium"
    printf 'impl_trivial=%q\n' ""
    printf 'LANDING_OPEN_QUESTION_LABEL=%q\n' "open-question"
    printf 'events=%q\n' "$tmp_dir/events"
    printf '%s\n' 'log_event() { printf "%s\t%s\n" "$1" "$2" >> "$events"; }'
    printf 'landing_open_question_label_project() { printf %%s %q; return %q; }\n' "$word" "$rc"
    printf '%s\n' 'refinement_label_ensure_one() { printf "%s\t%s\n" "refinement_label_ensure_one" "$*" >> "$events"; }'
    printf '%s\n' 'approver_stage_complexity() { printf "medium"; }'
    printf '%s\n' 'run_approver_stage() { printf "%s\t%s\n" "run_approver_stage" "$*" >> "$events"; }'
    printf '%s\n' 'run_landing_stage() { printf "%s\t%s\n" "run_landing_stage" "$*" >> "$events"; }'
    printf '%s\n' "$block"
    printf '%s\n' 'printf -- "--\n"'
  } > "$harness"
  : > "$tmp_dir/events"
  bash "$harness" 2>"$tmp_dir/stderr"
  cat "$tmp_dir/events"
}

reached_end() {
  local word="$1" rc="$2" out
  out="$(run_block "$word" "$rc")"
  [[ "$out" == *$'--'* ]] && echo yes || echo no
}

# --- The regression itself: a `failed` projection must not kill the cycle ----
out="$(run_block "failed" 1)"
assert_eq "a 'failed' projection still logs open-question-raised" \
  "yes" "$([[ "$out" == *"open-question-raised"* ]] && echo yes || echo no)"
assert_contains "  ... with the truthful label_projection recorded" \
  '"label_projection":"failed"' "$out"
assert_eq "  ... and the self-heal retry actually runs (agent-ops#687)" \
  "yes" "$([[ "$out" == *"refinement_label_ensure_one"* ]] && echo yes || echo no)"
assert_eq "  ... and the round still reaches the Approver stage" \
  "yes" "$([[ "$out" == *"run_approver_stage"* ]] && echo yes || echo no)"
assert_eq "  ... and still reaches the landing arming step" \
  "yes" "$([[ "$out" == *"run_landing_stage"* ]] && echo yes || echo no)"
assert_eq "  ... and the block runs to its own end, not an early exit" \
  "yes" "$(reached_end "failed" 1)"

# --- `unrecorded` (the read failure) is covered by the same guard -----------
out="$(run_block "unrecorded" 1)"
assert_contains "an 'unrecorded' projection is recorded truthfully" \
  '"label_projection":"unrecorded"' "$out"
assert_eq "  ... and still reaches the Approver stage" \
  "yes" "$([[ "$out" == *"run_approver_stage"* ]] && echo yes || echo no)"
assert_eq "  ... and still reaches the landing arming step" \
  "yes" "$([[ "$out" == *"run_landing_stage"* ]] && echo yes || echo no)"
assert_eq "  ... and the block runs to its own end" \
  "yes" "$(reached_end "unrecorded" 1)"

# --- The healthy path is unaffected ------------------------------------------
out="$(run_block "added" 0)"
assert_contains "an 'added' projection is recorded truthfully" \
  '"label_projection":"added"' "$out"
assert_eq "  ... reaches the Approver stage" \
  "yes" "$([[ "$out" == *"run_approver_stage"* ]] && echo yes || echo no)"
assert_eq "  ... and the block runs to its own end" \
  "yes" "$(reached_end "added" 0)"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
