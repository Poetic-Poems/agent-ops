#!/usr/bin/env bash
#
# test/escalation-autonomy.test.sh — regression test for
# lib/escalation-autonomy.sh (agent-ops#627).
#
# Narrower than test/merge-autonomy.test.sh's own coverage: there are two
# functions here and no kill switch to test alongside them, per this file's
# own header on why one is pointless here.
#
#   - escalation_autonomy_configured_level — the same
#     top-level-default/per-repo-override precedence stage_timeouts and
#     merge_autonomy_configured_level both use.
#   - escalation_autonomy_adjudicated_before — requirement 36b's "bounded, not
#     a loop" guard, read off the log the same way `crash_loop_escalated_since`
#     reads its own already-escalated fact. What makes it worth a test of its
#     own is that failing *open* here is what loops: an item whose one pass has
#     been spent must be found spent, or the adjudication that already answered
#     this disagreement runs again, answers it the same way, and no human is
#     ever paged.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/escalation-autonomy.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/escalation-autonomy.sh
. "$SCRIPT_DIR/lib/escalation-autonomy.sh"

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

# --- escalation_autonomy_configured_level ---

no_key_cfg='{}'
assert_eq "no escalation_autonomy key anywhere defaults to always-escalate" "always-escalate" \
  "$(escalation_autonomy_configured_level "$no_key_cfg" "acme/widgets")"

top_level_cfg='{"escalation_autonomy": "adjudicate-first"}'
assert_eq "the top-level key governs a repo with no override" "adjudicate-first" \
  "$(escalation_autonomy_configured_level "$top_level_cfg" "acme/widgets")"

override_cfg='{"escalation_autonomy": "adjudicate-first", "repos": [
  {"slug": "acme/widgets", "escalation_autonomy": "always-escalate"},
  {"slug": "acme/gizmos"}
]}'
assert_eq "a repo's own override wins over the top-level key" "always-escalate" \
  "$(escalation_autonomy_configured_level "$override_cfg" "acme/widgets")"
assert_eq "a repo with no override of its own falls through to the top-level key" "adjudicate-first" \
  "$(escalation_autonomy_configured_level "$override_cfg" "acme/gizmos")"
assert_eq "a repo absent from repos[] entirely still falls through to the top-level key" "adjudicate-first" \
  "$(escalation_autonomy_configured_level "$override_cfg" "acme/unlisted")"

null_top_level_cfg='{"escalation_autonomy": null}'
assert_eq "an explicit null top-level key reads as always-escalate, not the literal null" "always-escalate" \
  "$(escalation_autonomy_configured_level "$null_top_level_cfg" "acme/widgets")"

null_override_cfg='{"escalation_autonomy": "adjudicate-first", "repos": [
  {"slug": "acme/widgets", "escalation_autonomy": null}
]}'
assert_eq "an explicit null repo override falls through to the top-level key, not the literal null" \
  "adjudicate-first" "$(escalation_autonomy_configured_level "$null_override_cfg" "acme/widgets")"

assert_eq "malformed config falls back to always-escalate" "always-escalate" \
  "$(escalation_autonomy_configured_level 'not json' "acme/widgets")"

# --- escalation_autonomy_adjudicated_before ---

# A file per fixture, never a pipe: `failures` is incremented by assert_eq in
# this shell, and a `... | { assert_pass ... }` would run it in a subshell
# whose count dies with it — a failing assertion that reports itself and is
# then forgotten is worse than no assertion at all.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

adj_evt() {  # adj_evt REPO ITEM -> one enabler-adjudication log line
  jq -nc --arg r "$1" --arg i "$2" \
    '{ts: "2026-08-02T00:00:00Z", event: "enabler-adjudication", repo: $r, item: $i,
      verdict: "adequate", evidence: "…", adjudication: true}'
}

assert_spent() {  # assert_spent DESC EXPECTED_RC REPO ITEM LOG_FILE
  local desc="$1" expected="$2" repo="$3" item="$4" log="$5" rc=0
  escalation_autonomy_adjudicated_before "$repo" "$item" < "$log" || rc=$?
  assert_eq "$desc" "$expected" "$rc"
}

