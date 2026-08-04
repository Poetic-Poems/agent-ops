#!/usr/bin/env bash
#
# test/config-schema.test.sh — self-contained regression test for
# config.schema.json, lib/config-schema.sh and the configuration half of
# scripts/doctor.sh (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 4c).
#
# Three things are asserted, and they fail in different directions:
#
#   - **The shipped config validates.** If it ever stops doing so the schema
#     and the system have diverged, and since agent-cycle.sh does not read the
#     schema, the pipeline would go on running while the check that is supposed
#     to describe it says it cannot. That is the one failure here that means
#     the *schema* is wrong rather than the config.
#   - **Every keyword the schema uses is enforced.** A validator that silently
#     ignores a keyword is worse than no validator: the operator is told the
#     config is fine. So each keyword config.schema.json actually uses is
#     exercised with a value that must be rejected — and the rule that the
#     schema may only use keywords lib/config-schema.sh implements is itself
#     asserted, by reading the keywords out of the schema and comparing them
#     against the supported set.
#   - **doctor.sh's cross-key rules fire.** These are the checks the schema
#     cannot express, each mirroring a startup guard in agent-cycle.sh or a
#     requirement whose breach is silent. They are asserted through the shipped
#     script, against mutations of the shipped config, so what is tested is
#     doctor.sh rather than a restatement of its logic.
#
# Every case is a mutation of the repository's own config.json, so a key added
# to the config without a schema entry fails the very first assertion.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/config-schema.test.sh
#
# Exit status is 0 iff every assertion passed. No network is used — doctor.sh
# is always invoked with --offline.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"

CONFIG="$SCRIPT_DIR/config.json"
SCHEMA="$SCRIPT_DIR/config.schema.json"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; failures=$(( failures + 1 )); }

# assert_valid DESC JQ_MUTATION
# The mutated config must validate cleanly.
assert_valid() {
  local desc="$1" mutation="$2" out
  jq "$mutation" "$CONFIG" > "$tmp/c.json" || { bad "$desc (mutation did not apply)"; return; }
  if out="$(config_schema_errors "$tmp/c.json" "$SCHEMA")"; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     unexpected error(s): %s\n' "$desc" "$out"
    failures=$(( failures + 1 ))
  fi
}

