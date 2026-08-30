#!/usr/bin/env bash
#
# test/sweep-human-visibility.test.sh — regression test for
# scripts/sweep-human-visibility.sh (requirement 38, agent-ops#242).
#
# The script is the periodic half of the human-visibility guarantee: for
# every open, ready pull request this system raised, whichever review request
# `lib/handoff.sh` would ensure at the moment of handoff (requirement 38a) is
# re-ensured here too, on a cycle that never touches that pull request through
# any stage — a CHANGES_REQUESTED pull request whose round the Implementer has
# already answered gets requirement 31b's re-request repeated too (the
# self-heal, tech-debt/TD-PPagop-26080804.md) — and an approved, mergeable,
# green pull request idle past `human_nudge_idle_hours` gets one nudge comment
# (requirement 38c), never a second one for the same approval.
#
# `gh` is stubbed through SWEEP_GH; the underlying `lib/handoff.sh` functions
# have their own dedicated regression test (test/handoff.test.sh) and are
# exercised only for the call shapes this script's own control flow depends
# on — not re-proven here.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/sweep-human-visibility.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$SCRIPT_DIR/scripts/sweep-human-visibility.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

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

# --- The config the sweep reads --------------------------------------------------
config="$tmp_dir/config.json"
write_config() {  # <enabler_assignee> <human_nudge_idle_hours> [<merge_queue_dequeue_notice_max_age_hours>]
  if [[ -n "${3:-}" ]]; then
    jq -n --arg a "$1" --argjson h "$2" --argjson d "$3" \
      '{pr_label: "autonomous-agent", enabler_assignee: $a, human_nudge_idle_hours: $h,
        merge_queue_dequeue_notice_max_age_hours: $d}' \
      > "$config"
  else
    jq -n --arg a "$1" --argjson h "$2" \
      '{pr_label: "autonomous-agent", enabler_assignee: $a, human_nudge_idle_hours: $h}' \
      > "$config"
  fi
}
write_config warwickallen 24

URL="https://github.com/o/r/pull/1"

# --- The stub gh -------------------------------------------------------------
# State lives in files, the same shapes test/handoff.test.sh's stubs use, so a
# gh call the underlying lib/handoff.sh functions make is served identically.
#   $tmp_dir/prlist.json  the `gh pr list` payload, already the shape the real
#                          `--jq` filter would leave: a bare array of URLs
#   $tmp_dir/list-fail    present -> `pr list` fails
#   $tmp_dir/draft        "true" | "false" — the draft flag `pr view` reports
#   $tmp_dir/reviews      the reviews array, verbatim JSON (raw GitHub shape:
#                          user.login, user.type, state, submitted_at, body)
#   $tmp_dir/issue-comments.json  the PR's general (issue) comments, verbatim
#                          JSON: an array of {created_at, body}
#   $tmp_dir/pending      the requested_reviewers logins, one per line
#   $tmp_dir/author       the pull request author's login
#   $tmp_dir/post-fail    present -> the POST changes nothing
#   $tmp_dir/api-fail     the path fragment whose GET should fail, if any
#   $tmp_dir/idle-view.json  the payload for the script's own idle-check
#                             `pr view --json reviewDecision,...` (no --jq)
#   $tmp_dir/view-fail    present -> that idle-check view fails
#   $tmp_dir/comment-fail present -> `pr comment` fails
#   $tmp_dir/posts        one line per POST
#   $tmp_dir/comments.log one paragraph per posted comment body
#   $tmp_dir/pages        how many pages `--paginate` splits a listing over
#                          (default 1) — each emitted as its own document
#
# `/reviews` and `/issues/…/comments` GET calls apply the *real* `--jq`
# filter the caller passed to the raw fixture, rather than a filter of the
# stub's own — `_handoff_blocking_reviewers` (login/bot/state) and
# `_sweep_round_answered` (state/at/who/body) both read `/reviews`, with
# different shapes, and only running each caller's own filter serves both
# correctly from one fixture.
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"

if [[ "$1 $2" == "pr list" ]]; then
  [[ -f "$d/list-fail" ]] && exit 1
  jq -r '.[]' "$d/prlist.json"
  exit 0
fi

if [[ "$1 $2" == "pr view" ]]; then
  if [[ "$*" == *"isDraft"* ]]; then
    cat "$d/draft"
    exit 0
  fi
  [[ -f "$d/view-fail" ]] && exit 1
  cat "$d/idle-view.json"
  exit 0
fi

