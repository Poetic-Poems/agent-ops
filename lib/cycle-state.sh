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
#
# And one *carry-forward* (requirement 3h): the refinements. When the Enabler
# specifies an under-specified item that has no thread to write into, the spec
# it produced lives only in the log, and `refinements_map` is what puts it back
# in front of the Co-Ordinator that will next select the item. Same log, same
# keying, same tolerance of a torn line.

# read_pr_url_breadcrumb CLONE_DIR
# Print the PR URL the Implementer left under .git/ the moment it opened its
# draft PR, or nothing if it never got that far.
#
# The fallback for when a stage exits without ever producing a final message
# (so there's nothing to grep or parse): a stranded attempt can still be found
# and flagged instead of going silent.
#
# Not the last fallback, and not a reliable one: writing this file is a step in
# the Implementer's own procedure, so a stage that skipped its final message
# may equally have skipped this — and on 2026-08-03 three did. What requirement
# 9 falls back to when this comes up empty is `pr_url_for_branch`
# (lib/handoff.sh), which asks GitHub about the branch the *Script* pushed and
# so needs nothing from the stage that failed.
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

# Requirement 18a's marker: a `recheck-clean` event records that a
# Co-Ordinator re-read a blocked GitHub issue's thread after its `updated_at`
# moved past the block's own `ts`, and judged that the blocker still holds. It
# clears nothing — only `unblocked` does that — so it is folded into the
# block's own record as `recheck_clean_ts` rather than treated as another
# member of the set/clear pair `_latest_unresolved` computes. The event is
# repo-scoped (`{item, repo}`, requirement 33), unlike `unblocked`, because
# the two fail in opposite directions: an `unblocked` that over-clears only
# makes an item a candidate again, where a `recheck_clean_ts` folded into an
# unrelated repo's identically-numbered item *raises* that item's comparison
# threshold, so it suppresses a mandated re-read rather than adding one — and
# issue numbers collide across repos far more readily than register ids do.
# Scoping the match makes that fail safe structurally: a marker can only ever
# suppress the one issue its Co-Ordinator actually read.
#
# A repo-less event (older logs, or a report the Script accepted as a bare
# id) still folds — into every same-numbered blocked item. That fallback
# leans on the emitting cycle rather than the match: requirement 18a obliged
# that Co-Ordinator to re-read every blocked issue of that id whose thread
# had moved, so its marker stands for each of them, provided it complied.
# The residual case either way — a blocked issue no marker covers — is
# caught by requirement 35a, whose clocks are measured from the block's own
# `ts` and which this marker deliberately never touches.
# shellcheck disable=SC2016  # jq's $b/$rechecks, not the shell's.
BLOCKED_ITEMS_JQ='
  def latest_unresolved($set; $clear): '"$LATEST_UNRESOLVED_JQ"';
  . as $all
  | ($all | latest_unresolved("attempt-failed"; "unblocked")) as $blocked
  | ([ $all[] | select(.event == "recheck-clean" and (.item // "") != "") ]) as $rechecks
  | $blocked
  | map(. as $b
        | ($rechecks
           | map(select(.item == $b.item
                        and ((.repo // "") == "" or (.repo // "") == ($b.repo // ""))))
           | map(.ts // "")
           | sort | last) as $rc_ts
        | if $rc_ts == null then $b else $b + {recheck_clean_ts: $rc_ts} end)
'

# blocked_items [LOG_FILE]
# Print, as a JSON array, the most recent attempt-failed event for every item
# with no later unblocked event — the items a Co-Ordinator must skip *for now*,
# and may clear itself once the impediment has demonstrably gone. Each entry
# additionally carries `recheck_clean_ts` when a `recheck-clean` marker exists
# for it (requirement 18a) — the newest such ts, for the Co-Ordinator to
# compare a blocked GitHub issue's `updated_at` against alongside the block's
# own `ts`. Reads LOG_FILE, or stdin if it is omitted or "-".
blocked_items() {
  local src="${1:--}" out=""
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$BLOCKED_ITEMS_JQ" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$BLOCKED_ITEMS_JQ" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
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

# void_object_closed_items [LOG_FILE]
# Print, as a JSON array of {repo, item}, every void item requirement 34k's
# act-on-void sweep has already handled — closed the GitHub object for, or
# found it already closed. Reads LOG_FILE, or stdin if it is omitted or "-".
#
# This is the sweep's own idempotency: closing a void'd issue or pull request
# is a one-shot action, deliberately never repeated even if a human reopens
# the object without applying the `unvoid_label` (requirement 34f) — the
# sanctioned way to say a void was wrong. (Requirement 34n qualifies that
# since: once the void has *retired* — actioned and `void_retire_after_days`
# old — a plain reopen does put the item back in front of the pipeline, as a
# fresh candidate rather than a cleared void; 34f records the ratified
# position.) Without this record the sweep would
# re-close whatever it had just reopened, every cycle, forever: exactly the
# "unvoided" bug 34f itself warns against, aimed at a human's plain re-open
# instead of at the label.
#
# `void-object-closed` is a fact, not a state with a clearing event like
# `item-void`/`unvoided` — once an item has been actioned, it stays actioned,
# so the latest occurrence is enough; no _latest_unresolved pairing is needed.
void_object_closed_items() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "void-object-closed"
                   and (.repo // "") != "" and (.item // "") != "")
      | {repo, item} ] | unique'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# void_retired_items [LOG_FILE]
# Print, as a JSON array of {repo, item, ts}, the most recent `void-retired`
# event for every {repo, item} pair one was ever recorded against (requirement
# 34n). Reads LOG_FILE, or stdin if it is omitted or "-".
#
# `void-retired` is a fact, not a state, for the same reason and in the same
# shape as `void-object-closed` above: retirement is decided once, on evidence
# (actioned and old — requirement 34n), and recording the decision is what
# stops the next cycle asking GitHub the same settled question about the same
# id forever. The one wrinkle a plain unique-pairs read would miss is *time*:
# an item can be voided afresh after its old verdict retired (the object
# reopened and re-gathered, then found already-done again), and the new
# `item-void` must not be masked by the old retirement — so the latest `ts`
# per pair is kept, for `subtract_retired_voids` to order against.
#
# Repoless or itemless events are dropped, as everywhere else in this file: a
# retirement is only ever recorded from an actioned pair, and an actioned pair
# always names both.
void_retired_items() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "void-retired"
                   and (.repo // "") != "" and (.item // "") != "") ]
    | group_by((.repo // "") + "|" + .item)
    | map(sort_by(.ts) | last | {repo, item, ts})'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# first_seen_known_items [LOG_FILE]
# Print, as a JSON array of {repo, item}, every item a `first-seen` event has
# ever been logged for (requirement 33, TD-PPagop-26081405, issue #248
# acceptance 4). Reads LOG_FILE, or stdin if it is omitted or "-".
#
# `first-seen` is a fact, not a state like `item-void`/`unvoided`: once an
# item has been logged, it stays logged, so the existence of any occurrence —
# from this node or a peer's — is enough to answer "has the fleet already
# seen this item", the once-ever guarantee `emit_first_seen` (agent-cycle.sh)
# reads this back to keep. No _latest_unresolved pairing, no clearing event.
first_seen_known_items() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "first-seen"
                   and (.repo // "") != "" and (.item // "") != "")
      | {repo, item} ] | unique'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# draft_obsolete_flags [LOG_FILE]
# Print, as a JSON array, every `draft-obsolete-flagged` event ever logged —
# `{repo, item, pr, evidence, cycle, node, ts}`, written by the Script
# (agent-cycle.sh) when an Enabler verdict flags a draft pull request as
# unwanted (design doc §5.5, issue #413, WI-10). Reads LOG_FILE, or stdin if
# it is omitted or "-".
#
# A fact, not a state, the same reason `first_seen_known_items` above keeps no
# clearing event: flagging a draft is not itself a void (that engagement
# writes no `item-void`), so nothing ever retracts a flag once logged — it
# either goes on to corroborate a later, independent void
# (`lib/void-guard.sh`'s `void_draft_obsolete_flag_reason`, which does its own
# repo/item/age/cycle filtering) or it simply never does. Every occurrence,
# from this node or a peer's, is handed to the guard unfiltered by repo or
# item — the guard is what decides which ones are relevant to the void in
# front of it, the same division of labour `blocked_items`/`open_blocked_
# items` already keep.
draft_obsolete_flags() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "draft-obsolete-flagged"
                   and (.repo // "") != "" and (.item // "") != "")
      | {repo, item, pr: (.pr // null), evidence: (.evidence // null),
         cycle: (.cycle // ""), node: (.node // ""), ts: (.ts // "")} ]'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# latest_issues_excluded [LOG_FILE]
# Print, as a JSON object keyed by repo slug, the `excluded` array carried by
# the most recent `issues-excluded` event logged for that repo (requirement
# 33, review decision on agent-ops#452 concern 1) — the "previous state" the
# on-change logging in agent-cycle.sh compares each cycle's freshly gathered
# set against. Reads LOG_FILE, or stdin if it is omitted or "-", the same
# read-off-the-union-log convention first_seen_known_items (above) uses,
# with the same tolerated once-per-cycle-per-node race and first-wins
# convention for readers.
#
# A repo with no `issues-excluded` event yet is simply absent from the
# result: the caller reads a missing key as an empty previous set, per the
# review decision's "no previous event ⇒ previous set was empty" rule — the
# same reading a first occurrence gets from first_seen_known_items.
latest_issues_excluded() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "issues-excluded" and (.repo // "") != "") ]
    | group_by(.repo)
    | map({key: .[0].repo, value: (sort_by(.ts) | last | .excluded // [])})
    | from_entries'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# subtract_retired_voids VOID_JSON RETIRED_JSON
# Print VOID_JSON (the shape `void_items` returns) with every entry whose
# {repo, item} pair a RETIRED_JSON record (`void_retired_items`) covers
# dropped — "covers" meaning the retirement's `ts` is strictly later than the
# void entry's own, the same ordering rule every clearing event here obeys
# (`LATEST_UNRESOLVED_JQ`), so a fresh `item-void` recorded *after* the pair
# retired re-enters the extract on its own terms.
#
# This is requirement 34n's memory, applied before anything reads the extract:
# the bound it gives holds even on a cycle whose register read fails, because
# it needs nothing but the log — and it is what keeps the per-cycle register
# read proportional to the unretired residue rather than to every void ever
# filed. Both inputs are unbounded, so both travel on stdin, never in argv
# (requirement 4g). Fails safe the same way `retire_void_items` does: a jq
# failure on either input returns VOID_JSON verbatim — never subtracting is
# one oversized extract, wrongly subtracting is a verdict silently dropped.
subtract_retired_voids() {
  local void_json="${1:-[]}" retired_json="${2:-[]}" out=""
  # shellcheck disable=SC2016  # jq's $void/$retired/$e, not the shell's.
  out="$(jq -c -n '
    input as $void | input as $retired
    | $void
    | map(. as $e
          | select($retired
                   | any((.repo // "") == ($e.repo // "")
                         and (.item // "") == ($e.item // "")
                         and ((.ts // "") > ($e.ts // "")))
                   | not))
  ' <<<"$void_json"$'\n'"$retired_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out="$void_json"
  printf '%s' "$out"
}

# retire_void_items VOID_JSON ACTIONED_JSON RETIRE_AFTER_DAYS [NOW_EPOCH]
# Print VOID_JSON (the shape `void_items` returns) with every entry that is
# both **actioned** — its `{repo, item}` pair present in ACTIONED_JSON — and
# **old** — its `ts` at least RETIRE_AFTER_DAYS old — dropped (requirement
# 34n). Everything else, including every entry `_latest_unresolved` groups
# under the same key, passes through unchanged.
#
# This does not change what is void (requirement 34c is untouched, and every
# internal reader that subtracts void from blocked — `open_blocked_items`,
# `enabler_eligible_items`, `refinements_map`, each its own copy of
# `LATEST_UNRESOLVED_JQ` rather than a call to `void_items` — recomputes the
# *raw*, unretired set straight off the log, so a retired item never
# resurfaces as blocked). It only shrinks the *extract* a caller goes on to
# hand to the Co-Ordinator, the no-op fingerprint, or the Refiner's candidate
# filter — the value requirement 4g moved onto stdin after it crossed
# `MAX_ARG_STRLEN` at 122 entries on 2026-08-12, and which keeps growing by
# one entry for every item ever voided if nothing ever retires. ACTIONED_JSON
# is the caller's business, not this function's: `void_object_closed_items`
# (requirement 34k, an issue or pull request GitHub confirms closed) and a
# register row read `resolved` or `not-debt` (requirement 34i's own "gone"
# statuses, checked for the void set the same way that requirement already
# checks it for the blocked one) are both `{repo, item}` pairs, so the caller
# simply concatenates them.
#
# A void naming no repo — the hand-appended form requirement 34c allows —
# never matches an ACTIONED_JSON entry (every actioned pair names a repo) and
# so is never retired; a human's own line is left for a human to retract.
#
# Fails safe in every direction an unattended cycle can hit: RETIRE_AFTER_DAYS
# 0 (or not a non-negative integer) disables retirement outright and returns
# VOID_JSON verbatim, unparseable input (either JSON argument, or a `ts` that
# does not parse as ISO-8601) counts as "not old" rather than erroring the
# entry away, and a jq failure of any kind returns VOID_JSON unchanged. Never
# retiring is always the safe direction here — the failure mode is one more
# cycle carrying an entry that was ready to go, not a void quietly reopened.
#
# This function only *decides*; the caller records each entry it dropped as a
# `void-retired` event, and it is the recorded set (`void_retired_items`,
# subtracted by `subtract_retired_voids` above) that keeps an id from being
# re-evidenced and re-decided every cycle thereafter.
retire_void_items() {
  local void_json="${1:-[]}" actioned_json="${2:-[]}" retire_days="${3:-0}" now="${4:-}"
  local out=""
  if ! [[ "$retire_days" =~ ^[0-9]+$ ]] || (( retire_days == 0 )); then
    printf '%s' "$void_json"
    return 0
  fi
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  # Both arrays on stdin, never in argv (requirement 4g): VOID_JSON is the
  # unbounded extract itself, and ACTIONED_JSON grows with it — an --argjson
  # here is the same delivery that failed at MAX_ARG_STRLEN on 2026-08-12.
  # shellcheck disable=SC2016  # jq's $done/$e/$key/$t/$old, not the shell's.
  out="$(jq -c -n --argjson days "$retire_days" --argjson now "$now" '
    input as $void | input as $actioned
    | ($actioned | map((.repo // "") + "|" + (.item // "")) | unique) as $done
    | $void
    | map(. as $e
          | (($e.repo // "") + "|" + ($e.item // "")) as $key
          | ((try ($e.ts | fromdateiso8601) catch null)) as $t
          | (($done | index($key)) != null) as $actioned_hit
          | ($t != null and ($now - $t) >= ($days * 86400)) as $old
          | select(($actioned_hit and $old) | not))
  ' <<<"$void_json"$'\n'"$actioned_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out="$void_json"
  printf '%s' "$out"
}

# The two states meet in one place, and the answer there is always the same:
# **void wins** (requirement 34h). An item can hold both marks at once, and
# routinely does — `item-void` is a state of its own and clears no block, so the
# Enabler's `void` verdict, which is its ordinary way of retiring work that
# turned out to be already done, leaves the last `attempt-failed` standing for
# ever. Nothing re-examines such an item and nothing selects it: it is finished
# with, and every consumer that *acts* on the blocked set already subtracts the
# void one before it does.
#
# This is that subtraction, written once (requirement 34a). It had been written
# twice — inline in the Enabler's eligibility rule, and not at all in the
# Publisher — which is exactly the drift 34a warns about, and it surfaced where
# 34a says it would: the dashboard's Blocked items table, the page you would go
# to to find this class of bug, listed fifteen items the pipeline had already
# closed the book on, one of them for a fortnight.
#
# The match is requirement 34's, not a stricter one: a void naming no repo
# covers the item in every repo, for the reason 34c gives — both an `item-void`
# and its `unvoided` may be hand-appended by a human, who has no repo to hand.
# shellcheck disable=SC2016  # jq's $all/$void/$b, not the shell's.
OPEN_BLOCKED_JQ='
  def latest_unresolved($set; $clear): '"$LATEST_UNRESOLVED_JQ"';
  . as $all
  | ($all | latest_unresolved("item-void"; "unvoided")) as $void
  | ($all | ('"$BLOCKED_ITEMS_JQ"'))
  | map(. as $b
        | select($void
                 | any(.item == $b.item
                       and ((.repo // "") == "" or (.repo // "") == ($b.repo // "")))
                 | not))
'

# open_blocked_items [LOG_FILE]
# Print, as a JSON array, the blocked items that are not void — the items still
# waiting on something, in the sense a human reading a dashboard or an Enabler
# deciding where to spend means it. Entries are `blocked_items`' entries
# unchanged, `recheck_clean_ts` and all. Reads LOG_FILE, or stdin if it is
# omitted or "-".
#
# `blocked_items` remains the raw rule of requirement 34 and is what the
# Co-Ordinator's own skip list is built from: it is handed the void list beside
# the blocked one and requirement 34c is emphatic that it must be able to see
# both, so nothing is subtracted there.
open_blocked_items() {
  local src="${1:--}" out=""
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$OPEN_BLOCKED_JQ" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$OPEN_BLOCKED_JQ" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# The refinements a later Co-Ordinator must be given (requirement 3h), as one jq
# program over the fleet's whole event stream: the latest `item-refined` event
# per repo+item, for items that are not void.
#
# Keyed repo → item → payload rather than by item alone, for requirement 34's
# reason: an item id is only unique within its repo, and a refinement written
# for one repo's TD26071805 is not a specification of the other's.
#
# Void items are dropped because a refined specification of work that does not
# exist is worse than none: it would arrive in the Co-Ordinator's input arguing,
# in detail and in the pipeline's own voice, for an item requirement 34c says
# must never be selected again.
#
# A refinement is also dropped once a *fresher* needs-refinement block stands
# against the same item — the Implementer's escape hatch (requirement 9f) or a
# further Refiner decline (requirement 39d) saying the specification it names
# was tried and found wanting. Comparing timestamps rather than existence alone
# is what lets the item be refined again afterwards: a later `item-refined`
# clears an older block exactly the way `unblocked` already does, and this rule
# must not re-shadow that recovery.
# shellcheck disable=SC2016  # jq's $set/$clear/$r, not the shell's.
REFINEMENTS_MAP_JQ='
  def latest_unresolved($set; $clear): '"$LATEST_UNRESOLVED_JQ"';
  . as $all
  | ($all | latest_unresolved("item-void"; "unvoided")) as $void
  | ($all | latest_unresolved("attempt-failed"; "unblocked")) as $blocked
  | [ $all[]
      | select(.event == "item-refined"
               and (.item // "") != "" and (.repo // "") != "")
      | . as $r
      | select($void
               | any((.item // "") == ($r.item // "")
                     and ((.repo // "") == "" or (.repo // "") == ($r.repo // "")))
               | not)
      | select($blocked
               | any((.kind // "") == "needs-refinement"
                     and (.item // "") == ($r.item // "")
                     and ((.repo // "") == "" or (.repo // "") == ($r.repo // ""))
                     and (((.ts // "") > ($r.ts // ""))))
               | not) ]
  | sort_by(.ts)
  | reduce .[] as $r ({};
      .[$r.repo][($r.item | tostring)] =
        ({ts: ($r.ts // ""), cycle: ($r.cycle // "")}
         + (if ($r.spec // "") == "" then {} else {spec: $r.spec} end)
         + (if ($r.comment_url // "") == "" then {} else {comment_url: $r.comment_url} end)))
'

# refinements_map [LOG_FILE]
# Print, as a JSON object keyed repo → item, the latest refinement recorded for
# every item that has one and is not void. Reads LOG_FILE, or stdin if it is
# omitted or "-".
#
# Always succeeds, printing {} for a missing, empty or unreadable log, for the
# same reason `_latest_unresolved` prints []: this is computed inside a cycle
# running under `set -e`, and a log it cannot parse must cost the Co-Ordinator
# one input, never the cycle.
refinements_map() {
  local src="${1:--}" out=""
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$REFINEMENTS_MAP_JQ" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$REFINEMENTS_MAP_JQ" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# The Enabler's eligibility rule (requirement 35a), as one jq program over the
# fleet's whole event stream. It re-uses the extracts above rather than
# re-deriving any of them: the set it computes is a subset of `open_blocked_items`
# — blocked and not void — and a second opinion about which items those are is
# exactly the drift requirement 34a exists to prevent.
#
# An item is eligible iff all of:
#
#   1. it is blocked — call that latest attempt-failed event B — and
#   2. it is not void: an item with no work needs no unblocking, and the
#      blocked∩void shape every `void` verdict creates (requirement 34h) must
#      not be re-examined at Opus prices. Both clauses are `open_blocked_items`;
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
#                     for `coordinator` with `exit_code: 0`) since — or
#                     REFINEMENT_MIN_COORD_CYCLES, for a block whose `kind` is
#                     `needs-refinement`. Counting *cycles that actually
#                     selected* rather than wall-clock hours is what makes the
#                     threshold mean "the pipeline has had several honest
#                     chances to clear this itself": a fleet standing down on
#                     a usage limit, or a switch, logs no coordinator
#                     stage-end and so ages nothing.
#      issue-closed — the item's latest escalation is no longer open and no
#                     examination has followed it since it was raised. This
#                     bypasses the threshold deliberately: the human acted, and
#                     the whole protocol promised them that closing the issue
#                     is what re-starts the work (requirement 36a). Ordinarily
#                     that means the escalation was raised after B (the block
#                     it answers is still the current one); but when B is a
#                     `needs-refinement` re-flag whose `refined_before` (the
#                     item's latest `item-refined`) both exists and predates
#                     the escalation, the re-flag disputes the same
#                     specification the escalation was about, so the human's
#                     close answers it too — TD-PPagop-26082901's race, where
#                     a re-flag between the raise and the next Enabler pass
#                     would otherwise strand the close. A re-flag with no
#                     prior refinement is outside this on purpose: the thrash
#                     guard does not bite without one, so `threshold` already
#                     delivers that item its first refinement.
#      recheck      — the newest examination of it is older than RECHECK_HOURS
#                     (0 disables). This is the path by which evidence that
#                     arrived after an examination — a diagnosis posted into
#                     the very thread whose absence blocked the item — is
#                     eventually read at all, and the only bound on how long a
#                     permanently-stuck item can sit unexamined.
#
# A re-block after an examination re-enters through `threshold`, because every
# guard above is measured from B: a fresh attempt-failed moves B forward, which
# leaves the old examination behind it and starts the count again — except for
# the `needs-refinement` shape of `issue-closed` just described, which is
# measured from the escalation instead precisely so that re-block does not
# strand an already-closed escalation.
#
# An `enabler-examined` whose outcome is `escalation-failed` is deliberately not
# an examination. The engagement reached a verdict it could not act on, so the
# item is exactly where it was; treating the marker as progress would retire the
# item on the strength of a failed `gh issue create`.
#
# Each entry carries `pr_url` when the blocking event named one (requirement
# 32a). Under that requirement a pull request the Reviewer could not hand off is
# a blocked item like any other, and for a finishing source the item id names a
# register entry rather than the PR — so without this the Enabler would have to
# re-derive from the id the very artefact the block is about. Empty when the
# block had no PR, which is most of them.
#
# Two more fields carry the refinement class (requirements 34e, 36b). `kind` is
# the block's own marker, so an engagement can tell an under-specified item from
# an impeded one and knows which duty it is there to perform; it is `""` for
# every ordinary block, which is what keeps this class invisible to the rest of
# the rule. `refined_before` is the latest `item-refined` for the same repo+item
# — the thrash guard's input, and the record of what the last engagement already
# said, so a second one need not guess at it.
#
# TD-PPagop-26082819: an `item-refined` event whose `comment_url` does not
# actually name a comment — logged before the recording seam
# (`refinement_record_fields`, `lib/refinement.sh`) validated its shape, the
# same phantom shape #818's and #874's events both carried — is skipped here
# rather than trusted, so `$refined` derives to the latest event that really
# is corroborated (or `null`, if none is). `$phantom` is the caller's own
# pre-computed set of such events, over the same `$all` (see
# `enabler_eligible_items`'s own comment on why the check lives there and not
# inline here): every candidate for `$refined` is drawn from the same
# `$all[]` this file already scans, so matching an event against that set —
# rather than re-testing the URL's shape a second time in this jq program —
# keeps `refinement_comment_url_valid` (`lib/refinement.sh`) the one place
# that predicate is evaluated, on the same "one predicate, one rule" terms
# TD-PPagop-26082603 asks for.
#
# The match is on the whole `{repo, item, ts}` triple, never `ts` alone.
# `log_event` (`agent-cycle.sh`) stamps whole-second UTC timestamps and this
# runs over the fleet-wide *union* log, so two `item-refined` events sharing
# a second across different items is ordinary traffic — keying on `ts` alone
# would let one item's phantom suppress another item's genuine refinement,
# silently disarming requirement 36b's thrash guard for an item that really
# was refined and discarding the `spec`/`comment_url` `lib/enabler.sh`'s
# adjudication path reads back out of `refined_before`.
# shellcheck disable=SC2016  # jq's $ vars ($all/$b/$open/$phantom/…), not the shell's.

# $all and $phantom are bound by the caller, via `input as $all`/`input as
# $phantom` (requirement 4g) — never a leading `. as $all` here, since the
# caller runs this body with `jq -n`.
ENABLER_ELIGIBLE_JQ='
  def same_item($e): (.item // "") == ($e.item // "")
                     and ((.repo // "") == "" or (.repo // "") == ($e.repo // ""));
  ($all | ('"$OPEN_BLOCKED_JQ"')) as $blocked
  | [ $blocked[]
      | . as $b
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
           | select(.event == "enabler-examined" and same_item($b)
                    and (.outcome // "") != "escalation-failed"
                    and $escalation != null and .ts > $escalation.ts) ]
         | sort_by(.ts)) as $examined_since_escalation
      | ([ $all[]
           | select(.event == "item-refined" and same_item($b))
           | . as $e
           | select($phantom
                    | any(.ts == ($e.ts // "")
                          and .repo == ($e.repo // "")
                          and .item == (($e.item // "") | tostring))
                    | not) ]
         | sort_by(.ts) | last) as $refined
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
              and ($examined_since_escalation | length) == 0
              and ($escalation.ts > $b.ts
                   or (($b.kind // "") == "needs-refinement"
                       and $refined != null
                       and $refined.ts < $escalation.ts))
           then "issue-closed"
         elif ($examined | length) == 0
           then ((if ($b.kind // "") == "needs-refinement"
                  then $refinement_min_coord else $min_coord end) as $effective_min
                 | if $coord_cycles >= $effective_min then "threshold" else null end)
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
         pr_url: ($b.pr_url // ""),
         kind: ($b.kind // ""),
         refined_before: (if $refined == null then null
                          else {ts: ($refined.ts // ""), cycle: ($refined.cycle // ""),
                                comment_url: ($refined.comment_url // ""),
                                spec: ($refined.spec // "")}
                          end),
         escalation: (if $escalation == null then null
                      else {issue_number: ($escalation.issue_number | tostring | tonumber),
                            issue_url: ($escalation.issue_url // ""),
                            ts: ($escalation.ts // "")}
                      end)}
    ]
'

# enabler_eligible_items [LOG_FILE] [MIN_COORD_CYCLES] [RECHECK_HOURS] [OPEN_ISSUES_JSON] [NOW_EPOCH] [REFINEMENT_MIN_COORD_CYCLES]
# Print, as a JSON array, the blocked items the Enabler may examine this cycle
# (requirement 35a), each carrying the `reason` it became eligible. Reads
# LOG_FILE, or stdin if it is omitted or "-".
#
# OPEN_ISSUES_JSON maps a repo slug to its open issue numbers, built from the
# source-state digests of the repos that sampled cleanly; a slug that is absent
# is a repo we could not read, and an escalation there is treated as possibly
# still open.
#
# REFINEMENT_MIN_COORD_CYCLES is the `threshold` reason's cycle count for a
# block whose `kind` is `needs-refinement`, defaulting to MIN_COORD_CYCLES
# when omitted or not a number — the two ages independently only when a
# caller actually configures them apart (requirement 35a).
#
# Always succeeds, printing [] for a missing, empty or unreadable log, exactly
# as `_latest_unresolved` does and for the same reason: the caller runs under
# `set -e` inside the exit trap, and a log it cannot parse must cost an
# engagement, never a cycle. A threshold that is not a number prints [] too —
# an unreadable setting is not a licence to spend.
enabler_eligible_items() {
  local src="${1:--}" min_coord="${2:-}" recheck_hours="${3:-0}" open_issues="${4:-{\}}" now="${5:-}" refinement_min_coord="${6:-}"
  local out="" all_json="" docs
  local phantom_blocked="" phantom_json='[]' phantom_n=0
  # Falls back to a literal copy of lib/refinement.sh's own pattern rather
  # than an unbound-variable abort under `set -u` when that file has not been
  # sourced (a caller testing this file in isolation): the two must still
  # agree, so this is a fallback, never a second definition to keep in sync
  # by hand — production always has the real one sourced (agent-cycle.sh
  # sources every lib/*.sh file, requirement 4a).
  local comment_url_re="${REFINEMENT_COMMENT_URL_RE:-(#issuecomment-[0-9]+|/issues/comments/[0-9]+)$}"
  [[ "$min_coord" =~ ^[0-9]+$ ]] || { printf '[]'; return 0; }
  [[ "$recheck_hours" =~ ^[0-9]+$ ]] || recheck_hours=0
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  [[ "$refinement_min_coord" =~ ^[0-9]+$ ]] || refinement_min_coord="$min_coord"
  jq -e 'type == "object"' <<<"$open_issues" >/dev/null 2>&1 || open_issues='{}'
  if [[ "$src" == "-" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  fi
  if [[ -n "$all_json" ]]; then
    # TD-PPagop-26082819: an `item-refined` event logged before the recording
    # seam (`refinement_record_fields`, `lib/refinement.sh`) validated
    # `comment_url`'s shape can still be sitting on the log — #818's and
    # #874's both were. Scoped to items this cycle's own open blocks
    # actually name (`open_blocked_items`, the same extract requirement 34
    # builds, reused rather than re-derived), so a resolved item's old
    # phantom does not warn forever.
    phantom_blocked="$(jq -c '.[]' <<<"$all_json" 2>/dev/null | open_blocked_items - 2>/dev/null || true)"
    [[ -n "$phantom_blocked" ]] || phantom_blocked='[]'
    phantom_json="$(jq -nc --arg re "$comment_url_re" '
        input as $all | input as $blocked
        | ($blocked | map({r: (.repo // ""), i: ((.item // "") | tostring)})) as $bitems
        | [ $all[]?
            | select((.event // "") == "item-refined")
            | select((.comment_url // "") != "")
            | select((.comment_url | test($re)) | not)
            | . as $e | (($e.repo // "")) as $er | (($e.item // "") | tostring) as $ei
            | select($bitems | any(.r == $er and .i == $ei))
            | {repo: $er, item: $ei, ts: ($e.ts // "")} ]' \
      <<<"$all_json"$'\n'"$phantom_blocked" 2>/dev/null || true)"
    [[ -n "$phantom_json" ]] || phantom_json='[]'
    phantom_n="$(jq 'length' <<<"$phantom_json" 2>/dev/null || printf 0)"
    [[ "$phantom_n" =~ ^[0-9]+$ ]] || phantom_n=0
    if (( phantom_n > 0 )); then
      # `command -v`, not a bare call: a harness that tests this file in
      # isolation (test/enabler-eligibility.test.sh) defines no `log_event`,
      # and this function's own "always succeeds" contract must hold there
      # too — production always has it, sourced from agent-cycle.sh itself.
      command -v log_event >/dev/null 2>&1 && log_event "warning" "$(jq -nc --argjson p "$phantom_json" \
        --arg d "enabler-eligibility: ignoring phantom item-refined event(s) whose comment_url does not actually name a comment — the block(s) they claimed to refine are treated as still unrefined (TD-PPagop-26082819)" \
        '{detail: $d, phantom: $p}')"
    fi
    # $all (the log, arbitrary in length), $open (the open-issues map, one
    # number per open issue per repo) and $phantom (TD-PPagop-26082819's
    # phantom events, computed above — the whole `{repo, item, ts}` triple,
    # since `ts` alone does not identify an event on a fleet-wide log stamped
    # to the second) arrive on stdin, one document per line, bound
    # positionally with `input as $name` in the order printed
    # (requirement 4g) — never in argv.
    docs="$all_json"$'\n'"$open_issues"$'\n'"$phantom_json"
    out="$(jq -nc --argjson min_coord "$min_coord" --argjson recheck_hours "$recheck_hours" \
        --argjson now "$now" --argjson refinement_min_coord "$refinement_min_coord" \
        'input as $all | input as $open | input as $phantom | ('"$ENABLER_ELIGIBLE_JQ"')' \
        <<<"$docs" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# reviewer_complexity SUMMARY_GRADE TRIVIAL [LABEL_GRADE...]
# Print the effective complexity the Reviewer stage runs at (requirement 8a):
# the highest valid grade (`low` < `medium` < `high`) among the Implementer
# summary's `complexity` and the PR's `complexity:*` label values — taking the
# maximum is what makes the label's raise-never-lower rule (requirement 26a)
# hold at the decision point too. When no argument carries a valid grade at
# all, falls back to `low` if TRIVIAL is "1" (the Co-Ordinator already
# classified the work order trivial, requirement 19 — the answer is known
# without asking the trivial tier to self-grade) and `medium`, the default
# tier, otherwise.
#
# Always succeeds, and an unknown grade contributes nothing rather than
# failing: this feeds a model choice, and a garbled grade must degrade to the
# default tier, never cost the cycle.
reviewer_complexity() {
  local summary="${1:-}" trivial="${2:-0}" g best="" best_rank=0 rank
  shift 2 2>/dev/null || shift $#
  for g in "$summary" "$@"; do
    case "$g" in
      high)   rank=3 ;;
      medium) rank=2 ;;
      low)    rank=1 ;;
      *)      rank=0 ;;
    esac
    if (( rank > best_rank )); then
      best_rank=$rank
      best="$g"
    fi
  done
  if [[ -n "$best" ]]; then
    printf '%s\n' "$best"
  elif [[ "$trivial" == "1" ]]; then
    printf 'low\n'
  else
    printf 'medium\n'
  fi
}
