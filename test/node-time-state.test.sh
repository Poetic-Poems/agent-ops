#!/usr/bin/env bash
#
# test/node-time-state.test.sh — self-contained regression test for
# lib/node-time-state.sh (docs/FLOW-SCHEMA.md's "Node time-state record",
# D21 of docs/ROADMAP.md, issue #597).
#
# What matters here:
#
#   the six states     every node-second in the window lands in exactly one
#   are exhaustive      of producing/overhead/externally-blocked/idle-with-
#   and mutually        demand/idle-without-demand/down, or unaccounted for
#   exclusive           an unrecognised `state` — never both, never neither.
#   the invariant       `expected_total_seconds` (node-count x window) equals
#   balances            the sum of every state plus `unaccounted`, asserted
#                        on a fixture exercising every state at once.
#   the cause           idle-with-demand seconds are split by the four D21
#   translation         causes; the four pre-existing stand-down causes this
#                        requirement does not rename (raced, pre-claimed,
#                        fabricated, untraceable) translate to peer-claimed/
#                        coordinator-declined via node_time_state_for_cause.
#   absence is down     a node with zero events in the window, and a node
#                        whose first event lands partway through it, both
#                        score `down` for the ungoverned stretch.
#   no double-counting  two overlapping event streams for one node (an
#                        agent-cycle.sh run and a review-cycle.sh run) do not
#                        inflate that node's total past one window's worth
#                        of seconds — every point lands on one merged,
#                        chronologically-ordered timeline.
#   degradations        a malformed raw line, an event naming no node, a
#                        `node-state` event whose `ts` is present but fails
#                        `fromdateiso8601`, and a `node-state` event with no
#                        `cause` (idle-with-demand with an unrecognised or
#                        absent cause counts under `unspecified` rather than
#                        being dropped) all yield a conforming report rather
#                        than aborting the fold.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/node-time-state.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# lib/node-time-state.sh's logging helpers call this; the fold itself never
# does, but sourcing the file defines log_node_state_transition/
# set_node_state_terminal/suppress_node_state_transitions too, which this
# file's own cause-translation and suppression tests drive. Capturing rather
# than discarding, so "emits nothing" is assertable as a fact about what
# reached the log and not merely as the absence of a crash.
logged_events=()
log_event() { logged_events+=("$1 $2"); }
reset_node_state() {
  logged_events=()
  unset _NODE_STATE_CURRENT _CYCLE_TERMINAL_STATE _CYCLE_TERMINAL_CAUSE _NODE_STATE_SUPPRESSED
}

# shellcheck source=lib/node-time-state.sh
. "$SCRIPT_DIR/lib/node-time-state.sh"

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

fold_of() {  # <fixture-file> [since [until]]
  node_time_state_fold "$1" "${2:-}" "${3:-}"
}

# --- The cause vocabulary (node_time_state_for_cause) ------------------------

assert_eq "disabled-node maps to down" \
  "down	disabled-node" "$(node_time_state_for_cause disabled-node)"
assert_eq "disabled-fleet maps to down" \
  "down	disabled-fleet" "$(node_time_state_for_cause disabled-fleet)"
assert_eq "usage-limit maps to externally-blocked" \
  "externally-blocked	usage-limit" "$(node_time_state_for_cause usage-limit)"
assert_eq "unreachable maps to externally-blocked" \
  "externally-blocked	unreachable" "$(node_time_state_for_cause unreachable)"
assert_eq "back-pressure maps to idle-with-demand" \
  "idle-with-demand	back-pressure" "$(node_time_state_for_cause back-pressure)"
assert_eq "raced translates to idle-with-demand/peer-claimed (never renamed on its own event)" \
  "idle-with-demand	peer-claimed" "$(node_time_state_for_cause raced)"
assert_eq "pre-claimed translates to idle-with-demand/peer-claimed" \
  "idle-with-demand	peer-claimed" "$(node_time_state_for_cause pre-claimed)"
assert_eq "fabricated translates to idle-with-demand/coordinator-declined" \
  "idle-with-demand	coordinator-declined" "$(node_time_state_for_cause fabricated)"
