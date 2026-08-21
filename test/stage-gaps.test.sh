#!/usr/bin/env bash
#
# test/stage-gaps.test.sh — a stage's inter-event gaps are measured while it
# runs, and summarised as requirement 33a / docs/METERING-SCHEMA.md describe.
#
# A gap is the interval between one growth of the stage's event stream and the
# next. Nothing in the finished transcript records it — the envelope says the
# run took 30 minutes and 47 turns, and is silent about whether those turns
# were evenly spread or whether the run sat still for eleven minutes in the
# middle. That distinction is the whole point of measuring: a cap sized
# against durations cannot tell a busy stage from a wedged one, and these
# numbers are what a liveness threshold is eventually sized from.
#
# Two halves, and they fail in different ways:
#
#   the arithmetic   `stage_gap_stats` against a known sample. Nearest-rank,
#                    not interpolated, so every printed figure is a silence
#                    that really happened — checked here at the awkward ranks
#                    (a single observation, an even count, p99 of a small
#                    sample) rather than only in the middle where every
#                    definition agrees.
#   the measurement  `run_claude_stage` against a stub that emits with
#                    controlled pauses. This is the half that could pass
#                    vacuously: a run whose gaps were never sampled and a run
#                    with no gaps both report small numbers, so the pauses
#                    here are made long enough that a working measurement and
#                    a broken one cannot produce the same answer.
#
# The measurement half is timing-dependent, so its assertions are one-sided —
# "at least this long", never an exact figure — and its pauses are sized well
# clear of the two-second poll resolution. A loaded machine makes a gap look
# longer, never shorter, so a bound from below is the shape that cannot flake.
#
# `claude` is a stub on PATH — no network, no model, no cost.
#
# Run directly: ./test/stage-gaps.test.sh — exit 0 iff all passed.

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

