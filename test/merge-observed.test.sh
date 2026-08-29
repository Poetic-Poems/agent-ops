#!/usr/bin/env bash
#
# test/merge-observed.test.sh — regression test for
# `reviewer_merge_observed` (lib/merge-observed.sh, requirement 32c,
# agent-ops#916): the completion a mid-stage merge ends in instead of
# `attempt-failed` — `merge-observed` logged, the Reviewer's own leftovers
# (`file_debt`/`file_issue`) filed under the ordinary pipeline login, and the
# PR-keyed claim released.
#
# `log_event`, `release_pr_claim`, `techdebt_file_debt` and
# `techdebt_file_issue` are stubbed as simple recorders — the same role
# test/enabler-tech-debt-file-wiring.test.sh already gives the last two —
# rather than wired for real; lib/tech-debt-file.sh's own filing logic is
# exercised for real by test/tech-debt-file.test.sh. Each recorder joins its
# arguments with an ASCII unit separator (\x1f) rather than a plain space, so
# an argument that itself contains spaces (a body, a title) does not corrupt
# positional extraction.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/merge-observed.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0
US=$'\x1f'

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

# --- Stubs ---------------------------------------------------------------
# Each records its call as one \x1f-joined line in $tmp_dir/<name>-calls;
# techdebt_file_debt and techdebt_file_issue additionally consult
# $tmp_dir/<name>-outcome ("ok" or "fail") to decide what to return, the same
# recorder role test/enabler-tech-debt-file-wiring.test.sh already gives them.
log_event() { printf '%s\t%s\n' "$1" "$2" >>"$tmp_dir/log-calls"; }
release_pr_claim() { printf 'x' >>"$tmp_dir/release-calls"; }
techdebt_file_debt() {
  local IFS="$US"; printf '%s\n' "$*" >>"$tmp_dir/file-debt-calls"
  [[ "$(cat "$tmp_dir/file-debt-outcome" 2>/dev/null || echo ok)" == "ok" ]] || return 1
  printf 'TD-PPagop-26082999\thttps://github.com/acme/widgets/pull/501'
}
techdebt_file_issue() {
  local IFS="$US"; printf '%s\n' "$*" >>"$tmp_dir/file-issue-calls"
  [[ "$(cat "$tmp_dir/file-issue-outcome" 2>/dev/null || echo ok)" == "ok" ]] || return 1
  printf '502\thttps://github.com/acme/widgets/issues/502'
}

# shellcheck source=lib/merge-observed.sh
. "$SCRIPT_DIR/lib/merge-observed.sh"

reset_stubs() {
  : > "$tmp_dir/log-calls"
  : > "$tmp_dir/release-calls"
  : > "$tmp_dir/file-debt-calls"
  : > "$tmp_dir/file-issue-calls"
  printf 'ok' > "$tmp_dir/file-debt-outcome"
  printf 'ok' > "$tmp_dir/file-issue-outcome"
  rm -f "$tmp_dir/reviewer-merge-observed-file-issue.md"
}

release_calls() { wc -c <"$tmp_dir/release-calls" | tr -d ' '; }
events_named() { grep $'^'"$1"$'\t' "$tmp_dir/log-calls" | cut -f2-; }
debt_field() { cut -d "$US" -f"$1" "$tmp_dir/file-debt-calls"; }
issue_field() { cut -d "$US" -f"$1" "$tmp_dir/file-issue-calls"; }

selected_repo="acme/widgets"
selected_item="42"
cycle_dir="$tmp_dir"
# The cycle's own clone of $selected_repo, distinct from cycle_dir on purpose:
# techdebt_file_debt's GIT_DIR must be the clone (it fetches origin/main there),
# and cycle_dir is where this file writes the file_issue body. The two being
# different values here is what lets the assertions below tell them apart.
clone_dir="$tmp_dir/clone"
DEFAULTED_CONFIG='{"pr_label":"autonomous-agent"}'
URL="https://github.com/acme/widgets/pull/916"

# --- No leftovers: just the completion and the claim release ------------------
reset_stubs
reviewer_merge_observed "$URL" "b48eebf1234" '{}' "reviewer"
mo="$(events_named merge-observed)"
assert_eq "merge-observed names the repo" '"acme/widgets"' "$(jq -c '.repo' <<<"$mo")"
assert_eq "  ... the item" '"42"' "$(jq -c '.item' <<<"$mo")"
assert_eq "  ... the pull request" "\"$URL\"" "$(jq -c '.pr_url' <<<"$mo")"
assert_eq "  ... the stage" '"reviewer"' "$(jq -c '.stage' <<<"$mo")"
assert_eq "  ... and the merge sha" '"b48eebf1234"' "$(jq -c '.merge_sha' <<<"$mo")"
assert_eq "the PR-keyed claim is released exactly once" "1" "$(release_calls)"
assert_eq "no tech-debt is filed with an empty verdict" "" "$(cat "$tmp_dir/file-debt-calls")"
assert_eq "no issue is filed with an empty verdict" "" "$(cat "$tmp_dir/file-issue-calls")"

# --- An empty merge sha is omitted from the event, not printed as "" ----------
reset_stubs
reviewer_merge_observed "$URL" "" '{}' "reviewer-stage-start"
mo="$(events_named merge-observed)"
assert_eq "an empty merge_sha is omitted from the event" "null" "$(jq -c '.merge_sha // null' <<<"$mo")"
assert_eq "the stage-start call site's own stage word is carried" '"reviewer-stage-start"' "$(jq -c '.stage' <<<"$mo")"

