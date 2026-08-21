#!/usr/bin/env bash
#
# test/enabler-eligibility.test.sh — regression test for the Enabler's
# eligibility rule (`enabler_eligible_items` in lib/cycle-state.sh,
# requirement 35a).
#
# This rule decides when the pipeline spends an Opus pass, and it is wrong in
# two directions with very different costs. Too permissive and a
# permanently-stuck item is re-examined every cycle, or a duplicate issue is
# filed at the human; too strict and the escalation path never fires at all,
# which looks exactly like a pipeline with nothing to escalate. Both failures
# are silent, so every boundary below is asserted on both sides of itself.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/enabler-eligibility.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"

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

log="$tmp_dir/log.jsonl"
now="$(date -u -d '2026-07-25T12:00:00Z' +%s)"
open_none='{"o/r":[]}'
open_52='{"o/r":[52]}'

# eligible [MIN] [RECHECK] [OPEN_ISSUES] [REFINEMENT_MIN] — the rule over
# $log, at a fixed now.
eligible() {
  enabler_eligible_items "$log" "${1:-3}" "${2:-0}" "${3:-$open_none}" "$now" "${4:-}"
}
# reason_for ITEM [MIN] [RECHECK] [OPEN_ISSUES] [REFINEMENT_MIN] — the
# eligibility reason for one item, or "" if ineligible.
reason_for() {
  eligible "${2:-3}" "${3:-0}" "${4:-$open_none}" "${5:-}" \
    | jq -r --arg i "$1" '[.[] | select(.item == $i)] | first | .reason // ""'
}

# Three cycles that ran a Co-Ordinator, all after the block below. The event
# shape is copied from what agent-cycle.sh actually writes (`stage-end` with
# `stage: "coordinator"` and an `exit_code`), because a rule that counts an
# event nobody emits counts nothing, forever, while looking correct.
coord_cycles() {  # <n> [first-hour]
  local n="$1" h="${2:-10}" i
  for (( i = 0; i < n; i++ )); do
    printf '{"ts":"2026-07-22T%02d:05:00Z","cycle":"c%d","event":"stage-end","stage":"coordinator","exit_code":0}\n' \
      "$(( h + i ))" "$(( i + 1 ))"
  done
}

blocked_line='{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"TD1","detail":"needs repo secrets","unblock_condition":"a human adds SENTRY_DSN"}'

# --- Nothing to read at all ---

assert_eq "a missing log yields no eligible items" "[]" \
  "$(enabler_eligible_items "$tmp_dir/nonexistent.jsonl" 3 0 "$open_none" "$now")"

: > "$log"
assert_eq "an empty log yields no eligible items" "[]" "$(eligible)"

# A threshold that is not a number is a misconfiguration, and the fail-safe
# direction is "engage nothing" — an unreadable setting must not authorise
# spend.
printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
assert_eq "an unreadable threshold yields no eligible items" "[]" \
  "$(enabler_eligible_items "$log" "" 0 "$open_none" "$now")"

# --- The threshold boundary (requirement 35a) ---

printf '%s\n' "$blocked_line" > "$log"
coord_cycles 2 >> "$log"
assert_eq "two coordinator cycles is below a threshold of three" "" "$(reason_for TD1)"

printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
assert_eq "three coordinator cycles crosses the threshold" "threshold" "$(reason_for TD1)"
assert_eq "the entry carries the block it was minted from" \
  "implementer|needs repo secrets|a human adds SENTRY_DSN|2026-07-22T09:00:00Z" \
  "$(eligible | jq -r '.[0] | [.stage, .detail, .unblock_condition, .blocked_ts] | join("|")')"
assert_eq "an item with no escalation carries none" "null" \
  "$(eligible | jq -c '.[0].escalation')"
assert_eq "a block that named no pull request carries an empty one" '""' \
  "$(eligible | jq -c '.[0].pr_url')"

# Requirement 32a: a pull request the Reviewer could not hand off is a blocked
# item like any other, and it is the Enabler that decides whether the pipeline
# can finish it or a human must be asked. For a finishing source the item id
# names a register entry rather than the PR, so without this the Enabler would
# have to re-derive from the id the very artefact the block is about.
printf '%s\n' '{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"reviewer","repo":"o/r","item":"TD1","detail":"reviewer verdict blocked: failing: build","pr_url":"https://github.com/o/r/pull/111"}' > "$log"
coord_cycles 3 >> "$log"
assert_eq "a reviewer hand-back is eligible like any other block" "threshold" "$(reason_for TD1)"
assert_eq "and the entry carries the pull request it is about" \
  "https://github.com/o/r/pull/111" "$(eligible | jq -r '.[0].pr_url')"

