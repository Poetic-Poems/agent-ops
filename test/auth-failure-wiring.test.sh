#!/usr/bin/env bash
#
# test/auth-failure-wiring.test.sh — regression test for requirement 2.0b's
# GitHub credential check in agent-cycle.sh (agent-ops#691): not whether
# `github_auth_probe` classifies a 401 correctly (test/github-limit.test.sh
# covers that in isolation) but whether the cycle actually acts on the
# classification — standing down with the right reason and escalating,
# before anything downstream (the Co-Ordinator most of all) ever runs.
#
# The incident this guards: a node's `GH_TOKEN` expired, and every cycle for
# ~3 hours ran a full Co-Ordinator engagement ($0.21 each) before every claim
# failed with `cause: "unreachable"` — a 401 folded into the same bucket as a
# network blip, so the stand-down read "this is an outage, not contention"
# and nobody went looking at the token. The three things worth asserting
# here are exactly the three the issue's acceptance criteria named:
#
#   - **`unauthorized` stands the cycle down before the block falls through**
#     — this test never reaches a Co-Ordinator call because the extracted
#     block is everything that runs before one; if the block did not `exit 0`
#     here, a real cycle would carry on into it (asserted as "FELL THROUGH"
#     never appearing for this mode).
#   - **The stand-down reason names the credential problem, not a generic
#     outage** — the exact wording the issue asked for, not "GitHub could not
#     be reached for any candidate".
#   - **It escalates through `create_escalation_issue`**, the same
#     fleet-scoped, deduplicated route 1c's usage-limit freeze and 2.7's
#     crash loop already use — not `escalation_autonomy`, which is scoped to
#     Enabler refinement-disagreements alone (see the block's own comment).
#
# Also asserts the two cases requirement 2.0b must leave alone: `ok`
# credentials fall through to the rest of the cycle untouched, and
# `unreachable` (a network fault, not a rejection) is left for the existing
# claim-loop classification to handle rather than being escalated here.
#
# The block is lifted verbatim out of agent-cycle.sh, the way
# test/backpressure-wiring.test.sh and test/void-retire-wiring.test.sh lift
# their own, so the assertions are about the shipped code rather than a copy
# of its logic.
#
# No network: `github_auth_probe` and `create_escalation_issue` are both
# stubs, the second recording the argv and body it was handed.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
# ./test/auth-failure-wiring.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

auth_block="$(extract_block '^# 2\.0b GitHub credential check' '^# 2\.1 Usage-limit cooldown' "$AGENT_CYCLE")"
if [[ -z "$auth_block" ]]; then
  echo "FAIL - could not extract the GitHub credential check block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if ! grep -q 'github_auth_probe' <<<"$auth_block"; then
  echo "FAIL - extracted block does not call github_auth_probe — the anchors matched the wrong text" >&2
  exit 1
fi

# run_block MODE DETAIL ESCALATION_FILE EVENT_FILE — MODE/DETAIL are what the
# stubbed github_auth_probe reports. Writes every create_escalation_issue call
# (argv, one per line, plus its body file's content) to ESCALATION_FILE and
# every log_event call to EVENT_FILE, and prints the block's own exit status
# followed by "FELL THROUGH" iff it ran off the end rather than exiting.
run_block() {
  local mode="$1" detail="$2" escalation_file="$3" event_file="$4"
  : > "$escalation_file"
  : > "$event_file"
  (
    # `-e`, matching agent-cycle.sh's own top-of-file flags exactly (not
    # this test file's own, looser `set -uo pipefail`): a stubbed helper
    # that returns non-zero for a benign reason — `read` reading a final
    # line with no trailing newline is exactly this bug's own shape — would
    # abort the block silently under `-e` and read here as a false "FELL
    # THROUGH never happened", the same way it would abort a real cycle.
    set -euo pipefail
    # shellcheck disable=SC2034  # consumed by $auth_block below, invisible to a static reader
    DRY_RUN=0
    # shellcheck disable=SC2034  # consumed by $auth_block below, invisible to a static reader
    crash_loop_repo="acme/agent-ops"
    # shellcheck disable=SC2034  # consumed by $auth_block below, invisible to a static reader
    enabler_assignee="ops-bot"
    # shellcheck disable=SC2034  # consumed by $auth_block below, invisible to a static reader
    enabler_escalation_label="autonomous-agent-escalation"
    # shellcheck disable=SC2034  # consumed by $auth_block below, invisible to a static reader
    cycle_dir="$tmp_dir"
    # shellcheck disable=SC2034  # consumed by $auth_block below, invisible to a static reader
    node_name="test-node"
    # shellcheck disable=SC2034  # consumed by $auth_block below, invisible to a static reader
    cycle_id="20260101T000000Z-test-node-1"

    # shellcheck disable=SC2317  # called from $auth_block via eval, invisible to a static reader
    github_auth_probe() { printf '%s\t%s\n' "$AUTH_MODE" "$AUTH_DETAIL"; }
    export AUTH_MODE="$mode" AUTH_DETAIL="$detail"

    # Records exactly the argv a real escalation would pass
    # (repo, item, label, title, body_file), plus the body file's own
    # contents, so the assertions below can check both the routing and the
    # message a human would actually read.
    # shellcheck disable=SC2317  # called from $auth_block via eval, invisible to a static reader
    create_escalation_issue() {
      { printf 'repo=%s\nitem=%s\nlabel=%s\ntitle=%s\n' "$1" "$2" "$3" "$4"
        echo "---body---"
        cat "$5" 2>/dev/null
        echo "---end---"
      } >> "$ESCALATION_FILE"
      printf '99\thttps://github.com/acme/agent-ops/issues/99'
    }
    export ESCALATION_FILE="$escalation_file"

    # shellcheck disable=SC2317  # called from $auth_block via eval, invisible to a static reader
    log_event() {
      printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$EVENT_FILE"
    }
    export EVENT_FILE="$event_file"

    eval "$auth_block"
    printf 'FELL THROUGH\n' >> "$EVENT_FILE"
  )
  printf '%s' "$?"
}

