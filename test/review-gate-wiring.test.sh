#!/usr/bin/env bash
#
# test/review-gate-wiring.test.sh — regression test for the block in
# agent-cycle.sh that decides what `handoff_complete_review`'s
# (lib/handoff.sh) verdict actually *does* at the Reviewer's `ready` handoff.
#
# Before agent-ops#440, this file stubbed `review_gate_verdict` directly and
# pinned the whole gate-then-flip sequence inline in agent-cycle.sh. That
# sequence now lives in `handoff_complete_review`, shared verbatim with the
# Enabler's `complete_handoff` recovery path (test/handoff.test.sh covers the
# function itself — every branch of `safe`/`gate`/`closing_keyword` it can
# return, including the exit-status-vs-word distinction TD-PPagop-26081305
# was filed over). What is left for this file is the thinner question: given
# each shape `handoff_complete_review` can return, does agent-cycle.sh's own
# Reviewer block react correctly?
#
#   - **`gate.word == "dirty"` ends the cycle**, recording the requirement 32a
#     handback whose `unblock_condition` names the pull-request-shaped fault.
#   - **`gate.checks_unreadable == true` ends it too, but says something
#     else.** A required-check list this node could not read is a fact about
#     the node; it earns its own `warning` — so a degraded `gh` is visible as
#     a pattern across items rather than as N pull requests each apparently
#     broken — and a handback whose `unblock_condition` points at retrying
#     rather than at a defect that may not exist.
#   - **`closing_keyword.word == "dirty"` (gate clean) ends it too**, naming
#     the missing keyword rather than either gate's own wording.
#   - **The flip itself failing (`safe: false`, everything else clean) ends
#     it with its own wording** — "still a draft", naming nothing to fix.
#   - **A non-blocking `unknown` (either gate) is none of the above.** `safe`
#     stays `true`; the block must fall through to the rest of the handoff,
#     leaving its own `warning` to the code past this extract.
#
# TD-PPagop-26081404's streak escalation is still exercised here —
# `handoff_complete_review` only reports whether the required-checks read
# failed, not how many times in a row this node has failed it — but as of
# TD-PPagop-26081603 the block calls the shared
# `review_gate_escalate_unreadable_streak` (also lifted verbatim, alongside
# the block itself) rather than running the streak-and-escalate sequence
# inline, so this file stubs only that helper's own two callees,
# `review_gate_unknown_streak_verdict` and `review_gate_degraded_since` (each
# covered by its own test in test/review-gate.test.sh), to pin the same
# behaviour:
#
#   - once `review_gate_unknown_streak_verdict` reports this node's run has
#     crossed the threshold, the block logs one `review-gate-checks-degraded`
#     escalation instead of piling another `warning` on top — and exactly
#     one: an already-escalated run (`review_gate_degraded_since`) logs
#     neither a repeat nor the warning — while still refusing the handoff
#     exactly as before.
#
# The block and the shared helper are lifted verbatim out of agent-cycle.sh,
# the same way test/closing-keyword-wiring.test.sh lifts its own, so the
# assertions are about the shipped code rather than a copy of its logic. Their
# callees are stubbed: `handoff_complete_review`,
# `review_gate_unknown_streak_verdict` and `review_gate_degraded_since`,
# `log_event` and `log_reviewer_handback`.
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
# From the gate's own `gate_default_branch` lookup through the closing `fi` of
# the `review_safe != "true"` handback chain — everything that acts on
# `handoff_complete_review`'s answer, and nothing past it (the unknown-warning
# and flip-bookkeeping code that follows is out of this file's scope).
gate_block="$(awk '
  /^  gate_default_branch=/ { on = 1 }
  on                        { print }
  on && /^  fi$/            { exit }
' "$CYCLE")"

if [[ -z "$gate_block" ]]; then
  echo "FAIL - could not extract the ready-gate block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# TD-PPagop-26081603: the gate block no longer runs the streak-and-escalate
# sequence inline — it calls `review_gate_escalate_unreadable_streak`, shared
# with the Enabler's `complete_handoff` recovery path — so that function is
# lifted too, verbatim, and run for real; only its own two callees
# (`review_gate_unknown_streak_verdict`, `review_gate_degraded_since`) are
# stubbed below, the same way they always were.
streak_helper_fn="$(awk '
  /^review_gate_escalate_unreadable_streak\(\) \{/ { on = 1 }
  on                                                { print }
  on && /^}$/                                       { exit }
