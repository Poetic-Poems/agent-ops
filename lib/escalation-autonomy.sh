#!/usr/bin/env bash
#
# lib/escalation-autonomy.sh — the `escalation_autonomy` trust ladder
# (D18 pattern, agent-ops#627): whether the Enabler's refinement-disagreement
# escalations (requirement 36b) go straight to a human, or are adjudicated
# once first.
#
# `escalation_autonomy` is a top-level config key with a per-repo override
# inside `repos[]` — the same `stage_timeouts`/`merge_autonomy` precedence
# pattern (requirement 4f) `lib/merge-autonomy.sh`'s own
# `merge_autonomy_configured_level` already applies: a repo's own entry wins
# when present, the top-level key otherwise, `always-escalate` (today's
# behaviour, byte-for-byte) failing that.
#
# Deliberately narrower than `lib/merge-autonomy.sh`: there is no kill switch
# and no `_effective_level` layer here. `adjudicate-first` never lets the
# Script act with less human oversight than `always-escalate` already
# does — it only ever *replaces* one escalation with one adjudication pass
# that itself either confirms the earlier refinement (an outcome
# `always-escalate` would have reached too, just slower, once the human
# read the same evidence) or escalates anyway. There is nothing here for a
# kill switch to override.

# escalation_autonomy_configured_level CONFIG_JSON SLUG
# The level `config.json` (already schema-defaulted, or not — an absent
# top-level key reads as "always-escalate" either way) names for SLUG: that
# repo's own `escalation_autonomy` entry in `repos[]` when set, else the
# top-level key, else `always-escalate`.
escalation_autonomy_configured_level() {
  local config_json="$1" slug="$2" repo_level top_level
  repo_level="$(jq -r --arg slug "$slug" \
    '(.repos // [])[] | select(.slug == $slug) | .escalation_autonomy // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_level" && "$repo_level" != "null" ]]; then
    printf '%s' "$repo_level"
    return 0
  fi
  top_level="$(jq -r '.escalation_autonomy // "always-escalate"' <<<"$config_json" 2>/dev/null)"
  [[ -n "$top_level" && "$top_level" != "null" ]] || top_level="always-escalate"
  printf '%s' "$top_level"
}

# escalation_autonomy_adjudicated_before REPO ITEM < union.jsonl
# Exit 0 when an `enabler-adjudication` event for REPO+ITEM already exists in
# the log on stdin — this item's one adjudication pass has been spent — and 1
# otherwise. The item match is `ENABLER_ELIGIBLE_JQ`'s own `same_item`: the id
# must match, and the repo must match or be absent, so an event written before
# the field existed still counts against its item rather than silently
# granting a second pass.
#
# The bound requirement 36b states (agent-ops#627, "bounded, not a loop"), on
# the Script's side of the boundary and mechanical for exactly the reason the
# thrash guard beside it is: an `adequate` verdict clears the block and
# re-records the *existing* refinement, so the item comes back selectable with
# `refined_before` still set — and a re-flag of it reaches the same `escalate`
# verdict, over the same evidence, that an adjudication pass has already
# answered once. Without this, the pass that answered it would simply run
# again and answer it the same way, and the disagreement the thrash guard
# escalates would loop between two models forever with nobody paged.
#
# The caller's one exemption is the thrash guard's own: eligibility
# `reason: "issue-closed"`, which exists only because a human acted on an
# escalation about this item (requirement 35a), so the pass it authorises is
# the first since they did — one per item, per human touch.
escalation_autonomy_adjudicated_before() {
  local repo="$1" item="$2" hits
  hits="$(jq -r -R -n --arg r "$repo" --arg i "$item" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "enabler-adjudication"
               and (.item // "") == $i
               and ((.repo // "") == "" or (.repo // "") == $r)) ]
    | length
  ' 2>/dev/null || echo 0)"
  [[ "$hits" =~ ^[0-9]+$ ]] && (( hits > 0 ))
}
