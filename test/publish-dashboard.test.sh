#!/usr/bin/env bash
#
# test/publish-dashboard.test.sh — regression tests for
# scripts/publish-dashboard.sh and scripts/publish-dashboard-launcher.sh.
#
# Four behaviours here have already failed in production, one is a scaling
# property, and one is an invariant the detail window's jq port could silently
# break, so they get tests rather than a careful reading:
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
#   the transcript cap    TRANSCRIPT_CAP is a byte budget; jq's own string
#                         slicing counts codepoints, so a multi-byte-heavy
#                         transcript could blow well past the cap and grow
#                         data.js — exactly the size concern this budget exists
#                         for
#
# No network and no GitHub: every publish runs --no-github against a
# synthesised state dir (a throwaway HOME, since config.json's state_dir is
# ~-relative). No test framework is used (none exists elsewhere in this
# repo). Run directly:
#
#   ./test/publish-dashboard.test.sh
#
# Exit status is 0 iff every assertion passed.

# As in test/model-id.test.sh: version 0.10 of the linter reads two helpers here
# as unreachable, because the only calls to them are inside command
# substitutions.
# shellcheck disable=SC2317

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

# A pid nothing holds, in *this* namespace — the point of the lock-liveness
# tests below is that a foreign-host lock must not be judged by `kill -0`
# even when it would (wrongly) say "dead" here.
dead_pid() {
  local p
  for (( p = $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768) - 1; p > 300; p-- )); do
    kill -0 "$p" 2>/dev/null || { printf '%s' "$p"; return 0; }
  done
  printf '4194303'
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

# One stage of one cycle, for the cost roll-ups. `make_cycle` above is the
# single-stage shorthand the older assertions are written against; this is the
# same envelope with the actor named, since which agent spent it is now a
# dimension of its own.
make_stage() {  # make_stage <home> <cid> <stage> <cost> <model>
  local d="$1/.local/state/poetic-agents/cycles/$2"
  mkdir -p "$d"
  printf '{"type":"result","subtype":"success","total_cost_usd":%s,"duration_ms":5,"num_turns":1,"is_error":false,"modelUsage":{"%s":{}},"result":"ok"}' \
    "$4" "$5" > "$d/$3.out"
}

