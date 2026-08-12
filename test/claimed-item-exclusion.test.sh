#!/usr/bin/env bash
#
# test/claimed-item-exclusion.test.sh — regression tests for issue #304's
# deterministic-code pieces, lifted whole out of agent-cycle.sh rather than
# reimplemented, so a change to the real function is what this suite
# exercises:
#
#   - exclude_claimed_refs (requirement 3q): every pre-fetched source's own
#     candidates are filtered by item ref against the fleet's fresh claims
#     before they ever reach the Co-Ordinator — the generalisation of issue
#     #238's pr_number filter (test/pr-claim-exclusion.test.sh) to every
#     pre-fetched array, not only the three finishing sources'.
#   - is_pre_claimed (requirement 17a): the claim loop's pre-claim skip test —
#     true iff a candidate's repo+item is already in this cycle's own fresh
#     claimed set, the backstop for the four live-read sources (tech-debt,
#     project-review, failed-runs, implementation-plan) that have no
#     pre-fetched array for exclude_claimed_refs to filter.
#   - standdown_cause_for (requirement 17a): which of "pre-claimed",
#     "unreachable" or "raced" a stand-down carries, structured so a reader
#     never mistakes a selection defect (nothing attempted) for either kind
#     of genuine contention.
#
# Together these are what closes issue #304: a Co-Ordinator that read
# `claimed` correctly and proposed a known-claimed item anyway, reasoning
# that "an alternate costs nothing when the first claim succeeds" — first at
# any rank in its candidate list, and repeatedly across a whole day. Code, not
# prompt emphasis, is what makes a claimed item unselectable regardless of
# where in the ranking a model puts it.
#
# No network and no GitHub. Run directly:
#
#   ./test/claimed-item-exclusion.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- Lift the three functions whole out of agent-cycle.sh ----------------------
# Same extraction technique as test/pr-claim-exclusion.test.sh and
# test/signal-exit.test.sh: delimited by its own `name() {` line and a `}`
# back at column 0.
extract_function() {  # extract_function <name>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$SCRIPT_DIR/agent-cycle.sh"
}

exclude_claimed_refs_src="$(extract_function exclude_claimed_refs)"
is_pre_claimed_src="$(extract_function is_pre_claimed)"
standdown_cause_for_src="$(extract_function standdown_cause_for)"

for pair in "exclude_claimed_refs_src:exclude_claimed_refs" \
            "is_pre_claimed_src:is_pre_claimed" \
            "standdown_cause_for_src:standdown_cause_for"; do
  var="${pair%%:*}"; name="${pair#*:}"
  if [[ "${!var}" != *"$name()"* ]]; then
    printf 'FAIL - could not extract %s from agent-cycle.sh (renamed or moved?)\n' "$name"
    exit 1
  fi
done

eval "$exclude_claimed_refs_src"
eval "$is_pre_claimed_src"
eval "$standdown_cause_for_src"

# --- exclude_claimed_refs: item-ref filtering (requirement 3q) -----------------

candidates='[
  {"ref": "52", "title": "issue fifty-two"},
  {"ref": "53", "title": "issue fifty-three"},
  {"ref": "dependabot-alert-42", "title": "postcss bump"}
]'
filtered="$(exclude_claimed_refs "$candidates" '["52"]')"
assert_eq "exclude_claimed_refs drops the candidate whose ref is claimed" "2" \
  "$(jq 'length' <<<"$filtered")"
assert_eq "…keeping the unclaimed candidates" "1" \
  "$(jq '[.[] | select(.ref == "53")] | length' <<<"$filtered")"
assert_eq "…a claimed item is dropped regardless of its position in the array" "0" \
  "$(jq '[.[] | select(.ref == "dependabot-alert-42")] | length' \
     <<<"$(exclude_claimed_refs "$candidates" '["dependabot-alert-42"]')")"
assert_eq "an empty claimed-ref set filters nothing" "3" \
  "$(jq 'length' <<<"$(exclude_claimed_refs "$candidates" '[]')")"
