#!/usr/bin/env bash
#
# lib/metering.sh — the per-stage metering record (docs/METERING-SCHEMA.md,
# requirement 33a of docs/IMPLEMENTATION-PIPELINE-SPEC.md).
#
# Sourced by agent-cycle.sh and review-cycle.sh so both pipelines derive the
# same record from a stage's own `claude --output-format json` envelope,
# rather than each growing its own copy of the field list.

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
# to nulls rather than aborting the log_event call it feeds.
metering_fields() {
  local model="$1" out_file="$2"
  jq -nc --arg model "$model" \
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
        tokens: (
          ($e.modelUsage // {}) as $mu
          | if ($mu | type) != "object" or ($mu | length) == 0 then null
            else {
              input: ([$mu[] | (.inputTokens // 0)] | add),
              output: ([$mu[] | (.outputTokens // 0)] | add),
              cache_creation: ([$mu[] | (.cacheCreationInputTokens // 0)] | add),
              cache_read: ([$mu[] | (.cacheReadInputTokens // 0)] | add)
            }
            end
        )
      }' 2>/dev/null
}
