#!/usr/bin/env bash
#
# test/host-budget.test.sh — regression test for lib/host-budget.sh
# (agent-ops#757): the pure sum/verdict/describe arithmetic requirement
# 2.0g's stand-down and scripts/doctor.sh's own advisory share, so the two
# cannot silently disagree about what "over budget" means.
#
# test/host-budget-wiring.test.sh covers whether the cycle actually acts on
# these functions' verdicts; this file covers only the functions themselves,
# against fixture `containers[]` arrays, so no assertion depends on this
# host's real container set.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/host-budget.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/host-budget.sh
. "$SCRIPT_DIR/lib/host-budget.sh"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected %q, got %q)\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# --- fixtures ----------------------------------------------------------------

# Two running containers with known ceilings, one exited container with a
# large ceiling that must never be counted, and one running container with
# no readable memory ceiling and no CPU limit at all.
containers_mixed='[
  {"state":"running","memory":{"max_bytes":1073741824},"cpu":{"limit_nanos":500000000}},
  {"state":"running","memory":{"max_bytes":2147483648},"cpu":{"limit_nanos":1000000000}},
  {"state":"exited","memory":{"max_bytes":999999999999},"cpu":{"limit_nanos":999999999999}},
  {"state":"running","memory":{"max_bytes":null},"cpu":{"limit_nanos":null}}
]'

# A set of containers whose declared ceilings cannot fit a small host —
# proving the overcommit path directly, per the issue's own "Done when",
# rather than waiting for a real host to run out.
containers_cannot_fit='[
  {"state":"running","memory":{"max_bytes":3221225472},"cpu":{"limit_nanos":2000000000}},
  {"state":"running","memory":{"max_bytes":3221225472},"cpu":{"limit_nanos":2000000000}}
]'

# --- host_budget_declared_mem_bytes / _cpu_nanos ------------------------------

assert_eq "mem sum counts only running, known-ceiling entries" \
  "3221225472" "$(host_budget_declared_mem_bytes "$containers_mixed")"
assert_eq "cpu sum counts only running, known-limit entries" \
  "1500000000" "$(host_budget_declared_cpu_nanos "$containers_mixed")"
assert_eq "mem sum is 0, never empty, for an empty array" \
  "0" "$(host_budget_declared_mem_bytes '[]')"
assert_eq "cpu sum is 0, never empty, for an empty array" \
  "0" "$(host_budget_declared_cpu_nanos '[]')"
assert_eq "mem sum is 0 for a malformed array" \
  "0" "$(host_budget_declared_mem_bytes 'not json')"

# --- host_budget_declared_mem_unknown_count / _cpu_unknown_count -------------

assert_eq "one running container has an unknown memory ceiling" \
  "1" "$(host_budget_declared_mem_unknown_count "$containers_mixed")"
assert_eq "one running container has an unknown cpu limit" \
  "1" "$(host_budget_declared_cpu_unknown_count "$containers_mixed")"
assert_eq "an exited container's own unknown ceiling is not counted" \
  "0" "$(host_budget_declared_mem_unknown_count '[{"state":"exited","memory":{"max_bytes":null}}]')"

# --- host_budget_summary_json -------------------------------------------------

summary="$(host_budget_summary_json 6442450944 4 "$containers_mixed")"
assert_eq "summary carries the host mem total through" \
  "6442450944" "$(jq -r '.mem_total_bytes' <<<"$summary")"
assert_eq "summary computes mem headroom" \
  "3221225472" "$(jq -r '.mem_headroom_bytes' <<<"$summary")"
assert_eq "summary carries cpu_count through" \
  "4" "$(jq -r '.cpu_count' <<<"$summary")"
assert_eq "summary computes cpu headroom in nanos" \
  "2500000000" "$(jq -r '.cpu_headroom_nanos' <<<"$summary")"

summary_unknown_total="$(host_budget_summary_json '' '' "$containers_mixed")"
assert_eq "mem_total_bytes is null, not 0, for a non-numeric host total" \
  "null" "$(jq -r '.mem_total_bytes' <<<"$summary_unknown_total")"
