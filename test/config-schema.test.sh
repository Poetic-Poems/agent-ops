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
# `x-docs`, and everything at any depth beneath it, is a vendor extension
# outside JSON Schema's keyword space (#198) — never read by
# lib/config-schema.sh, by design — so any path through an `x-`-prefixed key
# is dropped whole before the keyword comparison, the same way an actual
# property name under "properties"/"$defs" is. At any depth, because
# `x-docs.value` is itself keyed by audience for the keys whose two tables
# render different value cells.
#
# A `default` value's own contents are data, not schema — `config_defaults`
# copies it verbatim into config.json's output rather than reading it as
# JSON Schema — so a key beneath one (`refinement_policy`'s default of
# `{"issues": "preferred"}`, say) must not be compared against the keyword
# list on the strength of sharing a name with something unimplemented
# (`oneOf`, or here, `issues`) that the schema never actually uses as a
# keyword. Dropped only when `default` is *not* the path's own last element —
# `default` itself must still be recognised as the keyword it is.
used="$(jq -r '[paths(scalars != null) + paths(type == "object" or type == "array")]
  | map(map(select(type == "string")))
  | map(select(any(.[]; startswith("x-")) | not))
  | map(select((index("default")) as $di | $di == null or $di == (length - 1)))
  | [ .[]
      | . as $p
      | range($p | length) as $i
      | select($i == 0
               or ($p[$i - 1] != "properties" and $p[$i - 1] != "$defs"))
      | $p[$i] ]
  | unique
  | .[]' "$SCHEMA" 2>/dev/null | sort -u)"
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
# lib/prompt-overrides.sh's own assembly functions tolerate a malformed
# prompt_overrides silently (they read it with jq's `?`/`// empty`), so its
# structural shape — an object at every stage, `extend` an array of
# non-empty strings, `replace` a non-empty string — is entirely the schema's
# job now (requirement 1b); these four mirror the cases
# test/prompt-overrides.test.sh used to assert directly against the retired
# `prompt_overrides_config_error`.
assert_rejected "a non-object prompt-override stage value is rejected" \
  '.prompt_overrides = {coordinator: "a.md"}' \
  'config.prompt_overrides.coordinator: expected object, got string'
assert_rejected "a non-array prompt-override extend is rejected" \
  '.prompt_overrides = {coordinator: {extend: "a.md"}}' \
  'config.prompt_overrides.coordinator.extend: expected array, got string'
assert_rejected "a non-string prompt-override extend entry is rejected" \
  '.prompt_overrides = {coordinator: {extend: [1]}}' \
  'config.prompt_overrides.coordinator.extend[0]: expected string, got number'
assert_rejected "a non-string prompt-override replace is rejected" \
  '.prompt_overrides = {coordinator: {replace: ["a.md"]}}' \
  'config.prompt_overrides.coordinator.replace: expected string, got array'

# --- A key with no fallback anywhere in the code is required: absent, the
#     `jq -r` that reads it yields the string "null", and the pipeline runs on
#     that. ---
assert_rejected "a required key cannot be dropped" \
  'del(.branch_prefix)' 'config: missing required key "branch_prefix"'
assert_rejected "a required project_review.defaults key cannot be dropped while project_review is configured" \
  'del(.project_review.defaults.model)' 'config.project_review.defaults: missing required key "model"'
assert_rejected "project_review.defaults cannot be dropped while project_review is configured" \
  'del(.project_review.defaults)' 'config.project_review: missing required key "defaults"'
assert_rejected "project_review.repos cannot be dropped while project_review is configured" \
  'del(.project_review.repos)' 'config.project_review: missing required key "repos"'
assert_valid "the whole project_review block may be dropped (the review pipeline is optional)" \
  'del(.project_review)'
assert_valid "an optional key may be absent" \
  'del(.state_repo, .schedule, .crash_loop_after)'

