#!/usr/bin/env bash
#
# test/metering.test.sh — self-contained regression test for
# lib/metering.sh (docs/METERING-SCHEMA.md, requirement 33a of
# docs/IMPLEMENTATION-PIPELINE-SPEC.md).
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/metering.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/metering.sh
. "$SCRIPT_DIR/lib/metering.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

failures=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# Runs metering_fields and pipes it through `jq -c FILTER` for a one-value
# comparison — every assertion below reduces the whole object to the single
# field (or sub-expression) it cares about.
field() {
  local model="$1" out_file="$2" filter="$3"
  metering_fields "$model" "$out_file" | jq -c "$filter"
}

# --- A well-formed single-model envelope: every field is pulled straight
#     from the stage's own result envelope, and tokens sums the
#     one modelUsage entry. ---
single="$work_dir/single.out"
cat > "$single" <<'JSON'
{"type":"result","subtype":"success","total_cost_usd":0.1234,"duration_ms":5000,
 "num_turns":3,"is_error":false,
 "modelUsage":{"claude-sonnet-5":{"inputTokens":100,"outputTokens":50,
   "cacheReadInputTokens":300,"cacheCreationInputTokens":200,"costUSD":0.1234}},
 "result":"ok"}
JSON

assert_eq "single-model: model is the passed-in id, not re-derived from the envelope" \
  '"claude-sonnet-5"' "$(field claude-sonnet-5 "$single" '.model')"
assert_eq "single-model: cost_usd is the envelope's total_cost_usd" \
  "0.1234" "$(field claude-sonnet-5 "$single" '.cost_usd')"
assert_eq "single-model: duration_ms is the envelope's duration_ms" \
  "5000" "$(field claude-sonnet-5 "$single" '.duration_ms')"
assert_eq "single-model: num_turns is the envelope's num_turns" \
  "3" "$(field claude-sonnet-5 "$single" '.num_turns')"
assert_eq "single-model: is_error is the envelope's is_error" \
  "false" "$(field claude-sonnet-5 "$single" '.is_error')"
assert_eq "single-model: tokens sums the one modelUsage entry" \
  '{"input":100,"output":50,"cache_creation":200,"cache_read":300}' \
  "$(field claude-sonnet-5 "$single" '.tokens')"

# --- A multi-model envelope (a stage whose subagents ran a different model):
#     tokens is the sum across every modelUsage entry, not just the primary
#     model's, matching how cost_usd already counts subagent spend. ---
multi="$work_dir/multi.out"
cat > "$multi" <<'JSON'
{"type":"result","subtype":"success","total_cost_usd":0.5,"duration_ms":9000,
 "num_turns":7,"is_error":false,
 "modelUsage":{
   "claude-opus-5":{"inputTokens":100,"outputTokens":50,"cacheReadInputTokens":10,"cacheCreationInputTokens":20,"costUSD":0.4},
   "claude-haiku-4-5":{"inputTokens":40,"outputTokens":10,"cacheReadInputTokens":5,"cacheCreationInputTokens":1,"costUSD":0.1}
 },
 "result":"ok"}
JSON

assert_eq "multi-model: model is still the invocation's own model, not a modelUsage key" \
  '"claude-opus-5"' "$(field claude-opus-5 "$multi" '.model')"
assert_eq "multi-model: cost_usd counts subagent spend (the envelope's own total)" \
  "0.5" "$(field claude-opus-5 "$multi" '.cost_usd')"
assert_eq "multi-model: tokens sums both models, not just the primary one" \
  '{"input":140,"output":60,"cache_creation":21,"cache_read":15}' \
  "$(field claude-opus-5 "$multi" '.tokens')"

# --- Falsy-but-present values (0, false) must survive, not collapse to null
#     the way a naive `// null` would treat them. ---
zero="$work_dir/zero.out"
cat > "$zero" <<'JSON'
{"total_cost_usd":0,"duration_ms":0,"num_turns":1,"is_error":false,"modelUsage":{}}
JSON

assert_eq "a genuinely zero cost_usd survives (not collapsed to null)" \
  "0" "$(field claude-sonnet-5 "$zero" '.cost_usd')"
assert_eq "a genuinely zero duration_ms survives (not collapsed to null)" \
  "0" "$(field claude-sonnet-5 "$zero" '.duration_ms')"
