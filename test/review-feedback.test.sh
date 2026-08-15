#!/usr/bin/env bash
#
# test/review-feedback.test.sh — regression test for the candidate rule of
# scripts/gather-review-feedback.sh (requirement 3c).
#
# The rule decides *whose turn it is* on a pull request a human has asked for
# changes on, and it has exactly one dangerous direction. The agent raises PRs
# as the account it runs as, and GitHub forbids approving or dismissing a review
# on your own PR — so `reviewDecision` stays CHANGES_REQUESTED even after the
# fix is pushed. Nothing about the PR's own state ever says "answered". The only
# thing that does is the comparison this file tests: the blocking review
# against GitHub review-thread events (a marked reply, or a review-requested
# event) — never a commit's date, which a force-push re-stamps to push time
# without a human, or the agent, having answered anything (agent-ops#239).
#
# Get it wrong and every PR the agent fixes stays a candidate forever: selected,
# re-fixed, re-selected, on the hour, each cycle looking like a productive one
# and each one paying a Sonnet run to redo work already pushed. The pipeline
# would never look broken.
#
# Most of the rule is tested where it lives — as jq over the same shapes the
# GitHub API returns, with the gatherer's `gh` calls out of reach of a unit
# test. Keep this in step with the filters in the script.
#
# The pagination hazard below is the exception: it is a property of how the
# script's four `gh api --paginate` reads combine across page boundaries, so
# it can only be caught by running the real script (via REVIEW_FEEDBACK_GH)
# against a stub `gh` that actually pages a fixture, the way
# test/merge-conflicts.test.sh's Dependabot section already does for its own
# script (see "The gatherer itself, exercised via a stub gh" below).
#
# Run directly:
#
#   ./test/review-feedback.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
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

# --- The PR filter: which PRs are even ours to answer? ---

# The shape `gh pr list --json number,title,headRefName,headRefOid,isDraft,reviewDecision,url,body`
# returns. One of each kind we must accept or reject.
prs='[
  {"number": 57, "isDraft": false, "reviewDecision": "CHANGES_REQUESTED", "headRefName": "agent/td1-fix"},
  {"number": 58, "isDraft": true,  "reviewDecision": "CHANGES_REQUESTED", "headRefName": "agent/td2-fix"},
  {"number": 59, "isDraft": false, "reviewDecision": "APPROVED",          "headRefName": "agent/td3-fix"},
  {"number": 60, "isDraft": false, "reviewDecision": "REVIEW_REQUIRED",   "headRefName": "agent/td4-fix"},
  {"number": 61, "isDraft": false, "reviewDecision": null,                "headRefName": "agent/td5-fix"},
  {"number": 62, "isDraft": false, "reviewDecision": "CHANGES_REQUESTED", "headRefName": "feature/a-humans-branch"}
]'

pr_filter() {
  jq -c '[.[] | select(.isDraft | not)
              | select(.reviewDecision == "CHANGES_REQUESTED")
              | select(.headRefName | startswith("agent/"))
              | .number]' <<<"$prs"
}

assert_eq "only open, ready, agent-branch, changes-requested PRs are candidates" \
  "[57]" "$(pr_filter)"

# Each exclusion, named, so a future edit that drops one fails loudly:
# - #58 draft: a draft PR is the Implementor's own claim marker, not something a
#   human has finished reviewing.
# - #59/#60/#61: nobody has asked for changes.
# - #62: the Human Gate is explicit that branches outside `branch_prefix` belong
#   to humans. An agent force-pushing a colleague's PR because they happened to
#   request changes on it would be a memorable way to discover this rule.
assert_eq "a draft PR is not a review-feedback candidate" \
  "0" "$(jq '[.[] | select(.number == 58) | select(.isDraft | not)] | length' <<<"$prs")"
assert_eq "an approved PR is not a review-feedback candidate" \
  "0" "$(jq '[.[] | select(.number == 59) | select(.reviewDecision == "CHANGES_REQUESTED")] | length' <<<"$prs")"
assert_eq "a human's own branch is never ours to push to" \
  "0" "$(jq '[.[] | select(.number == 62) | select(.headRefName | startswith("agent/"))] | length' <<<"$prs")"

# --- The turn rule: is the feedback unanswered? ---
#
# Mirrors scripts/gather-review-feedback.sh's own jq exactly (kept in step, per
# the file header): the review currently blocking `reviewDecision` (a
# reviewer's own latest APPROVED-or-CHANGES_REQUESTED review, filtered to
# CHANGES_REQUESTED), then "answered" is any marked reply or review-requested
# event *after* that review's timestamp — never a commit's date, which a
# force-push can re-stamp without a human, or the agent, having done anything
# (agent-ops#239; PR #205 silently dropped out of selection this way).