' "$CYCLE")"

if [[ -z "$streak_helper_fn" ]]; then
  echo "FAIL - could not extract review_gate_escalate_unreadable_streak from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

URL="https://github.com/Poetic-Poems/poetic-fiddle/pull/198"
# Where the stubbed `handoff_complete_review` records the fourth argument it
# was handed (requirement 31c's round-start bound, agent-ops#533), so the
# assertions below can pin that the call site forwards it.
gate_arg4="$tmp_dir/gate-arg4"

# run_gate_block REVIEW_JSON [STREAK_JSON [ALREADY]]
# Runs the block under the same `set -euo pipefail` agent-cycle.sh runs under,
# with `handoff_complete_review` stubbed to print REVIEW_JSON verbatim,
# `review_gate_unknown_streak_verdict` (TD-PPagop-26081404) stubbed to print
# STREAK_JSON (empty by default — no streak reached), and
# `review_gate_degraded_since` stubbed to report already-escalated exactly
# when ALREADY is non-empty. `node_name`, `log_file` and
# `review_gate_unknown_streak_after` are defined the way agent-cycle.sh's own
# top level defines them; the streak functions are stubbed rather than run for
# real, so their values only need to exist, not to be meaningful — `log_file`
# still has to be a real, readable path, since the block redirects it into the
# (stubbed) functions exactly as it would the real ones. `enabler_assignee` is
# passed through to the stub only to confirm the call site forwards it.
# Prints every `log_event` call as `<kind><TAB><detail-count-or-ok>` (the
# bookkeeping event's own payload is its `ok` flag, so that is what its line
# carries), every `log_reviewer_handback` as
# `handback<TAB><detail><TAB><unblock_condition>`, then `--` if the block ran
# to the end rather than ending the cycle.
# shellcheck disable=SC2016  # The harness's own `$1`/`$2`/`$3`, written out literally for it to expand, not this shell's.
run_gate_block() {
  local review_json="$1" streak_json="${2:-}" already="${3:-}" harness="$tmp_dir/gate-harness.sh"
  local events="$tmp_dir/events" node_log="$tmp_dir/node-log.jsonl" since_rc=1
  [[ -n "$already" ]] && since_rc=0
  : > "$node_log"
  : > "$gate_arg4"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'impl_pr_url=%q\n' "$URL"
    printf '%s\n' 'work_order_json='"'"'{"default_branch":"main"}'"'"''
    printf 'node_name=%q\n' "n1"
    printf 'enabler_assignee=%q\n' "alice"
    printf 'cycle_started_at=%q\n' "2026-08-17T00:00:00Z"
    printf 'log_file=%q\n' "$node_log"
    printf '%s\n' 'review_gate_unknown_streak_after=3'
    printf '%s\n' 'log_event() { printf "%s\t%s\n" "$1" "$(jq -r ".detail // .count // (if has(\"ok\") then (.ok|tostring) else \"\" end)" <<<"$2")" >>'"$(printf '%q' "$events")"'; }'
    printf '%s\n' 'log_reviewer_handback() { printf "handback\t%s\t%s\n" "$1" "${3:-}" >>'"$(printf '%q' "$events")"'; }'
    printf 'handoff_complete_review() { printf %%s "${4:-}" >%q; printf %%s %q; }\n' \
      "$gate_arg4" "$review_json"
    printf 'review_gate_unknown_streak_verdict() { cat >/dev/null; printf %%s %q; }\n' "$streak_json"
    printf 'review_gate_degraded_since() { cat >/dev/null; return %s; }\n' "$since_rc"
    printf '%s\n' "$streak_helper_fn"
    printf '%s\n' "$gate_block"
    printf '%s\n' 'printf -- "--\n" >>'"$(printf '%q' "$events")"''
  } > "$harness"
  : > "$events"
  bash "$harness" >/dev/null 2>&1
  cat "$events"
}