# --- config_defaults: the schema's `default` is the only place a default is
#     written (issue #197), so this is what every reader now relies on
#     instead of its own `// literal`. ---
assert_defaults() {
  local desc="$1" mutation="$2" jq_check="$3" out
  jq "$mutation" "$CONFIG" > "$tmp/c.json" || { bad "$desc (mutation did not apply)"; return; }
  if ! out="$(config_defaults "$tmp/c.json" "$SCHEMA")"; then
    printf 'FAIL - %s\n     config_defaults itself failed\n' "$desc"
    failures=$(( failures + 1 ))
    return
  fi
  if jq -e "$jq_check" <<<"$out" >/dev/null 2>&1; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     check: %s\n     against: %s\n' "$desc" "$jq_check" "$out"
    failures=$(( failures + 1 ))
  fi
}

assert_defaults "an absent key with a schema default is filled in" \
  'del(.state_repo)' '.state_repo == ""'
assert_defaults "an explicit null is treated the same as absent" \
  '.state_repo = null' '.state_repo == ""'
assert_defaults "a key the config already sets is left exactly as written" \
  '.crash_loop_after = 4' '.crash_loop_after == 4'
assert_defaults "a nested object absent as a whole is synthesised from its own leaves' defaults" \
  'del(.schedule)' \
  '.schedule == {cycle_hours: "*", cycle_interval_minutes: 15, excluded_minutes: [], review_hour: 3, review_offset_minutes: 29, heartbeat_minutes: 5, state_sync_push_minutes: 5, state_sync_fetch_minutes: 7, log_rotation_minute: 19}'
assert_defaults "one leaf missing from a present nested object is filled without disturbing its siblings" \
  '.schedule = {review_hour: 9}' \
  '.schedule.review_hour == 9 and .schedule.cycle_hours == "*" and .schedule.log_rotation_minute == 19'
assert_defaults "an array item's own default is filled per item" \
  '.repos[0].nice = 7 | del(.repos[1].nice)' \
  '.repos[0].nice == 7 and .repos[1].nice == 0'
assert_defaults "a required key with no schema default anywhere passes through untouched" \
  '.project_review.defaults.model = "custom-model"' '.project_review.defaults.model == "custom-model"'
assert_defaults "a nested object's non-defaultable properties are not fabricated when absent" \
  'del(.project_review)' '(.project_review | has("repos")) | not'
assert_defaults "config_defaults performs no schema validation of its own" \
  '.pr_labell = "x"' '.pr_labell == "x"'

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
assert_rejected "an empty project_review.defaults.pr_label is rejected" \
  '.project_review.defaults.pr_label = ""' 'config.project_review.defaults.pr_label: must not be empty'
assert_rejected "an empty project_review repo pr_label override is rejected" \
  '.project_review.repos[0].pr_label = ""' 'config.project_review.repos[0].pr_label: must not be empty'
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
assert_rejected "a project_review repo slug that is not owner/name is rejected" \
  '.project_review.repos = [{slug: "poetic"}]' 'config.project_review.repos[0].slug: "poetic" does not match'
assert_rejected "a project_review repo entry with no slug is rejected" \
  '.project_review.repos = [{model: "claude-sonnet-5"}]' \
  'config.project_review.repos[0]: missing required key "slug"'
assert_rejected "a misspelt key inside a project_review repo entry is rejected" \
  '.project_review.repos[0].sluggg = "a/b"' \
  'config.project_review.repos[0]: unknown key "sluggg"'
assert_valid "a project_review repo entry may override any of defaults' own keys" \
  '.project_review.repos[0] += {model: "claude-opus-5", pr_label: "custom-review", branch_prefix: "custom/", timeout_review: 30, inactivity_review: 5, min_days_between_reviews: 1, not_before: "2026-01-01T00:00:00Z"}'
assert_valid "a project_review repo entry carrying only slug inherits every default" \
  '.project_review.repos = [{slug: "Poetic-Poems/poetic"}]'