if [[ "$1 $2" == "pr comment" ]]; then
  [[ -f "$d/comment-fail" ]] && exit 1
  body=""
  shift 2
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body" ]]; then body="$2"; shift 2; else shift; fi
  done
  printf '%s\n===\n' "$body" >> "$d/comments.log"
  exit 0
fi

if [[ "$1 $2" == "api -X" ]]; then
  printf '%s\n' "$*" >> "$d/posts"
  if [[ ! -f "$d/post-fail" ]]; then
    for a in "$@"; do
      [[ "$a" == reviewers\[\]=* ]] && printf '%s\n' "${a#reviewers[]=}" >> "$d/pending"
    done
    sort -u -o "$d/pending" "$d/pending"
  fi
  exit 0
fi

if [[ "$1 $2" == "api graphql" ]]; then
  [[ -f "$d/mq-fail" ]] && exit 1
  jqfilter="" prev=""
  for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqfilter="$a"
    prev="$a"
  done
  jq -c "$jqfilter" "$d/mq-response.json" 2>/dev/null
  exit 0
fi

path="$2"
fail="$(cat "$d/api-fail" 2>/dev/null || true)"
if [[ -n "$fail" && "$path" == *"$fail" ]]; then
  failmsg="$(cat "$d/api-fail-msg" 2>/dev/null || true)"
  [[ -n "$failmsg" ]] && printf '%s\n' "$failmsg" >&2
  exit 1
fi

jqfilter=""
prev=""
for a in "$@"; do
  [[ "$prev" == "--jq" ]] && jqfilter="$a"
  prev="$a"
done

# `--paginate` emits the filter's result once per page, as separate documents;
# `pages` makes the stub do that so a caller that wraps an aggregate inside
# `--jq` is caught here rather than in production past thirty items.
pages="$(cat "$d/pages" 2>/dev/null || printf 1)"

if [[ "$path" == */reviews ]]; then
  for (( p = 0; p < pages; p++ )); do jq -c "$jqfilter" "$d/reviews"; done
elif [[ "$path" == */comments ]]; then
  for (( p = 0; p < pages; p++ )); do jq -c "$jqfilter" "$d/issue-comments.json"; done
elif [[ "$*" == *"user.login"* ]]; then
  cat "$d/author"
else
  while IFS= read -r l; do [[ -n "$l" ]] && printf '%s\n' "$l"; done < "$d/pending"
fi
STUB
chmod +x "$tmp_dir/gh"

review_n=0
review() {  # <login> <state> [type] [body]
  jq -cn --arg login "$1" --arg type "${3:-User}" --arg state "$2" \
      --arg at "$(printf '2026-08-03T10:%02d:00Z' "$(( ++review_n ))")" --arg body "${4:-}" \
    '{user: {login: $login, type: $type}, state: $state, submitted_at: $at, body: $body}'
}
set_reviews() {
  review_n=0
  local IFS=,
  printf '[%s]' "$*" > "$tmp_dir/reviews"
}

# issue_comment AT BODY — a general PR comment (`gh pr comment`), the shape
# the Implementer's marked reply lands as (issue #, not review #).
issue_comment() {
  jq -cn --arg at "$1" --arg body "$2" '{created_at: $at, body: $body}'
}
set_issue_comments() {
  local IFS=,
  printf '[%s]' "$*" > "$tmp_dir/issue-comments.json"
}

comments() { cat "$tmp_dir/comments.log" 2>/dev/null || true; }
comment_count() {
  [[ -s "$tmp_dir/comments.log" ]] || { printf '0'; return; }
  grep -c '^===$' "$tmp_dir/comments.log"
}

