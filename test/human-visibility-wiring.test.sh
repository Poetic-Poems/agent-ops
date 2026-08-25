#!/usr/bin/env bash
#
# test/human-visibility-wiring.test.sh — regression test for the block in
# agent-cycle.sh that turns requirement 38e's reduction into a repo entry's
# `human_visibility` array: which repos it calls
# `scripts/gather-human-visibility-hygiene.sh` for, what slice of the
# violations it hands each one, and where it puts the answer.
#
# `test/human-visibility-hygiene.test.sh` and
# `test/gather-human-visibility-hygiene.test.sh` cover the two halves either
# side of this block — the reduction that produces the violations and the
# gatherer that re-verifies them live — and both pass with the wiring between
# them broken. That is not hypothetical: the source shipped gated on
# `.sources // [] | any(.; . == "human-visibility")`, whose generator emits the
# `sources` *array* rather than its elements, so the condition compared an array
# to a string and was false for every repo ever configured. Every unit test on
# either side stayed green while the source could never fire once. The gate is
# the thing with no other cover, so it is what this file asserts:
#
#   - **A repo whose `sources` list `human-visibility` is gated in**, and its
#     entry's `human_visibility` array carries the gatherer's candidate. This is
#     the assertion the shipped gate failed.
#   - **A repo whose `sources` omit it is gated out** — left at `[]`, with the
#     gatherer never called for it. An opt-in source that fires anyway costs a
#     live `gh` re-check per cycle on a repo that asked for none.
#   - **Each repo is handed its own slice of the violations**, not the
#     fleet-wide array: the gatherer filters by slug itself, but a caller that
#     leaked another repo's violations into the ref digest would scope the item
#     to a set the repo has nothing to do with.
#   - **A gatherer that finds nothing still leaves a valid `[]`**, the ordinary
#     answer almost every cycle gets, rather than an absent key or a partial
#     assignment.
#   - **A repo with void residue of this shape but no live violation is walked
#     anyway** (agent-ops#646), so requirement 34n's liveness rule gets the
#     `.ok` marker it needs to retire that residue — while still contributing
#     no candidate, since the gatherer handed an empty slice returns one. The
#     opt-in gate still applies to it, and an unreadable reduction still walks
#     nobody: `[]` handed to the gatherer on violations we failed to read
#     would certify an emptiness nothing established.
#
# The block is lifted verbatim out of agent-cycle.sh, the same way
# test/finish-then-continue.test.sh lifts the chain block, so the assertions are
# about the shipped code rather than a copy of its logic. Its two callees are
# stubbed: `human_visibility_violations` (covered by its own test) and
# `gather_human_visibility_hygiene` (a thin wrapper over the gatherer, which has
# its own test), the latter also recording every slug it is called with so the
# gate can be asserted in both directions.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/human-visibility-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- Extraction ---------------------------------------------------------------
# From the `human_visibility_json` initialiser through the `done < <(…)` that
# closes the walk, inclusive — the span requirement 38e's own comments sit
# above. The terminator was a bare `fi` until agent-ops#646: the walk had been
# wrapped in an `if` on the violation count, which the widened repo list
# replaced with the list itself being empty. `|| true)` ends the process
# substitution feeding the loop and appears nowhere else in the block.
extract_hv_block() {
  awk '
    /^human_visibility_json="\$\(human_visibility_violations / { on = 1 }
    on                   { print }
    on && /\|\| true\)$/ { exit }
  ' "$1"
}

block="$(extract_hv_block "$SCRIPT_DIR/lib/candidate-gather.sh")"
if [[ -z "$block" ]]; then
  echo "FAIL - could not extract the human-visibility block from lib/candidate-gather.sh — has it moved?" >&2
  exit 1
fi

