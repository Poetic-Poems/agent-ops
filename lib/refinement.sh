#!/usr/bin/env bash
#
# lib/refinement.sh — under-specification as a class of block: what the
# Co-Ordinator must produce to report one, what the Script records, which items
# the labels are projected onto, how a human's own hand-applied label is read
# back, and how many refinements one Enabler engagement takes on (requirements
# 16a, 34e, 34g, 35d, 36b, 38b).
#
# ## The gap this closes
#
# Requirement 17 tells the Co-Ordinator to skip an item it cannot rank against
# the "adequately refined" bar, and requirement 16 tells it to skip an item
# gated on a decision only a human can make. Both skips were silent. The item
# was re-read and re-skipped every cycle, for as long as it existed, with
# nothing recorded and nobody told — the pipeline paying to rediscover the same
# non-answer hourly, and the one person who could fix it never learning the item
# was starving. The failure has this system's signature shape: nothing looks
# broken.
#
# A label alone turned out to be half the fix, the first time round:
# agent-ops#203 was exactly this shape and labelled correctly, yet sat
# invisible because nothing else made it findable. Requirement 38b closed that
# second half by *assigning* the issue to `enabler_assignee` alongside the
# label — until agent-ops#639: assignment as bookkeeping meant "on hold" and
# "a human must personally act" were the same signal on GitHub, so the
# projection could never be told apart from a genuine escalation
# (requirement 36a) or a human's own claim, and stale ones went uncorrected —
# 21 of them, by 2026-08-21. `blocked` plus a reason label
# (`blocked:needs-refinement` today, the only kind this projection covers) is
# the second half now: two labels, applied and removed exactly where the
# assignment used to be, that reach the same Assigned-to-me visibility problem
# without occupying the one signal requirement 36a's genuine escalations still
# need for themselves.
#
# ## Why a block rather than a new state
#
# Because everything the escape path needs already exists for blocked items.
# Selection exclusion (requirement 16.1), Enabler eligibility and its threshold
# (35a), the claim that stops two nodes examining one item (35c), the escalation
# protocol and its duplicate guard (36a), the issue-closed recheck — all of it
# keys on `attempt-failed`/`unblocked` and none of it needs to know why the item
# stopped. A parallel state would have to re-earn every one of those properties,
# and would earn them slightly differently. So a refinement block *is* an
# `attempt-failed`, marked `kind: "needs-refinement"` so the stages that care can
# tell, and invisible to the stages that do not.
#
# The built-in delay is a feature, not a cost of the reuse: the threshold gives
# the human, or the Co-Ordinator's own cheap re-check (requirement 18), several
# cycles to settle the item before the expensive stage is bought.
#
# ## Why the label is a projection and never the record
#
# Work items here are heterogeneous — issues, `TECH-DEBT.md` rows, review
# recommendations, findings, plan tasks, per-round PR refs — and a GitHub label
# can only ever reach one of those sources. A pipeline that read the label as
# its record of *every* item's state would therefore see a sixth of its own
# state and would be wrong about the rest in a way that reads as correct. So
# the shared log stays the record for a block the Co-Ordinator reported: the
# label the Script projects onto it is applied when the item happens to be an
# issue, removed when the block clears, and never read back.
#
# ## Reading the label back for the one writer who cannot use the log
# (requirement 34g)
#
# That rule is deliberately narrower than "never read back" sounds, because it
# was written to describe the Script's *own* projection, and it leaves the one
# person the whole mechanism serves with no way to invoke it: a human reading
# an issue has no `needs_refinement` entry to hand the Co-Ordinator, and no
# `state_dir/log.jsonl` to append to from a browser (the same gap requirement
# 34f closes for a void). Applying the label by hand does nothing, and looks
# exactly like it worked.
#
# So a hand-applied label is a second, narrower kind of report, read back only
# for the blocks it creates. `refinement_hand_flag_new` turns a labelled,
# open issue with no block yet into an `attempt-failed` exactly like a
# Co-Ordinator's `needs_refinement` entry would — `refinement_hand_flag_fields`
# builds it, marked `hand_flagged: true` so the block is traceable to a human
# rather than a model. `refinement_hand_flag_cleared` is the reverse: an issue
# whose block carries that marker but has lost the label maps to the existing
# hand-appended `unblocked` path (requirement 18), because a human taking the
# label off while the block is open is asking for exactly that.
#
# The marker is what keeps this from becoming the wider read-back the design
# note above rejects. A block the Script itself projected the label onto (a
# Co-Ordinator's report) carries no `hand_flagged` field, so removing that
# label — by hand, by mistake, or by whatever the repo's own automation does —
# clears nothing here: that block's lifecycle is still the one-way projection
# it always was, cleared only by the Co-Ordinator's re-check or the Enabler.
# Reading the label back for *every* refinement block, not just the ones a
# human created with it, would silently reopen a block a model is still
# working on the moment anything touches its label — the "reconciliation path
# the current design gets to live without" that made this a deferred decision
# rather than an omission (`TECH-DEBT.md` TD26072602).
#
# Eligibility asks nothing new of a hand-flagged block. Requirement 35a
# already treats the `kind` marker as informational for every clause but the
# threshold — a hand-flagged block crosses the same
# `refinement_after_coordinator_cycles` threshold as a Co-Ordinator's own
# refinement block, because both carry `kind: "needs-refinement"` and the rule
# reads only that. Carving out a faster (or slower) path for this one origin
# would be the exact exception 35a's own design note declines to make, and
# there is no fleet evidence that a human's label needs different pacing than
# a model's report.
#
# Requires `lib/void-guard.sh` (for `entry_field_text`) to be sourced first, as
# agent-cycle.sh does. Sourced, never executed: it sets no shell options,
# because agent-cycle.sh runs under `set -euo pipefail`.
#
# Environment:
#   REFINEMENT_GH  override `gh` (tests stub it).

