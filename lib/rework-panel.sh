#!/usr/bin/env bash
#
# lib/rework-panel.sh — the rework panel (docs/FLOW-SCHEMA.md's "rework
# record" and "item lifecycle record", D23 of docs/ROADMAP.md, issue #611).
#
# Answers exactly three questions from data that already exists — nothing
# inferred, nothing re-classified:
#
#   how much?   rework's share of tokens and of elapsed time, against
#               first-pass yield.
#   whose?      repetitions grouped by `attributed_stage`, with an explicit
#               "not attributed" bucket for the seven classes
#               docs/FLOW-SCHEMA.md's own attribution rule leaves `null` —
#               never inferred here either.
#   how far?    the escape ladder — one row per detection stage in the
#               pipeline's own cost order (agent review, the human gate,
#               post-merge), each carrying the share of caught defects that
#               passed that rung and the measured cost of catching one at
#               the next.
#
# D23 is emphatic that rework is never a target of zero: a Reviewer catching
# a defect is the system working, not failing. This module never collapses
# "how much" and "how far" into one score for exactly that reason — a naive
# reader watching only `escape_ladder[agent-review].caught` (how many
# defects the Reviewer itself caught) could mistake a Reviewer that has
# started waving work through for an improvement, since that count falls
# exactly when defects stop being caught there. Keeping `caught` and
# `escape_rate` as two separate fields on the same row — one a raw count,
# the other the share of that rung's own population that went on uncaught —
# is what lets a falling `caught` alongside a rising `escape_rate` stay
# legible as a regression instead of cancelling out inside one blended
# score.
#
# A pure derivation, on the same terms lib/item-lifecycle.sh's
# `item_lifecycle_fold` and lib/rework.sh's `rework_fields` already are:
# reads the log, touches no lock, writes no event. Reuses
# `item_lifecycle_fold` for first-pass yield and the escape ladder's own
# population (landed items) rather than re-deriving fate from the log a
# second time. Callers must source lib/cycle-state.sh and
# lib/item-lifecycle.sh before this file; the one production caller,
# scripts/publish-dashboard.sh, sources all three in that order, and
# test/rework-panel.test.sh does the same.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# The {repo, item} join key, identical to lib/item-lifecycle.sh's own
# `item_key` — item coerced with `tostring` so a numeric and a string item id
# are the same key.
# shellcheck disable=SC2016  # jq's own def, not the shell's.
REWORK_PANEL_KEY_JQ='
  def rw_item_key: ((.repo // "") | tostring) + "|" + ((.item // "") | tostring);
'

# The main fold. $all (every parsed event this run can see) and $lifecycle
# (item_lifecycle_fold's own report over the same log) arrive on stdin as two
# documents, bound positionally by the caller — big-things-on-stdin,
# requirement 4g, the same convention lib/item-lifecycle.sh's own
# ITEM_LIFECYCLE_FOLD_JQ follows for $all/$void/$blocked/$obsolete.
#
# --- Deduping the rework stream (docs/FLOW-SCHEMA.md, "Do not double-count")
# The union log carries every node's own copy of a repetition two or more
# nodes each observed, so this reduces first-wins-by-`ts` — the reduction that
# section states in its own words, and the copy whose `cycle` actually first
# observed the repetition rather than whichever node echoed it last — on the
# record's own stable identity: `{repo, item, class}` for every
# class but `post-merge-revert`, which adds `evidence.by` (the reverting or
# following-up pull request), since more than one corrective pull request can
# in principle be detected for the same original. A fleet-wide class with
# neither `repo` nor `item` (crash-loop escalation, and every Co-Ordinator/
# Enabler/Refiner backstop `stage-rerun`) has no such identity — `{repo, item,
# class}` alone degenerates to one key shared by every occurrence of that
# class across the whole log's history, not just the one repetition several
# nodes echoed — so these additionally carry `ts` and `evidence` into the key,
# distinguishing genuinely separate occurrences while still collapsing exact
# same-instant copies of one occurrence the same way the item-bearing classes
# do. `evidence.by` on a non-object `evidence` (a bare string or number,
# `docs/FLOW-SCHEMA.md`'s "any | null") would abort the whole fold from inside
# this `def` if indexed directly, so the `post-merge-revert` branch routes it
# through `objects` first — an empty result there (not an object) falls
# through `//` to `""` exactly like a genuinely absent field would. The
# item-less branch embeds `.evidence` itself rather than indexing into it, so
# it needs no such guard.
#
# --- The escape ladder's rung mapping
# Three rungs, in the pipeline's own rising cost order (issue #611's own
# framing): `agent-review` (every class but the two below — a Reviewer or an
# earlier stage catching something before a human ever looks), `human-gate`
# (`human-change-request` — the reconciliation gate's own dirty verdict at
# the Reviewer's handoff), `post-merge` (`post-merge-revert` — nothing caught
# it until a corrective pull request landed after merge). This is a mapping
# from the nine documented classes to the three rungs docs/ROADMAP.md's D23
# names, never an attribution guess — the same class-to-rung table
# docs/DASHBOARD-SPEC.md documents in prose for this panel.
#
# --- The escape ladder's population: caught defects, not all landed items
# A landed item with zero rework records of any class may have had zero real
# defects, or may have had one nothing here ever caught — the two are
# indistinguishable from this record alone, and this module does not guess
# which. So the ladder's population at the agent-review rung is *only* landed
# items with at least one caught defect (at any rung) — `clean_count` reports
# the excluded, never-caught-anything population separately, rather than
# folding it into a rate that would otherwise overstate how much passed
# undetected. `escape_rate` at a rung is what fraction of that rung's own
# population (items whose defect was not yet caught) went on uncaught to a
# later rung; the post-merge rung is terminal — it has no further rung to
# escape to, so it reports no rate, not a `0` that would misread as "always
# caught here."
#
# --- First-pass yield is the narrower, literally-specified reading
# "An item lifecycle record with fate=landed and zero rework records
# *attributed to a stage*" (issue #611's own refinement) — i.e. zero records
# whose `attributed_stage` is non-null (`human-change-request`,
# `stage-rerun`), not zero rework records of any class. A landed item that
# bounced once on `review-round-trip` (attribution `null`, D23's own
# attribution rule) still counts as first-pass by this literal definition.
# `clean_count` above is the different, broader figure — zero rework records
# of any class — reported separately so the two are never confused for one
# another on the page.
#
# --- The cost join
# `cost_by_cycle` sums each `stage-end` event's own `cost_usd`/`duration_ms`/
# `tokens.*` (null-as-zero, docs/METERING-SCHEMA.md's own aggregation rule),
# grouped by that event's `cycle` — the same field a `rework` event carries
# from the identical `log_event` envelope (lib/rework.sh's own header), except
# `post-merge-revert`, whose `cycle` is always `null` because that class is
# mined after the fact, outside any cycle. "The measured cost of catching one
# at the next rung" is therefore genuinely unmeasurable for the human-gate
# row's own "next" (post-merge) — reported as `null` with its own
# `cost_to_catch_at_next_note` explaining why, distinct from the post-merge
# row's `null` (which means "terminal, no next rung" instead).
#
# A catch whose own `cycle` this log carries no `stage-end` for at all — a
# peer's log that failed to fetch, a cycle whose stage events have aged out of
# what survives — is dropped from the average rather than folded in as a
# zero-cost sample: an unmeasured cycle counted as `0` would drag the reported
# cost of catching a defect toward zero and read as measured, which is the same
# "an outage is not a quiet zero" distinction every other roll-up on the page
# makes. So `n` is the number of catches actually measured, never the number
# that happened, and a rung with catches but no metering for any of them reads
# `null` with its own note rather than `$0.00`.
#
# The whole of a rework-bearing cycle's spend counts as rework in `how_much`:
# `stage-end` meters a stage, and nothing in docs/FLOW-SCHEMA.md's record says
# which part of a cycle a repetition consumed, so no apportionment within a
# cycle is derivable here. That makes `rework_share` an upper bound rather than
# a measured split — stated in those words on the panel's own face, and in
# docs/DASHBOARD-SPEC.md.
# shellcheck disable=SC2016  # jq's own $all/$lifecycle/etc, not the shell's.
REWORK_PANEL_JQ='
  '"$REWORK_PANEL_KEY_JQ"'
  def rung_of:
    if .class == "post-merge-revert" then "post-merge"
    elif .class == "human-change-request" then "human-gate"
    else "agent-review" end;
  def dedup_key:
    if .class == "post-merge-revert"
    then [(.repo // ""), (.item // ""), .class, ((.evidence | objects | .by) // "")]
    elif (.repo // "") == "" and (.item // "") == ""
    then [(.repo // ""), (.item // ""), .class, (.ts // ""), (.evidence // null)]
    else [(.repo // ""), (.item // ""), .class] end;
  def sum_field($f): (map(.[$f] // 0) | add) // 0;
  def share($total; $part): if $total == 0 then null else ($part / $total) end;

  ($all | map(select(type == "object"))) as $ev

  # $rew_raw is every parsed rework event, pre-dedup — used only where a
  # cycle being present in the rework stream at all is what matters (the
  # tokens/time share below), never for a count, which always reads the
  # deduped $rew instead.
  | ($ev | map(select(.event == "rework"))) as $rew_raw

  | ($rew_raw
     | group_by(dedup_key) | map(sort_by(.ts // "") | first)
     | map(. + {rung: rung_of})) as $rew

  | ($ev | map(select(.event == "stage-end" and ((.cycle // "") | tostring) != ""))
     | map({cycle: (.cycle | tostring),
            cost_usd: (.cost_usd // 0), duration_ms: (.duration_ms // 0),
            tokens: (((.tokens.input // 0) + (.tokens.output // 0)
                      + (.tokens.cache_creation // 0) + (.tokens.cache_read // 0)))})
     | group_by(.cycle)
     | map({key: .[0].cycle, value: {
         cost_usd: (map(.cost_usd) | add), duration_ms: (map(.duration_ms) | add),
         tokens: (map(.tokens) | add)}})
     | from_entries) as $cost_by_cycle

  | def avg_cost($rows):
       ($rows | map(.cycle // null) | map(select(. != null)) | map(tostring)
              | map($cost_by_cycle[.]) | map(select(. != null))) as $costs
       | if ($costs | length) == 0 then null
         else { n: ($costs | length),
                tokens: (($costs | map(.tokens) | add) / ($costs | length)),
                elapsed_ms: (($costs | map(.duration_ms) | add) / ($costs | length)),
                cost_usd: (($costs | map(.cost_usd) | add) / ($costs | length)) }
         end;

  ($lifecycle.records // []) as $records
  | ($records | map(select(.fate == "landed"))) as $landed
  | ($landed | map(rw_item_key)) as $landed_keys
  | ($landed | length) as $landed_total

  # --- Whose: grouped by attributed_stage, explicit not-attributed bucket ---
  | ($rew | map(select(.attributed_stage != null))) as $attributed
  | ($rew | map(select(.attributed_stage == null))) as $unattributed
  | ({
      by_attributed_stage: ($attributed | group_by(.attributed_stage)
        | map({stage: .[0].attributed_stage, count: length}) | sort_by(.stage)),
      not_attributed: {
        count: ($unattributed | length),
        by_class: ($unattributed | group_by(.class)
          | map({class: .[0].class, count: length}) | sort_by(.class))
      }
    }) as $whose

  # --- How much: tokens/elapsed share, first-pass yield -------------------
  # $rework_cycles reads $rew_raw, not the deduped $rew: a cycle carrying a
  # rework record whose copy lost the {repo, item, class} first-wins dedup
  # (a peer node echoing the same repetition, or — before this fix — any
  # second same-class repetition landing in the same review-feedback round)
  # is still a cycle real rework work happened in, so it still belongs in the
  # rework-spend bucket below. The record-level dedup above still governs
  # every *count* (`rework_count`, `whose`, the escape ladder) — only this
  # cycle-membership test reads the raw stream, which is what keeps
  # `rework_share` the upper bound its own comment below and
  # docs/DASHBOARD-SPEC.md promise, never an undercount.
  | ($rew_raw | map(.cycle) | map(select(. != null)) | unique) as $rework_cycles
  | ($cost_by_cycle | to_entries) as $cost_entries
  | ($cost_entries | map(.value)) as $all_costs
  | ($cost_entries | map(select(.key as $k | $rework_cycles | index($k) != null)) | map(.value)) as $rework_costs
  | ({ tokens: ( ($all_costs | sum_field("tokens")) as $t
                 | ($rework_costs | sum_field("tokens")) as $r
                 | {total: $t, rework: $r, rework_share: share($t; $r)} ),
       elapsed_ms: ( ($all_costs | sum_field("duration_ms")) as $t
                 | ($rework_costs | sum_field("duration_ms")) as $r
                 | {total: $t, rework: $r, rework_share: share($t; $r)} ),
       cost_usd: ( ($all_costs | sum_field("cost_usd")) as $t
                 | ($rework_costs | sum_field("cost_usd")) as $r
                 | {total: $t, rework: $r, rework_share: share($t; $r)} )
     }) as $tokens_time

  | ($attributed | map(rw_item_key) | unique) as $attributed_keys
  | ($landed_keys | map(select(. as $k | $attributed_keys | index($k) == null)) | length) as $first_pass_n
  | ({ landed_total: $landed_total, first_pass: $first_pass_n,
       yield: share($landed_total; $first_pass_n) }) as $first_pass_yield

  # --- How far: the escape ladder ------------------------------------------
  | ($rew | map(select(rw_item_key as $k | ($k | test("^\\|$")) | not))) as $item_rew
  | ($item_rew | group_by(rw_item_key)
     | map({key: (.[0] | rw_item_key),
            furthest: ( [.[].rung] | unique
              | if index("post-merge") then "post-merge"
                elif index("human-gate") then "human-gate"
                else "agent-review" end )})
     | map({key, value: .furthest}) | from_entries) as $furthest_by_key
  | ($landed_keys | map($furthest_by_key[.] // "none")) as $furthest_list
  | ($furthest_list | map(select(. == "agent-review")) | length) as $n_agent_review
  | ($furthest_list | map(select(. == "human-gate")) | length) as $n_human_gate
  | ($furthest_list | map(select(. == "post-merge")) | length) as $n_post_merge
  | ($furthest_list | map(select(. == "none")) | length) as $n_clean
  | (avg_cost($item_rew | map(select(.rung == "human-gate")))) as $cost_human_gate
  | (avg_cost($item_rew | map(select(.rung == "post-merge")))) as $cost_post_merge
  | ( ($n_agent_review + $n_human_gate + $n_post_merge) ) as $pop_agent_review
  | ( $n_human_gate + $n_post_merge ) as $pop_human_gate
  | ( $n_post_merge ) as $pop_post_merge
  | ([
      { stage: "agent-review", population: $pop_agent_review, caught: $n_agent_review,
        escaped: ($pop_agent_review - $n_agent_review),
        escape_rate: share($pop_agent_review; ($pop_agent_review - $n_agent_review)),
        cost_to_catch_at_next: $cost_human_gate,
        cost_to_catch_at_next_note: (if $cost_human_gate == null
          then "no human-gate catch with metered cycle spend in this window to measure"
          else null end) },
      { stage: "human-gate", population: $pop_human_gate, caught: $n_human_gate,
        escaped: ($pop_human_gate - $n_human_gate),
        escape_rate: share($pop_human_gate; ($pop_human_gate - $n_human_gate)),
        cost_to_catch_at_next: $cost_post_merge,
        cost_to_catch_at_next_note: "not measurable: post-merge-revert records carry no cycle (mined after the fact, outside any cycle)" },
      { stage: "post-merge", population: $pop_post_merge, caught: $n_post_merge,
        escaped: null, escape_rate: null,
        cost_to_catch_at_next: null,
        cost_to_catch_at_next_note: "terminal rung: nothing further to escape to" }
    ]) as $escape_ladder

  | {
      how_much: ($tokens_time + { first_pass_yield: $first_pass_yield, rework_count: ($rew | length) }),
      whose: $whose,
      escape_ladder: $escape_ladder,
      clean_count: $n_clean
    }
'

# rework_panel_build LOG_FILE [SINCE]
# Print the rework panel — `how_much`, `whose`, `escape_ladder`, `clean_count`
# — folded from LOG_FILE, or stdin if it is "-". Requires lib/cycle-state.sh
# and lib/item-lifecycle.sh already sourced (item_lifecycle_fold supplies the
# landed population first-pass yield and the escape ladder both read).
#
# SINCE, like item_lifecycle_fold's own, bounds only the landed *population*
# (`item_lifecycle_fold`'s own "population, never fate" contract) — the
# rework stream's own dedup and rung classification always read the whole
# log, since a caught defect's rung is a permanent fact about it, the same
# "never windowed" argument docs/DASHBOARD-SPEC.md's escape-audits paragraph
# makes. The Publisher calls with SINCE empty (unwindowed throughout); a
# future caller passing one narrows which landed items this run reports
# without changing how any one of them is classified.
#
# Always succeeds, on the same terms item_lifecycle_fold already does: a
# caller running under `set -e` must not be killed by one. It distinguishes
# the two ways there can be nothing to report, because they mean opposite
# things to a reader:
#
#   A missing, empty or unreadable log is not a failure — the fold runs to
#   completion over an empty stream and reports the all-zero shape, which is
#   the true statement "no rework recorded".
#
#   The fold itself failing is. jq aborts the whole program from inside a
#   `def` on any field a record shapes differently than the fold expects, and
#   nothing partial survives that — so the all-zero shape would be a
#   confidently-stated falsehood, indistinguishable on the page from a fleet
#   that genuinely repeated no work. This reports the outage shape instead
#   (`{how_much: null, whose: null, escape_ladder: null, clean_count: null}`,
#   docs/DASHBOARD-SPEC.md), the same "an outage is not a quiet zero"
#   distinction every other roll-up on the page makes, and the same shape
#   scripts/publish-dashboard.sh substitutes when it cannot assemble the
#   payload at all. Guarding each individual index against every shape a
#   malformed peer record could take is unbounded; keeping the fallback
#   honest is not, and holds for the errors nobody anticipated as well as
#   the ones they did.
rework_panel_build() {
  local src="${1:--}" since="${2:-}" raw="" all_json="" lifecycle_json="" out=""
  if [[ "$src" == "-" ]]; then
    raw="$(cat 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    raw="$(cat "$src" 2>/dev/null || true)"
  fi

  lifecycle_json="$(item_lifecycle_fold - "$since" <<<"$raw" 2>/dev/null || true)"
  [[ -n "$lifecycle_json" ]] || lifecycle_json='{"records":[]}'

  all_json="$(jq -c -R 'fromjson? // empty' <<<"$raw" 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  [[ -n "$all_json" ]] || all_json='[]'

  out="$(jq -nc 'input as $all | input as $lifecycle | ('"$REWORK_PANEL_JQ"')' \
      <<<"$all_json"$'\n'"$lifecycle_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='{"how_much":null,"whose":null,"escape_ladder":null,"clean_count":null}'
  printf '%s' "$out"
}
