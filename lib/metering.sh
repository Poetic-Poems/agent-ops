#!/usr/bin/env bash
#
# lib/metering.sh — the per-stage metering record (docs/METERING-SCHEMA.md,
# requirement 33a of docs/IMPLEMENTATION-PIPELINE-SPEC.md).
#
# Sourced by agent-cycle.sh and review-cycle.sh so both pipelines derive the
# same record from a stage's own JSON envelope — the `result` event
# lib/stage-run.sh leaves in `<stage>.out` — rather than each growing its own
# copy of the field list.

# metering_fields MODEL OUT_FILE
# Prints the documented per-stage metering object: model, cost_usd,
# duration_ms, num_turns, is_error, and tokens{input,output,cache_creation,
# cache_read}. MODEL is the id passed to the invocation (not re-derived from
# the envelope, which may be silent or ambiguous about it); OUT_FILE is the
# stage's own `.out` transcript.
#
# tokens sums the envelope's `modelUsage` map across every model entry rather
# than reading its top-level `usage` object: `usage` excludes subagent
# activity while `modelUsage` — like `total_cost_usd` — includes it, and the
# two would otherwise disagree about what "this stage" spent. `tokens` is
# null when `modelUsage` is absent or empty, exactly as `cost_usd` and the
# rest are null when the envelope itself is missing or unparseable — a stage
# that never ran, or crashed before writing one, degrades this whole object
# to nulls rather than aborting the log_event call it feeds. `model` alone is
# always present: it is the argument, not something read out of the envelope.
#
# That degradation has to hold for *any* envelope, not just the shapes
# anticipated below, because of what the callers do with the result: it is
# interpolated into `jq --argjson m` at the `stage-end` site, so a run that
# printed nothing would fail that jq too and cost the whole event its `stage`
# and `exit_code` — the fields requirements 33/34 key on — not merely its
# metering. Hence both the per-entry `select` in `tokens` and the fallback
# after the call: whatever jq makes of the envelope, this function prints one
# valid object.
metering_fields() {
  local model="$1" out_file="$2" record
  record="$(jq -nc --arg model "$model" \
    --rawfile raw <(cat "$out_file" 2>/dev/null || printf '{}') '
    ($raw | try fromjson catch {}) as $raw_e
    | (if ($raw_e | type) == "object" then $raw_e else {} end) as $e
    # `// null` would be wrong here: jq treats `0` and `false` as falsy, so a
    # genuinely-zero cost, duration, turn count or a false `is_error` would
    # collapse to null exactly like a truly-absent field. `has` distinguishes
    # "present and zero/false" from "absent".
    | def present($k): $e | has($k);
      {
        model: $model,
        cost_usd: (if present("total_cost_usd") then $e.total_cost_usd else null end),
        duration_ms: (if present("duration_ms") then $e.duration_ms else null end),
        num_turns: (if present("num_turns") then $e.num_turns else null end),
        is_error: (if present("is_error") then $e.is_error else null end),
        # `select(type == "object")` per entry, not just on the map: indexing
        # a scalar entry with `.inputTokens` is a hard jq error, which would
        # take the whole program — and with it `cost_usd`, which was perfectly
        # readable — down with it. Skipping the entry sums what is countable.
        tokens: (
          ($e.modelUsage // {}) as $mu
          | (if ($mu | type) == "object" then [$mu[] | select(type == "object")] else [] end) as $used
          | if ($used | length) == 0 then null
            else {
              input: ([$used[] | (.inputTokens // 0)] | add),
              output: ([$used[] | (.outputTokens // 0)] | add),
              cache_creation: ([$used[] | (.cacheCreationInputTokens // 0)] | add),
              cache_read: ([$used[] | (.cacheReadInputTokens // 0)] | add)
            }
            end
        )
      }' 2>/dev/null)" || record=""
  if [[ -z "$record" ]]; then
    record="$(jq -nc --arg model "$model" \
      '{model: $model, cost_usd: null, duration_ms: null, num_turns: null, is_error: null, tokens: null}')"
  fi
  printf '%s\n' "$record"
}
