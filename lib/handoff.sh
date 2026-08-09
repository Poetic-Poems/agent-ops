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
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail` and a library that re-sets options silently
# changes its caller.
#
# Environment:
#   HANDOFF_GH  override `gh` (tests stub it).

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

# _handoff_blocking_reviewers SLUG NUMBER
# Print, one per line, the logins of the humans whose review currently blocks
# the pull request. Returns non-zero, printing nothing, when GitHub could not be
# asked — the same rule as `_handoff_draft_flag`, for the same reason.
#
# "Currently blocks" is computed the way GitHub computes `reviewDecision`, not
# by taking the newest review: only APPROVED and CHANGES_REQUESTED count, and
# the last of those *per reviewer* is that reviewer's standing position. A
# COMMENTED review does not change anyone's decision, so a human who requested
# changes and then added a comment is still blocking — and reading their newest
# review would have concluded otherwise and asked nobody for anything.
#
# Bots are excluded. This org runs Copilot code review on every PR, and a bot
# can be re-requested exactly like a person: doing so would spend money and
# noise on the one reviewer that is not the human this exists to reach.
#
# The PR's author needs no exclusion — GitHub forbids requesting changes on
# your own pull request, so an author can never appear in this set. That is
# also what makes the set safe to POST verbatim: requesting a review from the
# author is a 422, and it is unreachable here.
_handoff_blocking_reviewers() {
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
  jq -s -r '
    [.[] | select(.bot | not)
         | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")]
    | group_by(.login) | map(last)
    | map(select(.state == "CHANGES_REQUESTED") | .login)
    | unique | .[]' <<<"$lines" 2>/dev/null || return 1
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
# Either way the author is struck off the candidates before anything is asked,
# never asked-for-and-refused: a 422 is not a transient failure worth warning
# about every cycle, it is a fact about the configuration that will not change
# tomorrow, and one invalid login fails the whole POST rather than its own
# entry. That filter is what makes `known` safe to trust — a `COMMENT` review
# is open to a pull request's author, so the reviews list can name them (see
# `_handoff_known_reviewers`) — and it is why ASSIGNEE equal to the author is a
# `skip` rather than an attempt.
#
# Prints one of:
#   skip       PR_URL is empty, the PR is a draft, something is already
#               `CHANGES_REQUESTED`-blocking it (confirm_review_requested's
#               job, not this one's), or the only candidate target is the
#               pull request's own author.
#   already    every candidate target already has a pending review request.
#   requested  this call asked, and GitHub now shows it pending.
#   failed     the request could not be read, or did not take.
#
# Exit status is 0 for `skip`, `already` and `requested`, 1 for `failed` — the
# same convention as `confirm_review_requested`, so callers can share one
# `case` shape across both.
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

  if [[ -n "$known" ]]; then
    targets="$known"
  elif [[ -n "$assignee" && "$assignee" != "$author" ]]; then
    targets="$assignee"
  else
    printf 'skip'
    return 0
  fi

  if ! pending="$("$gh_bin" api "repos/$slug/pulls/$number" \
                    --jq '[.requested_reviewers[]?.login] | .[]' 2>/dev/null)"; then
    printf 'failed'
    return 1
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
                    --jq '[.requested_reviewers[]?.login] | .[]' 2>/dev/null)"; then
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