# The weekly project-review pipeline's record: same envelope, a sibling
# directory, and one transcript per repository reviewed.
make_review() {  # make_review <home> <review-id> <repo-slug> <cost> <model>
  local d="$1/.local/state/poetic-agents/reviews/$2"
  mkdir -p "$d"
  printf '{"type":"result","subtype":"success","total_cost_usd":%s,"duration_ms":5,"num_turns":1,"is_error":false,"modelUsage":{"%s":{}},"result":"ok"}' \
    "$4" "$5" > "$d/reviewer-${3//\//_}.out"
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
assert_eq "a torn envelope still drops its whole cycle" "0" \
  "$(jq -r --arg d "$today_day" '[.cycles[] | select(.id == ($d + "T235959Z-99"))] | length' <<<"$data")"

# recent_costs backs the dashboard's "today (local)"/"last 24h" toggle (#186):
# each row needs the cycle's own instant, not just its GMT day.
assert_eq "recent_costs carries one row per today cycle" \
  "3" "$(jq -r '.counts.recent_costs | length' <<<"$data")"
assert_eq "recent_costs sums to the same total as the GMT day it came from" \
  "1" "$(jq -r '[.counts.recent_costs[].cost] | add' <<<"$data")"
assert_eq "every recent_costs row carries a real ISO instant" "3" \
  "$(jq -r '[.counts.recent_costs[].ts | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))] | length' <<<"$data")"
assert_eq "the cycle far outside COST_SCAN_DAYS is excluded from recent_costs too" \
  "0" "$(jq -r '[.counts.recent_costs[].ts | select(startswith("2020"))] | length' <<<"$data")"

raw="$(cat "$a/.local/state/poetic-agents/dashboard/data.js")"
assert_contains "token shapes are redacted" "[REDACTED-TOKEN]" "$raw"
assert_lacks "no raw token survives"        "ghp_0123456789abcdefXYZ0123" "$raw"
assert_lacks "no /home path survives"       "/home/fixtureuser" "$raw"

# A cycle directory that doesn't parse as a `YYYYMMDDTHHMMSSZ-…` id (a
# hand-placed or future-format one) must not corrupt or invent a timestamp —
# it still counts toward the totals `day` already covered, and drops out of
# `recent_costs` on `ts == null` rather than a guess.
j="$(new_home nodeJ)"
make_cycle "$j" "manual-import-1" 0.3 model-a
run_publish "$j"
jdata="$(data_of "$j")"
assert_eq "a non-timestamp cycle directory still counts toward the total" \
  "0.3" "$(jq -r '.counts.spend_total_usd' <<<"$jdata")"
assert_eq "but is excluded from recent_costs rather than guessed at" \
  "0" "$(jq -r '.counts.recent_costs | length' <<<"$jdata")"

# --- The transcript cap is bytes, not codepoints ----------------------------------
# TRANSCRIPT_CAP (40000) is a byte budget. 20000 repeats of a 3-byte codepoint
# is 60000 bytes — comfortably over the cap either way a slice could count —
# and floor(40000/3) = 13333 whole codepoints (39999 bytes) is what a
# byte-honouring truncation keeps; a codepoint-counting slice (jq's own
# `.[0:$cap]`, used naively) would instead keep 40000 codepoints, 120000 bytes,
# three times the budget.
t="$(new_home nodeT)"
multibyte_result="$(printf '\xe2\x82\xac%.0s' $(seq 1 20000))"
make_cycle "$t" "${today_day}T090000Z-41" 0.25 model-a "$multibyte_result"
run_publish "$t"
tdata="$(data_of "$t")"
result_field="$(jq -j '.cycles[0].stages.coordinator.result' <<<"$tdata")"
assert_eq "a multi-byte-heavy result is truncated to the byte cap" \
  "39999" "$(printf '%s' "$result_field" | wc -c)"
assert_eq "and to the whole-codepoint count that implies" \
  "13333" "$(printf '%s' "$result_field" | wc -m)"

# --- A well-formed empty result does not drop its cycle (TD26072802) --------------
# A stage that ran and reported a genuinely empty `result` is not a torn
# envelope: the envelope itself parses fine, only the text inside it is
# blank. That must render like any other unparseable-text stage — status
# null — rather than vanishing the whole cycle the way a torn envelope does
# (asserted against node "a" above).
e="$(new_home nodeE)"
make_cycle "$e" "${today_day}T100000Z-51" 0.25 model-a ""
run_publish "$e"
edata="$(data_of "$e")"
assert_eq "a well-formed envelope with an empty result still renders its cycle" \
  "1" "$(jq -r '.cycles | length' <<<"$edata")"
assert_eq "the empty stage renders with a null status, not a dropped row" \
  "null" "$(jq -r '.cycles[0].stages.coordinator.status' <<<"$edata")"

# --- Only cycles are cycles ------------------------------------------------------
# A record no cycle produced — the hand-appended kind, which uses the
# `cycle: "manual"` sentinel of implementation spec 33 — must not become a row
# in Recent cycles. It has no `cycle-start`, no `cycle-end` and no transcript
# directory, so it renders as a cycle that started whenever the first hand-edit
# was made and can never end; and because the id sort is lexical, "manual"
# outranks every digit, so the phantom pins itself to the top of the table and
# holds a MAX_CYCLES slot for good. Two hand-appended records a fortnight
# apart, so a regression that groups them shows up as one row rather than two.
# The events themselves must survive in the log tail — dropping the row is a
# statement about what a cycle is, not about which records are worth keeping.
c="$(new_home nodeC)"
make_cycle "$c" "${today_day}T080000Z-31" 0.25 model-a
{
  printf '{"ts":"2026-07-12T02:40:00Z","cycle":"manual","node":"nodeC-self","event":"unvoided","item":"review-2026-07-11-R-02"}\n'
  printf '{"ts":"2026-07-26T02:29:36Z","cycle":"manual","node":"nodeC-peer","event":"limit-hit","resume_at":"1970-01-01T00:00:00Z","class":"monthly","reset_known":true}\n'
  printf '{"ts":"2026-07-26T08:00:00Z","cycle":"%sT080000Z-31","node":"nodeC-self","event":"cycle-start"}\n' "$today_day"
  printf '{"ts":"2026-07-26T08:10:00Z","cycle":"%sT080000Z-31","node":"nodeC-self","event":"cycle-end","exit_code":0}\n' "$today_day"
} > "$c/.local/state/poetic-agents/log.jsonl"

run_publish "$c" NODE_NAME=nodeC-self
cdata="$(data_of "$c")"
assert_eq "a hand-appended record raises no cycle row" "0" \
  "$(jq '[.cycles[] | select(.id == "manual")] | length' <<<"$cdata")"
assert_eq "the real cycle is the only one, and is at the top" \
  "${today_day}T080000Z-31" "$(jq -r '.cycles[0].id' <<<"$cdata")"
assert_eq "and the phantom takes none of the MAX_CYCLES budget" "1" \
  "$(jq -r '.counts.cycles_shown' <<<"$cdata")"
assert_eq "while both hand-appended events stay in the log tail" "2" \
  "$(jq '[.log_tail[] | select(.cycle == "manual")] | length' <<<"$cdata")"

# --- No-op ticks are counted, not listed (issue #271) -----------------------------
# Under the */15 cadence most firings are the stand-down short-circuit
# (`cycle-start` → `stand-down` → `cycle-end`) or the lock-held skip
# (`cycle-start` → `cycle-skipped` → `cycle-end`), and at one MAX_CYCLES slot
# each they pushed the substantive history off the page. More no-op ticks
# than the whole window holds, every one newer than the real work, must leave
# the substantive cycles listed and surface only the O(1) `noop_ticks`
# aggregate — total, split by kind, the newest tick's timestamp. The match is
# the exact event shape, so a stand-down carrying more than the shape stays a
# row: here, one that never logged `cycle-end` (a killed node, not a tick).
n="$(new_home nodeN)"
n_worked="${today_day}T010000Z-nodeN-1"
n_none="${today_day}T020000Z-nodeN-2"
n_kill="${today_day}T023000Z-nodeN-3"
{
  printf '{"ts":"2026-08-01T01:00:00Z","cycle":"%s","node":"nodeN","event":"cycle-start"}\n' "$n_worked"
  printf '{"ts":"2026-08-01T01:00:01Z","cycle":"%s","node":"nodeN","event":"selection","repo":"o/a","item":"1","source":"tech-debt","title":"t"}\n' "$n_worked"
  printf '{"ts":"2026-08-01T01:00:02Z","cycle":"%s","node":"nodeN","event":"pr-raised","repo":"o/a","pr_url":"https://github.com/o/a/pull/7"}\n' "$n_worked"
  printf '{"ts":"2026-08-01T01:00:03Z","cycle":"%s","node":"nodeN","event":"cycle-end","exit_code":0}\n' "$n_worked"
  printf '{"ts":"2026-08-01T02:00:00Z","cycle":"%s","node":"nodeN","event":"cycle-start"}\n' "$n_none"
  printf '{"ts":"2026-08-01T02:00:01Z","cycle":"%s","node":"nodeN","event":"none-selected","reason":"nothing to do"}\n' "$n_none"
  printf '{"ts":"2026-08-01T02:00:02Z","cycle":"%s","node":"nodeN","event":"cycle-end","exit_code":0}\n' "$n_none"
  printf '{"ts":"2026-08-01T02:30:00Z","cycle":"%s","node":"nodeN","event":"cycle-start"}\n' "$n_kill"
  printf '{"ts":"2026-08-01T02:30:01Z","cycle":"%s","node":"nodeN","event":"stand-down","reason":"disabled: maintenance"}\n' "$n_kill"
  i=0
  while (( i < 42 )); do
    if (( i % 2 == 0 )); then noop_ev="stand-down"; else noop_ev="cycle-skipped"; fi
    printf '{"ts":"2026-08-01T12:%02d:00Z","cycle":"%sT12%02d00Z-nodeN-t%d","node":"nodeN","event":"cycle-start"}\n' "$i" "$today_day" "$i" "$i"
    printf '{"ts":"2026-08-01T12:%02d:01Z","cycle":"%sT12%02d00Z-nodeN-t%d","node":"nodeN","event":"%s","reason":"r"}\n' "$i" "$today_day" "$i" "$i" "$noop_ev"
    printf '{"ts":"2026-08-01T12:%02d:02Z","cycle":"%sT12%02d00Z-nodeN-t%d","node":"nodeN","event":"cycle-end","exit_code":0}\n' "$i" "$today_day" "$i" "$i"
    i=$(( i + 1 ))
  done
} > "$n/.local/state/poetic-agents/log.jsonl"
run_publish "$n" NODE_NAME=nodeN
ndata="$(data_of "$n")"
assert_eq "42 newer no-op ticks leave every substantive cycle listed" "3" \
  "$(jq '.cycles | length' <<<"$ndata")"
assert_eq "no lock-held skip holds a detail row" "0" \
  "$(jq '[.cycles[] | select(.outcome == "skipped")] | length' <<<"$ndata")"
assert_eq "the one stand-down row left is the unfinished one" "$n_kill" \
  "$(jq -r '[.cycles[] | select(.outcome == "stand-down")] | .[0].id' <<<"$ndata")"
assert_eq "which never logged cycle-end, so it is not a tick" "null" \
  "$(jq -r '[.cycles[] | select(.outcome == "stand-down")] | .[0].ended_at' <<<"$ndata")"
assert_eq "the worked cycle keeps its slot under the flood" "1" \
  "$(jq --arg c "$n_worked" '[.cycles[] | select(.id == $c)] | length' <<<"$ndata")"
assert_eq "and so does the none-selected one — a Co-Ordinator verdict, not a no-op" "1" \
  "$(jq --arg c "$n_none" '[.cycles[] | select(.id == $c)] | length' <<<"$ndata")"
assert_eq "the aggregate counts every filtered tick" "42" \
  "$(jq -r '.noop_ticks.total' <<<"$ndata")"
assert_eq "split by kind: the stand-down short-circuits" "21" \
  "$(jq -r '.noop_ticks.standdown' <<<"$ndata")"
assert_eq "and the lock-held skips" "21" \
  "$(jq -r '.noop_ticks.skipped' <<<"$ndata")"
assert_eq "carrying the newest tick's own timestamp" "2026-08-01T12:41:02Z" \
  "$(jq -r '.noop_ticks.last_ts' <<<"$ndata")"

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
# A container killed mid-append leaves NULs where the last writes should be.
# One NUL makes the whole file binary to grep, which then stops
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

# --- The cron panel survives a rotation (TD26072501, spec requirement 2.6) ------
# scripts/rotate-logs.sh renames cron.log to cron.log.1 once it grows past
# log_retained_bytes, leaving a fresh, short cron.log behind. The panel must
# not go blank for the tick that lands between rotation and the log
# regaining 40 lines of its own — it reads cron.log.1 too, oldest first.
p="$(new_home nodeP)"
cron_log="$p/.local/state/poetic-agents/cron.log"
printf 'old-line-%d\n' 1 2 3 > "$cron_log.1"
printf 'new-line-%d\n' 1 2 > "$cron_log"
run_publish "$p"
pdata="$(data_of "$p")"
assert_eq "the panel carries every line, old and new" "5" \
  "$(jq '.cron_tail | length' <<<"$pdata")"
assert_eq "the oldest rotated line comes first" "old-line-1" \
  "$(jq -r '.cron_tail[0]' <<<"$pdata")"
assert_eq "the newest live line comes last" "new-line-2" \
  "$(jq -r '.cron_tail[-1]' <<<"$pdata")"

# A live file that already fills the 40-line window on its own needs nothing
# from .1 — the rotated generation must not leak into a panel that doesn't
# need it.
q="$(new_home nodeQ)"
cron_log_q="$q/.local/state/poetic-agents/cron.log"
printf 'stale-rotated-line\n' > "$cron_log_q.1"
for i in $(seq 1 45); do printf 'live-line-%d\n' "$i"; done > "$cron_log_q"
run_publish "$q"
qdata="$(data_of "$q")"
assert_eq "the panel stays capped at 40" "40" "$(jq '.cron_tail | length' <<<"$qdata")"
assert_lacks "and a rotated line the live file doesn't need is left out" \
  "stale-rotated-line" "$(jq -c '.cron_tail' <<<"$qdata")"

# --- The fleet view (DASHBOARD-SPEC "one fleet view from every node") -----------
# A synthetic peer materialised the way state-sync fetch would: its own state
# tree under the peers directory, with a heartbeat, a log and one cycle whose
# transcript carries a cost, a foreign path and a token — the peer's records
# must merge into every roll-up AND pass through the same redaction as our own.
f="$(new_home nodeF)"
peer="$f/.cache/poetic-agents/workspaces/.agent-ops-peers/peer1"
peer2="$f/.cache/poetic-agents/workspaces/.agent-ops-peers/peer2"
mkdir -p "$peer/cycles/${today_day}T040000Z-peer1-77" "$peer2" "$f/.local/state/poetic-agents/fleet-cache"
printf '{"node":"peer1","role":"active","ts":"%s","last_cycle":"%sT040000Z-peer1-77"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$today_day" > "$peer/heartbeat.json"
# peer1 is mid-cycle: a `cycle-start` with no `cycle-end`, a coordinator stage
# that finished, an implementor stage that has not, and the selection between
# them. That is the whole of what a peer publishes about what it is doing —
# it publishes no lock — so it is the whole of what its card can be built from.
{
  printf '{"ts":"2026-01-01T04:00:00Z","cycle":"%sT040000Z-peer1-77","node":"peer1","event":"cycle-start"}\n' "$today_day"
  printf '{"ts":"2026-01-01T04:00:01Z","cycle":"%sT040000Z-peer1-77","node":"peer1","event":"stage-start","stage":"coordinator"}\n' "$today_day"
  printf '{"ts":"2026-01-01T04:00:02Z","cycle":"%sT040000Z-peer1-77","node":"peer1","event":"stage-end","stage":"coordinator","exit_code":0}\n' "$today_day"
  printf '{"ts":"2026-01-01T04:00:03Z","cycle":"%sT040000Z-peer1-77","node":"peer1","event":"selection","repo":"Poetic-Poems/poetic","item":"TD26071401","source":"tech-debt","title":"share the limit detector"}\n' "$today_day"
  printf '{"ts":"2026-01-01T04:00:04Z","cycle":"%sT040000Z-peer1-77","node":"peer1","event":"stage-start","stage":"implementor"}\n' "$today_day"
} > "$peer/log.jsonl"
printf '{"type":"result","subtype":"success","total_cost_usd":0.25,"duration_ms":5,"num_turns":1,"is_error":false,"modelUsage":{"model-p":{}},"result":"peer secret ghp_9876543210abcdefXYZ9876 in /home/peeruser/thing"}' \
  > "$peer/cycles/${today_day}T040000Z-peer1-77/coordinator.out"
# peer2 is between cycles: its last one ran to `cycle-end`.
printf '{"node":"peer2","role":"active","ts":"%s","last_cycle":"%sT033000Z-peer2-88"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$today_day" > "$peer2/heartbeat.json"
{
  printf '{"ts":"2026-01-01T03:30:00Z","cycle":"%sT033000Z-peer2-88","node":"peer2","event":"cycle-start"}\n' "$today_day"
  printf '{"ts":"2026-01-01T03:30:01Z","cycle":"%sT033000Z-peer2-88","node":"peer2","event":"selection","repo":"Poetic-Poems/poetic-fiddle","item":"issue-9","source":"issues","title":"an issue"}\n' "$today_day"
  printf '{"ts":"2026-01-01T03:40:00Z","cycle":"%sT033000Z-peer2-88","node":"peer2","event":"cycle-end","exit_code":0}\n' "$today_day"
} > "$peer2/log.jsonl"
# This node holds a live lock (this test process is the pid), so its own row is
# read from the lock rather than derived. The `-skipped` cycle after it is the
# case that makes the distinction load-bearing: a tick that starts, finds the
# lock held and ends is the newest `cycle-start` on this node while the cycle
# actually holding the lock is still running.
self_cid="${today_day}T050000Z-nodeF-self-$$"
make_cycle "$f" "$self_cid" 0.50 model-a
{
  printf '{"ts":"2026-01-01T05:00:00Z","cycle":"%s","node":"nodeF-self","event":"cycle-start"}\n' "$self_cid"
  printf '{"ts":"2026-01-01T05:00:01Z","cycle":"%s","node":"nodeF-self","event":"stage-start","stage":"coordinator"}\n' "$self_cid"
  printf '{"ts":"2026-01-01T05:00:02Z","cycle":"%s","node":"nodeF-self","event":"stage-end","stage":"coordinator","exit_code":0}\n' "$self_cid"
  printf '{"ts":"2026-01-01T05:00:03Z","cycle":"%s","node":"nodeF-self","event":"selection","repo":"Poetic-Poems/poetic","item":"TD26072004","source":"tech-debt","title":"bound the local history"}\n' "$self_cid"
  printf '{"ts":"2026-01-01T05:00:04Z","cycle":"%s","node":"nodeF-self","event":"stage-start","stage":"implementor"}\n' "$self_cid"
  printf '{"ts":"2026-01-01T05:10:00Z","cycle":"%sT051000Z-nodeF-self-skipped","node":"nodeF-self","event":"cycle-start"}\n' "$today_day"
  printf '{"ts":"2026-01-01T05:10:01Z","cycle":"%sT051000Z-nodeF-self-skipped","node":"nodeF-self","event":"cycle-skipped","detail":"lock held"}\n' "$today_day"
  printf '{"ts":"2026-01-01T05:10:02Z","cycle":"%sT051000Z-nodeF-self-skipped","node":"nodeF-self","event":"cycle-end","exit_code":0}\n' "$today_day"
} > "$f/.local/state/poetic-agents/log.jsonl"
printf '{"pid":%s,"started_at":"2026-01-01T05:00:00Z"}' "$$" > "$f/.local/state/poetic-agents/lock.json"
# A cached fleet limit flag (requirement 2.1): shown without any GitHub call.
# Deliberately in the pre-`reset_known` shape, carrying the superseded
# `needs_human`: a node upgrades before its peers do, and a flag written by
# one still on the previous release must render rather than break.
printf '{"resume_at":"2031-01-01T00:00:00Z","class":"monthly-spend","needs_human":true,"node":"peer1","ts":"2026-01-01T04:01:00Z"}' \
  > "$f/.local/state/poetic-agents/fleet-cache/limit.json"

run_publish "$f" NODE_NAME=nodeF-self
assert_eq "a fleet publish exits 0" "0" "$?"
fdata="$(data_of "$f")"
node_live() { jq -r --arg n "$1" --arg k "$2" '.fleet.nodes[] | select(.node==$n) | .live[$k]' <<<"$fdata"; }

assert_eq "the page names its own node" "nodeF-self" "$(jq -r '.node' <<<"$fdata")"
assert_eq "fleet.nodes carries self and both peers" "3" "$(jq '.fleet.nodes | length' <<<"$fdata")"
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

# --- What each node is doing (DASHBOARD-SPEC "the live state is per node") -------
# The header's old single live readout is now one per node, so every node needs
# its own answer — and a peer's has to come from its published log, since a peer
# publishes no lock.
assert_eq "a peer mid-cycle is reported running" "true" "$(node_live peer1 running)"
assert_eq "from its own cycle, not the fleet's newest" "${today_day}T040000Z-peer1-77" \
  "$(node_live peer1 cycle)"
assert_eq "its live stage is the stage-start with no stage-end" "implementor" \
  "$(node_live peer1 stage)"
# The clock the page holds that stage against its own timeout: the *live*
# stage's start, not the cycle's and not the finished coordinator's. Getting
# this wrong in either direction defeats the rule — the cycle's start would
# flag a healthy stage that followed a long one, and a finished stage's would
# never flag anything.
assert_eq "and it is dated by that stage-start, not by the cycle's" "2026-01-01T04:00:04Z" \
  "$(node_live peer1 stage_since)"
assert_eq "its work carries the item the Co-Ordinator selected" "TD26071401" \
  "$(node_live peer1 item)"
assert_eq "and the source, so the card can tag it like the cycles column" "tech-debt" \
  "$(node_live peer1 source)"
assert_eq "and the repo it is working in" "Poetic-Poems/poetic" "$(node_live peer1 repo)"
assert_eq "a peer whose cycle ended is idle" "false" "$(node_live peer2 running)"
assert_eq "and reports when it ended" "2026-01-01T03:40:00Z" "$(node_live peer2 ended_at)"
assert_eq "each node answers for itself, not for the fleet" "issue-9" "$(node_live peer2 item)"

assert_eq "a live lock makes this node running" "true" "$(jq -r '.status.running' <<<"$fdata")"
assert_eq "and its row says so too" "true" "$(node_live nodeF-self running)"
assert_eq "our own row is the lock's cycle, not the newest cycle-start" "$self_cid" \
  "$(node_live nodeF-self cycle)"
assert_eq "so a skipped tick cannot masquerade as what we are doing" "implementor" \
  "$(node_live nodeF-self stage)"
assert_eq "our own row is dated by its live stage too" "2026-01-01T05:00:04Z" \
  "$(node_live nodeF-self stage_since)"
assert_eq "and the lock's own reading of it agrees" "2026-01-01T05:00:04Z" \
  "$(jq -r '.status.current.stage_since' <<<"$fdata")"
# The cap the page measures a live stage against has to reach it, or the rule
# is inert however good the timestamps are. Since requirement 4f every stage
# has its own, announced on its `stage-start`, so what must arrive is that
# number on the live row — and, for a row whose event predates the
# announcement, the fleet-wide fallback beside it.
assert_eq "the live row carries the cap its stage was actually given" "true" \
  "$(jq -r '(.status.current | has("stage_backstop_min"))' <<<"$fdata")"
assert_eq "a peer row carries it too, which is the only clock its card has" "true" \
  "$(jq -r '[.fleet.nodes[] | select(.live != null) | (.live | has("stage_backstop_min"))] | all' <<<"$fdata")"
assert_eq "and the fleet-wide fallback per actor reaches the page" "object" \
  "$(jq -r '.config.stage_backstops | type' <<<"$fdata")"
# `lock_stale_after` is no longer a configured constant but a derivation over
# the backstops in force; the page still reads it under that name, so it has
# to arrive as a number whether or not the configuration mentions it.
assert_eq "the derived lock threshold reaches the page" "true" \
  "$(jq -r '(.config.lock_stale_after // 0) > 0' <<<"$fdata")"
assert_eq "and the work is the one the lock's cycle selected" "TD26072004" \
  "$(node_live nodeF-self item)"
# peer2's, not nodeF-self's own newer `-skipped` tick: a no-op tick holds no
# detail slot (#271), so it cannot be the fleet's last cycle either.
assert_eq "the fleet's newest cycle names the node that ran it" "peer2" \
  "$(jq -r '.status.last_cycle.node' <<<"$fdata")"

# With the lock gone, our own row falls back to the same derivation the peers
# use — and must then report the cycle as over rather than eternally running.
rm -f "$f/.local/state/poetic-agents/lock.json"
run_publish "$f" NODE_NAME=nodeF-self
fdata="$(data_of "$f")"
assert_eq "no lock, no running claim" "false" "$(jq -r '.status.running' <<<"$fdata")"
assert_eq "and the node's own row agrees" "false" "$(node_live nodeF-self running)"
assert_eq "falling back to its newest cycle" "${today_day}T051000Z-nodeF-self-skipped" \
  "$(node_live nodeF-self cycle)"

# `status.last_cycle` is the newest cycle that FINISHED, not the newest that
# started. Both readers want a completed one — the headers date it by
# `ended_at` and the node cards badge it by `outcome` — so a cycle-start with
# no end must not take the slot: it would date the fleet's last activity with a
# null (rendered "—") and label it with the outcome ladder's floor. Here the
# newest cycle in the union is peer1's, which is mid-flight, so the field must
# skip past it — and past the `-skipped` no-op tick, which holds no detail row
# since #271 — to the newest substantive one that logged `cycle-end`.
printf '{"ts":"2026-01-01T06:00:00Z","cycle":"%sT060000Z-peer1-99","node":"peer1","event":"cycle-start"}\n' \
  "$today_day" >> "$peer/log.jsonl"
run_publish "$f" NODE_NAME=nodeF-self
fdata="$(data_of "$f")"
assert_eq "the newest cycle overall is the unfinished one" "${today_day}T060000Z-peer1-99" \
  "$(jq -r '.cycles[0].id' <<<"$fdata")"
assert_eq "but last_cycle skips it for the newest substantive one that ended" \
  "${today_day}T033000Z-peer2-88" "$(jq -r '.status.last_cycle.id' <<<"$fdata")"
assert_eq "so the field it is dated by is never null" "2026-01-01T03:40:00Z" \
  "$(jq -r '.status.last_cycle.ended_at' <<<"$fdata")"
assert_eq "and the outcome is a real verdict, not the ladder's floor" "selected" \
  "$(jq -r '.status.last_cycle.outcome' <<<"$fdata")"
assert_eq "while the skipped tick itself is counted, not listed (#271)" "1" \
  "$(jq -r '.noop_ticks.skipped' <<<"$fdata")"

# A node that has never run a cycle has no live state at all — null, not a
# fabricated idle record. (`live` is absent from the page's reading of it.)
g="$(new_home nodeG)"
run_publish "$g" NODE_NAME=nodeG-self
assert_eq "a node with no history reports no live state" "null" \
  "$(jq -r '.fleet.nodes[0].live' <<<"$(data_of "$g")")"

# --- Lock-liveness is host-aware (TD-PPagop-26080101) -----------------------------
# The dashboard shares the scheduler's state volume but never its PID
# namespace (deploy/docker/compose.yaml: dashboard and scheduler are separate
# containers), so a bare `kill -0` against `lock.json`'s pid answers a
# question about an *unrelated* process in the dashboard's own namespace, in
# both directions — the same confusion #130 fixed in the watchtower
# pre-update hook and TD-PPagop-26072901 fixed in both cycle scripts'
# `acquire_lock`. `host` names the container that wrote the lock: only when
# it matches ours (or is absent, predating the stamp) can `kill -0` answer for
# it; any other lock is unanswerable from here and must read as not alive,
# never falling back to `kill -0` regardless of what it would say.
h="$(new_home nodeH)"
lock_of_h="$h/.local/state/poetic-agents/lock.json"
write_lock() {  # write_lock FILE PID HOST
  local f="$1" pid="$2" host="$3"
  jq -n --argjson pid "$pid" \
        --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg host "$host" \
        '{pid: $pid, started_at: $started_at, host: $host}' > "$f"
}

# Our own container's lock: a pid is answerable by `kill -0` exactly here.
write_lock "$lock_of_h" "$$" "containerA"
run_publish "$h" NODE_NAME=nodeH-self HOSTNAME=containerA
assert_eq "our own container's live pid is read as running" "true" \
  "$(jq -r '.status.running' <<<"$(data_of "$h")")"

write_lock "$lock_of_h" "$(dead_pid)" "containerA"
run_publish "$h" NODE_NAME=nodeH-self HOSTNAME=containerA
assert_eq "and a dead one in our own container is not" "false" \
  "$(jq -r '.status.running' <<<"$(data_of "$h")")"

# The regression itself: a lock written by another container, naming a pid
# that happens to be alive in *this* namespace too ($$, this test process).
# A bare `kill -0` would say "running" — coincidence, not evidence, since the
# pid is meaningless outside the namespace that minted it — and that false
# positive is exactly what the host check must prevent.
write_lock "$lock_of_h" "$$" "containerB"
run_publish "$h" NODE_NAME=nodeH-self HOSTNAME=containerA
assert_eq "a foreign lock is not running, however alive its pid looks here" "false" \
  "$(jq -r '.status.running' <<<"$(data_of "$h")")"

# The reverse hazard (pid 55423 on 2026-07-28): a foreign lock whose pid
# reads as dead here must not be trusted either — the writer's namespace is
# simply unanswerable from this one, in both directions.
write_lock "$lock_of_h" "$(dead_pid)" "containerB"
run_publish "$h" NODE_NAME=nodeH-self HOSTNAME=containerA
assert_eq "and a foreign lock with a locally-dead pid reads the same way" "false" \
  "$(jq -r '.status.running' <<<"$(data_of "$h")")"

# An unstamped lock (written before `host` existed) cannot name a foreign
# container, so it falls back to `kill -0` like our own.
jq -n --argjson pid "$$" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{pid: $pid, started_at: $started_at}' > "$lock_of_h"
run_publish "$h" NODE_NAME=nodeH-self HOSTNAME=containerA
assert_eq "an unstamped lock's live pid still reads as running" "true" \
  "$(jq -r '.status.running' <<<"$(data_of "$h")")"
rm -f "$lock_of_h"

# --- Cost by actor, and the review pipeline's share of it ------------------------
# Which agent the money went on is the cut an operator can act on — the model
# and the day are not things anyone chooses. It is derived from the transcript's
# own filename, which is also why the weekly project review had to join the scan
# to make it: its records live in `reviews/`, so while that directory went
# unread the Project Reviewer was both the most expensive actor per run and the
# only one invisible, and every total on the page was quietly partial.
k="$(new_home nodeK)"
make_stage "$k" "${today_day}T060000Z-21" coordinator 0.25 model-a
make_stage "$k" "${today_day}T060000Z-21" implementor 2.00 model-b
make_stage "$k" "${today_day}T060000Z-21" reviewer    0.75 model-b
make_stage "$k" "${today_day}T070000Z-22" enabler     0.50 model-a
make_review "$k" "${today_day}T080000Z-nodeK-31" Poetic-Poems/poetic 4.00 model-b
run_publish "$k"
kdata="$(data_of "$k")"
# `+ 0` is not decoration: jq 1.7 round-trips a number it never operates on as
# the literal it read, so a single-transcript group prints "2.00" where 1.6
# prints "2" — and the suite runs under both (the laptop's jq and the image's).
# Forcing the arithmetic canonicalises it, so the assertion compares values
# rather than the two jqs' formatting.
actor_usd() { jq -r --arg a "$1" '.counts.by_actor[] | select(.actor==$a) | .usd + 0' <<<"$kdata"; }

assert_eq "each stage's cost is attributed to its own actor" "2" "$(actor_usd implementor)"
assert_eq "including the Enabler, which no cycle total counts" "0.5" "$(actor_usd enabler)"
# The one attribution that is not the filename verbatim: a review's transcript
# is `reviewer-<repo>.out`, and reading it as a second Reviewer would merge two
# different agents on two different schedules into one bar.
assert_eq "a review is the Project Reviewer, not a second Reviewer" "4" "$(actor_usd project-reviewer)"
assert_eq "and the cycle Reviewer keeps its own figure" "0.75" "$(actor_usd reviewer)"
assert_eq "the actors sum to the total, so the chart accounts for every dollar" \
  "7.5" "$(jq -r '.counts.spend_total_usd + 0' <<<"$kdata")"
assert_eq "and the review's spend reaches the by-model roll-up too" "6.75" \
  "$(jq -r '.counts.by_model[] | select(.model=="model-b") | .usd + 0' <<<"$kdata")"
assert_eq "the chart is ordered by spend, largest first" "true" \
  "$(jq -r '[.counts.by_actor[].usd] | . == (sort | reverse)' <<<"$kdata")"

# --- What each node is running ---------------------------------------------------
# A peer publishes no container, so its version is knowable only because its
# heartbeat carries one. A peer that predates that (or a node whose image has no
# stamp and no checkout) must read as *unknown* rather than inherit ours — the
# fleet's "behind" marker compares these, and a wrong answer here would either
# invent a skew or hide one.
vh="$(new_home nodeV)"
vpeer="$vh/.cache/poetic-agents/workspaces/.agent-ops-peers/peerV"
vold="$vh/.cache/poetic-agents/workspaces/.agent-ops-peers/peerOld"
mkdir -p "$vpeer" "$vold"
printf '{"node":"peerV","role":"active","ts":"%s","last_cycle":"","version":{"pr":88,"commit":"aa53d62f1b0c4e9a7d2839fbc5104e6a8d7b3f21","short":"aa53d62","built_at":"2026-07-26T11:21:00Z","repo":"Poetic-Poems/agent-ops","source":"image","dirty":false},"compose":{"status":"drifted","diff_lines":3},"image":{"status":"behind","registry_commit":"bb64d73a2c1d","registry_created_at":"2026-07-26T12:00:00Z","checked_at":"2026-07-26T12:05:00Z"}}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$vpeer/heartbeat.json"
printf '{"node":"peerOld","role":"standby","ts":"%s","last_cycle":""}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$vold/heartbeat.json"
run_publish "$vh" NODE_NAME=nodeV-self
vdata="$(data_of "$vh")"
node_version() { jq -r --arg n "$1" --arg k "$2" '.fleet.nodes[] | select(.node==$n) | .version[$k]' <<<"$vdata"; }

assert_eq "a peer's version comes from its heartbeat" "88" "$(node_version peerV pr)"
assert_eq "with the commit that was built" "aa53d62" "$(node_version peerV short)"
assert_eq "a peer that publishes none reports none, not ours" "null" \
  "$(jq -r '.fleet.nodes[] | select(.node=="peerOld") | .version' <<<"$vdata")"
assert_eq "and this node answers for itself" "1" \
  "$(jq '[.fleet.nodes[] | select(.self) | has("version")] | length' <<<"$vdata")"

# The compose-drift verdict rides the same rules (#131): only the node itself
# can read its own host's compose.yaml, so a peer's verdict comes from its
# heartbeat or not at all, and this node computes its own.
assert_eq "a peer's compose verdict comes from its heartbeat" "drifted" \
  "$(jq -r '.fleet.nodes[] | select(.node=="peerV") | .compose.status' <<<"$vdata")"
assert_eq "a peer that publishes none reads null, never a locally computed one" "null" \
  "$(jq -r '.fleet.nodes[] | select(.node=="peerOld") | .compose' <<<"$vdata")"
assert_eq "and this node answers for its own compose file too" "1" \
  "$(jq '[.fleet.nodes[] | select(.self) | has("compose")] | length' <<<"$vdata")"

# The image-drift verdict (#155) rides the same rules once more: only the
# node itself can query the registry on its own behalf, so a peer's verdict
# comes from its heartbeat or not at all. This node's own verdict is asserted
# only to exist (has), not for its content — lib/image-drift.sh's own suite
# covers what the verdict says, and this suite runs from a plain checkout
# (agent_ops_version's source is "checkout" here, not "image"), for which the
# verdict is null by lib/image-drift.sh's own rule.
assert_eq "a peer's image verdict comes from its heartbeat" "behind" \
  "$(jq -r '.fleet.nodes[] | select(.node=="peerV") | .image.status' <<<"$vdata")"
assert_eq "with the registry commit it named" "bb64d73a2c1d" \
  "$(jq -r '.fleet.nodes[] | select(.node=="peerV") | .image.registry_commit' <<<"$vdata")"
assert_eq "a peer that publishes none reads null, never a locally computed one" "null" \
  "$(jq -r '.fleet.nodes[] | select(.node=="peerOld") | .image' <<<"$vdata")"
assert_eq "and this node answers for its own image too" "1" \
  "$(jq '[.fleet.nodes[] | select(.self) | has("image")] | length' <<<"$vdata")"

# --- The pull-request index ------------------------------------------------------
# Every `#number` on the page resolves to a record here. Two properties are what
# make that affordable at the heartbeat's cadence, and neither leaves a trace
# when it breaks — a re-fetched entry renders exactly like a cached one, so the
# only symptom of losing either is an API bill and a publish that overruns its
# window. Driven through DASHBOARD_GH_CMD, so asserting on a GitHub tick costs
# no network call.
x="$(new_home nodeX)"
gh_calls="$tmp_dir/gh-calls"
gh_stub="$tmp_dir/stub-gh.sh"
cat > "$gh_stub" <<'STUB'
#!/usr/bin/env bash
# Stands in for `gh`: records the call, then answers the Publisher's queries.
printf '%s\n' "$*" >> "$GH_CALL_LOG"
# `api <path> [--jq <prog>]`. The register answers below hand back the payload
# shape GitHub really returns and let jq apply the filter, so what is under
# test is the Publisher's own selector and not a rehearsal of it here.
gh_jq() { if [[ "$3" == "--jq" ]]; then jq -r "$4"; else cat; fi; }
case "$1 $2" in
  "pr list")   printf '[]' ;;
  "issue list") printf '[]' ;;
  "run list")  printf '[]' ;;
  "pr view")
    # `pr view <n> -R <slug> --json …`; every fixture PR is merged, so the
    # Publisher must never ask for one of them twice.
    printf '{"number":%s,"title":"a merged change","url":"https://github.com/%s/pull/%s","state":"MERGED","isDraft":false,"createdAt":"2026-07-20T00:00:00Z","mergedAt":"2026-07-21T00:00:00Z","closedAt":"2026-07-21T00:00:00Z","mergeCommit":{"oid":"1234567890abcdef"},"author":{"login":"someone"},"labels":[{"name":"autonomous-agent"}],"reviewDecision":"APPROVED","baseRefName":"main"}' \
      "$3" "$5" "$3" ;;
  "api --paginate")
    # gather-findings.sh's own shape: `api --paginate <path>`, no `--jq` — the
    # path is $3 here, not $2. A healthy fleet with neither alert type open
    # answers both with an ordinary empty list (TD-PPagop-26080201's failing
    # cases, below, are what exercise the other side of this).
    case "$3" in
      "repos/"*"/dependabot/alerts"*)     printf '[]' ;;
      "repos/"*"/code-scanning/alerts"*)  printf '[]' ;;
      *) exit 1 ;;
    esac ;;
  "api "*)
    case "$2" in
      # An ordinary, healthy answer: no open issues. TD-PPagop-26080201's own
      # cases below are what exercise a failed listing.
      "repos/"*"/issues?"*) printf '[]' ;;
      # One repo keeps a register; the others 404, as a repo with none does —
      # a real `contents/tech-debt` 404 carries the API's own error body, which
      # is what tells that apart from a call that simply did not answer
      # (TD-PPagop-26080201); a stub that only ever printed nothing here would
      # make every repo without a register look exactly like a failed read.
      # Four items say what the panel has to get right — open, in-progress,
      # resolved, and one whose blob will not answer — and four more make the
      # roster too big to read in one tick.
      "repos/Poetic-Poems/agent-ops/contents/tech-debt")
        { printf '[{"type":"file","name":"TD-PPagop-26070101.md","sha":"aaaaaaa1"}'
          printf ',{"type":"file","name":"TD-PPagop-26070102.md","sha":"bbbbbbb2"}'
          printf ',{"type":"file","name":"TD-PPagop-26070103.md","sha":"ccccccc3"}'
          printf ',{"type":"file","name":"TD-PPagop-26070104.md","sha":"ddddddd4"}'
          for n in 05 06 07 08; do
            printf ',{"type":"file","name":"TD-PPagop-260702%s.md","sha":"f00000%s"}' "$n" "$n"
          done
          printf ',{"type":"dir","name":"drafts","sha":"eeeeeee5"}]'
        } | gh_jq "$@" ;;
      "repos/Poetic-Poems/agent-ops/git/blobs/"*)
        case "${2##*/}" in
          aaaaaaa1) td_title="An open thing";              td_status=open ;;
          bbbbbbb2) td_title="A thing already being worked"; td_status=in-progress ;;
          ccccccc3) td_title="A thing long since resolved"; td_status=resolved ;;
          f00000*)  td_title="A filler item";              td_status=resolved ;;
          *) exit 1 ;;   # ddddddd4: the read that never answers
        esac
        printf -- '---\nid: an-item\ntitle: %s\nstatus: %s\nfiled: 2026-07-01\n---\n\nWhy it matters.\n' \
          "$td_title" "$td_status" \
          | base64 -w 60 | jq -Rsc '{content: ., encoding: "base64"}' | gh_jq "$@" ;;
      "repos/"*"/contents/tech-debt")
        printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1 ;;
      *)
        case "$3" in
          *default_branch*) printf 'main' ;;
          *) exit 1 ;;
        esac ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$gh_stub"

