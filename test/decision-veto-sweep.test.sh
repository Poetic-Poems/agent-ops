#!/usr/bin/env bash
#
# test/decision-veto-sweep.test.sh — regression test for
# `run_decision_veto_sweep` (lib/decision-veto.sh, agent-ops#937,
# agent-ops#1198): the wiring that turns `scripts/sweep-decision-vetoes.sh`'s
# stdout into fleet-log events.
#
# This file's own job, on top of what `record_needs_refinement_block`'s
# recording is already covered by (test/dependency-block-refusal.test.sh and
# friends): that a veto re-block logs an `escalated` event naming the same
# log issue, `decision: true` — the registration that makes
# `ENABLER_ELIGIBLE_JQ` (lib/cycle-state.sh, see
# test/enabler-eligibility.test.sh's own decision-veto-tie cases) treat an
# open veto as a mechanical hold and its close as an immediate release. This
# fires whenever this item has a *live* block to attach it to — a freshly
# recorded one, or one this cycle's own `blocked_json` already carried before
# the sweep ran (review round 2: an Implementer needs-refinement bounce
# landing between the decision and the owner's reopen is exactly the case
# most likely to prompt a veto, and `record_needs_refinement_block` refuses
# to record a *second* block over the same item, so the registration must
# not depend on that call succeeding) — but never for an item with no live
# block at all (a genuinely malformed entry) or that does not match the veto
# this cycle's own `vetoed` action just reported.
#
# `scripts/sweep-decision-vetoes.sh` itself is replaced by a fixture under a
# fake `SCRIPT_DIR` that plays back a canned action stream regardless of its
# stdin — this file is about the wiring one level up, already covered
# end-to-end by test/sweep-decision-vetoes.test.sh for the script itself.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/decision-veto-sweep.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$REPO_ROOT/lib/cycle-state.sh"
# shellcheck source=lib/decision-veto.sh
. "$REPO_ROOT/lib/decision-veto.sh"

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

assert_eq_n() {  # assert_eq_n DESC EXPECTED_COUNT NEEDLE HAYSTACK — count of NEEDLE lines in HAYSTACK
  local desc="$1" expected="$2" needle="$3" haystack="$4" actual
  actual="$(grep -c -- "$needle" <<<"$haystack" || true)"
  assert_eq "$desc" "$expected" "$actual"
}

# --- Fixture harness ---------------------------------------------------------
# `run_decision_veto_sweep` shells out to
# "$SCRIPT_DIR/scripts/sweep-decision-vetoes.sh"; SCRIPT_DIR is pointed at a
# fake root whose own copy of that path is this test's own canned fixture,
# playing back one action stream regardless of stdin.
SCRIPT_DIR="$tmp_dir/fake-root"
mkdir -p "$SCRIPT_DIR/scripts"
fixture="$SCRIPT_DIR/scripts/sweep-decision-vetoes.sh"
cat > "$fixture" <<'STUB'
#!/usr/bin/env bash
cat "$ACTIONS_FILE"
STUB
chmod +x "$fixture"

CONFIG_FILE="$tmp_dir/config.json"
jq -n '{repos: [{slug: "acme/widgets"}]}' > "$CONFIG_FILE"

union_log="$tmp_dir/union.jsonl"
: > "$union_log"

cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"
node_name="node-1"
cycle_id="cycle-1"
DRY_RUN=0

LOG_EVENT_CALLS_FILE="$tmp_dir/log_event_calls"
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$LOG_EVENT_CALLS_FILE"; }
reset_log_event_calls() { rm -f "$LOG_EVENT_CALLS_FILE"; }
log_event_calls() { [[ -f "$LOG_EVENT_CALLS_FILE" ]] && cat "$LOG_EVENT_CALLS_FILE"; return 0; }

# RECORD_RESULT controls whether the stubbed recorder reports the block as
# newly recorded (0, the ordinary case) or refused (1): the real recorder's
# own refusal logic is covered elsewhere (test/dependency-block-refusal.test.sh
# and neighbours). blocked_json is the cycle global the real recorder itself
# consults for its own already-blocked refusal — set before a case simulates
# an item that already carries a live block when the sweep runs.
RECORD_RESULT=0
blocked_json='[]'
RECORD_CALLS_FILE="$tmp_dir/record_calls"
reset_record_calls() { rm -f "$RECORD_CALLS_FILE"; RECORD_RESULT=0; blocked_json='[]'; }
# shellcheck disable=SC2317  # invoked only by run_decision_veto_sweep
record_needs_refinement_block() {
  printf '%s\t%s\n' "$1" "$2" >> "$RECORD_CALLS_FILE"
  return "$RECORD_RESULT"
}

