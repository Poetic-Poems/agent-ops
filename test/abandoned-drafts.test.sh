#!/usr/bin/env bash
#
# test/abandoned-drafts.test.sh — regression test for the candidate rule of
# scripts/gather-abandoned-drafts.sh (requirement 3e) and the back-pressure
# narrowing it shares with review-feedback (requirement 2.2a).
#
# The rule decides which of *our own* draft PRs have been abandoned and are safe
# to finish, and it has two dangerous directions:
#   - too eager, and it steals a draft a peer node (or a human) is still working,
#     force-pushing over live work;
#   - too shy, and a genuinely stalled draft sits forever occupying a
#     back-pressure slot while every cycle looks healthy.
# The freshness gate is "last **real** activity older than the threshold"
# (TD26072605) — not GitHub's raw `updatedAt`, which also moves for a label edit
# or a comment the pipeline posted about itself, neither of which means anybody
# is on it. This is the half most easily broken by a careless edit — so it is
# asserted here, as jq over the same shapes the GitHub API returns, since the
# gatherer's `gh` calls aren't reachable from a unit test. Keep this in step with
# the filters in the script.
#
# Run directly:
#
#   ./test/abandoned-drafts.test.sh
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

# --- The candidate filter: which draft PRs are ours to finish? ---

# The shape the gatherer works on: what `gh pr list --json
# number,title,headRefName,headRefOid,isDraft,updatedAt,url,body,comments,reviews`
# returns (the `--label` filter is applied by gh, so every row here already
# carries pr_label), with `head_committed_at` annotated onto each row from the
# one REST call the gatherer makes per surviving candidate — `GET
# /repos/<slug>/commits/<headRefOid>`, read as `.commit.committer.date`.
#
# The listing no longer asks for the whole `commits` collection. It cost 31
# GraphQL points a call against a repository with three open pull requests —
# `gh` requests `commits(last: 100)` in each of the `--limit` slots and GitHub
# charges for nodes asked for, not returned — and that is how the fleet
# exhausted its hourly budget on 2026-08-12. The head sha now arrives as the
# scalar `headRefOid` for 1 point, and the head commit's date, which this
# computation needs and a sha alone does not give, comes from REST.
#
# `cutoff` is `now − stale-hours`; a PR is abandoned when its **last real
# activity** — not its raw `updatedAt` — is older than it.
cutoff='2026-07-24T09:00:00Z'
marker='<!-- agent-ops:pipeline-comment'
# shellcheck disable=SC2016  # the backtick in #94's fixture body is literal Markdown, not command substitution
prs='[
  {"number": 80, "isDraft": true,  "headRefName": "agent/td1-fix",
   "head_committed_at": "2026-07-24T03:00:00Z", "headRefOid": "a1", "reviews": [], "comments": []},
  {"number": 81, "isDraft": false, "headRefName": "agent/td2-fix",
   "head_committed_at": "2026-07-24T03:00:00Z", "headRefOid": "a2", "reviews": [], "comments": []},
  {"number": 82, "isDraft": true,  "headRefName": "agent/td3-fix",
   "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "a3", "reviews": [],
   "comments": [{"createdAt": "2026-07-24T11:00:00Z", "body": "still working on this"}]},
  {"number": 83, "isDraft": true,  "headRefName": "feature/a-humans-branch",
   "head_committed_at": "2026-07-24T03:00:00Z", "headRefOid": "a4", "reviews": [], "comments": []},
  {"number": 84, "isDraft": true,  "headRefName": "td/TD26072001",
   "head_committed_at": "2026-07-24T01:00:00Z", "headRefOid": "a5", "reviews": [], "comments": []},
  {"number": 85, "isDraft": true,  "headRefName": "agent/label-edit-only",
   "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "a6", "reviews": [], "comments": []},
  {"number": 86, "isDraft": true,  "headRefName": "agent/marker-comment-only",
   "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "a7", "reviews": [],
   "comments": [{"createdAt": "2026-07-28T21:00:00Z",
                 "body": "Autonomous agent (implementor) stopped on this PR: … <!-- agent-ops:pipeline-comment cycle=20260728T210000Z-node-1-99 -->"}]},
  {"number": 87, "isDraft": true,  "headRefName": "agent/human-comment-recent",
   "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "a8", "reviews": [],
   "comments": [{"createdAt": "2026-07-28T21:00:00Z", "body": "any update on this?"}]},
  {"number": 88, "isDraft": true,  "headRefName": "agent/human-review-recent",
   "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "a9",
   "reviews": [{"submittedAt": "2026-07-28T21:00:00Z"}], "comments": []},
  {"number": 89, "isDraft": true,  "headRefName": "agent/marker-review-only",
   "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "b1",
   "reviews": [{"submittedAt": "2026-07-28T21:00:00Z",
                "body": "Flagging a design choice for the human reviewer. <!-- agent-ops:pipeline-comment cycle=20260728T210000Z-node-1-99 -->"}],
   "comments": []},
  {"number": 94, "isDraft": true,  "headRefName": "agent/marker-comment-with-actor",
   "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "b6", "reviews": [],
   "comments": [{"createdAt": "2026-07-28T21:00:00Z",
                 "body": "**Implementor** · autonomous pipeline · node `poetic-1`\n\nStopped on this PR: … <!-- agent-ops:pipeline-comment cycle=20260728T210000Z-node-1-99 actor=implementor -->"}]}
]'