# Three cycles whose PRs are recorded the way the pipeline records them (a log
# event carrying pr_url), and a peer running a fourth. The peer's is the case
# the open-PR query can never cover: the version a container runs is a merged
# pull request by construction.
xlog="$x/.local/state/poetic-agents/log.jsonl"
: > "$xlog"
for n in 201 202 203; do
  cid="${today_day}T0${n:2:1}0000Z-nodeX-$n"
  make_stage "$x" "$cid" coordinator 0.1 model-a
  printf '{"ts":"2026-07-26T0%s:00:00Z","cycle":"%s","node":"nodeX-self","event":"pr-raised","repo":"Poetic-Poems/poetic","pr_url":"https://github.com/Poetic-Poems/poetic/pull/%s"}\n' \
    "${n:2:1}" "$cid" "$n" >> "$xlog"
done
xpeer="$x/.cache/poetic-agents/workspaces/.agent-ops-peers/peerX"
mkdir -p "$xpeer"
printf '{"node":"peerX","role":"active","ts":"%s","last_cycle":"","version":{"pr":88,"commit":"aa53d62f1b0c4e9a7d2839fbc5104e6a8d7b3f21","short":"aa53d62","built_at":"2026-07-26T11:21:00Z","repo":"Poetic-Poems/agent-ops","source":"image","dirty":false}}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$xpeer/heartbeat.json"

