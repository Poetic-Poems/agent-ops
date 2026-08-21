#!/usr/bin/env bash
#
# test/verdict-fate.test.sh — regression test for lib/verdict-fate.sh, the
# pure join and classification behind the D18 Approver-verdict/human-action
# divergence record (agent-ops#573).
#
# Four things are asserted:
#
#   - `verdict_fate_posted_review` maps the model's own vocabulary
#     (`approve`/`refuse`/`land`/`escalate`, plus `adjudication`) onto the
#     two GitHub review events the Script ever actually posts, printing empty
#     for anything that reaches neither.
#   - `verdict_fate_latest_per_pr` collapses a pull request with more than
#     one `approver-verdict` event to its single latest by `ts`; excludes a
#     verdict whose review never reached GitHub (`posted:false`, or an
#     escalate/unrecognised verdict with no `posted_review` at all) while
#     defaulting a pre-agent-ops#573 event with no `posted` field at all to
#     `true` (the best available assumption for history this file cannot
#     re-observe); and matches a repo prefix exactly, the same
#     no-substring-match discipline `scripts/autonomy-stage-report.sh`'s own
#     `crit_agent_approved_prs` already applies (a `o/repo-extra` decoy must
#     never count toward `o/repo`).
#   - `verdict_fate_classify` covers every fate/comparison pair the issue's
#     own vocabulary names: an APPROVE landing by the Script or by a human
#     (agreement), an APPROVE closing unmerged (divergence), an APPROVE with
#     a standing human `CHANGES_REQUESTED` afterwards — its own fate,
#     `changes-requested-after-approval`, never collapsed into
#     `closed-unmerged` even when the pull request is later fixed and merged
#     anyway (the issue's stated "sharp edge") — a REQUEST_CHANGES closing
#     unmerged (agreement) or landing anyway (divergence, a human override),
#     and a still-open pull request with no standing request (pending,
#     either verdict).
#   - `verdict_fate_summarize` computes agreement/divergence/pending/sample/
#     rate correctly and declines to state a rate below the stated minimum
#     sample (`insufficient-sample`), the same "never state a rate a handful
#     of data points cannot support" discipline this issue's acceptance
#     criteria name.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/verdict-fate.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/verdict-fate.sh
. "$SCRIPT_DIR/lib/verdict-fate.sh"

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

# --- verdict_fate_posted_review ---------------------------------------------

assert_eq "ordinary approve -> APPROVE" "APPROVE" "$(verdict_fate_posted_review approve false)"
assert_eq "ordinary refuse -> REQUEST_CHANGES" "REQUEST_CHANGES" "$(verdict_fate_posted_review refuse false)"
assert_eq "ordinary unrecognised -> empty" "" "$(verdict_fate_posted_review maybe false)"
assert_eq "adjudication land -> APPROVE" "APPROVE" "$(verdict_fate_posted_review land true)"
assert_eq "adjudication refuse -> REQUEST_CHANGES" "REQUEST_CHANGES" "$(verdict_fate_posted_review refuse true)"
assert_eq "adjudication escalate -> empty (no review posted)" "" "$(verdict_fate_posted_review escalate true)"
assert_eq "adjudication approve is not a real adjudication verdict -> empty" "" "$(verdict_fate_posted_review approve true)"

# --- verdict_fate_latest_per_pr ----------------------------------------------

EVENTS='[
  {"ts":"2026-08-01T00:00:00Z","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/1","repo":"o/repo","tier":"medium","model":"m1","verdict":"refuse","adjudication":false,"posted":true},
  {"ts":"2026-08-02T00:00:00Z","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/1","repo":"o/repo","tier":"medium","model":"m1","verdict":"approve","adjudication":false,"posted":true},
  {"ts":"2026-08-01T00:00:00Z","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/2","repo":"o/repo","tier":"medium","model":"m1","verdict":"approve","adjudication":false,"posted":false},
  {"ts":"2026-08-01T00:00:00Z","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/3","repo":"o/repo","tier":"low","model":"","verdict":"maybe","adjudication":false,"posted":true},
  {"ts":"2026-08-01T00:00:00Z","event":"approver-verdict","pr_url":"https://github.com/o/repo-extra/pull/9","repo":"o/repo-extra","tier":"medium","model":"m1","verdict":"approve","adjudication":false,"posted":true},
  {"ts":"2026-08-05T00:00:00Z","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/4","tier":"medium","verdict":"approve","adjudication":false}
]'

