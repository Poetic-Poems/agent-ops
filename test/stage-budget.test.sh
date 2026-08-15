#!/usr/bin/env bash
#
# test/stage-budget.test.sh — the derivation that decides how long a stage is
# allowed (requirement 4f, lib/stage-budget.sh).
#
# Every number here is a pure function of the fleet log, so this file is a
# fixture and a set of expectations — no clock, no network, no model. The
# fixture dates are absolute for that reason: a derivation whose answers moved
# with the wall clock could not be asserted on at all.
#
# What is worth testing, and why each one fails silently otherwise:
#
#   the safe direction     Both mechanisms are chosen so that being wrong
#                          costs the marginal minutes of a doomed session
#                          rather than a finished stage. The watchdog widens
#                          on a censored observation and never narrows below
#                          its prior; the backstop jumps on a kill and creeps
#                          down only under three simultaneous conditions. Get
#                          either direction backwards and the mechanism still
#                          runs, still produces numbers, and quietly destroys
#                          work — which is exactly the failure it replaces.
#   the cell key           (actor, repository, model). Pool the models and a
#                          controller sees an average kill rate that is too
#                          tight for one and too loose for the other, and
#                          converges for neither. Nothing in the output looks
#                          wrong when that happens.
#   the cold start         A repository with no history must get a working
#                          answer on its first cycle, because a customer must
#                          never be asked to choose a timeout.
#   the censoring          A killed run contributes no duration. Its recorded
#                          length is its cap, and treating that as an
#                          observation is the death spiral this design exists
#                          to avoid.
#   degradation            A malformed log, an absent field, a stage from
#                          before any of this existed: all must yield a
#                          usable answer rather than an empty one, because the
#                          caller launches a stage with whatever comes back.
#
# Run directly: ./test/stage-budget.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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

