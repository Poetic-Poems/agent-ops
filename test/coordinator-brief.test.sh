#!/usr/bin/env bash
#
# test/coordinator-brief.test.sh — self-contained regression test for
# lib/coordinator-brief.sh (issue #78,
# docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 4b).
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/coordinator-brief.test.sh
#
# Exit status is 0 iff every assertion passed.

# The expected-output fixtures below are single-quoted on purpose: they carry
# literal backticks from the rendered Markdown, which must never expand.
# shellcheck disable=SC2016

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/coordinator-brief.sh
. "$SCRIPT_DIR/lib/coordinator-brief.sh"

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

# --- Two repos, each with several sources: header, separator, one row per
#     repo, sources numbered from 1 in the order config.json gave them. ---
two_repos='[
  {"slug": "org/repo-a", "sources": ["security", "issues:urgent", "tech-debt"]},
  {"slug": "org/repo-b", "sources": ["security", "tech-debt", "code-quality"]}
]'
expected_two_repos='| Repo | Work sources, in priority order |
|---|---|
| `org/repo-a` | 1. `security` · 2. `issues:urgent` · 3. `tech-debt` |
| `org/repo-b` | 1. `security` · 2. `tech-debt` · 3. `code-quality` |'
assert_eq "two repos render one row each, sources numbered in config order" \
  "$expected_two_repos" "$(coordinator_work_sources_table "$two_repos")"

# --- Reordering a repo's sources in the input changes only the numbering it
#     produces, which is the whole point: config.json drives this, not a
#     hand-edited prompt. ---
reordered='[{"slug": "org/repo-a", "sources": ["tech-debt", "security", "issues:urgent"]}]'
expected_reordered='| Repo | Work sources, in priority order |
|---|---|
| `org/repo-a` | 1. `tech-debt` · 2. `security` · 3. `issues:urgent` |'
assert_eq "reordering config sources reorders the rendered table" \
  "$expected_reordered" "$(coordinator_work_sources_table "$reordered")"

# --- A single-repo, single-source input is the smallest well-formed case. ---
one_repo='[{"slug": "org/solo", "sources": ["security"]}]'
expected_one_repo='| Repo | Work sources, in priority order |
|---|---|
| `org/solo` | 1. `security` |'
assert_eq "a single repo with one source renders one row" \
  "$expected_one_repo" "$(coordinator_work_sources_table "$one_repo")"

# --- An empty `repos` array is the input the Script never actually sends
#     (config.json requires at least one repo), but the function must not
#     choke on it: just the header and separator, no rows. ---
expected_empty='| Repo | Work sources, in priority order |
|---|---|'
assert_eq "an empty repos array renders only the header" \
  "$expected_empty" "$(coordinator_work_sources_table "[]")"

echo
if (( failures == 0 )); then
  echo "All coordinator-brief assertions passed."
  exit 0
else
  echo "$failures coordinator-brief assertion(s) FAILED."
  exit 1
fi