assert_eq "a candidate with no ref at all is never filtered on" "1" \
  "$(jq 'length' <<<"$(exclude_claimed_refs '[{"title": "no ref"}]' '["52"]')")"
assert_eq "malformed claimed-refs JSON degrades to passing candidates through" "3" \
  "$(jq 'length' <<<"$(exclude_claimed_refs "$candidates" 'not json')")"
assert_eq "malformed candidates JSON degrades to the original string" "not json at all" \
  "$(exclude_claimed_refs 'not json at all' '["52"]')"

# Every pre-fetched source's own candidates use the same `ref` key
# (requirement 3o/3q: every gatherer mints `ref` as the exact claim key), so
# the same filter applies identically whichever source produced them.
issues_candidates='[{"source":"issues","ref":"52"},{"source":"issues","ref":"53"}]'
assert_eq "an issues candidate is excluded by the same ref-based filter" "1" \
  "$(jq 'length' <<<"$(exclude_claimed_refs "$issues_candidates" '["52"]')")"
register_hygiene_candidates='[{"source":"register-hygiene","ref":"register-hygiene-413128de0d60"}]'
assert_eq "a register-hygiene candidate is excluded the same way" "0" \
  "$(jq 'length' <<<"$(exclude_claimed_refs "$register_hygiene_candidates" '["register-hygiene-413128de0d60"]')")"

# --- is_pre_claimed: the claim loop's pre-attempt test (requirement 17a) -------

fleet_claimed='[
  {"repo": "org/repo-a", "item": "TD26051201", "age_hours": 2},
  {"repo": "org/repo-a", "item": "pr-57-review-1", "age_hours": 0, "pr_number": 57}
]'
if is_pre_claimed "org/repo-a" "TD26051201" "$fleet_claimed"; then
  printf 'ok   - %s\n' "a claimed repo+item reads pre-claimed"
else
  printf 'FAIL - %s\n' "a claimed repo+item reads pre-claimed"
  failures=$(( failures + 1 ))
fi
if is_pre_claimed "org/repo-a" "TD99999999" "$fleet_claimed"; then
  printf 'FAIL - %s\n' "an unclaimed item in a claimed repo reads pre-claimed"
  failures=$(( failures + 1 ))
else
  printf 'ok   - %s\n' "an unclaimed item in a claimed repo does not read pre-claimed"
fi
if is_pre_claimed "org/repo-b" "TD26051201" "$fleet_claimed"; then
  printf 'FAIL - %s\n' "the same item id in a different repo reads pre-claimed"
  failures=$(( failures + 1 ))
else
  printf 'ok   - %s\n' "the same item id in a different repo does not read pre-claimed"
fi
if is_pre_claimed "org/repo-a" "TD26051201" 'not json'; then
  printf 'FAIL - %s\n' "malformed fleet_claimed_json defaults to pre-claimed"
  failures=$(( failures + 1 ))
else
  printf 'ok   - %s\n' "malformed fleet_claimed_json degrades to not-pre-claimed, not a false positive"
fi
if is_pre_claimed "org/repo-a" "TD26051201" '[]'; then
  printf 'FAIL - %s\n' "an empty fleet claim set reads pre-claimed"
  failures=$(( failures + 1 ))
else
  printf 'ok   - %s\n' "an empty fleet claim set never reads pre-claimed"
fi

# --- standdown_cause_for: which cause a stand-down carries (requirement 17a) ---

assert_eq "zero attempts (every candidate skipped) reads pre-claimed" "pre-claimed" \
  "$(standdown_cause_for 0 0)"
assert_eq "every attempted candidate unreachable reads unreachable" "unreachable" \
  "$(standdown_cause_for 3 3)"
assert_eq "at least one attempted, not all unreachable, reads raced" "raced" \
  "$(standdown_cause_for 3 1)"
assert_eq "at least one attempted, none unreachable, reads raced" "raced" \
  "$(standdown_cause_for 2 0)"
assert_eq "zero attempts takes priority over the vacuous unreachable==attempts case" "pre-claimed" \
  "$(standdown_cause_for 0 0)"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