assert_eq "untraceable translates to idle-with-demand/coordinator-declined" \
  "idle-with-demand	coordinator-declined" "$(node_time_state_for_cause untraceable)"
assert_eq "no-demand maps to idle-without-demand" \
  "idle-without-demand	no-demand" "$(node_time_state_for_cause no-demand)"
assert_eq "an unrecognised cause maps to nothing — never guessed at" \
  "	" "$(node_time_state_for_cause bogus-cause)"

assert_eq "idle_split: positive total -> idle-with-demand with the named cause" \
  "idle-with-demand	awaiting-tick" "$(node_time_state_idle_split 3 awaiting-tick)"
assert_eq "idle_split: zero total -> the healthy idle-without-demand zero" \
  "idle-without-demand	no-demand" "$(node_time_state_idle_split 0 awaiting-tick)"
assert_eq "idle_split: an unreadable total degrades to the healthy zero, never a guess" \
  "idle-without-demand	no-demand" "$(node_time_state_idle_split "" awaiting-tick)"

# --- A tick that owns no node-second emits nothing ---------------------------
#
# The one pitfall #597's own refinement names by hand: "`cycle-skipped` is not
# a state. A tick that found the lock held means the node is busy in the other
# process, whose own events already own those seconds." The fold holds each
# point's state until the next point's `ts`, and a running stage emits nothing
# between its own `stage-start` and `stage-end`, so a single transition from a
# skipped tick would relabel the rest of a live Implementer engagement as this
# tick's idle. Asserted here rather than left to the emission sites' own
# comments, because "logs nothing" is invisible in every other test.

reset_node_state
suppress_node_state_transitions
finalize_node_state_for_cycle
assert_eq "a suppressed cycle logs no terminal transition at all" \
  "0" "${#logged_events[@]}"

reset_node_state
suppress_node_state_transitions
set_node_state_terminal idle-with-demand back-pressure
finalize_node_state_for_cycle
assert_eq "  ... even when a terminal state was already recorded before it" \
  "0" "${#logged_events[@]}"

reset_node_state
suppress_node_state_transitions
finalize_node_state_for_review
assert_eq "a suppressed review run logs no terminal transition either" \
  "0" "${#logged_events[@]}"

# The control: without suppression, both finalizers do log — so the assertions
# above are testing the suppression and not a stub that never fires.
reset_node_state
finalize_node_state_for_cycle
assert_eq "unsuppressed, a cycle with no gather settles into the healthy zero" \
  "1" "${#logged_events[@]}"
assert_eq "  ... naming idle-without-demand/no-demand" \
  'node-state {"state":"idle-without-demand","prev_state":"down","cause":"no-demand"}' \
  "${logged_events[0]}"

reset_node_state
eligible_items_total=4
finalize_node_state_for_cycle
assert_eq "unsuppressed, a positive eligible count minus this cycle's own claim is idle-with-demand" \
  'node-state {"state":"idle-with-demand","prev_state":"down","cause":"awaiting-tick"}' \
  "${logged_events[0]}"
eligible_items_total=1
reset_node_state
finalize_node_state_for_cycle
assert_eq "  ... and an eligible count of exactly one (the item just claimed) is the healthy zero" \
  'node-state {"state":"idle-without-demand","prev_state":"down","cause":"no-demand"}' \
  "${logged_events[0]}"
unset eligible_items_total
reset_node_state

assert_eq "node_state_for_stage: implementer is producing" \
  "producing" "$(node_state_for_stage implementer)"
assert_eq "node_state_for_stage: reviewer is producing" \
  "producing" "$(node_state_for_stage reviewer)"
assert_eq "node_state_for_stage: every other actor is overhead" \
  "overhead" "$(node_state_for_stage coordinator)"
assert_eq "  ... enabler too" "overhead" "$(node_state_for_stage enabler)"
assert_eq "  ... approver-adjudicate-open-question too" \
  "overhead" "$(node_state_for_stage approver-adjudicate-open-question)"

