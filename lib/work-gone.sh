#!/usr/bin/env bash
#
# lib/work-gone.sh — which blocked items are blocked on work that no longer
# exists (requirement 34i).
#
# A block says "something is in the way *for now*", and requirement 34 leaves
# clearing it to somebody who looks: the Co-Ordinator, which re-checks its own
# blocked list, or the Enabler, which re-examines at Opus prices. Both of those
# readers have a blind spot in the same place, and it is the ordinary case:
#
#   the item is not blocked any more because the *work* is gone.
#
# The issue was closed, the pull request merged, the register entry flipped to
# `resolved`. Nothing about that moment produces an event — the merge is a human
# clicking a button in a browser — so the block outlives the work it describes.
# The Co-Ordinator never revisits it, because a finished item is offered by no
# source and so never reaches the Co-Ordinator's candidates at all; the Enabler
# does, but only after `enabler_recheck_hours`, and it pays a full engagement to
# discover what one `gh` read already sitting on disk would have said. The item
# that prompted this had been merged, register-flipped and done for a day, with
# an escalation issue closed behind it, and was still listed as blocked, waiting
# on a re-examination that was two days away.
#
# So this is the cheap half of that judgement, made deterministically, from
# state the cycle already holds. It clears nothing that is *still* work and asks
# no model anything: it answers one question per item class, and only where the
# answer is a fact.
#
#   an issue              the issue is not in the repo's open-issue digest
#   a pull request        the pull request is not in the repo's open-PR digest
#                         (`pr-<n>-abandoned-…`, `-conflict-…`, `-review-…`)
#   a register item       the item's own file on the default branch says
#                         `status: resolved` or `status: not-debt`
#   a project-review ref  a *merged* pull request on the default branch names
#                         the recommendation's own `review-<date>-R-NN` ref —
#                         the same test requirement 16 already applies when
#                         deciding whether to offer the recommendation as a
#                         candidate at all, read here instead of asked of a
#                         model
#   a plan task id         the task's own checkbox, in the repo's
#                         `implementation_plan_path` document on the default
#                         branch, is checked (`- [x]`)
#
# Everything else — a security or code-quality finding, a register-hygiene or
# human-visibility item — is left blocked for the Enabler, and deliberately:
# `gather-findings.sh` degrades to `[]` on an API error *by design*, because
# its output is given to the Co-Ordinator and a Co-Ordinator that sees no
# findings simply declines. Read as a clearing signal, that same `[]` says
# "every alert is fixed", and one 403 would clear every alert block on the
# fleet. The digest this file reads instead carries `ok` precisely so that an
# unsampled repo can be told from an empty one (requirement 3b), and an
# `ok: false` repo clears nothing here. Neither a register-hygiene nor a
# human-visibility item has a completion signal at all to read — the
# register, or GitHub's own live pull-request state, *is* the item, and its
# own re-derivation is what `gather-register-hygiene.sh` or
# `gather-human-visibility-hygiene.sh` itself repairs.
#
# The event written is `unblocked`, never `item-void`. Requirement 34d makes a
# void something that must be *corroborated* and 34c makes it terminal, and
# neither is what this is: this is the cheap, reversible half of the judgement,
# and requirement 34 names over-clearing the safe direction — an item wrongly
# unblocked becomes a candidate again, is offered by no source, and nothing
# happens.
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh runs
# under `set -euo pipefail`.

# The id shapes this rule can decide, kept in one place because two readers need
# them: the clearance rule below, and the Script, which asks each side-channel
# only about the ids that could possibly be its shape (`work_gone_register_ids`,
# `work_gone_review_refs`, `work_gone_plan_ids`).
#
# `TD26072401` is the legacy flat id and `TD-PPpoet-26072401` the scoped one
# (`docs/TECH-DEBT-REGISTER.md` in Poetic-Poems/poetic); both are live, because
# a block predating a register's migration still names the item by the id it had
# when it was recorded.
WORK_GONE_ISSUE_RE='^[0-9]+$'
WORK_GONE_PR_RE='^pr-(?<n>[0-9]+)-'
WORK_GONE_REGISTER_RE='^TD([0-9]{8}|-[A-Za-z0-9]+-[0-9]{8})$'

# `review-2026-07-11-R-02`: the review-dated ref requirement 15 mints for every
# `project-review` recommendation, unchanged from filing to selection.
WORK_GONE_REVIEW_RE='^review-[0-9]{4}-[0-9]{2}-[0-9]{2}-R-[0-9]+$'

# `W10-breach-handling`: an implementation-plan task id, distinguished from the
# other shapes above (and from `dependabot-alert-4`, `code-scanning-alert-7`,
# `register-hygiene-<hash>`, `human-visibility-<hash>`, none of which start
# with an upper-case letter) by construction rather than by enumerating what
# it is not.
WORK_GONE_PLAN_RE='^[A-Z][A-Za-z0-9]*-[a-z0-9][a-z0-9-]*$'

