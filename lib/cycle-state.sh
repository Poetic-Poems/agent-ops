#!/usr/bin/env bash
#
# lib/cycle-state.sh — how a cycle reports that an item cannot proceed, and
# reads back which items a Co-Ordinator must skip.
#
# Sourced by both agent-cycle.sh and scripts/publish-dashboard.sh so the
# semantics of requirements 34 and 34c have exactly one definition — what the
# dashboard reports is then, by construction, what the Co-Ordinator is told —
# and can be regression-tested directly (test/cycle-state.test.sh).
#
# Two states, deliberately distinct (requirement 34c):
#
#   blocked — the work is real but something is in the way *for now* (a red
#             check, an unmerged dependency, a decision nobody has taken). The
#             Co-Ordinator is expected to re-check it and clear it (`unblocked`)
#             once the impediment is demonstrably gone.
#   void    — there is no work: the work order's premise is false, almost always
#             because the item is already done on default_branch. Nothing is in
#             the way, so there is nothing that can "become unblocked" — and the
#             evidence that would tempt an agent to clear it (the work *is*
#             done) is precisely the reason it must stay shut.
#
# Collapsing the two is not a hypothetical. It shipped: an already-done review
# recommendation was recorded as `blocked`, and the next Co-Ordinator, following
# its standing instruction to clear blockers that have gone away, saw the work
# was done, concluded nothing blocked it, and logged `unblocked` — freeing the
# item to be selected and rediscovered forever. Only a human (`unvoided`, hand-
# appended) may clear a void; no agent may.

# read_pr_url_breadcrumb CLONE_DIR
# Print the PR URL the Implementor left under .git/ the moment it opened its
# draft PR, or nothing if it never got that far.
#
# The fallback for when a stage exits without ever producing a final message
# (so there's nothing to grep or parse): a stranded attempt can still be found
# and flagged instead of going silent.
#
# Always succeeds. The callers are `[[ -z "$url" ]] && url="$(read_pr_url_breadcrumb …)"`,
# whose status is this function's, so returning non-zero here aborts the whole
# cycle under `set -e` — before the failure it was about to report is logged.
read_pr_url_breadcrumb() {
  local f="$1/.git/agent-ops-pr-url"
  [[ -f "$f" ]] || return 0
  head -n1 "$f" | tr -d '[:space:]'
}

# item_event_fields STAGE DETAIL REPO ITEM [EXTRA_JSON]
# Print the log fields common to the events that pin a state on one item
# (attempt-failed, item-void). REPO/ITEM are omitted when empty — a stage that
# fails before the Co-Ordinator has selected anything (or because it failed to
# select) has no item to blame, and must not be recorded as if it pinned a state
# on one.
item_event_fields() {
  local stage="$1" detail="$2" repo="$3" item="$4" extra="${5:-{\}}"
  jq -nc --arg s "$stage" --arg d "$detail" --arg r "$repo" --arg i "$item" --argjson x "$extra" \
    '{stage: $s, detail: $d}
     + (if $r == "" then {} else {repo: $r} end)
     + (if $i == "" then {} else {item: $i} end)
     + $x'
}

# The rule behind both extracts: an item is in a state iff its most recent
# $set event has no later $clear event. `blocked` and `void` are the same shape
# over different event pairs, so they share one program rather than two copies
# that agree until the day it matters (the drift TD26071401 fixed for limit
# detection, and requirement 34a makes general).
#
# Events carrying no item are dropped rather than grouped under a shared empty
# key: they pin nothing, and collapsing them together yields one meaningless
# entry that describes no item at all.
#
# State is keyed on repo+item, because an item id is only unique within its
# repo — both repos carry a `dependabot-alert-1` and number tech debt from the
# same date — so keying on the id alone would let one repo starve the other's
# identically-named work.
#
# A clearing event that names no repo clears that item in *every* repo. That is
# deliberate, not laxity: `unblocked` is reported by the Co-Ordinator as a bare
# item id (requirement 18) and both clears may be appended by hand by a human
# (requirements 34, 34c), so neither source has a repo to match on. Over-
# clearing is the safe direction — the item merely becomes a candidate again,
# and re-pins on the next attempt if the reason is still there.
# shellcheck disable=SC2016  # $set/$clear/$events/$e are jq's, not the shell's.
LATEST_UNRESOLVED_JQ='
  [ .[] | select((.event == $set or .event == $clear)
                 and (.item // "") != "") ] as $events
  | ($events | map(select(.event == $clear))) as $clears
  | $events
  | map(select(.event == $set))
  | group_by((.repo // "") + "|" + .item)
  | map(sort_by(.ts) | last)
  | map(. as $e
        | select($clears
                 | any(.item == $e.item
                       and ((.repo // "") == "" or .repo == ($e.repo // ""))
                       and .ts > $e.ts)
                 | not))
'

# _latest_unresolved SET_EVENT CLEAR_EVENT [LOG_FILE]
# Always succeeds, printing [] for a missing, empty, or unreadable log: a caller
# running under `set -e` must not be killed by an unparseable log line, and a
# log that can't be read pins nothing. Malformed lines are skipped rather than
# fatal, so one truncated append can't strand every item.
_latest_unresolved() {
  local set_event="$1" clear_event="$2" src="${3:--}" out=""
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc --arg set "$set_event" --arg clear "$clear_event" "$LATEST_UNRESOLVED_JQ" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc --arg set "$set_event" --arg clear "$clear_event" "$LATEST_UNRESOLVED_JQ" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# blocked_items [LOG_FILE]
# Print, as a JSON array, the most recent attempt-failed event for every item
# with no later unblocked event — the items a Co-Ordinator must skip *for now*,
# and may clear itself once the impediment has demonstrably gone. Reads
# LOG_FILE, or stdin if it is omitted or "-".
blocked_items() {
  _latest_unresolved "attempt-failed" "unblocked" "${1:--}"
}

# void_items [LOG_FILE]
# Print, as a JSON array, the most recent item-void event for every item with no
# later unvoided event — the items that no longer describe real work, which a
# Co-Ordinator must skip and must never clear. Reads LOG_FILE, or stdin if it is
# omitted or "-".
#
# A void is scoped to the item id, so it cannot outstay its welcome: next week's
# review files its recommendations under fresh refs (review-<new-date>-R-NN),
# which no void covers. Voiding R-02 today cannot silence a genuine regression a
# later review finds.
void_items() {
  _latest_unresolved "item-void" "unvoided" "${1:--}"
}
