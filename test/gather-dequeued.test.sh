#!/usr/bin/env bash
#
# test/gather-dequeued.test.sh — regression test for the candidate rule of
# scripts/gather-dequeued.sh (requirement 3z, TD-PPagop-26081409) and the
# back-pressure narrowing it shares with review-feedback, merge-conflicts and
# abandoned-drafts (requirement 2.2a).
#
# The rule decides which of *our own* ready PRs GitHub's merge queue dequeued
# over a merge-group checks failure, and it has two dangerous directions:
#   - too eager, and it offers a PR whose dequeue a human manually caused (or
#     whose reason this system cannot read confidently) as if this system could
#     fix it — pushing a "fix" to a branch the human just took back is exactly
#     the failure TD-PPagop-26081409 was filed to prevent;
#   - too shy, and a genuinely broken, dequeued PR sits forever looking
#     approved, mergeable and green to every other source, occupying a
#     back-pressure slot while every cycle looks healthy.
# The `MERGEABLE`-only gate (never `CONFLICTING`, which is
# scripts/gather-merge-conflicts.sh's own candidate — the two rules must never
# both admit the same PR head) and the `failed_checks`-only allow-list on
# `dequeue_reason` are what hold the line. Keep this in step with the filters
# in the script.
#
# The candidate rule is exercised for real, through DEQUEUED_GH/MERGE_QUEUE_GH,
# against a stub `gh` combining a `pr list` fixture (the "ours" listing) and an
# `api graphql` fixture (`lib/merge-queue.sh`'s own probe) — the same
# combined-stub technique test/sweep-human-visibility.test.sh already uses.
#
# Run directly:
#
#   ./test/gather-dequeued.test.sh
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

# --- The "ours" filter: which ready PRs might even be in scope? ---
#
# The shape `gh pr list --json number,title,headRefName,headRefOid,baseRefName,isDraft,mergeable,updatedAt,url,body`
# returns. Draft, mergeable and branch-ownership are decided here exactly as
# scripts/gather-merge-conflicts.sh's own "ours" filter is — the two share the
# same "ours" test by construction.
prs='[
  {"number": 90, "isDraft": false, "mergeable": "MERGEABLE",   "headRefName": "agent/td1-fix"},
  {"number": 91, "isDraft": true,  "mergeable": "MERGEABLE",   "headRefName": "agent/td2-fix"},
  {"number": 92, "isDraft": false, "mergeable": "CONFLICTING", "headRefName": "agent/td3-fix"},
  {"number": 93, "isDraft": false, "mergeable": "UNKNOWN",     "headRefName": "agent/td4-fix"},
  {"number": 94, "isDraft": false, "mergeable": "MERGEABLE",   "headRefName": "feature/a-humans-branch"},
  {"number": 95, "isDraft": false, "mergeable": "MERGEABLE",   "headRefName": "td/TD26072001"}
]'

candidate_filter() {
  jq -c '[.[] | select(.isDraft | not)
              | select(.mergeable == "MERGEABLE")
              | select((.headRefName | startswith("agent/"))
                       or (.headRefName | startswith("td/")))
              | .number]' <<<"$prs"
}

assert_eq "only open, non-draft, MERGEABLE, ours-by-branch PRs pass the ours filter" \
  "[90,95]" "$(candidate_filter)"

# - #91 draft: never enqueueable in the first place, so never dequeueable either.
# - #92 CONFLICTING: this is scripts/gather-merge-conflicts.sh's own candidate —
#   the two rules must never both admit the same PR head, which is what keeps
#   requirement 3z complementary to requirement 3g rather than overlapping it.
# - #93 UNKNOWN: the transient state gather-merge-conflicts.sh also never
#   trusts; this rule requires MERGEABLE exactly, so an UNKNOWN PR passes
#   neither rule until GitHub finishes computing it.
# - #94 human branch: only agent/ or td/ branches are ours.
assert_eq "a draft PR is never a dequeued candidate" \
  "0" "$(jq '[.[] | select(.number == 91) | select(.isDraft | not)] | length' <<<"$prs")"
assert_eq "a CONFLICTING PR is never a dequeued candidate — that is merge-conflicts' alone" \
  "0" "$(jq '[.[] | select(.number == 92) | select(.mergeable == "MERGEABLE")] | length' <<<"$prs")"
assert_eq "an UNKNOWN-mergeability PR is not a candidate — never act on a guess" \
  "0" "$(jq '[.[] | select(.number == 93) | select(.mergeable == "MERGEABLE")] | length' <<<"$prs")"
