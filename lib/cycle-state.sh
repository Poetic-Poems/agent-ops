#!/usr/bin/env bash
#
# lib/cycle-state.sh — how a cycle reports a failed attempt and reads back
# which items are blocked.
#
# Sourced by both agent-cycle.sh and scripts/publish-dashboard.sh so the
# blocked-item semantics of requirement 34 have exactly one definition — what
# the dashboard reports blocked is then, by construction, what the Co-Ordinator
# is told is blocked — and can be regression-tested directly
# (test/cycle-state.test.sh).
#
# Requirements 33/34: an item is blocked iff the most recent
# attempt-failed/unblocked event *for that item* is attempt-failed. Both halves
# of that contract have to agree on the key — an attempt-failed event that
# omits `item` can never block the item it failed on, which is how a stale
# work order came to be re-selected every cycle for days.

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

# attempt_failed_fields STAGE DETAIL REPO ITEM [EXTRA_JSON]
# Print the log fields for one attempt-failed event. REPO/ITEM are omitted when
# empty — a stage that fails before the Co-Ordinator has selected anything (or
# because it failed to select) has no item to blame, and must not be recorded
# as if it blocked one.
attempt_failed_fields() {
  local stage="$1" detail="$2" repo="$3" item="$4" extra="${5:-{\}}"
  jq -nc --arg s "$stage" --arg d "$detail" --arg r "$repo" --arg i "$item" --argjson x "$extra" \
    '{stage: $s, detail: $d}
     + (if $r == "" then {} else {repo: $r} end)
     + (if $i == "" then {} else {item: $i} end)
     + $x'
}

# The requirement 34 blocked-item rule. This is the one place either caller's
# copy comes from — agent-cycle.sh feeds it to the Co-Ordinator, and
# publish-dashboard.sh shows it on the dashboard; do not inline a copy
# elsewhere (the same drift TD26071401 fixed for limit detection).
#
# Events carrying no item are dropped rather than grouped under a shared empty
# key: they block nothing, and collapsing them together yields one meaningless
# "blocked" entry that describes no item at all.
#
# Blocks are keyed on repo+item, because an item id is only unique within its
# repo — both repos carry a `dependabot-alert-1` and number tech debt from the
# same date — so keying on the id alone would let one repo's block starve the
# other's identically-named work.
#
# An unblocked event that names no repo clears that item in *every* repo. That
# is deliberate, not laxity: `unblocked` is reported by the Co-Ordinator as a
# bare item id (requirement 18) and may be appended by hand by a human
# (requirement 34), so neither source has a repo to match on. Over-clearing is
# the safe direction — the item merely becomes a candidate again, and re-blocks
# on the next attempt if the blocker is still there.
# shellcheck disable=SC2016  # $events/$unblocks/$failure are jq's, not the shell's.
BLOCKED_ITEMS_JQ='
  [ .[] | select((.event == "attempt-failed" or .event == "unblocked")
                 and (.item // "") != "") ] as $events
  | ($events | map(select(.event == "unblocked"))) as $unblocks
  | $events
  | map(select(.event == "attempt-failed"))
  | group_by((.repo // "") + "|" + .item)
  | map(sort_by(.ts) | last)
  | map(. as $failure
        | select($unblocks
                 | any(.item == $failure.item
                       and ((.repo // "") == "" or .repo == ($failure.repo // ""))
                       and .ts > $failure.ts)
                 | not))
'

# blocked_items [LOG_FILE]
# Print, as a JSON array, the most recent attempt-failed event for every item
# with no later unblocked event — i.e. exactly the items a Co-Ordinator must
# skip. Reads LOG_FILE, or stdin if it is omitted or "-".
#
# Always succeeds, printing [] for a missing, empty, or unreadable log: a
# caller running under `set -e` must not be killed by an unparseable log line,
# and a log that can't be read blocks nothing. Malformed lines are skipped
# rather than fatal, so one truncated append can't strand every blocked item.
blocked_items() {
  local src="${1:--}" out=""
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null | jq -sc "$BLOCKED_ITEMS_JQ" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null | jq -sc "$BLOCKED_ITEMS_JQ" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}
