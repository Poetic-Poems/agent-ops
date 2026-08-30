#!/usr/bin/env bash
#
# test/github-budget-report.test.sh — regression test for
# scripts/github-budget-report.sh (requirement 2.0d, agent-ops#1087): the
# per-hour, per-stage and per-node sums over `github-budget` events, and the
# two things the report must never do — count an unreadable reading's
# figures, or attribute a window roll's movement to a stage.
#
# Run directly:
#
#   ./test/github-budget-report.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$SCRIPT_DIR/scripts/github-budget-report.sh"

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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Two nodes, two hours. poetic-1's cycle reads at start, after two stages and
# at the end; ockham-2's cycle-start is unreadable, its stage reading spans a
# window roll, and its hour holds two refusals and one budget stand-down. A
# damaged line and a non-budget event are in the mix to be ignored.
log_a="$tmp_dir/a.jsonl"
log_b="$tmp_dir/b.jsonl"
cat > "$log_a" <<'LOG'
{"ts":"2026-08-30T06:33:00Z","cycle":"c1","node":"poetic-1","event":"cycle-start"}
{"ts":"2026-08-30T06:33:02Z","cycle":"c1","node":"poetic-1","event":"github-budget","phase":"cycle-start","readable":true,"core":{"limit":5000,"used":100,"remaining":4900,"reset":1788076235},"graphql":{"limit":5000,"used":10,"remaining":4990,"reset":1788076295},"since_previous":{"core":null,"graphql":null,"window_rolled":false}}
{"ts":"2026-08-30T06:40:00Z","cycle":"c1","node":"poetic-1","event":"github-budget","phase":"stage","stage":"implementer","readable":true,"core":{"limit":5000,"used":160,"remaining":4840,"reset":1788076235},"graphql":{"limit":5000,"used":12,"remaining":4988,"reset":1788076295},"since_previous":{"core":60,"graphql":2,"window_rolled":false}}
{"ts":"2026-08-30T06:50:00Z","cycle":"c1","node":"poetic-1","event":"github-budget","phase":"stage","stage":"reviewer","readable":true,"core":{"limit":5000,"used":200,"remaining":4800,"reset":1788076235},"graphql":{"limit":5000,"used":15,"remaining":4985,"reset":1788076295},"since_previous":{"core":40,"graphql":3,"window_rolled":false}}
{"ts":"2026-08-30T06:55:00Z","cycle":"c1","node":"poetic-1","event":"github-budget","phase":"cycle-end","readable":true,"core":{"limit":5000,"used":230,"remaining":4770,"reset":1788076235},"graphql":{"limit":5000,"used":15,"remaining":4985,"reset":1788076295},"since_previous":{"core":30,"graphql":0,"window_rolled":false}}
this line is damaged and must be skipped
{"ts":"2026-08-30T07:05:00Z","cycle":"c2","node":"poetic-1","event":"github-budget","phase":"stage","stage":"reviewer","readable":true,"core":{"limit":5000,"used":4990,"remaining":10,"reset":1788076235},"graphql":{"limit":5000,"used":20,"remaining":4980,"reset":1788076295},"since_previous":{"core":100,"graphql":1,"window_rolled":false}}
LOG
cat > "$log_b" <<'LOG'
{"ts":"2026-08-30T07:03:00Z","cycle":"c9","node":"ockham-2","event":"github-budget","phase":"cycle-start","readable":false}
{"ts":"2026-08-30T07:04:00Z","cycle":"c9","node":"ockham-2","event":"guard-degraded","site":"handoff","detail":"HTTP 403: API rate limit exceeded for user ID 2049303."}
{"ts":"2026-08-30T07:04:30Z","cycle":"c9","node":"ockham-2","event":"guard-degraded","site":"sweep","detail":"GraphQL: API rate limit already exceeded for user ID 2049303."}
{"ts":"2026-08-30T07:04:40Z","cycle":"c9","node":"ockham-2","event":"guard-degraded","site":"contents","detail":"HTTP 404: Not Found"}
{"ts":"2026-08-30T07:06:00Z","cycle":"c9","node":"ockham-2","event":"stand-down","reason":"GitHub API budget exhausted: core has 10 point(s) left","github_resource":"core","github_remaining":"10","resume_at":"2026-08-30T07:10:35Z"}
{"ts":"2026-08-30T07:20:00Z","cycle":"c10","node":"ockham-2","event":"github-budget","phase":"stage","stage":"reviewer","readable":true,"core":{"limit":5000,"used":7,"remaining":4993,"reset":1788079835},"graphql":{"limit":5000,"used":1,"remaining":4999,"reset":1788079895},"since_previous":{"core":7,"graphql":1,"window_rolled":true}}
LOG

