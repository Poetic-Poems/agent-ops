#!/usr/bin/env bash
#
# test/publish-dashboard.test.sh — regression tests for
# scripts/publish-dashboard.sh and scripts/publish-dashboard-launcher.sh.
#
# Two behaviours here have already failed in production and one is a scaling
# property, so they get tests rather than a careful reading:
#
#   the launcher's exit   a healthy window must end 0 — its status once came
#                         from the final tick's lock bookkeeping, so
#                         supercronic reported every successful window as a
#                         failure, every five minutes
#   the cost scan         batching must preserve the per-file semantics: the
#                         day cut-off, the model roll-up, tolerance of a torn
#                         envelope mid-write, and unconditional redaction
#   the process budget    a long history must not translate into thousands of
#                         jq forks per publish (tens of seconds under WSL2)
#
# No network and no GitHub: every publish runs --no-github against a
# synthesised state dir (a throwaway HOME, since config.json's state_dir is
# ~-relative). No test framework is used (none exists elsewhere in this
# repo). Run directly:
#
#   ./test/publish-dashboard.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH="$SCRIPT_DIR/scripts/publish-dashboard.sh"
LAUNCHER="$SCRIPT_DIR/scripts/publish-dashboard-launcher.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n' "$desc" "$needle"
    failures=$(( failures + 1 ))
  fi
}

# --- A node --------------------------------------------------------------------
# Each node is a HOME: config.json's state_dir is ~-relative, so a throwaway
# home is a throwaway state dir.
new_home() {  # new_home <name> -> prints its HOME
  local home="$tmp_dir/$1"
  mkdir -p "$home/.local/state/poetic-agents/cycles"
  printf '%s' "$home"
}

# One stage envelope, the shape `claude -p --output-format json` writes: a
# single line of compact JSON. Costs are chosen float-exact (quarters) so jq's
# additions compare cleanly.
make_cycle() {  # make_cycle <home> <cid> <cost> <model> [result-text]
  local home="$1" cid="$2" cost="$3" model="$4" result="${5:-ok}"
  local d="$home/.local/state/poetic-agents/cycles/$cid"
  mkdir -p "$d"
  printf '{"type":"result","subtype":"success","total_cost_usd":%s,"duration_ms":5,"num_turns":1,"is_error":false,"modelUsage":{"%s":{}},"result":"%s"}' \
    "$cost" "$model" "$result" > "$d/coordinator.out"
}

run_publish() {  # run_publish <home> [env assignments…]
  local home="$1"; shift
  env HOME="$home" "$@" "$PUBLISH" --no-github >/dev/null 2>&1
}

data_of() {  # the JSON inside data.js, wrapper stripped
  local home="$1"
  tail -n +2 "$home/.local/state/poetic-agents/dashboard/data.js" \
    | sed -e '1s/^window\.DASHBOARD_DATA = //' -e '$ s/;$//'
}

today="$(date -u +%Y%m%dT%H%M%SZ)"
today_day="${today:0:8}"

# --- The scan's semantics -------------------------------------------------------
a="$(new_home nodeA)"
# Three cycles today: 0.25 + 0.50 on model-a, 0.25 on model-b; the first
# carries a token and a /home path in its transcript for the redaction check.
make_cycle "$a" "${today_day}T010000Z-11" 0.25 model-a \
  "token ghp_0123456789abcdefXYZ0123 in /home/fixtureuser/secret"
make_cycle "$a" "${today_day}T020000Z-12" 0.50 model-a
make_cycle "$a" "${today_day}T030000Z-13" 0.25 model-b
# One cycle far outside COST_SCAN_DAYS: must not count.
make_cycle "$a" "20200101T000000Z-1" 99 model-old
# One torn envelope (a stage mid-write), named to sort after everything else
# so only itself is at stake in the final batch.
mkdir -p "$a/.local/state/poetic-agents/cycles/${today_day}T235959Z-99"
printf '{"partial":' > "$a/.local/state/poetic-agents/cycles/${today_day}T235959Z-99/coordinator.out"

run_publish "$a"
assert_eq "publish exits 0" "0" "$?"

