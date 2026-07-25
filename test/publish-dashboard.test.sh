#!/usr/bin/env bash
#
# test/publish-dashboard.test.sh — regression tests for
# scripts/publish-dashboard.sh and scripts/publish-dashboard-launcher.sh.
#
# Four behaviours here have already failed in production and one is a scaling
# property, so they get tests rather than a careful reading:
#
#   the launcher's exit   a healthy window must end 0 — its status once came
#                         from the final tick's lock bookkeeping, so
#                         supercronic reported every successful window as a
#                         failure, every five minutes
#   the GitHub cadence    exactly one tick per window may spend API calls, and
#                         one must — the gate was once a wall-clock modulo that
#                         a cron-fired window could never satisfy, so the PR
#                         panels aged for half an hour at a time while the page
#                         around them said "data 3s ago"
#   the holed log         a container killed mid-append leaves NULs, and one NUL
#                         makes grep go quiet over the whole file — the damage
#                         is to every later read, not to the lines that were
#                         lost, so the launcher strips them and says so
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
# The newest *parseable* cycle gets an event stream entry carrying the node
# field the pipelines stamp; the publisher must surface it per cycle. (The
# torn cycle above is skipped from the detail list — its stages don't parse —
# so it cannot anchor this assertion.)
printf '{"ts":"2026-01-01T00:00:00Z","cycle":"%sT030000Z-13","node":"nodeA-test","event":"cycle-start"}\n' \
  "$today_day" > "$a/.local/state/poetic-agents/log.jsonl"

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
assert_eq "a cycle surfaces the node that produced it" "nodeA-test" \
  "$(jq -r '.cycles[0].node' <<<"$data")"

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

# --- The heartbeat's GitHub cadence -----------------------------------------------
# The gate deciding which tick fetches from GitHub is the one thing on this page
# that leaves no evidence when it breaks: a skipped fetch is designed to render
# exactly like a fresh one (it carries the last fetch forward), so a gate that
# never fires shows up only as a PR list that is quietly half an hour old. Its
# predecessor, `EPOCHSECONDS % 300 < 5`, could not fire at all under a `*/5` cron
# entry, and nothing noticed for as long as it was deployed. Hence a test of the
# cadence itself, driven through a stub Publisher (LAUNCHER_PUBLISH_CMD) so that
# asserting on a GitHub tick costs no network call.
l="$(new_home nodeL)"
gh_stamp="$l/.local/state/poetic-agents/.dashboard-github.json"
tick_log="$tmp_dir/ticks"
stub="$tmp_dir/stub-publish.sh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
# Stands in for the Publisher: records this tick's mode and, on a GitHub tick,
# writes the fetch stamp where publish-dashboard.sh writes it.
if [[ "${1:-}" == "--no-github" ]]; then
  printf 'local\n' >> "$TICK_LOG"
else
  printf 'github\n' >> "$TICK_LOG"
  printf '{}' > "$GH_STAMP"
fi
STUB
chmod +x "$stub"

run_window() {  # run_window <window-seconds> -> "<github-ticks> <total-ticks>"
  : > "$tick_log"
  env HOME="$l" LAUNCHER_WINDOW="$1" LAUNCHER_PUBLISH_CMD="$stub" \
      TICK_LOG="$tick_log" GH_STAMP="$gh_stamp" "$LAUNCHER" >/dev/null 2>&1
  printf '%s %s' "$(grep -c '^github$' "$tick_log")" "$(grep -c . "$tick_log")"
}

# Cold — no stamp at all. A 20-second window runs at least two ticks whatever
# second it starts on, which pins down both halves of the gate: it fires, and
# having fired it stops.
read -r gh_ticks all_ticks <<<"$(run_window 20)"
assert_eq "a cold window fetches from GitHub exactly once" "1" "$gh_ticks"
assert_eq "and keeps publishing locally after that fetch" "1" "$(( all_ticks >= 2 ))"
assert_contains "the GitHub tick is logged" "github: refreshing" \
  "$(cat "$l/.local/state/poetic-agents/dashboard.log")"