: > "$tmp_dir/empty.jsonl"
assert_spent "an empty log has spent no pass" 1 acme/widgets TD001 "$tmp_dir/empty.jsonl"

adj_evt acme/widgets TD001 > "$tmp_dir/one.jsonl"
assert_spent "an adjudication for this very item is found" 0 acme/widgets TD001 "$tmp_dir/one.jsonl"
assert_spent "...but not credited to a different item" 1 acme/widgets TD002 "$tmp_dir/one.jsonl"

adj_evt acme/gizmos TD001 > "$tmp_dir/other-repo.jsonl"
assert_spent "...nor to the same id in a different repository" 1 acme/widgets TD001 \
  "$tmp_dir/other-repo.jsonl"

# `same_item`'s own tolerance (lib/cycle-state.sh): an event with no repo
# field still counts against its item, so a record written without one cannot
# silently hand out a second pass.
jq -nc '{ts: "2026-08-02T00:00:00Z", event: "enabler-adjudication", item: "TD001", verdict: "adequate"}' \
  > "$tmp_dir/no-repo.jsonl"
assert_spent "a repo-less adjudication event still counts against its item" 0 acme/widgets TD001 \
  "$tmp_dir/no-repo.jsonl"

# Every other event for the same item is irrelevant — in particular
# `item-refined` and `unblocked`, which the adequate path writes beside the
# adjudication and which a looser "has this item been through here" read
# would confuse with it.
{ jq -nc '{ts: "2026-08-02T00:00:00Z", event: "item-refined", repo: "acme/widgets", item: "TD001"}'
  jq -nc '{ts: "2026-08-02T00:00:01Z", event: "unblocked", repo: "acme/widgets", item: "TD001"}'
  jq -nc '{ts: "2026-08-02T00:00:02Z", event: "escalated", repo: "acme/widgets", item: "TD001"}'
} > "$tmp_dir/neighbours.jsonl"
assert_spent "no neighbouring event is mistaken for an adjudication" 1 acme/widgets TD001 \
  "$tmp_dir/neighbours.jsonl"

# The union log is concatenated from every peer's own file, so a torn line is
# a real shape. It must not read as "no pass spent" when the pass is right
# there — this guard failing open is what loops.
{ printf 'not json\n'; adj_evt acme/widgets TD001; printf '{"event": "trunc\n'; } \
  > "$tmp_dir/torn.jsonl"
assert_spent "unparseable lines are skipped rather than hiding a spent pass" 0 acme/widgets TD001 \
  "$tmp_dir/torn.jsonl"

# agent-ops#936: a decide-tactical pass's own enabler-adjudication event must
# never be mistaken for an adjudicate-first one — the two rungs' bounds must
# stay independent, or a repository that moved between them would have one
# rung's bound spent by the other's history.
decide_evt() {  # decide_evt REPO ITEM -> one decide-tactical-tagged enabler-adjudication log line
  jq -nc --arg r "$1" --arg i "$2" \
    '{ts: "2026-08-02T00:00:00Z", event: "enabler-adjudication", repo: $r, item: $i,
      verdict: "settle", evidence: "…", adjudication: true, pass: "decide-tactical", reason_key: "abc123"}'
}
decide_evt acme/widgets TD001 > "$tmp_dir/decide-only.jsonl"
assert_spent "a decide-tactical pass's own event does not spend adjudicate-first's bound" 1 \
  acme/widgets TD001 "$tmp_dir/decide-only.jsonl"

# --- escalation_autonomy_decide_reason_key ---

same_a="$(jq -nc '{detail: "Should the disk gate read state_dir too?", unblock_condition: "a decision on scope"}')"
same_b="$(jq -nc '{detail: "  should the disk gate read state_dir too?  ", unblock_condition: "A Decision On Scope"}')"
different="$(jq -nc '{detail: "a different question entirely", unblock_condition: "x"}')"