data="$(data_of "$a")"
jq -e . <<<"$data" >/dev/null 2>&1
assert_eq "data.js payload is valid JSON" "0" "$?"

assert_eq "spend total honours the day cut-off and survives the torn envelope" \
  "1" "$(jq -r '.counts.spend_total_usd' <<<"$data")"
assert_eq "spend today matches" \
  "1" "$(jq -r '.counts.spend_today_usd' <<<"$data")"
assert_eq "by_model rolls up per model" \
  "0.75" "$(jq -r '.counts.by_model[] | select(.model=="model-a") | .usd' <<<"$data")"
assert_eq "by_day buckets by the cycle directory's day" \
  "1" "$(jq -r --arg d "$today_day" '.counts.by_day[] | select(.day==$d) | .usd' <<<"$data")"

raw="$(cat "$a/.local/state/poetic-agents/dashboard/data.js")"
assert_contains "token shapes are redacted" "[REDACTED-TOKEN]" "$raw"
assert_lacks "no raw token survives"        "ghp_0123456789abcdefXYZ0123" "$raw"
assert_lacks "no /home path survives"       "/home/fixtureuser" "$raw"

# --- The process budget on a long history ---------------------------------------
# 300 single-stage cycles ≈ months of history. The per-file scan forked two jq
# per envelope plus one re-parse per row (~900 forks before the detail loop
# even starts); batched, the scan is ~13 forks and the whole publish sits
# around 500 — the bound below is halfway to the old behaviour, generous to
# incidental change but far below a per-file regression.
b="$(new_home nodeB)"
i=0
while (( i < 300 )); do
  make_cycle "$b" "${today_day}T$(printf '%06d' "$i")Z-$i" 1 model-bulk
  i=$(( i + 1 ))
done

# The publisher hardens its own PATH for cron, so a shim directory would be
# bypassed. An exported function wins over any PATH lookup in the child bash
# and is inherited through env — defined inside a subshell so this script's
# own jq calls stay uninstrumented. Calls made by xargs (the batched scan)
# exec jq directly and are not counted, which only makes the bound stricter
# about what it measures: the bash-forked calls the per-file scan multiplied.
count_file="$tmp_dir/jq-count"; : > "$count_file"

start_s=$SECONDS
(
  jq() { printf 'x\n' >> "${JQ_COUNT_FILE:?}"; command jq "$@"; }
  export -f jq
  env HOME="$b" JQ_COUNT_FILE="$count_file" "$PUBLISH" --no-github >/dev/null 2>&1
)
assert_eq "bulk publish exits 0" "0" "$?"
elapsed=$(( SECONDS - start_s ))
jq_calls="$(wc -l < "$count_file")"
printf '# bulk publish: 300 cycles, %s jq invocations, %ss\n' "$jq_calls" "$elapsed"
assert_eq "bulk publish stays within its process budget (<1000 jq calls)" \
  "1" "$(( jq_calls < 1000 ))"

datb="$(data_of "$b")"
assert_eq "detail loop stays capped at MAX_CYCLES" \
  "40" "$(jq -r '.counts.cycles_shown' <<<"$datb")"
assert_eq "bulk spend total counts every envelope" \
  "300" "$(jq -r '.counts.spend_total_usd' <<<"$datb")"

# --- The launcher's exit status --------------------------------------------------
# A shortened window (LAUNCHER_WINDOW) runs one real tick and stops; five
# minutes of wall clock is the one thing a test may not spend.
env HOME="$a" LAUNCHER_WINDOW=15 "$LAUNCHER" >/dev/null 2>&1
assert_eq "launcher exits 0 on a healthy window" "0" "$?"

# And with the lock already held: every tick skips (exit 111 inside), which
# must still be a healthy window, logged as skipped.
lck="$a/.local/state/poetic-agents/dashboard.lck"
log="$a/.local/state/poetic-agents/dashboard.log"
: > "$log"
flock "$lck" sleep 30 &
holder=$!
env HOME="$a" LAUNCHER_WINDOW=15 "$LAUNCHER" >/dev/null 2>&1
rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
assert_eq "launcher exits 0 while another publish holds the lock" "0" "$rc"
assert_contains "skipped ticks are logged" "skipped: publish already running" "$(cat "$log")"

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