run_gh_publish() {  # a full (stubbed) GitHub tick
  env HOME="$x" NODE_NAME=nodeX-self GH_CALL_LOG="$gh_calls" \
      DASHBOARD_GH_CMD="$gh_stub" "$PUBLISH" >/dev/null 2>&1
}

: > "$gh_calls"
run_gh_publish
assert_eq "a GitHub publish exits 0 against the stub" "0" "$?"
xdata="$(data_of "$x")"
assert_eq "a cycle's pull request is indexed" "a merged change" \
  "$(jq -r '.github.pr_index["Poetic-Poems/poetic#201"].title' <<<"$xdata")"
assert_eq "with the merge commit, abbreviated for reading" "1234567" \
  "$(jq -r '.github.pr_index["Poetic-Poems/poetic#201"].merge_commit' <<<"$xdata")"
assert_eq "and its labels, for the card" "autonomous-agent" \
  "$(jq -r '.github.pr_index["Poetic-Poems/poetic#201"].labels[0]' <<<"$xdata")"
assert_eq "the version a node runs is indexed too, though no open-PR query names it" \
  "MERGED" "$(jq -r '.github.pr_index["Poetic-Poems/agent-ops#88"].state' <<<"$xdata")"
# Asserted by membership, not by count: this node's own version contributes a
# reference too (whatever pull request the checkout under test last merged), and
# a count would then be a test of this repository's git history.
assert_eq "every reference on the page resolves" "true" \
  "$(jq -r '.github.pr_index
            | has("Poetic-Poems/poetic#201") and has("Poetic-Poems/poetic#202")
              and has("Poetic-Poems/poetic#203") and has("Poetic-Poems/agent-ops#88")' <<<"$xdata")"
