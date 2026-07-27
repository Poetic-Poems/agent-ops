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

raw="$(cat "$a/.local/state/poetic-agents/dashboard/data.js")"
assert_contains "token shapes are redacted" "[REDACTED-TOKEN]" "$raw"
assert_lacks "no raw token survives"        "ghp_0123456789abcdefXYZ0123" "$raw"
assert_lacks "no /home path survives"       "/home/fixtureuser" "$raw"

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
assert_eq "and the work is the one the lock's cycle selected" "TD26072004" \
  "$(node_live nodeF-self item)"
assert_eq "the fleet's newest cycle names the node that ran it" "nodeF-self" \
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
# skip past it to the newest one that logged `cycle-end`.
printf '{"ts":"2026-01-01T06:00:00Z","cycle":"%sT060000Z-peer1-99","node":"peer1","event":"cycle-start"}\n' \
  "$today_day" >> "$peer/log.jsonl"
run_publish "$f" NODE_NAME=nodeF-self
fdata="$(data_of "$f")"
assert_eq "the newest cycle overall is the unfinished one" "${today_day}T060000Z-peer1-99" \
  "$(jq -r '.cycles[0].id' <<<"$fdata")"
assert_eq "but last_cycle skips it for the newest that ended" "${today_day}T051000Z-nodeF-self-skipped" \
  "$(jq -r '.status.last_cycle.id' <<<"$fdata")"
assert_eq "so the field it is dated by is never null" "2026-01-01T05:10:02Z" \
  "$(jq -r '.status.last_cycle.ended_at' <<<"$fdata")"
assert_eq "and the outcome is a real verdict, not the ladder's floor" "skipped" \
  "$(jq -r '.status.last_cycle.outcome' <<<"$fdata")"

# A node that has never run a cycle has no live state at all — null, not a
# fabricated idle record. (`live` is absent from the page's reading of it.)
g="$(new_home nodeG)"
run_publish "$g" NODE_NAME=nodeG-self
assert_eq "a node with no history reports no live state" "null" \
  "$(jq -r '.fleet.nodes[0].live' <<<"$(data_of "$g")")"

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
printf '{"node":"peerV","role":"active","ts":"%s","last_cycle":"","version":{"pr":88,"commit":"aa53d62f1b0c4e9a7d2839fbc5104e6a8d7b3f21","short":"aa53d62","built_at":"2026-07-26T11:21:00Z","repo":"Poetic-Poems/agent-ops","source":"image","dirty":false}}\n' \
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
case "$1 $2" in
  "pr list")   printf '[]' ;;
  "issue list") printf '[]' ;;
  "run list")  printf '[]' ;;
  "pr view")
    # `pr view <n> -R <slug> --json …`; every fixture PR is merged, so the
    # Publisher must never ask for one of them twice.
    printf '{"number":%s,"title":"a merged change","url":"https://github.com/%s/pull/%s","state":"MERGED","isDraft":false,"createdAt":"2026-07-20T00:00:00Z","mergedAt":"2026-07-21T00:00:00Z","closedAt":"2026-07-21T00:00:00Z","mergeCommit":{"oid":"1234567890abcdef"},"author":{"login":"someone"},"labels":[{"name":"autonomous-agent"}],"reviewDecision":"APPROVED","baseRefName":"main"}' \
      "$3" "$5" "$3" ;;
  "api "*)
    case "$3" in
      *default_branch*) printf 'main' ;;
      *) exit 1 ;;
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

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
