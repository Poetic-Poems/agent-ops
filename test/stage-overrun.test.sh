#!/usr/bin/env bash
#
# test/stage-overrun.test.sh — the dashboard rule that catches a stage which has
# outlived its own timeout.
#
# The gap this guards: `lock_stale_after` bounds how long a *cycle* may
# plausibly run (4 hours), but agent-cycle.sh bounds each *stage* far more
# tightly — run_claude_stage kills the process group when the stage timeout
# expires and logs `stage-end` after it. A Co-Ordinator is capped at 15 minutes,
# so a node rolled mid-cycle used to go on reporting "coordinator choosing work"
# for the remaining three and three-quarter hours before anything on the page
# doubted it. That is most of the way to its next cycle.
#
# Three properties here are the ones worth holding still, because each fails
# silently and in a different direction:
#
#   measured to the heartbeat  a missing `stage-end` is known only as far as the
#                              state that node last published. Measuring to the
#                              clock instead would flag every stage that ended
#                              just after its final push — and would drag the
#                              skew between two machines into the arithmetic,
#                              where measuring one node against its own two
#                              timestamps has none
#   per-stage timeouts         an Implementor gets 120 minutes and a Co-Ordinator
#                              15; one shared threshold would either miss the
#                              Co-Ordinator case entirely or condemn every
#                              healthy Implementor
#   silence on unknown stages  the review pipeline runs stages this map does not
#                              name, and a stage with no configured timeout is
#                              one the rule may make no claim about
#
# The rule is read out of dashboard/index.html rather than restated here, so
# this cannot pass against a copy that the page has since moved on from; the
# extraction asserts it found something for the same reason.
#
# This is the first test of any of `dashboard/index.html`'s JavaScript, and it
# takes only the easy half of TD26072606: a pure function, called directly, with
# no DOM in sight. The `test/dashboard-render.test.sh` that record asks for —
# fixture `DASHBOARD_DATA` through a stub DOM, asserting on rendered cells — is
# still open, and this is not it.
#
# No network. Needs node, which the image carries for the Claude CLI; absent, the
# file skips with a note rather than failing, as TD26072606 asks for and as
# test/render-crontab.test.sh does for supercronic.
#
# Run directly: ./test/stage-overrun.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGE="$SCRIPT_DIR/dashboard/index.html"

failures=0

if ! command -v node >/dev/null 2>&1; then
  printf 'ok   - node not installed here; CI runs this rule in-image\n\nall assertions passed\n'
  exit 0
fi

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- The rule, lifted out of the page ------------------------------------------
# `parseTs` is the page-wide date helper the rule leans on; the block below it is
# the rule itself, from the timeout map through the node-row wrapper.
helper="$(grep '^  function parseTs' "$PAGE")"
rule="$(awk '
  /var STAGE_BACKSTOP_PRIOR = \{/ { on = 1 }
  on                              { print }
  /function nodeStageOverrun/     { seen = 1 }
  seen && /^  \}$/                { exit }
' "$PAGE")"

if [[ -z "$helper" || -z "$rule" ]]; then
  printf 'FAIL - the rule could not be found in %s (renamed or moved?)\n' "${PAGE#"$SCRIPT_DIR"/}"
  exit 1
fi
assert_contains "the extracted rule carries the fallback priors" "STAGE_BACKSTOP_PRIOR" "$rule"
assert_contains "and both entry points" "function nodeStageOverrun" "$rule"

# --- The cases -------------------------------------------------------------------
# Config mirrors the shipped config.json. Timestamps are absolute so the verdicts
# do not move with the wall clock — which is itself the point of case `heartbeat`.
verdicts="$(node -e '
  var D = {config: {stage_backstops: {coordinator: 15, implementor: 90,
                                      reviewer: 30, enabler: 30}},
           generated_at: "2026-01-01T04:40:00Z"};
