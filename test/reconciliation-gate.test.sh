#!/usr/bin/env bash
#
# test/reconciliation-gate.test.sh — regression test for
# lib/reconciliation-gate.sh (requirement 31c, agent-ops#533): the pipeline-
# side gate that refuses a draft-to-ready flip while a human's plain PR
# comment, posted since the pull request last left draft, carries no
# `<!-- agent-ops:reconciles comment=<id> -->` line answering it.
#
# `gh` is stubbed through RECONCILIATION_GATE_GH, the same convention
# test/closing-keyword-gate.test.sh's and test/review-gate.test.sh's stubs
# use.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/reconciliation-gate.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/reconciliation-gate.sh
. "$SCRIPT_DIR/lib/reconciliation-gate.sh"

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

URL="https://github.com/Poetic-Poems/agent-ops/pull/512"

# --- The stub gh --------------------------------------------------------------
# State lives in files:
#   $tmp_dir/timeline.json   the `api repos/.../issues/512/timeline` payload;
#                             "ERROR" makes the call fail.
#   $tmp_dir/pr.json         the `api repos/.../pulls/512` payload (createdAt
#                             fallback); "ERROR" makes the call fail.
#   $tmp_dir/comments.json   the `api repos/.../issues/512/comments` payload;
#                             "ERROR" makes the call fail.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
[[ "${1:-}" == "api" ]] || exit 1
shift
path="" filter="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) filter="$2"; shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) path="$1"; shift ;;
  esac