assert_rejected "a state_repo that is not owner/name is rejected" \
  '.state_repo = "agent-ops-state"' 'config.state_repo: "agent-ops-state" does not match'
assert_valid "an empty state_repo is accepted (single-node operation)" \
  '.state_repo = ""'
assert_rejected "an unknown merge_autonomy level is rejected" \
  '.merge_autonomy = "agent-does-everything"' 'config.merge_autonomy: "agent-does-everything" is not one of'
assert_rejected "an unknown per-repo merge_autonomy override is rejected" \
  '.repos[0].merge_autonomy = "agent-does-everything"' \
  'config.repos[0].merge_autonomy: "agent-does-everything" is not one of'
assert_valid "every merge_autonomy level, top-level and per-repo, is accepted" \
  '.merge_autonomy = "agent-merges-all" | .repos[0].merge_autonomy = "agent-approves"'
assert_valid "a repo with no merge_autonomy override is accepted (inherits the top-level key)" \
  '.merge_autonomy = "agent-approves"'

# --- config_project_review_repos: the resolution rule (issue #342/requirement
#     342) — a repo's own override wins when present and non-null, defaults[key]
#     otherwise, and a repo carrying only `slug` inherits every default. ---
assert_project_review() {
  local desc="$1" mutation="$2" jq_check="$3" out
  jq "$mutation" "$CONFIG" > "$tmp/c.json" || { bad "$desc (mutation did not apply)"; return; }
  out="$(config_defaults "$tmp/c.json" "$SCHEMA")" || { bad "$desc (config_defaults failed)"; return; }
  out="$(config_project_review_repos "$out")" || { bad "$desc (config_project_review_repos failed)"; return; }
  if jq -e "$jq_check" <<<"$out" >/dev/null 2>&1; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     check: %s\n     against: %s\n' "$desc" "$jq_check" "$out"
    failures=$(( failures + 1 ))
  fi
}

assert_project_review "a repo entry with no overrides resolves to every default" \
  '.project_review.repos = [{slug: "Poetic-Poems/poetic"}]' \
  '.[0].model == "claude-sonnet-5" and .[0].pr_label == "project-review"
   and .[0].branch_prefix == "review/" and .[0].min_days_between_reviews == 13
   and .[0].not_before == "2026-07-30T16:00:00Z"
   and .[0].model_key == "project_review.defaults.model"'
assert_project_review "a repo's own override wins over the default, for that key alone" \
  '.project_review.repos = [{slug: "Poetic-Poems/poetic", model: "claude-opus-5"}]' \
  '.[0].model == "claude-opus-5" and .[0].pr_label == "project-review"
   and .[0].model_key == "project_review.repos[0].model"'
assert_project_review "a repo may override every key defaults carries" \
  '.project_review.repos = [{slug: "Poetic-Poems/poetic", model: "claude-opus-5",
     pr_label: "custom-review", branch_prefix: "custom/", min_days_between_reviews: 1,
     not_before: "2026-01-01T00:00:00Z", timeout_review: 30, inactivity_review: 5}]' \
  '.[0] == {slug: "Poetic-Poems/poetic", model: "claude-opus-5", model_key: "project_review.repos[0].model",
     pr_label: "custom-review", branch_prefix: "custom/", min_days_between_reviews: 1, not_before: "2026-01-01T00:00:00Z",
     timeout_review: 30, inactivity_review: 5}'
assert_project_review "two repos resolve independently — one overriding, one inheriting" \
  '.project_review.repos = [{slug: "Poetic-Poems/poetic", model: "claude-opus-5"},
     {slug: "Poetic-Poems/poetic-fiddle"}]' \
  '.[0].model == "claude-opus-5" and .[1].model == "claude-sonnet-5"
   and .[0].model_key == "project_review.repos[0].model"
   and .[1].model_key == "project_review.defaults.model"'