# --- The refinement threshold (requirement 35a, TD-PPagop-26072604) ---
#
# A block whose `kind` is `needs-refinement` ages on REFINEMENT_MIN instead of
# MIN when the two are configured apart; left unconfigured (REFINEMENT_MIN
# unset or absent), it ages on the exact same MIN as any other block — the
# inherited default that keeps today's behaviour unchanged.

refinement_blocked_line='{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD2","kind":"needs-refinement","detail":"under-specified","unblock_condition":"a human writes acceptance criteria"}'

printf '%s\n' "$refinement_blocked_line" > "$log"
coord_cycles 3 >> "$log"
assert_eq "unconfigured, a refinement block inherits the ordinary threshold at 3 cycles" \
  "threshold" "$(reason_for TD2 3 0 "$open_none")"

printf '%s\n' "$refinement_blocked_line" > "$log"
coord_cycles 2 >> "$log"
assert_eq "unconfigured, a refinement block is still below the inherited threshold at 2 cycles" \
  "" "$(reason_for TD2 3 0 "$open_none")"

# Configured apart: a refinement block now waits for its own, larger threshold,
# while an ordinary block alongside it is unaffected.
printf '%s\n' "$refinement_blocked_line" > "$log"
coord_cycles 3 >> "$log"
assert_eq "a refinement threshold of 5 is not yet crossed at 3 cycles" \
  "" "$(reason_for TD2 3 0 "$open_none" 5)"

printf '%s\n' "$refinement_blocked_line" > "$log"
coord_cycles 5 >> "$log"
assert_eq "a refinement threshold of 5 is crossed at 5 cycles" \
  "threshold" "$(reason_for TD2 3 0 "$open_none" 5)"

cat > "$log" <<EOF
$blocked_line
$refinement_blocked_line
EOF
coord_cycles 3 >> "$log"
assert_eq "an ordinary block still crosses its own threshold of 3 while refinement waits for 5" \
  "threshold" "$(reason_for TD1 3 0 "$open_none" 5)"
assert_eq "and the refinement block alongside it is not yet eligible" \
  "" "$(reason_for TD2 3 0 "$open_none" 5)"
assert_eq "the eligible ordinary entry carries no kind" \
  "" "$(eligible 3 0 "$open_none" 5 | jq -r '.[] | select(.item == "TD1") | .kind')"

# A non-numeric refinement threshold is a misconfiguration, not a licence to
# spend: it falls back to MIN, the same fail-safe direction as an unreadable
# MIN itself.
printf '%s\n' "$refinement_blocked_line" > "$log"
coord_cycles 3 >> "$log"
assert_eq "a garbage refinement threshold falls back to the ordinary one" \
  "threshold" "$(reason_for TD2 3 0 "$open_none" "not-a-number")"

# Only a *successful* Co-Ordinator counts, and only one per cycle: a stage that
# timed out established nothing, another stage's end is not a selection pass,
# and a cycle whose events were replicated twice must not age the item twice.
printf '%s\n' "$blocked_line" > "$log"
coord_cycles 2 >> "$log"
cat >> "$log" <<'EOF'
{"ts":"2026-07-22T13:05:00Z","cycle":"c9","event":"stage-end","stage":"coordinator","exit_code":124}
{"ts":"2026-07-22T14:05:00Z","cycle":"c8","event":"stage-end","stage":"implementer","exit_code":0}
{"ts":"2026-07-22T15:05:00Z","cycle":"c2","event":"stage-end","stage":"coordinator","exit_code":0}
EOF
assert_eq "a timed-out Co-Ordinator, another stage, and a repeated cycle id do not count" \
  "" "$(reason_for TD1)"

# Cycles that ran *before* the block say nothing about it.
printf '%s\n' "$blocked_line" > "$log"
cat >> "$log" <<'EOF'
{"ts":"2026-07-21T10:05:00Z","cycle":"b1","event":"stage-end","stage":"coordinator","exit_code":0}
{"ts":"2026-07-21T11:05:00Z","cycle":"b2","event":"stage-end","stage":"coordinator","exit_code":0}
{"ts":"2026-07-21T12:05:00Z","cycle":"b3","event":"stage-end","stage":"coordinator","exit_code":0}
EOF
assert_eq "coordinator cycles older than the block do not age it" "" "$(reason_for TD1)"

# --- An unblocked or void item is not eligible ---

printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
printf '%s\n' '{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"unblocked","item":"TD1"}' >> "$log"
assert_eq "an item that is no longer blocked is not eligible" "[]" "$(eligible)"

# The live shape this exclusion exists for: an item recorded both blocked and
# void (before the two states were split). It needs no unblocking, and one
# Opus pass per recheck window on an item with no work is the whole cost of
# getting this wrong.
printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
printf '%s\n' '{"ts":"2026-07-22T09:30:00Z","cycle":"c0","event":"item-void","stage":"implementer","repo":"o/r","item":"TD1","detail":"already done on main"}' >> "$log"
assert_eq "a blocked item that is also void is not eligible" "[]" "$(eligible)"

printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
cat >> "$log" <<'EOF'
{"ts":"2026-07-22T09:30:00Z","cycle":"c0","event":"item-void","stage":"implementer","repo":"o/r","item":"TD1","detail":"already done on main"}
{"ts":"2026-07-23T09:00:00Z","cycle":"m","event":"unvoided","item":"TD1"}
EOF
assert_eq "a human unvoiding it makes it eligible again" "threshold" "$(reason_for TD1)"

# --- The examination guard, and re-entry after a re-block ---

printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
printf '%s\n' '{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"still-blocked","detail":"still needs the secret"}' >> "$log"
assert_eq "an examined item is not re-examined by the threshold" "" "$(reason_for TD1)"

# A failed escalation examined nothing: the engagement reached a verdict it
# could not act on, so the item is exactly where it was. Treating the marker as
# progress would retire the item on the strength of a failed `gh issue create`.
printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
printf '%s\n' '{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"escalation-failed","detail":"gh issue create failed"}' >> "$log"
assert_eq "an escalation-failed outcome is not an examination" "threshold" "$(reason_for TD1)"

# A fresh attempt-failed moves B forward, which leaves the old examination
# behind it: the item re-enters through the threshold rather than waiting out a
# recheck window against an examination of an older state.
cat > "$log" <<'EOF'
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"TD1","detail":"first block"}
{"ts":"2026-07-22T09:30:00Z","cycle":"c1","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"unblocked","detail":"the dependency merged"}
{"ts":"2026-07-22T09:31:00Z","cycle":"c1","event":"unblocked","repo":"o/r","item":"TD1","by":"enabler"}
{"ts":"2026-07-23T08:00:00Z","cycle":"c5","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"TD1","detail":"blocked again, differently"}
{"ts":"2026-07-23T10:05:00Z","cycle":"c6","event":"stage-end","stage":"coordinator","exit_code":0}
{"ts":"2026-07-23T11:05:00Z","cycle":"c7","event":"stage-end","stage":"coordinator","exit_code":0}
{"ts":"2026-07-23T12:05:00Z","cycle":"c8","event":"stage-end","stage":"coordinator","exit_code":0}
EOF
assert_eq "a re-blocked item re-enters through the threshold" "threshold" "$(reason_for TD1)"
assert_eq "and it is measured from the *new* block" "2026-07-23T08:00:00Z" \
  "$(eligible | jq -r '.[0].blocked_ts')"

# --- Escalations (requirement 36a's closure loop) ---

escalated_log() {  # writes a block, three cycles, an examination and an escalation
  printf '%s\n' "$blocked_line" > "$log"
  coord_cycles 3 >> "$log"
  cat >> "$log" <<'EOF'
{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"escalate","detail":"needs repo secrets set by a human"}
{"ts":"2026-07-23T09:00:01Z","cycle":"c4","event":"escalated","repo":"o/r","item":"TD1","issue_number":52,"issue_url":"https://github.com/o/r/issues/52","blocked_ts":"2026-07-22T09:00:00Z"}
EOF
}

escalated_log
assert_eq "an item with an open escalation is not eligible" "" \
  "$(reason_for TD1 3 72 "$open_52")"
assert_eq "and the recheck window does not reopen it while the issue is open" "" \
  "$(reason_for TD1 3 1 "$open_52")"

escalated_log
assert_eq "the issue leaving the open digest makes it eligible to verify" "issue-closed" \
  "$(reason_for TD1 3 0 "$open_none")"
assert_eq "the entry names the issue to verify" "52|https://github.com/o/r/issues/52" \
  "$(eligible 3 0 "$open_none" | jq -r '.[0].escalation | [(.issue_number | tostring), .issue_url] | join("|")')"

# Once the closure has been verified, the item is done with: the verification
# examination is newer than the escalation, so nothing wakes it again until it
# is re-blocked or the recheck window elapses.
escalated_log
printf '%s\n' '{"ts":"2026-07-24T09:00:00Z","cycle":"c9","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"still-blocked","detail":"the issue was closed but the secret is still absent"}' >> "$log"
assert_eq "an examination after the closure retires the verification" "" \
  "$(reason_for TD1 3 0 "$open_none")"

# A repo whose source state could not be sampled has no digest, and an
# escalation there might still be open. "Cannot tell" resolves to ineligible:
# the cheap mistake is a delayed engagement, the expensive one is a duplicate
# issue in the human's inbox.
escalated_log
assert_eq "a missing repo digest leaves the escalation possibly open" "" \
  "$(reason_for TD1 3 0 '{"o/other":[]}')"
# An item that was never escalated needs no digest to be judged.
printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
assert_eq "an item with no escalation needs no digest" "threshold" \
  "$(reason_for TD1 3 0 '{"o/other":[]}')"

# An escalated event with no usable issue number cannot be checked against the
# digest at all; it must not read as "closed" and hand the item a free
# verification pass.
printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
cat >> "$log" <<'EOF'
{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"escalate","detail":"needs a human"}
{"ts":"2026-07-23T09:00:01Z","cycle":"c4","event":"escalated","repo":"o/r","item":"TD1","issue_url":"https://github.com/o/r/issues/52"}
EOF
assert_eq "an escalated event with no issue number grants no verification pass" "" \
  "$(reason_for TD1 3 0 "$open_none")"

# --- The recheck window (requirement 35a's only bound on a stuck item) ---

recheck_log() {  # an examination at a fixed distance before `now`
  printf '%s\n' "$blocked_line" > "$log"
  coord_cycles 3 >> "$log"
  printf '{"ts":"%s","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"still-blocked","detail":"waiting"}\n' \
    "$(date -u -d "@$(( now - $1 * 3600 ))" +%Y-%m-%dT%H:%M:%SZ)" >> "$log"
}

recheck_log 71
assert_eq "an examination 71 hours old is inside a 72-hour window" "" "$(reason_for TD1 3 72)"
recheck_log 72
assert_eq "an examination 72 hours old is re-checked" "recheck" "$(reason_for TD1 3 72)"
# The same log, read twice: an examination well past any window is re-checked
# when the valve is on and never re-checked when it is off. `0` is therefore a
# decision to leave a stuck item unexamined for as long as it stays blocked.
recheck_log 74
assert_eq "an examination well past the window is re-checked" "recheck" "$(reason_for TD1 3 72)"
assert_eq "a recheck window of 0 disables the valve entirely" "" "$(reason_for TD1 3 0)"

# An examination whose timestamp cannot be read cannot be aged, and an unaged
# recheck is an unbounded one — it would fire every cycle.
printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
printf '%s\n' '{"ts":"whenever","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","outcome":"still-blocked"}' >> "$log"
assert_eq "an examination with an unparseable ts is not re-checked" "" "$(reason_for TD1 3 72)"

# --- Keying, and tolerance of a torn log ---

# An item id is only unique within its repo (requirement 34): blocking TD1 in
# one repo must not make the other repo's TD1 eligible, or the Enabler would
# escalate the wrong repository's work to the human.
cat > "$log" <<'EOF'
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"TD1","detail":"a"}
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"implementer","repo":"o/other","item":"TD1","detail":"b"}
{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","outcome":"still-blocked"}
EOF
coord_cycles 3 >> "$log"
assert_eq "an examination in one repo does not retire the other repo's same-named item" \
  "o/other" "$(eligible 3 0 '{"o/r":[],"o/other":[]}' | jq -r '.[].repo')"

# One truncated append must not strand every eligible item: the log is written
# by an appending process and read by this one.
printf '%s\n' "$blocked_line" > "$log"
coord_cycles 3 >> "$log"
printf '%s' '{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"cycle-e' >> "$log"
assert_eq "a malformed trailing line does not lose an eligible item" "threshold" \
  "$(reason_for TD1)"

# --- The argv cap (requirement 4g) ---
# The open-issues map carries one number per open issue per repo, so it grows
# with the fleet's issue count rather than with anything this rule bounds.
# Delivered via `--argjson` it would, past MAX_ARG_STRLEN (131072 bytes, the
# kernel's per-entry argv cap), make the whole rule's jq fail into its
# `|| true` and print `[]` — every blocked item read as ineligible, which is
# the direction that silently retires the Enabler rather than one that shows up
# as an error anywhere. Requirement 4g puts the map on stdin; this pins it,
# with a fixture the first assertion proves is genuinely past the cap.
escalated_log
big_open="$(jq -nc --argjson keep "$open_none" \
  '$keep + ([range(9000) | {("o/filler-" + tostring): [1, 2, 3]}] | add)')"
assert_eq "the oversized open-issues fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_open" | wc -c) > 131072 ))"
assert_eq "an open-issues map past the argv cap still reads the escalation as closed" \
  "issue-closed" "$(reason_for TD1 3 0 "$big_open")"

# The call-site shape under `set -e`: the Script computes this inside a cycle
# that must survive whatever the log contains, and calls it from the exit trap's
# path. An unreadable log is a normal outcome, not a reason to die.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/cycle-state.sh"
  e="$(enabler_eligible_items "/nonexistent/log.jsonl" 3 72 '{}')"
  f="$(enabler_eligible_items "$log" "not-a-number" 72 'garbage')"
  printf '%s%s' "$e" "$f" >/dev/null
  exit 0
) >/dev/null 2>&1
assert_eq "neither an unreadable log nor a garbage argument aborts the caller under set -e" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