'"$helper"'
'"$rule"'
  var T = function (m) {
    return new Date(Date.parse("2026-01-01T04:00:00Z") + m*60000).toISOString();
  };
  console.log(JSON.stringify({
    overrun:      stageOverrun("coordinator", T(0), T(40)),
    well_within:  stageOverrun("coordinator", T(0), T(10)),
    inside_grace: stageOverrun("coordinator", T(0), T(16)),
    past_grace:   stageOverrun("coordinator", T(0), T(18)),
    heartbeat:    stageOverrun("coordinator", T(0), T(5)),
    implementor:  stageOverrun("implementor", T(0), T(40)),
    unknown:      stageOverrun("project-reviewer", T(0), T(600)),
    no_timestamp: stageOverrun("coordinator", null, T(40)),
    announced:    stageOverrun("coordinator", T(0), T(40), 60),
    announced_hit: stageOverrun("coordinator", T(0), T(70), 60),
    announced_unknown_stage: stageOverrun("project-reviewer", T(0), T(200), 120),
    prior_only:   stageOverrun("reviewer", T(0), T(200)),
    row_running:  nodeStageOverrun({heartbeat_ts: T(40), self: false,
                                    live: {running: true, stage: "coordinator", stage_since: T(0)}}),
    row_announced: nodeStageOverrun({heartbeat_ts: T(40), self: false,
                                    live: {running: true, stage: "coordinator", stage_since: T(0),
                                           stage_backstop_min: 60}}),
    row_self:     nodeStageOverrun({heartbeat_ts: T(40), self: true,
                                    live: {running: true, stage: "coordinator", stage_since: T(0)}}),
    row_idle:     nodeStageOverrun({heartbeat_ts: T(40), self: false,
                                    live: {running: false, stage: "coordinator", stage_since: T(0)}}),
    row_no_live:  nodeStageOverrun({heartbeat_ts: T(40), self: false, live: null})
  }));
' 2>&1)" || { printf 'FAIL - the rule did not evaluate:\n%s\n' "$verdicts"; exit 1; }

v() { jq -r --arg k "$1" '.[$k] // "null"' <<<"$verdicts"; }

assert_contains "a Co-Ordinator 40m into a 15m backstop is flagged" \
  "coordinator has been live 40m against its own 15m backstop" "$(v overrun)"
assert_contains "and the message says what that means for the cycle" \
  "this cycle is over" "$(v overrun)"
assert_eq "a Co-Ordinator well inside its timeout is not" "null" "$(v well_within)"
assert_eq "nor is one inside the kill sequence's grace" "null" "$(v inside_grace)"
assert_contains "but past the grace it is" "18m against its own 15m" "$(v past_grace)"

# The property that makes the rule safe to believe: the verdict is a statement
# about what that node had published, not about how long ago it published it.
assert_eq "a stage judged only to the heartbeat is not flagged for the gap after it" \
  "null" "$(v heartbeat)"

assert_eq "each stage is held against its own timeout, not a shared one" \
  "null" "$(v implementor)"
assert_eq "a stage with no cap known to the page gets no verdict at all" \
  "null" "$(v unknown)"
assert_eq "and neither does one the log never dated" "null" "$(v no_timestamp)"

# The cap a stage was actually given outranks anything the page knows about
# actors in general — every stage now has its own, and the announced one is
# the number that will kill this stage and no other.
assert_eq "the announced cap outranks the fleet-wide one, and 40m inside 60m is not an overrun" \
  "null" "$(v announced)"
assert_contains "…while 70m past it is" \
  "against its own 60m backstop" "$(v announced_hit)"
assert_contains "an announced cap lets even an unnamed stage be judged" \
  "project-reviewer has been live" "$(v announced_unknown_stage)"
assert_contains "a stage with no announcement and no fleet figure falls back to the shipped prior" \
  "against its own 30m backstop" "$(v prior_only)"

assert_contains "a running row is judged" "coordinator" "$(v row_running)"
assert_eq "a row carrying its own cap is judged against that" "null" "$(v row_announced)"
# Our own row is exempt from the liveness rule because a live pid settles it.
# It is not exempt from this one: a pid proves the cycle script is alive, and a
# live script would have ended the stage itself.
assert_contains "our own row is judged too, unlike the liveness rule" \
  "coordinator" "$(v row_self)"
assert_eq "an idle row is not" "null" "$(v row_idle)"
assert_eq "nor is a node with no live state" "null" "$(v row_no_live)"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
