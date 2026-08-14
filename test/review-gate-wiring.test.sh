#!/usr/bin/env bash
#
# test/review-gate-wiring.test.sh — regression test for the block in
# agent-cycle.sh that decides what requirement 31c's gate
# (lib/review-gate.sh) actually *does* with each of its verdicts at the
# Reviewer's `ready` handoff.
#
# test/review-gate.test.sh covers the verdict itself. It passes with the
# consequence wired either way round, and the consequence is what
# TD-PPagop-26081305 was filed about:
#
#   - **`dirty` refuses the handoff**, recording the requirement 32a handback
#     whose `unblock_condition` names the pull-request-shaped fault to fix.
#   - **The blocking `unknown` refuses it too, but says something else.** A
#     required-check list this node could not read is a fact about the node;
#     it earns its own `warning` — so a degraded `gh` is visible as a pattern
#     across items rather than as N pull requests each apparently broken — and
#     a handback whose `unblock_condition` points at retrying rather than at a
#     defect that may not exist. Recording it under the `dirty` wording was
#     the debt; recording it as no handback at all would hand a human a pull
#     request certified on a check list nobody read.
#   - **The non-blocking `unknown` is neither.** An alerts read that could not
#     be asked (exit 0, same word) must fall through to the rest of the
#     handoff — its `warning` is logged further down, past the extract below —
#     because a token missing one permission must not freeze the fleet.
#   - **The word alone cannot tell the last two apart**, so the block has to
#     read `review_gate_verdict`'s exit status; a `|| true` here is the
#     regression this file exists to catch.
#
# TD-PPagop-26081404 added one more property: the blocking `unknown`'s own
# `warning` is a per-item event, and a `gh` degraded enough to earn one rarely
# earns only one — once `review_gate_unknown_streak_verdict` (its own test in
# test/review-gate.test.sh) reports this node's run has crossed the
# threshold, the block must log one `review-gate-checks-degraded` escalation
# instead of piling another `warning` on top, while still refusing the
# handoff exactly as before.
#
# The block is lifted verbatim out of agent-cycle.sh, the same way
# test/closing-keyword-wiring.test.sh lifts its own, so the assertions are
# about the shipped code rather than a copy of its logic. Its callees are
# stubbed: `review_gate_verdict` and `review_gate_unknown_streak_verdict`
# (each covered by its own test in test/review-gate.test.sh), `log_event`
# and `log_reviewer_handback`.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/review-gate-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                 %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- Extraction ---------------------------------------------------------------
# From the gate's own `gate_default_branch` lookup to the requirement 25a
# comment that starts the closing-keyword gate below it — everything that acts
# on `review_gate_verdict`'s answer, and nothing else.
gate_block="$(awk '
  /^  gate_default_branch=/                      { on = 1 }
  on && /^  # Requirement 25a, asked again here/ { exit }
  on                                             { print }
' "$CYCLE")"

if [[ -z "$gate_block" ]]; then
  echo "FAIL - could not extract the ready-gate block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

URL="https://github.com/Poetic-Poems/poetic-fiddle/pull/198"

# run_gate_block VERDICT RC [STREAK_JSON]
# Runs the block under the same `set -euo pipefail` agent-cycle.sh runs under,
# with `review_gate_verdict` stubbed to print VERDICT (a literal `clean` /
# `dirty<TAB>reason` / `unknown<TAB>reason`) and exit RC, and
# `review_gate_unknown_streak_verdict` (TD-PPagop-26081404) stubbed to print
# STREAK_JSON (empty by default — no streak reached). `node_name`,
# `log_file` and `review_gate_unknown_streak_after` are defined the way
# agent-cycle.sh's own top level defines them; the streak function is
# stubbed rather than run for real, so their values only need to exist, not
# to be meaningful — `log_file` still has to be a real, readable path, since
# the block redirects it into the (stubbed) function exactly as it would the
# real one. Prints every `log_event` call as `<kind><TAB><detail-or-count>`,
# every `log_reviewer_handback` as `handback<TAB><detail><TAB><unblock_condition>`,
# then `--` if the block ran to the end rather than ending the cycle.
# shellcheck disable=SC2016  # The harness's own `$1`/`$2`/`$3`, written out literally for it to expand, not this shell's.
run_gate_block() {
  local verdict="$1" rc="$2" streak_json="${3:-}" harness="$tmp_dir/gate-harness.sh"
  local events="$tmp_dir/events" node_log="$tmp_dir/node-log.jsonl"
  : > "$node_log"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'impl_pr_url=%q\n' "$URL"
    printf '%s\n' 'work_order_json='"'"'{"default_branch":"main"}'"'"''
    printf 'node_name=%q\n' "n1"
    printf 'log_file=%q\n' "$node_log"
    printf '%s\n' 'review_gate_unknown_streak_after=3'
    printf '%s\n' 'log_event() { printf "%s\t%s\n" "$1" "$(jq -r ".detail // .count // \"\"" <<<"$2")" >>'"$(printf '%q' "$events")"'; }'
    printf '%s\n' 'log_reviewer_handback() { printf "handback\t%s\t%s\n" "$1" "${3:-}" >>'"$(printf '%q' "$events")"'; }'
    printf 'review_gate_verdict() { printf %%s %q; return %q; }\n' "$verdict" "$rc"
    printf 'review_gate_unknown_streak_verdict() { cat >/dev/null; printf %%s %q; }\n' "$streak_json"
    printf '%s\n' "$gate_block"
    printf '%s\n' 'printf -- "--\n" >>'"$(printf '%q' "$events")"''
  } > "$harness"
  : > "$events"
  bash "$harness" >/dev/null 2>&1
  cat "$events"
}

