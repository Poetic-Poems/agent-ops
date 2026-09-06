#!/usr/bin/env bash
#
# test/review-context-wiring.test.sh — R1c is wired into `review-cycle.sh`
# itself, not merely available to it.
#
# test/review-context.test.sh proves `review_context_missing_configured`
# reports a broken `review_instructions`/`review_context` path, and
# test/config-schema.test.sh proves `scripts/doctor.sh` turns that report
# into a `fail`. Neither proves the thing R1c actually promises: that the
# *cycle* refuses to start. A sweep that is written but never called, or
# called after the lock is taken, or called with the un-resolved config
# instead of the requirement-342 output, passes both of those files and
# still reviews every configured repository against less than the operator
# asked for — silently, which is the exact failure the fail-fast exists to
# prevent.
#
# Four behaviours:
#
#   broken path   a configured `review_instructions` entry that does not
#                 resolve exits the cycle non-zero, before any repository is
#                 touched, naming the repository, the field and the path so
#                 an operator can fix it without reading the source
#   per-repo      the same for a `review_context` override on one
#                 repository's own `repos[]` entry — the sweep reads
#                 requirement 342's resolved view, not `defaults` alone
#   resolvable    a path that does resolve is silently fine: no refusal, and
#                 the tick ends 0
#   unconfigured  and neither key configured at all is vacuously fine, which
#                 is every installation that does not use the facility
#
# The shim-node harness is test/review-not-before.test.sh's, for the same
# reason it gives: the real `review-cycle.sh` runs against a directory of
# symlinks back into this tree with a `config.json` of its own, so what is
# under test is the shipped script rather than a re-statement of it.
#
# No network — the refusal happens before the lock and before any `gh` call,
# and `project_review.repos` is otherwise emptied. Run directly:
# ./test/review-context-wiring.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# A shim node: symlinks back into the tree, plus a config of its own. `$1` is a
# jq filter applied to the real config, so each case states only its difference
# and every other required key stays in step with the shipped file. The state
# directory is created here rather than left to the run, because a relative
# `review_instructions` path resolves against it and the resolvable case needs
# somewhere to put the file.
make_node() {  # make_node <name> <jq-filter> -> prints its directory
  local name="$1" filter="$2"
  local dir="$tmp_dir/$name"
  mkdir -p "$dir" "$dir/home/.local/state/poetic-agents"
  local item
  for item in lib prompts scripts .claude review-cycle.sh agent-cycle.sh config.schema.json; do
    [[ -e "$SCRIPT_DIR/$item" ]] && ln -s "$SCRIPT_DIR/$item" "$dir/$item"
  done
  jq "$filter" "$SCRIPT_DIR/config.json" > "$dir/config.json"
  printf '%s' "$dir"
}

# Run in the *current* shell, with the output going to a file the caller
# reads afterwards, rather than the more obvious `out="$(run_review "$d")"`:
# a command substitution is a subshell, so an `RC=$?` set inside one is
# discarded on the way out and every exit-status assertion against it would
# read the variable's initial value instead — passing whatever the script
# actually returned. The status is half of what this file is testing.
RC=0
run_review() {  # run_review <dir> -> writes $tmp_dir/out.txt, sets RC
  local dir="$1"
  env HOME="$dir/home" AGENT_OPS_ROLE=active \
    timeout 60 "$dir/review-cycle.sh" --once > "$tmp_dir/out.txt" 2>&1
  RC=$?
}

# `state_repo: ""` keeps the fleet switch from reaching for one; the repos
# list stands in for a real installation's, since the sweep must see
# requirement 342's per-repository view rather than `defaults` alone.
BASE='.state_repo = "" | .project_review.repos = [{slug: "Test-Org/one"}, {slug: "Test-Org/two"}]'

# --- A configured path that does not resolve refuses the whole cycle ---------
d="$(make_node broken "$BASE | .project_review.defaults.review_instructions = [\"absent-instructions.md\"]")"
run_review "$d"; out="$(cat "$tmp_dir/out.txt")"
assert_eq "a broken review_instructions path exits non-zero" "1" "$RC"
assert_contains "the refusal says what it is refusing" \
  "configured review instructions/context paths do not resolve" "$out"
assert_contains "and names the repository it was resolved for" "Test-Org/one" "$out"
assert_contains "…every repository it was resolved for, not just the first" "Test-Org/two" "$out"
assert_contains "and the field, so the right key gets fixed" "review_instructions" "$out"
assert_contains "and the configured path as written" "absent-instructions.md" "$out"
assert_contains "and what it resolved to, which is where the typo shows" \
  "$d/home/.local/state/poetic-agents/absent-instructions.md" "$out"

# --- A per-repository override is swept too (requirement 342) ---------------
# `defaults` is untouched here: a sweep reading it alone would find nothing
# wrong and run the cycle against a repository whose own configured context
# is missing.
d="$(make_node per-repo "$BASE | .project_review.repos[1].review_context = [\"absent-context.md\"]")"
run_review "$d"; out="$(cat "$tmp_dir/out.txt")"
assert_eq "a broken per-repo review_context override exits non-zero too" "1" "$RC"
assert_contains "naming the repository that carries the override" "Test-Org/two" "$out"
assert_contains "and its field" "review_context" "$out"
assert_lacks "and not the repository that does not carry it" "Test-Org/one:" "$out"

# --- A path that resolves is silently fine ----------------------------------
d="$(make_node resolvable "$BASE | .project_review.repos = [] | .project_review.defaults.review_instructions = [\"present-instructions.md\"]")"
printf 'weigh the documentation as strictly as the code\n' \
  > "$d/home/.local/state/poetic-agents/present-instructions.md"
run_review "$d"; out="$(cat "$tmp_dir/out.txt")"
assert_lacks "a resolvable path raises no refusal" "do not resolve" "$out"
assert_eq "and the tick ends 0" "0" "$RC"

# --- Nothing configured at all is vacuously fine ----------------------------
# `project_review` is optional and most installations will never set either
# key; the sweep must not turn that into a fault.
d="$(make_node unconfigured "$BASE | .project_review.repos = []")"
run_review "$d"; out="$(cat "$tmp_dir/out.txt")"
assert_lacks "an installation configuring neither key raises no refusal" "do not resolve" "$out"
assert_eq "and its tick ends 0 as well" "0" "$RC"

echo
if (( failures == 0 )); then
  echo "All review-context wiring assertions passed."
  exit 0
else
  echo "$failures review-context wiring assertion(s) FAILED."
  exit 1
fi