idx_n="$(jq '.github.pr_index | length' <<<"$xdata")"

# The property that keeps this free: a merged pull request never changes, so a
# warm index spends nothing. Without it, every tick re-reads every number on the
# page — invisibly, because the result is identical.
assert_eq "a cold index reads each referenced pull request once, never twice" \
  "$(grep -c '^pr view' "$gh_calls")" "$(grep '^pr view' "$gh_calls" | sort -u | wc -l)"
: > "$gh_calls"
run_gh_publish
assert_eq "and a warm one re-reads none of them" "0" "$(grep -c '^pr view' "$gh_calls")"
assert_eq "while still serving them all" "$idx_n" \
  "$(jq '.github.pr_index | length' <<<"$(data_of "$x")")"

# A --no-github tick carries the index forward like every other GitHub-sourced
# panel; blanking it would empty every hover card on the page between fetches.
run_publish "$x" NODE_NAME=nodeX-self
assert_eq "a local-only tick carries the index forward" "$idx_n" \
  "$(jq '.github.pr_index | length' <<<"$(data_of "$x")")"

# And the cold-start bound: forty references at up to GH_TIMEOUT each would not
# fit in the heartbeat's window, so a tick fills a few and the rest wait.
y="$(new_home nodeY)"
ylog="$y/.local/state/poetic-agents/log.jsonl"
: > "$ylog"
i=0
while (( i < 12 )); do
  cid="${today_day}T09$(printf '%04d' "$i")Z-nodeY-$i"
  make_stage "$y" "$cid" coordinator 0.1 model-a
  printf '{"ts":"2026-07-26T09:00:00Z","cycle":"%s","node":"nodeY-self","event":"pr-raised","repo":"Poetic-Poems/poetic","pr_url":"https://github.com/Poetic-Poems/poetic/pull/3%02d"}\n' \
    "$cid" "$i" >> "$ylog"
  i=$(( i + 1 ))
