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
#   an issue           the issue is not in the repo's open-issue digest
#   a pull request     the pull request is not in the repo's open-PR digest
#                      (`pr-<n>-abandoned-…`, `-conflict-…`, `-review-…`)
#   a register item    the item's own file on the default branch says
#                      `status: resolved` or `status: not-debt`
#
# Everything else — a review recommendation, an implementation-plan item, a
# security finding — is left blocked for the Enabler, and deliberately:
#
#   - The file-backed sources (`project-review`, `implementation-plan`) are read
#     by the Co-Ordinator from the repository itself, so the Script has nothing
#     to compare an item id against without a fetch of its own, and "done" for
#     those is a judgement about prose rather than a field.
#   - The findings sources are worse than absent: `gather-findings.sh` degrades
#     to `[]` on an API error *by design*, because its output is given to the
#     Co-Ordinator and a Co-Ordinator that sees no findings simply declines. Read
#     as a clearing signal, that same `[]` says "every alert is fixed", and one
#     403 would clear every alert block on the fleet. The digest this file reads
#     instead carries `ok` precisely so that an unsampled repo can be told from
#     an empty one (requirement 3b), and an `ok: false` repo clears nothing here.
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
# them: the clearance rule below, and the Script, which asks the register only
# about the ids that could possibly be register ids (`work_gone_register_ids`).
#
# `TD26072401` is the legacy flat id and `TD-PPpoet-26072401` the scoped one
# (`docs/TECH-DEBT-REGISTER.md` in Poetic-Poems/poetic); both are live, because
# a block predating a register's migration still names the item by the id it had
# when it was recorded.
WORK_GONE_ISSUE_RE='^[0-9]+$'
WORK_GONE_PR_RE='^pr-(?<n>[0-9]+)-'
WORK_GONE_REGISTER_RE='^TD([0-9]{8}|-[A-Za-z0-9]+-[0-9]{8})$'

# work_gone_register_ids BLOCKED_JSON
# Print, as a JSON object keyed by repo slug, the blocked items whose ids are
# register ids: `{"owner/repo": ["TD-PPpoet-26072401", …]}`. Repos with none are
# absent, so a caller iterating this makes no call for a repo it has nothing to
# ask about — which is the steady state, and the reason the register read costs
# nothing on a fleet with no blocked register items.
#
# Always succeeds, printing {} for input it cannot read.
work_gone_register_ids() {
  local blocked="${1:-[]}" out=""
  # shellcheck disable=SC2016  # jq's $re, not the shell's.
  out="$(jq -c --arg re "$WORK_GONE_REGISTER_RE" '
    [ .[] | select((.repo // "") != "" and ((.item // "") | test($re))) ]
    | group_by(.repo)
    | map({key: .[0].repo, value: (map(.item) | unique)})
    | from_entries' <<<"$blocked" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# work_gone_clearances BLOCKED_JSON SOURCE_STATES_JSON [REGISTER_STATUS_JSON]
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
# Always succeeds, printing [] for input it cannot read: the caller runs under
# `set -e` mid-cycle, and a malformed digest must cost a clearance, never a
# cycle.
work_gone_clearances() {
  local blocked="${1:-[]}" states="${2:-[]}" register="${3:-{\}}" out=""
  # shellcheck disable=SC2016  # every $ below is jq's.
  out="$(jq -nc \
    --argjson blocked "$blocked" --argjson states "$states" --argjson register "$register" \
    --arg issue_re "$WORK_GONE_ISSUE_RE" --arg pr_re "$WORK_GONE_PR_RE" '
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
         else
           ((($register[$repo] // {})[$item] // "") | ascii_downcase) as $status
           | if $status == "resolved" or $status == "not-debt"
             then "the tech-debt register records it \($status)"
             else null end
         end) as $reason
      | select($reason != null)
      | {repo: $repo, item: $item, reason: $reason} ]' 2>/dev/null || true)"
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}