assert_gt() {
  local desc="$1" floor="$2" actual="$3"
  if [[ "$actual" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && (( $(printf '%.0f' "$actual") > floor )); then
    printf 'ok   - %s (%s > %s)\n' "$desc" "$actual" "$floor"
  else
    printf 'FAIL - %s\n     expected: more than %s\n     actual:   %s\n' "$desc" "$floor" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# shellcheck source=lib/stage-budget.sh
. "$SCRIPT_DIR/lib/stage-budget.sh"

NOW="2026-08-07T00:00:00Z"
SETTINGS="$(stage_budget_settings '{}')"

# run TS CYCLE STAGE EXIT MODEL DURATION_MS GAP_MAX [KILL_REASON]
run() {
  jq -nc --arg ts "$1" --arg c "$2" --arg s "$3" --argjson x "$4" --arg m "$5" \
    --argjson d "$6" --argjson g "$7" --arg kr "${8:-}" \
    '{ts: $ts, cycle: $c, event: "stage-end", stage: $s, exit_code: $x, model: $m,
      duration_ms: $d, gaps: {n: 3, p50: 2, p95: $g, p99: $g, max: $g}}
     + (if $kr == "" then {} else {kill_reason: $kr} end)'
}
selection() {
  jq -nc --arg ts "$1" --arg c "$2" --arg r "$3" '{ts: $ts, cycle: $c, event: "selection", repo: $r}'
}
table_for() { stage_budget_table "$(stage_budget_observations < "$1")" "$SETTINGS" "$NOW"; }
cell() { jq -r --arg k "$2" ".cells[\$k].$3 // \"missing\"" <<<"$1"; }

# --- 1. The cell key, and the repository join --------------------------------------
# A `stage-end` names its stage and nothing else; the repository it was working
# is on the `selection` event of the same cycle. Get that join wrong and every
# implementation cell collapses into one.
{
  selection 2026-08-05T00:00:00Z c1 Poetic-Poems/agent-ops
  run 2026-08-05T00:10:00Z c1 reviewer 0 claude-opus-5 600000 120
  selection 2026-08-05T01:00:00Z c2 Poetic-Poems/poetic
  run 2026-08-05T01:10:00Z c2 reviewer 0 claude-sonnet-5 300000 30
  run 2026-08-05T01:20:00Z c2 coordinator 0 claude-haiku-4-5 90000 20
} > "$tmp_dir/join.jsonl"
t="$(table_for "$tmp_dir/join.jsonl")"

assert_eq "a stage is keyed to the repository its cycle selected" \
  "Poetic-Poems/agent-ops" "$(cell "$t" "reviewer|Poetic-Poems/agent-ops|claude-opus-5" repo)"
assert_eq "and two repositories are two cells, not one" \
  "2" "$(jq '[.cells | to_entries[] | select(.value.actor == "reviewer")] | length' <<<"$t")"
# The strongest single predictor of how long a stage runs is the model. Pool
# two of them and a cell has a bimodal duration distribution that no single
# quantile describes, and a controller that converges for neither.
assert_eq "the model is part of the key, not folded away" \
  "claude-opus-5" "$(cell "$t" "reviewer|Poetic-Poems/agent-ops|claude-opus-5" model)"
# The Co-Ordinator runs before selection and the Enabler spans repositories:
# neither has a repository, and inventing one would fragment its sample.
assert_eq "the Co-Ordinator has no repository axis" \
  "*" "$(cell "$t" "coordinator|*|claude-haiku-4-5" repo)"

# --- 2. The cold start ---------------------------------------------------------------
# The Pullwright requirement: a repository nobody has ever run gets a working
# answer on cycle one, from the shipped prior, without anyone choosing a
# number.
fresh="$(stage_budget_resolve "$t" implementor Some/brand-new claude-sonnet-5 '{}')"
assert_eq "an unseen cell answers from the shipped prior" \
  "prior" "$(jq -r '.basis' <<<"$fresh")"
assert_eq "…with the prior backstop" "150" "$(jq -r '.backstop_min' <<<"$fresh")"
assert_eq "…and the prior watchdog threshold" "10" "$(jq -r '.inactivity_min' <<<"$fresh")"
empty="$(stage_budget_resolve '{}' reviewer Any/repo any-model '{}')"
assert_eq "an empty table answers too, rather than answering nothing" \
  "90" "$(jq -r '.backstop_min' <<<"$empty")"

# --- 3. The backstop moves up on a kill, hard -----------------------------------------
# A kill is the only unambiguous evidence a cap is too tight, and it is exactly
# the censored observation that made fitting a cap to durations self-defeating.
# Here it is the control signal instead.
{
  selection 2026-08-05T00:00:00Z k1 Poetic-Poems/agent-ops
  run 2026-08-05T00:10:00Z k1 reviewer 0 claude-opus-5 600000 60
  selection 2026-08-05T02:00:00Z k2 Poetic-Poems/agent-ops
  run 2026-08-05T02:10:00Z k2 reviewer 124 claude-opus-5 5400000 60 backstop
} > "$tmp_dir/kill.jsonl"
tk="$(table_for "$tmp_dir/kill.jsonl")"
assert_eq "one backstop kill multiplies the cap (90 -> 135)" \
  "135" "$(cell "$tk" "reviewer|Poetic-Poems/agent-ops|claude-opus-5" backstop_min)"
assert_eq "and the kill is counted, not merely absorbed" \
  "1" "$(cell "$tk" "reviewer|Poetic-Poems/agent-ops|claude-opus-5" backstop_kills)"

# A second kill compounds — but the ceiling is what stops that being unbounded.
{
  cat "$tmp_dir/kill.jsonl"
  selection 2026-08-05T04:00:00Z k3 Poetic-Poems/agent-ops
  run 2026-08-05T04:10:00Z k3 reviewer 124 claude-opus-5 8100000 60 backstop
  selection 2026-08-05T06:00:00Z k4 Poetic-Poems/agent-ops
  run 2026-08-05T06:10:00Z k4 reviewer 124 claude-opus-5 8100000 60 backstop
} > "$tmp_dir/kill3.jsonl"
tk3="$(table_for "$tmp_dir/kill3.jsonl")"
assert_eq "repeated kills are bounded by the ceiling (2x the prior)" \
  "180" "$(cell "$tk3" "reviewer|Poetic-Poems/agent-ops|claude-opus-5" backstop_min)"

# --- 4. …and does not drift down on a handful of clean runs ---------------------------
# Multiplicative increase, additive decrease: the sharp move is upward because
# a cap set too small is what destroys a stage. A few clean runs must buy no
# reduction at all.
{
  selection 2026-08-05T00:00:00Z d0 Poetic-Poems/poetic
  run 2026-08-05T00:10:00Z d0 implementor 0 claude-sonnet-5 300000 30
  selection 2026-08-05T01:00:00Z d1 Poetic-Poems/poetic
  run 2026-08-05T01:10:00Z d1 implementor 0 claude-sonnet-5 300000 30
  selection 2026-08-05T02:00:00Z d2 Poetic-Poems/poetic
  run 2026-08-05T02:10:00Z d2 implementor 0 claude-sonnet-5 300000 30
} > "$tmp_dir/clean.jsonl"
tc="$(table_for "$tmp_dir/clean.jsonl")"
assert_eq "three clean runs move the backstop not at all" \
  "150" "$(cell "$tc" "implementor|Poetic-Poems/poetic|claude-sonnet-5" backstop_min)"

# --- 5. A killed run contributes no duration ------------------------------------------
# Its recorded length is its cap, not its length. Counting it would drag the
# 95th percentile — and with it the floor under the cap — towards the very
# wall that truncated it.
obs="$(stage_budget_observations < "$tmp_dir/kill.jsonl")"
assert_eq "a killed run is recorded, and its duration is not" \
  "null" "$(jq -r '[.[] | select(.killed == "backstop")][0].duration_min' <<<"$obs")"
assert_eq "…while a completed run keeps its own" \
  "10" "$(jq -r '[.[] | select(.killed == "")][0].duration_min' <<<"$obs")"
assert_eq "so the percentile is over completed runs only" \
  "1" "$(cell "$tk" "reviewer|Poetic-Poems/agent-ops|claude-opus-5" completed)"

# --- 6. The watchdog widens on silence, and never narrows below its prior --------------
# `k x max(gap)` on the maximum rather than a mean plus sigma, so a censored
# observation pushes the threshold *up*. A run killed for inactivity at T
# records a maximum gap of T, and the next threshold computed from it is k x T.
{
  selection 2026-08-05T00:00:00Z g1 Poetic-Poems/agent-ops
  run 2026-08-05T00:10:00Z g1 implementor 0 claude-sonnet-5 600000 900
} > "$tmp_dir/gap.jsonl"
tg="$(table_for "$tmp_dir/gap.jsonl")"
assert_gt "a long silence widens the threshold past its prior" \
  10 "$(cell "$tg" "implementor|Poetic-Poems/agent-ops|claude-sonnet-5" inactivity_min)"

# Short gaps must not tighten it. A watchdog that narrowed itself would
# reintroduce, from the other side, the failure this design exists to end.
{
  selection 2026-08-05T00:00:00Z s1 Poetic-Poems/poetic
  run 2026-08-05T00:10:00Z s1 implementor 0 claude-sonnet-5 600000 2
  selection 2026-08-05T01:00:00Z s2 Poetic-Poems/poetic
  run 2026-08-05T01:10:00Z s2 implementor 0 claude-sonnet-5 600000 2
} > "$tmp_dir/short.jsonl"
ts="$(table_for "$tmp_dir/short.jsonl")"
assert_eq "consistently short silences never narrow it below the prior" \
  "10" "$(cell "$ts" "implementor|Poetic-Poems/poetic|claude-sonnet-5" inactivity_min)"

# And it can never exceed the backstop above it: a watchdog that let a stage
# past its own outer bound could never fire.
assert_eq "the threshold is capped at the backstop" "true" \
  "$(jq -r '[.cells[] | (.inactivity_min <= .backstop_min)] | all' <<<"$tg")"

# --- 7. Shrinkage: a cell speaks for itself only once it has something to say ----------
# One run is not evidence. The estimate slides from the pooled value towards
# the cell's own as its run count grows, and says which it is on.
assert_eq "a cell with one run is marked as shrunk towards the pool" \
  "shrunk" "$(cell "$tg" "implementor|Poetic-Poems/agent-ops|claude-sonnet-5" basis)"
one_run="$(cell "$tg" "implementor|Poetic-Poems/agent-ops|claude-sonnet-5" inactivity_min)"
# 4 x 900s = 60 min of its own, against a 10-minute prior carrying 20
# run-equivalents: one run moves it a twenty-first of the way, not all of it.
assert_eq "…so one long silence does not carry the whole estimate" \
  "true" "$(jq -n --argjson v "$one_run" '$v < 60')"

# --- 8. Precedence: configuration outranks the derivation -----------------------------
over="$(stage_budget_resolve "$tk" reviewer Poetic-Poems/agent-ops claude-opus-5 \
  '{"backstop": 45, "inactivity": 3}')"
assert_eq "a configured backstop wins over the derived one" "45" "$(jq -r '.backstop_min' <<<"$over")"
assert_eq "and a configured threshold likewise" "3" "$(jq -r '.inactivity_min' <<<"$over")"
assert_eq "and the event says the value came from configuration" \
  "config" "$(jq -r '.source' <<<"$over")"
half="$(stage_budget_resolve "$tk" reviewer Poetic-Poems/agent-ops claude-opus-5 '{"backstop": 45}')"
assert_eq "overriding the backstop alone applies to the backstop" \
  "45" "$(jq -r '.backstop_min' <<<"$half")"
assert_eq "…and leaves the threshold to the derivation" \
  "true" "$(jq -n --argjson v "$(jq -r '.inactivity_min' <<<"$half")" '$v >= 10')"

# --- 9. The derived lock ----------------------------------------------------------------
# It must clear the worst case the cycle could draw, which is why it sums the
# widest backstop each actor could be given rather than the one it will be.
# Five implementation actors as of the Refiner (requirement 39): coordinator,
# implementor, reviewer, enabler, refiner — each contributes its widest
# backstop, plus slack.
lock_sec="$(stage_budget_lock_seconds "$tk3" '{}' 30 0)"
assert_eq "the lock clears the summed worst-case backstops plus slack" \
  "$(( (20 + 150 + 180 + 30 + 30 + 30 + 30) * 60 ))" "$lock_sec"
assert_eq "a configured value is a floor, not the answer" \
  "$(( 12 * 3600 ))" "$(stage_budget_lock_seconds "$tk3" '{}' 30 12)"
assert_eq "…and is ignored when the derivation already exceeds it" \
  "$lock_sec" "$(stage_budget_lock_seconds "$tk3" '{}' 30 1)"
assert_eq "an empty table still derives a lock, from the priors alone" \
  "$(( (20 + 150 + 90 + 30 + 30 + 30 + 30) * 60 ))" "$(stage_budget_lock_seconds '{}' '{}' 30 0)"

# --- 9a. All-actor overrides, the shared input scripts/doctor.sh and --------------------
#         agent-cycle.sh both derive the lock from (requirement 4f)
# A plain fleet-wide key and a per-repository one both count, and a repo's is
# never dropped just because it happens to be narrower than the fleet-wide key
# for a different actor.
cfg='{"timeout_reviewer": 45,
      "repos": [{"slug": "a/one", "stage_timeouts": {"implementor": 200}},
                {"slug": "a/two", "stage_inactivity": {"reviewer": 7}}]}'
overrides="$(stage_budget_all_overrides "$cfg")"
assert_eq "the plain fleet-wide key is picked up" \
  "45" "$(jq -r '.reviewer.backstop' <<<"$overrides")"
assert_eq "a per-repository stage_timeouts entry is picked up for its actor" \
  "200" "$(jq -r '.implementor.backstop' <<<"$overrides")"
assert_eq "a per-repository stage_inactivity entry is picked up for its actor" \
  "7" "$(jq -r '.reviewer.inactivity' <<<"$overrides")"
assert_eq "an actor nobody configured answers null, not zero" \
  "null" "$(jq -r '.enabler.backstop' <<<"$overrides")"
assert_eq "the Refiner is covered too, fleet-wide only (no per-repo form)" \
  "20" "$(jq -r '.refiner.backstop' <<<"$(stage_budget_all_overrides '{"timeout_refiner": 20}')")"
assert_eq "the Approver is covered, fleet-wide timeout" \
  "25" "$(jq -r '.approver.backstop' <<<"$(stage_budget_all_overrides '{"timeout_approver": 25}')")"
assert_eq "the Approver is covered, fleet-wide inactivity" \
  "8" "$(jq -r '.approver.inactivity' <<<"$(stage_budget_all_overrides '{"inactivity_approver": 8}')")"
wide_cfg='{"repos": [{"slug": "a/one", "stage_timeouts": {"reviewer": 10}},
                     {"slug": "a/two", "stage_timeouts": {"reviewer": 99}}]}'