latest="$(verdict_fate_latest_per_pr "$EVENTS" "o/repo")"
assert_eq "pull/1 collapses to its later, latest verdict" \
  "approve" "$(jq -r '.[] | select(.pr_url | endswith("/1")) | .verdict' <<<"$latest")"
assert_eq "  ... and its ts is the later one" \
  "2026-08-02T00:00:00Z" "$(jq -r '.[] | select(.pr_url | endswith("/1")) | .ts' <<<"$latest")"
assert_eq "pull/2's posted:false verdict is excluded entirely" \
  "" "$(jq -r '.[] | select(.pr_url | endswith("/2")) | .pr_url' <<<"$latest")"
assert_eq "pull/3's unrecognised verdict (empty posted_review) is excluded" \
  "" "$(jq -r '.[] | select(.pr_url | endswith("/3")) | .pr_url' <<<"$latest")"
assert_eq "o/repo-extra's decoy is excluded by the exact-prefix match" \
  "" "$(jq -r '.[] | select(.repo == "o/repo-extra") | .pr_url' <<<"$latest")"
assert_eq "pull/4, with no explicit posted field, defaults to true and is included" \
  "APPROVE" "$(jq -r '.[] | select(.pr_url | endswith("/4")) | .posted_review' <<<"$latest")"
assert_eq "exactly two surviving entries (1, and 4 defaulting to posted:true; 2 and 3 excluded)" \
  "2" "$(jq 'length' <<<"$latest")"

no_prefix="$(verdict_fate_latest_per_pr "$EVENTS" "")"
assert_eq "no prefix filter includes the decoy repo too" \
  "3" "$(jq 'length' <<<"$no_prefix")"

# --- verdict_fate_classify ---------------------------------------------------

no_reviews='[]'
cra_review='[{"login":"human1","state":"CHANGES_REQUESTED","submitted_at":"2026-08-10T00:00:00Z","bot":false}]'
bot_cra_review='[{"login":"some-bot[bot]","state":"CHANGES_REQUESTED","submitted_at":"2026-08-10T00:00:00Z","bot":true}]'
stale_cra_review='[{"login":"human1","state":"CHANGES_REQUESTED","submitted_at":"2026-08-01T00:00:00Z","bot":false}]'
VTS="2026-08-05T00:00:00Z"

r="$(verdict_fate_classify APPROVE true merged "$no_reviews" "$VTS")"
assert_eq "APPROVE + armed + merged -> landed-by-script/agreement" \
  '{"fate":"landed-by-script","comparison":"agreement"}' "$r"

r="$(verdict_fate_classify APPROVE false merged "$no_reviews" "$VTS")"
assert_eq "APPROVE + unarmed + merged -> landed-by-human/agreement" \
  '{"fate":"landed-by-human","comparison":"agreement"}' "$r"

r="$(verdict_fate_classify APPROVE false closed "$no_reviews" "$VTS")"
assert_eq "APPROVE + closed unmerged -> divergence" \
  '{"fate":"closed-unmerged","comparison":"divergence"}' "$r"

r="$(verdict_fate_classify APPROVE false open "$no_reviews" "$VTS")"
assert_eq "APPROVE + still open, no standing request -> pending" \
  '{"fate":"still-open","comparison":"pending"}' "$r"