# gh's nested collections arrive capped at 100 items, unpaginated, and
# `comments` oldest-first — so a collection at exactly the cap may be missing
# the newest activity. These fixtures are appended with jq because writing a
# hundred rows out longhand would bury the point. Every date *visible* on
# #90–#91 is stale; the point is that at the cap what is visible cannot be
# trusted, so the PR must not be judged at all. #92 is the other way the same
# thing happens — a head commit whose date could not be read, which the
# gatherer leaves as a null `head_committed_at`. #93 is the boundary contrast:
# one under the cap, the data is complete, and judgement resumes.
prs="$(jq -c '
  . + [{"number": 90, "isDraft": true, "headRefName": "agent/comments-at-cap",
        "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "b2", "reviews": [],
        "comments": [range(100) | {"createdAt": "2026-07-20T01:00:00Z", "body": "old chatter"}]},
       {"number": 91, "isDraft": true, "headRefName": "agent/reviews-at-cap",
        "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "b3",
        "reviews": [range(100) | {"submittedAt": "2026-07-20T01:00:00Z", "body": "old review"}],
        "comments": []},
       {"number": 92, "isDraft": true, "headRefName": "agent/head-commit-unreadable",
        "head_committed_at": null, "headRefOid": "b4",
        "reviews": [], "comments": []},
       {"number": 93, "isDraft": true, "headRefName": "agent/comments-under-cap",
        "head_committed_at": "2026-07-20T00:00:00Z", "headRefOid": "b5", "reviews": [],
        "comments": [range(99) | {"createdAt": "2026-07-20T01:00:00Z", "body": "old chatter"}]}]' <<<"$prs")"

