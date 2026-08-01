#!/usr/bin/env bash
#
# lib/refinement.sh — under-specification as a class of block: what the
# Co-Ordinator must produce to report one, what the Script records, which items
# the label is projected onto, how a human's own hand-applied label is read
# back, and how many refinements one Enabler engagement takes on (requirements
# 16a, 34e, 34g, 35d, 36b).
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

# refinement_block_fields ENTRY_JSON [LABEL]
# Print the extra fields the `attempt-failed` event carries for this block
# (requirement 34e): the `kind` marker, the entry's `missing` promoted to
# `unblock_condition` — it is exactly what a later Co-Ordinator or the Enabler
# reads to judge whether the item has since become selectable — the `evidence`
# and the reporting `source`, plus `needs_refinement_label` when the Script
# actually managed to apply the label.
#
# The label is recorded on the event, not assumed from config, because it is
# what a later cycle removes: a label the Script did not apply is one it must
# not claim to have removed, and config may have changed in between.
#
# `$lbl`, not `$label`: `label` is a jq keyword, and a program that fails to
# compile here would silently record a block with no fields at all — the same
# trap `maybe_run_enabler` documents at its own jq call.
refinement_block_fields() {
  local entry="$1" label="${2:-}"
  jq -nc --argjson e "$entry" --arg kind "$REFINEMENT_BLOCK_KIND" --arg lbl "$label" '
    {kind: $kind,
     unblock_condition: ($e.missing // ""),
     evidence: ($e.evidence // ""),
     source: ($e.source // "")}
    + (if $lbl == "" then {} else {needs_refinement_label: $lbl} end)' \
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
  local labelled="${1:-[]}" blocked="${2:-[]}" out
  out="$(jq -nc --argjson l "$labelled" --argjson b "$blocked" '
    [ $l[]?
      | select(((.state // "open") == "open"))
      | select(((.repo // "") != "") and ((.number // "") != ""))
      | . as $e
      | select(
          ($b | any(.[]?;
                     (.repo // "") == ($e.repo // "") and
                     ((.item // "") | tostring) == (($e.number // "") | tostring))) | not
        )
    ]' 2>/dev/null || true)"
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
  local labelled="${1:-[]}" blocked="${2:-[]}" out
  out="$(jq -nc --argjson l "$labelled" --argjson b "$blocked" --arg kind "$REFINEMENT_BLOCK_KIND" '
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
    ] | unique' 2>/dev/null || true)"
  [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || out='[]'
  printf '%s' "$out"
}
