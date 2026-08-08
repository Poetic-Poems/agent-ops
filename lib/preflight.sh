#!/usr/bin/env bash
#
# lib/preflight.sh — the done-check the Script runs on the item a cycle just
# claimed, before it pays for an Implementor engagement (issue #245).
#
# `lib/work-gone.sh` already answers "is this item's work gone?" for the
# blocked set, from digests the cycle gathers anyway — an issue closed, a pull
# request closed or merged, a register row resolved or not-debt. A freshly
# claimed candidate is not blocked, but the question is identical, and
# TD-PPpfid-26072801 (re-selected and re-implemented 21 hours after it
# merged) shows it is exactly as live for a fresh claim as for a stalled one:
# the register said `resolved` the whole time, and nothing asked it until the
# Implementor stage did — a full engagement to learn what one `gh` read
# already sitting in the cycle's own gathered state would have said.
#
# So this is a one-item call into the same machinery, not a second
# implementation of it: `preflight_done_reason` wraps `work_gone_clearances`
# around a synthetic one-entry blocked list. Its answer is deterministic —
# read off `gh`/the register file, never asked of a model — so it needs no
# corroboration guard (requirement 34d exists to catch a model's fabricated
# citation; there is no model here to fabricate one) and is fit to feed
# `log_item_void` directly.
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail`. Depends on `work_gone_clearances`
# (lib/work-gone.sh), sourced first.

# preflight_done_reason REPO ITEM STATES_JSON [REGISTER_JSON]
#
# Print the reason the item is already done, or nothing when it is not (or
# cannot be told). REPO/ITEM are the just-claimed candidate's own fields;
# STATES_JSON is the cycle's `source_states_json` (already gathered for every
# repo it walked, well before the claim); REGISTER_JSON is `{}` unless the
# item is register-shaped, in which case the caller has fetched its one row
# fresh (the freshly claimed item was never a member of the blocked set that
# `register_status_json` is otherwise scoped to).
preflight_done_reason() {
  local repo="$1" item="$2" states="$3" register="${4:-{\}}" blocked
  blocked="$(jq -nc --arg r "$repo" --arg i "$item" '[{repo: $r, item: $i}]')"
  work_gone_clearances "$blocked" "$states" "$register" '{}' '{}' \
    | jq -r 'if length == 0 then "" else .[0].reason end' 2>/dev/null
}
