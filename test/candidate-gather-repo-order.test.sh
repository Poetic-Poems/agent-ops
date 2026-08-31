#!/usr/bin/env bash
#
# test/candidate-gather-repo-order.test.sh — regression test for
# lib/candidate-gather.sh's `_repo_order_default_branch` (agent-ops#1085).
#
# `gather_ordered_repos`'s own repo-ordering walk used to read a repository's
# default branch and its tip commit's own date as two REST calls
# (`repos/<slug>`, then `repos/<slug>/commits/<default_branch>`); this
# function is the one GraphQL query that answers both at once. Every
# assertion below is really one assertion in different clothes: a caller must
# never read a failed or malformed read as a real answer — the loop around
# this function supplies its own `main`/epoch fallback (TD-PPagop-26081407)
# precisely because this function must not guess one itself.
#
# `gh` is stubbed through CANDIDATE_GATHER_GH; the stub applies the caller's
# own `--jq` filter to a fixture GraphQL response, the same technique
# test/merge-queue.test.sh and test/sweep-human-visibility.test.sh use for
# their own `gh api graphql` stubs.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/candidate-gather-repo-order.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/candidate-gather.sh
. "$SCRIPT_DIR/lib/candidate-gather.sh"

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

# --- The stub gh -------------------------------------------------------------
# $tmp_dir/response.json  the GraphQL response body, verbatim (the shape
#                          `gh api graphql` itself would hand to `--jq`)
# $tmp_dir/fail            present -> the call fails outright (network/auth)
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1 $2" == "api graphql" ]]; then
  [[ -f "$d/fail" ]] && { echo "stub gh: simulated network failure" >&2; exit 1; }
  jqfilter="." prev=""
  for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqfilter="$a"
    prev="$a"
  done
  jq -c "$jqfilter" "$d/response.json"
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"

# response DEFAULT_BRANCH COMMITTED_DATE — an ordinary answer; either argument
# empty renders that field entirely absent, the shape a real repository with
# no commits on its default branch (an empty repo) or a missing name would
# leave.
response() {
  local branch="${1:-}" at="${2:-}" ref='null'
  if [[ -n "$branch" || -n "$at" ]]; then
    ref="$(jq -nc --arg b "$branch" --arg a "$at" \
      '{name: (if $b == "" then null else $b end),
        target: (if $a == "" then null else {committedDate: $a} end)}')"
  fi
  jq -n --argjson ref "$ref" '{data: {repository: {defaultBranchRef: $ref}}}' \
    > "$tmp_dir/response.json"
}

read_default_branch() { CANDIDATE_GATHER_GH="$tmp_dir/gh" _repo_order_default_branch "$@"; }

# --- The ordinary answer ------------------------------------------------------
response main "2026-08-30T19:14:05Z"
out="$(read_default_branch o/r)"; rc=$?
assert_eq "an ordinary repository: exit 0" "0" "$rc"
assert_eq "  ... default_branch<TAB>commit_ts" "$(printf 'main\t2026-08-30T19:14:05Z')" "$out"

# --- A non-"main" default branch ---------------------------------------------
response trunk "2026-08-14T10:00:00Z"
out="$(read_default_branch o/r)"
assert_eq "a repository whose default branch is not main" \
  "$(printf 'trunk\t2026-08-14T10:00:00Z')" "$out"

# --- A failed gh call is unknown, never a guessed answer ----------------------
response main "2026-08-30T19:14:05Z"
: > "$tmp_dir/fail"
out="$(read_default_branch o/r)"; rc=$?
assert_eq "a failed gh call: non-zero exit" "1" "$rc"
assert_eq "  ... and no output a caller could mistake for a real answer" "" "$out"
rm -f "$tmp_dir/fail"

# --- An empty repository (no commits on its default branch, or GitHub simply
#     did not resolve one) is also unknown, never guessed at -----------------
response "" ""
out="$(read_default_branch o/r)"; rc=$?
assert_eq "a repository with no defaultBranchRef at all: non-zero exit" "1" "$rc"
assert_eq "  ... and no output" "" "$out"

# --- Half an answer is still no answer: this function draws no distinction
#     between the branch and the commit date being unreadable, leaving that
#     granularity to the caller's own pre-existing per-half `guard_warn` -----
response main ""
out="$(read_default_branch o/r)"; rc=$?
assert_eq "a branch name with no commit date: non-zero exit" "1" "$rc"
assert_eq "  ... and no output" "" "$out"

response "" "2026-08-30T19:14:05Z"
out="$(read_default_branch o/r)"; rc=$?
assert_eq "a commit date with no branch name: non-zero exit" "1" "$rc"
assert_eq "  ... and no output" "" "$out"

# --- A malformed response is also unknown -------------------------------------
printf '{"data":{}}' > "$tmp_dir/response.json"
out="$(read_default_branch o/r)"; rc=$?
assert_eq "a malformed response: non-zero exit" "1" "$rc"
assert_eq "  ... and no output" "" "$out"

# --- Bad arguments never reach gh at all --------------------------------------
response main "2026-08-30T19:14:05Z"
out="$(read_default_branch "")"; rc=$?
assert_eq "an empty slug is rejected before calling gh" "1" "$rc"
assert_eq "  ... no output" "" "$out"

out="$(read_default_branch "no-slash-here")"; rc=$?
assert_eq "a slug with no owner/repo separator is rejected before calling gh" "1" "$rc"
assert_eq "  ... no output" "" "$out"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
