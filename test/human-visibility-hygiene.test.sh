#!/usr/bin/env bash
#
# test/human-visibility-hygiene.test.sh — regression test for
# lib/human-visibility-hygiene.sh's `human_visibility_violations` (requirement
# 38e): the reduction over the log union that turns
# scripts/sweep-human-visibility.sh's `warning` events back into the set of
# violations still standing.
#
# The rule is "most recent event per identity wins, but a success only
# clears a warning that shares its family" — the same "latest wins" shape
# `_latest_unresolved` already applies to a block and its clearance
# (lib/cycle-state.sh), narrowed by family so that three distinct actions
# firing for one pull request in a single sweep pass (requirement 38f) do not
# clear each other's unrelated warnings (agent-ops#393) — asserted from both
# directions:
#
#   - **Too eager** keeps a violation a later, *same-family* success already
#     answered. A later `human-review-requested` clears a same-`pr_url`
#     `could not request review from …` warning; a later `human-nudged`
#     clears a same-`pr_url` `could not post the idle nudge comment` warning,
#     and likewise a same-`pr_url` `could not read the pull request's
#     reviews …` warning (`_handoff_pr_approved`'s own read failing inside
#     the idle-nudge check alone, so it joins the nudge family rather than
#     the wider fail-safe default); a later `human-dequeue-notice` clears a
#     same-`pr_url` `could not post the merge-queue-dequeued notice` warning;
#     and any of the three clears a same-`pr_url` warning shape none of the
#     families recognises (the fail-safe default for a read failure that
#     gates every downstream check).
#   - **Too shy** drops a violation nothing has actually resolved: an
#     unrelated warning (a different sweep entirely, or a different repo/PR)
#     must never clear it; a *different-family* success — a dequeue notice
#     posting while a review-request warning stands, or vice versa — must
#     never clear it either; and a repo-level (empty `pr_url`) violation must
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

# --- A "could not read the pull request's reviews" warning joins the nudge
# --- family: only a later nudge clears it, not an unrelated review-request -
{
  warning_line "o/a" "https://github.com/o/a/pull/9" \
    "could not read the pull request's reviews — skipping the idle-nudge check"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-nudged", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/9", reviewer: "foo"}'
} > "$log"
assert_eq "a later nudge clears a same-pr_url reviews-read warning" \
  "0" "$(jq 'length' <<<"$(human_visibility_violations "$log")")"

{
  warning_line "o/a" "https://github.com/o/a/pull/9" \
    "could not read the pull request's reviews — skipping the idle-nudge check"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-review-requested", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/9", reviewers: ["foo"]}'
} > "$log"
out="$(human_visibility_violations "$log")"
assert_eq "a review-request success does not mask a reviews-read warning" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... the reviews-read warning survives verbatim" \
  "could not read the pull request's reviews — skipping the idle-nudge check" \
  "$(jq -r '.[0].detail' <<<"$out")"

# --- A dequeue notice, its own family, also clears its own warning ---------
{
  warning_line "o/a" "https://github.com/o/a/pull/9" "could not post the merge-queue-dequeued notice"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-dequeue-notice", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/9", reviewer: "foo"}'
} > "$log"
assert_eq "a later dequeue notice clears the same pr_url's dequeue-notice warning" \
  "0" "$(jq 'length' <<<"$(human_visibility_violations "$log")")"

# --- agent-ops#393: a same-pass success of a DIFFERENT family must not mask
# --- an unrelated, still-outstanding warning for the same pull request -----
{
  warning_line "o/a" "https://github.com/o/a/pull/9" "could not request review from foo"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-dequeue-notice", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/9", reviewer: "foo"}'
} > "$log"
out="$(human_visibility_violations "$log")"
assert_eq "a same-pass dequeue notice does not mask a review-request warning" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... the review-request warning survives verbatim" \
  "could not request review from foo" "$(jq -r '.[0].detail' <<<"$out")"

{
  warning_line "o/a" "https://github.com/o/a/pull/9" "could not post the merge-queue-dequeued notice"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-review-requested", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/9", reviewers: ["foo"]}'
} > "$log"
out="$(human_visibility_violations "$log")"
assert_eq "a review-request success does not mask a dequeue-notice warning" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... the dequeue-notice warning survives verbatim" \
  "could not post the merge-queue-dequeued notice" "$(jq -r '.[0].detail' <<<"$out")"

{
  warning_line "o/a" "https://github.com/o/a/pull/9" "could not post the idle nudge comment"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-dequeue-notice", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/9", reviewer: "foo"}'
} > "$log"
assert_eq "a dequeue notice does not mask an idle-nudge warning" \
  "1" "$(jq 'length' <<<"$(human_visibility_violations "$log")")"

# --- An unrecognised warning shape still clears off any success ------------
{
  warning_line "o/a" "https://github.com/o/a/pull/9" \
    "could not read the pull request's state — skipping its review-state checks"
  jq -nc '{ts: "2026-08-08T01:00:00Z", cycle: "c", node: "n",
            event: "human-dequeue-notice", repo: "o/a",
            pr_url: "https://github.com/o/a/pull/9", reviewer: "foo"}'
} > "$log"
assert_eq "an unrecognised warning shape is cleared by any success (fail-safe default)" \
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