r="$(verdict_fate_classify APPROVE false open "$cra_review" "$VTS")"
assert_eq "APPROVE + a human CHANGES_REQUESTED afterwards -> its own fate, divergence, even while still open" \
  '{"fate":"changes-requested-after-approval","comparison":"divergence"}' "$r"

r="$(verdict_fate_classify APPROVE true merged "$cra_review" "$VTS")"
assert_eq "  ... and stays that fate even once the pull request later lands anyway (the sharp edge)" \
  '{"fate":"changes-requested-after-approval","comparison":"divergence"}' "$r"

r="$(verdict_fate_classify APPROVE false open "$bot_cra_review" "$VTS")"
assert_eq "a bot's own CHANGES_REQUESTED never counts as a human's" \
  '{"fate":"still-open","comparison":"pending"}' "$r"

r="$(verdict_fate_classify APPROVE false open "$stale_cra_review" "$VTS")"
assert_eq "a CHANGES_REQUESTED submitted BEFORE the verdict's own ts does not count as 'after'" \
  '{"fate":"still-open","comparison":"pending"}' "$r"

r="$(verdict_fate_classify REQUEST_CHANGES false closed "$no_reviews" "$VTS")"
assert_eq "REQUEST_CHANGES + closed unmerged -> agreement (the human concurred)" \
  '{"fate":"closed-unmerged","comparison":"agreement"}' "$r"

r="$(verdict_fate_classify REQUEST_CHANGES false merged "$no_reviews" "$VTS")"
assert_eq "REQUEST_CHANGES + landed anyway -> divergence (a human override)" \
  '{"fate":"landed-by-human","comparison":"divergence"}' "$r"

r="$(verdict_fate_classify REQUEST_CHANGES false open "$no_reviews" "$VTS")"
assert_eq "REQUEST_CHANGES + still open -> pending" \
  '{"fate":"still-open","comparison":"pending"}' "$r"

# --- verdict_fate_summarize ---------------------------------------------------

entries='[{"comparison":"agreement"},{"comparison":"agreement"},{"comparison":"agreement"},{"comparison":"divergence"},{"comparison":"pending"}]'
summary="$(verdict_fate_summarize "$entries" 4)"
assert_eq "summarize: agreement count" "3" "$(jq -r '.agreement' <<<"$summary")"
assert_eq "summarize: divergence count" "1" "$(jq -r '.divergence' <<<"$summary")"
assert_eq "summarize: pending count (excluded from the rate)" "1" "$(jq -r '.pending' <<<"$summary")"
assert_eq "summarize: sample is agreement+divergence, not pending" "4" "$(jq -r '.sample' <<<"$summary")"
assert_eq "summarize: rate is divergence/sample" "0.25" "$(jq -r '.rate' <<<"$summary")"
assert_eq "summarize: status is divergence — any divergence at all fails the bar" \
  "divergence" "$(jq -r '.status' <<<"$summary")"

below_min="$(verdict_fate_summarize '[{"comparison":"agreement"},{"comparison":"agreement"}]' 5)"
assert_eq "a sample below the stated minimum declines to state a rate" \
  "insufficient-sample" "$(jq -r '.status' <<<"$below_min")"
assert_eq "  ... though the rate is still computed, just not trusted as a verdict" \
  "0" "$(jq -r '.rate' <<<"$below_min")"

clean="$(verdict_fate_summarize '[{"comparison":"agreement"},{"comparison":"agreement"},{"comparison":"agreement"},{"comparison":"agreement"},{"comparison":"agreement"}]' 5)"
assert_eq "zero divergence at or above the minimum sample -> clean" "clean" "$(jq -r '.status' <<<"$clean")"

empty_summary="$(verdict_fate_summarize '[]' 5)"
assert_eq "an empty sample never states a rate" "insufficient-sample" "$(jq -r '.status' <<<"$empty_summary")"
assert_eq "  ... and rate is null, not a divide-by-zero" "null" "$(jq -r '.rate' <<<"$empty_summary")"

echo
if (( failures == 0 )); then
  echo "All verdict-fate assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