# --- unauthorized: the incident this exists for ---

esc_file="$tmp_dir/unauthorized-escalations"
evt_file="$tmp_dir/unauthorized-events"
block_rc="$(run_block unauthorized 'gh: Bad credentials (HTTP 401)' "$esc_file" "$evt_file")"

assert_eq "unauthorized credentials stand the cycle down (exit 0, never falls through)" \
  "0" "$block_rc"
assert_eq "…and the block never runs off its own end into the rest of the cycle" \
  "no" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"

standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "a stand-down event was logged" "yes" "$(if [[ -n "$standdown_line" ]]; then echo yes; else echo no; fi)"
assert_eq "the stand-down reason names the credential problem" \
  "yes" "$(if [[ "$standdown_line" == *"GitHub authentication failed (HTTP 401)"* && "$standdown_line" == *"GH_TOKEN is invalid or expired"* ]]; then echo yes; else echo no; fi)"
assert_eq "…and never claims this is a generic outage" \
  "no" "$(if [[ "$standdown_line" == *"could not be reached"* || "$standdown_line" == *"outage, not contention"* ]]; then echo yes; else echo no; fi)"
assert_eq "…and the structured cause is unauthorized, not unreachable" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"unauthorized"'* ]]; then echo yes; else echo no; fi)"

assert_eq "exactly one escalation is filed" \
  "1" "$(grep -c '^---end---' "$esc_file" 2>/dev/null)"
assert_eq "the escalation names the item ref by node" \
  "yes" "$(if grep -q '^item=auth-failure:test-node$' "$esc_file"; then echo yes; else echo no; fi)"
assert_eq "…filed in crash_loop_repo, not a target repository" \
  "yes" "$(if grep -q '^repo=acme/agent-ops$' "$esc_file"; then echo yes; else echo no; fi)"
assert_eq "…labelled and titled for a human scanning open issues" \
  "yes" "$(if grep -q '^label=autonomous-agent-escalation$' "$esc_file" && grep -q '^title=.*HTTP 401' "$esc_file"; then echo yes; else echo no; fi)"
assert_eq "…and the body quotes GitHub's own 401 response" \
  "yes" "$(if grep -q 'Bad credentials (HTTP 401)' "$esc_file"; then echo yes; else echo no; fi)"

# --- ok: nothing to do, the cycle proceeds untouched ---

esc_file="$tmp_dir/ok-escalations"
evt_file="$tmp_dir/ok-events"
block_rc="$(run_block ok '' "$esc_file" "$evt_file")"
assert_eq "working credentials fall through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…without filing anything" "0" "$(grep -c '^---end---' "$esc_file" 2>/dev/null)"
assert_eq "…and without standing anything down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- unreachable: a network fault, not a rejection — left to the existing
# claim-loop classification (cause "unreachable" there already), not
# escalated by this check ---

esc_file="$tmp_dir/unreachable-escalations"
evt_file="$tmp_dir/unreachable-events"
block_rc="$(run_block unreachable 'gh: connection reset by peer' "$esc_file" "$evt_file")"
assert_eq "a network fault is not treated as a credential rejection" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and nothing is escalated for it here" \
  "0" "$(grep -c '^---end---' "$esc_file" 2>/dev/null)"

echo
if (( failures == 0 )); then
  echo "All auth-failure-wiring assertions passed."
  exit 0
else
  echo "$failures auth-failure-wiring assertion(s) FAILED."
  exit 1
fi