assert_project_review "an absent project_review resolves to no repos, never an error" \
  'del(.project_review)' '. == []'

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
assert_doctor "doctor fails duplicate slugs in project_review.repos, as review-cycle.sh would" \
  '.project_review.repos[1].slug = .project_review.repos[0].slug' 1 \
  'project_review.repos lists [Poetic-Poems/poetic] more than once'
assert_doctor "doctor passes distinct project_review.repos slugs" \
  '.' 0 'every project_review.repos entry names a distinct repository'
assert_doctor "doctor fails a label set to blocked, which would make its item unselectable" \
  '.unvoid_label = "blocked"' 1 'unvoid_label is "blocked"'
assert_doctor "doctor fails the refined label set to blocked — the projection would bury the item as it became workable" \
  '.refined_label = "blocked"' 1 'refined_label is "blocked"'
assert_doctor "doctor fails a PR label named obsolete, which every draft would then carry as its own close corroboration" \
  '.pr_label = "obsolete"' 1 'pr_label is "obsolete"'
assert_doctor "doctor fails a label named Obsolete case-insensitively, as the void guard reads it" \
  '.project_review.defaults.pr_label = "Obsolete"' 1 'project_review pr_label is "Obsolete"'
assert_doctor "doctor fails an obsolete label on a repo's own project_review override too" \
  '.project_review.repos[0].pr_label = "Obsolete"' 1 'project_review pr_label is "Obsolete"'
assert_doctor "doctor fails an excluded_minutes that leaves the renderer no minute" \
  '.schedule.excluded_minutes = [range(60)]' 1 'excludes every minute of the hour'
# The stale-lock assertion this used to make is gone, and deliberately: the
# lock threshold is now derived from the backstops in force rather than
# checked against them (requirement 4f), so it cannot be outrun and there is
# nothing left to warn about. What replaces it is the other half of that
# bargain — a configured cap is an override that turns the self-tuning off,
# and doctor says so rather than letting a value set once and forgotten look
# like the system still adapting.
assert_doctor "doctor reports the derived lock rather than checking a configured one" \
  '.lock_stale_after = 1' 0 'the cycle lock is derived at'
assert_doctor "doctor warns that a configured cap pins itself" \
  '.timeout_reviewer = 60' 0 'turns off its self-tuning'
assert_doctor "doctor warns that a configured Refiner cap pins itself, not only the four repo-scoped actors" \
  '.timeout_refiner = 15' 0 "timeout_refiner is set, which pins"
assert_doctor "doctor warns on a per-repo stage_timeouts override, naming the repo" \
  '.repos[0].stage_timeouts = {"implementor": 90}' 0 \
  "Poetic-Poems/poetic's stage_timeouts.implementor is set, which pins"
assert_doctor "doctor warns on a per-repo stage_inactivity override, naming the repo" \
  '.repos[0].stage_inactivity = {"reviewer": 5}' 0 \
  "Poetic-Poems/poetic's stage_inactivity.reviewer is set, which pins"
assert_doctor "a per-repo override wider than every prior widens the reported lock, matching what agent-cycle.sh derives" \
  '.repos[0].stage_timeouts = {"implementor": 300}' 0 \
  "the cycle lock is derived at 500 min"
assert_doctor "doctor warns when a repo's project_review label collides with the implementation one" \
  '.project_review.repos[0].pr_label = .pr_label' 0 \
  "Poetic-Poems/poetic's project_review pr_label ($(jq -r '.pr_label' "$CONFIG")) equals pr_label"
assert_doctor "doctor warns when the mirror would outlive the node that writes it" \
  '.state_local_cycles_retained = 10' 0 'is below cycles_retained'
assert_doctor "doctor warns when crash-loop escalation is configured with nowhere to file" \
  '.crash_loop_after = 4 | .crash_loop_repo = ""' 0 'crash_loop_after is set but crash_loop_repo is empty'
assert_doctor "doctor reports a schema violation as a failure, naming the path" \
  '.pr_labell = "x"' 1 'config: unknown key "pr_labell"'