wide_overrides="$(stage_budget_all_overrides "$wide_cfg")"
assert_eq "the *largest* configured value wins across repositories, not the last one read" \
  "99" "$(jq -r '.reviewer.backstop' <<<"$wide_overrides")"
assert_eq "…so the lock derived from it clears that widest per-repo backstop, exactly as scripts/doctor.sh reports" \
  "$(( (20 + 150 + 99 + 30 + 30 + 30 + 30) * 60 ))" \
  "$(stage_budget_lock_seconds '{}' "$wide_overrides" 30 0)"

# --- 10. Degradation ---------------------------------------------------------------------
# The caller launches a stage with whatever comes back, so nothing here may
# answer with nothing.
printf 'not json\n{"event":"stage-end"}\n' > "$tmp_dir/junk.jsonl"
junk="$(table_for "$tmp_dir/junk.jsonl")"
assert_eq "a malformed log yields a table, not a failure" \
  "object" "$(jq -r 'type' <<<"$junk")"
assert_eq "and resolving against it still answers" \
  "150" "$(jq -r '.backstop_min' <<<"$(stage_budget_resolve "$junk" implementor Any/repo m '{}')")"

# A stage-end from before any of this existed: no gaps, no kill_reason. Exit
# 124 was a wall-clock kill and nothing else could produce it, so it is read
# that way.
printf '%s\n' '{"ts":"2026-08-05T00:00:00Z","cycle":"o1","event":"stage-end","stage":"reviewer","exit_code":124}' \
  > "$tmp_dir/legacy.jsonl"
