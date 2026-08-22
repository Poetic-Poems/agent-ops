#!/usr/bin/env bash
#
# lib/label-marker.sh — the pipeline's own memory of the label actions it has
# taken, the counterpart to `lib/pipeline-marker.sh`'s comment marker (#222)
# for the one write a marker cannot reach: a label carries no hidden text to
# stamp, so an add or a remove leaves nothing on the object itself
# distinguishing this system's own hand from a human's — even though, exactly
# as with a comment, both happen under the one GitHub account this system runs
# as (requirement 9d).
#
# `needs_refinement_label`'s hand-flag path (requirement 34g,
# `refinement_hand_flag_new`) already avoids the obvious version of this bug:
# an issue the Script just labelled is, by construction, already blocked, so
# the "not already blocked" test excludes it without needing to know who
# applied the label. What it cannot catch is the case that test is blind to on
# purpose — a *removal* that silently failed (a rate limit, a permissions
# blip; `refinement_label_remove` already tolerates this, by design, per
# `release_refinement_label`'s own comment) leaves the label sitting on an
# issue whose block has since cleared. The next cycle's hand-flag scan finds
# it labelled, finds no open block, and — without this file — reads that
# exactly like a human asking for one, restarting a block nobody asked for.
# This is that RC4 fleet incident (`docs/reviews/2026-08-07-…`): the pipeline
# unable to tell its own label writes from the human's, each round costing an
# engagement.
#
# The fix is the same shape as the comment marker's, adapted to what a label
# can carry: nothing on the object, so the memory lives in the shared log
# instead. Every add or remove the Script performs is logged as an
# `own-label-action` event; a reader compares GitHub's own record of when the
# label was last applied (`gather-hand-flagged-refinements.sh`'s `labelled_at`)
# against this file's record of when *we* last touched it. If ours is the
# later — or the same — action, the current state is explained without a
# human ever touching the label, and no read-back mechanism may treat it as
# one.
#
# The record is written at the call site (agent-cycle.sh), not inside
# `lib/refinement.sh`'s `refinement_label_add`/`_remove`: those stay pure `gh`
# wrappers, the same "library stays a pure function" boundary
# `stage_budget_overrides` documents for its own config read. This file holds
# only the read-back half — a pure function of the log, like every other
# extract in `lib/cycle-state.sh`.
#
# #526: comparing "ours" and GitHub's clocks directly is not enough. A node
# whose clock runs behind GitHub's can stamp `own.ts` earlier than the
# `labelled_at` it caused, which the original exact-order comparison read as
# a human's later touch; and the `own-label-action` record a peer node just
# wrote has not necessarily reached the node doing the read-back yet, since
# it arrives by the fleet's periodic state-sync rather than synchronously.
# The read-back below instead (1) matches any recorded `add` within a skew
# tolerance of `labelled_at`, in either direction, rather than requiring
# ours to be no later than GitHub's, and (2) treats a label applied more
# recently than a grace period as *not yet attributable* when no own record
# explains it — neither a hand-flag nor a stale write to retry — rather than
# assuming the silence means a human, since the record may simply not have
# propagated yet. See `own_class` below for the three-way classification
# this produces, shared verbatim by every reader so they cannot drift into
# disagreeing about which class a candidate falls into.
#
# Sourced by agent-cycle.sh. Sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail`.

# How long a node's clock may disagree with GitHub's (LABEL_OWN_SKEW_TOLERANCE_SECONDS)
# and how long an own-label-action record may take to propagate from the
# writing node to the reading one over the fleet's periodic state-sync
# (LABEL_OWN_GRACE_SECONDS). Both env-overridable, like every other pipeline
# timing constant (e.g. `GITHUB_LIMIT_MAX_WAIT_SECONDS`), so a test can
# substitute a value that reads clearly without touching production
# behaviour. Production values: 120s comfortably exceeds every skew measured
# on this fleet (13s and 5+s in opposite directions, per #526); 1800s
# comfortably exceeds the ~12 minutes of state-sync staleness #526 measured
# against a ~6-7 minute fetch cadence.
LABEL_OWN_SKEW_TOLERANCE_SECONDS="${LABEL_OWN_SKEW_TOLERANCE_SECONDS:-120}"
LABEL_OWN_GRACE_SECONDS="${LABEL_OWN_GRACE_SECONDS:-1800}"