# idle_view REVIEW_DECISION MERGEABLE CI_GREEN APPROVED_AT ALREADY_NUDGED
#   [ALREADY_DEQUEUE_NOTIFIED_AT] [MERGE_STATE_STATUS]
#
# MERGE_STATE_STATUS defaults to `CLEAN` — the state every target repository's
# approved, green, up-to-date pull request actually reads, including on
# agent-ops, whose ruleset requires zero approving reviews. `BLOCKED` is the
# one value the nudge must refuse: `mergeable` alone reports merge-*conflict*
# state, so a base branch still short of a second required approval is
# `MERGEABLE` and `BLOCKED` together, and `_handoff_pr_approved` — true on the
# first standing approval — cannot see the shortfall on its own.
#
# ALREADY_NUDGED accepts:
#   yes             a genuine, pipeline-authored nudge comment (actor=script,
#                   the real shape scripts/sweep-human-visibility.sh posts)
#   reviewer-actor  the same genuine shape, but authored under a different
#                   pipeline actor — agent-ops#390 acceptance 3: recognition
#                   must not be hardcoded to actor=script
#   quoted-no-stamp the exact `<!-- agent-ops:human-nudge -->` string, quoted
#                   by a write that carries no pipeline marker at all — must
#                   never suppress a nudge (agent-ops#390 fault #1)
#   mentioned       a pipeline-authored comment (carries the marker prefix)
#                   that only discusses the mechanism in prose, without the
#                   exact HTML-comment form — the poetic-fiddle-style false
#                   positive agent-ops#390 fault #1 describes; must never
#                   suppress a nudge
#   no              no nudge-related comment at all
idle_view() {
  local decision="$1" mergeable="$2" green="$3" at="$4" nudged="$5" dq_at="${6:-}"
  local merge_state="${7:-CLEAN}"
  local rollup='[]'
  [[ "$green" == "yes" ]] && rollup='[{"conclusion":"SUCCESS"}]'
  [[ "$green" == "mixed" ]] && rollup='[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"}]'
  # A `SKIPPED` `CheckRun` (a job gated off by a `paths:` filter or an `if:`,
  # as every target repository carries on every pull request) has no `.state`
  # field at all — `CheckRun` and `StatusContext` are distinct GitHub shapes —
  # so this fixture omits it, the same as the real rollup would.
  [[ "$green" == "skipped" ]] && rollup='[{"conclusion":"SUCCESS"},{"conclusion":"SKIPPED"}]'
  [[ "$green" == "cancelled" ]] && rollup='[{"conclusion":"SUCCESS"},{"conclusion":"CANCELLED"}]'
  # A `CheckRun` still running reports `status`, not `conclusion` — GitHub
  # leaves `conclusion` null until the run completes.
  [[ "$green" == "in_progress" ]] && rollup='[{"conclusion":"SUCCESS"},{"status":"IN_PROGRESS","conclusion":null}]'
  local extra=() comments='[]'
  case "$nudged" in
    yes)
      extra+=("$(jq -cn --arg m "$(pipeline_comment_marker c1 script)" \
        '{body: ("reminder\n\n" + $m + "\n<!-- agent-ops:human-nudge -->")}')")
      ;;
    reviewer-actor)
      extra+=("$(jq -cn --arg m "$(pipeline_comment_marker c1 reviewer)" \
        '{body: ("reminder\n\n" + $m + "\n<!-- agent-ops:human-nudge -->")}')")
      ;;
    quoted-no-stamp)
      extra+=('{"body":"a bystander quoting the marker\n\n<!-- agent-ops:human-nudge -->"}')
      ;;
    mentioned)
      extra+=("$(jq -cn --arg m "$(pipeline_comment_marker c1 reviewer)" \
        '{body: ("Reviewed. This touches the agent-ops:human-nudge gate in sweep-human-visibility.sh.\n\n" + $m)}')")
      ;;
  esac
  if [[ -n "$dq_at" ]]; then
    extra+=("$(jq -cn --arg at "$dq_at" \
      '{body: ("already notified\n\n<!-- agent-ops:merge-queue-dequeued:" + $at + " -->")}')")
  fi
  (( ${#extra[@]} )) && comments="$(printf '%s\n' "${extra[@]}" | jq -s -c '.')"
  jq -n --arg d "$decision" --arg m "$mergeable" --argjson rollup "$rollup" \
    --arg at "$at" --argjson comments "$comments" --arg ms "$merge_state" \
    '{reviewDecision: $d, mergeable: $m, mergeStateStatus: $ms,
      statusCheckRollup: $rollup,
      reviews: (if $at == "" then [] else [{state: "APPROVED", submittedAt: $at}] end),
      comments: $comments}' > "$tmp_dir/idle-view.json"
}

# set_merge_queue QUEUED [DEQUEUED_AT] [REASON]
# The raw GraphQL-shaped fixture `merge_queue_probe`'s own `--jq` filter
# reads — the stub applies the caller's real filter, the same technique
# `/reviews` and `/issues/…/comments` above use.
set_merge_queue() {
  local queued="$1" at="${2:-}" reason="${3:-}" nodes='[]'
  if [[ -n "$at" ]]; then
    nodes="$(jq -cn --arg at "$at" --arg r "$reason" '[{createdAt: $at, reason: $r}]')"
  fi
  jq -n --argjson q "$queued" --argjson nodes "$nodes" \
    '{data: {repository: {pullRequest: {isInMergeQueue: $q, timelineItems: {nodes: $nodes}}}}}' \
    > "$tmp_dir/mq-response.json"
}

reset_stub() {
  printf '["%s"]\n' "$URL" > "$tmp_dir/prlist.json"
  printf 'false' > "$tmp_dir/draft"
  printf 'warwickallen\n' > "$tmp_dir/author"
  printf '[]' > "$tmp_dir/issue-comments.json"
  : > "$tmp_dir/pending"; : > "$tmp_dir/posts"; : > "$tmp_dir/comments.log"
  rm -f "$tmp_dir/api-fail" "$tmp_dir/api-fail-msg" "$tmp_dir/post-fail" "$tmp_dir/list-fail" \
        "$tmp_dir/view-fail" "$tmp_dir/comment-fail" "$tmp_dir/pages" "$tmp_dir/mq-fail"
  set_merge_queue false
  idle_view "" "" "" "" no
}

run_sweep() {
  SWEEP_GH="$tmp_dir/gh" AGENT_OPS_CONFIG="$config" bash "$SWEEP" o/r c1 node1
}

# --- No pull requests: costs one listing and nothing else -----------------------
write_config warwickallen 24
reset_stub
printf '[]\n' > "$tmp_dir/prlist.json"
out="$(run_sweep)"
assert_eq "no open pull requests produces no actions" "" "$out"

# --- enabler_assignee unset: the same silent no-op an Enabler disabled is -------
write_config "" 24
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
out="$(run_sweep)"
assert_eq "no enabler_assignee means nothing to request or nudge" "" "$out"
write_config warwickallen 24

# --- No legal review-request candidate: a warning, not silence ------------------
# The one `skip` reason nothing else will ever ask about again (tech-debt/
# TD-PPagop-26081001.md): `enabler_assignee` is also the pull request's own
# author (`reset_stub`'s default) and nobody else has ever reviewed it, so
# `ensure_human_reviewer` returns its distinguishable `skip\tno-candidate`
# rather than the bare `skip` a blocked pull request gets (the sweep's own
# listing already excludes drafts) — and that is the one `skip` reason this
# sweep itself surfaces as a `warning`, unlike a still-blocked pull request
# (see below), which produces no action at all.
reset_stub
set_reviews
out="$(run_sweep)"
assert_eq "no legal candidate is a warning" "warning" "$(jq -r '.action' <<<"$out")"
assert_contains "  ... naming the pull request" "$URL" "$(jq -r '.pr_url' <<<"$out")"
assert_contains "  ... naming the assignee that could not be used" \
  "enabler_assignee=warwickallen" "$(jq -r '.detail' <<<"$out")"
assert_eq "  ... having asked GitHub nothing" "" "$(cat "$tmp_dir/posts")"

# --- Still CHANGES_REQUESTED-blocked, unanswered: left entirely alone -----------
# The self-heal (see the script's design note; tech-debt/TD-PPagop-26080804.md)
# only fires on an *answered* round. With no marked Implementer reply at all —
# the ordinary case, a human still waiting on the pipeline — nothing is
# requested and nothing is nudged: the blocked PR's next actor is the
# pipeline, not the human.
reset_stub
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
idle_view CHANGES_REQUESTED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a still-blocked, unanswered PR is left entirely alone" "" "$out"
assert_eq "  ... no review request POSTed" "" "$(cat "$tmp_dir/posts")"
assert_eq "  ... no nudge comment posted" "0" "$(comment_count)"

# --- Self-heal: an answered CHANGES_REQUESTED round is re-requested -------------
# Requirement 31b's re-request, repeated here for the round the Reviewer's own
# handoff lost to a crash. Only a marked reply from the Implementer turns this
# on — never a review-requested event, since this call's own request would
# otherwise read back next cycle as an answer to itself (the queue-inversion
# and silent-starvation failures the script's design note explains).
implementer_reply="$(printf 'Addressed the review.\n\n%s cycle=X actor=implementer -->' "$PIPELINE_COMMENT_MARKER_PREFIX")"

reset_stub
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
set_issue_comments "$(issue_comment "2026-08-03T10:05:00Z" "$implementer_reply")"
idle_view CHANGES_REQUESTED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an answered CHANGES_REQUESTED round is re-requested" "human-review-requested" \
  "$(jq -r '.action' <<<"$out")"
assert_eq "  ... naming the blocking reviewer" "Warwick-Allen" \
  "$(jq -r '.reviewers[0]' <<<"$out")"
assert_contains "  ... POSTed the re-request" "reviewers[]=Warwick-Allen" "$(cat "$tmp_dir/posts")"
assert_eq "  ... and never nudges a still-CHANGES_REQUESTED pull request" "0" "$(comment_count)"

# A reply that predates the blocking review answered a *previous* round, not
# this one, and must not self-heal it.
reset_stub
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
set_issue_comments "$(issue_comment "2020-01-01T00:00:00Z" "$implementer_reply")"
idle_view CHANGES_REQUESTED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a reply predating the blocking review does not self-heal" "" "$out"

# An unmarked comment — a human chiming in, or an unrelated bot — never counts.
reset_stub
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
set_issue_comments "$(issue_comment "2026-08-03T10:05:00Z" "looks close")"
idle_view CHANGES_REQUESTED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an unmarked comment does not self-heal" "" "$out"

# --- Self-heal: the green gate (agent-ops#338) --------------------------------
# The self-heal replays only half of the Reviewer's own `ready` verdict, which
# never fires without requirement 31c's green precondition — so an answered
# round on a not-green pull request must stay a silent no-op, never a guessed
# request, and the gate must short-circuit before `_sweep_round_answered` is
# even asked (no `/reviews`/`/comments` read, hence no warning either).
reset_stub
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
set_issue_comments "$(issue_comment "2026-08-03T10:05:00Z" "$implementer_reply")"
idle_view CHANGES_REQUESTED MERGEABLE mixed "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an answered round on a red (mixed) rollup makes no request" "" "$out"
assert_eq "  ... and posts nothing" "" "$(cat "$tmp_dir/posts")"

reset_stub
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
set_issue_comments "$(issue_comment "2026-08-03T10:05:00Z" "$implementer_reply")"
idle_view CHANGES_REQUESTED MERGEABLE "" "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an answered round on an empty (not-yet-run) rollup makes no request" "" "$out"
assert_eq "  ... and posts nothing" "" "$(cat "$tmp_dir/posts")"

# A SKIPPED CheckRun alongside SUCCESS is not a failure for the self-heal
# either — it shares `_sweep_checks_green` with the idle nudge rather than a
# stricter copy of it.
reset_stub
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
set_issue_comments "$(issue_comment "2026-08-03T10:05:00Z" "$implementer_reply")"
idle_view CHANGES_REQUESTED MERGEABLE skipped "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an answered round on a rollup whose only non-SUCCESS entry is SKIPPED still self-heals" \
  "human-review-requested" "$(jq -r '.action' <<<"$out")"

# --- Self-heal: an unreadable round is a warning, never a guessed request -------
reset_stub
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
printf '/comments' > "$tmp_dir/api-fail"
idle_view CHANGES_REQUESTED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an unreadable round is a warning" "warning" "$(jq -r '.action' <<<"$out")"
assert_contains "  ... naming the pull request" "$URL" "$(jq -r '.pr_url' <<<"$out")"
assert_eq "  ... and posts nothing" "" "$(cat "$tmp_dir/posts")"

# --- Self-heal: the reads survive a paginated listing ---------------------------
# `gh api --paginate` emits the `--jq` filter's result once per page, as
# separate documents — so an aggregate written inside the filter is computed
# per page and disagrees with itself past the endpoint's thirty-item default
# (the hazard `_handoff_blocking_reviewers` documents in lib/handoff.sh). Both
# of `_sweep_round_answered`'s reads therefore stream one object per line and
# slurp afterwards. Getting this wrong fails *open*: two documents pass a
# `type == "array"` check and then break the extraction, and an extraction
# that cannot run must never reach the branch that re-requests a human.
reset_stub
printf '2' > "$tmp_dir/pages"
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
set_issue_comments "$(issue_comment "2026-08-03T10:05:00Z" "$implementer_reply")"
idle_view CHANGES_REQUESTED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a paginated answered round still self-heals" "human-review-requested" \
  "$(jq -r '.action' <<<"$out")"

# The same listing paginated, with nothing answering it, must stay silent —
# not warn, and above all not re-request.
reset_stub
printf '2' > "$tmp_dir/pages"
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
idle_view CHANGES_REQUESTED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a paginated unanswered round is neither warned about nor re-requested" "" "$out"
assert_eq "  ... and posts nothing" "" "$(cat "$tmp_dir/posts")"

# --- Approved, idle, and never re-asked: both halves fire together --------------
# ensure_human_reviewer re-requests the approver (nobody CHANGES_REQUESTED-
# blocking it), and because the PR is also approved+mergeable+green+idle with
# no nudge yet, the idle nudge fires in the same pass.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an idle approved PR is both re-requested and nudged" \
  "$(printf 'human-review-requested\nnudged')" \
  "$(jq -r '.action' <<<"$out" | sort)"
assert_eq "  ... naming the approver as the review target" "Warwick-Allen" \
  "$(jq -r 'select(.action == "human-review-requested") | .reviewers[0]' <<<"$out")"
assert_eq "  ... naming the assignee as the nudge target" "warwickallen" \
  "$(jq -r 'select(.action == "nudged") | .reviewer' <<<"$out")"
assert_contains "the nudge comment carries the header and the marker" \
  "<!-- agent-ops:human-nudge -->" "$(comments)"
assert_contains "  ... and is stamped as this system's own write" \
  "<!-- agent-ops:pipeline-comment cycle=c1 actor=script -->" "$(comments)"
assert_contains "  ... visibly attributed" "**Script**" "$(comments)"
assert_eq "  ... exactly one comment posted" "1" "$(comment_count)"

# --- Already nudged: the marker makes it idempotent, not time-windowed ----------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" yes
out="$(run_sweep)"
assert_eq "a PR nudged once already is not nudged again" "" "$out"
assert_eq "  ... and posts no comment" "0" "$(comment_count)"

# A genuine nudge-shaped comment authored under a different pipeline actor
# (e.g. the Reviewer, not the Script) still counts — recognition keys off
# `PIPELINE_COMMENT_MARKER_PREFIX` alone, never a specific actor= value
# (agent-ops#390 acceptance 3).
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" reviewer-actor
out="$(run_sweep)"
assert_eq "a nudge-shaped comment authored by another pipeline actor still counts" \
  "" "$out"
assert_eq "  ... and posts no comment" "0" "$(comment_count)"

# --- A non-pipeline write reproducing the literal marker never disables the -----
# --- nudge: pipeline authorship is required, not just the exact string ---------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" quoted-no-stamp
out="$(run_sweep)"
assert_eq "a bystander quoting the exact marker is still nudged" \
  "nudged" "$(jq -r 'select(.action == "nudged") | .action' <<<"$out")"

# --- A pipeline-authored comment merely discussing the nudge mechanism never ----
# --- disables it either: the exact HTML-comment form is required too -----------
# --- (agent-ops#390 fault #1 — the Reviewer summarising this very fix) ---------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" mentioned
out="$(run_sweep)"
assert_eq "a pipeline comment merely mentioning the marker is still nudged" \
  "nudged" "$(jq -r 'select(.action == "nudged") | .action' <<<"$out")"

# --- Not idle long enough yet: no nudge, review request still self-heals --------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
idle_view APPROVED MERGEABLE yes "$(date -u +%Y-%m-%dT%H:%M:%SZ)" no
out="$(run_sweep)"
assert_eq "a freshly-approved PR is not nudged" "human-review-requested" \
  "$(jq -r '.action' <<<"$out")"
assert_eq "  ... no comment posted" "0" "$(comment_count)"

# --- Conflicting: never nudge a PR that is not actually mergeable ---------------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED CONFLICTING yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a conflicting PR is never nudged" "" "$out"

# --- BLOCKED: mergeable is not the same question as "GitHub would merge it" -----
# `_handoff_pr_approved` is true on the first standing approval, so on a base
# branch requiring two or more the nudge would otherwise claim a pull request
# was only waiting on a merge click while GitHub was waiting on a second
# approval. `mergeable` cannot see that — it reports merge-conflict state —
# and `mergeStateStatus` is where GitHub says so.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" no "" BLOCKED
out="$(run_sweep)"
assert_eq "an approved, MERGEABLE, green, idle but BLOCKED PR is never nudged" "" "$out"

# Only `BLOCKED` may suppress it. `BEHIND` is a strict-checks branch needing an
# update — a merge click's own business, and exactly what the nudge exists to
# prompt — and `UNKNOWN` is GitHub not having finished computing the field,
# which must fail open like every other unreadable state in this sweep.
for state in CLEAN BEHIND UNKNOWN; do
  reset_stub
  set_reviews "$(review Warwick-Allen APPROVED)"
  printf 'Warwick-Allen\n' > "$tmp_dir/pending"
  idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" no "" "$state"
  out="$(run_sweep)"
  assert_eq "a $state merge state is still nudged" \
    "nudged" "$(jq -r 'select(.action == "nudged") | .action' <<<"$out")"
done

# --- Checks not all green: an empty or mixed rollup is never "green" ------------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE mixed "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a mixed rollup is never nudged" "" "$out"

reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE "" "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an empty rollup (no checks run yet) is never nudged" "" "$out"

# --- A SKIPPED CheckRun is not a failure: it is what a paths:-filtered or ------
# --- if:-gated job reports, on every pull request in every target repo (#384) --
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE skipped "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a rollup whose only non-SUCCESS entry is SKIPPED is nudged" \
  "nudged" "$(jq -r 'select(.action == "nudged") | .action' <<<"$out")"

# --- A real failure state must still block the nudge, SKIPPED notwithstanding --
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE cancelled "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a CANCELLED entry is never nudged" "" "$out"

reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE in_progress "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an IN_PROGRESS entry is never nudged" "" "$out"

# --- Merge-queue awareness (requirement 38f, agent-ops#374) ---------------------
#
# `dequeued_at` fixtures below are computed relative to "now" (never a
# hardcoded literal): scripts/sweep-human-visibility.sh reads the real wall
# clock (`date +%s`), and agent-ops#394 added an age gate
# (`merge_queue_dequeue_notice_max_age_hours`, default 24 h) that a fixed
# past literal would eventually age out of, breaking this suite on a later
# day for a reason that has nothing to do with a real regression.
recent_dequeue_at() {  # <hours ago>
  date -u -d "-$1 hours" +%Y-%m-%dT%H:%M:%SZ
}

# A currently-queued pull request reads APPROVED/MERGEABLE/green exactly like
# one nobody has acted on yet — the human has already clicked merge, so the
# idle nudge must not fire and tell them otherwise.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" no
set_merge_queue true
out="$(run_sweep)"
assert_eq "a currently-queued PR is never nudged" "" "$out"
assert_eq "  ... no comment posted" "0" "$(comment_count)"

# A dequeue notice fires immediately — unconditional on idle_hours — because
# it is new information, not the "forgot to click merge" case that threshold
# exists for.
write_config warwickallen 0
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "" no
dq_at="$(recent_dequeue_at 1)"
set_merge_queue false "$dq_at" "failed_checks"
out="$(run_sweep)"
assert_eq "a checks-failure dequeue posts its own dequeue-notice action even with idle_hours 0" \
  "dequeue-notice" "$(jq -r '.action' <<<"$out")"
assert_contains "  ... the notice names the removal time" "$dq_at" "$(comments)"
assert_contains "  ... and the reason" "failed_checks" "$(comments)"
assert_contains "  ... marked idempotent per removal event" \
  "<!-- agent-ops:merge-queue-dequeued:${dq_at} -->" "$(comments)"
write_config warwickallen 24

# Idempotent: a dequeue already notified (the marker for this exact
# timestamp already on the pull request) is not notified again.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
dq_at="$(recent_dequeue_at 1)"
idle_view APPROVED MERGEABLE yes "" no "$dq_at"
set_merge_queue false "$dq_at" "failed_checks"
out="$(run_sweep)"
assert_eq "an already-notified dequeue is not notified again" "" "$out"
assert_eq "  ... no comment posted" "0" "$(comment_count)"

# A second, later dequeue (a fresh timestamp) gets its own notice even though
# an earlier one was already acknowledged.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
older_dq_at="$(recent_dequeue_at 2)"
newer_dq_at="$(recent_dequeue_at 1)"
idle_view APPROVED MERGEABLE yes "" no "$older_dq_at"
set_merge_queue false "$newer_dq_at" "failed_checks"
out="$(run_sweep)"
assert_eq "a fresh dequeue after an already-notified one still posts its own dequeue-notice" \
  "dequeue-notice" "$(jq -r 'select(.action == "dequeue-notice") | .action' <<<"$out")"
assert_contains "  ... naming the new removal time" "$newer_dq_at" "$(comments)"

# Re-queued at the same head since the recorded dequeue: nothing fresh to
# say, so no notice — the probe's `queued: true` wins over the stale event.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" no
set_merge_queue true "$(recent_dequeue_at 1)" "failed_checks"
out="$(run_sweep)"
assert_eq "a re-queued PR with a stale dequeue event gets no notice, nor a nudge" \
  "" "$out"

# A "manual" dequeue — the maintainer removing their own queue entry — is
# not this notice's business: it addresses a human about a defect they did
# not cause, and here they caused it themselves (agent-ops#394).
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "" no
set_merge_queue false "$(recent_dequeue_at 1)" "manual"
out="$(run_sweep)"
assert_eq "a manual dequeue gets no notice, nor a nudge" "" "$out"
assert_eq "  ... no comment posted" "0" "$(comment_count)"

# A dequeue older than merge_queue_dequeue_notice_max_age_hours gets no
# notice even on the very first sweep to see it — the rollout case
# agent-ops#394 closes, so a repository's queue adoption does not
# retroactively read every already-old removal as fresh news.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "" no
set_merge_queue false "$(recent_dequeue_at 48)" "failed_checks"
out="$(run_sweep)"
assert_eq "a dequeue past the default max age gets no notice, nor a nudge" "" "$out"
assert_eq "  ... no comment posted" "0" "$(comment_count)"

# `merge_queue_dequeue_notice_max_age_hours: 0` disables the notice
# outright (agent-ops#429) — an explicit guard, not merely a zero-width
# threshold: a same-second dequeue (age 0) would otherwise still satisfy
# `age <= threshold` with threshold 0 and post anyway.
write_config warwickallen 0 0
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "" no
set_merge_queue false "$(recent_dequeue_at 0)" "failed_checks"
out="$(run_sweep)"
assert_eq "merge_queue_dequeue_notice_max_age_hours 0 disables the notice even for a same-second dequeue" \
  "" "$out"
assert_eq "  ... no comment posted" "0" "$(comment_count)"
write_config warwickallen 24

# An unreadable merge-queue probe must never be read as "definitely not
# queued" — but it also must not break the pre-existing idle-nudge path,
# which behaves exactly as it did before this feature existed.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" no
: > "$tmp_dir/mq-fail"
out="$(run_sweep)"
assert_eq "an unreadable merge-queue probe still allows the ordinary idle nudge" \
  "nudged" "$(jq -r 'select(.action == "nudged") | .action' <<<"$out")"

# The dequeue-notice POST itself failing is a warning, not silence.
write_config warwickallen 0
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "" no
set_merge_queue false "$(recent_dequeue_at 1)" "failed_checks"
printf x > "$tmp_dir/comment-fail"
out="$(run_sweep)"
assert_eq "a failed dequeue-notice POST is a warning" "warning" \
  "$(jq -r --arg u "$URL" 'select(.pr_url == $u) | .action' <<<"$out" | tail -n1)"
write_config warwickallen 24

# --- human_nudge_idle_hours 0 disables the nudge, not the review request --------
write_config warwickallen 0
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "idle_hours 0 disables the nudge only" "human-review-requested" \
  "$(jq -r '.action' <<<"$out")"
write_config warwickallen 24

# --- Failures are warnings, never a silent "nothing to do" ----------------------
# An unreadable `/reviews` breaks two independent reads on the same pull
# request — `ensure_human_reviewer`'s candidate check (lib/handoff.sh) and
# the idle nudge's own approval check (`_handoff_pr_approved`, derived from
# the same endpoint rather than `reviewDecision`, agent-ops#391) — so both
# warn, rather than one masking the other.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf '/reviews' > "$tmp_dir/api-fail"
out="$(run_sweep)"
assert_eq "an unreadable reviews list warns on every check that reads it" \
  "$(printf 'warning\nwarning')" "$(jq -r '.action' <<<"$out" | sort)"
assert_eq "  ... both naming the pull request" "$(printf '%s\n%s' "$URL" "$URL")" \
  "$(jq -r '.pr_url' <<<"$out" | sort)"

# agent-ops#1082: when the /reviews read behind the idle-nudge check fails
# specifically on a GitHub REST rate-limit refusal, the warning says so
# distinguishably, rather than the same generic detail a non-rate-limit
# failure gets.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf '/reviews' > "$tmp_dir/api-fail"
printf 'HTTP 403: API rate limit exceeded for user ID 2049303' > "$tmp_dir/api-fail-msg"
out="$(run_sweep)"
assert_contains "a rate-limited reviews read names the cause in the idle-nudge warning" \
  "could not read the pull request's reviews — skipping the idle-nudge check (GitHub's primary rate limit refused the read)" \
  "$(jq -r 'select(.action == "warning") | .detail' <<<"$out" | grep 'idle-nudge')"

reset_stub
printf x > "$tmp_dir/list-fail"
out="$(run_sweep)"
assert_eq "an unreadable pull-request listing is a warning" "warning" "$(jq -r '.action' <<<"$out")"

reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf x > "$tmp_dir/view-fail"
out="$(run_sweep)"
assert_eq "an unreadable idle-check view is a warning, after the self-heal" \
  "human-review-requested" "$(jq -r 'select(.action != "warning") | .action' <<<"$out")"
assert_eq "  ... and a warning" "1" \
  "$(jq -r 'select(.action == "warning") | .action' <<<"$out" | wc -l | tr -d ' ')"

# --- Usage error: no repo argument ----------------------------------------------
out="$(SWEEP_GH="$tmp_dir/gh" AGENT_OPS_CONFIG="$config" bash "$SWEEP" 2>&1)"; rc=$?
assert_eq "no repo argument is a usage error" "64" "$rc"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