# --- Every state exercised at once, on two nodes, plus the invariant --------
#
# Node n1: down (before its first event, 00:00-00:10) -> overhead (a
# coordinator stage, 00:10-00:20) -> producing (an implementer stage,
# 00:20-00:40) -> overhead (stage-end, 00:40-00:45) -> externally-blocked
# (a github-budget stand-down, 00:45-01:00) -> idle-with-demand/back-pressure
# (01:00 to the window's own end, 01:30).
#
# Node n2: down until 00:50, then idle-without-demand/no-demand for the rest
# of the window — the "absent for part of the window" case.
fixture="$tmp_dir/six-states.jsonl"
cat > "$fixture" <<'EOF'
{"ts":"2026-02-01T00:10:00Z","node":"n1","cycle":"c1","event":"node-state","state":"overhead","prev_state":"down","cause":null}
{"ts":"2026-02-01T00:20:00Z","node":"n1","cycle":"c1","event":"node-state","state":"producing","prev_state":"overhead","cause":null}
{"ts":"2026-02-01T00:40:00Z","node":"n1","cycle":"c1","event":"node-state","state":"overhead","prev_state":"producing","cause":null}
{"ts":"2026-02-01T00:45:00Z","node":"n1","cycle":"c1","event":"node-state","state":"externally-blocked","prev_state":"overhead","cause":"github-budget"}
{"ts":"2026-02-01T01:00:00Z","node":"n1","cycle":"c1","event":"node-state","state":"idle-with-demand","prev_state":"externally-blocked","cause":"back-pressure"}
{"ts":"2026-02-01T00:50:00Z","node":"n2","cycle":"c2","event":"node-state","state":"idle-without-demand","prev_state":"down","cause":"no-demand"}
EOF

# --since is set explicitly to 00:00 — ten minutes before n1's own first
# event — so this fixture can exercise n1's own leading "absent" gap too;
# left at its default (derived from the earliest event seen), the window
# would start exactly at n1's first event and that gap would be zero by
# construction, proving nothing.
report="$(fold_of "$fixture" "2026-02-01T00:00:00Z")"

assert_eq "window starts at the explicit --since, ends at the latest event" \
  '{"from":"2026-02-01T00:00:00Z","to":"2026-02-01T01:00:00Z"}' \
  "$(jq -c '.window | {from, to}' <<<"$report")"
assert_eq "n1: down for the leading gap before its first event" \
  "600" "$(jq -c '.by_node.n1.down' <<<"$report")"
assert_eq "n1: overhead sums both overhead stretches (00:10-00:20, 00:40-00:45)" \
  "900" "$(jq -c '.by_node.n1.overhead' <<<"$report")"
assert_eq "n1: producing for its one implementer stretch" \
  "1200" "$(jq -c '.by_node.n1.producing' <<<"$report")"
assert_eq "n1: externally-blocked for its github-budget stretch" \
  "900" "$(jq -c '.by_node.n1["externally-blocked"]' <<<"$report")"
assert_eq "n1: idle-with-demand from its last transition to the window's own end" \
  "0" "$(jq -c '.by_node.n1["idle-with-demand"]' <<<"$report")"
assert_eq "n2: absent for the whole window before its one event scores down" \
  "3000" "$(jq -c '.by_node.n2.down' <<<"$report")"
assert_eq "n2: idle-without-demand for the remainder" \
  "600" "$(jq -c '.by_node.n2["idle-without-demand"]' <<<"$report")"
assert_eq "the invariant balances: node-count x window == every state summed" \
  "true" "$(jq -c '.balanced' <<<"$report")"
assert_eq "  ... expected_total_seconds is node-count (2) x window (3600s)" \
  "7200" "$(jq -c '.expected_total_seconds' <<<"$report")"

# --- A wider window (--until past n1's last event) puts real seconds behind
#     idle-with-demand, so the cause split has something to report ----------

report_wide="$(fold_of "$fixture" "" "2026-02-01T01:30:00Z")"
assert_eq "widening the window with --until extends the last transition's own interval" \
  "1800" "$(jq -c '.by_node.n1["idle-with-demand"]' <<<"$report_wide")"
assert_eq "idle_with_demand_by_cause attributes it to back-pressure" \
  "1800" "$(jq -c '.idle_with_demand_by_cause["back-pressure"]' <<<"$report_wide")"
