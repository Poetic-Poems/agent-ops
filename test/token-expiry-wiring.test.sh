#!/usr/bin/env bash
#
# test/token-expiry-wiring.test.sh — regression test for agent-cycle.sh's
# token-expiry escalation block (agent-ops#694): not whether
# `token_expiry_parse`/`token_expiry_escalated_for` compute correctly in
# isolation (test/token-expiry.test.sh covers that) but whether the cycle
# actually acts on `.doctor-status.json`'s `token_expiry` field — escalating
# once, and only once per expiry timestamp, without ever standing the cycle
# down for it.
#
# The three things worth asserting, mirroring
# test/auth-failure-wiring.test.sh's own structure for the sibling check
# (requirement 2.0b):
#
#   - A token under the warning threshold escalates exactly once, through
#     `create_escalation_issue` in `crash_loop_repo` — not `escalation_autonomy`
#     — and the cycle always falls through afterwards (unlike 2.0b, this never
#     stands the cycle down: an unexpired token blocks nothing).
#   - A second cycle, same `expires_at`, escalates nothing further — the
#     `token-expiry-escalated` dedup, not merely "is there an open issue".
#   - A token at or above the threshold, or no recorded token_expiry at all,
#     escalates nothing.
#
# The block is lifted verbatim out of agent-cycle.sh, the way
# test/auth-failure-wiring.test.sh lifts its own, so the assertions are about
# the shipped code rather than a copy of its logic. `token_expiry_escalated_for`
# itself is sourced for real (lib/token-expiry.sh) rather than stubbed, so the
# dedup assertions exercise the real dedup, not a test double's guess at it.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
# ./test/token-expiry-wiring.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/agent-cycle.sh"
# shellcheck source=lib/token-expiry.sh
. "$SCRIPT_DIR/lib/token-expiry.sh"

failures=0
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

te_block="$(extract_block '^# 1c\. Token-expiry escalation' '^# --- 2\. Stand-down checks ---' "$AGENT_CYCLE")"
if [[ -z "$te_block" ]]; then
  echo "FAIL - could not extract the token-expiry escalation block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if ! grep -q 'token_expiry_escalated_for' <<<"$te_block"; then
  echo "FAIL - extracted block does not call token_expiry_escalated_for — the anchors matched the wrong text" >&2
  exit 1
fi

# run_block STATE_DIR UNION_LOG ESCALATION_FILE EVENT_FILE — writes every
# create_escalation_issue call (argv, one per line, plus its body file's
# content) to ESCALATION_FILE and every log_event call to EVENT_FILE, and
# prints the block's own exit status followed by "FELL THROUGH" (always
# expected here — this block never stands the cycle down).
run_block() {
  # shellcheck disable=SC2034  # state_dir/union_log are read by $te_block via eval in the subshell below, invisible to a static reader
  local state_dir="$1" union_log="$2" escalation_file="$3" event_file="$4"
  : > "$escalation_file"
  : > "$event_file"
  (
    set -euo pipefail
    # shellcheck disable=SC2034  # consumed by $te_block below, invisible to a static reader
    DRY_RUN=0
    # shellcheck disable=SC2034
    crash_loop_repo="acme/agent-ops"
    # shellcheck disable=SC2034
    enabler_assignee="ops-bot"
    # shellcheck disable=SC2034
    enabler_escalation_label="autonomous-agent-escalation"
    # shellcheck disable=SC2034
    cycle_dir="$tmp_dir"
    # shellcheck disable=SC2034
    node_name="test-node"
    # state_dir and union_log are already bound by run_block's own `local`
    # parameters above, and this subshell inherits them — nothing to
    # reassign.

    # shellcheck disable=SC2317  # called from $te_block via eval, invisible to a static reader
    create_escalation_issue() {
      { printf 'repo=%s\nitem=%s\nlabel=%s\ntitle=%s\n' "$1" "$2" "$3" "$4"
        echo "---body---"
        cat "$5" 2>/dev/null
        echo "---end---"
      } >> "$ESCALATION_FILE"
      printf '99\thttps://github.com/acme/agent-ops/issues/99'
    }
    export ESCALATION_FILE="$escalation_file"

    # shellcheck disable=SC2317  # called from $te_block via eval, invisible to a static reader
    log_event() {
      printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$EVENT_FILE"
    }
    export EVENT_FILE="$event_file"

    eval "$te_block"
    printf 'FELL THROUGH\n' >> "$EVENT_FILE"
  )
  printf '%s' "$?"
}

write_status() {  # <state_dir> <days_remaining-or-empty> <expires_at>
  mkdir -p "$1"
  if [[ -n "$2" ]]; then
    jq -nc --argjson d "$2" --arg e "$3" \
      '{timestamp:"2026-08-01T00:00:00Z",verdict:"ok",fails:[],warns:[],skips:0,
        token_expiry:{expires_at:$e,days_remaining:$d}}' > "$1/.doctor-status.json"
  else
    jq -nc '{timestamp:"2026-08-01T00:00:00Z",verdict:"ok",fails:[],warns:[],skips:0,token_expiry:null}' \
      > "$1/.doctor-status.json"
  fi
}

# --- Under threshold: the incident this exists for ---

sd="$tmp_dir/state-under"
ul="$tmp_dir/union-under.jsonl"
: > "$ul"
write_status "$sd" 3 "2026-08-22T09:35:00Z"