# The marker that distinguishes a refinement block from every other
# `attempt-failed` (requirement 33's event vocabulary). One constant, because
# the Script writes it, the eligibility rule carries it, and the engagement cap
# selects on it.
REFINEMENT_BLOCK_KIND="needs-refinement"

# The generic hold marker (requirement 38b, agent-ops#639): fixed and
# unconfigurable, the same as `scripts/gather-issues.sh`'s own hardcoded
# `blocked` exclusion check, so the two can never drift apart by a renamed
# config key.
# shellcheck disable=SC2034  # read by agent-cycle.sh and scripts/sweep-legacy-refinement-assignees.sh, which source this file
REFINEMENT_BLOCKED_LABEL="blocked"

# refinement_blocked_reason_label KIND
# Print the `blocked:<reason>` label a block of KIND earns (requirement 38b's
# taxonomy, agent-ops#639), or nothing for a KIND with no reason label of its
# own. `needs-refinement` is the only kind this projection covers today —
# every block requirement 38b projects onto an issue is one the Co-Ordinator,
# the Refiner or the Implementer reported through `record_needs_refinement_block`,
# and all three mark it `kind: "needs-refinement"` — so this is a one-entry
# table, not a placeholder: a future block class that earns its own reason
# label extends the `case` here, not the caller.
#
# Fixed and unconfigurable, like `REFINEMENT_BLOCKED_LABEL` above: an
# installation cannot rename `blocked:needs-refinement` any more than it can
# rename `blocked` itself.
refinement_blocked_reason_label() {
  case "$1" in
    "$REFINEMENT_BLOCK_KIND") printf 'blocked:needs-refinement' ;;
    *) printf '' ;;
  esac
}

# refinement_entry_problem ENTRY_JSON
# Decide whether one `needs_refinement` entry may be recorded as a block.
#
# Prints nothing and returns 0 when it may. Prints a one-line reason and returns
# 1 when it may not — written to read in a log event and on the dashboard
# without the reader reconstructing the cycle.
#
# The bar is the same one requirement 34d sets for a `voided` entry, and for the
# same reason: a report is an assertion about an item the Co-Ordinator read, and
# an assertion with nothing behind it is an opinion. `evidence` says what it
# actually read, `missing` is the whole of what the Enabler starts from, and
# `repo`/`item` are what requirement 34 keys the block on — an entry naming no
# item blocks nothing at all.
refinement_entry_problem() {
  local entry="$1" field
  for field in repo item reason missing evidence; do
    [[ -n "$(entry_field_text "$entry" "$field")" ]] && continue
    case "$field" in
      repo)   printf 'names no repo, and requirement 34 keys a block on repo and item together' ;;
      item)   printf 'names no item, and an event carrying no item blocks nothing' ;;
      reason) printf 'gives no reason for failing the selection bar' ;;
      missing)
        printf 'says nothing about what is missing, so there is nothing for the Enabler to refine towards' ;;
      evidence)
        printf 'cites no evidence, and an unevidenced report is an opinion rather than a finding' ;;
    esac
    return 1
  done
  return 0
}