done
: > "$gh_calls"
env HOME="$y" NODE_NAME=nodeY-self GH_CALL_LOG="$gh_calls" \
    DASHBOARD_GH_CMD="$gh_stub" "$PUBLISH" >/dev/null 2>&1
y_views="$(grep -c '^pr view' "$gh_calls")"
assert_eq "a cold index is filled a few references a tick, not all at once" \
  "1" "$(( y_views <= 8 ))"
assert_eq "and it does make progress" "1" "$(( y_views > 0 ))"

# --- The tech-debt ledger's rows -------------------------------------------------
# The panel is headed "what the Co-Ordinator sees", so a row has to say what the
# work *is*: an ID alone named nothing, and most of a mature register is
# resolved items the Co-Ordinator will never pick up. Titles and statuses live
# one blob read per item down, which is affordable only because the read is
# keyed by the item's blob SHA and so never repeats — the property asserted
# below, since a re-read register renders exactly like a cached one and the only
# symptom of losing it is the API bill.
w="$(new_home nodeW)"
run_w_publish() {
  env HOME="$w" NODE_NAME=nodeW-self GH_CALL_LOG="$gh_calls" \
      DASHBOARD_GH_CMD="$gh_stub" "$PUBLISH" >/dev/null 2>&1
}
td_of() {  # td_of <data> <jq-suffix>
  jq -r '.github.inputs["Poetic-Poems/agent-ops"].tech_debt'"$2" <<<"$1"
}
: > "$gh_calls"
run_w_publish
wdata="$(data_of "$w")"
assert_eq "an item's row carries the title out of its own file" "An open thing" \
  "$(td_of "$wdata" '[] | select(.id == "TD-PPagop-26070101") | .title')"
