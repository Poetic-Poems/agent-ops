#!/usr/bin/env bash
#
# test/coordinator-input.test.sh — self-contained regression test for
# lib/coordinator-input.sh (agent-ops#641,
# docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 4i).
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/coordinator-input.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/coordinator-input.sh
. "$SCRIPT_DIR/lib/coordinator-input.sh"

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
assert_true() { assert_eq "$1" "true" "$2"; }

# A repo array with NUM issues, each carrying a BODY-byte body and NCOMMENTS
# comments of CBYTES each. Priority cycles through the four bands and
# `updated_at` through the month, so the last rung's keep-order has something
# to order by.
mk_repos() {  # <num> <body-bytes> <ncomments> <comment-bytes>
  python3 -c '
import json, sys
n, b, c, cb = (int(x) for x in sys.argv[1:5])
issues = [{
  "source": "issues", "ref": str(i), "number": i,
  "url": "https://github.com/o/r/issues/%d" % i, "title": "issue %d" % i,
  "priority": ["Low", "Medium", "High", "Urgent"][i % 4], "priority_set": True,
  "labels": ["enhancement"], "author": "someone",
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-08-%02dT00:00:00Z" % (i % 28 + 1),
  "body": "B" * b,
  "comments": [{"author": "someone", "created_at": "2026-08-01T00:00:00Z",
                "body": "C" * cb} for _ in range(c)],
} for i in range(1, n + 1)]
print(json.dumps([{"slug": "o/r", "sources": ["issues"], "issues": issues, "tech_debt": []}]))
' "$@"
}

fit() { coordinator_fit_bands "$1"; }   # repos on stdin, {repos, fit} on stdout

# --- An input already inside its allowance is handed back untouched, and
#     says so. This is the ordinary cycle and it must cost one measurement,
#     not a rung. ---
small="$(mk_repos 3 200 1 200)"
out="$(fit 5000000 <<<"$small")"
assert_eq "an input inside the allowance reports applied: false" \
  "false" "$(jq -r '.fit.applied' <<<"$out")"
assert_eq "an input inside the allowance is returned byte-identical" \
  "$(jq -S . <<<"$small")" "$(jq -S '.repos' <<<"$out")"

# --- The bound off (0) and a malformed budget both mean "change nothing".
#     A misread budget that stripped a cycle's candidates would be a worse
#     failure than the overflow this module exists to catch. ---
big="$(mk_repos 20 4000 4 4000)"
assert_eq "a budget of 0 disables the fit entirely" \
  "false" "$(fit 0 <<<"$big" | jq -r '.fit.applied')"
assert_eq "a non-numeric budget disables the fit entirely" \
  "false" "$(fit "not-a-number" <<<"$big" | jq -r '.fit.applied')"
assert_eq "a stdin document that is not an array answers with an empty array" \
  "[]" "$(fit 100 <<<'{"not": "an array"}' | jq -c '.repos')"

# --- Over the allowance: the result actually fits, and it fits because prose
#     was shed rather than candidates. Every entry is still selectable. ---
out="$(fit 60000 <<<"$big")"
assert_true "an oversized input is trimmed to inside its allowance" \
  "$(jq '.fit.bytes_after <= .fit.budget' <<<"$out")"
assert_eq "trimming to fit drops no entries" \
  "0" "$(jq -r '.fit.entries_dropped' <<<"$out")"
assert_eq "every candidate survives the trim" \
  "20" "$(jq -r '.repos[0].issues | length' <<<"$out")"
assert_eq "the identity fields selection runs on are never shed" \
  "1 1 https://github.com/o/r/issues/1 issue 1 Medium 2026-08-02T00:00:00Z" \
  "$(jq -r '.repos[0].issues[0] | "\(.ref) \(.number) \(.url) \(.title) \(.priority) \(.updated_at)"' <<<"$out")"