done
case "$path" in
  repos/*/issues/*/timeline)
    content="$(cat "$d/timeline.json" 2>/dev/null || echo '[]')"
    ;;
  repos/*/pulls/*)
    content="$(cat "$d/pr.json" 2>/dev/null || echo '{}')"
    ;;
  repos/*/issues/*/comments)
    content="$(cat "$d/comments.json" 2>/dev/null || echo '[]')"
    ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1 ;;
esac
[[ "$content" == "ERROR" ]] && { echo "could not read $path" >&2; exit 1; }
jq -rc "$filter" <<<"$content"
STUB
chmod +x "$tmp_dir/gh"
export RECONCILIATION_GATE_GH="$tmp_dir/gh"

set_timeline() { printf '%s' "$1" >"$tmp_dir/timeline.json"; }
set_pr() { printf '%s' "$1" >"$tmp_dir/pr.json"; }
set_comments() { printf '%s' "$1" >"$tmp_dir/comments.json"; }

# The stub's --jq applies the real filter to a JSON *array* one document at a
# time (mimicking --paginate streaming), so the fixtures below are arrays and
# the gate's own `--jq '.[] | ...'` filters run against them for real.

# --- clean: no human comments at all since the anchor -------------------------

set_timeline '[{"event": "ready_for_review", "created_at": "2026-08-16T20:00:00Z"}]'
set_comments '[]'
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "no comments since the anchor: clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# --- clean: comments exist, but all are the pipeline's own --------------------

set_comments "$(jq -nc --arg m "$PIPELINE_COMMENT_MARKER_PREFIX" '
  [{id: 1, created_at: "2026-08-16T21:00:00Z",
    body: ("**Reviewer** · autonomous pipeline · node `n1`\n\nNothing to report.\n\n" + $m + " cycle=X actor=reviewer -->"),
    user: {login: "warwickallen", type: "User"}}]')"
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "only marked pipeline comments since the anchor: clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# --- clean: comments exist, but only from bots ---------------------------------

set_comments '[{"id": 2, "created_at": "2026-08-16T21:05:00Z", "body": "LGTM",
                "user": {"login": "copilot-pull-request-reviewer[bot]", "type": "Bot"}}]'
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "only a bot comment since the anchor: clean" "clean" "$out"

# --- the regression itself: an unreconciled human comment is dirty -------------
# PR #512: the human requested three changes in a plain comment and flipped
# the PR to draft; the next Reviewer round answered one and never cited the
# other two.

set_comments '[{"id": 4718691960, "created_at": "2026-08-16T22:16:00Z",
                "body": "Three things: widen the protected-path list, rescope TD-PPagop-26081701, and re-read the kill switch.",
                "user": {"login": "warwickallen", "type": "User"}}]'
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "an unreconciled human comment is dirty" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the unreconciled comment by permalink, not by count" \
  "$URL#issuecomment-4718691960" "$out"
assert_contains "  ... naming the anchor it was measured since" "2026-08-16T20:00:00Z" "$out"

# --- a GitHub App's comment is not a human's ----------------------------------
# `performed_via_github_app` catches an App that posts under an ordinary user
# identity, which the `.user.type`/`[bot]`-suffix pair above does not.

set_comments '[{"id": 3, "created_at": "2026-08-16T21:06:00Z", "body": "Preview deployed.",
                "user": {"login": "vercel-deploy", "type": "User"},
                "performed_via_github_app": {"slug": "vercel"}}]'
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "a comment performed via a GitHub App is not a human's: clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# --- reconciled: a pipeline comment since cites the human comment's id --------

set_comments "$(jq -nc --arg m "$PIPELINE_COMMENT_MARKER_PREFIX" '
  [{id: 4718691960, created_at: "2026-08-16T22:16:00Z",
    body: "Three things: widen the protected-path list, rescope TD-PPagop-26081701, and re-read the kill switch.",
    user: {login: "warwickallen", type: "User"}},
   {id: 5, created_at: "2026-08-17T04:31:00Z",
    body: ("**Reviewer** · autonomous pipeline · node `n1`\n\nAnswered every point.\n\n<!-- agent-ops:reconciles comment=4718691960 -->\n\n" + $m + " cycle=X actor=reviewer -->"),
    user: {login: "warwickallen", type: "User"}}]')"
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "a cited human comment is clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# --- partially reconciled: two human comments, only one cited -----------------

set_comments "$(jq -nc --arg m "$PIPELINE_COMMENT_MARKER_PREFIX" '
  [{id: 10, created_at: "2026-08-16T22:16:00Z", body: "Widen the protected-path list.",
    user: {login: "warwickallen", type: "User"}},
   {id: 11, created_at: "2026-08-16T22:17:00Z", body: "Also rescope the tech-debt record.",
    user: {login: "warwickallen", type: "User"}},
   {id: 12, created_at: "2026-08-17T04:31:00Z",
    body: ("Reviewer note.\n\n<!-- agent-ops:reconciles comment=10 -->\n\n" + $m + " cycle=X actor=reviewer -->"),
    user: {login: "warwickallen", type: "User"}}]')"
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "one of two human comments still uncited is dirty" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming only the uncited one" "$URL#issuecomment-11" "$out"
[[ "$out" == *"#issuecomment-10"* ]] && printf 'FAIL - the cited comment leaked into the dirty reason\n     actual: %s\n' "$out" && failures=$(( failures + 1 ))

# --- the anchor: only comments after the pull request last left draft count ---

set_timeline '[{"event": "ready_for_review", "created_at": "2026-08-10T00:00:00Z"},
               {"event": "ready_for_review", "created_at": "2026-08-16T20:00:00Z"}]'
set_comments '[{"id": 20, "created_at": "2026-08-12T00:00:00Z",
                 "body": "An old comment from before the pull request last left draft.",
                 "user": {"login": "warwickallen", "type": "User"}}]'
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "a human comment before the most recent ready_for_review event: clean" "clean" "$out"
assert_eq "  ... the most recent ready_for_review event wins over an earlier one" "0" "$rc"

# --- no ready_for_review event at all: falls back to the pull request's own
#     creation time (a first round) ---------------------------------------------

set_timeline '[]'
set_pr '{"created_at": "2026-08-15T00:00:00Z"}'
set_comments '[{"id": 30, "created_at": "2026-08-15T12:00:00Z",
                "body": "A first-round comment.", "user": {"login": "warwickallen", "type": "User"}}]'
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "no ready_for_review event: falls back to creation time, still dirty if unreconciled" \
  "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the creation-time anchor" "2026-08-15T00:00:00Z" "$out"

# --- NOT_AFTER: the Reviewer's own step-7 flip must not become the anchor ------
#
# The real ordering on PR #512, which every case above quietly avoids by
# hand-crafting a timeline whose newest `ready_for_review` already predates
# the human's comment. In production it does not: `prompts/reviewer.md` step 7
# has the Reviewer run `gh pr ready` inside its own session, and the gate runs
# afterwards from `handoff_complete_review`. So the newest `ready_for_review`
# event is the Reviewer's own flip, and every comment the round was meant to
# answer necessarily predates it. Unbounded, the gate reports `clean` on
# exactly the pull request it exists to refuse.

set_timeline '[{"event": "ready_for_review", "created_at": "2026-08-16T22:05:40Z"},
               {"event": "convert_to_draft",  "created_at": "2026-08-16T22:16:30Z"},
               {"event": "ready_for_review", "created_at": "2026-08-17T04:31:16Z"}]'
set_pr '{"created_at": "2026-08-16T10:00:00Z"}'
set_comments "$(jq -nc --arg m "$PIPELINE_COMMENT_MARKER_PREFIX" '
  [{id: 5309946033, created_at: "2026-08-16T22:16:05Z",
    body: "Three things: widen the protected-path list, rescope TD-PPagop-26081701, and re-read the kill switch.",
    user: {login: "warwickallen", type: "User"}},
   {id: 5309999999, created_at: "2026-08-17T04:31:39Z",
    body: ("**Reviewer** · autonomous pipeline · node `n1`\n\nAutomated review complete.\n\n" + $m + " cycle=X actor=reviewer -->"),
    user: {login: "warwickallen", type: "User"}}]')"

out="$(reconciliation_gate "$URL" "2026-08-17T04:00:00Z")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "bounded by the round's start, the Reviewer's own flip is not the anchor" \
  "dirty" "${out%%$'\t'*}"
assert_contains "  ... so PR #512's standing change request is still named" \
  "$URL#issuecomment-5309946033" "$out"
# The fixture's own `convert_to_draft` at 22:16:30Z (the human's own
# draft-flip, part of PR #512's real ordering) is itself at or before this
# round's bound, and it follows the 22:05:40Z `ready_for_review` — so
# agent-ops#539's fix (below) excludes that event too, same as it would a
# revert `confirm_pr_draft` performs, and the anchor falls all the way back
# to the pull request's own creation time. The point being pinned here is
# unchanged: whichever anchor value it lands on, it is on the far side of the
# human's comment, so the comment is still named.
assert_contains "  ... measured since the pull request's own creation time, its last surviving anchor" \
  "2026-08-16T10:00:00Z" "$out"

out="$(reconciliation_gate "$URL")"
assert_eq "  ... and unbounded it would have missed it entirely — why the bound is not optional" \
  "clean" "$out"

# --- agent-ops#539: a refused, reverted flip must not become next round's
#     anchor either — the two-round regression the Approver's review named ---
#
# NOT_AFTER alone (agent-ops#533, above) stops the gate being fooled by the
# Reviewer's own flip *within* the round that made it. It does not stop the
# gate being fooled by that same flip *one round later*, once it has been
# refused and reverted: `handoff_complete_review` now performs that revert on
# a `dirty` verdict (`confirm_pr_draft`, agent-ops#539), but GitHub does not
# delete the original `ready_for_review` event, so — without also excluding a
# `ready_for_review` that a `convert_to_draft` later undid — that stale event
# is again the most recent `ready_for_review` at or before the next round's
# bound, and the still-unreconciled human comment reads as answered.
#
# This is the Approver's own reproduction against PR #512's real timestamps,
# extended one round past where the review noted "nothing in the diff
# exercises two consecutive rounds": round one's `ready_for_review` at
# 04:31:16Z is the Reviewer's step-7 flip inside round one; round one's gate
# (bounded by round one's own start) finds the human's comment unreconciled
# and is `dirty`; `handoff_complete_review` reverts that flip
# (`confirm_pr_draft`), which GitHub records as a `convert_to_draft` event at
# 04:31:40Z — after round one's own bound, so it plays no part in round one's
# own verdict, but it is on the timeline for round two to see. Before this
# fix, round two's bound (05:31:00Z) still fell after the *reverted*
# 04:31:16Z flip, unbounded by anything that told the gate it had been
# undone, so that flip won the anchor and the same unreconciled comment
# disappeared. After this fix, round two's anchor falls back past both
# reverted flips to the pull request's own creation time, and the comment is
# named again.

set_timeline '[{"event": "ready_for_review",  "created_at": "2026-08-16T22:05:40Z"},
               {"event": "convert_to_draft",  "created_at": "2026-08-16T22:16:30Z"},
               {"event": "ready_for_review",  "created_at": "2026-08-17T04:31:16Z"},
               {"event": "convert_to_draft",  "created_at": "2026-08-17T04:31:40Z"}]'
set_pr '{"created_at": "2026-08-16T10:00:00Z"}'
set_comments "$(jq -nc --arg m "$PIPELINE_COMMENT_MARKER_PREFIX" '
  [{id: 5309946033, created_at: "2026-08-16T22:16:05Z",
    body: "Three things: widen the protected-path list, rescope TD-PPagop-26081701, and re-read the kill switch.",
    user: {login: "warwickallen", type: "User"}},
   {id: 5309999999, created_at: "2026-08-17T04:31:39Z",
    body: ("**Reviewer** · autonomous pipeline · node `n1`\n\nAutomated review complete.\n\n" + $m + " cycle=X actor=reviewer -->"),
    user: {login: "warwickallen", type: "User"}}]')"

# Round one: bounded by its own start, before its own flip and before the
# revert that follows it inside the same round. Still dirty, same as the
# single-round case above.
out="$(reconciliation_gate "$URL" "2026-08-17T04:00:00Z")"; rc=$?
assert_eq "round one: exits 1" "1" "$rc"
assert_eq "round one is dirty — the human comment is still unreconciled" \
  "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the comment PR #512 never answered" \
  "$URL#issuecomment-5309946033" "$out"

# Round two: bounded past both the Reviewer's flip and the revert it earned.
# This is the case the Approver's review found nothing in the diff exercised
# — the regression is `clean` here, not `dirty`, before this fix.
out="$(reconciliation_gate "$URL" "2026-08-17T05:31:00Z")"; rc=$?
assert_eq "round two: exits 1" "1" "$rc"
assert_eq "round two stays dirty — the reverted flip is not a new anchor" \
  "dirty" "${out%%$'\t'*}"
assert_contains "  ... still naming the same unanswered comment one round later" \
  "$URL#issuecomment-5309946033" "$out"
assert_contains "  ... measured since the pull request's own creation time, past both reverted flips" \
  "2026-08-16T10:00:00Z" "$out"

# --- NOT_AFTER on a first round: no ready_for_review event precedes the bound --
# The same trap one layer down: the Reviewer's flip is also the *first*
# `ready_for_review` event on a never-yet-ready draft, so an unbounded read
# stops falling back to the creation time at the same moment.

set_timeline '[{"event": "ready_for_review", "created_at": "2026-08-17T04:31:16Z"}]'
set_pr '{"created_at": "2026-08-16T10:00:00Z"}'
set_comments '[{"id": 40, "created_at": "2026-08-16T18:00:00Z",
                "body": "Please rescope this before it goes ready.",
                "user": {"login": "warwickallen", "type": "User"}}]'
out="$(reconciliation_gate "$URL" "2026-08-17T04:00:00Z")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "no ready_for_review event at or before the bound: creation time is the anchor" \
  "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the creation-time anchor, not the in-round flip" \
  "2026-08-16T10:00:00Z" "$out"

# --- NOT_AFTER changes nothing where no flip happened inside the round --------
# The `review-feedback` and Enabler `complete_handoff` paths: the newest
# `ready_for_review` event already predates the bound, so the bounded and
# unbounded reads must agree.

set_timeline '[{"event": "ready_for_review", "created_at": "2026-08-16T20:00:00Z"}]'
set_comments '[{"id": 41, "created_at": "2026-08-16T22:00:00Z", "body": "One more thing.",
                "user": {"login": "warwickallen", "type": "User"}}]'
bounded="$(reconciliation_gate "$URL" "2026-08-17T04:00:00Z")"
unbounded="$(reconciliation_gate "$URL")"
assert_eq "a bound later than every ready_for_review event selects the same anchor" \
  "$unbounded" "$bounded"
assert_contains "  ... and that anchor is still the most recent such event" \
  "2026-08-16T20:00:00Z" "$bounded"

# --- unreadable timeline: unknown, not dirty -----------------------------------

set_timeline 'ERROR'
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "an unreadable timeline is unknown, not dirty" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0, so a caller warns rather than blocks" "0" "$rc"

# --- no ready_for_review event and no readable creation time: unknown ---------

set_timeline '[]'
set_pr 'ERROR'
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "no anchor at all is unknown, not dirty" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0" "0" "$rc"

# --- unreadable comments: unknown ----------------------------------------------

set_timeline '[{"event": "ready_for_review", "created_at": "2026-08-16T20:00:00Z"}]'
set_comments 'ERROR'
out="$(reconciliation_gate "$URL")"; rc=$?
assert_eq "unreadable comments: unknown, not dirty" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0" "0" "$rc"

# --- an empty URL is dirty, not a crash ----------------------------------------

out="$(reconciliation_gate "")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "no URL at all is dirty" "dirty" "${out%%$'\t'*}"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