# --- Assembly -----------------------------------------------------------------
# run_block VIOLATIONS_JSON REPOS_JSON GATHER_RESULT_JSON [VOID_JSON]
# Runs an assembled script that stubs the block's two callees, sets the globals
# it reads, executes it under the same `set -euo pipefail` agent-cycle.sh runs
# under, and prints the resulting `ordered_repos_json` followed by a `--` line
# and one line per slug the gatherer was called with (in call order).
# VOID_JSON defaults to `[]` — the ordinary cycle, with no residue of this
# shape to widen the walk with.
# shellcheck disable=SC2016  # The harness's own `$1`/`$2`/`$ordered_repos_json`, written out literally for it to expand, not this shell's.
run_block() {
  local violations="$1" repos="$2" gathered="$3" void="${4:-[]}" harness="$tmp_dir/harness.sh"
  : > "$tmp_dir/calls"
  {
    printf '%s\n' 'set -euo pipefail'
    printf '. %q\n' "$SCRIPT_DIR/lib/void-liveness.sh"
    printf '%s\n' 'guard_warn() { :; }'
    printf 'union_log=%q\n' "$tmp_dir/union.jsonl"
    printf 'void_json=%q\n' "$void"
    printf 'ordered_repos_json=%q\n' "$repos"
    printf '%s\n' 'human_visibility_violations() { printf "%s" '"$(printf '%q' "$violations")"'; }'
    printf '%s\n' 'gather_human_visibility_hygiene() {'
    printf '  printf "%%s\\n" "$1" >> %q\n' "$tmp_dir/calls"
    printf '  printf "%%s\\n" "$2" >> %q\n' "$tmp_dir/slices"
    printf '  printf "%%s" %q\n' "$gathered"
    printf '%s\n' '}'
    printf '%s\n' "$block"
    printf '%s\n' 'printf "%s\n" "$ordered_repos_json"'
    printf '%s\n' 'printf -- "--\n"'
    printf 'cat %q 2>/dev/null || true\n' "$tmp_dir/calls"
  } > "$harness"
  : > "$tmp_dir/slices"
  bash "$harness" 2>/dev/null
}

hv_of() { jq -c --arg r "$2" '.[] | select(.slug == $r) | .human_visibility' <<<"$1"; }

CANDIDATE='[{"source":"human-visibility","ref":"human-visibility-1a2b3c4d5e6f","url":"https://github.com/o/gated-in/pulls","problems":["HUMAN VISIBILITY  https://github.com/o/gated-in/pull/9: could not request review from someone"],"body":"…"}]'

# Two repos, identical but for the one source token that gates this block.
REPOS='[{"slug":"o/gated-in","human_visibility":[],"sources":["merge-conflicts","human-visibility","abandoned-drafts"]},{"slug":"o/gated-out","human_visibility":[],"sources":["merge-conflicts","abandoned-drafts"]}]'

# --- A violation on each repo, only one of which opted in ----------------------

VIOLATIONS='[{"repo":"o/gated-in","pr_url":"https://github.com/o/gated-in/pull/9","detail":"could not request review from someone","ts":"2026-08-12T09:00:00Z"},{"repo":"o/gated-out","pr_url":"","detail":"could not list o/gated-out'"'"'s open pull requests — sweeping nothing","ts":"2026-08-12T09:00:00Z"}]'

out="$(run_block "$VIOLATIONS" "$REPOS" "$CANDIDATE")"
repos_out="$(sed '/^--$/,$d' <<<"$out")"
calls_out="$(sed -n '/^--$/,$p' <<<"$out" | tail -n +2)"

assert_eq "a repo whose sources list human-visibility is gated in" \
  "$CANDIDATE" "$(hv_of "$repos_out" o/gated-in)"
assert_eq "  ... and the gatherer was called for it, exactly once" \
  "o/gated-in" "$calls_out"
assert_eq "a repo whose sources omit human-visibility keeps an empty array" \
  "[]" "$(hv_of "$repos_out" o/gated-out)"
