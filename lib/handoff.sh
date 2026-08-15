#!/usr/bin/env bash
#
# lib/handoff.sh — the moment a pull request stops being the pipeline's and
# becomes the human's, made a fact rather than a claim (requirement 31a).
#
# Requirement 31 gives the Reviewer one irreversible action: once CI is green
# and the PR is mergeable, it runs `gh pr ready`. That single call is the whole
# handoff — everything before it is the pipeline talking to itself, and
# everything after it is a human's queue. Requirement 32 then has the Reviewer
# *report* what it did, and the Script logs `pr-ready` from that report.
#
# Those are two different things, and treating the report as the deed is how a
# finished PR disappears. It happened: a Reviewer answered
# `{"status": "ready", "ci": "passing"}` for a PR whose work was complete and
# whose checks were green, never ran `gh pr ready`, and the Script logged
# `pr-ready` and moved on. The PR stayed a draft — invisible to the human, who
# is watching for review requests, and invisible to the log, which recorded a
# successful handoff. Three hours later the abandoned-drafts source (requirement
# 3e) correctly re-detected it as a stalled draft and paid an Implementor and a
# Reviewer to finish work that was already finished, at a fresh head SHA, which
# is a fresh ref no block covers — so it would have done that on the hour,
# indefinitely, each round looking productive.
#
# What makes this class of bug expensive is that no component is in a position
# to notice it. The Reviewer believes it handed off. The Script believes the
# Reviewer. The log agrees with both. Only GitHub disagrees, and nobody asked
# it. So this file asks it: the verdict stays the Reviewer's — it is the only
# actor that has read the diff — but whether the PR left draft is checked
# against the API, and the check is cheap enough (one field on one PR) to make
# unconditionally.
#
# The Script also *completes* a handoff the Reviewer left undone rather than
# failing it. The expensive, model-shaped half of requirement 31 is the
# judgement "this is ready"; `gh pr ready` is mechanism, and the Script can
# perform mechanism deterministically. Failing instead would put a PR the
# Reviewer has certified in front of a human as a problem, which is the outcome
# requirement 32a exists to avoid.
#
# `pr_url_for_branch` below is the same principle applied one step earlier, and
# it is here rather than beside the other requirement 9 fallbacks for that
# reason: those read what an actor left behind, and this asks GitHub. Nothing
# can be handed off that cannot be named, and the pipeline had three ways to
# name a stranded pull request, all three of which depend on the stage that has
# just failed (see requirement 9).
#
# `confirm_review_requested` is the same promise for the round *after* the
# first. A draft flip is the handoff exactly once per pull request; every
# later round begins with a PR that is already ready, so `gh pr ready` is a
# no-op and there is nothing left that puts the PR back in front of the human.
# See its own comment for what that cost.
#
# `ensure_human_reviewer` is the same promise again, for the case neither of
# the above covers: a ready pull request with nobody's review currently
# blocking it — first-round, or already approved — where the human still has
# not been *asked*, only auto-subscribed by CODEOWNERS and then dropped from
# the queue the moment they answered (requirement 38 in
# docs/IMPLEMENTATION-PIPELINE-SPEC.md).
#
# `handoff_answer_events` and `handoff_round_answered` are a different kind
# of promise again: not an action, but the judgement two callers must agree
# on before either acts — whether a review round is *answered* at all
# (requirement 3c's candidate rule, `scripts/gather-review-feedback.sh`, and
# requirement 38c's sweep, `scripts/sweep-human-visibility.sh`). The two used
# to compute this independently — one script had it, the other deliberately
# did not, because a naive second copy would have read the sweep's own past
# re-request as an answer to itself (tech-debt/TD-PPagop-26080804.md). One
# definition, two callers, each passing what it is and is not allowed to
# treat as an answer, is requirement 34a applied to a predicate instead of an
# action.
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail` and a library that re-sets options silently
# changes its caller.
#
# Environment:
#   HANDOFF_GH  override `gh` (tests stub it).
#   `handoff_answer_events` and `handoff_round_answered` read
#   `PIPELINE_COMMENT_MARKER_PREFIX` — source lib/pipeline-marker.sh before
#   this file, or before calling either.

# pr_url_for_branch TARGET_SLUG BRANCH
# Print the URL of the open pull request whose head is BRANCH in TARGET_SLUG,
# or nothing at all.
#
# The last of requirement 9's fallbacks for a stage that died without saying
# what it had opened, and the only one that does not depend on that stage. The
# other three — the final message's `pr_url`, a URL grepped out of the stage
# output, the `.git/agent-ops-pr-url` breadcrumb (requirement 23) — are all
# things the Implementor must have done something to produce, and an
# Implementor that failed to emit a parseable final message is precisely an
# Implementor that may have skipped them. All three came up empty on three
# items in one hour on 2026-08-03 (agent-ops #172, #173, #175), each with
# finished, pushed, CI-green work in a draft pull request the Script could no
# longer name: no stage-failure comment landed on any of them, and the
# Enabler's one lever for a stalled handoff — `complete_handoff`, gated on a
# non-empty `pr_url` from the block (requirement 32b) — was unavailable for
# exactly the failure it exists to recover. A human finished all three by
# hand.
#
# The branch needs nothing from the model: the Script computed it itself
# (`claim_branch_for`, requirement 17a) and pushed it before the stage began.
# So this is the fallback that holds when the stage contributed nothing at
# all, which is the case worth having one for.
#
# `--state open` is the question actually being asked: a pull request to
# comment on and hand off. `.[0]` because a head branch can in principle carry
# more than one open pull request (differing bases); `gh` lists newest first,
# which is the one this cycle pushed.
#
# Always succeeds, printing nothing when there is no such PR or the API cannot
# be reached — the two are not distinguished, deliberately. Every caller is a
# `[[ -z "$url" ]] && url="$(pr_url_for_branch …)"` on a failure path already
# in progress, under `errexit`, where a non-zero return would kill the cycle
# before it logs the failure this is trying to enrich (the same trap
# `read_pr_url_breadcrumb` documents). Coming up empty costs what the pipeline
# had before this existed; failing loudly costs the record.
pr_url_for_branch() {
  local slug="${1:-}" branch="${2:-}" gh_bin="${HANDOFF_GH:-gh}" url
  [[ -n "$slug" && -n "$branch" ]] || return 0
  url="$("$gh_bin" pr list -R "$slug" --head "$branch" --state open \
          --json url --jq '.[0].url // empty' 2>/dev/null)" || return 0
  printf '%s' "${url//[[:space:]]/}"
}

# _handoff_draft_flag PR_URL
# Print `true` or `false` — GitHub's own answer to whether the PR is a draft.
# Returns non-zero, printing nothing, when the answer could not be had: an
# unreachable API, a deleted PR, an authentication failure, or any reply that is
# not one of the two booleans. The caller must not read "could not ask" as
# "not a draft"; that is the assumption this whole file exists to remove.
_handoff_draft_flag() {
  local url="$1" gh_bin="${HANDOFF_GH:-gh}" flag
  flag="$("$gh_bin" pr view "$url" --json isDraft --jq '.isDraft' 2>/dev/null)" || return 1
  case "$flag" in
    true|false) printf '%s' "$flag" ;;
    *) return 1 ;;
  esac
}

# confirm_pr_ready PR_URL
# Ensure the pull request is genuinely out of draft, and say what that took.
#
# Prints exactly one word:
#   already   the Reviewer performed the handoff itself — the ordinary path,
#             and the only one that costs nothing but the check.
#   flipped   the PR was still a draft; this call ran `gh pr ready` and GitHub
#             now agrees it is not. The work is handed off, but the Reviewer
#             did not do it, which is worth a warning in the log.
#   failed    the PR is still a draft after the attempt, or its state could not
#             be read at all.
#
# Exit status is 0 for `already` and `flipped`, 1 for `failed`, so a caller may
# branch on the status and log the word.
#
# `failed` is deliberately also the answer when the API cannot be reached. The
# alternative — assume the Reviewer was right and log `pr-ready` — is exactly
# the silent strand above, and the cost of being wrong the other way is one
# blocked item that the Enabler re-examines (requirement 32a), not a human
# interruption. Fail towards the state something else will look at.
confirm_pr_ready() {
  local url="${1:-}" gh_bin="${HANDOFF_GH:-gh}" flag

  if [[ -z "$url" ]]; then
    printf 'failed'
    return 1
  fi

  if ! flag="$(_handoff_draft_flag "$url")"; then
    printf 'failed'
    return 1
  fi
  if [[ "$flag" == "false" ]]; then
    printf 'already'
    return 0
  fi

  # The flip's own exit status is not the answer — `gh pr ready` can report
  # success on a PR that stays a draft (and does report failure on races that
  # nonetheless land). Re-reading the flag is the answer, and it doubles as the
  # retry for a first read that was merely unlucky.
  "$gh_bin" pr ready "$url" >/dev/null 2>&1 || true

  if ! flag="$(_handoff_draft_flag "$url")"; then
    printf 'failed'
    return 1
  fi
  if [[ "$flag" == "false" ]]; then
    printf 'flipped'
    return 0
  fi

  printf 'failed'
  return 1
}

# _handoff_pr_parts PR_URL
# Print `owner/repo<TAB>number` for a pull request URL, or return non-zero.
#
# `confirm_pr_ready` gets by with `gh pr view <url>`, which resolves the URL
# itself. Requesting a review has no `gh` porcelain, so it goes through
# `gh api repos/<slug>/pulls/<n>/…` and the parts have to be named. Taking them
# from the URL rather than from the work order is deliberate: `pr_number` on the
# work order is a field the Co-Ordinator filled in (requirement 4), and the URL
# is the one identifier every caller already holds and requirement 9 has four
# ways to recover.
_handoff_pr_parts() {
  local url="${1:-}"
  [[ "$url" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]] || return 1
  printf '%s/%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# _handoff_latest_reviews SLUG NUMBER
# Print a compact JSON array of `{login, state}`, one entry per non-bot
# reviewer, giving each reviewer's *standing position* — the last of their own
# APPROVED or CHANGES_REQUESTED reviews, a COMMENTED review never changing it.
# This is the one computation GitHub's own `reviewDecision` performs, and both
# `_handoff_blocking_reviewers` (the CHANGES_REQUESTED half) and
# `_handoff_pr_approved` (the APPROVED half) below read it rather than each
# deriving it separately — one definition, two callers, requirement 34a's own
# argument. Returns non-zero, printing nothing, when GitHub could not be
# asked — the same rule as `_handoff_draft_flag`, for the same reason.
#
# Bots are excluded. This org runs Copilot code review on every PR, and a
# Bot-authored review is not a human's standing position, whichever way a
# caller reads it: not a reviewer to re-request (a bot can be, exactly like a
# person, and doing so would spend money and noise on the one reviewer that
# is not the human this exists to reach), and not a vote towards "approved"
# either.
#
# The PR's author needs no exclusion — GitHub forbids requesting changes on
# your own pull request, so an author can never appear in this set as
# CHANGES_REQUESTED. That is also what makes `_handoff_blocking_reviewers`'s
# set safe to POST verbatim: requesting a review from the author is a 422, and
# it is unreachable here.
_handoff_latest_reviews() {
  local slug="$1" number="$2" gh_bin="${HANDOFF_GH:-gh}" lines
  # One JSON object per line rather than an array: `--paginate` concatenates a
  # separate document per page, so an aggregate written inside `--jq` would be
  # computed per page and silently disagree with itself past thirty reviews.
  # The aggregation happens below, over every page at once.
  lines="$("$gh_bin" api "repos/$slug/pulls/$number/reviews" --paginate \
            --jq '.[] | select(.submitted_at != null)
                      | {login: .user.login,
                         bot: (((.user.type // "User") == "Bot") or (.user.login | endswith("[bot]"))),
                         state: .state}' 2>/dev/null)" || return 1
  jq -s -c '
    [.[] | select(.bot | not)
         | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")]
    | group_by(.login) | map(last) | map({login, state})' <<<"$lines" 2>/dev/null || return 1
}

# _handoff_blocking_reviewers SLUG NUMBER
# Print, one per line, the logins of the humans whose review currently blocks
# the pull request — every standing CHANGES_REQUESTED position from
# `_handoff_latest_reviews`. Returns non-zero, printing nothing, on the same
# "could not ask" terms as that function.
_handoff_blocking_reviewers() {
  local slug="$1" number="$2" latest
  latest="$(_handoff_latest_reviews "$slug" "$number")" || return 1
  jq -r '.[] | select(.state == "CHANGES_REQUESTED") | .login' <<<"$latest" 2>/dev/null || return 1
}

# _handoff_pr_approved SLUG NUMBER
# Print `true` when the pull request has at least one standing APPROVED
# position and nothing standing CHANGES_REQUESTED — the "approved" verdict
# GitHub's own `reviewDecision` would report if this repository's branch
# ruleset required at least one approving review. `false` otherwise. Returns
# non-zero, printing nothing, on the same "could not ask" terms as
# `_handoff_latest_reviews`.
#
# Exists because `reviewDecision` itself cannot be trusted for this: GitHub
# computes it against the base branch's *required* approving review count,
# and where that count is `0` — this repository's own ruleset, agent-ops#391
# — the field never becomes `APPROVED` no matter how many humans approve, so
# a caller gating on the field directly can never fire. Deriving the same
# verdict from the reviews list itself, the way `_handoff_blocking_reviewers`
# already does for its own half, has no such dependency.
_handoff_pr_approved() {
  local slug="$1" number="$2" latest
  latest="$(_handoff_latest_reviews "$slug" "$number")" || return 1
  jq -r '(any(.[]; .state == "APPROVED")) and (all(.[]; .state != "CHANGES_REQUESTED"))' \
    <<<"$latest" 2>/dev/null || return 1
}

# _handoff_known_reviewers SLUG NUMBER
# Print, one per line, the login of every non-bot account that has ever
# submitted a review on this pull request — any state, not only
# `CHANGES_REQUESTED` as `_handoff_blocking_reviewers` reads. Returns
# non-zero, printing nothing, on the same "could not ask" terms as the other
# `_handoff_*` readers.
#
# This is `ensure_human_reviewer`'s answer to a fact `_handoff_blocking_
# reviewers` never had to face: GitHub will not let a pull request's author
# approve it or request changes on it, so a `CHANGES_REQUESTED` reviewer can
# never be the author, but a review target chosen from *config* can be — on
# this system's own pull requests, they routinely are the same account (see
# `ensure_human_reviewer`). Whoever has already reviewed this pull request is
# in almost every case a login CODEOWNERS itself picked, without this file ever
# reading CODEOWNERS or knowing a second account exists behind one human's
# approvals.
#
# "Almost every": a `COMMENT` review *is* open to the author, so this list can
# contain them, and `ensure_human_reviewer` filters them out of it rather than
# trusting the reviews list to have done so.
_handoff_known_reviewers() {
  local slug="$1" number="$2" gh_bin="${HANDOFF_GH:-gh}" lines
  lines="$("$gh_bin" api "repos/$slug/pulls/$number/reviews" --paginate \
            --jq '.[] | select(.submitted_at != null)
                      | {login: .user.login,
                         bot: (((.user.type // "User") == "Bot") or (.user.login | endswith("[bot]")))}' \
            2>/dev/null)" || return 1
  jq -s -r '[.[] | select(.bot | not) | .login] | unique | .[]' <<<"$lines" 2>/dev/null || return 1
}

# _handoff_pr_author SLUG NUMBER
# Print the login of the pull request's author, or return non-zero, printing
# nothing, when GitHub could not be asked.
_handoff_pr_author() {
  local slug="$1" number="$2" gh_bin="${HANDOFF_GH:-gh}" login
  login="$("$gh_bin" api "repos/$slug/pulls/$number" --jq '.user.login // empty' 2>/dev/null)" \
    || return 1
  printf '%s' "$login"
}

# confirm_review_requested PR_URL
# Ensure the humans who asked for changes have been asked to look again, and
# say what that took.
#
# Prints `<word>`, or `<word><TAB><comma-separated logins>` where there are
# logins to name:
#   none       nobody's review blocks this PR — the ordinary path, and the
#              answer for every first-round pull request. One API call.
#   already    a re-review is pending from every blocking reviewer; whoever did
#              it (normally the Implementor, requirement 26b) got there first.
#   requested  this call asked, and GitHub now shows the request pending.
#   failed     the request could not be made, or did not take.
#
# Exit status is 0 for `none`, `already` and `requested`, 1 for `failed`.
#
# ## Why this exists
#
# A human asks for changes; the Implementor answers them and pushes; the
# Reviewer confirms CI is green and reports `ready`. Every actor has done its
# job, and the pull request is now in a state no one is watching: its
# `reviewDecision` is still `CHANGES_REQUESTED` — the author cannot clear that,
# by design — and *no review is requested of anyone*, because the reviewer's
# request was consumed the moment they submitted the review that asked for the
# changes. It is not in their review queue. It is not in anyone's. It sits at
# whatever position in the PR list its last update earned it, indefinitely,
# looking to every dashboard like a handed-off success.
#
# That is exactly what happened to poetic-fiddle #200: reviewed 10:18, answered
# and pushed 21:33, a comment posted at 21:44 saying the point was addressed —
# and it reached the human only because they went looking. The draft flip
# (requirement 31a) cannot cover this: the PR never went back to draft, so
# `confirm_pr_ready` correctly answers `already` and correctly logs a completed
# handoff. The handoff was completed. It just did not reach anybody.
#
# ## Why the Script and not the prompt
#
# The Implementor prompt has told it to re-request review since the
# review-feedback source existed, and #200 is what that instruction is worth on
# its own: best-effort prose, unverified, and the one round it was skipped is
# the round nobody could see had gone wrong. This is requirement 31a's lesson in
# a second clothing — the report is not the deed — so the answer is the same
# one: the model may still do it, the Script asks GitHub whether it happened,
# and where it did not the Script does it. The judgement ("these changes answer
# the review") stays with the models; requesting a review is mechanism.
#
# ## What it does not do
#
# It does not clear the block, and must not appear to. Re-requesting review
# leaves `reviewDecision` at `CHANGES_REQUESTED` and `mergeable_state` at
# `blocked` — verified against GitHub on #200, before and after — so the human
# gate holds exactly as "The Human Gate" describes it, and the PR still needs an
# approving review from a code owner that this system cannot give itself. All
# this does is put the PR back in the queue the human actually reads.
#
# Nor does it fail the handoff when it fails. The PR is finished, green and
# visible; what is missing is a notification, and the Implementor's own reply
# comment (requirement 26b) mentions the reviewer, which notifies them too.
# Recording an `attempt-failed` here would put a certified pull request in front
# of the Enabler as a problem — the outcome requirement 31a exists to avoid — to
# repair a secondary alerting path. So the failure is a `warning` and a field on
# the `pr-ready` event: visible on the dashboard, and never a false failure.
confirm_review_requested() {
  local url="${1:-}" gh_bin="${HANDOFF_GH:-gh}"
  local parts slug number blocking pending targets joined
  local -a args=()

  if [[ -z "$url" ]] || ! parts="$(_handoff_pr_parts "$url")"; then
    printf 'failed'
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  if ! blocking="$(_handoff_blocking_reviewers "$slug" "$number")"; then
    printf 'failed'
    return 1
  fi
  if [[ -z "$blocking" ]]; then
    printf 'none'
    return 0
  fi

  # Who is already on the hook. A reviewer who submits a review is removed from
  # this list by GitHub, which is the whole defect; a reviewer who is on it has
  # been asked and has not answered, and asking twice is a no-op that would
  # nonetheless report `requested` and read in the log as work done.
  if ! pending="$("$gh_bin" api "repos/$slug/pulls/$number" \
                    --jq '[.requested_reviewers[]?.login] | .[]' 2>/dev/null)"; then
    printf 'failed'
    return 1
  fi

  targets="$(comm -23 <(sort -u <<<"$blocking") <(sort -u <<<"$pending"))"
  joined="$(paste -sd, <<<"$blocking")"
  if [[ -z "$targets" ]]; then
    printf 'already\t%s' "$joined"
    return 0
  fi

  while IFS= read -r login; do
    [[ -n "$login" ]] && args+=(-f "reviewers[]=$login")
  done <<<"$targets"

  # As with `gh pr ready`, the POST's own exit status is not the answer: a 422
  # for one login in a batch fails the whole request, and a request that lands
  # can still be raced away. Re-reading the pending list is the answer.
  "$gh_bin" api -X POST "repos/$slug/pulls/$number/requested_reviewers" \
    "${args[@]}" >/dev/null 2>&1 || true

  if ! pending="$("$gh_bin" api "repos/$slug/pulls/$number" \
                    --jq '[.requested_reviewers[]?.login] | .[]' 2>/dev/null)"; then
    printf 'failed'
    return 1
  fi
  if [[ -n "$(comm -23 <(sort -u <<<"$blocking") <(sort -u <<<"$pending"))" ]]; then
    printf 'failed\t%s' "$joined"
    return 1
  fi

  printf 'requested\t%s' "$joined"
  return 0
}

# ensure_human_reviewer PR_URL ASSIGNEE
# Ensure a live review request is on a pull request whose next reviewer
# action belongs to a human, for the case `confirm_review_requested` does not
# cover: nobody's `CHANGES_REQUESTED` is blocking it, so there is no blocking
# reviewer to re-request from, and yet the pull request may still be sitting
# exactly where a human needs to look — a first review nobody has given, or
# an approval nobody has acted on since.
#
# This is agent-ops#242's poetic-fiddle #170: approved, green, and idle for
# 6.8 days, because CODEOWNERS' review request is consumed the moment the
# review is submitted and nothing ever asks again. Requesting review from
# someone who has already approved clears nothing they said — GitHub does not
# treat it as withdrawing the approval — it only puts the pull request back in
# the `pulls/review-requested` queue, which is the one dashboard a human
# actually watches. That is the whole point: this is a visibility nudge
# wearing the review-request mechanism, not a second review being solicited.
#
# The target is `_handoff_known_reviewers` (whoever has ever reviewed this
# pull request, in any state) before it is ever ASSIGNEE. That order matters
# on this system's own pull requests specifically: they are authored under
# the same account `enabler_assignee` routinely names (issue assignment has
# no such conflict; PR review does), and GitHub will refuse a review request
# aimed at a pull request's own author with a 422. CODEOWNERS already solved
# this once, automatically, the moment the pull request went ready — it never
# proposes the author as a reviewer of their own change — so reading who it
# already picked is both correct and one API call, where re-deriving the same
# answer from CODEOWNERS' file and org membership would be many. ASSIGNEE is
# the fallback for the one case that leaves nobody to read: a pull request
# CODEOWNERS never touched at all (no matching rule, or the repo does not use
# one).
#
# `_handoff_known_reviewers` only sees a reviewer who has *submitted* a
# review, which is not what CODEOWNERS' own auto-request actually leaves
# behind on a fresh pull request — a pending `requested_reviewers` entry,
# nobody having reviewed yet. Before this function existed to fall through to
# ASSIGNEE, that gap was invisible: this system's own pull requests have
# `assignee` equal to the author, so a first-round pull request with nobody's
# submitted review yet, but a live CODEOWNERS request already out for a
# *different* account, was misread as `skip\tno-candidate` — a live human
# review request already sitting on the pull request, reported as if none
# existed at all (agent-ops PRs #350, #353, #355; the two accounts are
# `@warwickallen`, this repo's own commit and comment identity, and
# `@Warwick-Allen`, its distinct human-review identity — both named in
# CODEOWNERS, so GitHub's own author-exclusion picks the latter without this
# function's help). So the already-pending `requested_reviewers` list is read
# too, before ASSIGNEE is ever considered: if it already names anyone,
# nothing needs asking — that candidate is reported as `already`, exactly the
# same shape a fresh request that turns out to already be pending gets below.
#
# Either way the author is struck off the candidates before anything is asked,
# never asked-for-and-refused: a 422 is not a transient failure worth warning
# about every cycle, it is a fact about the configuration that will not change
# tomorrow, and one invalid login fails the whole POST rather than its own
# entry. That filter is what makes `known` safe to trust — a `COMMENT` review
# is open to a pull request's author, so the reviews list can name them (see
# `_handoff_known_reviewers`) — and it is why ASSIGNEE equal to the author is a
# `skip` rather than an attempt.
#
# The no-candidate case carries its own detail (`skip\tno-candidate`),
# distinguishable from the other two `skip` reasons below (tech-debt/
# TD-PPagop-26081001.md): unlike a draft or a `CHANGES_REQUESTED`-blocked pull
# request — both fine to leave alone, since each has its own actor and its own
# clock — nothing else will ever ask this human, so a caller that cares (the
# periodic sweep, requirement 38c) needs to tell it apart from the other two
# to log a `warning` about it rather than passing over it in silence.
#
# Prints one of:
#   skip               the PR_URL is empty, the PR is a draft, or something is
#                       already `CHANGES_REQUESTED`-blocking it
#                       (confirm_review_requested's job, not this one's).
#   skip<TAB>no-candidate
#                       the only candidate target is the pull request's own
#                       author, and nobody else has a pending request
#                       either — there is nobody left to ask.
#   already             every candidate target already has a pending review
#                       request — including the case where nobody has
#                       reviewed yet, but somebody (typically CODEOWNERS)
#                       already has a request pending.
#   requested           this call asked, and GitHub now shows it pending.
#   failed              the request could not be read, or did not take.
#
# Exit status is 0 for `skip` (either shape), `already` and `requested`, 1 for
# `failed` — the same convention as `confirm_review_requested`, so callers can
# share one `case` shape across both.
ensure_human_reviewer() {
  local url="${1:-}" assignee="${2:-}" gh_bin="${HANDOFF_GH:-gh}"
  local parts slug number draft blocking known author targets pending
  local missing joined
  local -a args=()

  if [[ -z "$url" ]]; then
    printf 'skip'
    return 0
  fi
  if ! parts="$(_handoff_pr_parts "$url")"; then
    printf 'failed'
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  if ! draft="$(_handoff_draft_flag "$url")"; then
    printf 'failed'
    return 1
  fi
  if [[ "$draft" == "true" ]]; then
    printf 'skip'
    return 0
  fi

  if ! blocking="$(_handoff_blocking_reviewers "$slug" "$number")"; then
    printf 'failed'
    return 1
  fi
  if [[ -n "$blocking" ]]; then
    printf 'skip'
    return 0
  fi

  if ! known="$(_handoff_known_reviewers "$slug" "$number")"; then
    printf 'failed'
    return 1
  fi
  if ! author="$(_handoff_pr_author "$slug" "$number")"; then
    printf 'failed'
    return 1
  fi

  # The author is not a legal review target whichever list proposed them, so
  # the filter is applied to both. GitHub refuses `APPROVE` and
  # `REQUEST_CHANGES` from a pull request's own author but accepts a `COMMENT`
  # review — and a Reviewer's findings may be filed exactly that way
  # (`prompts/reviewer.md` offers `gh pr review --comment`), under the same
  # account that raised the pull request. One such review would otherwise put
  # the author into `known`, and the POST below 422s as a whole when any one
  # login on it is invalid: it would add *nobody*, not everybody-but-the-author,
  # switching requirement 38a's guarantee off on precisely the pull requests
  # this system raises.
  if [[ -n "$known" && -n "$author" ]]; then
    known="$(grep -Fxv -e "$author" <<<"$known" || true)"
  fi

  # Read once, ahead of the candidate decision: a pending request already
  # answers requirement 38a on its own, whoever put it there (CODEOWNERS, at
  # PR-open time, most often) — and GitHub never lets it name the author, so
  # the pending read needs no author filter to be trusted the same way
  # `known` does. It does carry `known`'s *bot* filter: a bot-type account or
  # a `[bot]`-suffixed login sitting in `requested_reviewers` is never read as
  # proof a human was asked (tech-debt/TD-PPagop-26081403.md) — this org runs
  # Copilot code review, and a repository ruleset can auto-request it into
  # this exact list. It also reads `requested_teams`: a requested team is
  # extended the same review-request mechanism CODEOWNERS gives a named
  # human, and a team can never itself be a bot, so
  # `scripts/gather-human-visibility-hygiene.sh`'s own read of this rule
  # (requirement 38e) counts it the same way this one does.
  if ! pending="$("$gh_bin" api "repos/$slug/pulls/$number" \
                    --jq '[(.requested_reviewers[]? | select(((.type // "User") == "Bot")
                             or (.login | endswith("[bot]")) | not) | .login),
                           (.requested_teams[]? | .slug)] | .[]' 2>/dev/null)"; then
    printf 'failed'
    return 1
  fi

  if [[ -n "$known" ]]; then
    targets="$known"
  elif [[ -n "$pending" ]]; then
    printf 'already\t%s' "$(paste -sd, <<<"$pending")"
    return 0
  elif [[ -n "$assignee" && "$assignee" != "$author" ]]; then
    targets="$assignee"
  else
    printf 'skip\tno-candidate'
    return 0
  fi

  joined="$(paste -sd, <<<"$targets")"
  missing="$(comm -23 <(sort -u <<<"$targets") <(sort -u <<<"$pending"))"
  if [[ -z "$missing" ]]; then
    printf 'already\t%s' "$joined"
    return 0
  fi

  while IFS= read -r login; do
    [[ -n "$login" ]] && args+=(-f "reviewers[]=$login")
  done <<<"$missing"

  # Same non-answer as `confirm_review_requested`'s POST: the exit status is
  # not the answer because a request that lands can still be raced away by a
  # concurrent submitted review. Re-reading the pending list is the answer.
  "$gh_bin" api -X POST "repos/$slug/pulls/$number/requested_reviewers" \
    "${args[@]}" >/dev/null 2>&1 || true

  if ! pending="$("$gh_bin" api "repos/$slug/pulls/$number" \
                    --jq '[(.requested_reviewers[]? | select(((.type // "User") == "Bot")
                             or (.login | endswith("[bot]")) | not) | .login),
                           (.requested_teams[]? | .slug)] | .[]' 2>/dev/null)"; then
    printf 'failed'
    return 1
  fi
  if [[ -n "$(comm -23 <(sort -u <<<"$targets") <(sort -u <<<"$pending"))" ]]; then
    printf 'failed\t%s' "$joined"
    return 1
  fi

  printf 'requested\t%s' "$joined"
  return 0
}