legacy="$(stage_budget_observations < "$tmp_dir/legacy.jsonl")"
assert_eq "a stage-end predating kill_reason is read as a backstop kill" \
  "backstop" "$(jq -r '.[0].killed' <<<"$legacy")"
assert_eq "and one predating the gap statistics contributes no gap" \
  "null" "$(jq -r '.[0].gap_max' <<<"$legacy")"

# Settings are a tuning surface, not a place a cycle can be broken from.
assert_eq "a malformed stage_budget object leaves the defaults standing" \
  "4" "$(jq -r '.gap_multiplier' <<<"$(stage_budget_settings '{"stage_budget": "nonsense"}')")"
assert_eq "a non-numeric setting is dropped rather than adopted" \
  "20" "$(jq -r '.shrinkage_runs' <<<"$(stage_budget_settings '{"stage_budget": {"shrinkage_runs": "many"}}')")"
assert_eq "a numeric one is adopted" \
  "7" "$(jq -r '.gap_multiplier' <<<"$(stage_budget_settings '{"stage_budget": {"gap_multiplier": 7}}')")"

# --- 11. The window ------------------------------------------------------------------------
# A repository whose cost profile is changing must be described by what it
# costs now, so evidence ages out.
{
  selection 2026-01-01T00:00:00Z w1 Poetic-Poems/agent-ops
  run 2026-01-01T00:10:00Z w1 reviewer 124 claude-opus-5 5400000 60 backstop
} > "$tmp_dir/old.jsonl"
tw="$(table_for "$tmp_dir/old.jsonl")"
assert_eq "a kill from seven months ago is outside the window and moves nothing" \
  "0" "$(jq '(.cells // {}) | length' <<<"$tw")"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