# The classification `label_filter_own_applications` and
# `label_own_stale_applications` below embed verbatim, so the two can never
# drift into disagreeing about which of three classes a candidate falls
# into:
#
#   "ours"      — an own `add` for this repo+item+label is recorded within
#                 LABEL_OWN_SKEW_TOLERANCE_SECONDS of `labelled_at`, in
#                 either direction, regardless of what the *latest* recorded
#                 action is — so an add that matches, followed by a remove
#                 that silently failed, still reads as ours (#526 cause 2).
#   "deferred"  — no own record explains the label, but `labelled_at` is
#                 newer than LABEL_OWN_GRACE_SECONDS ago: the absence may
#                 simply mean the writing node's record has not reached this
#                 node yet (#526 cause 1), so this is neither reported as a
#                 hand-flag nor offered up for a stale-removal retry.
#   "not-ours"  — everything else: the label is old enough, or the own
#                 record present and not near enough, that a human's own
#                 hand is the remaining explanation. This is the fail-safe
#                 default requirement 39f always used before #526 — an
#                 unreadable log, a malformed argument, or a missing
#                 `labelled_at` all resolve here too.
#
# A legacy `$own` object carrying only `{action, ts}` (rather than
# `label_own_actions_map`'s richer `{action, ts, adds}`) is still matched
# correctly: `own_add_near` treats `action == "add"` with its `ts` as an
# implicit single-element `adds`, so a caller (or a test) that builds an
# own-record by hand doesn't need to know about `adds` at all.
# shellcheck disable=SC2016  # jq's own $e/$own/$now_epoch/…, not the shell's.
_label_own_class_jq_def='
  def own_epoch($s): (try ($s | fromdateiso8601) catch null);
  def own_add_near($own; $at_epoch; $tol):
    (($own.adds // []) +
     (if (($own.action // "") == "add") and (($own.ts // "") != "")
      then [$own.ts] else [] end)) as $adds
    | if $at_epoch == null then false
      else ($adds | any(own_epoch(.) as $ae
             | $ae != null and (($ae - $at_epoch) | if . < 0 then -. else . end) <= $tol))
      end;
  def own_class($e; $own_map; $now_epoch; $tol; $grace):
    ((($e.repo // "") | tostring) + "|" + (($e.number // "") | tostring)) as $key
    | (($own_map[$key]) // {}) as $own
    | (own_epoch($e.labelled_at // "")) as $at_epoch
    | if own_add_near($own; $at_epoch; $tol) then "ours"
      elif $at_epoch == null then "not-ours"
      elif ($now_epoch != null) and (($now_epoch - $at_epoch) < $grace) then "deferred"
      else "not-ours"
      end;
'

# label_own_action_fields REPO ITEM LABEL ACTION
# Print the extra fields an `own-label-action` event carries: which item, which
# label, and whether the Script added or removed it. `ACTION` is `add` or
# `remove` — anything else is recorded as given, since a future action this
# file does not yet know about should still be logged rather than dropped.
label_own_action_fields() {
  local repo="$1" item="$2" label="$3" action="$4"
  jq -nc --arg r "$repo" --arg i "$item" --arg l "$label" --arg a "$action" \
    '{repo: $r, item: ($i | tostring), label: $l, action: $a}' 2>/dev/null || printf '{}'
}

# label_own_actions_map LABEL [LOG_FILE]
# Print, as a JSON object keyed `"<repo>|<item>"`, this system's own recorded
# history for LABEL against every repo+item that has one: `{action, ts,
# adds}`, where `action`/`ts` are the most recent action and its timestamp
# (unchanged from before #526) and `adds` is every `add` action's timestamp,
# oldest first — `own_class` (above) scans the whole of `adds`, not just the
# latest action, so an add that matches `labelled_at` is still recognised as
# ours even when a later `remove` was also recorded (#526 cause 2: the
# removal it attempted silently failed). Reads LOG_FILE, or stdin if it is
# omitted or "-". Always prints a valid object; an unreadable log yields
# `{}`, the same fail-safe shape as every other extract in
# `lib/cycle-state.sh`.
label_own_actions_map() {
  local label="$1" src="${2:--}" out=""
  # shellcheck disable=SC2016  # jq's $label/$e, not the shell's.
  local jq_prog='
    [ .[] | select(.event == "own-label-action" and (.label // "") == $label
                   and (.repo // "") != "" and (.item // "") != "") ]
    | sort_by(.ts)
    | reduce .[] as $e ({};
        ($e.repo + "|" + ($e.item | tostring)) as $k
        | .[$k] = ((.[$k] // {action: "", ts: "", adds: []})
            | .action = ($e.action // "")
            | .ts = ($e.ts // "")
            | if ($e.action // "") == "add"
              then .adds += [($e.ts // "")]
              else . end))'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc --arg label "$label" "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc --arg label "$label" "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# log_latest_ts [LOG_FILE]
# Print the newest `.ts` across LOG_FILE, or stdin if it is omitted or "-" —
# the log stream's own horizon: how far forward the fleet's shared memory
# reaches as of this snapshot, not wall clock (#670). `agent-cycle.sh` calls
# this once, immediately after `union_log` is materialised and before that
# cycle's own events are appended into it, and passes the result as the
# explicit `NOW` to `label_filter_own_applications` and
# `label_own_stale_applications` below — measuring the own-label grace period
# against how stale the snapshot actually is, rather than against however
# long this cycle has been running by the time the read-back gets to it.
# ISO 8601 UTC timestamps (`Z`-suffixed, as every `ts` in this fleet's logs
# is) sort correctly as plain strings, so no epoch conversion is needed here.
# Same fail-safe contract as every other extract in this file and in
# `lib/cycle-state.sh`: an unparseable line is skipped, not fatal, and an
# empty, missing, or unreadable stream yields empty output — which is exactly
# the value that makes `label_filter_own_applications`/
# `label_own_stale_applications` fall back to wall clock on their own, the
# same as before this function existed (a brand-new fleet's union log has no
# own records to defer against anyway).
log_latest_ts() {
  local src="${1:--}" out=""
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -rs 'map(.ts // empty) | if length == 0 then empty else max end' 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -rs 'map(.ts // empty) | if length == 0 then empty else max end' 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# label_filter_own_applications CANDIDATES_JSON OWN_ACTIONS_JSON [NOW]
# Print CANDIDATES_JSON — the `{repo, number, labelled_at, …}` array
# `scripts/gather-hand-flagged-refinements.sh` produces — with every entry
# dropped that `own_class` (above) classifies as "ours" or "deferred",
# keeping only "not-ours": a label old enough, or with no own record near
# enough, that a human's own hand remains the explanation. NOW is compared
# against `labelled_at` for the grace test and defaults to `date -u` when
# omitted or empty — but the caller that matters, `agent-cycle.sh`'s
# requirement-39f read-back, always passes `log_latest_ts`'s own
# `union_log_horizon` (#670) rather than relying on that default: the grace
# period has to be measured against how stale the union-log snapshot is, not
# against wall clock read back however much later in the cycle this runs.
# Tests pass a fixed value for the same reason the caller does — determinism
# — not because the default is otherwise the right choice in production.
#
# This is the read-back half requirement 39f describes, and the one place the
# attribution is decided: `label_is_own_application` and
# `label_own_stale_applications` below share the exact same `own_class`
# definition (`_label_own_class_jq_def`) so all three readers can never
# disagree about which class a candidate falls into. Entries are kept, not
# dropped, whenever the record is
# silent — an empty own record, an empty `labelled_at`, a malformed argument
# — because "not ours" is the safe direction: it leaves the caller with
# exactly the behaviour it had before this file existed rather than
# swallowing a human's flag. A "deferred" entry (label applied within the
# grace period, no own record yet) is *also* dropped here — neither reported
# nor retried — because #526 found that an unpropagated own-label-action
# record, not a human, was the actual explanation three times running.
label_filter_own_applications() {
  local candidates="${1:-[]}" own_map="${2:-{\}}" now="${3:-}" out="" docs jq_prog
  [[ -n "$now" ]] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Both arrive on stdin, one document per line, never in argv (requirement
  # 4g): the candidate list and the own-actions map both grow with the
  # fleet's history, and past MAX_ARG_STRLEN an `--argjson` delivery makes
  # this call fail into the "not ours" fallback below.
  docs="$candidates"$'\n'"$own_map"
  # shellcheck disable=SC2016  # jq's own $c/$o/$e/…, not the shell's.
  jq_prog='
'"$_label_own_class_jq_def"'
    input as $c | input as $o |
    (try ($now_arg | fromdateiso8601) catch null) as $now_epoch |
    [ $c[]?
      | . as $e
      | select(own_class($e; ($o // {}); $now_epoch; $tol_arg; $grace_arg) == "not-ours") ]'
  out="$(jq -nc --arg now_arg "$now" \
      --argjson tol_arg "$LABEL_OWN_SKEW_TOLERANCE_SECONDS" \
      --argjson grace_arg "$LABEL_OWN_GRACE_SECONDS" "$jq_prog" \
      <<<"$docs" 2>/dev/null || true)"
  if [[ -z "$out" ]] || ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    if jq -e 'type == "array"' <<<"$candidates" >/dev/null 2>&1; then
      out="$candidates"
    else
      out='[]'
    fi
  fi
  printf '%s' "$out"
}

# label_own_stale_applications CANDIDATES_JSON OWN_ACTIONS_JSON [BLOCKED_JSON] [NOW]
# Print CANDIDATES_JSON with every entry dropped *except* the ones
# `own_class` (above) classifies as "ours" and that have no block open —
# sharing that classification verbatim with `label_filter_own_applications`
# so the two can never disagree about which entries are which. Where that
# function answers "what a human might be asking about", this one answers
# "what is safe to retry removing": a label this system recorded a matching
# `add` for, still present on the issue only because a previous removal
# attempt (`release_refinement_label`, which tolerates the failure by
# design) did not take. Requirement 39f's read-back keeps such an entry from
# being misread as a fresh flag; this is the other half — handing it back so
# the call site can have another go at the removal itself, rather than
# leaving the label to sit there meaning nothing until a human notices.
#
# A "deferred" entry — no own record yet, but `labelled_at` within the grace
# period — is *excluded* here too, the same as from
# `label_filter_own_applications`: it is not proven to be ours, so it is not
# safe to retry removing (#526's requirement 3 — deferred is a third state,
# not a synonym for "kept" that would otherwise fall into this set as a
# false stale-retry candidate). NOW defaults to `date -u`, same as that
# function, and the same caller passes the same `union_log_horizon` here too
# (#670) — not optional: this function and `label_filter_own_applications`
# share `_label_own_class_jq_def` precisely so they cannot disagree about a
# candidate's class, and passing the horizon to one but not the other would
# reintroduce exactly that disagreement.
#
# BLOCKED_JSON is `lib/cycle-state.sh`'s `blocked_items` extract, and the test
# against it is what separates a stuck label from a working one: while a block
# is open the label is not a leftover at all but requirement 34e's live
# projection of that block onto the issue, the one thing telling a human
# reading it that the pipeline is waiting on them. Every block counts, not
# only a refinement one — the same "any existing block disqualifies the issue"
# rule `refinement_hand_flag_new` applies to the entries this function does
# not take. Omitted, it defaults to "nothing is blocked"; the one caller that
# acts on the result passes the extract.
#
# Fails safe in the direction a write demands: malformed CANDIDATES_JSON, a
# malformed OWN_ACTIONS_JSON or a malformed BLOCKED_JSON yields nothing to
# retry, the same "not ours" default `label_filter_own_applications` uses for
# reading, because here that default suppresses a GitHub write rather than a
# block.
label_own_stale_applications() {
  local candidates="${1:-[]}" own_map="${2:-{\}}" blocked="${3:-[]}" now="${4:-}" out docs jq_prog
  [[ -n "$blocked" ]] || blocked='[]'
  [[ -n "$now" ]] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # The candidate list, the own-actions map and the blocked set all arrive
  # on stdin, one document per line, never in argv (requirement 4g): all
  # three grow with the fleet's history, and past MAX_ARG_STRLEN an
  # `--argjson` delivery makes this call fail into the "nothing to retry"
  # fallback below — the safe direction for a write, but silent.
  docs="$candidates"$'\n'"$own_map"$'\n'"$blocked"
  # shellcheck disable=SC2016  # jq's own $c/$o/$b/$e/…, not the shell's.
  jq_prog='
'"$_label_own_class_jq_def"'
    input as $c | input as $o | input as $b |
    ($b | map((((.repo // "") | tostring)) + "|" + (((.item // "") | tostring)))) as $open |
    (try ($now_arg | fromdateiso8601) catch null) as $now_epoch |
    [ $c[]?
        | . as $e
        | (($e.repo // "") + "|" + (($e.number // "") | tostring)) as $key
        | select(own_class($e; ($o // {}); $now_epoch; $tol_arg; $grace_arg) == "ours")
        | select(($open | index($key)) == null) ]'
  out="$(jq -nc --arg now_arg "$now" \
      --argjson tol_arg "$LABEL_OWN_SKEW_TOLERANCE_SECONDS" \
      --argjson grace_arg "$LABEL_OWN_GRACE_SECONDS" "$jq_prog" \
      <<<"$docs" 2>/dev/null || true)"
  if [[ -z "$out" ]] || ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    out='[]'
  fi
  printf '%s' "$out"
}

# label_is_own_application OWN_ACTIONS_JSON REPO ITEM LABELLED_AT [NOW]
# True (exit 0) when the label's current presence on REPO/ITEM is explained by
# this system's own last action rather than a human's — the single-item form
# of `own_class` above, sharing its definition verbatim (not merely calling
# `label_filter_own_applications` and checking whether it dropped the
# candidate) precisely because that filter's *kept* set is not this
# function's complement any more: since #526, the filter also drops a
# "deferred" candidate, which is not yet proven ours either. Only a positive
# "ours" verdict answers true here; both "not-ours" and "deferred" answer
# false, and either an empty own record or an empty LABELLED_AT resolves to
# "not-ours", the safe direction, exactly as before #526. NOW defaults to
# `date -u`; pass it explicitly to test the grace period deterministically.
label_is_own_application() {
  local own_map="$1" repo="$2" item="$3" labelled_at="$4" now="${5:-}" out jq_prog
  [[ -n "$now" ]] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # shellcheck disable=SC2016  # jq's own $o/$r/$i/…, not the shell's.
  jq_prog='
'"$_label_own_class_jq_def"'
    input as $o |
    (try ($now_arg | fromdateiso8601) catch null) as $now_epoch |
    own_class({repo: $r, number: $i, labelled_at: $at}; ($o // {}); $now_epoch; $tol_arg; $grace_arg)'
  out="$(jq -nc --arg r "$repo" --arg i "$item" --arg at "$labelled_at" --arg now_arg "$now" \
      --argjson tol_arg "$LABEL_OWN_SKEW_TOLERANCE_SECONDS" \
      --argjson grace_arg "$LABEL_OWN_GRACE_SECONDS" "$jq_prog" \
      <<<"$own_map" 2>/dev/null || true)"
  [[ "$out" == '"ours"' ]]
}