out="$("$REPORT" "$log_a" "$log_b")"
rc=$?
# shellcheck disable=SC2016  # the fence is literal backticks, not an expansion
json="$(sed -n '/^```json$/,/^```$/p' <<<"$out" | sed '1d;$d')"

assert_eq "the report exits 0 over explicit log files" "0" "$rc"
assert_eq "it opens with its own heading" "# GitHub API budget report" "$(head -1 <<<"$out")"
assert_eq "it states what the figures are — the bucket's, not a node's" \
  "yes" "$(if [[ "$out" == *"upper bound on what that segment itself spent"* ]]; then echo yes; else echo no; fi)"

assert_eq "every github-budget event is a reading, the damaged line is not" \
  "7" "$(jq -r '.readings' <<<"$json")"
assert_eq "…of which the unreadable one is counted apart" \
  "6" "$(jq -r '.readable' <<<"$json")"

# Per hour: the 06 hour holds poetic-1's four readings; the 07 hour holds
# three readings, two refusals (the 404 is not one) and the stand-down.
assert_eq "the 06 hour's peak core used is the cycle-end reading's" \
  "230" "$(jq -r '.per_hour[] | select(.hour == "2026-08-30T06") | .core_peak_used' <<<"$json")"
assert_eq "…and its minimum core remaining likewise" \
  "4770" "$(jq -r '.per_hour[] | select(.hour == "2026-08-30T06") | .core_min_remaining' <<<"$json")"
assert_eq "the 07 hour's minimum remaining is the near-empty reading, not the rolled one's" \
  "10" "$(jq -r '.per_hour[] | select(.hour == "2026-08-30T07") | .core_min_remaining' <<<"$json")"
assert_eq "the 07 hour counts its two primary refusals and not the 404" \
  "2" "$(jq -r '.per_hour[] | select(.hour == "2026-08-30T07") | .refusals' <<<"$json")"
assert_eq "…and its one requirement-2.0 stand-down" \
  "1" "$(jq -r '.per_hour[] | select(.hour == "2026-08-30T07") | .budget_standdowns' <<<"$json")"
assert_eq "the unreadable reading counts as a reading but contributes no figure" \
  "3" "$(jq -r '.per_hour[] | select(.hour == "2026-08-30T07") | .readings' <<<"$json")"

# Per stage: the reviewer has two same-window readings (40 and 100) and one
# rolled reading that must be left out; the implementer has one.
assert_eq "a stage's movement excludes the reading that spanned a window roll" \
  "2" "$(jq -r '.per_stage[] | select(.stage == "reviewer") | .readings' <<<"$json")"
assert_eq "…its median is the upper of an even pair" \
  "100" "$(jq -r '.per_stage[] | select(.stage == "reviewer") | .core_movement_median' <<<"$json")"
assert_eq "…and its maximum is the largest same-window movement" \
  "100" "$(jq -r '.per_stage[] | select(.stage == "reviewer") | .core_movement_max' <<<"$json")"
assert_eq "a single-reading stage reports that reading" \
  "60" "$(jq -r '.per_stage[] | select(.stage == "implementer") | .core_movement_median' <<<"$json")"