# Warm — the stamp the run above left behind is seconds old, so no tick in the
# window that follows may spend an API call.
read -r gh_ticks all_ticks <<<"$(run_window 15)"
assert_eq "a window following a fresh fetch makes no GitHub call" "0" "$gh_ticks"
assert_eq "and still publishes locally" "1" "$(( all_ticks >= 1 ))"

# Aged — once the stamp passes LAUNCHER_GITHUB_MAX_AGE the next tick fetches,
# wherever in the five-minute window that tick happens to fall. This is the
# property the modulo gate could not provide: it needed the window to contain a
# 300-second boundary, and a window opened by cron never does.
touch -d '10 minutes ago' "$gh_stamp"
read -r gh_ticks all_ticks <<<"$(run_window 15)"
assert_eq "a stale stamp is refetched on the next tick" "1" "$gh_ticks"

# A publish that dies before it can stamp the file must not put every following
# tick back into GitHub mode: the launcher stamps the attempt itself.
touch -d '10 minutes ago' "$gh_stamp"
crash_stub="$tmp_dir/crash-publish.sh"
cat > "$crash_stub" <<'STUB'
#!/usr/bin/env bash
# A Publisher that dies before it reaches its own stamp write.
if [[ "${1:-}" == "--no-github" ]]; then printf 'local\n' >> "$TICK_LOG"
else printf 'github\n' >> "$TICK_LOG"; fi
exit 1
STUB
chmod +x "$crash_stub"
: > "$tick_log"
env HOME="$l" LAUNCHER_WINDOW=20 LAUNCHER_PUBLISH_CMD="$crash_stub" \
    TICK_LOG="$tick_log" GH_STAMP="$gh_stamp" "$LAUNCHER" >/dev/null 2>&1
assert_eq "a publish that never stamps still only gets one GitHub tick a window" \
  "1" "$(grep -c '^github$' "$tick_log")"

# --- A log holed by an unclean stop --------------------------------------------
# A container killed mid-append leaves NULs where the last writes should be
# (TD26072301). One NUL makes the whole file binary to grep, which then stops
# printing matches for everything around it — so the damage is not the lost
# lines but every later read of the 8 MB that survived.
launcher_log="$l/.local/state/poetic-agents/dashboard.log"
{ printf 'before the hole\n'; printf '\0\0\0\0\0\0\0\0'; printf 'after the hole\n'; } > "$launcher_log"
env HOME="$l" LAUNCHER_WINDOW=15 LAUNCHER_PUBLISH_CMD="$stub" \
    TICK_LOG="$tick_log" GH_STAMP="$gh_stamp" "$LAUNCHER" >/dev/null 2>&1
repaired="$(cat "$launcher_log")"
assert_eq "the hole is gone" "0" "$(tr -cd '\0' < "$launcher_log" | wc -c)"
assert_contains "the lines around it survive (before)" "before the hole" "$repaired"
assert_contains "and after"                            "after the hole"  "$repaired"
assert_contains "the loss is recorded, not closed over" "dropped 8 NUL byte(s)" "$repaired"

# An intact log must be left exactly as it is — no rewrite, no marker.
printf 'nothing wrong here\n' > "$launcher_log"
env HOME="$l" LAUNCHER_WINDOW=15 LAUNCHER_PUBLISH_CMD="$stub" \
    TICK_LOG="$tick_log" GH_STAMP="$gh_stamp" "$LAUNCHER" >/dev/null 2>&1
assert_lacks "an intact log gets no repair marker" "repaired: dropped" "$(cat "$launcher_log")"
assert_contains "and keeps what it had" "nothing wrong here" "$(cat "$launcher_log")"