assert_eq "  ... and the invariant still balances over the wider window" \
  "true" "$(jq -c '.balanced' <<<"$report_wide")"

# --- No double-counting across two overlapping event streams for one node --
#
# Same node, two "pipelines" (agent-cycle.sh's and review-cycle.sh's own
# node-state events, unioned exactly as scripts/node-time-state.sh unions
# log.jsonl and review-log.jsonl) both logging transitions inside one
# window. However they interleave, the merged single timeline still gives
# this one node exactly one window's worth of seconds.
overlap_fixture="$tmp_dir/overlap.jsonl"
cat > "$overlap_fixture" <<'EOF'
{"ts":"2026-03-01T00:00:00Z","node":"n1","cycle":"a1","event":"node-state","state":"overhead","cause":null}
{"ts":"2026-03-01T00:05:00Z","node":"n1","cycle":"r1","event":"node-state","state":"producing","cause":null}
{"ts":"2026-03-01T00:10:00Z","node":"n1","cycle":"a1","event":"node-state","state":"overhead","cause":null}
{"ts":"2026-03-01T00:15:00Z","node":"n1","cycle":"r1","event":"node-state","state":"idle-without-demand","cause":"no-demand"}
EOF
overlap_report="$(fold_of "$overlap_fixture")"
assert_eq "one node's merged timeline over two streams still sums to exactly one window" \
  "900" "$(jq -c '[.by_node.n1 | del(.idle_with_demand_by_cause) | to_entries[] | .value] | add' <<<"$overlap_report")"
assert_eq "  ... expected_total_seconds agrees (1 node x 900s)" \
  "900" "$(jq -c '.expected_total_seconds' <<<"$overlap_report")"
assert_eq "  ... and it balances" "true" "$(jq -c '.balanced' <<<"$overlap_report")"

# --- An unrecognised state is unaccounted, not dropped and not misclassified

unknown_fixture="$tmp_dir/unknown-state.jsonl"
cat > "$unknown_fixture" <<'EOF'
{"ts":"2026-04-01T00:00:00Z","node":"n1","event":"node-state","state":"overhead","cause":null}
{"ts":"2026-04-01T00:10:00Z","node":"n1","event":"node-state","state":"rebooting","cause":null}
{"ts":"2026-04-01T00:20:00Z","node":"n1","event":"node-state","state":"overhead","cause":null}
EOF
unknown_report="$(fold_of "$unknown_fixture")"
assert_eq "an unrecognised state's own interval lands in unaccounted" \
  "600" "$(jq -c '.by_node.n1.unaccounted' <<<"$unknown_report")"
assert_eq "  ... the invariant still balances (unaccounted counted, never dropped)" \
  "true" "$(jq -c '.balanced' <<<"$unknown_report")"

# --- idle-with-demand with no recognised cause counts as unspecified, never
#     dropped and never guessed at a real cause -------------------------------

no_cause_fixture="$tmp_dir/no-cause.jsonl"
cat > "$no_cause_fixture" <<'EOF'
{"ts":"2026-05-01T00:00:00Z","node":"n1","event":"node-state","state":"idle-with-demand"}
{"ts":"2026-05-01T00:10:00Z","node":"n1","event":"node-state","state":"idle-with-demand","cause":"something-new"}
{"ts":"2026-05-01T00:20:00Z","node":"n1","event":"node-state","state":"overhead"}
EOF
no_cause_report="$(fold_of "$no_cause_fixture")"
assert_eq "idle-with-demand with no cause field at all still counts toward the state total" \
  "1200" "$(jq -c '.by_node.n1["idle-with-demand"]' <<<"$no_cause_report")"
assert_eq "  ... both intervals land under unspecified, none of the four named causes" \
  "1200" "$(jq -c '.by_node.n1.idle_with_demand_by_cause.unspecified' <<<"$no_cause_report")"
assert_eq "  ... and the fleet-wide split agrees" \
  "1200" "$(jq -c '.idle_with_demand_by_cause.unspecified' <<<"$no_cause_report")"