esc_file="$tmp_dir/under-escalations"
evt_file="$tmp_dir/under-events"
block_rc="$(run_block "$sd" "$ul" "$esc_file" "$evt_file")"

assert_eq "a token under threshold never stands the cycle down (falls through)" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and the block itself exits cleanly" "0" "$block_rc"
assert_eq "exactly one escalation is filed" "1" "$(grep -c '^---end---' "$esc_file" 2>/dev/null)"
assert_eq "…filed in crash_loop_repo, not a target repository" \
  "yes" "$(if grep -q '^repo=acme/agent-ops$' "$esc_file"; then echo yes; else echo no; fi)"
assert_eq "…the item ref names the node and the expiry" \
  "yes" "$(if grep -q '^item=token-expiry:test-node:2026-08-22T09:35:00Z$' "$esc_file"; then echo yes; else echo no; fi)"
assert_eq "…labelled for a human scanning open issues" \
  "yes" "$(if grep -q '^label=autonomous-agent-escalation$' "$esc_file"; then echo yes; else echo no; fi)"
assert_eq "…and the body names the days remaining" \
  "yes" "$(if grep -q 'days remaining: \*\*3\*\*' "$esc_file"; then echo yes; else echo no; fi)"
te_event="$(grep '^token-expiry-escalated' "$evt_file" || true)"
assert_eq "a token-expiry-escalated event was logged" \
  "yes" "$(if [[ -n "$te_event" ]]; then echo yes; else echo no; fi)"
assert_eq "…naming the exact expiry timestamp" \
  "yes" "$(if [[ "$te_event" == *'"expires_at":"2026-08-22T09:35:00Z"'* ]]; then echo yes; else echo no; fi)"

# --- A second cycle over the same expiry: the dedup this exists for ---

esc_file2="$tmp_dir/under-escalations-2"
evt_file2="$tmp_dir/under-events-2"
# The union log now carries the escalation the first run logged, exactly as
# a real fleet log union would after state-sync — dedup reads this, not the
# first run's own in-process state.
awk -F'\t' '$1=="token-expiry-escalated"{print "{\"node\":\"test-node\",\"event\":\"token-expiry-escalated\"," substr($2,2)}' "$evt_file" > "$ul"
run_block "$sd" "$ul" "$esc_file2" "$evt_file2" > /dev/null
assert_eq "a second cycle over the same still-under-threshold expiry escalates nothing further" \
  "0" "$(grep -c '^---end---' "$esc_file2" 2>/dev/null)"
assert_eq "…and logs no second token-expiry-escalated event" \
  "0" "$(grep -c '^token-expiry-escalated' "$evt_file2" 2>/dev/null)"
assert_eq "…and still falls through cleanly" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file2"; then echo yes; else echo no; fi)"

# --- A rotated token (a new expires_at) escalates again despite the old dedup ---

sd_rot="$tmp_dir/state-rotated"
write_status "$sd_rot" 2 "2026-09-15T00:00:00Z"
esc_file3="$tmp_dir/rotated-escalations"
evt_file3="$tmp_dir/rotated-events"
run_block "$sd_rot" "$ul" "$esc_file3" "$evt_file3" > /dev/null
assert_eq "a rotated token (a new expires_at) is not shadowed by the old escalation" \
  "1" "$(grep -c '^---end---' "$esc_file3" 2>/dev/null)"

# --- At or above threshold: nothing to escalate ---

sd_ok="$tmp_dir/state-ok"
write_status "$sd_ok" 30 "2026-10-01T00:00:00Z"
esc_file4="$tmp_dir/ok-escalations"
evt_file4="$tmp_dir/ok-events"
run_block "$sd_ok" "$tmp_dir/empty-union.jsonl" "$esc_file4" "$evt_file4" > /dev/null
assert_eq "a token well above threshold escalates nothing" \
  "0" "$(grep -c '^---end---' "$esc_file4" 2>/dev/null)"
assert_eq "…and falls through" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file4"; then echo yes; else echo no; fi)"

# --- No token_expiry recorded yet (a node whose doctor.sh has not run, or an
#     absent-header credential) ---

sd_none="$tmp_dir/state-none"
write_status "$sd_none" "" ""
esc_file5="$tmp_dir/none-escalations"
evt_file5="$tmp_dir/none-events"
run_block "$sd_none" "$tmp_dir/empty-union2.jsonl" "$esc_file5" "$evt_file5" > /dev/null
assert_eq "no recorded token_expiry escalates nothing" \
  "0" "$(grep -c '^---end---' "$esc_file5" 2>/dev/null)"
assert_eq "…and falls through" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file5"; then echo yes; else echo no; fi)"

# --- No .doctor-status.json at all (a fresh node) ---

sd_missing="$tmp_dir/state-missing"
mkdir -p "$sd_missing"
esc_file6="$tmp_dir/missing-escalations"
evt_file6="$tmp_dir/missing-events"
run_block "$sd_missing" "$tmp_dir/empty-union3.jsonl" "$esc_file6" "$evt_file6" > /dev/null
assert_eq "a missing .doctor-status.json escalates nothing" \
  "0" "$(grep -c '^---end---' "$esc_file6" 2>/dev/null)"
assert_eq "…and falls through" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file6"; then echo yes; else echo no; fi)"

echo
if (( failures == 0 )); then
  echo "All token-expiry-wiring assertions passed."
  exit 0
else
  echo "$failures token-expiry-wiring assertion(s) FAILED."
  exit 1
fi