assert_ge() {
  local desc="$1" floor="$2" actual="$3"
  if [[ "$actual" =~ ^-?[0-9]+$ ]] && (( actual >= floor )); then
    printf 'ok   - %s (%s >= %s)\n' "$desc" "$actual" "$floor"
  else
    printf 'FAIL - %s\n     expected: at least %s\n     actual:   %s\n' "$desc" "$floor" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"

# Read by the cycle scripts' signal handlers, which this file does not have.
# shellcheck disable=SC2034
stage_pid=""
# shellcheck disable=SC2034
stage_name=""

# --- 1. The arithmetic -----------------------------------------------------------
assert_eq "no observations at all is null, not a zeroed object" \
  "null" "$(stage_gap_stats)"

# A stage that emitted once and then finished has exactly one gap, and every
# percentile of a one-element sample is that element.
assert_eq "a single observation is its own median, p95, p99 and max" \
  '{"n":1,"p50":12,"p95":12,"p99":12,"max":12}' "$(stage_gap_stats 12)"

# Ten observations, deliberately out of order: the summary sorts, the caller
# does not have to. Sorted they are 2 2 4 6 8 10 30 60 120 900, so nearest
# rank puts p50 at the 5th smallest (ceil(10·0.5)) — 8 — and both p95 and p99
# at the 10th, 900. All three are observations, not interpolations.
assert_eq "ten observations are sorted and summarised at the nearest rank" \
  '{"n":10,"p50":8,"p95":900,"p99":900,"max":900}' \
  "$(stage_gap_stats 4 900 2 60 10 8 6 30 2 120)"

# The property that makes these numbers safe to size a threshold from: the
# tail is an observation, not an average with a tail smeared into it. A sample
# that is quiet nine times out of ten and then stalls must report the stall.
assert_eq "one long silence among short ones survives as the max" \
  "1800" "$(stage_gap_stats 2 2 2 2 2 2 2 2 2 1800 | jq -r '.max')"
assert_eq "…and does not move the median" \
  "2" "$(stage_gap_stats 2 2 2 2 2 2 2 2 2 1800 | jq -r '.p50')"

# Junk in the sample is dropped rather than fatal: this is metering, and a
# metering failure must never be able to cost a stage-end event its own
# fields (requirement 33a).
assert_eq "unreadable observations are skipped, not fatal" \
  '{"n":2,"p50":4,"p95":6,"p99":6,"max":6}' "$(stage_gap_stats 4 "" 6 "x")"
assert_eq "a sample of nothing but junk is null" \
  "null" "$(stage_gap_stats "x" "y")"

# --- The stub ---------------------------------------------------------------------
# Emits its lines with a pause *before* each, so the pauses are silences the
# measurement has to see rather than trailing time after the last event.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
while IFS='|' read -r pause line; do
  sleep "$pause"
  printf '%s\n' "$line"
done < "$STUB_LINES"
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

# --- 2. The measurement ------------------------------------------------------------
# One long silence (8s) and two short ones. 8 seconds is four poll intervals:
# far enough clear of the resolution that a measurement which had failed
# altogether could not report it by accident.
{
  printf '1|%s\n' '{"type":"system","subtype":"init"}'
  printf '8|%s\n' '{"type":"assistant","message":{}}'
  printf '1|%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","num_turns":2}'
} > "$tmp_dir/lines.paced"

capture="$tmp_dir/paced"
mkdir -p "$capture"
STUB_LINES="$tmp_dir/lines.paced" \
  run_claude_stage implementer 120 test-model "a prompt" "$capture/implementer.out" "$capture"
rc=$?

assert_eq "a measured stage still exits with the invocation's own status" 0 "$rc"
assert_eq "the run reports a gap summary, not null" \
  "object" "$(jq -r 'type' <<<"$stage_gaps_json")"
# Counted per observed *growth*, not per event: two lines arriving inside one
# poll interval are one observation, because the file did not stand still
# between them. So this bounds from below rather than naming a figure.
assert_ge "gaps are counted per observed growth, plus the silence at the end" \
  2 "$(jq -r '.n' <<<"$stage_gaps_json")"
assert_ge "the eight-second silence is measured, not averaged away" \
  8 "$(jq -r '.max' <<<"$stage_gaps_json")"
assert_eq "and the median is the short gaps, not the long one" \
  "true" "$(jq -r '.p50 < .max' <<<"$stage_gaps_json")"

# The measurement must not have cost the stage anything: the envelope is still
# where its readers look for it.
assert_eq "the stage's envelope is unaffected by being measured" \
  "ok" "$(jq -r '.result' "$capture/implementer.out" 2>/dev/null)"

# --- 3. The silence after the last event -------------------------------------------
# The gap that matters most on a stage that was killed is the unterminated one
# at the end. Here the stub simply sleeps after its last line; the summary has
# to carry that silence even though no event ever closed it.
{
  printf '0|%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
  printf '7|%s\n' ''
} > "$tmp_dir/lines.trailing"

trailing="$tmp_dir/trailing"
mkdir -p "$trailing"
STUB_LINES="$tmp_dir/lines.trailing" \
  run_claude_stage reviewer 120 test-model "a prompt" "$trailing/reviewer.out" "$trailing"

assert_ge "the silence after the final event is counted as a gap" \
  6 "$(jq -r '.max' <<<"$stage_gaps_json")"

# --- 4. A stage that emitted nothing at all ------------------------------------------
# One gap spanning the whole run, not `null` and not an empty summary. This is
# the case a liveness threshold most needs in its sample — a stage that hangs
# before producing anything is the one with no other evidence about it — and
# it is also what makes `null` unambiguous everywhere else: a measured run
# always has at least one observation, so `null` can only mean "not measured".
printf '' > "$tmp_dir/lines.silent"
silent="$tmp_dir/silent"
mkdir -p "$silent"
STUB_LINES="$tmp_dir/lines.silent" \
  run_claude_stage coordinator 120 test-model "a prompt" "$silent/coordinator.out" "$silent"

assert_eq "a stage that emitted nothing still reports the silence that was all of it" \
  "1" "$(jq -r '.n' <<<"$stage_gaps_json")"
assert_eq "…as a summary rather than null, which is reserved for an unmeasured record" \
  "object" "$(jq -r 'type' <<<"$stage_gaps_json")"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