# --- A malformed raw line and an event naming no node are both excluded,
#     never fatal to the fold, and counted under skipped_events ------------

degraded_fixture="$tmp_dir/degraded.jsonl"
cat > "$degraded_fixture" <<'EOF'
this line is not JSON at all
{"ts":"2026-06-01T00:00:00Z","node":"n1","event":"node-state","state":"overhead"}
{"ts":"2026-06-01T00:05:00Z","event":"node-state","state":"producing"}
{"ts":"2026-06-01T00:10:00Z","node":"n1","event":"node-state","state":"overhead"}
EOF
degraded_report="$(fold_of "$degraded_fixture")"
assert_eq "a malformed raw line does not abort the fold" \
  "600" "$(jq -c '.window.seconds' <<<"$degraded_report")"
assert_eq "an event naming no node is excluded from every node's timeline" \
  "1" "$(jq -c '.skipped_events' <<<"$degraded_report")"
assert_eq "  ... and the invariant still balances over what remains" \
  "true" "$(jq -c '.balanced' <<<"$degraded_report")"

# --- A node-state event whose ts is present but fails fromdateiso8601 (a
#     +00:00 offset here, rather than the strict Z form) is excluded the
#     same way a missing ts is, never aborting the fold to the fallback
#     all-empty shape -----------------------------------------------------

bad_ts_fixture="$tmp_dir/bad-ts.jsonl"
cat > "$bad_ts_fixture" <<'EOF'
{"ts":"2026-06-03T00:00:00Z","node":"n1","event":"node-state","state":"overhead"}
{"ts":"2026-06-03T00:05:00+00:00","node":"n1","event":"node-state","state":"producing"}
{"ts":"2026-06-03T00:10:00Z","node":"n1","event":"node-state","state":"overhead"}
EOF
bad_ts_report="$(fold_of "$bad_ts_fixture")"
assert_eq "a node-state event with an unparseable ts does not abort the fold" \
  "600" "$(jq -c '.window.seconds' <<<"$bad_ts_report")"
assert_eq "  ... it is excluded from every node's timeline, counted under skipped_events" \
  "1" "$(jq -c '.skipped_events' <<<"$bad_ts_report")"
assert_eq "  ... the two well-formed events still fold normally into totals" \
  '{"producing":0,"overhead":600}' \
  "$(jq -c '{producing: .totals.producing, overhead: .totals.overhead}' <<<"$bad_ts_report")"
assert_eq "  ... and into by_node, never the fallback all-empty shape" \
  "600" "$(jq -c '.by_node.n1.overhead' <<<"$bad_ts_report")"
assert_eq "  ... and the invariant still balances over what remains" \
  "true" "$(jq -c '.balanced' <<<"$bad_ts_report")"

# --- An empty or unreadable log prints a conforming, all-zero report -------

empty_out="$(fold_of "$tmp_dir/does-not-exist.jsonl")"
assert_eq "a missing log reports zero nodes" "[]" "$(jq -c '.nodes' <<<"$empty_out")"
assert_eq "  ... balanced true, window seconds 0" \
  '{"balanced":true,"seconds":0}' "$(jq -c '{balanced, seconds: .window.seconds}' <<<"$empty_out")"
assert_eq "  ... and an empty by_node object, never a missing key" \
  '{}' "$(jq -c '.by_node' <<<"$empty_out")"

# --- review-cycle.sh: a stand-down that exits while agent-cycle.sh owns the
#     node emits no node-state transition -----------------------------------
#
# The rule docs/FLOW-SCHEMA.md states as "A tick that owns no node-second
# emits nothing", checked at the sites most likely to break it silently.
# review-cycle.sh's implementation-cycle stand-down is only the *last* ending
# that can fire while agent-cycle.sh is mid-stage on this node; six others —
# both switch stand-downs, both `not_before` stand-downs, the tier-two
# all-repos-held one and the usage-limit cooldown — exit before it is ever
# reached, and each records a terminal state. Left unsuppressed they log the
# competing idle/`down` transition the same section calls actively wrong, and
# because the fold holds each point until the next point's `ts`, one such tick
# relabels the rest of a live Implementer engagement.
#
# First structurally, over every one of them at once, so a seventh site added
# later cannot slip through: every `set_node_state_terminal` call that appears
# before the implementation-cycle check must be followed immediately by
# `suppress_node_state_if_peer_owns_node`.

