#!/usr/bin/env bash
#
# lib/escalation-autonomy.sh — the `escalation_autonomy` trust ladder
# (D18 pattern, agent-ops#627, agent-ops#936): three rungs, each including the
# one below it. `always-escalate` sends every Enabler `escalate` verdict
# straight to a human. `adjudicate-first` runs one bounded adjudication pass
# first, but only over a refinement disagreement (requirement 36b) — the
# narrowest shape a pass with only two answers (`adequate`/`inadequate`) can
# usefully judge. `decide-tactical` runs one bounded *decide* pass first over
# every `escalate` verdict, refinement disagreement or not, with three answers
# (`settle`/`decide`/`escalate`) — see `prompts/enabler-decide.md` and
# `run_enabler_decide` (lib/enabler.sh).
#
# `escalation_autonomy` is a top-level config key with a per-repo override
# inside `repos[]` — the same `stage_timeouts`/`merge_autonomy` precedence
# pattern (requirement 4f) `lib/merge-autonomy.sh`'s own
# `merge_autonomy_configured_level` already applies: a repo's own entry wins
# when present, the top-level key otherwise, `always-escalate` (today's
# behaviour, byte-for-byte) failing that.
#
# Deliberately narrower than `lib/merge-autonomy.sh`: there is no kill switch
# and no `_effective_level` layer here. Neither `adjudicate-first` nor
# `decide-tactical` ever lets the Script act with less human oversight than
# `always-escalate` already does — each only ever *replaces* one escalation
# with one bounded pass that itself either settles the item on the strength of
# evidence a human would have reached the same way, just slower, or escalates
# anyway. There is nothing here for a kill switch to override.

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
#
# Scoped to `adjudicate-first`'s own passes: an `enabler-adjudication` event
# carrying `pass: "decide-tactical"` (agent-ops#936) is excluded, so a
# repository that has moved between the two rungs never has one rung's bound
# spent by the other's history. An event with no `pass` field at all — every
# one this function's own bound ever wrote before decide-tactical existed —
# still counts, on the same "field absent, event still counts" tolerance the
# repo-less match above already gives a pre-#815 event.
escalation_autonomy_adjudicated_before() {
  local repo="$1" item="$2" hits
  hits="$(jq -r -R -n --arg r "$repo" --arg i "$item" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "enabler-adjudication"
               and (.pass // "adjudicate-first") != "decide-tactical"
               and (.item // "") == $i
               and ((.repo // "") == "" or (.repo // "") == $r)) ]
    | length
  ' 2>/dev/null || echo 0)"
  [[ "$hits" =~ ^[0-9]+$ ]] && (( hits > 0 ))
}

# escalation_autonomy_decide_reason_key ENTRY_JSON
# A short, stable fingerprint of *why* ENTRY_JSON's `escalate` verdict is in
# front of the Script — the re-flag's own words, not the item's identity —
# used to tell a fresh reason from a repeat of one already decided (D18,
# agent-ops#936, requirement 36d's "per-reason" bound). Built from `detail`
# and `unblock_condition` (the same two fields `prompts/enabler-adjudicate.md`
# already reads as "the re-flag's own stated reason"), lower-cased and
# whitespace-collapsed so two engagements paraphrasing the same wording still
# hash to the same key, then SHA-256'd and truncated to 16 hex characters —
# long enough that two genuinely different reasons collide only by the same
# astronomically small chance any truncated hash does, short enough to read
# in a log line rather than needing to be quoted whole.
escalation_autonomy_decide_reason_key() {
  local entry="$1" normalized
  normalized="$(jq -r '
    def norm: (. // "") | ascii_downcase | gsub("[ \t\r\n]+"; " ") | gsub("^ +"; "") | gsub(" +$"; "");
    (.detail | norm) + "\u241f" + (.unblock_condition | norm)
  ' <<<"$entry" 2>/dev/null || true)"
  printf '%s' "$normalized" | sha256sum | awk '{print substr($1, 1, 16)}'
}

# escalation_autonomy_decide_reason_seen REPO ITEM REASON_KEY < union.jsonl
# Exit 0 when a decide-tactical pass has already run for REPO+ITEM over this
# exact REASON_KEY — an `enabler-adjudication` event tagged `pass:
# "decide-tactical"`, or a `decision-taken` event, either carrying a matching
# `reason_key` — and 1 otherwise. This is the "same reason twice" half of the
# bound (requirement 36d): the genuine two-models-disagree loop
# `escalation_autonomy_adjudicated_before` already exists to stop, generalised
# from "any prior pass" to "a prior pass over this same complaint", since
# decide-tactical's broader scope means the same item can legitimately return
# with an unrelated fresh reason and deserves a fresh pass for it.
escalation_autonomy_decide_reason_seen() {
  local repo="$1" item="$2" reason_key="$3" hits
  hits="$(jq -r -R -n --arg r "$repo" --arg i "$item" --arg k "$reason_key" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(((.event == "enabler-adjudication" and (.pass // "") == "decide-tactical")
                or .event == "decision-taken")
               and (.item // "") == $i
               and ((.repo // "") == "" or (.repo // "") == $r)
               and (.reason_key // "") == $k
               and $k != "") ]
    | length
  ' 2>/dev/null || echo 0)"
  [[ "$hits" =~ ^[0-9]+$ ]] && (( hits > 0 ))
}

# escalation_autonomy_decide_pass_count REPO ITEM < union.jsonl
# The number of decide-tactical passes already spent for REPO+ITEM, over any
# reason — the "cap reached" half of the bound (requirement 36d,
# `escalation_adjudication_max_passes`): counts every `enabler-adjudication`
# event tagged `pass: "decide-tactical"` for this item, regardless of
# `reason_key`, since the cap bounds total spend per item rather than spend
# per reason.
escalation_autonomy_decide_pass_count() {
  local repo="$1" item="$2" n
  n="$(jq -r -R -n --arg r "$repo" --arg i "$item" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "enabler-adjudication" and (.pass // "") == "decide-tactical"
               and (.item // "") == $i
               and ((.repo // "") == "" or (.repo // "") == $r)) ]
    | length
  ' 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}