# review_json SAFE GATE_WORD GATE_REASON CHECKS_UNREADABLE CK_WORD CK_REASON
#             [RC_WORD RC_REASON [HANDOFF]]
# Assembles the JSON `handoff_complete_review` would print for the given
# shape, so each test case reads as the verdict it is asserting on. RC_WORD/
# RC_REASON default to empty, the shape the reconciliation gate never having
# run leaves behind.
review_json() {
  jq -nc --argjson safe "$1" --arg gw "$2" --arg gr "$3" --argjson cu "$4" \
    --arg cw "$5" --arg cr "$6" --arg rw "${7:-}" --arg rr "${8:-}" --arg h "${9:-}" \
    '{safe: $safe, gate: {word: $gw, reason: $gr, checks_unreadable: $cu},
      closing_keyword: {word: $cw, reason: $cr}, reconciliation: {word: $rw, reason: $rr},
      handoff: $h, rereview: {state: "", who: ""}, human_reviewer: {state: "", who: ""}}'
}

# The marker is the last line, and the command substitution above eats its
# newline, so both forms have to be accepted — the same shape
# test/closing-keyword-wiring.test.sh's own `reached_end` takes.
reached_end() { [[ "$1" == *$'--\n'* || "$1" == *'--' ]] && echo yes || echo no; }

# --- dirty gate: the pull request's own fault, named as such ------------------
out="$(run_gate_block "$(review_json false dirty "required check(s) not green: CI" false "" "")")"
assert_eq "a dirty gate ends the cycle rather than handing off" "no" "$(reached_end "$out")"
assert_contains "  ... recording the handback naming what the gate found" \
  "required check(s) not green: CI" "$out"
assert_contains "  ... with the unblock_condition a real failure earns" \
  "Get every required check green" "$out"
assert_contains "  ... the bookkeeping recording a successful required-checks read" \
  "review-gate-checks-read	true" "$out"
assert_lacks "  ... and no node-level warning, since nothing implicates the node" \
  "warning" "$out"

# --- the blocking unreadable check list: the node's fault, named as such ------
# TD-PPagop-26081305: the debt was that this arrived as the `dirty` handback
# above, whose unblock_condition names nothing this node can fix.
UNREADABLE="could not read $URL's required checks against its current head commit"
out="$(run_gate_block "$(review_json false unknown "$UNREADABLE" true "" "")")"
assert_eq "an unreadable required-check list refuses the handoff too" "no" "$(reached_end "$out")"
assert_contains "  ... logging a node-level warning naming what could not be read" \
  "warning	" "$out"
assert_contains "  ... the warning carrying the gate's own reason" "$UNREADABLE" "$out"
assert_contains "  ... and a handback pointing at retrying once GitHub can be read" \
  "Retry once a node can read GitHub" "$out"
assert_contains "  ... the bookkeeping recording the failed read" \
  "review-gate-checks-read	false" "$out"
assert_lacks "  ... never the required-checks wording, which names nothing to fix here" \
  "Get every required check green" "$out"

# --- the blocking unreadable check list, streak escalated ---------------------
# TD-PPagop-26081404: once `review_gate_unknown_streak_verdict` reports this
# node's run has crossed the threshold, the per-item node-level `warning`
# above is replaced by one `review-gate-checks-degraded` event naming the
# streak — the handback itself is unchanged.
STREAK='{"node":"n1","gate":"required-checks","count":3,"first_ts":"2026-08-14T10:00:00Z","last_ts":"2026-08-14T10:30:00Z"}'
out="$(run_gate_block "$(review_json false unknown "$UNREADABLE" true "" "")" "$STREAK")"
assert_eq "an escalated streak still refuses the handoff" "no" "$(reached_end "$out")"
assert_contains "  ... logging the escalation event naming the count" \
  "review-gate-checks-degraded	3" "$out"
assert_lacks "  ... instead of the per-item node-level warning" \
  "warning	" "$out"
assert_contains "  ... and still hands back with the same retry unblock_condition" \
  "Retry once a node can read GitHub" "$out"

# --- the same streak, already escalated: the run's one loud event stays one ---
out="$(run_gate_block "$(review_json false unknown "$UNREADABLE" true "" "")" "$STREAK" already)"
assert_eq "an already-escalated streak still refuses the handoff" "no" "$(reached_end "$out")"
assert_lacks "  ... without re-firing the escalation" \
  "review-gate-checks-degraded" "$out"
assert_lacks "  ... and without resurrecting the per-item warning" \
  "warning	" "$out"
assert_contains "  ... the bookkeeping still recording the failed read" \
  "review-gate-checks-read	false" "$out"
assert_contains "  ... and the handback still pointing at retrying" \
  "Retry once a node can read GitHub" "$out"