# --- The fleet view (DASHBOARD-SPEC "one fleet view from every node") -----------
# A synthetic peer materialised the way state-sync fetch would: its own state
# tree under the peers directory, with a heartbeat, a log and one cycle whose
# transcript carries a cost, a foreign path and a token — the peer's records
# must merge into every roll-up AND pass through the same redaction as our own.
f="$(new_home nodeF)"
peer="$f/.cache/poetic-agents/workspaces/.agent-ops-peers/peer1"
mkdir -p "$peer/cycles/${today_day}T040000Z-peer1-77" "$f/.local/state/poetic-agents/fleet-cache"
printf '{"node":"peer1","role":"active","ts":"%s","last_cycle":"%sT040000Z-peer1-77"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$today_day" > "$peer/heartbeat.json"
printf '{"ts":"2026-01-01T04:00:00Z","cycle":"%sT040000Z-peer1-77","node":"peer1","event":"cycle-start"}\n' \
  "$today_day" > "$peer/log.jsonl"
printf '{"type":"result","subtype":"success","total_cost_usd":0.25,"duration_ms":5,"num_turns":1,"is_error":false,"modelUsage":{"model-p":{}},"result":"peer secret ghp_9876543210abcdefXYZ9876 in /home/peeruser/thing"}' \
  > "$peer/cycles/${today_day}T040000Z-peer1-77/coordinator.out"
make_cycle "$f" "${today_day}T050000Z-self-55" 0.50 model-a
printf '{"ts":"2026-01-01T05:00:00Z","cycle":"%sT050000Z-self-55","node":"nodeF-self","event":"cycle-start"}\n' \
  "$today_day" > "$f/.local/state/poetic-agents/log.jsonl"
# A cached fleet limit flag (requirement 2.1): shown without any GitHub call.
printf '{"resume_at":"2031-01-01T00:00:00Z","class":"monthly-spend","needs_human":true,"node":"peer1","ts":"2026-01-01T04:01:00Z"}' \
  > "$f/.local/state/poetic-agents/fleet-cache/limit.json"

run_publish "$f" NODE_NAME=nodeF-self
assert_eq "a fleet publish exits 0" "0" "$?"
fdata="$(data_of "$f")"

assert_eq "the page names its own node" "nodeF-self" "$(jq -r '.node' <<<"$fdata")"
assert_eq "fleet.nodes carries self and the peer" "2" "$(jq '.fleet.nodes | length' <<<"$fdata")"
assert_eq "self is listed first and marked" "true" "$(jq -r '.fleet.nodes[0].self' <<<"$fdata")"
assert_eq "the peer's role comes from its heartbeat" "active" \
  "$(jq -r '.fleet.nodes[] | select(.node=="peer1") | .role' <<<"$fdata")"
assert_eq "a fresh heartbeat is not stale" "false" \
  "$(jq -r '.fleet.nodes[] | select(.node=="peer1") | .stale' <<<"$fdata")"
assert_eq "the peer's cycle merges into the fleet list" "1" \
  "$(jq '[.cycles[] | select(.node=="peer1")] | length' <<<"$fdata")"
assert_eq "and renders with its transcript's cost, from the peer's own directory" "0.25" \
  "$(jq -r '.cycles[] | select(.node=="peer1") | .stages.coordinator.cost_usd' <<<"$fdata")"
assert_eq "spend roll-ups are fleet-wide (one shared account)" "0.75" \
  "$(jq -r '.counts.spend_today_usd' <<<"$fdata")"
assert_eq "the cached fleet limit flag is surfaced" "2031-01-01T00:00:00Z" \
  "$(jq -r '.fleet.flags.limit.resume_at' <<<"$fdata")"
assert_eq "claims default to empty without a GitHub tick" "[]" \
  "$(jq -c '.fleet.claims' <<<"$fdata")"
raw_fleet="$(cat "$f/.local/state/poetic-agents/dashboard/data.js")"
assert_lacks "a peer's token is redacted like our own" "ghp_9876543210abcdefXYZ9876" "$raw_fleet"
assert_lacks "a peer's home path is redacted like our own" "/home/peeruser" "$raw_fleet"

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