assert_eq "a human's own branch is never ours to fix" \
  "0" "$(jq '[.[] | select(.number == 94) | select((.headRefName | startswith("agent/")) or (.headRefName | startswith("td/")))] | length' <<<"$prs")"
assert_eq "a tech-debt td/ claim branch counts as ours" \
  "1" "$(jq '[.[] | select(.number == 95) | select(.headRefName | startswith("td/"))] | length' <<<"$prs")"

# --- The ref: scoped to the head SHA, identically to gather-merge-conflicts.sh ---
ref_of() { jq -r '"pr-\(.number)-dequeued-\(.head_sha[0:12])"' <<<"$1"; }
assert_eq "the ref pins to the PR number and the head SHA's first 12 chars" \
  "pr-90-dequeued-1a2b3c4d5e6f" \
  "$(ref_of '{"number": 90, "head_sha": "1a2b3c4d5e6f7a8b9c0d"}')"
assert_eq "a new head after a fix yields a different ref, so an old block cannot cover it" \
  "pr-90-dequeued-ffffffffffff" \
  "$(ref_of '{"number": 90, "head_sha": "ffffffffffffaaaa1111"}')"

# --- Back-pressure narrowing (requirement 2.2a) ---
#
# When back-pressure trips, the cycle narrows to the four *finishing* sources
# rather than standing down.
ordered='[
  {"slug": "o/one", "sources": ["security", "review-feedback", "merge-conflicts", "dequeued", "abandoned-drafts", "tech-debt"], "review_feedback": [], "merge_conflicts": [], "dequeued": [{"ref": "pr-90-dequeued-1a2b3c4d5e6f"}], "abandoned_drafts": []},
  {"slug": "o/two", "sources": ["security", "review-feedback", "merge-conflicts", "dequeued", "abandoned-drafts", "issues"], "review_feedback": [], "merge_conflicts": [], "dequeued": [], "abandoned_drafts": []}
]'
restrict() { jq -c '[.[] | .sources = (.sources | map(select(. == "review-feedback" or . == "merge-conflicts" or . == "dequeued" or . == "abandoned-drafts")))]' <<<"$ordered"; }

assert_eq "restriction leaves only the four finishing sources selectable" \
  '["review-feedback","merge-conflicts","dequeued","abandoned-drafts"] ["review-feedback","merge-conflicts","dequeued","abandoned-drafts"]' \
  "$(restrict | jq -r '[.[] | (.sources | tojson)] | join(" ")')"
assert_eq "security and fresh sources are narrowed away — a full gate means finish, don't start" \
  "0" "$(restrict | jq '[.[].sources[] | select(. == "security" or . == "tech-debt" or . == "issues")] | length')"

# The count that decides stand-down vs restrict: all four finishing sources,
# across all repos.
assert_eq "finishing candidates count review-feedback, merge-conflicts, dequeued AND abandoned-drafts across all repos" \
  "1" "$(jq '[.[].review_feedback[]?, .[].merge_conflicts[]?, .[].dequeued[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"
assert_eq "with nothing waiting to finish, the count is 0 and the cycle stands down as before" \
  "0" "$(jq '[.[] | .review_feedback = [] | .merge_conflicts = [] | .dequeued = [] | .abandoned_drafts = []] | [.[].review_feedback[]?, .[].merge_conflicts[]?, .[].dequeued[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"

# --- Exercised for real: the script against a combined stub gh -------------
#
# $tmp_dir/prlist.json   the `gh pr list --json ...` payload
# $tmp_dir/probes.json   {"<number>": {queued, dequeued_at, dequeue_reason}}
#                        keyed by PR number as a string; a number absent here
#                        makes the probe fail (unreadable), exactly as a real
#                        `gh api graphql` failure would.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"

if [[ "$1 $2" == "pr list" ]]; then
  cat "$d/prlist.json"
  exit 0
fi