assert_eq "and the status the Co-Ordinator would find" "open" \
  "$(td_of "$wdata" '[] | select(.id == "TD-PPagop-26070101") | .status')"
assert_eq "and a link to the item file behind it" \
  "https://github.com/Poetic-Poems/agent-ops/blob/main/tech-debt/TD-PPagop-26070101.md" \
  "$(td_of "$wdata" '[] | select(.id == "TD-PPagop-26070101") | .url')"
assert_eq "a resolved item is no work source, and is not shown as one" "false" \
  "$(td_of "$wdata" ' | any(.id == "TD-PPagop-26070103")')"
assert_eq "an item already being worked sorts above the merely open" "TD-PPagop-26070102" \
  "$(td_of "$wdata" '[0].id')"
assert_eq "an item whose file would not read is still listed, as the bare ID it was" "" \
  "$(td_of "$wdata" '[] | select(.id == "TD-PPagop-26070104") | .title')"
# The cold-start bound, for the same reason as the pull-request index above: a
# fleet's worth of registers is well over a hundred blobs and would not fit in
# one publish.
w_blobs="$(grep -c 'git/blobs' "$gh_calls")"
assert_eq "a cold register is read a few items a tick, not all at once" \
  "1" "$(( w_blobs <= 4 ))"
assert_eq "and it does make progress" "1" "$(( w_blobs > 0 ))"

run_w_publish            # the ticks that finish the roster
run_w_publish
: > "$gh_calls"
run_w_publish            # …and one with nothing left to read
assert_eq "a warm register re-reads none of the items it has already read" "0" \
  "$(grep -c 'git/blobs/[abcf]' "$gh_calls")"
assert_eq "while a read that never answered is tried again" "1" \
  "$(grep -c 'git/blobs/ddddddd4' "$gh_calls")"
wdata="$(data_of "$w")"
assert_eq "and a fully-read register is down to the items that are actually work" "3" \
  "$(td_of "$wdata" ' | length')"

# A --no-github tick carries the rows forward like every other GitHub-sourced
# panel, rather than blanking the ledger between fetches.
run_publish "$w" NODE_NAME=nodeW-self
assert_eq "a local-only tick carries the ledger forward" "3" \
  "$(td_of "$(data_of "$w")" ' | length')"

# --- Per-source, per-repo read state (TD-PPagop-26080201) -----------------------
# Four of `github.inputs[<slug>]`'s five sources used to conflate "answered
# emptily" with "did not answer at all": `issues`, `failed_runs`, `tech_debt`
# and `findings` all degraded a failed call to the same `[]` a genuinely empty
# one produces, indistinguishable on the page. Each now carries a `state`
# alongside its data — "answered", "answered_404" (a legitimate absence, only
# ever `tech_debt`) or "failed" — and `github.ok`/`error` reflect a failure
# from any of them, not only `pr list`'s.
#
# The healthy fleet against `xdata` (the PR-index run above, same stub) is the
# ordinary case: every source for every repo answered, and the two repos with
# no register 404 legitimately rather than failing.
assert_eq "a healthy repo's issues read as answered" "answered" \
  "$(jq -r '.github.inputs["Poetic-Poems/poetic"].state.issues' <<<"$xdata")"
assert_eq "and its failing-runs listing too" "answered" \
  "$(jq -r '.github.inputs["Poetic-Poems/poetic"].state.failed_runs' <<<"$xdata")"
assert_eq "and its findings gathering too" "answered" \
  "$(jq -r '.github.inputs["Poetic-Poems/poetic"].state.findings' <<<"$xdata")"
assert_eq "a repo with no tech-debt register 404s legitimately, not a failure" \
  "answered_404" "$(jq -r '.github.inputs["Poetic-Poems/poetic"].state.tech_debt' <<<"$xdata")"
assert_eq "the repo whose register does exist reads it as answered" "answered" \
  "$(jq -r '.github.inputs["Poetic-Poems/agent-ops"].state.tech_debt' <<<"$xdata")"

# A second stub, parameterised by $GH_STUB_FAIL, answers every source
# healthily except the one under test, which it fails for a reason that is
# NOT a legitimate absence (a rate limit, `status: "403"`, distinct from the
# `tech_debt` 404 above) — the case the fix exists for.
gh_fail_stub="$tmp_dir/stub-gh-fail.sh"
cat > "$gh_fail_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
rate_limited() {
  printf '{"message":"API rate limit exceeded for user ID 1.","status":"403"}'
  echo "gh: API rate limit exceeded (HTTP 403)" >&2
  exit 1
}
case "$1 $2" in
  "pr list")
    [[ "$GH_STUB_FAIL" == "prs" ]] && rate_limited
    printf '[]' ;;
  "run list")
    [[ "$GH_STUB_FAIL" == "runs" ]] && rate_limited
    printf '[]' ;;
  "api --paginate")
    case "$3" in
      "repos/"*"/dependabot/alerts"*|"repos/"*"/code-scanning/alerts"*)
        [[ "$GH_STUB_FAIL" == "findings" ]] && rate_limited
        printf '[]' ;;
      *) exit 1 ;;
    esac ;;
  "api "*)
    case "$2" in
      "repos/"*"/issues?"*)
        [[ "$GH_STUB_FAIL" == "issues" ]] && rate_limited
        printf '[]' ;;
      "repos/Poetic-Poems/poetic/contents/tech-debt")
        [[ "$GH_STUB_FAIL" == "tech_debt" ]] && rate_limited
        printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1 ;;
      "repos/"*"/contents/tech-debt")
        # Every other repo still 404s legitimately, whichever source this run
        # is failing, so this scenario proves `failed` and `answered_404` are
        # told apart from each other, not just from `answered`.
        printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1 ;;
      *)
        case "$3" in
          *default_branch*) printf 'main' ;;
          *) exit 1 ;;
        esac ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$gh_fail_stub"

run_fail_publish() {  # run_fail_publish <home> <which-source-fails>
  env HOME="$1" NODE_NAME=nodeFail-self GH_CALL_LOG="$gh_calls" GH_STUB_FAIL="$2" \
      DASHBOARD_GH_CMD="$gh_fail_stub" "$PUBLISH" >/dev/null 2>&1
}

f="$(new_home nodeFail)"
run_fail_publish "$f" issues
fdata="$(data_of "$f")"
assert_eq "a failed issues listing is marked failed, not answered emptily" "failed" \
  "$(jq -r '.github.inputs["Poetic-Poems/poetic"].state.issues' <<<"$fdata")"
assert_eq "and the page-wide alarm fires for it" "false" "$(jq -r '.github.ok' <<<"$fdata")"
assert_contains "naming what failed" "issues" "$(jq -r '.github.error' <<<"$fdata")"

f="$(new_home nodeFail2)"
run_fail_publish "$f" runs
assert_eq "a failed workflow-run listing is marked failed" "failed" \
  "$(jq -r '.github.inputs["Poetic-Poems/poetic"].state.failed_runs' <<<"$(data_of "$f")")"

f="$(new_home nodeFail3)"
run_fail_publish "$f" findings
assert_eq "a failed findings gathering is marked failed" "failed" \
  "$(jq -r '.github.inputs["Poetic-Poems/poetic"].state.findings' <<<"$(data_of "$f")")"