# _work_gone_ids_matching RE BLOCKED_JSON
# Shared machinery behind work_gone_register_ids, work_gone_review_refs and
# work_gone_plan_ids: print, as a JSON object keyed by repo slug, the blocked
# items whose id matches RE: `{"owner/repo": ["TD-PPpoet-26072401", …]}`. Repos
# with none are absent, so a caller iterating this makes no call for a repo it
# has nothing to ask about — which is the steady state, and the reason each of
# these reads costs nothing on a fleet with no blocked items of that shape.
#
# Always succeeds, printing {} for input it cannot read.
_work_gone_ids_matching() {
  local re="$1" blocked="${2:-[]}" out=""
  # shellcheck disable=SC2016  # jq's $re, not the shell's.
  out="$(jq -c --arg re "$re" '
    [ .[] | select((.repo // "") != "" and ((.item // "") | test($re))) ]
    | group_by(.repo)
    | map({key: .[0].repo, value: (map(.item) | unique)})
    | from_entries' <<<"$blocked" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# work_gone_register_ids BLOCKED_JSON — the blocked items shaped like a
# tech-debt register id, for `scripts/gather-register-status.sh`.
work_gone_register_ids() {
  _work_gone_ids_matching "$WORK_GONE_REGISTER_RE" "${1:-[]}"
}

# work_gone_review_refs BLOCKED_JSON — the blocked items shaped like a
# project-review recommendation ref, for `scripts/gather-review-status.sh`.
work_gone_review_refs() {
  _work_gone_ids_matching "$WORK_GONE_REVIEW_RE" "${1:-[]}"
}

# work_gone_plan_ids BLOCKED_JSON — the blocked items shaped like an
# implementation-plan task id, for `scripts/gather-plan-status.sh`.
work_gone_plan_ids() {
  _work_gone_ids_matching "$WORK_GONE_PLAN_RE" "${1:-[]}"
}

# work_gone_clearances BLOCKED_JSON SOURCE_STATES_JSON [REGISTER_STATUS_JSON]
#                       [REVIEW_STATUS_JSON] [PLAN_STATUS_JSON]
# Print, as a JSON array, one entry per block whose work is demonstrably gone —
# the input to the `unblocked` events the Script writes:
#
#   {"repo": "owner/repo", "item": "123", "reason": "issue #123 is closed"}
#
# BLOCKED_JSON is the open blocked set (`open_blocked_items`, requirement 34h):
# a void item needs no unblocking, and writing one an `unblocked` would put a
# clear against a void in the log for no reason at all.
#
# SOURCE_STATES_JSON is the cycle's own array of source-state digests
# (requirement 3b), one per repo it walked. A repo missing from it, or carrying
# `ok: false`, decides nothing: unknown is not gone. That is the same direction
# requirement 35a's escalation test fails in, for the same reason — the cost of
# waiting is one more cycle, and the cost of being wrong is a block cleared out
# from under work that is still real.
#
# REGISTER_STATUS_JSON maps repo → item id → the `status` field of that item's
# file on the default branch (`scripts/gather-register-status.sh`). Absent, empty
# or unreadable means the register was not read, which decides nothing either.
#
# REVIEW_STATUS_JSON maps repo → recommendation ref → "merged" when a merged
# pull request on the default branch names that ref
# (`scripts/gather-review-status.sh`); anything else absent or unreadable
# decides nothing.
#
# PLAN_STATUS_JSON maps repo → task id → "done" or "open", read off that task's
# own checkbox in the repo's implementation-plan document
# (`scripts/gather-plan-status.sh`); anything else absent or unreadable decides
# nothing.
#
# Always succeeds, printing [] for input it cannot read: the caller runs under
# `set -e` mid-cycle, and a malformed digest must cost a clearance, never a
# cycle.
work_gone_clearances() {
  local blocked="${1:-[]}" states="${2:-[]}" register="${3:-{\}}" \
        review="${4:-{\}}" plan="${5:-{\}}" out="" docs
  # The open blocked set and the source-states array arrive on stdin, one
  # document per line, never in argv (requirement 4g): both grow with the
  # fleet's history, and past MAX_ARG_STRLEN an `--argjson` delivery makes
  # this call fail into its `2>/dev/null || true` — blocks silently stop
  # clearing.
  docs="$blocked"$'\n'"$states"
  # shellcheck disable=SC2016  # every $ below is jq's.
  out="$(jq -nc \
    --argjson register "$register" \
    --argjson review "$review" --argjson plan "$plan" \
    --arg issue_re "$WORK_GONE_ISSUE_RE" --arg pr_re "$WORK_GONE_PR_RE" \
    --arg review_re "$WORK_GONE_REVIEW_RE" --arg plan_re "$WORK_GONE_PLAN_RE" '
    input as $blocked | input as $states |
    def digest($slug): [ $states[] | select((.slug // "") == $slug and .ok == true) ] | first;
    [ $blocked[]
      | . as $b
      | ($b.repo // "") as $repo
      | ($b.item // "") as $item
      | select($item != "")
      | digest($repo) as $st
      | (if ($item | test($issue_re)) then
           (if $st == null then null
            elif ([ $st.issues[]? | .n ] | index($item | tonumber)) != null then null
            else "issue #\($item) is closed" end)
         elif ($item | test($pr_re)) then
           (($item | capture($pr_re) | .n | tonumber) as $n
            | if $st == null then null
              elif ([ $st.open_prs[]? | .n ] | index($n)) != null then null
              else "pull request #\($n) is closed or merged" end)
         elif ($item | test($review_re)) then
           ((($review[$repo] // {})[$item] // "") | ascii_downcase) as $status
           | if $status == "merged"
             then "a merged pull request references \($item)"
             else null end
         elif ($item | test($plan_re)) then
           ((($plan[$repo] // {})[$item] // "") | ascii_downcase) as $status
           | if $status == "done"
             then "the implementation plan marks \($item) done"
             else null end
         else
           ((($register[$repo] // {})[$item] // "") | ascii_downcase) as $status
           | if $status == "resolved" or $status == "not-debt"
             then "the tech-debt register records it \($status)"
             else null end
         end) as $reason
      | select($reason != null)
      | {repo: $repo, item: $item, reason: $reason} ]' \
    <<<"$docs" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}