if [[ "$1 $2" == "api graphql" ]]; then
  number=""
  prev=""
  for a in "$@"; do
    [[ "$prev" == "-F" && "$a" == number=* ]] && number="${a#number=}"
    prev="$a"
  done
  probe="$(jq -c --arg n "$number" '.[$n] // empty' "$d/probes.json" 2>/dev/null)"
  [[ -n "$probe" ]] || exit 1
  jqfilter="" prev=""
  for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqfilter="$a"
    prev="$a"
  done
  jq -nc --argjson pr "$probe" \
    '{data: {repository: {pullRequest: {
        isInMergeQueue: $pr.queued,
        timelineItems: {nodes: (if $pr.dequeued_at == null then []
                                 else [{createdAt: $pr.dequeued_at, reason: ($pr.dequeue_reason // "")}] end)}
      }}}}' | jq -c "$jqfilter"
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/gh"

pr_entry() {  # <number> <headRefName> <mergeable> <isDraft>
  jq -nc --argjson n "$1" --arg h "$2" --arg m "$3" --argjson d "$4" --arg sha "sha${1}00000000" \
    '{number: $n, title: ("fix " + ($n|tostring)), headRefName: $h, headRefOid: $sha,
      baseRefName: "main", isDraft: $d, mergeable: $m,
      updatedAt: "2026-08-01T00:00:00Z", url: ("https://github.com/o/r/pull/" + ($n|tostring)),
      body: "body"}'
}

# Fixture: five candidate PRs exercising every gate at once.
#   96  MERGEABLE, queued=false, dequeued_at set, reason=failed_checks -> candidate
#   97  MERGEABLE, currently queued (re-queued since)                  -> not a candidate
#   98  MERGEABLE, queued=false, reason=manual removal                 -> not a candidate (deny)
#   99  MERGEABLE, probe unreadable (no fixture entry)                 -> not a candidate (fail closed)
#   100 CONFLICTING, would otherwise match failed_checks                -> not a candidate (merge-conflicts' own)
jq -nc \
  --argjson p96 "$(pr_entry 96 agent/td96 MERGEABLE false)" \
  --argjson p97 "$(pr_entry 97 agent/td97 MERGEABLE false)" \
  --argjson p98 "$(pr_entry 98 agent/td98 MERGEABLE false)" \
  --argjson p99 "$(pr_entry 99 agent/td99 MERGEABLE false)" \
  --argjson p100 "$(pr_entry 100 agent/td100 CONFLICTING false)" \
  '[$p96, $p97, $p98, $p99, $p100]' > "$tmp_dir/prlist.json"

jq -nc '{
  "96": {queued: false, dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "failed_checks"},
  "97": {queued: true,  dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "failed_checks"},
  "98": {queued: false, dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "the enqueuer removed this pull request from the queue"},
  "100": {queued: false, dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "failed_checks"}
}' > "$tmp_dir/probes.json"

out="$(DEQUEUED_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-dequeued.sh" "o/r" "autonomous-agent" "agent/" 2>"$tmp_dir/stderr")"

assert_eq "gather-dequeued.sh exits with a valid JSON array" \
  "array" "$(jq -r 'type' <<<"$out" 2>/dev/null || echo "not-json")"
assert_eq "only the checks-failure, not-currently-queued, MERGEABLE PR is a candidate" \
  "[96]" "$(jq -c '[.[].number]' <<<"$out")"
assert_eq "the candidate carries source, ref, dequeued_at and dequeue_reason" \
  '{"source":"dequeued","ref":"pr-96-dequeued-sha960000000","dequeued_at":"2026-08-14T01:00:00Z","dequeue_reason":"failed_checks"}' \
  "$(jq -c '.[0] | {source, ref, dequeued_at, dequeue_reason}' <<<"$out")"
assert_eq "a currently re-queued PR is never a candidate" \
  "0" "$(jq '[.[] | select(.number == 97)] | length' <<<"$out")"
assert_eq "a non-failed_checks dequeue reason is never a candidate — the allow-list, not a deny-list" \
  "0" "$(jq '[.[] | select(.number == 98)] | length' <<<"$out")"
assert_eq "an unreadable probe (no fixture) is never a candidate — fail closed, never 'not dequeued'" \
  "0" "$(jq '[.[] | select(.number == 99)] | length' <<<"$out")"
assert_eq "a CONFLICTING PR is never a candidate even with a matching probe — merge-conflicts' alone" \
  "0" "$(jq '[.[] | select(.number == 100)] | length' <<<"$out")"

# --- Fails safe -------------------------------------------------------------
empty_out="$(DEQUEUED_GH="$tmp_dir/gh-missing" "$SCRIPT_DIR/scripts/gather-dequeued.sh" "o/r" "autonomous-agent" "agent/" 2>/dev/null)"
assert_eq "an unreachable gh degrades to an empty array, exit 0" \
  "[]" "$empty_out"

if (( failures > 0 )); then
  printf '\n%d assertion(s) FAILED\n' "$failures"
  exit 1
fi
printf '\nAll assertions passed.\n'
