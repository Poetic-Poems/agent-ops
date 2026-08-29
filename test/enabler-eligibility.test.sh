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
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# TD-PPagop-26082819: enabler_eligible_items now checks a phantom
# item-refined event's comment_url shape against REFINEMENT_COMMENT_URL_RE
# (lib/refinement.sh) before trusting it — sourced here so that check runs
# against the real pattern rather than this file's own fallback copy.
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"

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

log="$tmp_dir/log.jsonl"
now="$(date -u -d '2026-07-25T12:00:00Z' +%s)"
open_none='{"o/r":[]}'
open_52='{"o/r":[52]}'

# log_event is stubbed, not sourced from agent-cycle.sh: enabler_eligible_items
# (TD-PPagop-26082819) calls it, guarded by `command -v`, to warn once a
# phantom item-refined event is found — captured here the same way `gh` is
# stubbed in test/needs-refinement.test.sh, so that warning is observable
# without lifting agent-cycle.sh's own logging machinery into this harness.
LOG_EVENT_CALLS_FILE="$tmp_dir/log_event_calls"
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$LOG_EVENT_CALLS_FILE"; }
log_event_calls() { [[ -f "$LOG_EVENT_CALLS_FILE" ]] && wc -l < "$LOG_EVENT_CALLS_FILE" | tr -d ' ' || printf '0'; }
log_event_last_fields() { [[ -f "$LOG_EVENT_CALLS_FILE" ]] && tail -n1 "$LOG_EVENT_CALLS_FILE" | cut -f2- || printf ''; }
reset_log_event_calls() { rm -f "$LOG_EVENT_CALLS_FILE"; }

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

# coord_cycles_after TS N — like coord_cycles above, but its N stage-end
# events start one hour after TS instead of the fixed 2026-07-22 date: the
# TD-PPagop-26082819 fixtures below are dated in August, and a block's own
# coord_cycles count is only ever the stage-end events *after its own ts*
# (ENABLER_ELIGIBLE_JQ's $coord_cycles), so a fixed-July helper would count
# zero for them regardless of N.
coord_cycles_after() {
  local ts="$1" n="$2" i epoch
  epoch="$(date -u -d "$ts" +%s)"
  for (( i = 1; i <= n; i++ )); do
    printf '{"ts":"%s","cycle":"ca%d","event":"stage-end","stage":"coordinator","exit_code":0}\n' \
      "$(date -u -d "@$(( epoch + i * 3600 ))" +%Y-%m-%dT%H:%M:%SZ)" "$i"
  done
}

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

# --- The #706 race: a needs-refinement re-flag after the close (TD-PPagop-26082901) ---
#
# A fresh block landing *after* the escalation was raised — observed in every
# case as a Co-Ordinator needs-refinement re-flag — used to move B past the
# escalation and strand the human's close: it satisfied none of `threshold`
# (the thrash guard refuses a second refinement without a human touch),
# `issue-closed` (keyed on the raise time) or `recheck` (nothing has examined
# it yet to grow stale). The exemption is keyed on the block the escalation was
# raised for instead: a re-flag disputing the same, unchanged specification is
# answered by the same close.

reflag_after_close_log() {  # escalation raised, closed, *then* re-blocked needs-refinement
  cat > "$log" <<'EOF'
{"ts":"2026-07-20T08:00:00Z","cycle":"c-1","event":"item-refined","repo":"o/r","item":"TD1","spec":"original spec"}
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"TD1","detail":"needs repo secrets","unblock_condition":"a human adds SENTRY_DSN"}
EOF
  coord_cycles 3 >> "$log"
  cat >> "$log" <<'EOF'
{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"escalate","detail":"needs a human decision"}
{"ts":"2026-07-23T09:00:01Z","cycle":"c4","event":"escalated","repo":"o/r","item":"TD1","issue_number":52,"issue_url":"https://github.com/o/r/issues/52","blocked_ts":"2026-07-22T09:00:00Z"}
{"ts":"2026-07-23T12:18:06Z","cycle":"c5","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD1","kind":"needs-refinement","detail":"re-flagged after the close","unblock_condition":"a human clarifies again"}
EOF
}

reflag_after_close_log
assert_eq "a needs-refinement re-flag raised after an already-closed escalation is still issue-closed" \
  "issue-closed" "$(reason_for TD1 3 0 "$open_none")"
assert_eq "the entry still carries the needs-refinement kind and the prior refinement" \
  "needs-refinement|2026-07-20T08:00:00Z" \
  "$(eligible 3 0 "$open_none" | jq -r '.[0] | [.kind, .refined_before.ts] | join("|")')"

# The negative the fix's own scope excludes: an examination that already
# consumed the close — whether before or after the re-flag — must not be
# re-granted through the needs-refinement exemption. That close was already
# looked at, so nothing here is "an escalation nobody has acted on since".
reflag_after_close_log
printf '%s\n' '{"ts":"2026-07-23T10:00:00Z","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"still-blocked","detail":"already looked at the closed issue"}' >> "$log"
assert_eq "an examination after the close, even before the re-flag, is not issue-closed" \
  "" "$(reason_for TD1 3 0 "$open_none")"