# Per cycle (agent-ops#1086): the sum of same-window since_previous.core
# across a cycle's own readings. c1's cycle-start carries no since_previous
# (excluded); its spend is the implementer (60) + reviewer (40) + cycle-end
# (30) readings. c2 has one reading (100). c9's only reading is unreadable, so
# its spend is 0 despite having a reading. c10's only reading is window-rolled,
# so it too spends 0 despite being readable.
assert_eq "c1's per-cycle core spend sums every same-window reading but the null cycle-start" \
  "130" "$(jq -r '.per_cycle[] | select(.cycle == "c1") | .core_spend' <<<"$json")"
assert_eq "…and its node is named" \
  "poetic-1" "$(jq -r '.per_cycle[] | select(.cycle == "c1") | .node' <<<"$json")"
assert_eq "c2's spend is its one reading" \
  "100" "$(jq -r '.per_cycle[] | select(.cycle == "c2") | .core_spend' <<<"$json")"
assert_eq "c9's spend is 0 — its only reading is unreadable" \
  "0" "$(jq -r '.per_cycle[] | select(.cycle == "c9") | .core_spend' <<<"$json")"
assert_eq "c10's spend is 0 — its only reading spans a window roll" \
  "0" "$(jq -r '.per_cycle[] | select(.cycle == "c10") | .core_spend' <<<"$json")"
assert_eq "every cycle enters the breakdown even with zero spend" \
  "c1,c10,c2,c9" "$(jq -r '[.per_cycle[].cycle] | sort | join(",")' <<<"$json")"

# Per node.
assert_eq "poetic-1's readings span two cycles" \
  "5 0 2" "$(jq -r '.per_node[] | select(.node == "poetic-1") | "\(.readings) \(.unreadable) \(.cycles_with_record)"' <<<"$json")"
assert_eq "ockham-2's unreadable reading is counted" \
  "2 1 2" "$(jq -r '.per_node[] | select(.node == "ockham-2") | "\(.readings) \(.unreadable) \(.cycles_with_record)"' <<<"$json")"

# --since keeps only what is at or after the mark.
# shellcheck disable=SC2016
since_json="$("$REPORT" --since 2026-08-30T07:00:00Z "$log_a" "$log_b" | sed -n '/^```json$/,/^```$/p' | sed '1d;$d')"
assert_eq "--since drops the earlier hour entirely" \
  "2026-08-30T07" "$(jq -r '[.per_hour[].hour] | join(",")' <<<"$since_json")"

# The fleet-shaped read: state_dir's own log plus each peer directory's copy.
fleet="$tmp_dir/fleet"
mkdir -p "$fleet/state" "$fleet/peers/ockham-2"
cp "$log_a" "$fleet/state/log.jsonl"
cp "$log_b" "$fleet/peers/ockham-2/log.jsonl"
# shellcheck disable=SC2016
fleet_json="$("$REPORT" --state-dir "$fleet/state" --peers-dir "$fleet/peers" | sed -n '/^```json$/,/^```$/p' | sed '1d;$d')"
assert_eq "the fleet read unions this node's log with its peers'" \
  "7" "$(jq -r '.readings' <<<"$fleet_json")"

# Nothing to report is said, not crashed on.
empty="$tmp_dir/empty.jsonl"; : > "$empty"
assert_eq "an empty log yields the empty-report line and exit 0" \
  "0:yes" "$(o="$("$REPORT" "$empty")"; r=$?; echo "$r:$(if [[ "$o" == *"nothing to report"* ]]; then echo yes; else echo no; fi)")"
assert_eq "a missing log is an error, not an empty report" \
  "1" "$("$REPORT" "$tmp_dir/nope.jsonl" >/dev/null 2>&1; echo $?)"

echo
if (( failures == 0 )); then
  echo "All github-budget-report assertions passed."
  exit 0
else
  echo "$failures github-budget-report assertion(s) FAILED."
  exit 1
fi
