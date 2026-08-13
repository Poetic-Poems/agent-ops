#!/usr/bin/env bash
#
# test/human-visibility-hygiene.test.sh — regression test for
# lib/human-visibility-hygiene.sh's `human_visibility_violations` (requirement
# 38e): the reduction over the log union that turns
# scripts/sweep-human-visibility.sh's `warning` events back into the set of
# violations still standing.
#
# The rule is "most recent event per identity wins", the same shape
# `_latest_unresolved` already applies to a block and its clearance
# (lib/cycle-state.sh) — asserted from both directions:
#
#   - **Too eager** keeps a violation a later success already answered. Every
#     later `human-review-requested` or `human-nudged` for the same `pr_url`
#     must clear the identical-`pr_url` warning that preceded it.
#   - **Too shy** drops a violation nothing has actually resolved: an
#     unrelated warning (a different sweep entirely, or a different repo/PR)
#     must never clear it, and a repo-level (empty `pr_url`) violation must
#     survive with no per-PR success able to touch it at all — the gap
#     scripts/gather-human-visibility-hygiene.sh's own live re-check exists to
#     close, not this reduction.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/human-visibility-hygiene.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/human-visibility-hygiene.sh
. "$SCRIPT_DIR/lib/human-visibility-hygiene.sh"

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

warning_line() {  # <repo> <pr_url> <detail>
  jq -nc --arg r "$1" --arg u "$2" --arg d "$3" \
    '{ts: "2026-08-08T00:00:00Z", cycle: "c", node: "n", event: "warning",
      detail: ("human-visibility sweep (" + $r + "): " + ({pr_url: $u, detail: $d} | tostring))}'
}

log="$tmp_dir/log.jsonl"

# --- An empty or missing log is [] ------------------------------------------
assert_eq "a missing log is []" "[]" "$(human_visibility_violations "$tmp_dir/nope.jsonl")"
: > "$log"
assert_eq "an empty log is []" "[]" "$(human_visibility_violations "$log")"

# --- A single repo-level (listing) warning survives, with no PR to clear it -
{
  warning_line "o/a" "" "could not list o/a's open pull requests — sweeping nothing"
} > "$log"
out="$(human_visibility_violations "$log")"
assert_eq "a lone repo-level warning survives" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... naming the repo" "o/a" "$(jq -r '.[0].repo' <<<"$out")"
assert_eq "  ... with an empty pr_url" "" "$(jq -r '.[0].pr_url' <<<"$out")"

# --- A per-PR warning is cleared by a later success for the same pr_url ----
{
  warning_line "o/a" "https://github.com/o/a/pull/9" "could not request review from foo"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-review-requested", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/9", reviewers: ["foo"]}'
} > "$log"
assert_eq "a later success clears the same pr_url's warning" \
  "0" "$(jq 'length' <<<"$(human_visibility_violations "$log")")"

# --- A nudge, not only a review-request, also clears -----------------------
{
  warning_line "o/a" "https://github.com/o/a/pull/9" "could not post the idle nudge comment"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-nudged", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/9", reviewer: "foo"}'
} > "$log"
assert_eq "a later nudge clears the same pr_url's warning" \
  "0" "$(jq 'length' <<<"$(human_visibility_violations "$log")")"

# --- An unrelated success does not clear a different identity --------------
{
  warning_line "o/a" "https://github.com/o/a/pull/9" "could not request review from foo"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-review-requested", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/10", reviewers: ["foo"]}'
} > "$log"
out="$(human_visibility_violations "$log")"
assert_eq "a different pr_url's success leaves this one standing" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... still naming pull 9" "https://github.com/o/a/pull/9" "$(jq -r '.[0].pr_url' <<<"$out")"

# --- A warning from a different sweep entirely is ignored -------------------
{
  jq -nc '{ts: "2026-08-08T00:00:00Z", cycle: "c", node: "n", event: "warning",
            detail: "orphan-branch sweep (o/a): something else entirely"}'
} > "$log"
assert_eq "a differently-shaped warning is not read as human-visibility" \
  "0" "$(jq 'length' <<<"$(human_visibility_violations "$log")")"

# --- Two repos' violations both survive, independently ---------------------
{
  warning_line "o/a" "" "could not list o/a's open pull requests — sweeping nothing"
  warning_line "o/b" "https://github.com/o/b/pull/1" "could not request review from bar"
} > "$log"
out="$(human_visibility_violations "$log")"
assert_eq "two repos' violations both survive" "2" "$(jq 'length' <<<"$out")"
assert_eq "  ... repos sorted" "o/a
o/b" "$(jq -r '.[].repo' <<<"$out" | sort)"

# --- The latest detail wins when the identity repeats -----------------------
{
  warning_line "o/a" "https://github.com/o/a/pull/9" "could not request review from foo"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n", event: "warning",
            detail: ("human-visibility sweep (o/a): "
                     + ({pr_url: "https://github.com/o/a/pull/9",
                         detail: "could not post the idle nudge comment"} | tostring))}'
} > "$log"
out="$(human_visibility_violations "$log")"
assert_eq "a repeated identity keeps only the latest detail" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... the newer one" "could not post the idle nudge comment" \
  "$(jq -r '.[0].detail' <<<"$out")"

# --- Malformed lines are skipped, not fatal ---------------------------------
{
  printf 'not json at all\n'
  warning_line "o/a" "" "could not list o/a's open pull requests — sweeping nothing"
} > "$log"
assert_eq "a torn line does not lose the real one" \
  "1" "$(jq 'length' <<<"$(human_visibility_violations "$log")")"

# --- Reading from stdin works too -------------------------------------------
out="$(warning_line "o/a" "" "could not list o/a's open pull requests — sweeping nothing" \
       | human_visibility_violations -)"
assert_eq "stdin ('-') is read the same as a file" "1" "$(jq 'length' <<<"$out")"
out="$(warning_line "o/a" "" "could not list o/a's open pull requests — sweeping nothing" \
       | human_visibility_violations)"
assert_eq "an omitted argument defaults to stdin" "1" "$(jq 'length' <<<"$out")"

echo
if (( failures == 0 )); then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