assert_eq "mem_headroom_bytes is null when mem_total_bytes is null" \
  "null" "$(jq -r '.mem_headroom_bytes' <<<"$summary_unknown_total")"
assert_eq "cpu_headroom_nanos is null when cpu_count is null" \
  "null" "$(jq -r '.cpu_headroom_nanos' <<<"$summary_unknown_total")"

# --- host_budget_mem_verdict ---------------------------------------------------

assert_eq "mem verdict is ok when the sum plus reserve fits" \
  "ok" "$(host_budget_mem_verdict 1000000000 6000000000 0)"
assert_eq "mem verdict is over when the sum plus reserve exceeds the host" \
  "over" "$(host_budget_mem_verdict 5000000000 6000000000 2000000000)"
assert_eq "mem verdict is ok for an unreadable host total — no evidence, no verdict" \
  "ok" "$(host_budget_mem_verdict 999999999999 '' 0)"
assert_eq "mem verdict is exactly at the boundary: equal is ok, not over" \
  "ok" "$(host_budget_mem_verdict 6000000000 6000000000 0)"

# --- host_budget_cpu_verdict ---------------------------------------------------

assert_eq "cpu verdict is ok when the sum plus reserve fits" \
  "ok" "$(host_budget_cpu_verdict 2000000000 4 0)"
assert_eq "cpu verdict is over when the sum exceeds the host's own core count" \
  "over" "$(host_budget_cpu_verdict 5000000000 4 0)"
assert_eq "cpu verdict is ok for an unreadable host cpu count" \
  "ok" "$(host_budget_cpu_verdict 999999999999 '' 0)"
assert_eq "a fractional cpu reserve is honoured" \
  "over" "$(host_budget_cpu_verdict 3800000000 4 0.5)"

# --- the declared-budgets-that-cannot-fit proof (issue #757's own "Done when") -

cannot_fit_summary="$(host_budget_summary_json 5368709120 3 "$containers_cannot_fit")"
mem_declared="$(jq -r '.mem_declared_bytes' <<<"$cannot_fit_summary")"
mem_total="$(jq -r '.mem_total_bytes' <<<"$cannot_fit_summary")"
cpu_declared="$(jq -r '.cpu_declared_nanos' <<<"$cannot_fit_summary")"
cpu_count="$(jq -r '.cpu_count' <<<"$cannot_fit_summary")"
assert_eq "the declared sum genuinely exceeds this fixture host's memory" \
  "yes" "$(if (( mem_declared > mem_total )); then echo yes; else echo no; fi)"
assert_eq "…and the mem verdict reads over" \
  "over" "$(host_budget_mem_verdict "$mem_declared" "$mem_total" 0)"
assert_eq "…and the cpu verdict reads over too" \
  "over" "$(host_budget_cpu_verdict "$cpu_declared" "$cpu_count" 0)"

# --- host_budget_describe -----------------------------------------------------

description="$(host_budget_describe "$cannot_fit_summary" 536870912 0)"
assert_eq "describe names the declared memory sum in MiB" \
  "yes" "$(if [[ "$description" == *"6144 MiB"* ]]; then echo yes; else echo no; fi)"
assert_eq "describe names the reserve in MiB" \
  "yes" "$(if [[ "$description" == *"512 MiB"* ]]; then echo yes; else echo no; fi)"
assert_eq "describe names the declared cpu sum in cores" \
  "yes" "$(if [[ "$description" == *"4.00 cores"* ]]; then echo yes; else echo no; fi)"
assert_eq "describe names the host cpu count" \
  "yes" "$(if [[ "$description" == *"3 host CPUs"* ]]; then echo yes; else echo no; fi)"

description_unknown="$(host_budget_describe "$summary" 0 0)"
assert_eq "describe names an unknown-container count when one exists" \
  "yes" "$(if [[ "$description_unknown" == *"1 container(s) with an unknown ceiling"* ]]; then echo yes; else echo no; fi)"

echo
if (( failures == 0 )); then
  echo "All host-budget assertions passed."
  exit 0
else
  echo "$failures host-budget assertion(s) FAILED."
  exit 1
fi