assert_eq "  ... and is handed its own slice of the violations, not the fleet's" \
  '[{"repo":"o/gated-in","pr_url":"https://github.com/o/gated-in/pull/9","detail":"could not request review from someone","ts":"2026-08-12T09:00:00Z"}]' \
  "$(head -1 "$tmp_dir/slices")"

# --- A gatherer whose live re-check drops everything ---------------------------

out="$(run_block "$VIOLATIONS" "$REPOS" '[]')"
repos_out="$(sed '/^--$/,$d' <<<"$out")"

assert_eq "a candidate the live re-check drops leaves a valid empty array" \
  "[]" "$(hv_of "$repos_out" o/gated-in)"

# --- No violations at all: the ordinary cycle ---------------------------------

out="$(run_block '[]' "$REPOS" "$CANDIDATE")"
repos_out="$(sed '/^--$/,$d' <<<"$out")"
calls_out="$(sed -n '/^--$/,$p' <<<"$out" | tail -n +2)"

assert_eq "no violations leaves every repo's array empty" \
  "[][]" "$(hv_of "$repos_out" o/gated-in)$(hv_of "$repos_out" o/gated-out)"
assert_eq "  ... and calls the gatherer for no repo at all" "" "$calls_out"

# --- The widened walk (agent-ops#646) -----------------------------------------
# A repo whose violations have all cleared is the state in which its
# `human-visibility-<hash>` void residue should retire — and the state the
# unwidened walk skipped, leaving no `.ok` marker for the liveness rule to
# read and the residue stuck for ever.

HV_VOID='[{"repo":"o/gated-in","item":"human-visibility-1a2b3c4d5e6f","ts":"2026-07-01T00:00:00Z"}]'

out="$(run_block '[]' "$REPOS" "$CANDIDATE" "$HV_VOID")"
repos_out="$(sed '/^--$/,$d' <<<"$out")"
calls_out="$(sed -n '/^--$/,$p' <<<"$out" | tail -n +2)"

assert_eq "a repo with void residue but no live violation is walked anyway" \
  "o/gated-in" "$calls_out"
assert_eq "  ... handed an empty slice, since it has no violation of its own" \
  "[]" "$(head -1 "$tmp_dir/slices")"
assert_eq "  ... and contributes no candidate: the real gatherer returns [] on []" \
  "[]" "$(hv_of "$(sed '/^--$/,$d' <<<"$(run_block '[]' "$REPOS" '[]' "$HV_VOID")")" o/gated-in)"

# The opt-in gate is not weakened by the widening: residue in a repo that
# never asked for this source still costs no live re-check.
HV_VOID_OUT='[{"repo":"o/gated-out","item":"human-visibility-1a2b3c4d5e6f","ts":"2026-07-01T00:00:00Z"}]'
out="$(run_block '[]' "$REPOS" "$CANDIDATE" "$HV_VOID_OUT")"
calls_out="$(sed -n '/^--$/,$p' <<<"$out" | tail -n +2)"
assert_eq "residue in a repo whose sources omit human-visibility is still gated out" \
  "" "$calls_out"

# A void naming a shape this rule does not own must not widen the walk either.
out="$(run_block '[]' "$REPOS" "$CANDIDATE" \
       '[{"repo":"o/gated-in","item":"register-hygiene-1a2b3c4d5e6f","ts":"2026-07-01T00:00:00Z"}]')"
calls_out="$(sed -n '/^--$/,$p' <<<"$out" | tail -n +2)"
assert_eq "a void of another shape does not widen the walk" "" "$calls_out"

# The gate that stops a marker certifying an emptiness nothing established:
# an unreadable reduction walks nobody, residue or no residue.
out="$(run_block 'not valid json' "$REPOS" "$CANDIDATE" "$HV_VOID")"
calls_out="$(sed -n '/^--$/,$p' <<<"$out" | tail -n +2)"
assert_eq "an unreadable violation reduction walks no repo, residue notwithstanding" \
  "" "$calls_out"

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