review_cycle="$SCRIPT_DIR/review-cycle.sh"
unguarded="$(awk '
  /^if impl_cycle_running; then/ { past = 1 }
  past { next }
  prev ~ /^[[:space:]]*set_node_state_terminal / && $0 !~ /^[[:space:]]*suppress_node_state_if_peer_owns_node$/ {
    printf "%d:%s\n", NR - 1, prev
  }
  { prev = $0 }
' "$review_cycle")"
assert_eq "every terminal state recorded before the implementation-cycle check is guarded" \
  "" "$unguarded"
assert_eq "  ... and there is at least one such site, so the scan is not vacuous" \
  "6" "$(awk '/^if impl_cycle_running; then/ { exit } /^[[:space:]]*suppress_node_state_if_peer_owns_node$/ { n++ } END { print n + 0 }' "$review_cycle")"

# Then behaviourally, end to end, against the real script — the routine case,
# since `project_review.defaults.not_before` in force is a steady state rather
# than a race: on an installation using it *every* review tick reaches this
# ending, including the ones landing inside a live Implementer stage.

shim_node() {  # shim_node <name> -> prints its directory
  # Separate statements on purpose: `local a=… b="$a"` expands every argument
  # before assigning any, so the second would read an unset `name` under
  # `set -u` — the same note test/review-not-before.test.sh carries at its own
  # copy of this shim.
  local name="$1"
  local dir="$tmp_dir/$name"
  local item
  mkdir -p "$dir" "$dir/home/.local/state/poetic-agents"
  for item in lib prompts scripts .claude review-cycle.sh agent-cycle.sh config.schema.json; do
    [[ -e "$SCRIPT_DIR/$item" ]] && ln -s "$SCRIPT_DIR/$item" "$dir/$item"
  done
  # `repos: []` and `state_repo: ""` keep the run offline; the stand-down
  # under test fires long before either would matter anyway.
  jq '.project_review.repos = [] | .state_repo = ""
      | .project_review.defaults.not_before = "2099-01-01T00:00:00Z"' \
    "$SCRIPT_DIR/config.json" > "$dir/config.json"
  printf '%s' "$dir"
}

node_states_of() {  # node_states_of <dir> -> one "state/cause" per line
  jq -r 'select(.event == "node-state") | "\(.state)/\(.cause)"' \
    "$1/home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null || true
}

run_shim_review() {  # run_shim_review <dir>
  env HOME="$1/home" AGENT_OPS_ROLE=active timeout 60 "$1/review-cycle.sh" --once >/dev/null 2>&1
}

# A live holder of lock.json: any process this test can prove is running.
sleep 60 &
live_pid=$!
d="$(shim_node busy)"
jq -nc --argjson p "$live_pid" '{pid: $p}' > "$d/home/.local/state/poetic-agents/lock.json"
run_shim_review "$d"
assert_eq "a not_before stand-down logs no node-state while agent-cycle.sh holds the node" \
  "" "$(node_states_of "$d")"
assert_eq "  ... and still stands down for its own reason, unchanged" \
  "no-demand" "$(jq -r 'select(.event == "review-stand-down") | .cause' \
    "$d/home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null)"
kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null

# The two negatives that matter: silence must be caused by the peer, not by
# the guard swallowing the transition wholesale. A node with no lock at all,
# and a node whose lock.json names a pid that is gone, both still emit.
d="$(shim_node idle)"
run_shim_review "$d"
assert_eq "with no implementation cycle running, the same stand-down still logs its idle state" \
  "idle-without-demand/no-demand" "$(node_states_of "$d")"

d="$(shim_node stale)"
jq -nc '{pid: 2147483646}' > "$d/home/.local/state/poetic-agents/lock.json"
run_shim_review "$d"
assert_eq "a lock.json naming a pid that is gone does not suppress the transition" \
  "idle-without-demand/no-demand" "$(node_states_of "$d")"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
