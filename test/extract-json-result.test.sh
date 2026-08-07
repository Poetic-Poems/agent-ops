#!/usr/bin/env bash
#
# test/extract-json-result.test.sh — the final-message parser's three copies
# (agent-cycle.sh, review-cycle.sh, and publish-dashboard.sh's jq port) accept
# the same shapes and agree on every case. DASHBOARD-SPEC.md's "same
# algorithm" claim, made checkable.
#
# What this guards: on 2026-08-03 an Enabler engagement examined three
# refinement items, reached a correct `escalate` verdict on each, drafted
# every escalation issue — and ended with a summary paragraph, a blank line,
# and the verdict object, bare. The parser of the day accepted pure JSON or a
# fenced ```json block and nothing else, so the engagement was discarded
# whole, and the items sat behind its never-released claims for the rest of
# claim_ttl_hours. The bare-object-suffix salvage exists for exactly that
# shape; the cases below pin it, pin what it deliberately still refuses (an
# object with trailing prose, a summary that merely mentions braces), and pin
# the three copies to each other so the dashboard never renders as silent a
# verdict the cycle accepted.
#
# Also guarded: issue #237's shape, a verdict fenced without a `json` info
# string (or with a different one). The fence fallback used to require the
# literal tag and so missed it — on 2026-08-07 that discarded poetic-2's
# completed conflict resolution of PR #205, erasing pipeline memory that the
# conflict was fixed. The fence matcher now toggles on any ``` line, tagged
# or not, in or out of a block.
#
# The implementations are lifted from their scripts rather than restated
# here, so this cannot pass against copies the scripts have since moved on
# from; each extraction asserts it found something for the same reason. The
# two bash copies run in their own `bash -c` child because they share a
# function name; no network, no model, no cost.
#
# Run directly: ./test/extract-json-result.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- Lift the two bash copies ---
lift_bash_fn() {
  awk '
    /^extract_json_result\(\) \{$/ { on = 1 }
    on                             { print }
    on && /^\}$/                   { exit }
  ' "$1"
}

agent_fn="$(lift_bash_fn "$SCRIPT_DIR/agent-cycle.sh")"
review_fn="$(lift_bash_fn "$SCRIPT_DIR/review-cycle.sh")"
if [[ -z "$agent_fn" || -z "$review_fn" ]]; then
  echo "FAIL - could not lift extract_json_result from one of the cycle scripts"
  exit 1
fi

# --- Lift the jq port (try_json + extract_status) from the dashboard ---
try_json_def="$(grep -m1 '^def try_json' "$SCRIPT_DIR/scripts/publish-dashboard.sh")"
extract_status_def="$(awk '
  /^def extract_status\(\$text\):$/ { on = 1 }
  on                                { print }
  on && /^  end;$/                  { exit }
' "$SCRIPT_DIR/scripts/publish-dashboard.sh")"
if [[ -z "$try_json_def" || -z "$extract_status_def" ]]; then
  echo "FAIL - could not lift try_json/extract_status from publish-dashboard.sh"
  exit 1
fi
jq_defs="$try_json_def"$'\n'"$extract_status_def"

# Each runner prints the parsed compact JSON, or nothing when the text is
# unparseable — the one observable every caller of these parsers actually
# reads (agent-cycle.sh and review-cycle.sh both `|| true` the exit code and
# test the output; the dashboard reads `.value`).
run_agent()  { bash -c "$agent_fn"$'\nextract_json_result "$1"' bash "$1" 2>/dev/null; }
run_review() { bash -c "$review_fn"$'\nextract_json_result "$1"' bash "$1" 2>/dev/null; }
run_jq() {
  jq -nrc --arg text "$1" \
    "$jq_defs"$'\nextract_status($text) | .value | if . == null then empty else . end' \
    2>/dev/null
}

check() {  # check DESC TEXT EXPECTED  (EXPECTED = compact JSON, or "<none>")
  local desc="$1" text="$2" expected="$3" a r j
  a="$(run_agent "$text")";  [[ -n "$a" ]] || a="<none>"
  r="$(run_review "$text")"; [[ -n "$r" ]] || r="<none>"
  j="$(run_jq "$text")";     [[ -n "$j" ]] || j="<none>"
  assert_eq "$desc (agent-cycle.sh)" "$expected" "$a"
  assert_eq "$desc (review-cycle.sh)" "$expected" "$r"
  assert_eq "$desc (dashboard jq port)" "$expected" "$j"
}

# --- The shapes that always parsed ---
check "pure JSON object" \
  '{"status": "ready", "pr_url": "https://example.invalid/1"}' \
  '{"status":"ready","pr_url":"https://example.invalid/1"}'

check "prose then fenced json block" \
  $'Here is my verdict.\n```json\n{"verdict": "unblocked"}\n```' \
  '{"verdict":"unblocked"}'

check "fenced block wins over a later bare object" \
  $'```json\n{"from": "fence"}\n```\n{"from": "suffix"}' \
  '{"from":"fence"}'

# --- issue #237: a fence with no `json` info-string, or a different one ---
check "prose then plain-fenced object, no info string (issue #237)" \
  $'Here is my verdict.\n```\n{"verdict": "unblocked"}\n```' \
  '{"verdict":"unblocked"}'

check "prose then fenced object tagged with something other than json" \
  $'Here is my verdict.\n```JSON\n{"verdict": "unblocked"}\n```' \
  '{"verdict":"unblocked"}'

# --- The 2026-08-03 shape: prose, a blank line, the verdict object bare ---
check "prose then bare object suffix (the discarded-engagement shape)" \
  $'I have what I need. All three items turn on something only the maintainer\ncan supply, so all three escalate.\n\n{"examined":[{"repo":"Poetic-Poems/poetic-fiddle","item":"TD-PPpfid-26080108","verdict":"escalate"}],"notes":"none"}' \
  '{"examined":[{"repo":"Poetic-Poems/poetic-fiddle","item":"TD-PPpfid-26080108","verdict":"escalate"}],"notes":"none"}'

check "prose then pretty-printed object suffix" \
  $'Verdict below.\n\n{\n  "verdict": "still-blocked",\n  "reason": "impediment stands"\n}' \
  '{"verdict":"still-blocked","reason":"impediment stands"}'

check "brace-opening line that does not parse, then one that does" \
  $'{ not json at all\nstill prose\n{"ok": true}' \
  '{"ok":true}'

check "two trailing objects: only the single-value suffix (the last) is taken" \
  $'preamble\n{"first": 1}\n{"second": 2}' \
  '{"second":2}'

# --- What the salvage deliberately refuses ---
check "object with trailing prose still fails" \
  $'{"verdict": "unblocked"}\nLet me know if you need anything else.' \
  "<none>"

check "prose mentioning braces mid-line only" \
  $'The config block { retries: 3 } needs a decision.' \
  "<none>"

check "prose only" \
  $'I examined the items and will report next cycle.' \
  "<none>"

check "whitespace only (TD26072802)" $'  \n\t\n' "<none>"

check "empty string (TD26072802)" "" "<none>"

exit "$(( failures > 0 ))"