assert_doctor "doctor passes the shipped configuration" \
  '.' 0 'No failures'

# --- D18 (requirement 2.3b): merge_autonomy above human needs an Approver
#     identity configured. Doctor-only — nothing at cycle start consumes this
#     pairing yet, so there is no matching agent-cycle.sh refusal to mirror,
#     unlike the two shared cross-key rules above. ---
assert_doctor "doctor fails a merge_autonomy level above human with no approver_app_id, naming the key" \
  '.merge_autonomy = "agent-approves"' 1 \
  'merge_autonomy is "agent-approves" with no approver_app_id configured'
assert_doctor "doctor fails a per-repo merge_autonomy override above human with no approver_app_id, naming the repo" \
  '.repos[0].merge_autonomy = "agent-merges-all"' 1 \
  "Poetic-Poems/poetic's merge_autonomy override is \"agent-merges-all\" with no approver_app_id configured"
assert_doctor "doctor passes a merge_autonomy level above human once approver_app_id is set" \
  '.merge_autonomy = "agent-approves" | .approver_app_id = "123456"' 0 \
  'merge_autonomy is "agent-approves"'
assert_doctor "doctor passes human explicitly, same as the default, with no approver_app_id" \
  '.merge_autonomy = "human"' 0 'merge_autonomy is "human"'

# --- The gate is a startup refusal in the real entry points, not merely in
#     the library function above (requirement 1b): agent-cycle.sh and
#     review-cycle.sh each validate config.json against the schema before any
#     individual key is read from it — the same fail-fast position
#     requirement 1a's model-id resolution occupies — and well before the
#     lock. Exercised here by driving the real scripts end to end, with
#     claude/gh stubbed the way test/role.test.sh stubs them, so reaching
#     either stub would itself mean the gate had failed to stop the cycle.
#
#     agent-cycle.sh's CONFIG_FILE is `$SCRIPT_DIR/config.json`, derived from
#     the running script's own directory, so a doctored config can only be
#     tried against a throwaway copy of the whole app tree — this
#     repository's real config.json must stay untouched. review-cycle.sh
#     instead honours AGENT_OPS_CONFIG (built for tests; see its own
#     comment), so it is pointed at a mutated file in place, no copy needed. ---
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

guard_app="$tmp/guard-app"
mkdir -p "$guard_app"
cp "$SCRIPT_DIR/agent-cycle.sh" "$SCHEMA" "$guard_app/"
cp -r "$SCRIPT_DIR/lib" "$SCRIPT_DIR/prompts" "$SCRIPT_DIR/scripts" "$guard_app/"

guard_home="$tmp/guard-home"
mkdir -p "$guard_home/.local/bin"
# Reaching either stub would mean the gate let a cycle through to real work —
# which would otherwise spend real money or hit the real network before the
# gate has anything to say about it. Every case below asserts its exit came
# from the gate's own message, which fires before any claude or gh call.
for stub in claude gh; do
  printf '#!/bin/sh\necho "%s stub: the schema gate should have prevented this" >&2\nexit 1\n' "$stub" \
    > "$guard_home/.local/bin/$stub"
  chmod +x "$guard_home/.local/bin/$stub"
done

# run_cycle_guard CONFIG_JSON — writes CONFIG_JSON as the copied app's
# config.json and runs the copied agent-cycle.sh against it: AGENT_OPS_ROLE
# active so the role guard (which runs first) does not short-circuit before
# the schema gate does, and a throwaway HOME so nothing here can touch this
# machine's real state_dir. Sets $guard_out and $guard_rc.
run_cycle_guard() {
  printf '%s' "$1" > "$guard_app/config.json"
  guard_out="$(env AGENT_OPS_ROLE=active HOME="$guard_home" "$guard_app/agent-cycle.sh" 2>&1)"
  guard_rc=$?
}

