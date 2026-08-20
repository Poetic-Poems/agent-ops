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

ESCALATION_AUTONOMY_LEVELS=(always-escalate adjudicate-first)

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