run() {  # run ACTIONS_JSONL — runs the sweep with the fixture playing back the given actions
  local actions_file="$tmp_dir/actions.jsonl"
  printf '%s' "$1" > "$actions_file"
  ACTIONS_FILE="$actions_file" run_decision_veto_sweep
}

# --- Case 1: an ordinary non-terminal veto — the block is recorded, and an
# `escalated` event registers the same log issue, marked `decision: true` ---
reset_log_event_calls
reset_record_calls
actions='{"action":"vetoed","repo":"acme/widgets","item":"42","issue_number":501,"issue_url":"https://github.com/acme/widgets/issues/501","by":"warwickallen","terminal":false}
{"action":"needs-refinement","repo":"acme/widgets","item":"42","reason":"a human vetoed the pipeline decision by reopening https://github.com/acme/widgets/issues/501","missing":"the owner decision, posted as a comment","evidence":"decision-log issue https://github.com/acme/widgets/issues/501 was reopened"}
{"action":"comment-posted","repo":"acme/widgets","item":"42","url":"https://github.com/acme/widgets/issues/42#issuecomment-1"}'
run "$actions"

calls="$(log_event_calls)"
assert_eq_n "logs exactly one decision-vetoed event" "1" "^decision-vetoed" "$calls"
assert_eq_n "logs exactly one escalated event" "1" "^escalated" "$calls"
esc_fields="$(grep '^escalated' <<<"$calls" | cut -f2-)"
assert_eq "the escalated event names the same log issue number" "501" "$(jq -r '.issue_number' <<<"$esc_fields")"
assert_eq "...and its url" "https://github.com/acme/widgets/issues/501" "$(jq -r '.issue_url' <<<"$esc_fields")"
assert_eq "...and the original item, not the log issue" "42" "$(jq -r '.item' <<<"$esc_fields")"
assert_eq "...and the repo" "acme/widgets" "$(jq -r '.repo' <<<"$esc_fields")"
assert_eq "...marked decision: true, distinguishing it from an ordinary Enabler escalation" \
  "true" "$(jq -r '.decision' <<<"$esc_fields")"
assert_eq "the recorder is called with the block, stage script" "script" \
  "$(cut -f2 "$RECORD_CALLS_FILE")"

# --- Case 2: the recorder refuses, and the item was not already blocked
# either (a genuinely malformed entry) — no escalated event is logged, since
# there is no live block anywhere to attach it to ----------------------------
reset_log_event_calls
reset_record_calls
RECORD_RESULT=1
run "$actions"
calls="$(log_event_calls)"
assert_eq_n "still logs the decision-vetoed event" "1" "^decision-vetoed" "$calls"
assert_eq_n "logs no escalated event when nothing is actually blocked" "0" "^escalated" "$calls"

# --- Case 2b (review round 2): the recorder refuses because the item was
# *already* blocked (blocked_json already carries it) when the sweep ran —
# the escalated event still fires, registering the existing block rather
# than a fresh one, since an Implementer needs-refinement bounce landing
# between the decision and the owner's reopen is exactly the real case this
# covers, not a corner case -----------------------------------------------
reset_log_event_calls
reset_record_calls
RECORD_RESULT=1
blocked_json='[{"repo":"acme/widgets","item":"42","detail":"needs a human to add a secret"}]'
run "$actions"
calls="$(log_event_calls)"
assert_eq_n "still logs the decision-vetoed event" "1" "^decision-vetoed" "$calls"
assert_eq_n "logs the escalated event against the item's existing block" "1" "^escalated" "$calls"
esc_fields="$(grep '^escalated' <<<"$calls" | cut -f2-)"
assert_eq "the escalated event still names the log issue, not the pre-existing block" \
  "501" "$(jq -r '.issue_number' <<<"$esc_fields")"

# --- Case 3: a terminal veto (revisit-filed, no needs-refinement action at
# all) — nothing to register an escalation against, so none is logged -------
reset_log_event_calls
reset_record_calls
terminal_actions='{"action":"vetoed","repo":"acme/widgets","item":"44","issue_number":503,"issue_url":"https://github.com/acme/widgets/issues/503","by":"warwickallen","terminal":true}
{"action":"revisit-filed","repo":"acme/widgets","item":"44","number":700,"url":"https://github.com/acme/widgets/issues/700"}'
run "$terminal_actions"
calls="$(log_event_calls)"
assert_eq_n "logs the decision-vetoed event for a terminal item too" "1" "^decision-vetoed" "$calls"
assert_eq_n "logs no escalated event — there is no re-block to register it against" "0" "^escalated" "$calls"

echo
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
echo "all tests passed"