marker="$PIPELINE_COMMENT_MARKER_PREFIX"

# submitted_at null = a pending review the human is still drafting; it has not
# been sent and must not count as feedback. Two accounts, as in the wild: the
# agent's own (`warwickallen`, COMMENTED only — it cannot request changes on
# its own PR) and the human's second account (`Warwick-Allen`).
reviews='[
  {"id": 1, "state": "COMMENTED",         "at": "2026-07-17T01:22:24Z", "who": "warwickallen"},
  {"id": 2, "state": "CHANGES_REQUESTED", "at": "2026-07-17T01:22:54Z", "who": "Warwick-Allen"}
]'

blocking_of() {
  jq -c '
    ([.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")]
     | group_by(.who) | map(last)) as $latest_per_reviewer
    | ($latest_per_reviewer | map(select(.state == "CHANGES_REQUESTED")) | sort_by(.at) | last) // null
  ' <<<"$1"
}
# extract_answer_events REVIEWS ISSUE_COMMENTS REREQUESTS
# The exact extraction scripts/gather-review-feedback.sh runs: a marked review
# or marked general comment whose marker's `actor=` field is `implementor`, or
# any review-requested timeline event. Other actors (`script`, `enabler`,
# `reviewer`, `refiner`) and a legacy marker with no `actor=` field at all are
# marked but must not close a round — only the Implementor's own reply does
# (agent-ops#292, decided in agent-ops#278).
extract_answer_events() {
  jq -c -n --arg marker "$marker" --arg implementor_actor "actor=implementor -->" \
      --argjson reviews "$1" --argjson comments "$2" --argjson rr "$3" '
    ([$reviews[]  | select((.body // "") | contains($marker) and contains($implementor_actor)) | .at]
     + [$comments[] | select((.body // "") | contains($marker) and contains($implementor_actor)) | .at]
     + [$rr[] | .at]) | sort
  '
}
answered_after() {
  # $1 = answer_events (a JSON array of timestamp strings), $2 = cutoff
  jq -r --arg c "$2" '[.[] | select(. > $c)] | length' <<<"$1"
}

assert_eq "COMMENTED never blocks — the CHANGES_REQUESTED review is the round" \
  '{"id":2,"state":"CHANGES_REQUESTED","at":"2026-07-17T01:22:54Z","who":"Warwick-Allen"}' \
  "$(blocking_of "$reviews")"

blocking_at="$(jq -r '.at' <<<"$(blocking_of "$reviews")")"

assert_eq "no answer event at all — unanswered, our turn" \
  "0" "$(answered_after '[]' "$blocking_at")"

# The case that decides whether this feature loops forever: the Implementor
# has answered — a marked reply comment, timestamped by GitHub when it was
# posted, not by any commit. The reply is a *general PR comment* (`gh pr
# comment`), which lands in issue comments, not the reviews collection.
# shellcheck disable=SC2016  # the backtick is literal Markdown, not command substitution
implementor_reply="$(jq -c -n --arg at "2026-07-17T01:30:00Z" --arg body "$(printf '**Implementor** · autonomous pipeline · node `poetic-1`\n\nAddressed both points.\n\n%s cycle=X actor=implementor -->' "$marker")" \
  '[{at: $at, body: $body}]')"
answered_by_reply="$(extract_answer_events '[]' "$implementor_reply" '[]')"
assert_eq "a marked reply after the review — answered, the human's turn" \
  "1" "$(answered_after "$answered_by_reply" "$blocking_at")"

# An unmarked comment — a human chiming in, or an unrelated bot — must not
# count as an answer; only this system's own marked write does.
human_comment="$(jq -c -n --arg at "2026-07-17T01:30:00Z" '[{at: $at, body: "looks close"}]')"
assert_eq "an unmarked comment after the review does not answer it" \
  "0" "$(answered_after "$(extract_answer_events '[]' "$human_comment" '[]')" "$blocking_at")"

# --- The actor restriction (agent-ops#292) ---
#
# On PR #269, an `actor=script` comment (a stage giving up) and an
# `actor=enabler` comment (a stall being diagnosed) each carried the marker
# and, under the old "any marked reply" rule, closed the round — the work sat
# stranded until a human was escalated (agent-ops#278). Only `actor=implementor`
# may close a round.
# shellcheck disable=SC2016  # the backtick is literal Markdown, not command substitution
script_giveup="$(jq -c -n --arg at "2026-07-17T01:30:00Z" --arg body "$(printf '**Script** · autonomous pipeline · node `poetic-1`\n\nThe Implementor stage stopped on this pull request.\n\n%s cycle=X actor=script -->' "$marker")" \
  '[{at: $at, body: $body}]')"
assert_eq "an actor=script comment (a stage giving up) does not answer the round" \
  "0" "$(answered_after "$(extract_answer_events '[]' "$script_giveup" '[]')" "$blocking_at")"

# shellcheck disable=SC2016  # the backtick is literal Markdown, not command substitution
enabler_diagnosis="$(jq -c -n --arg at "2026-07-17T01:30:00Z" --arg body "$(printf '**Enabler** · autonomous pipeline · node `poetic-1`\n\nStill blocked; diagnosing the stall.\n\n%s cycle=X actor=enabler -->' "$marker")" \
  '[{at: $at, body: $body}]')"
assert_eq "an actor=enabler comment (a stall being diagnosed) does not answer the round" \
  "0" "$(answered_after "$(extract_answer_events '[]' "$enabler_diagnosis" '[]')" "$blocking_at")"

# A legacy marker with no `actor=` field at all — from before the field
# existed — must not be treated as an answer either; only a positive
# `actor=implementor` match closes the round.
legacy_marker="$(jq -c -n --arg at "2026-07-17T01:30:00Z" --arg body "$(printf 'Addressed both points.\n\n%s cycle=X -->' "$marker")" \
  '[{at: $at, body: $body}]')"
assert_eq "a legacy marked comment with no actor= field does not answer the round" \
  "0" "$(answered_after "$(extract_answer_events '[]' "$legacy_marker" '[]')" "$blocking_at")"

# Equally, a review-requested event (confirm_review_requested, lib/handoff.sh)
# answers it, with no reply comment at all — GitHub's timeline record of
# `confirm_review_requested` asking the reviewer to look again.
rerequest_event="$(jq -c -n --arg at "2026-07-17T01:31:00Z" '[{at: $at}]')"
answered_by_rerequest="$(extract_answer_events '[]' '[]' "$rerequest_event")"
assert_eq "a review-requested event after the review — also answered" \
  "1" "$(answered_after "$answered_by_rerequest" "$blocking_at")"

# --- The regression this exists to prevent (agent-ops#239) ---
#
# A conflict-resolution force-push re-stamps every commit's date to push time.
# The old rule compared that date against the review's `submitted_at` and
# read a fresh commit date as "answered" — with no reply, no re-review, and no
# review-requested event: the push resolved a conflict, it did not address a
# single word of the review. The new rule has nothing to feed on here: a
# force-push produces zero answer events, so the round stays a candidate no
# matter how recent the commit is.
force_pushed_commit_at="2026-07-17T09:00:00Z"
assert_eq "a force-push with no answer event never satisfies the old commit compare" \
  "true" "$([[ "$force_pushed_commit_at" > "$blocking_at" ]] && echo true || echo false)"
assert_eq "...but the new rule still finds it unanswered, no matter how new the commit is" \
  "0" "$(answered_after '[]' "$blocking_at")"

# And a fresh round after a genuine answer is our turn again.
reviews_round2="$(jq -c '. + [{"id": 3, "state": "CHANGES_REQUESTED", "at": "2026-07-17T02:00:00Z", "who": "Warwick-Allen"}]' <<<"$reviews")"
blocking_at2="$(jq -r '.at' <<<"$(blocking_of "$reviews_round2")")"
assert_eq "a new CHANGES_REQUESTED after our answer reopens it" \
  "2026-07-17T02:00:00Z" "$blocking_at2"
assert_eq "...and the old answer event does not satisfy the new round" \
  "0" "$(answered_after "$answered_by_reply" "$blocking_at2")"

# --- The round's ref ---
#
# Scoped to the blocking review's id, not the PR. An item recorded blocked
# (requirement 34) stays blocked until something clears it, so a bare `pr-57`
# that the Implementor once failed on would still be blocked when the human
# posted fresh guidance — and their new review would land on a dead item. A
# per-round ref means each round is a new item no old block covers, the same
# reasoning as the review-dated `review-<date>-R-NN` refs.
ref_of() {
  local reviews_json="$1" id
  id="$(jq -r '.id' <<<"$(blocking_of "$reviews_json")")"
  printf 'pr-57-review-%s' "$id"
}
assert_eq "the ref pins to the blocking review, not the chattiest one" \
  "pr-57-review-2" "$(ref_of "$reviews")"
assert_eq "a second round yields a different ref, so an old block cannot cover it" \
  "pr-57-review-3" "$(ref_of "$reviews_round2")"

# --- The body: every review in the round, whoever wrote it ---
#
# The substance and the formal signal routinely live in different reviews by
# different accounts, because GitHub will not let a PR's author request changes
# on it. In the wild here: `warwickallen` (the agent's own account, so
# COMMENTED is all it can leave) wrote 6.5 KB of specific findings, and the
# human's second account posted the CHANGES_REQUESTED whose body reads, in full,
# "Refer to <link>". Gathering only the blocking review hands the Implementor
# the word "Refer to" and nothing to act on.
round='[
  {"id": 1, "state": "COMMENTED", "at": "2026-07-17T01:22:24Z", "who": "warwickallen", "body": "the gitignore gap is the one I would block on"},
  {"id": 2, "state": "CHANGES_REQUESTED", "at": "2026-07-17T01:22:54Z", "who": "Warwick-Allen", "body": "Refer to https://github.com/…#pullrequestreview-4718691960"}
]'
body="$(jq -r --argjson fr "$round" --argjson fc '[]' -n '
  ([$fr[] | "── review (\(.state)) by \(.who) at \(.at)\n\(.body)"] +
   [$fc[] | "── inline comment by \(.who) on \(.path):\(.line // "?") at \(.at)\n\(.body)"])
  | join("\n\n")')"
assert_eq "the body carries the substantive COMMENTED review, not just the blocking one" \
  "1" "$(grep -c 'gitignore gap' <<<"$body")"
assert_eq "the body carries the blocking review too" \
  "1" "$(grep -c 'Refer to' <<<"$body")"

# --- Back-pressure restriction (requirement 2.2a) ---
#
# The narrowing agent-cycle.sh applies when back-pressure trips and review
# feedback is waiting. Tested here rather than live because reaching the branch
# needs max_open_agent_prs exceeded *and* an unanswered review round at the same
# moment — a state that exists only when the pipeline is genuinely stuck, which
# is exactly when nobody wants to be finding out whether this works.
#
# The narrowing is what stops the deadlock: with every agent PR sent back for
# changes, the plain check would stand the cycle down before the Co-Ordinator
# ran, so the one source that could clear them is never reached and the pipeline
# dies silently. Restricting the source list rather than adding a mode flag
# means the Co-Ordinator cannot select anything else — it is told the runtime
# input's `sources` are authoritative, and a source it cannot see is a source it
# cannot pick.
ordered='[
  {"slug": "o/one", "sources": ["security", "review-feedback", "tech-debt", "issues"], "review_feedback": [{"ref": "pr-57-review-2"}]},
  {"slug": "o/two", "sources": ["security", "review-feedback", "issues"], "review_feedback": []}
]'
# Narrowing is to lib/handoff.sh's handoff_narrow_repos_to_finishing_sources
# (requirement 2.2a, issue #431) — the four *finishing* sources
# (review-feedback, merge-conflicts, dequeued, abandoned-drafts); this fixture
# only carries review-feedback, so the result is review-feedback alone. The
# other three sides are exercised in their own tests.
restrict() { handoff_narrow_repos_to_finishing_sources "$ordered"; }

assert_eq "restriction leaves only review-feedback selectable" \
  '["review-feedback"] ["review-feedback"]' \
  "$(restrict | jq -r '[.[] | (.sources | tojson)] | join(" ")')"
assert_eq "security is narrowed away too — a full gate means finish, don't start" \
  "0" "$(restrict | jq '[.[].sources[] | select(. == "security")] | length')"
assert_eq "the repos themselves survive the narrowing" \
  "2" "$(restrict | jq 'length')"
assert_eq "the waiting candidates are still attached for the Co-Ordinator to read" \
  "1" "$(restrict | jq '[.[].review_feedback[]?] | length')"

# The count that decides stand-down vs restrict.
assert_eq "candidates across all repos are counted, not just the first" \
  "1" "$(jq '[.[].review_feedback[]?] | length' <<<"$ordered")"
assert_eq "with nothing waiting, the count is 0 and the cycle stands down as before" \
  "0" "$(jq '[.[] | .review_feedback = []] | [.[].review_feedback[]?] | length' <<<"$ordered")"

# --- The gatherer itself fails safe ---

assert_eq "an unknown repo yields [] and exit 0, never a broken cycle" "[]" \
  "$("$SCRIPT_DIR/scripts/gather-review-feedback.sh" "Poetic-Poems/does-not-exist" autonomous-agent 'agent/' 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

# --- Pagination past thirty items (TD-PPagop-26081306) ---
#
# `gh api --paginate` re-runs its `--jq` filter once per page and prints each
# page's result as its own JSON document; it never concatenates pages before
# filtering. A `--jq` filter that builds its own aggregate (`[.[] | …]`) is
# therefore computed *per page* and disagrees with itself past the endpoint's
# thirty-item default page size — the exact hazard test/handoff.test.sh already
# pins for `handoff_round_answered` itself ("two concatenated pages are
# unknown, never answered"). This section pins the other half: that the four
# `gh api --paginate` reads in the script feed that function one correct,
# fully-aggregated array each, no matter which page an item lands on.
#
# Reached only by running the real script through a stub `gh`
# (REVIEW_FEEDBACK_GH) that pages a fixture for real — 30 items per page,
# GitHub's own default — the way test/merge-conflicts.test.sh's Dependabot
# section already does for gather-merge-conflicts.sh. A plain jq assertion
# over an already-assembled array cannot exercise a page boundary; only a `gh`
# call that actually splits the fixture and re-invokes the filter per page can.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
d="$(dirname "$0")"

if [[ "${1:-} ${2:-}" == "pr list" ]]; then
  cat "$d/prs.json"
  exit 0
fi

if [[ "${1:-}" == "api" ]]; then
  endpoint="$2"
  shift 2
  filter=""
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--jq" ]]; then
      filter="${args[$((i + 1))]}"
      break
    fi
  done
  case "$endpoint" in
    */pulls/*/reviews) fixture="$d/reviews.json" ;;
    */issues/*/comments) fixture="$d/issue-comments.json" ;;
    */issues/*/timeline) fixture="$d/timeline.json" ;;
    */pulls/*/comments) fixture="$d/pr-comments.json" ;;
    *) exit 1 ;;
  esac
  # Reproduce gh api --paginate's own behaviour for real: split the fixture
  # into 30-item pages (GitHub's own default) and run the --jq filter once per
  # page, printing each page's result as its own JSON document — never merged
  # across pages. A filter that aggregates internally (`[.[] | …]`) would
  # therefore emit one array per page here, not one array overall; the fixed
  # script's filters emit one object per matching item instead, which stays
  # correct regardless of where the split falls.
  jq -c '[range(0; (. | length); 30) as $i | .[$i:($i + 30)]]' "$fixture" \
    | jq -c '.[]' \
    | while IFS= read -r page; do
        jq -c "$filter" <<<"$page"
      done
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"

cat > "$tmp_dir/prs.json" <<'JSON'
[
  {"number": 200, "title": "fix(pagination): stream every gh api --paginate read",
   "headRefName": "agent/td-pagination-fix", "headRefOid": "abc123def456",
   "isDraft": false, "reviewDecision": "CHANGES_REQUESTED",
   "url": "https://github.com/o/r/pull/200", "body": ""}
]
JSON

# 31 reviews: 30 COMMENTED fillers fill page one exactly, so the sole
# CHANGES_REQUESTED review — the blocking review the whole candidate rule
# hinges on — lands alone on page two, as isolated as a page boundary can put
# it.
jq -n '[range(0; 30) | {id: (. + 1), state: "COMMENTED",
        submitted_at: ("2026-08-01T00:00:" + (if . < 10 then "0" else "" end) + (. | tostring) + "Z"),
        user: {login: ("filler-reviewer-" + (. | tostring))}, body: "noise"}]' \
  | jq '. + [{"id": 999, "state": "CHANGES_REQUESTED", "submitted_at": "2026-08-01T00:05:00Z",
              "user": {"login": "Warwick-Allen"},
              "body": "Please fix the pagination handling."}]' \
  > "$tmp_dir/reviews.json"

jq -n '[range(0; 30) | {created_at: ("2026-08-01T00:00:" + (if . < 10 then "0" else "" end) + (. | tostring) + "Z"),
        body: "unrelated chatter"}]' > "$tmp_dir/issue-comments-unanswered.json"

jq '. + [{"created_at": "2026-08-01T00:06:00Z", "body": "still not it"}]' \
  "$tmp_dir/issue-comments-unanswered.json" > "$tmp_dir/issue-comments.json"

printf '[]' > "$tmp_dir/timeline.json"

jq -n '[range(0; 30) | {created_at: ("2026-08-01T00:00:" + (if . < 10 then "0" else "" end) + (. | tostring) + "Z"),
        user: {login: "filler"}, path: "README.md", line: 1, body: "noise"}]' \
  | jq '. + [{"created_at": "2026-08-01T00:07:00Z", "user": {"login": "Warwick-Allen"},
              "path": "scripts/gather-review-feedback.sh", "line": 220,
              "body": "this is the inline comment on the second page"}]' \
  > "$tmp_dir/pr-comments.json"

out="$(REVIEW_FEEDBACK_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-review-feedback.sh" o/r autonomous-agent 'agent/' 2>/dev/null)"
assert_eq "an unanswered round is still found with the blocking review alone on page two" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... the ref pins to the blocking review found on page two, not a filler's" \
  "pr-200-review-999" "$(jq -r '.[0].ref' <<<"$out")"
assert_eq "  ... the body carries the blocking review's own text" \
  "1" "$(jq -r '.[0].body' <<<"$out" | grep -c 'Please fix the pagination handling')"
assert_eq "  ... and the inline comment that itself landed on page two" \
  "1" "$(jq -r '.[0].body' <<<"$out" | grep -c 'this is the inline comment on the second page')"

# Now the answer — the Implementor's own marked reply — is what lands alone on
# page two of the issue-comments read. Before the fix this is exactly the
# read whose --argjson downstream failed on a multi-page value; after it, the
# round must read cleanly as answered and the PR must drop out of the
# candidate list.
marker="$PIPELINE_COMMENT_MARKER_PREFIX"
# shellcheck disable=SC2016  # the backtick is literal Markdown, not command substitution
implementor_reply="$(printf '**Implementor** · autonomous pipeline · node `poetic-1`\n\nAddressed the pagination bug.\n\n%s cycle=X actor=implementor -->' "$marker")"
jq --arg body "$implementor_reply" \
  '. + [{"created_at": "2026-08-01T00:10:00Z", "body": $body}]' \
  "$tmp_dir/issue-comments-unanswered.json" > "$tmp_dir/issue-comments.json"

out="$(REVIEW_FEEDBACK_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-review-feedback.sh" o/r autonomous-agent 'agent/' 2>/dev/null)"
assert_eq "a marked reply isolated alone on page two of the comments read answers the round" \
  "0" "$(jq 'length' <<<"$out")"

# --- The argv cap (requirement 4g, TD-PPagop-26081406) ---
#
# The assembled review body ($fresh/$fresh_comments), the candidate build
# ($pr, a whole pull-request object including its body) and the per-candidate
# append ($cand) all used to ride into jq as --argjson: genuinely unbounded,
# not merely growing — the same shape and the same reasoning that put
# gather-merge-conflicts.sh first on TD-PPagop-26081401's list. Past
# MAX_ARG_STRLEN (131072 bytes) the build died at execve; this repo's whole
# review_feedback band came out empty. Requirement 4g moves all three onto
# stdin.
#
# The candidate build ($pr) is pinned by driving the real script, via the
# same stub gh as the pagination section above, with a PR object whose body
# alone is past the cap — genuinely unbounded even though the candidate's own
# `body` field is assembled from the reviews, not from $pr.body, because the
# whole $pr object rides together regardless of which fields the jq program
# reads. (lib/handoff.sh's own `handoff_answer_events` reads the same
# $reviews array first, before $fresh is even derived — TD-PPagop-26081406
# did not enumerate it, so it was left alone and filed separately as
# TD-PPagop-26081501; that item's own fix is pinned below, driving the real
# script the same way rather than in TD-PPagop-26081501's own
# test/handoff.test.sh, since only running the real script proves this
# script's own upstream call is what benefits.)
# One fixture for every argv-cap scenario below — the PR body, the review
# body and the extracted-block runs all need the same "past MAX_ARG_STRLEN"
# property and nothing else, so generating it once keeps them from drifting
# apart silently when one is edited.
oversized_body="$(head -c 140000 < /dev/zero | tr '\0' 'x')"
assert_eq "the oversized-body fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( ${#oversized_body} > 131072 ))"

cat > "$tmp_dir/prs.json" <<JSON
[
  {"number": 300, "title": "fix(oversized): pad the PR body past the argv cap",
   "headRefName": "agent/td-oversized-fix", "headRefOid": "0ff512edb0dy",
   "isDraft": false, "reviewDecision": "CHANGES_REQUESTED",
   "url": "https://github.com/o/r/pull/300", "body": "$oversized_body"}
]
JSON
cat > "$tmp_dir/reviews.json" <<'JSON'
[{"id": 1, "state": "CHANGES_REQUESTED", "submitted_at": "2026-08-01T00:05:00Z",
  "user": {"login": "Warwick-Allen"}, "body": "please fix"}]
JSON
printf '[]' > "$tmp_dir/issue-comments.json"
printf '[]' > "$tmp_dir/timeline.json"
printf '[]' > "$tmp_dir/pr-comments.json"

out="$(REVIEW_FEEDBACK_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-review-feedback.sh" o/r autonomous-agent 'agent/' 2>/dev/null)"
assert_eq "a PR object past the argv cap still produces the candidate" "1" \
  "$(jq 'length' <<<"$out")"
assert_eq "  ... and the ref still pins to the blocking review (oversized PR body)" \
  "pr-300-review-1" "$(jq -r '.[0].ref' <<<"$out")"

# A single oversized *review* body (TD-PPagop-26081501): before that fix, this
# died in `handoff_answer_events` (lib/handoff.sh), upstream of $fresh even
# being derived, so a single oversized review failed the whole candidate rule
# regardless of how small everything else stayed — the exact repro the
# tech-debt record confirmed by hand.
cat > "$tmp_dir/prs.json" <<'JSON'
[
  {"number": 301, "title": "fix(oversized): pad a review body past the argv cap",
   "headRefName": "agent/td-oversized-review", "headRefOid": "0ff512edb0dz",
   "isDraft": false, "reviewDecision": "CHANGES_REQUESTED", "url": "https://github.com/o/r/pull/301", "body": ""}
]
JSON
printf '[{"id": 2, "state": "CHANGES_REQUESTED", "submitted_at": "2026-08-01T00:05:00Z", "user": {"login": "Warwick-Allen"}, "body": "%s"}]' \
  "$oversized_body" > "$tmp_dir/reviews.json"
printf '[]' > "$tmp_dir/issue-comments.json"
printf '[]' > "$tmp_dir/timeline.json"
printf '[]' > "$tmp_dir/pr-comments.json"

out="$(REVIEW_FEEDBACK_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-review-feedback.sh" o/r autonomous-agent 'agent/' 2>/dev/null)"
assert_eq "an oversized single review body no longer kills handoff_answer_events" "1" \
  "$(jq 'length' <<<"$out")"
assert_eq "  ... and the ref still pins to the blocking review (oversized review body)" \
  "pr-301-review-2" "$(jq -r '.[0].ref' <<<"$out")"

# The review-body assembly and the per-candidate array append are inline, not
# functions, so each is lifted by its own literal start/end lines — the same
# technique test/pr-claim-exclusion.test.sh's `extract_claims_fold` uses —
# and run with the real script's own $fresh/$fresh_comments and $out/$cand
# too large to have survived as a second --argjson.
extract_block() {  # extract_block <start-literal> <end-literal>
  awk -v s="$1" -v e="$2" \
    'index($0, s) == 1 { on = 1 } on { print } on && index($0, e) > 0 { exit }' \
    "$SCRIPT_DIR/scripts/gather-review-feedback.sh"
}

# shellcheck disable=SC2016  # both single-quoted args are literal source text to match, not meant to expand
body_block="$(extract_block '  body_json="$(jq -cn' 'body_json='"'"'""'"'"'')"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$body_block" != *'input as $fr | input as $fc'* ]]; then
  printf 'FAIL - could not extract the review-body assembly from scripts/gather-review-feedback.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi

run_body_block() {  # run_body_block <fresh-json> <fresh_comments-json>
  # fresh and fresh_comments are consumed only by the eval'd body_block,
  # invisible to shellcheck.
  # shellcheck disable=SC2034
  # stderr silenced: the assembly is deliberately loud on unparseable input,
  # which is the direction we want in production and noise in a test.
  ( fresh="$1" fresh_comments="$2"; eval "$body_block" 2>/dev/null; printf '%s' "$body_json" )
}
# Bash-side JSON assembly, not jq --arg: an --arg carrying the oversized
# string would hit the very argv cap this section exists to prove the real
# code no longer does.
fresh_oversized="$(printf '[{"state": "CHANGES_REQUESTED", "who": "Warwick-Allen", "at": "2026-08-01T00:05:00Z", "body": "%s"}]' "$oversized_body")"
built_body="$(run_body_block "$fresh_oversized" '[]')"
assert_eq "a fresh-reviews array past the argv cap still assembles the body" "1" \
  "$([[ "$built_body" == *"$oversized_body"* ]] && echo 1 || echo 0)"
# The assembly stays JSON-encoded rather than raw, because its only consumer
# is the candidate build and it has to reach it on stdin: this string is the
# concatenation of the two arrays just taken out of argv, so handing it on as
# an `--arg body` would put every one of those bytes back into a single argv
# element and leave the cap exactly where it was.
assert_eq "  ... and hands it on JSON-encoded, ready for stdin" "1" \
  "$(jq -e 'type == "string"' <<<"$built_body" >/dev/null 2>&1 && echo 1 || echo 0)"
# A failed assembly still yields a document the candidate build can bind, so
# a PR whose review text cannot be rendered keeps its candidate with an empty
# body rather than being dropped from the band.
assert_eq "an unparseable reviews array still yields a bindable empty body" '""' \
  "$(run_body_block 'not json' '[]')"

# The candidate build: $pr and the assembled body both arrive on stdin now.
# Driven with a body past the cap, which as an `--arg body` died at execve and
# took the candidate with it.
# shellcheck disable=SC2016  # both single-quoted args are literal source text to match, not meant to expand
cand_block="$(extract_block '  cand="$(jq -nc' '"$body_json")" || {')"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$cand_block" != *'input as $pr | input as $body'* ]]; then
  printf 'FAIL - could not extract the candidate build from scripts/gather-review-feedback.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
run_cand_block() {  # run_cand_block <pr-json> <body-json>
  # every one of these is consumed only by the eval'd cand_block, invisible
  # to shellcheck.
  # shellcheck disable=SC2034
  ( pr="$1" body_json="$2" number="400" review_id="7" item="" head_sha="abc123"
    reviewed_at="2026-08-01T00:05:00Z" slug="o/r"
    eval "${cand_block%|| \{}"; printf '%s' "$cand" )
}
oversized_body_json="$(printf '"%s"' "$oversized_body")"
assert_eq "the oversized assembled-body fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( ${#oversized_body_json} > 131072 ))"
built_cand="$(run_cand_block \
  '{"number":400,"url":"https://github.com/o/r/pull/400","title":"t","headRefName":"agent/x"}' \
  "$oversized_body_json")"
assert_eq "an assembled review body past the argv cap still produces the candidate" \
  "pr-400-review-7" "$(jq -r '.ref' <<<"$built_cand")"
# Compared in bash, not with `jq --arg b`: an --arg carrying the oversized
# string would hit the very cap this section exists to prove the real code no
# longer does — the same trap the body assembly above sidesteps.
assert_eq "  ... carrying the whole oversized body, not a truncation" "1" \
  "$([[ "$(jq -r '.body' <<<"$built_cand")" == "$oversized_body" ]] && echo 1 || echo 0)"

# The per-candidate array append: $out (the whole review_feedback band
# collected so far) and $cand both arrive on stdin now, not argv — pinned
# with an accumulator already past the cap from prior candidates, proving a
# late append does not drop what came before it.
# shellcheck disable=SC2016  # both single-quoted args are literal source text to match, not meant to expand
append_block="$(extract_block '  out="$(jq -nc '"'"'input as $arr | input as $c' '  })"')"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$append_block" != *'candidate dropped'* ]]; then
  printf 'FAIL - could not extract the array-assembly append from scripts/gather-review-feedback.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
run_append_block() {  # run_append_block <out-json> <cand-json>
  # cand/slug/number/review_id are consumed only by the eval'd append_block,
  # invisible to shellcheck.
  # shellcheck disable=SC2034
  ( out="$1" cand="$2" slug="o/r" number="301" review_id="2"
    eval "$append_block"; printf '%s' "$out" )
}
big_out="$(jq -nc '[range(1300) | {source: "review-feedback", ref: ("pr-" + (. | tostring) + "-review-1"),
  body: ("pad " + ("x" * 100))}]')"
assert_eq "the oversized accumulator fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_out" | wc -c) > 131072 ))"
new_cand='{"source":"review-feedback","ref":"pr-301-review-2","body":"the newest one"}'
appended="$(run_append_block "$big_out" "$new_cand")"
assert_eq "an append onto an oversized accumulator keeps every prior candidate" \
  "1301" "$(jq 'length' <<<"$appended")"
assert_eq "  ... plus the new one just appended" "1" \
  "$(jq '[.[] | select(.ref == "pr-301-review-2")] | length' <<<"$appended")"

rm -rf "$tmp_dir"
trap - EXIT

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