key_a="$(escalation_autonomy_decide_reason_key "$same_a")"
key_b="$(escalation_autonomy_decide_reason_key "$same_b")"
key_c="$(escalation_autonomy_decide_reason_key "$different")"
assert_eq "reason keys are stable and case/whitespace-insensitive" "$key_a" "$key_b"
if [[ "$key_a" == "$key_c" ]]; then
  printf 'FAIL - %s\n     expected: different keys for different reasons\n     actual:   both %s\n' \
    "reason keys distinguish genuinely different reasons" "$key_a"
  failures=$(( failures + 1 ))
else
  printf 'ok   - %s\n' "reason keys distinguish genuinely different reasons"
fi
assert_eq "a reason key is 16 hex characters" "16" "${#key_a}"

# --- escalation_autonomy_decide_reason_seen / escalation_autonomy_decide_pass_count ---

assert_reason_seen() {  # assert_reason_seen DESC EXPECTED_RC REPO ITEM KEY LOG_FILE
  local desc="$1" expected="$2" repo="$3" item="$4" key="$5" log="$6" rc=0
  escalation_autonomy_decide_reason_seen "$repo" "$item" "$key" < "$log" || rc=$?
  assert_eq "$desc" "$expected" "$rc"
}

: > "$tmp_dir/empty.jsonl"
assert_reason_seen "an empty log has seen no reason" 1 acme/widgets TD001 "$key_a" "$tmp_dir/empty.jsonl"

decide_full_evt() {  # decide_full_evt REPO ITEM KEY -> a decide-tactical event tagged with KEY
  jq -nc --arg r "$1" --arg i "$2" --arg k "$3" \
    '{ts: "2026-08-02T00:00:00Z", event: "enabler-adjudication", repo: $r, item: $i,
      verdict: "settle", evidence: "…", adjudication: true, pass: "decide-tactical", reason_key: $k}'
}
decide_full_evt acme/widgets TD001 "$key_a" > "$tmp_dir/one-decide.jsonl"
assert_reason_seen "the same reason key is found" 0 acme/widgets TD001 "$key_a" "$tmp_dir/one-decide.jsonl"
assert_reason_seen "...but not credited to a different reason on the same item" 1 \
  acme/widgets TD001 "$key_c" "$tmp_dir/one-decide.jsonl"
assert_reason_seen "...nor to the same key on a different item" 1 \
  acme/widgets TD002 "$key_a" "$tmp_dir/one-decide.jsonl"
assert_eq "an adjudicate-first event (no pass tag) does not count toward decide-tactical's history" \
  "0" "$(escalation_autonomy_decide_pass_count acme/widgets TD001 < "$tmp_dir/one.jsonl")"
assert_eq "one decide-tactical event is counted" "1" \
  "$(escalation_autonomy_decide_pass_count acme/widgets TD001 < "$tmp_dir/one-decide.jsonl")"

decision_taken_evt="$(jq -nc --arg r "acme/widgets" --arg i "TD001" --arg k "$key_a" \
  '{ts: "2026-08-02T00:05:00Z", event: "decision-taken", repo: $r, item: $i,
    decision: "use option B", rationale: "…", reason_key: $k}')"
printf '%s\n' "$decision_taken_evt" > "$tmp_dir/decision-only.jsonl"
assert_reason_seen "a decision-taken event alone (no enabler-adjudication) still counts as seen" 0 \
  acme/widgets TD001 "$key_a" "$tmp_dir/decision-only.jsonl"
assert_eq "...but a decision-taken event alone is not a spent decide-tactical pass for the cap" "0" \
  "$(escalation_autonomy_decide_pass_count acme/widgets TD001 < "$tmp_dir/decision-only.jsonl")"

{ decide_full_evt acme/widgets TD001 "key1"
  decide_full_evt acme/widgets TD001 "key2"
  decide_full_evt acme/widgets TD001 "key3"
} > "$tmp_dir/three-decides.jsonl"
assert_eq "three decide-tactical passes over three different reasons all count toward the cap" "3" \
  "$(escalation_autonomy_decide_pass_count acme/widgets TD001 < "$tmp_dir/three-decides.jsonl")"
assert_reason_seen "a fourth, genuinely new reason has not itself been seen" 1 \
  acme/widgets TD001 "key4" "$tmp_dir/three-decides.jsonl"

echo
if (( failures == 0 )); then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