f="$(new_home nodeFail4)"
run_fail_publish "$f" tech_debt
fdata="$(data_of "$f")"
assert_eq "a real tech-debt-listing failure is marked failed, not a legitimate 404" \
  "failed" "$(jq -r '.github.inputs["Poetic-Poems/poetic"].state.tech_debt' <<<"$fdata")"
assert_eq "while an unrelated repo's genuine 404 still reads as one" "answered_404" \
  "$(jq -r '.github.inputs["Poetic-Poems/poetic-fiddle"].state.tech_debt' <<<"$fdata")"

f="$(new_home nodeFail5)"
run_fail_publish "$f" prs
fdata="$(data_of "$f")"
assert_eq "a failed pr list still raises the page-wide alarm" "false" "$(jq -r '.github.ok' <<<"$fdata")"
assert_contains "naming pr list, not a source it never touched" "pr list" "$(jq -r '.github.error' <<<"$fdata")"

# --- Blocked rows carry `kind` for a refinement block (TD26072603) --------------
# A refinement block (`kind: "needs-refinement"`, lib/refinement.sh) is one
# `attempt-failed` event among ordinary ones; the extract must not drop the
# marker on its way into data.js, since the page's badge and filter both key
# on it.
z="$(new_home nodeZ)"
zlog="$z/.local/state/poetic-agents/log.jsonl"
{
  printf '{"ts":"2026-07-26T00:00:00Z","event":"attempt-failed","repo":"Poetic-Poems/agent-ops","item":"TD26072610","stage":"coordinator","detail":"a red check on the base branch"}\n'
  printf '{"ts":"2026-07-26T00:00:00Z","event":"attempt-failed","repo":"Poetic-Poems/agent-ops","item":"TD26072611","stage":"coordinator","detail":"never specified what done means","kind":"needs-refinement","unblock_condition":"a human decision","source":"tech-debt"}\n'
  # A third item, blocked and then voided: `item-void` clears no block, so this
  # is the shape every Enabler `void` verdict leaves behind, and the page must
  # show it under one heading, not two (requirement 34h).
  printf '{"ts":"2026-07-26T00:00:00Z","event":"attempt-failed","repo":"Poetic-Poems/agent-ops","item":"TD26072612","stage":"implementor","detail":"waiting on an upstream release"}\n'
  printf '{"ts":"2026-07-27T00:00:00Z","event":"item-void","repo":"Poetic-Poems/agent-ops","item":"TD26072612","detail":"already on main","evidence":"merged in #144"}\n'
} > "$zlog"
run_publish "$z"
zdata="$(data_of "$z")"
assert_eq "an ordinary block's kind is the empty string" "" \
  "$(jq -r '.blocked[] | select(.item=="TD26072610") | .kind' <<<"$zdata")"
assert_eq "a refinement block's kind survives into data.js" "needs-refinement" \
  "$(jq -r '.blocked[] | select(.item=="TD26072611") | .kind' <<<"$zdata")"
assert_eq "a blocked item that has since been voided is not listed as blocked" "0" \
  "$(jq '[.blocked[] | select(.item=="TD26072612")] | length' <<<"$zdata")"
assert_eq "it is listed as void instead, with its evidence" "merged in #144" \
  "$(jq -r '.void[] | select(.item=="TD26072612") | .evidence' <<<"$zdata")"
assert_eq "and the blocks either side of it are untouched" "2" \
  "$(jq '.blocked | length' <<<"$zdata")"

# --- Recovered and pure race losses are distinguished (issue #245) ---------------
# A cycle that loses its first candidate to a peer but wins the next one must
# not look like an ordinary first-try selection, and a cycle that loses every
# candidate must say whether that was contention or a GitHub outage — both
# read from the claim-lost/stand-down events alone, no new stage envelope
# needed.
w="$(new_home nodeW)"
wlog="$w/.local/state/poetic-agents/log.jsonl"
w_recovered="${today_day}T040000Z-recovered"
w_raced="${today_day}T050000Z-raced"
w_unreachable="${today_day}T060000Z-unreachable"
{
  # Recovered: one held loss, then a selection that names it, then real work.
  printf '{"ts":"2026-07-28T00:00:00Z","cycle":"%s","node":"nodeW","event":"cycle-start"}\n' "$w_recovered"
  printf '{"ts":"2026-07-28T00:00:01Z","cycle":"%s","node":"nodeW","event":"claim-lost","repo":"o/a","item":"1","branch":"td/1","rc":3,"cause":"held"}\n' "$w_recovered"
  printf '{"ts":"2026-07-28T00:00:02Z","cycle":"%s","node":"nodeW","event":"selection","repo":"o/a","item":"2","source":"tech-debt","model":"m","title":"t","branch":"td/2","race_losses":1}\n' "$w_recovered"
  printf '{"ts":"2026-07-28T00:00:03Z","cycle":"%s","node":"nodeW","event":"pr-raised","repo":"o/a","pr_url":"https://github.com/o/a/pull/9"}\n' "$w_recovered"
  printf '{"ts":"2026-07-28T00:00:04Z","cycle":"%s","node":"nodeW","event":"cycle-end"}\n' "$w_recovered"
  # Stood down after every candidate raced away.
  printf '{"ts":"2026-07-28T01:00:00Z","cycle":"%s","node":"nodeW","event":"cycle-start"}\n' "$w_raced"
  printf '{"ts":"2026-07-28T01:00:01Z","cycle":"%s","node":"nodeW","event":"claim-lost","repo":"o/a","item":"3","branch":"td/3","rc":3,"cause":"held"}\n' "$w_raced"
  printf '{"ts":"2026-07-28T01:00:02Z","cycle":"%s","node":"nodeW","event":"stand-down","reason":"every candidate is already claimed elsewhere","candidates":1,"cause":"raced"}\n' "$w_raced"
  printf '{"ts":"2026-07-28T01:00:03Z","cycle":"%s","node":"nodeW","event":"cycle-end"}\n' "$w_raced"
  # Stood down over a GitHub outage — no contention to report.
  printf '{"ts":"2026-07-28T02:00:00Z","cycle":"%s","node":"nodeW","event":"cycle-start"}\n' "$w_unreachable"
  printf '{"ts":"2026-07-28T02:00:01Z","cycle":"%s","node":"nodeW","event":"claim-lost","repo":"o/a","item":"4","branch":"td/4","rc":1,"cause":"unreachable"}\n' "$w_unreachable"
  printf '{"ts":"2026-07-28T02:00:02Z","cycle":"%s","node":"nodeW","event":"stand-down","reason":"GitHub could not be reached for any candidate — this is an outage, not contention","candidates":1,"cause":"unreachable"}\n' "$w_unreachable"
  printf '{"ts":"2026-07-28T02:00:03Z","cycle":"%s","node":"nodeW","event":"cycle-end"}\n' "$w_unreachable"
} > "$wlog"
run_publish "$w"
wdata="$(data_of "$w")"
cycle_field() {  # cycle_field <data> <cid> <field>
  jq -r --arg c "$2" --arg f "$3" '.cycles[] | select(.id==$c) | .[$f]' <<<"$1"
}
assert_eq "a recovered race is marked raced" "true" "$(cycle_field "$wdata" "$w_recovered" raced)"
assert_eq "carrying the loss count that recovered" "1" "$(cycle_field "$wdata" "$w_recovered" race_losses)"
assert_eq "and its outcome still reads as real work, not a stand-down" "pr-raised" \
  "$(cycle_field "$wdata" "$w_recovered" outcome)"
assert_eq "a pure race loss stands down raced" "raced" "$(cycle_field "$wdata" "$w_raced" standdown_cause)"
assert_eq "and is marked raced too" "true" "$(cycle_field "$wdata" "$w_raced" raced)"
assert_eq "an outage stands down unreachable, not raced" "unreachable" \
  "$(cycle_field "$wdata" "$w_unreachable" standdown_cause)"
assert_eq "and is not marked raced — no peer held anything" "false" \
  "$(cycle_field "$wdata" "$w_unreachable" raced)"
# All three cycles carry a `claim-lost` beyond the bare no-op shape, so #271's
# filter must leave every one of them its detail row and count none of them.
assert_eq "a stand-down that carries more than the no-op shape is never aggregated" "0" \
  "$(jq -r '.noop_ticks.total' <<<"$wdata")"

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
