#!/usr/bin/env bash
#
# lib/refinement.sh — under-specification as a class of block: what the
# Co-Ordinator must produce to report one, what the Script records, which items
# the label is projected onto, and how many refinements one Enabler engagement
# takes on (requirements 16a, 34e, 35d, 36b).
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
# can only ever reach one of those sources. A pipeline that read the label would
# therefore see a sixth of its own state and would be wrong about the rest in a
# way that reads as correct. So the shared log is the record; the label is
# applied by the Script when the item happens to be an issue, removed when the
# block clears, and never read back. Its whole job is to tell a human browsing
# the issue list what the pipeline already knows.
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