# --- file_debt: filed under the pipeline login, by: reviewer ------------------
# Argument order: repo, title, body, provenance, token, git_dir, pr_label,
# default_fix, owner_decision.
reset_stubs
rev_json='{"status":"blocked","reason":"merged mid-pass","file_debt":{"title":"the gap","body":"body text","default_fix":"do X","owner_decision":false}}'
reviewer_merge_observed "$URL" "" "$rev_json" "reviewer"
assert_eq "techdebt_file_debt is called with the repo" "acme/widgets" "$(debt_field 1)"
assert_eq "  ... the title" "the gap" "$(debt_field 2)"
assert_eq "  ... the body" "body text" "$(debt_field 3)"
assert_contains "  ... naming this pull request in the provenance" "$URL" "$(debt_field 4)"
assert_eq "  ... with no TOKEN (the ordinary pipeline login)" "" "$(debt_field 5)"
# GIT_DIR is the cycle's clone of the target repo, never cycle_dir: the latter
# is a state directory with no `origin` to fetch, so techdebt_file_debt would
# fail at its first `git fetch` and the leftovers would be lost with only a
# warning to show for it.
assert_eq "  ... the cycle's own clone as GIT_DIR" "$tmp_dir/clone" "$(debt_field 6)"
assert_eq "  ... the configured pr_label" "autonomous-agent" "$(debt_field 7)"
assert_eq "  ... the default_fix" "do X" "$(debt_field 8)"
assert_eq "  ... and owner_decision false" "false" "$(debt_field 9)"
tdf="$(events_named tech-debt-filed)"
assert_eq "tech-debt-filed names the reviewer" '"reviewer"' "$(jq -c '.by' <<<"$tdf")"
assert_eq "  ... and the filed pull request" '"https://github.com/acme/widgets/pull/501"' "$(jq -c '.filed_pr_url' <<<"$tdf")"

# --- file_debt missing a body: ignored, warned, never filed -------------------
reset_stubs
rev_json='{"file_debt":{"title":"gap only"}}'
reviewer_merge_observed "$URL" "" "$rev_json" "reviewer"
assert_eq "a title-only file_debt calls techdebt_file_debt not at all" "" "$(cat "$tmp_dir/file-debt-calls")"
assert_contains "  ... and warns that it was ignored" "carries no title or body" "$(events_named warning)"

# --- file_debt with neither default_fix nor owner_decision: warned, still filed
reset_stubs
rev_json='{"file_debt":{"title":"gap","body":"body text"}}'
reviewer_merge_observed "$URL" "" "$rev_json" "reviewer"
assert_eq "no default_fix/owner_decision still files" "gap" "$(debt_field 2)"
assert_contains "  ... but warns about the missing default" "no default_fix and no owner_decision" "$(events_named warning)"

# --- file_debt: techdebt_file_debt itself fails -------------------------------
reset_stubs
printf 'fail' > "$tmp_dir/file-debt-outcome"
rev_json='{"file_debt":{"title":"gap","body":"body text","owner_decision":true}}'
reviewer_merge_observed "$URL" "" "$rev_json" "reviewer"
assert_contains "a failed filing call is warned, not silently dropped" \
  "could not file the tech-debt record" "$(events_named warning)"
assert_eq "  ... and no tech-debt-filed event is logged" "" "$(events_named tech-debt-filed)"

# --- file_issue: filed under the pipeline login, by: reviewer -----------------
# Argument order: repo, item_ref (the pull request), title, body_file, token,
# default_fix, owner_decision.
reset_stubs
rev_json='{"file_issue":{"title":"question","body":"why this matters","owner_decision":true}}'
reviewer_merge_observed "$URL" "" "$rev_json" "reviewer"
assert_eq "techdebt_file_issue is called with the repo" "acme/widgets" "$(issue_field 1)"
assert_eq "  ... the pull request as the item ref" "$URL" "$(issue_field 2)"
assert_eq "  ... the title" "question" "$(issue_field 3)"
assert_eq "  ... with no TOKEN (the ordinary pipeline login)" "" "$(issue_field 5)"
assert_contains "  ... the body_file carries the verdict's own body" \
  "why this matters" "$(cat "$tmp_dir/reviewer-merge-observed-file-issue.md")"
assert_contains "  ... and names the merged pull request" "$URL" "$(cat "$tmp_dir/reviewer-merge-observed-file-issue.md")"
fi_event="$(events_named issue-filed)"
assert_eq "issue-filed names the reviewer" '"reviewer"' "$(jq -c '.by' <<<"$fi_event")"
assert_eq "  ... and the filed issue number" "502" "$(jq -c '.issue_number' <<<"$fi_event")"

# --- file_issue missing a title: ignored, warned ------------------------------
reset_stubs
rev_json='{"file_issue":{"body":"why only"}}'
reviewer_merge_observed "$URL" "" "$rev_json" "reviewer"
assert_eq "a body-only file_issue calls techdebt_file_issue not at all" "" "$(cat "$tmp_dir/file-issue-calls")"
assert_contains "  ... and warns that it was ignored" "carries no title or body" "$(events_named warning)"

# --- Both fields at once: both filed, claim released once regardless ---------
reset_stubs
rev_json='{"file_debt":{"title":"gap","body":"body text","owner_decision":true},
           "file_issue":{"title":"question","body":"why","owner_decision":true}}'
reviewer_merge_observed "$URL" "" "$rev_json" "reviewer"
assert_eq "both fields file independently" "gap" "$(debt_field 2)"
assert_eq "  ... file_issue too" "question" "$(issue_field 3)"
assert_eq "  ... and the claim releases exactly once" "1" "$(release_calls)"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