# Mirrors the computation in scripts/gather-abandoned-drafts.sh: the
# draft/branch filter first, then last-real-activity (the head commit's date,
# or a review or comment not carrying the marker) against the cutoff — unless
# either nested collection is at gh's 100-item cap or the head commit's date
# could not be read, in which case activity is uncomputable and the PR is
# excluded outright.
candidate_filter() {
  jq -c --arg cutoff "$cutoff" --arg marker "$marker" \
    '[.[] | select(.isDraft)
          | select((.headRefName | startswith("agent/"))
                   or (.headRefName | startswith("td/")))
          | (((((.reviews  // []) | length) >= 100)
              or (((.comments // []) | length) >= 100))) as $at_cap
          | (if $at_cap or .head_committed_at == null then null
             else (([ .head_committed_at ]
                    + [ (.reviews // [])[] | select((.body // "") | contains($marker) | not) | .submittedAt ]
                    + [ (.comments // [])[] | select((.body // "") | contains($marker) | not) | .createdAt ])
                   | max)
             end) as $activity
          | select($activity != null and $activity < $cutoff)
          | .number]' <<<"$prs"
}

assert_eq "only open, draft, ours-by-branch, actually-stale PRs are candidates" \
  "[80,84,85,86,89,94,93]" "$(candidate_filter)"

# Each exclusion, named, so a future edit that drops one fails loudly:
# - #81 ready: a ready PR is finished work waiting on the human. Finishing it is
#   review-feedback's job; force-pushing it would breach the Human Gate.
# - #82 a human's comment, after the cutoff: a draft still being worked, or one
#   a peer node just touched. Stealing it would force-push over live work. This
#   is the assertion that keeps the feature from cannibalising in-flight cycles.
# - #83 human branch: only branches under agent/ (or the tech-debt td/ claim
#   branch) are ours; the Human Gate reserves the rest.
# - #87 a human's comment resets the clock even though the last commit is old —
#   the direct contrast with #86, whose only recent write is marker-stamped.
# - #88 a review resets the clock too, same as any other real activity.
is_candidate() { candidate_filter | jq --argjson n "$1" 'index($n) != null'; }

assert_eq "a ready PR is never an abandoned-draft candidate" \
  "false" "$(is_candidate 81)"
assert_eq "a human's recent comment keeps a draft off the list — never steal live work" \
  "false" "$(is_candidate 82)"
assert_eq "a human's own branch is never ours to finish" \
  "0" "$(jq '[.[] | select(.number == 83) | select((.headRefName | startswith("agent/")) or (.headRefName | startswith("td/")))] | length' <<<"$prs")"
assert_eq "a tech-debt td/ claim branch counts as ours" \
  "1" "$(jq '[.[] | select(.number == 84) | select(.headRefName | startswith("td/"))] | length' <<<"$prs")"
assert_eq "a human's recent comment resets the clock even over an old commit" \
  "false" "$(is_candidate 87)"
assert_eq "a human review resets the clock" \
  "false" "$(is_candidate 88)"

# --- TD26072605: the pipeline's own writes must not reset the clock ---

# #85 has no comments or reviews at all — its raw `updatedAt` is irrelevant
# because this script never reads that field; a label edit (which moves
# `updatedAt` but appears in none of commits/reviews/comments) is discounted
# simply by not being a signal this computation looks at.
assert_eq "a PR touched only by a label edit is still judged solely on real activity" \
  "true" "$(is_candidate 85)"

# #86 carries a comment stamped with the pipeline's own marker, timestamped
# well after the cutoff — and it is still a candidate, because the marker
# excludes it from the activity computation entirely (not-at-all, per
# TD26072605's decision, not a partial reset).
assert_eq "a comment carrying the pipeline's own marker does not reset the clock" \
  "true" "$(is_candidate 86)"

# #87 is the same shape as #86 — an old commit, one comment after the cutoff —
# but its comment carries no marker, so it is a human's write and does reset
# the clock. The pair is the regression guard: change the marker string, or the
# `contains($marker)` filter, and one of these two flips.
assert_eq "an unmarked comment at the same timestamp as #86's marked one still resets the clock" \
  "true false" "$(is_candidate 86) $(is_candidate 87)"

# #94 carries the newer marker shape — `actor=implementor` added alongside
# `cycle=` — and #86 carries the older shape with no `actor=` field at all.
# Detection matches on PIPELINE_COMMENT_MARKER_PREFIX alone (never the full
# marker string), so both shapes must exclude their comment from the activity
# clock identically: a fresh field added to the marker must not stop an
# already-posted, older-shaped comment from being recognised as the
# pipeline's own.
assert_eq "the older cycle-only marker shape and the newer cycle+actor shape both keep the clock from resetting" \
  "true true" "$(is_candidate 86) $(is_candidate 94)"

# #89 is #86 posted the other way. `gh pr comment` files a note under
# `comments`; `gh pr review --comment` files the same words under `reviews`,
# and prompts/reviewer.md step 5 lets the Reviewer use either — so the marker
# has to be honoured in both collections or the pipeline goes on resetting its
# own clock through whichever one is unfiltered. #88 is the contrast: a human's
# review, no marker, and it still counts.
assert_eq "a review carrying the pipeline's own marker does not reset the clock either" \
  "true" "$(is_candidate 89)"
assert_eq "a marked review and an unmarked one at the same timestamp differ" \
  "true false" "$(is_candidate 89) $(is_candidate 88)"

# --- gh's nested-collection cap: at-cap data is missing data ---
#
# `gh pr list` caps `reviews` and `comments` at 100 items each, unpaginated,
# and `comments` arrives oldest-first — so on a PR past the cap the response
# holds the *oldest* writes and the newest are absent. Every date visible on
# #90–#92 is stale, and each would be a candidate if judged; the rule is that
# at the cap the PR is not judged at all, because a human's comment posted
# yesterday could be precisely the entry the cap cut off — and stealing that
# draft is the failure the script's header names as the one to avoid. The
# exclusion is deliberate and costs something real: a genuinely abandoned draft
# carrying 100 of anything waits for a human instead of being auto-finished.
# That is the safe direction.
#
# #92 is the same rule reached the other way. `commits` needed a cap check of
# its own while it was read, because at the cap `commits[-1]` was the hundredth
# commit rather than the head; `headRefOid` is the head at any branch length,
# so that clause is gone. What replaces it is the failure the REST head-commit
# fetch can have: an unreadable date, left as null. The guard is load-bearing —
# jq sorts null below every string, so without it #92's activity would be null,
# `null < $cutoff` would hold, and a draft a human pushed to minutes ago would
# be handed to an Implementor to force-push over.
assert_eq "comments at gh's 100-item cap: the newest may be missing, so the PR is never judged" \
  "false" "$(is_candidate 90)"
assert_eq "reviews at the cap are excluded the same way" \
  "false" "$(is_candidate 91)"
assert_eq "an unreadable head-commit date excludes the PR, never reads as maximally stale" \
  "false" "$(is_candidate 92)"
assert_eq "one under the cap, the data is complete and the draft is judged normally" \
  "true" "$(is_candidate 93)"

# --- One definition: the marker as every writer of it spells it ---
#
# `lib/pipeline-marker.sh` is the single definition (requirement 34a), and the
# reader — and agent-cycle.sh's and review-cycle.sh's own comments — source it.
# Five places cannot: the fixtures above, and the comment instructions in
# prompts/implementor.md, prompts/enabler.md, prompts/reviewer.md and
# prompts/refiner.md, which a model reads and types out. Change the prefix
# without changing those and the Implementor, Enabler and Reviewer go on
# stamping a marker the gatherer no longer recognises — the clock resets
# TD26072605 removed, back again, with every test still green. The Refiner
# comments on issues rather than pull requests, so nothing it writes reaches
# this gatherer at all; its copy is asserted here for the same one-definition
# reason, not for the draft clock. These assertions are what makes the
# one-definition claim hold for the copies that must be spelled out.
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
assert_eq "the fixtures above carry the marker prefix the library defines" \
  "$PIPELINE_COMMENT_MARKER_PREFIX" "$marker"
for prompt in implementor enabler reviewer refiner; do
  assert_eq "prompts/$prompt.md tells its stage to write that same prefix" "yes" \
    "$(grep -qF -- "$PIPELINE_COMMENT_MARKER_PREFIX" "$SCRIPT_DIR/prompts/$prompt.md" \
       && echo yes || echo no)"
done

# --- The ref: scoped to the head SHA ---
#
# `pr-<n>-abandoned-<head-sha[:12]>`, not `pr-<n>-abandoned`. An item recorded
# blocked (requirement 34) stays blocked until something clears it, so a bare
# `pr-80-abandoned` that an Implementor once failed on would still be blocked
# after fresh commits landed — and the new, possibly-finishable state would never
# be looked at again. Scoping to the head means each distinct abandoned state is
# its own item that no older block covers, while a draft re-abandoned at the same
# head keeps the same ref and stays blocked. Same reasoning as review-feedback's
# per-round refs.
ref_of() { jq -r '"pr-\(.number)-abandoned-\(.head_sha[0:12])"' <<<"$1"; }
assert_eq "the ref pins to the PR number and the head SHA's first 12 chars" \
  "pr-80-abandoned-1a2b3c4d5e6f" \
  "$(ref_of '{"number": 80, "head_sha": "1a2b3c4d5e6f7a8b9c0d"}')"
assert_eq "a new head after fresh commits yields a different ref, so an old block cannot cover it" \
  "pr-80-abandoned-ffffffffffff" \
  "$(ref_of '{"number": 80, "head_sha": "ffffffffffffaaaa1111"}')"

# --- Back-pressure narrowing (requirement 2.2a) ---
#
# When back-pressure trips, the cycle narrows to the three *finishing* sources
# rather than standing down, so a gate full of stalled work can still be cleared.
# Tested here rather than live because reaching the branch needs
# max_open_agent_prs exceeded *and* a finishing candidate waiting at the same
# moment — the exact state nobody wants to be discovering the behaviour of.
ordered='[
  {"slug": "o/one", "sources": ["security", "review-feedback", "abandoned-drafts", "tech-debt"], "review_feedback": [], "abandoned_drafts": [{"ref": "pr-80-abandoned-1a2b3c4d5e6f"}]},
  {"slug": "o/two", "sources": ["security", "review-feedback", "abandoned-drafts", "issues"], "review_feedback": [], "abandoned_drafts": []}
]'
restrict() { jq -c '[.[] | .sources = (.sources | map(select(. == "review-feedback" or . == "merge-conflicts" or . == "abandoned-drafts")))]' <<<"$ordered"; }

assert_eq "restriction leaves only the finishing sources present in this fixture selectable" \
  '["review-feedback","abandoned-drafts"] ["review-feedback","abandoned-drafts"]' \
  "$(restrict | jq -r '[.[] | (.sources | tojson)] | join(" ")')"
assert_eq "security and fresh sources are narrowed away — a full gate means finish, don't start" \
  "0" "$(restrict | jq '[.[].sources[] | select(. == "security" or . == "tech-debt" or . == "issues")] | length')"

# The count that decides stand-down vs restrict: all three finishing sources,
# across all repos.
assert_eq "finishing candidates count review-feedback, merge-conflicts AND abandoned-drafts across all repos" \
  "1" "$(jq '[.[].review_feedback[]?, .[].merge_conflicts[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"
assert_eq "with nothing waiting to finish, the count is 0 and the cycle stands down as before" \
  "0" "$(jq '[.[] | .review_feedback = [] | .merge_conflicts = [] | .abandoned_drafts = []] | [.[].review_feedback[]?, .[].merge_conflicts[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"

# --- The gatherer itself fails safe ---

assert_eq "an unknown repo yields [] and exit 0, never a broken cycle" "[]" \
  "$("$SCRIPT_DIR/scripts/gather-abandoned-drafts.sh" "Poetic-Poems/does-not-exist" autonomous-agent 'agent/' 3 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

# A non-numeric staleness threshold is a caller bug, not licence to treat every
# draft as abandoned: fail safe to [] rather than to "everything".
assert_eq "a garbage staleness threshold yields [] rather than every draft" "[]" \
  "$("$SCRIPT_DIR/scripts/gather-abandoned-drafts.sh" "Poetic-Poems/poetic" autonomous-agent 'agent/' "not-a-number" 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

# --- The argv cap (requirement 4g, TD-PPagop-26081406) ---
#
# $pr (the candidate build — a whole pull-request object including its body)
# and $cand (the per-candidate append) both used to ride into jq as
# --argjson: unbounded past this call, identical in shape to
# gather-review-feedback.sh's own two sites. Past MAX_ARG_STRLEN (131072
# bytes) the build died at execve; this repo's whole abandoned_drafts band
# came out empty. Requirement 4g moves both onto stdin. Each is inline, not a
# function, so each is lifted by its own literal start/end lines — the same
# technique test/pr-claim-exclusion.test.sh's `extract_claims_fold` uses.
extract_block() {  # extract_block <start-literal> <end-literal>
  awk -v s="$1" -v e="$2" \
    'index($0, s) == 1 { on = 1 } on { print } on && index($0, e) > 0 { exit }' \
    "$SCRIPT_DIR/scripts/gather-abandoned-drafts.sh"
}

# shellcheck disable=SC2016  # both single-quoted args are literal source text to match, not meant to expand
cand_block="$(extract_block '  cand="$(jq -nc' '  }')"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$cand_block" != *'input as $pr | {source: "abandoned-drafts"'* ]]; then
  printf 'FAIL - could not extract the candidate build from scripts/gather-abandoned-drafts.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi

oversized_pr_body="$(head -c 140000 < /dev/zero | tr '\0' 'x')"
assert_eq "the oversized PR-body fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( ${#oversized_pr_body} > 131072 ))"

run_cand_block() {  # run_cand_block <pr-json>
  # number/head_sha/item/slug are consumed only by the eval'd cand_block,
  # invisible to shellcheck.
  # shellcheck disable=SC2034
  ( pr="$1" number="300" head_sha="deadbeefcafe00112233" item="" slug="o/r"
    eval "$cand_block"; printf '%s' "$cand" )
}
pr_oversized="$(printf '{"number": 300, "url": "https://github.com/o/r/pull/300", "title": "t", "headRefName": "agent/td-oversized-fix", "body": "%s"}' "$oversized_pr_body")"
built_cand="$(run_cand_block "$pr_oversized")"
assert_eq "a PR object past the argv cap still produces the candidate" "1" \
  "$(jq -e 'type == "object"' <<<"$built_cand" >/dev/null 2>&1 && echo 1 || echo 0)"
# Bash string matching, not grep -F with the oversized string as an argument:
# that would hit the very argv cap this section exists to prove the real code
# no longer does.
built_cand_body="$(jq -r '.body // ""' <<<"$built_cand")"
assert_eq "  ... carrying the full oversized body, not truncated or dropped" \
  "1" "$([[ "$built_cand_body" == *"$oversized_pr_body"* ]] && echo 1 || echo 0)"
assert_eq "  ... and the ref pins to the PR number and head SHA" \
  "pr-300-abandoned-deadbeefcafe" "$(jq -r '.ref' <<<"$built_cand")"

# shellcheck disable=SC2016  # both single-quoted args are literal source text to match, not meant to expand
append_block="$(extract_block '  out="$(jq -nc '"'"'input as $arr | input as $c' '  })"')"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$append_block" != *'candidate dropped'* ]]; then
  printf 'FAIL - could not extract the array-assembly append from scripts/gather-abandoned-drafts.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
run_append_block() {  # run_append_block <out-json> <cand-json>
  # cand/slug/number/head_sha are consumed only by the eval'd append_block,
  # invisible to shellcheck.
  # shellcheck disable=SC2034
  ( out="$1" cand="$2" slug="o/r" number="301" head_sha="cafebabecafe00998877"
    eval "$append_block"; printf '%s' "$out" )
}
big_out="$(jq -nc '[range(1300) | {source: "abandoned-drafts", ref: ("pr-" + (. | tostring) + "-abandoned-fill"),
  body: ("pad " + ("x" * 100))}]')"
assert_eq "the oversized accumulator fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_out" | wc -c) > 131072 ))"
new_cand='{"source":"abandoned-drafts","ref":"pr-301-abandoned-cafebabecafe","body":"the newest one"}'
appended="$(run_append_block "$big_out" "$new_cand")"
assert_eq "an append onto an oversized accumulator keeps every prior candidate" \
  "1301" "$(jq 'length' <<<"$appended")"
assert_eq "  ... plus the new one just appended" "1" \
  "$(jq '[.[] | select(.ref == "pr-301-abandoned-cafebabecafe")] | length' <<<"$appended")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