# refinement_issue_number ENTRY_JSON
# Print the issue number this entry's label projection applies to, or nothing.
#
# Only the `issues` source has an issue behind it; a tech-debt row, a review
# recommendation, a finding and a plan task have nowhere to put a label. An
# entry that names no source is judged on the ref's shape alone, since a bare
# number is the `issues` source's ref and every other source's is prefixed.
refinement_issue_number() {
  jq -r 'if ((.source // "issues") == "issues")
           and (((.item // "") | tostring) | test("^[0-9]+$"))
         then ((.item // "") | tostring) else empty end' <<<"$1" 2>/dev/null || true
}

# refinement_block_fields ENTRY_JSON [LABEL] [BLOCKED_LABEL] [BLOCKED_REASON_LABEL]
# Print the extra fields the `attempt-failed` event carries for this block
# (requirement 34e): the `kind` marker, the entry's `missing` promoted to
# `unblock_condition` — it is exactly what a later Co-Ordinator or the Enabler
# reads to judge whether the item has since become selectable — the `evidence`
# and the reporting `source`, plus `needs_refinement_label` when the Script
# actually managed to apply the label, and `blocked_label`/`blocked_reason_label`
# when it actually managed to apply each of those (requirement 38b,
# agent-ops#639).
#
# All three labels are recorded on the event, not assumed from config or from
# the fixed literals above, because they are what a later cycle removes: a
# label the Script did not apply is one it must not claim to have removed, and
# `needs_refinement_label` in particular is configurable — it may have changed
# in between.
#
# `$lbl`, not `$label`: `label` is a jq keyword, and a program that fails to
# compile here would silently record a block with no fields at all — the same
# trap `maybe_run_enabler` documents at its own jq call.
refinement_block_fields() {
  local entry="$1" label="${2:-}" blocked_label="${3:-}" blocked_reason_label="${4:-}"
  jq -nc --argjson e "$entry" --arg kind "$REFINEMENT_BLOCK_KIND" \
    --arg lbl "$label" --arg bl "$blocked_label" --arg brl "$blocked_reason_label" '
    {kind: $kind,
     unblock_condition: ($e.missing // ""),
     evidence: ($e.evidence // ""),
     source: ($e.source // "")}
    + (if $lbl == "" then {} else {needs_refinement_label: $lbl} end)
    + (if $bl == "" then {} else {blocked_label: $bl} end)
    + (if $brl == "" then {} else {blocked_reason_label: $brl} end)' \
    2>/dev/null || printf '{}'
}

# refinement_label_targets BLOCKED_JSON ITEM [REPO]
# Print, one per line as `<repo>\t<number>\t<label>`, every open refinement
# block for ITEM whose event records a projected label.
#
# BLOCKED_JSON is requirement 34's blocked extract, which is where the label's
# lifecycle is read from: the label mirrors the block, so the block record is
# the only thing that can say which issue carries one. REPO empty matches every
# repo, because the Co-Ordinator reports an `unblocked` as a bare item id
# (requirement 18) and a human appending one by hand has no repo either — the
# same over-clearing requirement 34 chooses, and harmless here, since the only
# issues reachable are ones this system labelled itself.
refinement_label_targets() {
  local blocked="$1" item="$2" repo="${3:-}"
  jq -r --arg it "$item" --arg repo "$repo" --arg kind "$REFINEMENT_BLOCK_KIND" '
    [ .[]?
      | select((.kind // "") == $kind)
      | select($it != "" and (((.item // "") | tostring) == $it))
      | select((.repo // "") != "")
      | select($repo == "" or (.repo // "") == $repo)
      | select((.needs_refinement_label // "") != "")
      | select(((.item // "") | tostring) | test("^[0-9]+$"))
      | "\(.repo)\t\(.item)\t\(.needs_refinement_label)" ]
    | unique | .[]' <<<"$blocked" 2>/dev/null || true
}

# refinement_blocked_label_targets BLOCKED_JSON ITEM [REPO]
# Print, one per line as `<repo>\t<number>\t<label>`, every `blocked`/
# `blocked:<reason>` label an open refinement block for ITEM carries
# (requirement 38b, agent-ops#639). Same shape and the same reasoning as
# `refinement_label_targets` — read that comment for why REPO empty matches
# every repo — extended to two possible label fields per block rather than
# one, since a block projects both `blocked_label` and `blocked_reason_label`
# together.
#
# A *legacy* block — one recorded before agent-ops#639, whose event carries
# `needs_refinement_assignee` and neither blocked-label field — yields only
# the reason label, never the generic `blocked`. `blocked:<reason>` is safe
# regardless: no human reaches for that compound name on their own, so
# `scripts/sweep-legacy-refinement-assignees.sh` can only ever have applied
# it, unconditionally, exactly as the fresh path does. `blocked` is not: it
# is a human's own, hand-applied control (`lib/labels.sh`'s own catalogue),
# and the sweep — like the fresh path — projects it through
# `refinement_label_project`'s read-before-write rather than an unconditional
# add. But unlike the fresh path, the sweep has no event of its own to record
# which of `added`/`present` actually happened: it does not rewrite the
# block's original `attempt-failed` event (nothing rewrites history), so a
# legacy block's `blocked_label` field can never be filled the way a fresh
# block's is. Treating every legacy block as carrying the generic `blocked`
# regardless — the way this once read — would let `release_refinement_label`
# remove a `blocked` a human applied for their own reasons on any issue that
# happens to also carry a still-open pre-agent-ops#639 block: the exact
# defect `refinement_label_project` exists to prevent, reappearing on the one
# path that cannot prove its own history. So a legacy block's `blocked` is
# left alone here — over-held rather than guessed at, the same trade-off
# `refinement_label_project` already makes for an unreadable label list — and
# comes off only by a human's own hand. A legacy block whose issue the sweep
# has not reached yet costs one `gh` call that finds nothing to remove, and a
# warning: the same best-effort contract every other removal on this path
# already has.
refinement_blocked_label_targets() {
  local blocked="$1" item="$2" repo="${3:-}" reason_label
  reason_label="$(refinement_blocked_reason_label "$REFINEMENT_BLOCK_KIND")"
  jq -r --arg it "$item" --arg repo "$repo" --arg kind "$REFINEMENT_BLOCK_KIND" \
     --arg reason "$reason_label" '
    [ .[]?
      | select((.kind // "") == $kind)
      | select($it != "" and (((.item // "") | tostring) == $it))
      | select((.repo // "") != "")
      | select($repo == "" or (.repo // "") == $repo)
      | select(((.item // "") | tostring) | test("^[0-9]+$"))
      | . as $e
      | ( if (($e.blocked_label // "") == "" and ($e.blocked_reason_label // "") == ""
              and ($e.needs_refinement_assignee // "") != "")
          then [$reason]
          else [$e.blocked_label, $e.blocked_reason_label] end
          | map(select((. // "") != ""))
          | .[]
          | "\($e.repo)\t\($e.item)\t\(.)" ) ]
    | unique | .[]' <<<"$blocked" 2>/dev/null || true
}

# refinement_blocked_label_stale BLOCKED_JSON [LOG_FILE]
# Print, one per line as `<repo>\t<item>\t<label>`, every `blocked`/
# `blocked:<reason>` label whose own-label-action history's most recent
# action for that repo+item+label is `add` — a removal either never attempted
# or attempted and silently failed (`release_refinement_label`, which
# tolerates the failure by design) — where the item is not currently in
# BLOCKED_JSON, i.e. its block has since cleared. Reads LOG_FILE, or stdin if
# it is omitted or "-", the same convention `lib/cycle-state.sh`'s
# `blocked_items` uses.
#
# Unlike `needs_refinement_label`'s stale-retry (`label_own_stale_applications`,
# requirement 39f), no live GitHub read or own/human attribution heuristic is
# needed here: `blocked`/`blocked:<reason>` are never applied by this pipeline
# except through `refinement_label_project`'s read-before-write (the generic
# label) or `record_needs_refinement_block`'s unconditional add (the fixed
# reason label) — never by a human's own hand, which is exactly what
# `refinement_label_project` exists to keep true for `blocked` too — so a
# logged `own-label-action add` with no later `remove` is proof enough on its
# own that a removal is ours to retry, with no `labelled_at` comparison
# required.
refinement_blocked_label_stale() {
  local blocked="${1:-[]}" src="${2:--}" log_json docs
  [[ -n "$blocked" ]] || blocked='[]'
  if [[ "$src" == "-" ]]; then
    log_json="$(jq -c -R 'fromjson? // empty' 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    log_json="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  fi
  [[ -n "$log_json" ]] || log_json='[]'
  docs="$log_json"$'\n'"$blocked"
  jq -nr '
    input as $log | input as $b |
    ($b | map((((.repo // "") | tostring)) + "|" + (((.item // "") | tostring)))) as $open |
    [ $log[]?
      | select((.event // "") == "own-label-action")
      | select((.label // "") == "blocked" or ((.label // "") | startswith("blocked:")))
      | select((.repo // "") != "" and ((.item // "") | tostring) != "") ]
    | group_by([(.repo // ""), ((.item // "") | tostring), (.label // "")])
    | map(sort_by(.ts) | last)
    | map(select((.action // "") == "add"))
    | map(select( ((((.repo // "") | tostring) + "|" + ((.item // "") | tostring)) as $k
                  | ($open | index($k)) == null) ))
    | .[]
    | "\(.repo)\t\(.item)\t\(.label)"' <<<"$docs" 2>/dev/null || true
}

# refinement_label_add REPO NUMBER LABEL
# refinement_label_remove REPO NUMBER LABEL
# Project the label onto an issue, or take it off again. Return non-zero when
# `gh` would not do it — a repo where the label was never created is the common
# case, and the caller records the block regardless: losing the projection costs
# a human's filter, losing the block would cost the item its escape path.
refinement_label_add() {
  local repo="$1" number="$2" label="$3" gh_bin="${REFINEMENT_GH:-gh}"
  [[ -n "$repo" && -n "$number" && -n "$label" ]] || return 1
  "$gh_bin" issue edit "$number" -R "$repo" --add-label "$label" >/dev/null 2>&1
}

refinement_label_remove() {
  local repo="$1" number="$2" label="$3" gh_bin="${REFINEMENT_GH:-gh}"
  [[ -n "$repo" && -n "$number" && -n "$label" ]] || return 1
  "$gh_bin" issue edit "$number" -R "$repo" --remove-label "$label" >/dev/null 2>&1
}

# refinement_label_project REPO NUMBER LABEL
# Put LABEL on the issue iff it is not already there, and say whether the
# resulting label is this projection's to remove later. Mirrors the deleted
# `refinement_assignee_project`'s read-before-write contract (agent-ops#651):
# `gh issue edit --add-label` succeeds as a no-op on an issue that already
# carries the label, so an unconditional add-and-record would later let
# `release_refinement_label` remove a label a human applied for their own
# reasons before this block ever existed — precisely the defect the deleted
# assignee projection's read existed to prevent, needed here for `blocked`
# because `lib/labels.sh`'s own catalogue still documents it as the human's
# own, hand-applied control (a repository without the label offers no way to
# say "not this one"), so a pipeline-projected `blocked` and a human's own can
# land on the same issue. `blocked:<reason>` does not need this: no human
# reaches for that compound name on their own, so its lifecycle stays
# unconditional, the same as `needs_refinement_label`'s.
#
# Prints one word, exactly the shape `refinement_assignee_project` used:
#   added       LABEL was absent and is now on the issue — record it, so the
#               block's clearing takes it off again.
#   present     LABEL was already on the issue. Nothing is touched and
#               nothing must be recorded.
#   unrecorded  the issue's labels could not be read, so the add was
#               attempted best-effort but must not be recorded — over-holding
#               a label is cosmetic; removing one that may have pre-existed is
#               the defect this function exists to prevent.
#   failed      the list was readable, LABEL was absent, and the add would not
#               take (a repo where the label was never created is the
#               practical case) — same contract as `refinement_label_add`: the
#               caller records the block regardless.
#
# Exit status is 0 for `added` and `present` (the projection is healthy), 1
# for `unrecorded` and `failed`.
refinement_label_project() {
  local repo="$1" number="$2" label="$3" gh_bin="${REFINEMENT_GH:-gh}" existing
  if [[ -z "$repo" || -z "$number" || -z "$label" ]]; then
    printf 'failed'
    return 1
  fi
  if ! existing="$("$gh_bin" issue view "$number" -R "$repo" --json labels \
                     --jq '.labels[].name' 2>/dev/null)"; then
    refinement_label_add "$repo" "$number" "$label" || true
    printf 'unrecorded'
    return 1
  fi
  if grep -qxF "$label" <<<"$existing"; then
    printf 'present'
    return 0
  fi
  if refinement_label_add "$repo" "$number" "$label"; then
    printf 'added'
    return 0
  fi
  printf 'failed'
  return 1
}

# refinement_assignee_remove REPO NUMBER ASSIGNEE
# Take an assignment off an issue. The only surviving half of what used to be
# a pair (`refinement_assignee_add`/`refinement_assignee_project` are gone,
# agent-ops#639): requirement 38b no longer assigns anything, so nothing here
# adds an assignment any more — this is now purely
# `scripts/sweep-legacy-refinement-assignees.sh`'s primitive, for undoing the
# stale assignments the old projection left behind on issues whose block is
# still open. Same failure contract as the label functions above: a repo
# where the assignee is not a valid collaborator, or is simply not currently
# assigned, is the practical no-op case, and the caller carries on regardless.
refinement_assignee_remove() {
  local repo="$1" number="$2" assignee="$3" gh_bin="${REFINEMENT_GH:-gh}"
  [[ -n "$repo" && -n "$number" && -n "$assignee" ]] || return 1
  "$gh_bin" issue edit "$number" -R "$repo" --remove-assignee "$assignee" >/dev/null 2>&1
}

# refinement_engagement_set ELIGIBLE_JSON MAX
# Print the eligible items one engagement takes on (requirement 35d): every
# ordinary blocked item, plus at most MAX refinement-class items, in the input's
# own order.
#
# Two properties are load-bearing. Ordinary items are never dropped — the cap
# exists because the day-one backlog of items that were silently skipped for
# months is unbounded, and an engagement that spent itself on those instead of
# the pull request nobody can see would have made things worse. And the survivors
# are chosen by oldest block first, deterministically, so every node in the fleet
# picks the same ones and they contend on the same claims (requirement 35c)
# rather than each engaging a different third of the backlog.
#
# MAX of 0 removes the class from engagements entirely: the blocks are still
# recorded and the items still wait, which is a legitimate way to run this while
# a backlog is being cleared by hand. An unreadable MAX is treated as 0 — an
# unparseable setting is not a licence to spend, exactly as in requirement 35a.
refinement_engagement_set() {
  local eligible="$1" max="${2:-0}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=0
  jq -c --argjson max "$max" --arg kind "$REFINEMENT_BLOCK_KIND" '
    def key: (.repo // "") + "|" + ((.item // "") | tostring);
    ( [ .[] | select((.kind // "") == $kind) ]
      | sort_by(.blocked_ts // "")
      | .[0:$max]
      | map(key) ) as $keep
    | [ .[]
        | . as $e
        | select(((.kind // "") != $kind) or ($keep | index($e | key))) ]' \
    <<<"$eligible" 2>/dev/null || printf '%s' "$eligible"
}

# refinement_record_fields VERDICT_JSON
# Print the payload of the `item-refined` event this `unblocked` verdict earns
# (requirement 36b), or nothing when it earns none.
#
# Two shapes, because refinement has to land where a *future* Co-Ordinator will
# read it and that place differs by item type. For an issue the Enabler posts
# one authoritative comment, which the Co-Ordinator already pastes into the work
# order along with the rest of the thread — so the event records the comment URL
# as a pointer. For every other item type there is no thread to write into, so
# the spec itself travels in the log and requirement 3h injects it into the
# Co-Ordinator's runtime input.
#
# Nothing at all means the Enabler unblocked a refinement item without refining
# it, which the caller records as a warning: the block clears, the item returns
# to the pool exactly as under-specified as before, and the next Co-Ordinator
# reports it again.
refinement_record_fields() {
  jq -c '
    ((.refined_spec // "") | if type == "string" then . else tojson end) as $spec
    | (((.comments_posted // []) | if type == "array" then (.[0] // "") else "" end)
       | tostring) as $url
    | if $spec == "" and $url == "" then empty
      else (if $spec == "" then {} else {spec: $spec} end)
           + (if $url == "" then {} else {comment_url: $url} end)
      end' <<<"$1" 2>/dev/null || true
}

# refinement_second_pass_refused ENTRY_JSON VERDICT_JSON
# The thrash guard (requirement 36b), on the Script's side of the boundary.
#
# Prints nothing and returns 0 when the verdict may stand. Prints a one-line
# reason and returns 1 when it may not: this item was refined once already, no
# human has touched it since, and the Enabler is offering a second refinement.
#
# One refinement per item per human touch. A cheap model re-flagging an item an
# expensive one has already specified is a disagreement between two models, and
# the way to settle it is to ask the person who owns the requirement — not to
# rewrite the spec and hand it back, which is a loop that terminates only when
# the two models happen to agree.
#
# The exemption is `issue-closed`, and it is the whole reason the guard can be
# mechanical rather than a plea in the prompt: that reason exists only because a
# human acted on an escalation about this item (requirement 35a), so the
# refinement it authorises is the *first* since they did. Everything else — a
# fresh threshold crossing, a recheck — is the same two models disagreeing
# again.
refinement_second_pass_refused() {
  local entry="$1" verdict="$2"
  local kind reason refined
  kind="$(jq -r '.kind // ""' <<<"$entry" 2>/dev/null || true)"
  [[ "$kind" == "$REFINEMENT_BLOCK_KIND" ]] || return 0
  [[ "$(jq -r '.verdict // ""' <<<"$verdict" 2>/dev/null || true)" == "unblocked" ]] || return 0
  refined="$(jq -r 'if (.refined_before // null) == null then "" else (.refined_before.ts // "unknown") end' \
               <<<"$entry" 2>/dev/null || true)"
  [[ -n "$refined" ]] || return 0
  reason="$(jq -r '.reason // ""' <<<"$entry" 2>/dev/null || true)"
  [[ "$reason" == "issue-closed" ]] && return 0
  printf 'refined once already at %s and no human has touched it since, so a second refinement is a disagreement only a human can settle' \
    "$refined"
  return 1
}

# refinement_is_disagreement ENTRY_JSON
# True (exit 0) iff ENTRY_JSON is a `needs-refinement` block that already
# carries a prior refinement (`refined_before` set) — the same shape
# `refinement_second_pass_refused` refuses a second `unblocked` verdict
# against, read here without the verdict/`issue-closed` conditions that
# function also checks, since this predicate is not about which verdict is
# allowed but about which *item* the disagreement is about.
#
# `escalation_autonomy`'s `adjudicate-first` setting (agent-ops#627) is this
# predicate's one caller: it decides whether an `escalate` verdict on this
# item is a genuine, fresh escalation or a re-flag of the same disagreement
# the thrash guard already knows about — the only shape a bounded adjudication
# pass can usefully judge, since it is the only one with a prior refinement to
# check the re-flag against.
refinement_is_disagreement() {
  local entry="$1" kind
  kind="$(jq -r '.kind // ""' <<<"$entry" 2>/dev/null || true)"
  [[ "$kind" == "$REFINEMENT_BLOCK_KIND" ]] || return 1
  [[ "$(jq -r 'if (.refined_before // null) == null then "" else "x" end' <<<"$entry" 2>/dev/null || true)" == "x" ]]
}

# refinement_hand_flag_new LABELLED_JSON BLOCKED_JSON
# Print, as a JSON array, the entries of LABELLED_JSON (the shape
# `scripts/gather-hand-flagged-refinements.sh` produces:
# `{repo, number, url, label, state, labelled_at, by}`) that need a fresh
# block: the issue is **open** and no block — of any kind, from any origin —
# is currently open for it (requirement 34g).
#
# Any existing block disqualifies the issue, not only a refinement one. That is
# the same rule `log_needs_refinement_items` applies to a Co-Ordinator's own
# report, and it is what "a label on an item already blocked for another
# reason" (`TECH-DEBT.md` TD26072602) resolves to: an item the Enabler is
# already holding is, by construction, already in BLOCKED_JSON, so it is never
# reported here either.
#
# A closed issue is excluded even though it may still carry the label —
# blocking a closed issue would earn it an Enabler engagement for a candidate
# the `issues` source, and the escalation-still-open eligibility test of
# requirement 35a, both already treat as unreachable. `state` empty (an older
# caller, or a test fixture) reads as open, matching the field's absence
# meaning "nothing said otherwise" everywhere else in this file.
#
# Always prints a valid array; malformed input yields `[]` rather than a
# non-zero status; the caller holds the fleet's lock and writes to the log
# unconditionally afterwards.
refinement_hand_flag_new() {
  local labelled="${1:-[]}" blocked="${2:-[]}" out docs
  # Both arrays arrive on stdin, one document per line, never in argv
  # (requirement 4g): the open blocked set grows with the fleet's history, and
  # past MAX_ARG_STRLEN an `--argjson` delivery makes this call fail into its
  # `2>/dev/null || true` — hand-applied refinement flags silently stop being
  # noticed.
  docs="$labelled"$'\n'"$blocked"
  out="$(jq -nc '
    input as $l | input as $b |
    [ $l[]?
      | select(((.state // "open") == "open"))
      | select(((.repo // "") != "") and ((.number // "") != ""))
      | . as $e
      | select(
          ($b | any(.[]?;
                     (.repo // "") == ($e.repo // "") and
                     ((.item // "") | tostring) == (($e.number // "") | tostring))) | not
        )
    ]' <<<"$docs" 2>/dev/null || true)"
  [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || out='[]'
  printf '%s' "$out"
}

# refinement_hand_flag_fields REPO NUMBER LABEL [BY] [LABELLED_AT] [URL]
# Print the extra fields a hand-flagged block's `attempt-failed` event carries
# (requirement 34g): the same `kind` marker as a Co-Ordinator's report, the
# label it was found under (so `refinement_label_targets` can take it off
# again through the existing lifecycle), and `hand_flagged: true` — the one
# field that distinguishes this origin from the Script's own projection, and
# the only thing `refinement_hand_flag_cleared` is allowed to act on.
#
# There is no `unblock_condition`: a Co-Ordinator's report promotes its
# `missing` field into one because that is what it was asked to write, but a
# human applying a label has said only "this needs specifying", not what is
# missing. An empty condition here is accurate, not a dropped field.
refinement_hand_flag_fields() {
  local repo="$1" number="$2" label="$3" by="${4:-}" at="${5:-}" url="${6:-}"
  jq -nc --arg kind "$REFINEMENT_BLOCK_KIND" --arg lbl "$label" --arg by "$by" \
    --arg at "$at" --arg url "$url" \
    '{kind: $kind, unblock_condition: "", source: "issues", hand_flagged: true}
     + (if $lbl == "" then {} else {needs_refinement_label: $lbl} end)
     + (if $by == "" then {} else {hand_flagged_by: $by} end)
     + (if $at == "" then {} else {hand_flagged_at: $at} end)
     + (if $url == "" then {} else {evidence: $url} end)' \
    2>/dev/null || printf '{}'
}

# refinement_hand_flag_cleared LABELLED_JSON BLOCKED_JSON
# Print, as a JSON array of `{repo, item}`, every open block that
# `refinement_hand_flag_new` created (`hand_flagged: true`) whose issue no
# longer appears — open or closed — in LABELLED_JSON: the human took the label
# off (requirement 34g).
#
# Scoped to `hand_flagged` blocks only, and that scoping is the whole point.
# A block the Script itself projected the label onto is not in this set, so a
# label removed from underneath one of those — by mistake, by the repo's own
# automation, by anything other than this mechanism — clears nothing here: its
# lifecycle stays the one-way projection requirement 34e always described.
# Reading the label back for every refinement block, regardless of who put it
# there, is the wider "second writer" this design deliberately declined
# (`TECH-DEBT.md` TD26072602) — it would let anything that touches the label
# reopen a block a model is still working from.
#
# A closed-but-still-labelled issue stays "labelled" here on purpose: the human
# has not withdrawn the flag, they have just closed the issue, and treating
# that as a removal would clear a block requirement 34g never earned the right
# to touch by itself.
refinement_hand_flag_cleared() {
  local labelled="${1:-[]}" blocked="${2:-[]}" out docs
  # Both arrays arrive on stdin, one document per line, never in argv
  # (requirement 4g): the open blocked set grows with the fleet's history, and
  # past MAX_ARG_STRLEN an `--argjson` delivery makes this call fail into its
  # `2>/dev/null || true` — hand-applied refinement flags silently stop being
  # cleared.
  docs="$labelled"$'\n'"$blocked"
  out="$(jq -nc --arg kind "$REFINEMENT_BLOCK_KIND" '
    input as $l | input as $b |
    [ $b[]?
      | select((.kind // "") == $kind)
      | select((.hand_flagged // false) == true)
      | select(((.repo // "") != "") and ((.item // "") != ""))
      | . as $e
      | select(
          ($l | any(.[]?;
                     (.repo // "") == ($e.repo // "") and
                     ((.number // "") | tostring) == (($e.item // "") | tostring))) | not
        )
      | {repo: $e.repo, item: $e.item}
    ] | unique' <<<"$docs" 2>/dev/null || true)"
  [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || out='[]'
  printf '%s' "$out"
}

# --- The Refiner (requirement 39) --------------------------------------------
#
# Everything above this line predates the Refiner and is unchanged by it: a
# refinement block is still recorded, aged, and cleared exactly as requirement
# 34e describes, whoever reports it. What follows is the Refiner's own half —
# finding items nobody has specified yet, before any of that machinery would
# otherwise engage — and it deliberately reuses `refinement_entry_problem`,
# `refinement_block_fields`, `refinement_label_add`/`_remove` and
# `refinement_blocked_reason_label` rather than duplicating them: a Refiner decline
# is recorded exactly the way a Co-Ordinator's `needs_refinement` report is
# (requirement 39d), because it is the same kind of block reaching the same
# escape hatch, just reported by a different stage.

# refiner_policy_value SOURCE POLICY_JSON
# Print the effective `refinement_policy` (requirement 39a) for SOURCE:
# "required", "preferred" or "exempt" — the default for any source the
# configuration's `refinement_policy` object does not name, which is every
# source until an installation opts one in.
refiner_policy_value() {
  local source="$1" policy="${2:-{\}}"
  jq -r --arg s "$source" '(. // {})[$s] // "exempt"' <<<"$policy" 2>/dev/null || printf 'exempt'
}

# refiner_candidate_items REPOS_JSON POLICY_JSON REFINEMENTS_JSON BLOCKED_JSON VOID_JSON CLAIMED_JSON
# Print, as a JSON array, every item from this cycle's pre-fetched source
# arrays — `findings`, `review_feedback`, `abandoned_drafts`, `merge_conflicts`,
# `dequeued`, `register_hygiene`, `issues`, `tech_debt`, `project_review`,
# `implementation_plan` — that the Refiner may spend an engagement on: its
# source's policy is not `exempt` (requirement 39a), it carries no refinement
# yet (REFINEMENTS_JSON, requirement 3h), and it is not already blocked,
# void, or held by an ordinary implementation claim — except an `issues`
# entry gather-issues.sh marked `priority_set: false`, which is a candidate
# even when already refined, solely for its missing `Priority` band
# (requirement 39g). Such an entry carries `triage_only: true` so the Refiner
# knows not to write a second specification for it.
#
# Each entry is `{repo, source, item, entry}` — `entry` is the gatherer's own
# object verbatim (an issue's full thread, a finding's title and severity, a
# tech-debt item's whole file), because the Refiner needs it to write a
# specification without a second fetch, the same reason the Co-Ordinator is
# handed it pre-fetched rather than told to query it.
#
# The first eight arrays are the same per-repo arrays requirement 3 assembles
# for the Co-Ordinator's own `ordered_repos_json`. `project_review` and
# `implementation_plan` are not: the Co-Ordinator still reads `reviews/…` and
# the plan document live (prompts/coordinator.md), so those two arrays exist
# only in the Refiner-only copy of the repos array `agent-cycle.sh` builds
# for this call (`refiner_repos_json`), narrower than the tech-debt-style
# pre-fetch and never folded into the Co-Ordinator's own input
# (TD-PPagop-26081307).
refiner_candidate_items() {
  local repos="${1:-[]}" policy="${2:-{\}}" refinements="${3:-{\}}" \
        blocked="${4:-[]}" void="${5:-[]}" claimed="${6:-[]}" docs
  # $refinements, $blocked, $void and $claimed are four of the five
  # aggregates requirement 4g names by name as growing with the fleet's
  # history (TD-PPagop-26081406); $repos already arrived on stdin. All five
  # travel there together now, one document per line, bound positionally
  # with `input as $name` in the order printed — never in argv, where past
  # MAX_ARG_STRLEN this call fails into its own `|| printf '[]'` and the
  # Refiner silently finds no candidates at all. $policy stays in argv: it is
  # the installation's own configuration, bounded by requirement 4g.
  docs="$(printf '%s\n' "$repos" "$refinements" "$blocked" "$void" "$claimed")"
  jq -nc --argjson policy "$policy" '
    input as $repos | input as $refinements | input as $blocked
    | input as $void | input as $claimed
    | def exempt($s): (($policy // {})[$s] // "exempt") == "exempt";
    def is_refined($repo; $item):
      (($refinements // {})[$repo][($item | tostring)] // null) != null;
    def is_blocked($repo; $item):
      $blocked | any(((.item // "") | tostring) == ($item | tostring)
                     and ((.repo // "") == "" or (.repo // "") == $repo));
    def is_void($repo; $item):
      $void | any(((.item // "") | tostring) == ($item | tostring)
                  and ((.repo // "") == "" or (.repo // "") == $repo));
    def is_claimed($repo; $item):
      $claimed | any((.repo // "") == $repo
                     and ((.item // "") | tostring) == ($item | tostring));
    # requirement 39g: an `issues` entry gather-issues.sh marked
    # `priority_set: false` is unbanded. When such an entry is *also* already
    # refined, it would otherwise never reach the Refiner again (is_refined
    # excludes it) — so a mechanical Priority triage would have to fall to a
    # human forever. `triage_only` lets it through solely for the band: the
    # existing exempt/blocked/void/claimed exclusions still bind unchanged,
    # only the is_refined exclusion is bypassed, and only for this reason.
    # An entry with no `priority_set` key at all (every source but `issues`,
    # and any `issues` entry gathered before this field existed) never
    # qualifies here. Deliberately `has("priority_set") and .priority_set ==
    # false` rather than `(.priority_set // null) == false`: the `//`
    # operator substitutes on a `false` left-hand side exactly as it does on
    # `null`, so the shorter form would collapse a real `priority_set: false`
    # into `null` and never match.
    def is_unbanded_issue($source; $e):
      $source == "issues" and ($e | has("priority_set")) and ($e.priority_set == false);
    [ $repos[] as $r
      | ($r.slug // "") as $repo
      | ( ($r.findings // [])[]?, ($r.review_feedback // [])[]?,
          ($r.abandoned_drafts // [])[]?, ($r.merge_conflicts // [])[]?,
          ($r.dequeued // [])[]?,
          ($r.register_hygiene // [])[]?, ($r.issues // [])[]?,
          ($r.tech_debt // [])[]?, ($r.project_review // [])[]?,
          ($r.implementation_plan // [])[]? )
      | . as $e
      | ($e.source // "") as $source
      | ($e.ref // "" | tostring) as $item
      | select($repo != "" and $source != "" and $item != "")
      | select(exempt($source) | not)
      | (is_refined($repo; $item)) as $refined
      | (is_unbanded_issue($source; $e) and $refined) as $triage_only
      | select($triage_only or ($refined | not))
      | select(is_blocked($repo; $item) | not)
      | select(is_void($repo; $item) | not)
      | select(is_claimed($repo; $item) | not)
      | {repo: $repo, source: $source, item: $item, entry: $e}
        + (if $triage_only then {triage_only: true} else {} end) ]
  ' <<<"$docs" 2>/dev/null || printf '[]'
}

# refiner_drop_unbandable_triage CANDIDATES_JSON UNRESOLVABLE_SLUGS_JSON
# Print CANDIDATES_JSON with every entry whose `triage_only` is `true` *and*
# whose `repo` appears in UNRESOLVABLE_SLUGS_JSON (a JSON array of the slugs
# the I/O wrapper named below found unbandable, by either route) removed,
# every other entry printed verbatim, order preserved (issue #511).
# A `triage_only` entry exists solely to let the Refiner band an
# already-refined issue (requirement 39g); when this token cannot resolve
# that repository's `Priority` field at all — or resolves it to a field
# carrying none of the four band names (issue #542) — the band can never be
# written, so the engagement it would cost has nothing it could achieve.
# Every other candidate from the same repository — and every candidate,
# `triage_only` or not, from a repository not named here — passes through
# unchanged.
#
# Pure and jq-only, so it is directly unit-testable; the live GraphQL check
# that produces UNRESOLVABLE_SLUGS_JSON lives in the I/O wrapper beside it,
# `refiner_filter_unbandable_triage` (agent-cycle.sh).
#
# Falls back to CANDIDATES_JSON unchanged on its own jq failure — never `[]`
# — on the same "an unchanged set is today's behaviour for one cycle; an
# empty one silently cancels every repository's refinement" terms as
# agent-cycle.sh's own TD-PPagop-26081407 fallbacks.
refiner_drop_unbandable_triage() {
  local candidates="${1:-[]}" unresolvable="${2:-[]}"
  jq -c --argjson u "$unresolvable" \
    '[ .[] | . as $e | ($e.repo // "") as $r
       | select((($e.triage_only == true) and (($u | index($r)) != null)) | not) ]' \
    <<<"$candidates" 2>/dev/null || printf '%s' "$candidates"
}

# refiner_engagement_set CANDIDATES_JSON MAX
# Reduce CANDIDATES_JSON to at most MAX entries, sorted by `repo`, `source`
# then `item` — deterministic, so every node in the fleet reduces to the same
# set and they contend on the same claims rather than each engaging a
# different slice of the backlog (the same reasoning as requirement 35d's cap
# for the Enabler, over a set with no `blocked_ts` to order by instead).
#
# MAX of 0 removes the class from engagements entirely: candidates are simply
# left unrefined and reconsidered next cycle. An unreadable MAX is treated as
# 0, on the same "not a licence to spend" terms as `refinement_engagement_set`.
refiner_engagement_set() {
  local candidates="${1:-[]}" max="${2:-0}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=0
  jq -c --argjson max "$max" 'sort_by(.repo, .source, .item) | .[0:$max]' \
    <<<"$candidates" 2>/dev/null || printf '[]'
}