# run_review_guard CONFIG_JSON — same, but against the real review-cycle.sh
# in place (via AGENT_OPS_CONFIG), since that script already resolves its
# config from the environment rather than its own directory.
run_review_guard() {
  printf '%s' "$1" > "$tmp/review-guard-config.json"
  guard_out="$(env AGENT_OPS_ROLE=active HOME="$guard_home" \
    AGENT_OPS_CONFIG="$tmp/review-guard-config.json" \
    "$SCRIPT_DIR/review-cycle.sh" 2>&1)"
  guard_rc=$?
}

run_cycle_guard "$(jq -c '.pr_labell = "x"' "$CONFIG")"
assert_eq "agent-cycle.sh exits 1 on a config that fails the schema" "1" "$guard_rc"
assert_contains "agent-cycle.sh's refusal names the schema" \
  "does not match config.schema.json" "$guard_out"
assert_contains "agent-cycle.sh's refusal names the offending path" \
  'unknown key "pr_labell"' "$guard_out"

run_review_guard "$(jq -c '.pr_labell = "x"' "$CONFIG")"
assert_eq "review-cycle.sh exits 1 on a config that fails the schema" "1" "$guard_rc"
assert_contains "review-cycle.sh's refusal names the schema" \
  "does not match config.schema.json" "$guard_out"
assert_contains "review-cycle.sh's refusal names the offending path" \
  'unknown key "pr_labell"' "$guard_out"

# --- The two hand-written startup guards the schema now subsumes: a bad
#     `nice` and a malformed `prompt_overrides` are refused by the schema
#     gate itself, in its own wording — the retired guards' own messages
#     ("invalid nice", "config.json prompt_overrides:") appear nowhere. ---
run_cycle_guard "$(jq -c '.repos[0].nice = 20' "$CONFIG")"
assert_eq "a nice above 19 exits 1 via the schema gate" "1" "$guard_rc"
assert_contains "the schema names the offending path" \
  "config.repos[0].nice: 20 is above the maximum 19" "$guard_out"
assert_not_contains "the retired nice guard's own wording is gone" \
  "invalid nice" "$guard_out"

run_cycle_guard "$(jq -c '.prompt_overrides = {coordinator: {extned: ["x.md"]}}' "$CONFIG")"
assert_eq "a malformed prompt_overrides exits 1 via the schema gate" "1" "$guard_rc"
assert_contains "the schema names the offending path" \
  'config.prompt_overrides.coordinator: unknown key "extned"' "$guard_out"
assert_not_contains "the retired prompt_overrides guard's own wording is gone" \
  "see README.md" "$guard_out"

# --- A config the schema accepts must still clear agent-cycle.sh's two
#     surviving cross-key guards — the schema gate passing is not the whole
#     of requirement 1b. ---
run_cycle_guard "$(jq -c '.enabler_assignee = ""' "$CONFIG")"
assert_eq "an unassigned enabled Enabler still exits 1, past the schema gate" "1" "$guard_rc"
assert_contains "the enabler_assignee guard still fires, shared with doctor.sh" \
  "enabler_model is set but enabler_assignee is not configured" "$guard_out"
assert_not_contains "a config the schema accepts is not reported as a schema failure" \
  "does not match config.schema.json" "$guard_out"

# review-cycle.sh's own cross-key guard: duplicate project_review.repos slugs
# (requirement R1b), shared with doctor.sh's own `fail` above through the same
# lib/config-schema.sh function.
run_review_guard "$(jq -c '.project_review.repos[1].slug = .project_review.repos[0].slug' "$CONFIG")"
assert_eq "duplicate project_review.repos slugs exit 1, past the schema gate" "1" "$guard_rc"
assert_contains "the duplicate-slug guard names the repeated slug" \
  "project_review.repos lists [Poetic-Poems/poetic] more than once" "$guard_out"
assert_not_contains "a config the schema accepts is not reported as a schema failure" \
  "does not match config.schema.json" "$guard_out"

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