assert_eq "a false is_error survives (not collapsed to null)" \
  "false" "$(field claude-sonnet-5 "$zero" '.is_error')"
assert_eq "an empty modelUsage map yields null tokens, not an empty-but-present object" \
  "null" "$(field claude-sonnet-5 "$zero" '.tokens')"

# --- Degradation: a missing, empty or unparseable out-file must never abort
#     the caller's log_event — every field becomes null instead. ---
missing="$work_dir/does-not-exist.out"
empty="$work_dir/empty.out"
printf '{}' > "$empty"
malformed="$work_dir/malformed.out"
printf 'not json at all' > "$malformed"

# `model` is the argument, never read from the envelope, so it is the one
# field still populated when everything else degrades.
all_null='{"model":"claude-sonnet-5","cost_usd":null,"duration_ms":null,"num_turns":null,"is_error":null,"tokens":null,"gaps":null}'

assert_eq "a missing out-file degrades to nulls, keeping the passed-in model" \
  "$all_null" "$(metering_fields claude-sonnet-5 "$missing" | jq -c .)"
assert_eq "an empty-object envelope degrades to nulls, keeping the passed-in model" \
  "$all_null" "$(metering_fields claude-sonnet-5 "$empty" | jq -c .)"
assert_eq "an unparseable envelope degrades to nulls, keeping the passed-in model" \
  "$all_null" "$(metering_fields claude-sonnet-5 "$malformed" | jq -c .)"

# --- An envelope no shape above anticipates must still yield one valid
#     object. The callers interpolate this into `jq --argjson m` at the
#     stage-end site, so printing nothing would cost the event its `stage` and
#     `exit_code` too, not just its metering. ---
scalar_usage="$work_dir/scalar-usage.out"
printf '{"total_cost_usd":0.4,"modelUsage":{"claude-opus-5":7}}' > "$scalar_usage"

assert_eq "a modelUsage entry that is not an object is skipped, not fatal" \
  "null" "$(field claude-opus-5 "$scalar_usage" '.tokens')"
assert_eq "and the rest of that envelope is still read" \
  "0.4" "$(field claude-opus-5 "$scalar_usage" '.cost_usd')"

mixed_usage="$work_dir/mixed-usage.out"
printf '{"modelUsage":{"claude-opus-5":{"inputTokens":10,"outputTokens":5},"broken":"x"}}' > "$mixed_usage"

assert_eq "a mix of usable and unusable entries sums the usable ones" \
  '{"input":10,"output":5,"cache_creation":0,"cache_read":0}' \
  "$(field claude-opus-5 "$mixed_usage" '.tokens')"

assert_eq "every envelope shape yields a parseable object, never empty output" \
  "object" "$(metering_fields claude-opus-5 "$scalar_usage" | jq -r 'type')"

# --- gaps: the one field that is not read from the envelope --------------------
# It is measured by the Script while the stage runs (lib/stage-run.sh) and
# handed in, so what belongs here is only that it is carried faithfully and
# that a caller which cannot supply it — or supplies rubbish — still gets a
# conforming record rather than a failed jq.
gaps='{"n":4,"p50":6,"p95":40,"p99":40,"max":40}'
assert_eq "gaps are carried through exactly as given" \
  "$gaps" "$(metering_fields claude-sonnet-5 "$single" "$gaps" | jq -c '.gaps')"
assert_eq "an omitted gaps argument is null, not a missing key" \
  "true" "$(metering_fields claude-sonnet-5 "$single" | jq -c 'has("gaps") and .gaps == null')"
assert_eq "an explicit null is null" \
  "null" "$(metering_fields claude-sonnet-5 "$single" null | jq -c '.gaps')"
assert_eq "an unparseable gaps argument degrades to null rather than failing the record" \
  "null" "$(metering_fields claude-sonnet-5 "$single" 'not json' | jq -c '.gaps')"
assert_eq "…and the rest of that record is intact" \
  "0.1234" "$(metering_fields claude-sonnet-5 "$single" 'not json' | jq -c '.cost_usd')"

echo
if (( failures == 0 )); then
  echo "All metering assertions passed."
  exit 0
else
  echo "$failures metering assertion(s) FAILED."
  exit 1
fi
