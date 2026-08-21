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
# A third gate holds a line the other two cannot reach. Unlike every sibling
# finishing source, nothing this system is permitted to do clears a dequeue:
# the timeline event is permanent, and only a human's "Merge when ready" flips
# `isInMergeQueue` back. So a fixed pull request keeps passing both gates
# above, and the head-SHA-scoped ref means each fix push mints a *fresh*
# candidate no block, void or claim covers. The answered clause — no marked
# `actor=implementer` reply newer than `dequeued_at` — is what stops that loop,
# and its assertions below are the ones to be most careful with: they are the
# difference between finishing a dequeue and re-opening it for ever.
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

# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"

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
# rather than standing down. The filter itself is lib/handoff.sh's
# handoff_narrow_repos_to_finishing_sources, sourced above — kept in one
# definition (issue #431) rather than hand-copied here.
ordered='[
  {"slug": "o/one", "sources": ["security", "review-feedback", "merge-conflicts", "dequeued", "abandoned-drafts", "tech-debt"], "review_feedback": [], "merge_conflicts": [], "dequeued": [{"ref": "pr-90-dequeued-1a2b3c4d5e6f"}], "abandoned_drafts": []},
  {"slug": "o/two", "sources": ["security", "review-feedback", "merge-conflicts", "dequeued", "abandoned-drafts", "issues"], "review_feedback": [], "merge_conflicts": [], "dequeued": [], "abandoned_drafts": []}
]'
restrict() { handoff_narrow_repos_to_finishing_sources "$ordered"; }

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
# $tmp_dir/reviews.json  {"<number>": [ {submitted_at, body}, … ]}
# $tmp_dir/comments.json {"<number>": [ {created_at, body}, … ]}
#                        the answered clause's two reads. A number absent from
#                        either file makes that read fail — the discriminator
#                        that must not be confused with an empty one, since
#                        both a failure and "nobody has commented" would
#                        otherwise arrive at the script as `[]`.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"

if [[ "$1 $2" == "pr list" ]]; then
  cat "$d/prlist.json"
  exit 0
fi

# The answered clause's reads: `api repos/<slug>/pulls/<n>/reviews` and
# `api repos/<slug>/issues/<n>/comments`, each with --paginate --jq. Real `gh`
# applies the filter per page and streams one object per line; so does this.
if [[ "$1" == "api" && "$2" == repos/*/pulls/*/reviews ]] \
   || [[ "$1" == "api" && "$2" == repos/*/issues/*/comments ]]; then
  case "$2" in
    */pulls/*) fixture="$d/reviews.json";  number="${2#*/pulls/}"; number="${number%/reviews}" ;;
    *)         fixture="$d/comments.json"; number="${2#*/issues/}"; number="${number%/comments}" ;;
  esac
  entries="$(jq -c --arg n "$number" '.[$n] // empty' "$fixture" 2>/dev/null)"
  # Absent from the fixture => this read fails, exactly as an API error would.
  [[ -n "$entries" ]] || exit 1
  jqfilter="" prev=""
  for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqfilter="$a"
    prev="$a"
  done
  jq -c "$jqfilter" <<<"$entries"
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

pr_entry() {  # <number> <headRefName> <mergeable> <isDraft> [updatedAt]
  jq -nc --argjson n "$1" --arg h "$2" --arg m "$3" --argjson d "$4" --arg sha "sha${1}00000000" \
    --arg u "${5:-2026-08-01T00:00:00Z}" \
    '{number: $n, title: ("fix " + ($n|tostring)), headRefName: $h, headRefOid: $sha,
      baseRefName: "main", isDraft: $d, mergeable: $m,
      updatedAt: $u, url: ("https://github.com/o/r/pull/" + ($n|tostring)),
      body: "body"}'
}

# The marker `handoff_answer_events` keys the answered clause on. Only
# `actor=implementer` closes a round; the others are here to prove they do not
# (the PR #269 / agent-ops#278 rule).
marker() {  # <actor>
  printf '<!-- agent-ops:pipeline-comment cycle=20260814T010000Z-n-1 actor=%s -->' "$1"
}