# --- A cut names itself: how many bytes went, and where the whole of it is.
#     Without the URL the Co-Ordinator cannot honour the prompt's duty to read
#     a trimmed entry live before selecting it. ---
assert_true "a truncated body ends in an elision marker naming the byte counts" \
  "$(jq -r '.repos[0].issues[0].body | test("…\\[Script: elided [0-9]+ of [0-9]+ bytes")' <<<"$out")"
assert_true "the elision marker names the entry's own url" \
  "$(jq -r '.repos[0].issues[0].body | test("read it whole at https://github.com/o/r/issues/1\\]")' <<<"$out")"
assert_true "a truncated body keeps its opening, not its end" \
  "$(jq -r '.repos[0].issues[0].body | startswith("BBBB")' <<<"$out")"

# --- Dropped comments are counted on the entry rather than vanishing, and it
#     is the *newest* that are kept: the prompt treats the latest comment that
#     contradicts the body as the current instruction. ---
threads="$(python3 -c '
import json
cs = [{"author": "a", "created_at": "2026-08-%02dT00:00:00Z" % (i + 1),
       "body": "comment-%d " % i + "x" * 3000} for i in range(10)]
print(json.dumps([{"slug": "o/r", "sources": ["issues"], "tech_debt": [], "issues": [
  {"source": "issues", "ref": "1", "number": 1, "url": "https://github.com/o/r/issues/1",
   "title": "t", "priority": "High", "updated_at": "2026-08-10T00:00:00Z",
   "body": "b", "comments": cs}]}]))')"
out="$(fit 12000 <<<"$threads")"
kept="$(jq -r '.repos[0].issues[0].comments | length' <<<"$out")"
elided="$(jq -r '.repos[0].issues[0].comments_elided' <<<"$out")"
assert_eq "dropped comments are counted, not silently lost" "10" "$(( kept + elided ))"
assert_true "the comments kept are the newest ones" \
  "$(jq -r '.repos[0].issues[0].comments[-1].body | startswith("comment-9")' <<<"$out")"

# --- The last rung, and only the last rung, drops entries — keeping the
#     highest Priority band first and the freshest thread within a band, and
#     recording the count on the repo entry the Co-Ordinator reads. ---
many="$(mk_repos 12 100 0 0)"
out="$(fit 1500 <<<"$many")"
assert_true "an allowance no amount of prose-shedding can meet drops entries" \
  "$(jq '.fit.entries_dropped > 0' <<<"$out")"
assert_eq "the entries kept are the highest-priority ones" \
  "Urgent" "$(jq -r '[.repos[0].issues[].priority] | unique | join(",")' <<<"$out")"
assert_true "within a band the freshest thread is kept first" \
  "$(jq '[.repos[0].issues[].updated_at] | . == (sort | reverse)' <<<"$out")"
assert_eq "dropped entries are counted on the repo entry" \
  "12" "$(jq -r '(.repos[0].issues | length) + .repos[0].issues_elided' <<<"$out")"

# --- Order is only ever disturbed when entries are actually dropped: a
#     trimmed cycle must differ from an untrimmed one in prose and nothing
#     else, or a reader comparing two cycles' inputs cannot tell what moved. ---
out="$(fit 60000 <<<"$big")"
assert_eq "a prose-only trim leaves the gatherer's own entry order alone" \
  "$(jq -c '[.[0].issues[].ref]' <<<"$big")" \
  "$(jq -c '[.repos[0].issues[].ref]' <<<"$out")"

# --- An allowance even one entry cannot meet is reported, not hidden. The
#     stage will be refused by the API this cycle; the union log has to carry
#     the cause rather than an exit code (agent-ops#641). ---
out="$(fit 200 <<<"$many")"
assert_eq "an unmeetable allowance reports fits: false" \
  "false" "$(jq -r '.fit.fits' <<<"$out")"
assert_true "an unmeetable allowance still hands back a usable array" \
  "$(jq '(.repos[0].issues | length) > 0' <<<"$out")"

# --- Requirement 4g: the repo array is fleet state and unbounded, so it must
#     never travel in argv. The first draft of coordinator_fit_report bound it
#     as `--argjson`, and this input — genuinely past MAX_ARG_STRLEN (131072)
#     — is what caught it: `jq: Argument list too long`, an empty result, and
#     a caller that would have fallen back to the unfitted array and died on
#     the window anyway. ---
past_cap="$(mk_repos 60 3000 0 0)"
if (( $(printf '%s' "$past_cap" | wc -c) <= 131072 )); then
  printf 'FAIL - the argv-cap pin is no longer past MAX_ARG_STRLEN (%s bytes)\n' \
    "$(printf '%s' "$past_cap" | wc -c)"
  failures=$(( failures + 1 ))
else
  printf 'ok   - the argv-cap pin is genuinely past MAX_ARG_STRLEN (%s bytes)\n' \
    "$(printf '%s' "$past_cap" | wc -c)"
fi
err="$(fit 5000000 <<<"$past_cap" 2>&1 >/dev/null)"
assert_eq "an over-cap array that already fits reaches jq on stdin, not argv" \
  "" "$err"
out="$(fit 5000000 <<<"$past_cap" 2>/dev/null)"
assert_eq "…and comes back whole" \
  "60" "$(jq -r '.repos[0].issues | length' <<<"$out")"
err="$(fit 100000 <<<"$past_cap" 2>&1 >/dev/null)"
assert_eq "an over-cap array that must be trimmed reaches jq on stdin too" \
  "" "$err"
out="$(fit 100000 <<<"$past_cap" 2>/dev/null)"
assert_true "…and the trimmed result is inside its allowance" \
  "$(jq '.fit.bytes_after <= .fit.budget' <<<"$out")"

# --- The tech-debt band is trimmed on the same terms as issues: it is the
#     other array carrying a whole document per entry. ---
td="$(python3 -c '
import json
print(json.dumps([{"slug": "o/r", "sources": ["tech-debt"], "issues": [], "tech_debt": [
  {"source": "tech-debt", "ref": "TD-PPagop-26080801", "id": "TD-PPagop-26080801",
   "title": "t", "filed": "2026-08-08",
   "url": "https://github.com/o/r/blob/main/tech-debt/TD-PPagop-26080801.md",
   "body": "F" * 40000}]}]))')"
out="$(fit 9000 <<<"$td")"
assert_true "an oversized tech-debt body is trimmed" \
  "$(jq '.fit.bytes_after <= .fit.budget' <<<"$out")"
assert_true "a trimmed tech-debt body names its own file url" \
  "$(jq -r '.repos[0].tech_debt[0].body | test("read it whole at https://github.com/o/r/blob/main/tech-debt/TD-PPagop-26080801.md\\]")' <<<"$out")"
assert_eq "a trimmed tech-debt entry keeps its id" \
  "TD-PPagop-26080801" "$(jq -r '.repos[0].tech_debt[0].id' <<<"$out")"

# --- The other bands are left alone. Their bodies are what the prompt
#     requires pasted verbatim into a work order, they are bounded by the
#     number of open pull requests rather than by history, and trimming them
#     would buy a few kilobytes at the cost of the Implementer's context. ---
others="$(python3 -c '
import json
big = "R" * 40000
print(json.dumps([{"slug": "o/r", "sources": ["review-feedback"], "issues": [], "tech_debt": [],
  "review_feedback": [{"source": "review-feedback", "ref": "pr-1-review-1",
                       "url": "https://github.com/o/r/pull/1", "body": big}],
  "merge_conflicts": [{"source": "merge-conflicts", "ref": "pr-2-conflict-a",
                       "url": "https://github.com/o/r/pull/2", "body": big}]}]))')"
out="$(fit 1000 <<<"$others")"
assert_eq "a review-feedback body is never trimmed" \
  "40000" "$(jq -r '.repos[0].review_feedback[0].body | length' <<<"$out")"
assert_eq "a merge-conflicts body is never trimmed" \
  "40000" "$(jq -r '.repos[0].merge_conflicts[0].body | length' <<<"$out")"

# --- The detail line a reader gets off the union log says what was done, in
#     words, without them having to open this file to decode a rung number. ---
out="$(fit 60000 <<<"$big")"
detail="$(coordinator_fit_detail "$(jq -c '.fit' <<<"$out")")"
assert_true "the log detail names the allowance it fitted into" \
  "$(grep -qF -- "-byte allowance" <<<"$detail" && echo true || echo false)"
assert_true "the log detail spells out what the rung trimmed" \
  "$(grep -qE 'newest [0-9]+ comment\(s\) at [0-9]+ bytes each, bodies at [0-9]+ bytes' <<<"$detail" && echo true || echo false)"
assert_eq "an untrimmed cycle produces no detail line at all" \
  "" "$(coordinator_fit_detail "$(fit 5000000 <<<"$small" | jq -c '.fit')")"
assert_true "a cycle that could not be fitted says so in the detail" \
  "$(grep -qF "still does not fit" <<<"$(coordinator_fit_detail "$(fit 200 <<<"$many" | jq -c '.fit')")" && echo true || echo false)"

# --- coordinator_fit_trimmed_items / coordinator_fit_trim_refusal_reason
#     (agent-ops#683): the exemption set behind requirement 34e's fourth
#     refusal and requirement 3x's matching completeness exception. ---

# The mass-flag shape: the bottom rung cuts every candidate's body to a
# title-level fragment, and every one of them is now trimmed — with every
# entry still present (budget 5000 lands on rung 8, `0:0:1000`, without
# forcing the entry-cap rungs below it, which would drop candidates rather
# than merely trim their prose).
many_small="$(mk_repos 3 5000 2 5000)"
bottom="$(fit 5000 <<<"$many_small")"
assert_eq "the fixture actually reaches the bottom rung with no entries dropped" \
  "8 0" "$(jq -r '"\(.fit.rung) \(.fit.entries_dropped)"' <<<"$bottom")"
trimmed="$(coordinator_fit_trimmed_items <<<"$(jq -c '.repos' <<<"$bottom")")"
assert_eq "the bottom rung marks every candidate trimmed" "3" "$(jq 'length' <<<"$trimmed")"
assert_eq "each mark carries the item's own repo, ref and source" \
  "$(jq -cS 'sort_by(.item)' <<<'[{"repo":"o/r","item":"1","source":"issues"},{"repo":"o/r","item":"2","source":"issues"},{"repo":"o/r","item":"3","source":"issues"}]')" \
  "$(jq -cS 'sort_by(.item)' <<<"$trimmed")"

# An input the fit never touches (inside its allowance) marks nothing.
untouched="$(fit 5000000 <<<"$small")"
assert_eq "an untrimmed cycle's fitted array marks nothing trimmed" "0" \
  "$(jq 'length' <<<"$(coordinator_fit_trimmed_items <<<"$(jq -c '.repos' <<<"$untouched")")")"

# A cycle trimmed only a little (a middle rung) marks only the entries that
# actually exceeded that rung's caps — not every entry in the band.
mixed="$(python3 -c '
import json
issues = [
  {"source": "issues", "ref": "1", "url": "https://github.com/o/r/issues/1",
   "title": "t", "priority": "Medium", "updated_at": "2026-08-01T00:00:00Z",
   "body": "tiny", "comments": []},
  {"source": "issues", "ref": "2", "url": "https://github.com/o/r/issues/2",
   "title": "t", "priority": "Medium", "updated_at": "2026-08-02T00:00:00Z",
   "body": "B" * 30000, "comments": []},
]
print(json.dumps([{"slug": "o/r", "sources": ["issues"], "issues": issues, "tech_debt": []}]))')"
mixed_out="$(fit 3000 <<<"$mixed")"
mixed_trimmed="$(coordinator_fit_trimmed_items <<<"$(jq -c '.repos' <<<"$mixed_out")")"
assert_eq "only the entry that actually exceeded the rung is marked trimmed" \
  '["2"]' "$(jq -c '[.[].item]' <<<"$mixed_trimmed")"

# The refusal function itself: refuses only an entry naming a repo+item the
# trimmed set carries, regardless of source, and names the rung.
entry_trimmed='{"repo":"o/r","item":"2","source":"issues","reason":"x","missing":"y","evidence":"z"}'
reason="$(coordinator_fit_trim_refusal_reason "$entry_trimmed" "$mixed_trimmed" "3")"
rc=$?
assert_eq "a report naming a trimmed item is refused" "1" "$rc"
assert_true "the refusal names the rung" "$(grep -qF 'rung 3' <<<"$reason" && echo true || echo false)"

entry_untouched='{"repo":"o/r","item":"1","source":"issues","reason":"x","missing":"y","evidence":"z"}'
coordinator_fit_trim_refusal_reason "$entry_untouched" "$mixed_trimmed" "3"
assert_eq "a report naming an untrimmed item is not refused" "0" "$?"

assert_eq "an entry naming no repo/item is never refused" "0" \
  "$(coordinator_fit_trim_refusal_reason '{}' "$mixed_trimmed" "3" >/dev/null 2>&1; echo $?)"
assert_eq "an empty trimmed set refuses nothing" "0" \
  "$(coordinator_fit_trim_refusal_reason "$entry_trimmed" '[]' "3" >/dev/null 2>&1; echo $?)"
assert_eq "malformed trimmed JSON degrades to refusing nothing" "0" \
  "$(coordinator_fit_trim_refusal_reason "$entry_trimmed" "not json" "3" >/dev/null 2>&1; echo $?)"

echo
if (( failures == 0 )); then
  echo "All coordinator-input assertions passed."
  exit 0
else
  echo "$failures coordinator-input assertion(s) FAILED."
  exit 1
fi
