#!/usr/bin/env bash
#
# lib/cycle-state.sh — how a cycle reports that an item cannot proceed, and
# reads back which items a Co-Ordinator must skip and which the Enabler may
# re-examine.
#
# Sourced by both agent-cycle.sh and scripts/publish-dashboard.sh so the
# semantics of requirements 34, 34c and 35a have exactly one definition — what
# the dashboard reports is then, by construction, what the Co-Ordinator is told
# — and can be regression-tested directly (test/cycle-state.test.sh,
# test/enabler-eligibility.test.sh).
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
#
# On top of those two states sits one *derived set* (requirement 35a): the
# blocked items the Enabler may re-examine. It is not a third state — no event
# sets it and none clears it — but a question asked of the whole log at once:
# which blocked, non-void items have sat long enough, or changed enough, that
# one expensive re-examination is worth buying. It belongs here for the reason
# the other two do (requirement 34a): the Script decides an engagement from it
# and the dashboard reports what came of one, and a rule that decides when to
# spend money would drift, in a second copy, in the direction of spending it.

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

# The Enabler's eligibility rule (requirement 35a), as one jq program over the
# fleet's whole event stream. It re-uses the blocked and void extracts above
# rather than re-deriving either: the set it computes is a subset of "blocked
# and not void", and a second opinion about which items those are is exactly
# the drift requirement 34a exists to prevent.
#
# An item is eligible iff all of:
#
#   1. it is blocked — call that latest attempt-failed event B;
#   2. it is not void — an item with no work needs no unblocking, and the live
#      blocked∩void shape (an item recorded both ways before the two states
#      were split) must not be re-examined at Opus prices;
#   3. no escalation issue for it is still open — the human has been asked and
#      has not answered yet, so there is nothing new to read. When the repo's
#      issue digest is missing (its source state could not be sampled) we
#      cannot tell, and "cannot tell" resolves to ineligible: the cheap
#      mistake is a delayed engagement, not a duplicate issue;
#   4. one of three reasons applies, and the reason travels on the entry so the
#      model knows why it was woken:
#
#      threshold    — nothing has examined it since B, and MIN_COORD_CYCLES
#                     distinct cycles have run a Co-Ordinator (a `stage-end`
#                     for `coordinator` with `exit_code: 0`) since. Counting
#                     *cycles that actually selected* rather than wall-clock
#                     hours is what makes the threshold mean "the pipeline has
#                     had several honest chances to clear this itself": a fleet
#                     standing down on a usage limit, or a switch, logs no
#                     coordinator stage-end and so ages nothing.
#      issue-closed — an escalation raised after B is no longer open and no
#                     examination has followed it. This bypasses the threshold
#                     deliberately: the human acted, and the whole protocol
#                     promised them that closing the issue is what re-starts
#                     the work (requirement 36a).
#      recheck      — the newest examination of it is older than RECHECK_HOURS
#                     (0 disables). This is the path by which evidence that
#                     arrived after an examination — a diagnosis posted into
#                     the very thread whose absence blocked the item — is
#                     eventually read at all, and the only bound on how long a
#                     permanently-stuck item can sit unexamined.
#
# A re-block after an examination re-enters through `threshold`, because every
# guard above is measured from B: a fresh attempt-failed moves B forward, which
# leaves the old examination behind it and starts the count again.
#
# An `enabler-examined` whose outcome is `escalation-failed` is deliberately not
# an examination. The engagement reached a verdict it could not act on, so the
# item is exactly where it was; treating the marker as progress would retire the
# item on the strength of a failed `gh issue create`.
# shellcheck disable=SC2016  # jq's $ vars ($all/$b/$open/…), not the shell's.
ENABLER_ELIGIBLE_JQ='
  def latest_unresolved($set; $clear): '"$LATEST_UNRESOLVED_JQ"';
  def same_item($e): (.item // "") == ($e.item // "")
                     and ((.repo // "") == "" or (.repo // "") == ($e.repo // ""));
  . as $all
  | ($all | latest_unresolved("attempt-failed"; "unblocked")) as $blocked
  | ($all | latest_unresolved("item-void"; "unvoided")) as $void
  | [ $blocked[]
      | . as $b
      | select($void | any(same_item($b)) | not)
      | ([ $all[]
           | select(.event == "escalated" and same_item($b)
                    and ((.issue_number // "") | tostring | test("^[0-9]+$"))) ]
         | sort_by(.ts)) as $escalations
      | ($escalations | last) as $escalation
      | ([ $all[]
           | select(.event == "enabler-examined" and same_item($b)
                    and (.outcome // "") != "escalation-failed"
                    and .ts > $b.ts) ]
         | sort_by(.ts)) as $examined
      | ([ $all[]
           | select(.event == "stage-end" and (.stage // "") == "coordinator"
                    and (.exit_code // 1) == 0
                    and (.cycle // "") != "" and .ts > $b.ts)
           | .cycle ]
         | unique | length) as $coord_cycles
      | (if $escalation == null then "none"
         elif ($open | has($b.repo // "") | not) then "unknown"
         elif (($open[$b.repo // ""] // []) | map(tostring)
               | index($escalation.issue_number | tostring)) != null then "open"
         else "closed"
         end) as $issue_state
      | (if $issue_state == "open" or $issue_state == "unknown" then null
         elif $issue_state == "closed"
              and $escalation.ts > $b.ts
              and ([ $examined[] | select(.ts > $escalation.ts) ] | length) == 0
           then "issue-closed"
         elif ($examined | length) == 0
           then (if $coord_cycles >= $min_coord then "threshold" else null end)
         else
           ((try (($examined | last).ts | fromdateiso8601) catch 0) as $seen
            | if $recheck_hours > 0 and $seen > 0
                 and ($now - $seen) >= ($recheck_hours * 3600)
              then "recheck" else null end)
         end) as $reason
      | select($reason != null)
      | {repo: ($b.repo // ""), item: $b.item, reason: $reason, blocked_ts: ($b.ts // ""),
         stage: ($b.stage // ""), detail: ($b.detail // ""),
         unblock_condition: ($b.unblock_condition // ""),
         escalation: (if $escalation == null then null
                      else {issue_number: ($escalation.issue_number | tostring | tonumber),
                            issue_url: ($escalation.issue_url // ""),
                            ts: ($escalation.ts // "")}
                      end)}
    ]
'

# enabler_eligible_items [LOG_FILE] [MIN_COORD_CYCLES] [RECHECK_HOURS] [OPEN_ISSUES_JSON] [NOW_EPOCH]
# Print, as a JSON array, the blocked items the Enabler may examine this cycle
# (requirement 35a), each carrying the `reason` it became eligible. Reads
# LOG_FILE, or stdin if it is omitted or "-".
#
# OPEN_ISSUES_JSON maps a repo slug to its open issue numbers, built from the
# source-state digests of the repos that sampled cleanly; a slug that is absent
# is a repo we could not read, and an escalation there is treated as possibly
# still open.
#
# Always succeeds, printing [] for a missing, empty or unreadable log, exactly
# as `_latest_unresolved` does and for the same reason: the caller runs under
# `set -e` inside the exit trap, and a log it cannot parse must cost an
# engagement, never a cycle. A threshold that is not a number prints [] too —
# an unreadable setting is not a licence to spend.
enabler_eligible_items() {
  local src="${1:--}" min_coord="${2:-}" recheck_hours="${3:-0}" open_issues="${4:-{\}}" now="${5:-}"
  local out=""
  [[ "$min_coord" =~ ^[0-9]+$ ]] || { printf '[]'; return 0; }
  [[ "$recheck_hours" =~ ^[0-9]+$ ]] || recheck_hours=0
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  jq -e 'type == "object"' <<<"$open_issues" >/dev/null 2>&1 || open_issues='{}'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc --argjson min_coord "$min_coord" --argjson recheck_hours "$recheck_hours" \
          --argjson open "$open_issues" --argjson now "$now" \
          "$ENABLER_ELIGIBLE_JQ" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc --argjson min_coord "$min_coord" --argjson recheck_hours "$recheck_hours" \
          --argjson open "$open_issues" --argjson now "$now" \
          "$ENABLER_ELIGIBLE_JQ" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}