# Fixture: ten PRs exercising every gate at once.
#   96  MERGEABLE, queued=false, dequeued_at set, reason=failed_checks -> candidate
#   97  MERGEABLE, currently queued (re-queued since)                  -> not a candidate
#   98  MERGEABLE, queued=false, reason=manual removal                 -> not a candidate (deny)
#   99  MERGEABLE, probe unreadable (no fixture entry)                 -> not a candidate (fail closed)
#   100 CONFLICTING, would otherwise match failed_checks                -> not a candidate (merge-conflicts' own)
# …and the answered clause, whose whole point is that the five gates above
# all still pass on every one of these:
#   101 implementer's marked reply AFTER dequeued_at                   -> not a candidate (answered)
#   102 the same reply BEFORE dequeued_at (a second dequeue since)     -> candidate
#   103 marked reviewer reply + an unmarked comment, both after        -> candidate (only implementer answers)
#   104 implementer's marked reply in a REVIEW body, after            -> not a candidate (both collections read)
#   105 comments read fails (absent from the fixture)                  -> not a candidate (fail closed)
#
# 96/102/103 are the three candidates, and their `dequeued_at` order is
# deliberately the reverse of their `updatedAt` order, so the closing sort
# cannot pass by accident on either field.
jq -nc \
  --argjson p96 "$(pr_entry 96 agent/td96 MERGEABLE false)" \
  --argjson p97 "$(pr_entry 97 agent/td97 MERGEABLE false)" \
  --argjson p98 "$(pr_entry 98 agent/td98 MERGEABLE false)" \
  --argjson p99 "$(pr_entry 99 agent/td99 MERGEABLE false)" \
  --argjson p100 "$(pr_entry 100 agent/td100 CONFLICTING false)" \
  --argjson p101 "$(pr_entry 101 agent/td101 MERGEABLE false)" \
  --argjson p102 "$(pr_entry 102 agent/td102 MERGEABLE false 2026-08-20T00:00:00Z)" \
  --argjson p103 "$(pr_entry 103 agent/td103 MERGEABLE false 2026-07-01T00:00:00Z)" \
  --argjson p104 "$(pr_entry 104 agent/td104 MERGEABLE false)" \
  --argjson p105 "$(pr_entry 105 agent/td105 MERGEABLE false)" \
  '[$p96, $p97, $p98, $p99, $p100, $p101, $p102, $p103, $p104, $p105]' > "$tmp_dir/prlist.json"

jq -nc '{
  "96":  {queued: false, dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "failed_checks"},
  "97":  {queued: true,  dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "failed_checks"},
  "98":  {queued: false, dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "the enqueuer removed this pull request from the queue"},
  "100": {queued: false, dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "failed_checks"},
  "101": {queued: false, dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "failed_checks"},
  "102": {queued: false, dequeued_at: "2026-08-13T01:00:00Z", dequeue_reason: "failed_checks"},
  "103": {queued: false, dequeued_at: "2026-08-15T01:00:00Z", dequeue_reason: "failed_checks"},
  "104": {queued: false, dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "failed_checks"},
  "105": {queued: false, dequeued_at: "2026-08-14T01:00:00Z", dequeue_reason: "failed_checks"}
}' > "$tmp_dir/probes.json"

# Reviews: only #104's carries the implementer's marked reply; everything else
# has an empty (but readable) review list.
jq -nc --arg impl "$(marker implementer)" '{
  "96": [], "97": [], "98": [], "99": [], "100": [], "101": [], "102": [], "103": [], "105": [],
  "104": [{submitted_at: "2026-08-14T02:00:00Z", body: ("Fixed the merge-group run.\n\n" + $impl)},
          {submitted_at: null, body: "a pending review, never submitted, never an answer"}]
}' > "$tmp_dir/reviews.json"

# Comments. #105 is deliberately absent: that read fails.
jq -nc --arg impl "$(marker implementer)" --arg rev "$(marker reviewer)" '{
  "96": [], "97": [], "98": [], "99": [], "100": [], "104": [],
  "101": [{created_at: "2026-08-14T02:00:00Z", body: ("Found and fixed it.\n\n" + $impl)}],
  "102": [{created_at: "2026-08-12T02:00:00Z", body: ("Found and fixed it.\n\n" + $impl)}],
  "103": [{created_at: "2026-08-14T02:00:00Z", body: ("Reviewed.\n\n" + $rev)},
          {created_at: "2026-08-14T03:00:00Z", body: "a human saying thanks, with no marker at all"}]
}' > "$tmp_dir/comments.json"