# The marker is the last line, and the command substitution above eats its
# newline, so both forms have to be accepted — the same shape
# test/closing-keyword-wiring.test.sh's own `reached_end` takes.
reached_end() { [[ "$1" == *$'--\n'* || "$1" == *'--' ]] && echo yes || echo no; }

# --- dirty: the pull request's own fault, named as such -----------------------
out="$(run_gate_block "dirty	required check(s) not green: CI" 1)"
assert_eq "a dirty verdict ends the cycle rather than handing off" "no" "$(reached_end "$out")"
assert_contains "  ... recording the handback naming what the gate found" \
  "required check(s) not green: CI" "$out"
assert_contains "  ... with the unblock_condition a real failure earns" \
  "Get every required check green" "$out"
assert_lacks "  ... and no node-level warning, since nothing implicates the node" \
  "warning" "$out"

# --- the blocking unknown: the node's fault, named as such --------------------
# TD-PPagop-26081305: the debt was that this arrived as the `dirty` handback
# above, whose unblock_condition names nothing this node can fix.
UNREADABLE="could not read $URL's required checks against its current head commit"
out="$(run_gate_block "unknown	$UNREADABLE" 1)"
assert_eq "an unreadable required-check list refuses the handoff too" "no" "$(reached_end "$out")"
assert_contains "  ... logging a node-level warning naming what could not be read" \
  "warning	" "$out"
assert_contains "  ... the warning carrying the gate's own reason" "$UNREADABLE" "$out"
assert_contains "  ... and a handback pointing at retrying once GitHub can be read" \
  "Retry once a node can read GitHub" "$out"
assert_lacks "  ... never the required-checks wording, which names nothing to fix here" \
  "Get every required check green" "$out"

# --- the blocking unknown, streak escalated: one loud event, not another warning
# TD-PPagop-26081404: once `review_gate_unknown_streak_verdict` reports this
# node's run has crossed the threshold, the per-item node-level `warning`
# above is replaced by one `review-gate-checks-degraded` event naming the
# streak — the handback itself is unchanged (still refuses the handoff, still
# points at retrying, never at the pull request).
STREAK='{"node":"n1","gate":"required-checks","count":3,"first_ts":"2026-08-14T10:00:00Z","last_ts":"2026-08-14T10:30:00Z"}'
out="$(run_gate_block "unknown	$UNREADABLE" 1 "$STREAK")"
assert_eq "an escalated streak still refuses the handoff" "no" "$(reached_end "$out")"
assert_contains "  ... logging the escalation event naming the count" \
  "review-gate-checks-degraded	3" "$out"
assert_lacks "  ... instead of the per-item node-level warning" \
  "warning	" "$out"
assert_contains "  ... and still hands back with the same retry unblock_condition" \
  "Retry once a node can read GitHub" "$out"

# --- the non-blocking unknown: exit 0, same word, opposite consequence --------
# The alerts read could not be asked. Its own warning is logged further down
# agent-cycle.sh, past this extract; what must hold here is that the handoff
# carries on. A block reading the word without the exit status stops here
# instead, freezing every pull request on a node whose token lacks one
# permission — which is what discarding the status with `|| true` used to
# guarantee in the other direction.
out="$(run_gate_block "unknown	could not confirm no new security-severity alert: 403" 0)"
assert_eq "an alerts-caused unknown does not end the cycle" "yes" "$(reached_end "$out")"
assert_lacks "  ... and records nothing against the item" "handback" "$out"
assert_lacks "  ... nor the node-level warning the blocking unknown earns" \
  "could not read" "$out"

# --- clean: nothing but the streak bookkeeping ---------------------------------
# TD-PPagop-26081404's bookkeeping event fires on every evaluation regardless
# of outcome — `review_gate_unknown_streak_verdict` needs it to tell a reset
# from a continuation — but it carries no warning or handback of its own.
out="$(run_gate_block "clean" 0)"
assert_eq "a clean verdict carries on to the rest of the handoff" "yes" "$(reached_end "$out")"
assert_contains "  ... logging only the streak bookkeeping event" \
  "review-gate-checks-read	" "$out"
assert_lacks "  ... no warning" "warning" "$out"
assert_lacks "  ... and no handback" "handback" "$out"

echo
if (( failures )); then
  printf 'review-gate-wiring.test.sh: %d assertion(s) failed\n' "$failures"
  exit 1
fi
echo "review-gate-wiring.test.sh: all assertions passed"