# assert_rejected DESC JQ_MUTATION SUBSTRING
# The mutated config must be rejected, and the message must name the offending
# path — an error that does not say *where* sends the operator hunting through
# a fifty-key file.
assert_rejected() {
  local desc="$1" mutation="$2" expect="$3" out
  jq "$mutation" "$CONFIG" > "$tmp/c.json" || { bad "$desc (mutation did not apply)"; return; }
  if out="$(config_schema_errors "$tmp/c.json" "$SCHEMA")"; then
    printf 'FAIL - %s\n     expected a rejection, got none\n' "$desc"
    failures=$(( failures + 1 ))
  elif [[ "$out" == *"$expect"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected message containing: %s\n     actual: %s\n' \
      "$desc" "$expect" "$out"
    failures=$(( failures + 1 ))
  fi
}

# assert_doctor DESC JQ_MUTATION EXPECTED_EXIT SUBSTRING
assert_doctor() {
  local desc="$1" mutation="$2" expected_exit="$3" expect="$4" out status
  jq "$mutation" "$CONFIG" > "$tmp/c.json" || { bad "$desc (mutation did not apply)"; return; }
  # Not --quiet: several of the rules below are asserted through the `ok` line
  # they print, and a check that passes silently cannot be told from one that
  # never ran.
  out="$(bash "$SCRIPT_DIR/scripts/doctor.sh" --offline --config "$tmp/c.json" 2>&1)"
  status=$?
  if (( status != expected_exit )); then
    printf 'FAIL - %s\n     expected exit %s, got %s\n     output: %s\n' \
      "$desc" "$expected_exit" "$status" "$out"
    failures=$(( failures + 1 ))
  elif [[ "$out" == *"$expect"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected output containing: %s\n     actual: %s\n' \
      "$desc" "$expect" "$out"
    failures=$(( failures + 1 ))
  fi
}

# --- The shipped configuration is the schema's first and most important
#     witness: it is the one config known to run a real fleet. ---
if out="$(config_schema_errors "$CONFIG" "$SCHEMA")"; then
  pass "the repository's own config.json validates against the schema"
else
  printf 'FAIL - the repository'"'"'s own config.json validates against the schema\n     %s\n' "$out"
  failures=$(( failures + 1 ))
fi

# --- The schema may only use keywords lib/config-schema.sh implements.
#     Without this, adding `oneOf` to the schema would not fail anything — it
#     would just quietly stop constraining the key it was added to. ---
# A quoted here-doc, so the four JSON Schema keywords that begin with `$` are
# the literal keyword names rather than shell expansions.
supported="$(sort -u <<'KEYWORDS'
$schema
$id
$ref
$defs
title
description
type
enum
const
minimum
maximum
exclusiveMinimum
exclusiveMaximum
minLength
pattern
minItems
uniqueItems
properties
required
additionalProperties
items
default
KEYWORDS
)"
used="$(jq -r '[paths(scalars != null) + paths(type == "object" or type == "array")]
  | map(map(select(type == "string")))
  | [ .[]
      | . as $p
      | range($p | length) as $i
      | select($i == 0
               or ($p[$i - 1] != "properties" and $p[$i - 1] != "$defs"))
      | $p[$i] ]
  | unique | .[]' "$SCHEMA" 2>/dev/null | sort -u)"
unsupported="$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$supported"))"
if [[ -z "$unsupported" ]]; then
  pass "the schema uses only keywords the validator implements"
else
  printf 'FAIL - the schema uses only keywords the validator implements\n     unimplemented: %s\n' \
    "$(tr '\n' ' ' <<<"$unsupported")"
  failures=$(( failures + 1 ))
fi

# --- `additionalProperties: false` is the whole point of having a schema at
#     all: a misspelled key is otherwise read by nobody and defaulted silently,
#     which is the failure this file exists to make loud. Asserted at all three
#     depths the config nests to. ---
assert_rejected "a misspelt top-level key is rejected" \
  '.pr_labell = "autonomous-agent"' 'config: unknown key "pr_labell"'
assert_rejected "a misspelt key inside a repo entry is rejected" \
  '.repos[0].nyce = -5' 'config.repos[0]: unknown key "nyce"'
assert_rejected "a misspelt key inside schedule is rejected" \
  '.schedule.review_hours = 3' 'config.schedule: unknown key "review_hours"'
assert_rejected "a misspelt prompt-override mode is rejected" \
  '.prompt_overrides = {coordinator: {extned: ["x.md"]}}' \
  'config.prompt_overrides.coordinator: unknown key "extned"'
assert_rejected "a misspelt prompt-override stage is rejected" \
  '.prompt_overrides = {coordinater: {extend: ["x.md"]}}' \
  'config.prompt_overrides: unknown key "coordinater"'

# --- A key with no fallback anywhere in the code is required: absent, the
#     `jq -r` that reads it yields the string "null", and the pipeline runs on
#     that. ---
assert_rejected "a required key cannot be dropped" \
  'del(.branch_prefix)' 'config: missing required key "branch_prefix"'
assert_rejected "a required review key cannot be dropped while review is configured" \
  'del(.review.model)' 'config.review: missing required key "model"'
assert_valid "the whole review block may be dropped (the review pipeline is optional)" \
  'del(.review)'
assert_valid "an optional key may be absent" \
  'del(.state_repo, .schedule, .crash_loop_after)'

# --- Types. The failure this catches is a number written as a string, which
#     jq reads back without complaint and bash then compares as text. ---
assert_rejected "a number written as a string is rejected" \
  '.max_open_agent_prs = "8"' 'config.max_open_agent_prs: expected integer, got string'
assert_rejected "a fractional value is rejected where whole minutes are meant" \
  '.timeout_reviewer = 30.5' 'config.timeout_reviewer: expected integer, got number'
assert_valid "a fractional value is accepted where hours are meant" \
  '.lock_stale_after = 4.5'
assert_rejected "repos must be an array" \
  '.repos = {slug: "a/b"}' 'config.repos: expected array, got object'
assert_rejected "a type error is reported alone, not compounded" \
  '.branch_prefix = 7' 'config.branch_prefix: expected string, got number'

# --- Ranges and lengths. Each bound below is one the code or the renderer
#     already assumes; the schema is where that assumption becomes checkable. ---
assert_rejected "nice above the supported range is rejected" \
  '.repos[0].nice = 25' 'config.repos[0].nice: 25 is above the maximum 19'
assert_rejected "nice below the supported range is rejected" \
  '.repos[0].nice = -20' 'config.repos[0].nice: -20 is below the minimum -19'
assert_valid "nice at the edge of the range is accepted" \
  '.repos[0].nice = 19 | .repos[1].nice = -19'
assert_rejected "an out-of-range excluded minute is rejected" \
  '.schedule.excluded_minutes = [60]' 'config.schedule.excluded_minutes[0]: 60 is above the maximum 59'
assert_rejected "a zero timeout is rejected" \
  '.timeout_implementor = 0' 'config.timeout_implementor: 0 is below the minimum 1'
assert_rejected "a zero lock_stale_after is rejected" \
  '.lock_stale_after = 0' 'config.lock_stale_after: 0 must be greater than 0'
assert_rejected "an empty branch_prefix is rejected" \
  '.branch_prefix = ""' 'config.branch_prefix: must not be empty'
# `gh pr list --label ''` matches every open pull request, so an empty label
# here does not disable anything — it hands the pipeline other people's work
# as its own, in every repository it is configured for at once.
assert_rejected "an empty pr_label is rejected" \
  '.pr_label = ""' 'config.pr_label: must not be empty'
assert_rejected "an empty review.pr_label is rejected" \
  '.review.pr_label = ""' 'config.review.pr_label: must not be empty'
# The labels that *do* switch a projection off when empty must keep doing so:
# tightening the two above must not tighten these by association.
assert_valid "the optional labels may still be empty (each switches its projection off)" \
  '.needs_refinement_label = "" | .unvoid_label = "" | .enabler_escalation_label = ""'
assert_rejected "an empty repos list is rejected" \
  '.repos = []' 'config.repos: needs at least 1 item(s)'

# --- Enumerations and patterns. A work source that is not a work source is
#     read by the Co-Ordinator's brief as nothing at all, so the repo quietly
#     loses that source. ---
assert_rejected "an unknown work source is rejected" \
  '.repos[0].sources += ["issues:urgnet"]' 'is not one of: security, issues:urgent'
assert_rejected "a duplicated work source is rejected" \
  '.repos[0].sources += [.repos[0].sources[0]]' 'config.repos[0].sources: contains duplicate entries'
assert_rejected "a repo slug that is not owner/name is rejected" \
  '.repos[0].slug = "poetic"' 'config.repos[0].slug: "poetic" does not match'
assert_rejected "a review repo slug that is not owner/name is rejected" \
  '.review.repos = ["poetic"]' 'config.review.repos[0]: "poetic" does not match'
assert_rejected "a state_repo that is not owner/name is rejected" \
  '.state_repo = "agent-ops-state"' 'config.state_repo: "agent-ops-state" does not match'
assert_valid "an empty state_repo is accepted (single-node operation)" \
  '.state_repo = ""'

# --- Model identifiers. D12's whole point is that the qualifier is checked
#     before it reaches `claude --model`, and the schema is the earlier of the
#     two places that happens. ---
assert_valid "a provider-qualified model id is accepted" \
  '.coordinator_model = "anthropic/claude-haiku-4-5-20251001"'
assert_rejected "a model id qualified with an unsupported provider is rejected" \
  '.coordinator_model = "openai/gpt-5"' 'config.coordinator_model: "openai/gpt-5" does not match'
assert_rejected "a required model id cannot be empty" \
  '.reviewer_model_default = ""' 'config.reviewer_model_default: must not be empty'
assert_valid "an optional model id may be empty (it switches its stage off)" \
  '.enabler_model = "" | .reviewer_model_complex = ""'

# --- doctor.sh's cross-key rules: what the schema cannot say. ---
assert_doctor "doctor fails an enabled Enabler with no assignee, as agent-cycle.sh would" \
  '.enabler_assignee = ""' 1 'enabler_model is set but enabler_assignee is not'
assert_doctor "doctor passes an Enabler disabled outright" \
  '.enabler_model = "" | .enabler_assignee = ""' 0 'the Enabler is disabled'
assert_doctor "doctor fails an implementation-plan source with no path, as agent-cycle.sh would" \
  '.repos[0].sources += ["implementation-plan"]' 1 'list the implementation-plan source with no implementation_plan_path'
assert_doctor "doctor fails a label set to blocked, which would make its item unselectable" \
  '.unvoid_label = "blocked"' 1 'unvoid_label is "blocked"'
assert_doctor "doctor fails an excluded_minutes that leaves the renderer no minute" \
  '.schedule.excluded_minutes = [range(60)]' 1 'excludes every minute of the hour'
assert_doctor "doctor warns when the stage timeouts outrun lock_stale_after" \
  '.lock_stale_after = 1' 0 'would have its own lock swept as stale'
assert_doctor "doctor warns when the review label collides with the implementation one" \
  '.review.pr_label = .pr_label' 0 'review.pr_label equals pr_label'
assert_doctor "doctor warns when the mirror would outlive the node that writes it" \
  '.state_local_cycles_retained = 10' 0 'is below cycles_retained'
assert_doctor "doctor warns when crash-loop escalation is configured with nowhere to file" \
  '.crash_loop_after = 4 | .crash_loop_repo = ""' 0 'crash_loop_after is set but crash_loop_repo is empty'
assert_doctor "doctor reports a schema violation as a failure, naming the path" \
  '.pr_labell = "x"' 1 'config: unknown key "pr_labell"'
assert_doctor "doctor passes the shipped configuration" \
  '.' 0 'No failures'

# --- A config that will not parse is a different conversation from one that
#     parses and is wrong: exit 2, and nothing downstream is even attempted. ---
printf '{ nope\n' > "$tmp/broken.json"
out="$(bash "$SCRIPT_DIR/scripts/doctor.sh" --offline --config "$tmp/broken.json" 2>&1)"
status=$?
if (( status == 2 )) && [[ "$out" == *"is not valid JSON"* ]]; then
  pass "doctor exits 2 on a config that is not JSON, without running further checks"
else
  printf 'FAIL - doctor exits 2 on a config that is not JSON\n     exit %s, output: %s\n' "$status" "$out"
  failures=$(( failures + 1 ))
fi

# A config that is not there at all is neither valid nor invalid, and the
# distinction matters to the caller: doctor.sh reports it as a check that
# could not run rather than as a configuration finding.
config_schema_errors "$tmp/absent.json" "$SCHEMA" >/dev/null 2>&1
status=$?
if (( status == 2 )); then
  pass "an unreadable config is distinguished from an invalid one (exit 2)"
else
  bad "an unreadable config is distinguished from an invalid one (exit 2, got $status)"
fi

echo
if (( failures == 0 )); then
  echo "All config-schema assertions passed."
  exit 0
else
  echo "$failures config-schema assertion(s) FAILED."
  exit 1
fi