out="$(DEQUEUED_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-dequeued.sh" "o/r" "autonomous-agent" "agent/" 2>"$tmp_dir/stderr")"

assert_eq "gather-dequeued.sh exits with a valid JSON array" \
  "array" "$(jq -r 'type' <<<"$out" 2>/dev/null || echo "not-json")"
assert_eq "only the checks-failure, not-currently-queued, MERGEABLE, unanswered PRs are candidates" \
  "[102,96,103]" "$(jq -c '[.[].number]' <<<"$out")"
assert_eq "the candidate carries source, ref, dequeued_at and dequeue_reason" \
  '{"source":"dequeued","ref":"pr-96-dequeued-sha960000000","dequeued_at":"2026-08-14T01:00:00Z","dequeue_reason":"failed_checks"}' \
  "$(jq -c '.[] | select(.number == 96) | {source, ref, dequeued_at, dequeue_reason}' <<<"$out")"
assert_eq "a currently re-queued PR is never a candidate" \
  "0" "$(jq '[.[] | select(.number == 97)] | length' <<<"$out")"
assert_eq "a non-failed_checks dequeue reason is never a candidate — the allow-list, not a deny-list" \
  "0" "$(jq '[.[] | select(.number == 98)] | length' <<<"$out")"
assert_eq "an unreadable probe (no fixture) is never a candidate — fail closed, never 'not dequeued'" \
  "0" "$(jq '[.[] | select(.number == 99)] | length' <<<"$out")"
assert_eq "a CONFLICTING PR is never a candidate even with a matching probe — merge-conflicts' alone" \
  "0" "$(jq '[.[] | select(.number == 100)] | length' <<<"$out")"

# --- The answered clause ----------------------------------------------------
#
# The whole point: every other gate still passes on all five PRs below. The
# dequeue itself never clears — `RemovedFromMergeQueueEvent` is permanent and
# only a human's re-queue flips `isInMergeQueue` back — so without this clause
# #101 and #104 would be re-offered on every cycle, at a fresh head-SHA ref no
# block covers, for as long as the human took to press "Merge when ready".
assert_eq "a dequeue the Implementer has already answered is not a candidate" \
  "0" "$(jq '[.[] | select(.number == 101)] | length' <<<"$out")"
assert_eq "the same reply BEFORE dequeued_at does not answer it — a second dequeue re-opens candidacy" \
  "1" "$(jq '[.[] | select(.number == 102)] | length' <<<"$out")"
assert_eq "another actor's marked reply, and an unmarked comment, never answer the round" \
  "1" "$(jq '[.[] | select(.number == 103)] | length' <<<"$out")"
assert_eq "the answer counts when it arrives as a review body, not only as an issue comment" \
  "0" "$(jq '[.[] | select(.number == 104)] | length' <<<"$out")"
assert_eq "an unreadable comments read yields no candidate rather than an unanswered one" \
  "0" "$(jq '[.[] | select(.number == 105)] | length' <<<"$out")"
assert_eq "…and says so on stderr rather than dropping it silently" \
  "1" "$(grep -c "pr #105's comments" "$tmp_dir/stderr")"

# --- Ordering: by dequeued_at, not updated_at -------------------------------
#
# #102 was dequeued first but commented on most recently; #103 was dequeued
# last but has the oldest `updatedAt`. Ordering on `updated_at` would put them
# in exactly the opposite order — which is the bug, because requirement 38f's
# own notice comment moves `updatedAt` on the very PRs this array carries, so
# telling the human would reset the pull request's place in the queue.
assert_eq "candidates are ordered longest-dequeued first" \
  "[102,96,103]" "$(jq -c '[.[].number]' <<<"$out")"
assert_eq "…which is not the order updated_at would have given" \
  "[103,96,102]" "$(jq -c '[sort_by(.updated_at)[].number]' <<<"$out")"

# --- Fails safe -------------------------------------------------------------
empty_out="$(DEQUEUED_GH="$tmp_dir/gh-missing" "$SCRIPT_DIR/scripts/gather-dequeued.sh" "o/r" "autonomous-agent" "agent/" 2>/dev/null)"
assert_eq "an unreachable gh degrades to an empty array, exit 0" \
  "[]" "$empty_out"

if (( failures > 0 )); then
  printf '\n%d assertion(s) FAILED\n' "$failures"
  exit 1
fi
printf '\nAll assertions passed.\n'