# --- dirty closing keyword (gate clean): named as such, not as the gate -------
out="$(run_gate_block "$(review_json false clean "" false dirty "no closing keyword for #42")")"
assert_eq "a dirty closing keyword ends the cycle too" "no" "$(reached_end "$out")"
assert_contains "  ... recording the handback naming the missing keyword" \
  "no closing keyword for #42" "$out"
assert_contains "  ... with its own unblock_condition, not the gate's" \
  "Add the missing closing keyword" "$out"
assert_lacks "  ... never the required-checks wording" \
  "Get every required check green" "$out"

# --- dirty reconciliation (both prior gates clean): named as such -------------
# agent-ops#533, PR #512: a human's plain PR comment posted since the pull
# request last left draft, never cited by a pipeline comment since.
out="$(run_gate_block "$(review_json false clean "" false clean "" dirty "human comment(s) posted on https://github.com/Poetic-Poems/poetic-fiddle/pull/198 since it last left draft carry no reconcile citation: comment id(s) 4718691960")")"
assert_eq "a dirty reconciliation gate ends the cycle too" "no" "$(reached_end "$out")"
assert_contains "  ... recording the handback naming the unreconciled comment" \
  "comment id(s) 4718691960" "$out"
assert_contains "  ... with its own unblock_condition, not either other gate's" \
  "Answer every unreconciled human comment" "$out"
assert_lacks "  ... never the required-checks wording" \
  "Get every required check green" "$out"
assert_lacks "  ... never the closing-keyword wording" \
  "Add the missing closing keyword" "$out"

# --- the round-start bound reaches handoff_complete_review --------------------
# Without it the reconciliation gate anchors on the Reviewer's own step-7 `gh
# pr ready` — a flip made inside this very round — and reports `clean` on
# every pull request it exists to refuse (see `_reconciliation_gate_anchor`).
# The bound is a fourth positional argument, so dropping it is silent: the
# gate still runs, still returns a verdict, and simply never fires. Pinned
# here at the call site, where the drop would happen.
assert_eq "the Reviewer's handoff forwards the round-start bound as the fourth argument" \
  "2026-08-17T00:00:00Z" "$(cat "$gate_arg4")"

# --- both gates clean, but the flip itself did not take -----------------------
out="$(run_gate_block "$(review_json false clean "" false clean "")")"
assert_eq "a flip that did not take ends the cycle with its own wording" "no" "$(reached_end "$out")"
assert_contains "  ... naming nothing to fix but the draft state itself" \
  "still a draft and the handoff could not be completed" "$out"

# --- non-blocking unknown (alerts read failed, checks read fine): carries on --
out="$(run_gate_block "$(review_json true clean "" false unknown "could not confirm no new security-severity alert: 403")")"
assert_eq "a non-blocking unknown does not end the cycle" "yes" "$(reached_end "$out")"
assert_lacks "  ... and records no handback" "handback" "$out"
assert_contains "  ... while still recording a successful required-checks read" \
  "review-gate-checks-read	true" "$out"

# --- non-blocking unknown (reconciliation read failed, both other gates clean) -
# The warning this earns is logged past this block's own extraction (see the
# header) — the same reason the alerts-unknown case above asserts nothing
# about its own warning text either — so this only pins that the block itself
# does not end the cycle over it.
out="$(run_gate_block "$(review_json true clean "" false clean "" unknown "could not read the PR's timeline")")"
assert_eq "a non-blocking reconciliation unknown does not end the cycle" "yes" "$(reached_end "$out")"
assert_lacks "  ... and records no handback" "handback" "$out"
assert_contains "  ... while still recording a successful required-checks read" \
  "review-gate-checks-read	true" "$out"

# --- clean: nothing but the streak bookkeeping ---------------------------------
out="$(run_gate_block "$(review_json true clean "" false clean "")" )"
assert_eq "a clean verdict carries on to the rest of the handoff" "yes" "$(reached_end "$out")"
assert_contains "  ... logging only the streak bookkeeping event, a successful read" \
  "review-gate-checks-read	true" "$out"
assert_lacks "  ... no warning" "warning" "$out"
assert_lacks "  ... and no handback" "handback" "$out"

echo
if (( failures )); then
  printf 'review-gate-wiring.test.sh: %d assertion(s) failed\n' "$failures"
  exit 1
fi
echo "review-gate-wiring.test.sh: all assertions passed"