# An ordinary (non-refinement) re-flag after the close gets no such exemption:
# only a needs-refinement re-flag disputes "the same specification" the
# escalation was about.
cat > "$log" <<'EOF'
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"TD1","detail":"needs repo secrets","unblock_condition":"a human adds SENTRY_DSN"}
EOF
coord_cycles 3 >> "$log"
cat >> "$log" <<'EOF'
{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"escalate","detail":"needs a human decision"}
{"ts":"2026-07-23T09:00:01Z","cycle":"c4","event":"escalated","repo":"o/r","item":"TD1","issue_number":52,"issue_url":"https://github.com/o/r/issues/52","blocked_ts":"2026-07-22T09:00:00Z"}
{"ts":"2026-07-23T12:18:06Z","cycle":"c5","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"TD1","detail":"blocked again, differently"}
EOF
assert_eq "an ordinary re-flag after the close is not exempted, and re-enters through the threshold" \
  "" "$(reason_for TD1 3 0 "$open_none")"

# Without a prior refinement at all, `refined_before` is null and the
# exemption cannot fire — there is no "same specification" to point to.
cat > "$log" <<'EOF'
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD1","kind":"needs-refinement","detail":"under-specified","unblock_condition":"a human writes acceptance criteria"}
EOF
coord_cycles 3 >> "$log"
cat >> "$log" <<'EOF'
{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"enabler-examined","repo":"o/r","item":"TD1","blocked_ts":"2026-07-22T09:00:00Z","outcome":"escalate","detail":"needs a human decision"}
{"ts":"2026-07-23T09:00:01Z","cycle":"c4","event":"escalated","repo":"o/r","item":"TD1","issue_number":52,"issue_url":"https://github.com/o/r/issues/52","blocked_ts":"2026-07-22T09:00:00Z"}
{"ts":"2026-07-23T12:18:06Z","cycle":"c5","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD1","kind":"needs-refinement","detail":"re-flagged after the close","unblock_condition":"a human clarifies again"}
EOF
assert_eq "a needs-refinement re-flag with no prior item-refined event gets no exemption" \
  "" "$(reason_for TD1 3 0 "$open_none")"

# --- TD-PPagop-26082819: a phantom item-refined event sets no refined_before ---
# #818's and #874's own item-refined events were both logged with a bare
# issue URL in comment_url — no #issuecomment- anchor, so it could never name
# a real comment — because the recording seam that now rejects that shape
# (refinement_record_fields, lib/refinement.sh) had not been fixed yet. Those
# events are still sitting on the fleet log; this is the reading seam that
# must not trust them, so the thrash guard they wrongly armed releases once
# the recording fix ships, with no history to edit.

reset_log_event_calls
cat > "$log" <<'EOF'
{"ts":"2026-08-26T08:45:09Z","cycle":"c-phantom","event":"item-refined","repo":"o/r","item":"TD1","by":"refiner","comment_url":"https://github.com/o/r/issues/818"}
{"ts":"2026-08-26T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD1","kind":"needs-refinement","detail":"under-specified","unblock_condition":"a human writes acceptance criteria"}
EOF
coord_cycles_after "2026-08-26T09:00:00Z" 3 >> "$log"
assert_eq "a block behind only a phantom item-refined event has no refined_before" \
  "null" "$(eligible 3 0 "$open_none" | jq -r '.[0].refined_before // "null"')"
assert_eq "…so the thrash guard's own exemption question (39a-style re-offer) never fires from it" \
  "threshold" "$(reason_for TD1 3 0 "$open_none")"
# Two calls above (eligible, then reason_for) each independently re-derive
# and warn — enabler_eligible_items runs once per cycle in production
# (compute_enabler_eligible_set, lib/eligibility.sh), so a real cycle logs
# this once; this harness just proves the warning fires at all and names the
# right thing, not the exact call count its own two lookups happen to cost.
if [[ "$(log_event_calls)" -ge 1 ]]; then
  printf 'ok   - %s\n' "…and the phantom is named in a warning"
else
  printf 'FAIL - %s\n     expected: >= 1\n     actual:   %s\n' "…and the phantom is named in a warning" "$(log_event_calls)"
  failures=$(( failures + 1 ))
fi
assert_contains "…naming its timestamp" "2026-08-26T08:45:09Z" "$(log_event_last_fields)"
assert_contains "…and its repo+item" '"item":"TD1"' "$(log_event_last_fields)"

# A later, *valid* item-refined event must still win over an earlier phantom
# — the derivation does not stop at the first phantom it meets, it keeps
# looking for the latest one that actually passes the shape check.
reset_log_event_calls
cat > "$log" <<'EOF'
{"ts":"2026-08-26T08:45:09Z","cycle":"c-phantom","event":"item-refined","repo":"o/r","item":"TD1","by":"refiner","comment_url":"https://github.com/o/r/issues/818"}
{"ts":"2026-08-27T10:00:00Z","cycle":"c-real","event":"item-refined","repo":"o/r","item":"TD1","by":"refiner","comment_url":"https://github.com/o/r/issues/818#issuecomment-99"}
{"ts":"2026-08-27T10:05:00Z","cycle":"c1","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD1","kind":"needs-refinement","detail":"still not enough","unblock_condition":"a human clarifies"}
EOF
coord_cycles_after "2026-08-27T10:05:00Z" 3 >> "$log"
assert_eq "a genuine, later refinement is still found behind an earlier phantom" \
  "2026-08-27T10:00:00Z" "$(eligible 3 0 "$open_none" | jq -r '.[0].refined_before.ts // "null"')"

# The reverse: a genuine refinement followed by a *later* phantom must still
# be found — the phantom does not shadow the real one just because it sorts
# after it by timestamp.
reset_log_event_calls
cat > "$log" <<'EOF'
{"ts":"2026-08-26T08:00:00Z","cycle":"c-real","event":"item-refined","repo":"o/r","item":"TD1","by":"refiner","comment_url":"https://github.com/o/r/issues/818#issuecomment-99"}
{"ts":"2026-08-26T08:45:09Z","cycle":"c-phantom","event":"item-refined","repo":"o/r","item":"TD1","by":"refiner","comment_url":"https://github.com/o/r/issues/818"}
{"ts":"2026-08-26T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD1","kind":"needs-refinement","detail":"under-specified","unblock_condition":"a human writes acceptance criteria"}
EOF
coord_cycles_after "2026-08-26T09:00:00Z" 3 >> "$log"
assert_eq "a later phantom does not shadow an earlier, genuine refinement" \
  "2026-08-26T08:00:00Z" "$(eligible 3 0 "$open_none" | jq -r '.[0].refined_before.ts // "null"')"

# A spec-carrying (non-issue) item-refined event has no comment_url at all —
# the phantom check must never touch it. Ordinary tech-debt/plan/review
# refinements keep working exactly as before.
reset_log_event_calls
cat > "$log" <<'EOF'
{"ts":"2026-07-20T08:00:00Z","cycle":"c-1","event":"item-refined","repo":"o/r","item":"TD1","spec":"original spec"}
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD1","kind":"needs-refinement","detail":"under-specified","unblock_condition":"a human writes acceptance criteria"}
EOF
coord_cycles 3 >> "$log"
assert_eq "a spec-carrying item-refined event is never treated as phantom" \
  "2026-07-20T08:00:00Z" "$(eligible 3 0 "$open_none" | jq -r '.[0].refined_before.ts // "null"')"
assert_eq "…and earns no phantom warning" "0" "$(log_event_calls)"

# One item's phantom must not suppress another item's genuine refinement.
# `log_event` stamps whole-second UTC timestamps and this rule runs over the
# fleet-wide *union* log, so two `item-refined` events sharing a second across
# different items is ordinary traffic, not a contrivance — which is why the
# phantom set is matched on the whole {repo, item, ts} triple and never on
# `ts` alone. Keyed on `ts` alone, TD1's real refinement below derives to
# null: the thrash guard silently disarms for an item that genuinely was
# refined, and the spec/comment_url lib/enabler.sh's adjudication path reads
# back out of `refined_before` is discarded with it.
reset_log_event_calls
cat > "$log" <<'EOF'
{"ts":"2026-08-26T08:45:09Z","cycle":"cA","event":"item-refined","repo":"o/r","item":"TD1","by":"refiner","comment_url":"https://github.com/o/r/issues/818#issuecomment-99"}
{"ts":"2026-08-26T08:45:09Z","cycle":"cB","event":"item-refined","repo":"o/r","item":"TD2","by":"refiner","comment_url":"https://github.com/o/r/issues/874"}
{"ts":"2026-08-26T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD1","kind":"needs-refinement","detail":"under-specified","unblock_condition":"a human clarifies"}
{"ts":"2026-08-26T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD2","kind":"needs-refinement","detail":"under-specified","unblock_condition":"a human clarifies"}
EOF
coord_cycles_after "2026-08-26T09:00:00Z" 3 >> "$log"
assert_eq "a phantom does not suppress another item's refinement sharing its timestamp" \
  "2026-08-26T08:45:09Z" \
  "$(eligible 3 0 "$open_none" | jq -r '.[] | select(.item == "TD1") | .refined_before.ts // "null"')"
assert_eq "…and the same-second phantom is still skipped for the item that owns it" \
  "null" \
  "$(eligible 3 0 "$open_none" | jq -r '.[] | select(.item == "TD2") | .refined_before.ts // "null"')"

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
