#!/usr/bin/env bash
#
# lib/item-lifecycle.sh — the item-lifecycle record (docs/FLOW-SCHEMA.md,
# requirement 49, issue #595): one durable record per work item, folded from
# the union log's own item-scoped events, ending in an explicit terminal
# fate. A pure derivation, on the same terms `lib/rework.sh`'s `rework_fields`
# and `lib/cycle-state.sh`'s extracts already are — reads the log, touches no
# lock, writes no event.
#
# Reuses `lib/cycle-state.sh`'s own `blocked_items`/`void_items`/
# `draft_obsolete_flags` for the set/clear resolution (a currently-blocked or
# currently-void item, and a flagged-obsolete draft) rather than re-deriving
# that logic a second time — the drift requirement 34a already warns against,
# generalised here to a third reader. Callers must source `lib/cycle-state.sh`
# before this file; production always does (agent-cycle.sh sources every
# lib/*.sh file, requirement 4a), and `test/item-lifecycle.test.sh` sources it
# explicitly.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# The {repo, item} join key, identical to every other reader of this log
# (lib/cycle-state.sh, scripts/pickup-metrics.sh): item coerced with
# `tostring` so a numeric and a string item id are the same key.
# shellcheck disable=SC2016  # jq's own def, not the shell's.
ITEM_LIFECYCLE_KEY_JQ='
  def item_key: ((.repo // "") | tostring) + "|" + ((.item // "") | tostring);
'

# The first-seen -> selection pairing `scripts/pickup-metrics.sh` originally
# derived inline (TD-PPagop-26081405, issue #248 acceptance 4), moved here so
# it is one fold with one set of readers rather than a copy kept in sync by
# hand. Unchanged in substance from pickup-metrics.sh's own prior version:
# first-wins-by-ts per {repo, item}, a bootstrap-flagged first-seen excluded
# from the latency sample but still counted, and an unpaired half reported
# under `coverage` rather than silently shrinking the count.
# shellcheck disable=SC2016  # jq's own $since/$all/etc, not the shell's.
ITEM_LIFECYCLE_PICKUP_PAIRS_JQ='
  '"$ITEM_LIFECYCLE_KEY_JQ"'
  def percentile($p; $arr):
    ($arr | sort) as $s
    | ($s | length) as $n
    | if $n == 0 then null
      else
        (($n - 1) * $p) as $idx
        | ($idx | floor) as $lo
        | ($idx | ceil) as $hi
        | if $lo == $hi then $s[$lo]
          else $s[$lo] + ($idx - $lo) * ($s[$hi] - $s[$lo])
          end
      end;
  def latency_stats($arr):
    {count: ($arr | length), median_seconds: percentile(0.5; $arr), p90_seconds: percentile(0.9; $arr)};
  def keyed($e):
    select(.event == $e
           and (((.repo // "") | tostring) != "")
           and (((.item // "") | tostring) != ""));
  def first_per_key:
    group_by(item_key) | map(sort_by(.ts) | first);

  ($all | map(select(type == "object")) | map(select($since == "" or (.ts // "") >= $since))) as $ev
  | ($ev | map(keyed("first-seen")) | first_per_key) as $fs_list
  | ($ev | map(keyed("selection"))  | first_per_key) as $sel_list
  | ($fs_list  | map({key: item_key, value: .}) | from_entries) as $fs_by_key
  | ($sel_list | map({key: item_key, value: .}) | from_entries) as $sel_by_key
  | ($fs_list  | map(item_key)) as $fs_keys
  | ($sel_list | map(item_key)) as $sel_keys
  | ([$fs_keys[]  | select(. as $k | $sel_by_key | has($k))])         as $paired_keys
  | ([$fs_keys[]  | select(. as $k | ($sel_by_key | has($k)) | not)]) as $fs_only_keys
  | ([$sel_keys[] | select(. as $k | ($fs_by_key  | has($k)) | not)]) as $sel_only_keys
  | ($paired_keys | map(
       $fs_by_key[.] as $fs | $sel_by_key[.] as $sel
       | {node: $sel.node, bootstrap: ($fs.bootstrap // false),
          latency_seconds: (($sel.ts | fromdateiso8601) - ($fs.ts | fromdateiso8601))}
     )) as $paired
  | ($paired | map(select(.bootstrap | not))) as $measured
  | ($paired | map(select(.bootstrap)) | length) as $bootstrap_excluded_count
  | ($measured | map(select(((.node // "") | tostring) != "")) | group_by(.node)
       | map({key: .[0].node, value: (map(.latency_seconds) | latency_stats(.))})
       | from_entries) as $by_node
  | {
      coverage: {
        paired: ($paired_keys | length),
        first_seen_only: ($fs_only_keys | length),
        selection_only: ($sel_only_keys | length)
      },
      pickup_latency: {
        bootstrap_excluded_count: $bootstrap_excluded_count,
        fleet: ($measured | map(.latency_seconds) | latency_stats(.)),
        by_node: $by_node
      }
    }
'

# item_lifecycle_pickup_pairs SINCE [LOG_FILE]
# Print `{coverage, pickup_latency}` — the shape `scripts/pickup-metrics.sh`
# merges into its own report — folded from LOG_FILE (or stdin, "-" or
# omitted). Always succeeds, printing the all-empty shape for a missing,
# empty or unreadable log, on the same terms every reader in
# lib/cycle-state.sh does.
item_lifecycle_pickup_pairs() {
  local since="${1:-}" src="${2:--}" all_json="" out=""
  if [[ "$src" == "-" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  fi
  [[ -n "$all_json" ]] || all_json='[]'
  out="$(jq -nc --arg since "$since" 'input as $all | ('"$ITEM_LIFECYCLE_PICKUP_PAIRS_JQ"')' \
    <<<"$all_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='{"coverage":{"paired":0,"first_seen_only":0,"selection_only":0},"pickup_latency":{"bootstrap_excluded_count":0,"fleet":{"count":0,"median_seconds":null,"p90_seconds":null},"by_node":{}}}'
  printf '%s' "$out"
}

# The main fold (docs/FLOW-SCHEMA.md's "Item lifecycle record"). $all/$void/
# $blocked/$obsolete arrive on stdin as four documents, bound positionally by
# the caller (requirement 4g — big things travel on stdin, never argv):
#
#   $all      every parsed event this run can see, unfiltered.
#   $void     `void_items`'s own output — the currently-void {repo, item}
#             pairs, each carrying the winning item-void's own `ts`.
#   $blocked  `blocked_items`'s own output — the currently-blocked pairs.
#   $obsolete `draft_obsolete_flags`'s own output — every
#             draft-obsolete-flagged event ever logged (the source function
#             does no repo/item filtering of its own, by design — see its
#             header); the fold matches it to `{$r, $i}` itself, the same
#             `resolved()` lookup $void and $blocked already go through.
#
# `orphan-branch-released` carries no `item` field of its own (out of this
# item's scope — `scripts/sweep-orphan-branches.sh` is not one of the sites
# requirement 49 touches), so a `reason: "superseded"` entry is matched back
# to its item the same way `scripts/sweep-closed-issues.sh` already resolves
# one from a branch: a head of exactly `agent/<N>`, the name this pipeline
# mints only for an issue- or tech-debt-sourced work order. An entry whose
# branch does not match that shape names no item this fold can key on, and is
# silently excluded from consideration for `superseded` — never guessed at.
#
# `$since` bounds the *population* — which items appear in `records[]` at all
# is decided by `group_by(item_key)` over `$ev`, the `$all2` events at or
# after `$since` — never the *fate* of an item that does appear. `landed` and
# `superseded` are read off `$full_by_key`, an unwindowed per-item index built
# from `$all2` before `$since` is applied, on the same terms `$void`/
# `$blocked`/`$obsolete` already are (each computed by the caller from the
# whole raw log, not from `$ev`). So an item entering the population because
# of one recent event still reports its true current fate even when the
# evidence that decides it — an older merge, an older void, an older block —
# sits before the window: "fate is current state; `--since` bounds only the
# population," never "fate is what the window alone can see." (`instants`,
# `first_seen` and `source` are the one place the window still shows through:
# they are windowed by design, so they answer "what did this run see for this
# item," not "everything this item ever did.")
#
# Fate is assigned by one strict priority, each rule checked only once every
# rule ahead of it has failed to match:
#
#   1. landed       — a `merge-observed` or `issue-closed-post-merge` event
#                     exists for this item. The strongest possible evidence
#                     (a real merge was observed) outranks every other mark,
#                     including a stale void.
#   2. voided       — `void_items` still carries this pair (latest
#                     `item-void`, no later `unvoided`).
#   3. superseded   — an `orphan-branch-released {reason: "superseded"}`
#                     resolves to this item (see above).
#   4. blocked      — `blocked_items` still carries this pair: a currently-
#                     blocked item is demonstrably still in the system, which
#                     outranks the merely uncorroborated intent below.
#   5. abandoned    — a `draft-obsolete-flagged` event exists for this item:
#                     the pipeline's own recorded intent to abandon a draft,
#                     pending the human corroboration (`lib/void-guard.sh`)
#                     that would otherwise retire it as `voided` on a later
#                     fold. A standing block is stronger evidence than this
#                     uncorroborated intent, hence rule 4 above it.
#   6. open         — none of the above: the item has entered (some event
#                     names it) but nothing yet says it has left.
#
# One case is deliberately not folded into the priority order above:
# `unaccounted`. An item is `unaccounted`, not `landed`, when it is *also*
# void *and* that void's own `ts` is later than the earliest landing
# evidence — a human or the Enabler recorded "no work exists" for an item
# that, on the log's own evidence, had already merged. That is a
# contradiction this fold does not resolve by guessing which side is right;
# it is surfaced, with the reason, for a human to read (the same discipline
# `docs/ROADMAP.md`'s D21 states for the flow account generally: "a second,
# a token or an item that cannot be classified lands in an explicit
# unaccounted bucket and is never dropped"). An unaccounted item still
# appears in `records[]`, `fate: "unaccounted"`, exactly as every other item
# does — `unaccounted[]` is a convenience projection of the same records,
# carrying the reason, never a second population.
#
# The invariant (`balanced`) holds by construction — fate is a total
# function over the entered set, into exactly one of seven buckets — and is
# still computed and printed rather than merely asserted in prose: a future
# change that lets an item fall through every rule above (or match two) is
# exactly the defect this field exists to catch.
# shellcheck disable=SC2016  # jq's own $all/$void/$blocked/$obsolete/etc, not the shell's.
ITEM_LIFECYCLE_FOLD_JQ='
  '"$ITEM_LIFECYCLE_KEY_JQ"'
  def resolved($set_json; $r; $i):
    $set_json | any(.repo == $r and ((.item // "") | tostring) == $i);
  def resolved_ts($set_json; $r; $i):
    ($set_json | map(select(.repo == $r and ((.item // "") | tostring) == $i)) | first | .ts) // null;

  ($all
   | map(select(type == "object"))
   | map(if (.event == "orphan-branch-released" and (.reason // "") == "superseded"
             and ((.item // "") == "") and ((.branch // "") | test("^agent/[0-9]+$")))
         then . + {item: (.branch | capture("^agent/(?<n>[0-9]+)$").n)}
         else . end)
  ) as $all2
  | ($all2 | map(select(((.repo // "") | tostring) != "" and ((.item // "") | tostring) != ""))
     | group_by(item_key) | map({key: (.[0] | item_key), value: .}) | from_entries) as $full_by_key
  | ($all2 | map(select($since == "" or (.ts // "") >= $since))) as $ev
  | ($ev | map(.ts // "") | map(select(. != "")) | sort) as $ts_all
  | {from: (if ($ts_all | length) == 0 then null else $ts_all[0] end),
     to:   (if ($ts_all | length) == 0 then null else $ts_all[-1] end)} as $window

  | ($ev | map(select(((.repo // "") | tostring) != "" and ((.item // "") | tostring) != "")))
  | group_by(item_key)
  | map(
      . as $sorted_input
      | ($sorted_input | sort_by(.ts // "")) as $sorted
      | ($sorted[0].repo) as $r
      | ($sorted[0].item | tostring) as $i
      | ($sorted | map({event, ts: (.ts // ""), node: (.node // null), cycle: (.cycle // null),
                         fields: (del(.event,.ts,.node,.cycle,.repo,.item))})) as $instants
      | ([$sorted[] | select(.event == "first-seen") | (.ts // "")] | map(select(. != "")) | sort | first) as $first_seen_ts
      | ([$sorted[] | select(.event == "selection")] | sort_by(.ts // "") | last | .source) as $source
      | ($full_by_key[$r + "|" + $i] // []) as $full_events
      | ([$full_events[] | select(.event == "merge-observed" or .event == "issue-closed-post-merge") | (.ts // "")]
          | map(select(. != "")) | sort | first) as $landed_ts
      | ($landed_ts != null) as $landed
      | ([$full_events[] | select(.event == "orphan-branch-released" and (.reason // "") == "superseded")] | length > 0) as $superseded_evidence
      | (resolved($obsolete; $r; $i)) as $abandoned_evidence
      | (resolved($void; $r; $i)) as $voided
      | (resolved_ts($void; $r; $i)) as $void_ts
      | (resolved($blocked; $r; $i)) as $blocked_flag
      | ($landed and $voided and $void_ts != null and $void_ts > $landed_ts) as $contradictory
      | (if $contradictory then
           {fate: "unaccounted",
            reason: ("voided (at " + $void_ts + ") after merge evidence at " + $landed_ts
                      + " — contradictory, not resolved automatically")}
         elif $landed then {fate: "landed"}
         elif $voided then {fate: "voided"}
         elif $superseded_evidence then {fate: "superseded"}
         elif $blocked_flag then {fate: "blocked"}
         elif $abandoned_evidence then {fate: "abandoned"}
         else {fate: "open"}
         end) as $fate_obj
      | {repo: $r, item: $i, source: $source, first_seen: $first_seen_ts, instants: $instants}
        + $fate_obj
    ) as $records
  | ($records | map(select(.fate == "landed"))      | length) as $n_landed
  | ($records | map(select(.fate == "voided"))      | length) as $n_voided
  | ($records | map(select(.fate == "superseded"))  | length) as $n_superseded
  | ($records | map(select(.fate == "abandoned"))   | length) as $n_abandoned
  | ($records | map(select(.fate == "blocked"))     | length) as $n_blocked
  | ($records | map(select(.fate == "open"))        | length) as $n_open
  | ($records | map(select(.fate == "unaccounted")) | length) as $n_unaccounted
  | ($records | length) as $n_entered
  | {
      window: $window,
      totals: {
        entered: $n_entered,
        leaving: ($n_landed + $n_voided + $n_superseded + $n_abandoned),
        in_progress: ($n_blocked + $n_open),
        unaccounted: $n_unaccounted,
        balanced: (($n_landed + $n_voided + $n_superseded + $n_abandoned
                     + $n_blocked + $n_open + $n_unaccounted) == $n_entered)
      },
      fates: {landed: $n_landed, voided: $n_voided, superseded: $n_superseded,
              abandoned: $n_abandoned, blocked: $n_blocked, open: $n_open},
      unaccounted: ($records | map(select(.fate == "unaccounted")) | map({repo, item, reason})),
      records: ($records | map(del(.reason)))
    }
'

# item_lifecycle_fold LOG_FILE [SINCE]
# Print the item-lifecycle report — `window`, `totals` (the flow invariant),
# `fates`, `unaccounted[]` and `records[]` — folded from LOG_FILE, or stdin if
# it is "-". Requires `lib/cycle-state.sh` (`blocked_items`, `void_items`,
# `draft_obsolete_flags`) already sourced.
#
# Always succeeds, printing the all-empty shape for a missing, empty or
# unreadable log, on the same terms `blocked_items`/`void_items` already do:
# a caller running under `set -e` must not be killed by one, and a log that
# cannot be read enters nothing.
item_lifecycle_fold() {
  local src="${1:--}" since="${2:-}" raw="" all_json="" void_json blocked_json obsolete_json out=""
  # Read the whole log into a variable rather than a file descriptor: stdin
  # can only be consumed once, and `void_items`/`blocked_items`/
  # `draft_obsolete_flags` each need their own full read below, exactly as
  # this function's own fold does.
  if [[ "$src" == "-" ]]; then
    raw="$(cat 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    raw="$(cat "$src" 2>/dev/null || true)"
  fi

  all_json="$(jq -c -R 'fromjson? // empty' <<<"$raw" 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  [[ -n "$all_json" ]] || all_json='[]'

  void_json="$(void_items - <<<"$raw" 2>/dev/null || true)"
  [[ -n "$void_json" ]] || void_json='[]'
  blocked_json="$(blocked_items - <<<"$raw" 2>/dev/null || true)"
  [[ -n "$blocked_json" ]] || blocked_json='[]'
  obsolete_json="$(draft_obsolete_flags - <<<"$raw" 2>/dev/null || true)"
  [[ -n "$obsolete_json" ]] || obsolete_json='[]'

  out="$(jq -nc --arg since "$since" \
      'input as $all | input as $void | input as $blocked | input as $obsolete | ('"$ITEM_LIFECYCLE_FOLD_JQ"')' \
      <<<"$all_json"$'\n'"$void_json"$'\n'"$blocked_json"$'\n'"$obsolete_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='{"window":{"from":null,"to":null},"totals":{"entered":0,"leaving":0,"in_progress":0,"unaccounted":0,"balanced":true},"fates":{"landed":0,"voided":0,"superseded":0,"abandoned":0,"blocked":0,"open":0},"unaccounted":[],"records":[]}'
  printf '%s' "$out"
}