# handoff_answer_events REVIEWS_JSON COMMENTS_JSON [REREQUESTS_JSON]
# Print, sorted oldest first, the timestamp of every event that answers a
# review round: a marked reply from the Implementor — a review or general PR
# comment carrying `lib/pipeline-marker.sh`'s marker with `actor=implementor`
# — found in REVIEWS_JSON or COMMENTS_JSON, and, only where REREQUESTS_JSON
# names one, a review-requested timeline event. REVIEWS_JSON and
# COMMENTS_JSON are arrays of objects carrying at least `at` (a timestamp)
# and `body`; extra fields (`id`, `state`, `who`, …) are ignored, so a caller
# may pass whatever shape it already fetched. REREQUESTS_JSON is an array of
# objects carrying `at`; omit it (or pass `[]`) to read the marked-reply
# signal alone.
#
# This is the extraction requirement 3c's candidate rule
# (scripts/gather-review-feedback.sh) has always made; it lives here so a
# second caller — `handoff_round_answered` below, and through it
# scripts/sweep-human-visibility.sh (requirement 38c) — shares the one
# definition (requirement 34a) instead of re-deriving it
# (tech-debt/TD-PPagop-26080804.md). See gather-review-feedback.sh's own
# header for why events, not a commit's `committedDate`, are what "answered"
# reads: a force-push re-stamps every commit's date to push time without a
# human, or the agent, having answered anything (agent-ops#239, PR #205).
#
# Only `actor=implementor` closes a round. The marker also carries
# `actor=script`, `actor=enabler`, `actor=reviewer` and `actor=refiner` for
# other pipeline writes, and two of those are by definition not answers:
# `actor=script` records a stage giving up, `actor=enabler` a stall being
# diagnosed. On PR #269 exactly those two comments closed a round under the
# old "any marked reply" rule, and the work sat stranded until a human was
# escalated (agent-ops#278). A legacy marker with no `actor=` field at all
# does not answer the round either, for the same reason.
handoff_answer_events() {
  local reviews="${1:-[]}" comments="${2:-[]}" rerequests="${3:-[]}"
  jq -c -n --arg marker "$PIPELINE_COMMENT_MARKER_PREFIX" --arg actor "actor=implementor -->" \
      --argjson reviews "$reviews" --argjson comments "$comments" --argjson rr "$rerequests" '
    ([$reviews[]  | select((.body // "") | contains($marker) and contains($actor)) | .at]
     + [$comments[] | select((.body // "") | contains($marker) and contains($actor)) | .at]
     + [$rr[] | .at]) | sort
  '
}

# handoff_round_answered BLOCKING_AT REVIEWS_JSON COMMENTS_JSON [REREQUESTS_JSON]
# Print `answered`, `unanswered` or `unknown` — whether the review round that
# began with the blocking review submitted at BLOCKING_AT has since been
# answered, per `handoff_answer_events` above. `unknown` means the question
# could not be put at all — BLOCKING_AT was empty, one of REVIEWS_JSON,
# COMMENTS_JSON or (when given) REREQUESTS_JSON was not a single JSON array,
# or the extraction over them failed — the same "could not ask" convention
# every other reader in this file follows.
# The caller must not read `unknown` as `unanswered`: a read failure must not
# look exactly like a human still waiting, and must not look exactly like a
# round safe to re-request either.
#
# Omit REREQUESTS_JSON (or pass `[]`) when the caller's own action might
# itself create a review-requested event —
# scripts/sweep-human-visibility.sh calling `confirm_review_requested` on an
# `answered` verdict, specifically — or that later request would read back
# next cycle as the round having already been answered, defeating the point
# of asking (the discriminating predicate this function exists to be —
# tech-debt/TD-PPagop-26080804.md). scripts/gather-review-feedback.sh, which
# never requests anything itself, passes the timeline's `review_requested`
# events too.
handoff_round_answered() {
  local blocking_at="${1:-}" reviews="${2:-}" comments="${3:-}" rerequests="${4:-[]}"
  local events count

  # Every failure below answers `unknown`, never `answered`. The tri-state is
  # asymmetric: `answered` is the verdict that *acts* — it is what has
  # scripts/sweep-human-visibility.sh re-request a human's review — so a
  # verdict reached by accident there costs requirement 3c's silent
  # starvation, while the same accident landing on `unknown` costs one
  # warning and a retry next cycle. Anything this cannot compute is therefore
  # a read it could not make.
  #
  # `jq -e 'type == "array"'` alone does not establish that: `jq` evaluates
  # the filter once per input document and exits on the last one's truth, so
  # two concatenated arrays — exactly what `gh api --paginate` emits per page
  # — pass it, and then fail `--argjson` inside `handoff_answer_events`. A
  # caller must hand these arguments over as one document each (see
  # `_handoff_blocking_reviewers` above for the streaming read that
  # guarantees it); the guards here are what stops one that does not from
  # being read as an answer.
  [[ -n "$blocking_at" ]] || { printf 'unknown'; return 0; }
  jq -e 'type == "array"' <<<"$reviews" >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  jq -e 'type == "array"' <<<"$comments" >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  jq -e 'type == "array"' <<<"$rerequests" >/dev/null 2>&1 || { printf 'unknown'; return 0; }

  events="$(handoff_answer_events "$reviews" "$comments" "$rerequests" 2>/dev/null)" \
    || { printf 'unknown'; return 0; }
  count="$(jq -r --arg c "$blocking_at" '[.[] | select(. > $c)] | length' <<<"$events" 2>/dev/null)" \
    || { printf 'unknown'; return 0; }
  [[ "$count" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
  if [[ "$count" != "0" ]]; then
    printf 'answered'
  else
    printf 'unanswered'
  fi
}
