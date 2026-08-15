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
#   the argv cap          the void extract grows with the log and once rode
#                         into the assemble as an --argjson, so at 132539 bytes
#                         `execve` refused it and every dashboard on the fleet
#                         froze at once (requirement 4g)
#   the failed assemble   whatever kills that jq, an empty payload must not be
#                         written over a good data.js and reported as a write
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

# cost_rows backs the model/actor charts' own time-frame selector (issue
# #334): the same window as by_day/by_model/by_actor, but un-summed, so the
# page can re-aggregate over whatever span the reader picks.
assert_eq "cost_rows carries one row per in-window cycle" \
  "3" "$(jq -r '.counts.cost_rows | length' <<<"$data")"
assert_eq "cost_rows sums to the same total as spend_total_usd" \
  "1" "$(jq -r '[.counts.cost_rows[].usd] | add' <<<"$data")"
assert_eq "each cost_rows entry carries day, model and actor" "3" \
  "$(jq -r '[.counts.cost_rows[] | select(.day != null and .model != null and .actor != null)] | length' <<<"$data")"
assert_eq "the cycle far outside COST_SCAN_DAYS is excluded from cost_rows too" \
  "0" "$(jq -r '[.counts.cost_rows[] | select(.model=="model-old")] | length' <<<"$data")"

# The verdict-quality aggregate (issue #319) ships even when the log holds no
# Co-Ordinator record at all, zeroed rather than absent: the page distinguishes
# "no rejected verdicts in the window" from "this Publisher never recorded any
# of this", and it can only draw that line if an empty window is still an
# object.
assert_eq "the verdict aggregate is present on a log with no Co-Ordinator record" \
  "object" "$(jq -r '.counts.coordinator_verdicts | type' <<<"$data")"
assert_eq "and reads as a real zero rather than a missing key" "0" \
  "$(jq -r '.counts.coordinator_verdicts.runs' <<<"$data")"
assert_eq "with no rate at all, since nothing was corroborated" "null" \
  "$(jq -r '.counts.coordinator_verdicts.rate' <<<"$data")"
assert_eq "and the per-band tally reads as a real empty array too" "[]" \
  "$(jq -c '.counts.coordinator_verdicts.by_band' <<<"$data")"

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

# --- Machine bookkeeping stays out of the log tail --------------------------------
# `review-gate-checks-read` (implementation spec requirement 31c,
# TD-PPagop-26081404) fires once per ready-gate evaluation and carries nothing
# an operator can act on — it exists for `review_gate_unknown_streak_verdict`
# to read — so the Publisher keeps it out of the log tail rather than letting
# a degraded run displace rows that have something to say. The escalation it
# feeds, `review-gate-checks-degraded`, is exactly what the tail is for and
# stays. `first-seen` (requirement 33, TD-PPagop-26081405) gets the same
# treatment: one per item a gather first reports, read only by
# scripts/pickup-metrics.sh.
{
  printf '{"ts":"2026-07-26T08:20:00Z","cycle":"%sT080000Z-31","node":"nodeC-self","event":"review-gate-checks-read","ok":false}\n' "$today_day"
  printf '{"ts":"2026-07-26T08:21:00Z","cycle":"%sT080000Z-31","node":"nodeC-self","event":"review-gate-checks-degraded","gate":"required-checks","count":3,"first_ts":"2026-07-26T06:20:00Z","last_ts":"2026-07-26T08:20:00Z"}\n' "$today_day"
  printf '{"ts":"2026-07-26T08:22:00Z","cycle":"%sT080000Z-31","node":"nodeC-self","event":"first-seen","repo":"o/r","item":"1","source":"tech-debt","basis":"poll","bootstrap":false}\n' "$today_day"
} >> "$c/.local/state/poetic-agents/log.jsonl"
run_publish "$c" NODE_NAME=nodeC-self
cdata="$(data_of "$c")"
assert_eq "the review-gate bookkeeping event is kept out of the log tail" "0" \
  "$(jq '[.log_tail[] | select(.event == "review-gate-checks-read")] | length' <<<"$cdata")"
assert_eq "while the escalation it feeds stays in it" "1" \
  "$(jq '[.log_tail[] | select(.event == "review-gate-checks-degraded")] | length' <<<"$cdata")"
assert_eq "first-seen is kept out of the log tail too" "0" \
  "$(jq '[.log_tail[] | select(.event == "first-seen")] | length' <<<"$cdata")"

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

# --- Co-Ordinator verdict quality (issue #319) ----------------------------------
# The rate the Script rejects a Co-Ordinator verdict at (implementation spec
# 3t/3v), by UTC day and by the model that produced it. Both terms are counted
# here, not just the rejections: the incident this came from (#310) was one
# node standing the whole fleet down for a day, and the operator question it
# left behind — is `coordinator_model` the wrong model — is a ratio, so a
# numerator with no denominator answers nothing.
#
# The unit is the verdict, not the cycle, because requirement 3v made a cycle
# able to produce two. The fixture holds one of each shape the aggregate must
# tell apart:
#
#   V1  rejected, then a retry that selected      2 verdicts, 1 rejected
#   V2  accepted over a non-empty eligible set    denominator only — and its
#                                                 `none-selected` must not be
#                                                 counted as a second verdict
#   V3  a `none-selected` from before 3v          1 rejected, attributed by
#                                                 its cycle's own stage-end
#   V4  an empty eligible set                     neither term
#   V5  rejected twice, then the Script picked    2 verdicts, 2 rejected, on
#                                                 the other model
v="$(new_home nodeV)"
v_today="$(date -u +%Y-%m-%d)"
v_yest="$(date -u -d '-1 day' +%Y-%m-%d 2>/dev/null || echo "$v_today")"
v_today_day="${v_today//-/}"
v_yest_day="${v_yest//-/}"
haiku="claude-haiku-4-5-20251001"
# One coordinator engagement: the `stage-end` requirement 33a writes for it.
# `$5` is `,"retry":true` for the retry of a rejected verdict, empty otherwise.
v_run() {  # v_run <iso-date> <hh:mm:ss> <cycle> <model> [retry-suffix]
  printf '{"ts":"%sT%sZ","cycle":"%s","node":"nodeV","event":"stage-end","stage":"coordinator","exit_code":0,"model":"%s"%s}\n' \
    "$1" "$2" "$3" "$4" "${5:-}"
}
{
  # V1 — rejected, retried, and the retry selected.
  v_run "$v_yest" "02:00:00" "${v_yest_day}T020000Z-nodeV-1" "$haiku"
  printf '{"ts":"%sT02:00:01Z","cycle":"%sT020000Z-nodeV-1","node":"nodeV","event":"warning","detail":"tech-debt verdict contradiction: the Script found 33 eligible open tech-debt item(s)","eligible_total":33,"unaccounted":[{"repo":"o/a","item":"TD-1"}]}\n' "$v_yest" "$v_yest_day"
  printf '{"ts":"%sT02:00:02Z","cycle":"%sT020000Z-nodeV-1","node":"nodeV","event":"corroboration","attempt":1,"verdict":"rejected","eligible_total":33,"unaccounted_total":1,"unaccounted":[{"repo":"o/a","item":"TD-1"}],"reason":"all recorded void","coordinator_model":"%s","bands":{"tech-debt":1}}\n' "$v_yest" "$v_yest_day" "$haiku"
  v_run "$v_yest" "02:05:00" "${v_yest_day}T020000Z-nodeV-1" "$haiku" ',"retry":true'
  printf '{"ts":"%sT02:05:02Z","cycle":"%sT020000Z-nodeV-1","node":"nodeV","event":"corroboration","attempt":2,"verdict":"accepted-by-selection","eligible_total":33,"coordinator_model":"%s"}\n' "$v_yest" "$v_yest_day" "$haiku"
  printf '{"ts":"%sT02:05:03Z","cycle":"%sT020000Z-nodeV-1","node":"nodeV","event":"selection","repo":"o/a","item":"TD-1","source":"tech-debt","model":"claude-opus-5","title":"t"}\n' "$v_yest" "$v_yest_day"
  # V2 — accepted over a non-empty eligible set: the denominator, once.
  v_run "$v_yest" "03:00:00" "${v_yest_day}T030000Z-nodeV-2" "$haiku"
  printf '{"ts":"%sT03:00:02Z","cycle":"%sT030000Z-nodeV-2","node":"nodeV","event":"corroboration","attempt":1,"verdict":"accepted","eligible_total":4,"unaccounted_total":0,"coordinator_model":"%s"}\n' "$v_yest" "$v_yest_day" "$haiku"
  printf '{"ts":"%sT03:00:03Z","cycle":"%sT030000Z-nodeV-2","node":"nodeV","event":"none-selected","reason":"every item is claimed","fingerprint":"abc","eligible_total":4,"coordinator_model":"%s"}\n' "$v_yest" "$v_yest_day" "$haiku"
  # V3 — a rejection recorded before 3v: no corroboration event, no fields.
  v_run "$v_yest" "04:00:00" "${v_yest_day}T040000Z-nodeV-3" "$haiku"
  printf '{"ts":"%sT04:00:01Z","cycle":"%sT040000Z-nodeV-3","node":"nodeV","event":"warning","detail":"tech-debt verdict contradiction: the Script found 7 eligible open tech-debt item(s)","eligible_total":7,"unaccounted":[{"repo":"o/c","item":"TD-7"}]}\n' "$v_yest" "$v_yest_day"
  printf '{"ts":"%sT04:00:02Z","cycle":"%sT040000Z-nodeV-3","node":"nodeV","event":"none-selected","reason":"legacy event","td_verdict_rejected":true}\n' "$v_yest" "$v_yest_day"
  # V4 — nothing was eligible, so there was nothing to corroborate.
  v_run "$v_today" "05:00:00" "${v_today_day}T050000Z-nodeV-4" "$haiku"
  printf '{"ts":"%sT05:00:02Z","cycle":"%sT050000Z-nodeV-4","node":"nodeV","event":"none-selected","reason":"nothing eligible","fingerprint":"def","eligible_total":0,"coordinator_model":"%s"}\n' "$v_today" "$v_today_day" "$haiku"
  # V5 — rejected twice on the other model, and the Script picked for it.
  v_run "$v_today" "06:00:00" "${v_today_day}T060000Z-nodeV-5" "claude-sonnet-5"
  printf '{"ts":"%sT06:00:02Z","cycle":"%sT060000Z-nodeV-5","node":"nodeV","event":"corroboration","attempt":1,"verdict":"rejected","eligible_total":9,"unaccounted_total":9,"unaccounted":[{"repo":"o/b","item":"TD-9"}],"reason":"nothing to do","coordinator_model":"claude-sonnet-5","bands":{"issues":1}}\n' "$v_today" "$v_today_day"
  v_run "$v_today" "06:05:00" "${v_today_day}T060000Z-nodeV-5" "claude-sonnet-5" ',"retry":true'
  printf '{"ts":"%sT06:05:02Z","cycle":"%sT060000Z-nodeV-5","node":"nodeV","event":"corroboration","attempt":2,"verdict":"rejected","eligible_total":9,"unaccounted_total":3,"unaccounted":[{"repo":"o/b","item":"TD-9"},{"repo":"o/b","item":"TD-10"}],"reason":"still nothing to do","coordinator_model":"claude-sonnet-5","bands":{"issues":1,"tech-debt":2}}\n' "$v_today" "$v_today_day"
  printf '{"ts":"%sT06:05:03Z","cycle":"%sT060000Z-nodeV-5","node":"nodeV","event":"selection","repo":"o/b","item":"TD-9","source":"tech-debt","model":"claude-opus-5","title":"t","selected_by":"script-fallback"}\n' "$v_today" "$v_today_day"
} > "$v/.local/state/poetic-agents/log.jsonl"
run_publish "$v" NODE_NAME=nodeV
vdata="$(jq -c '.counts.coordinator_verdicts' <<<"$(data_of "$v")")"

assert_eq "every Co-Ordinator engagement in the window is counted" "7" "$(jq -r '.runs' <<<"$vdata")"
assert_eq "including the retries, counted again on their own" "2" "$(jq -r '.retries' <<<"$vdata")"
assert_eq "every selection" "2" "$(jq -r '.selections' <<<"$vdata")"
assert_eq "and the ones the Script had to make itself" "1" "$(jq -r '.fallbacks' <<<"$vdata")"
assert_eq "every nothing-selected outcome" "3" "$(jq -r '.none_selected' <<<"$vdata")"
assert_eq "the denominator is the verdicts there was something to corroborate" "6" \
  "$(jq -r '.corroborated' <<<"$vdata")"
assert_eq "the numerator is the rejected ones" "4" "$(jq -r '.rejected' <<<"$vdata")"
assert_eq "and the rate is one over the other" "0.6666666666666666" "$(jq -r '.rate' <<<"$vdata")"
assert_eq "an empty eligible set enters neither term" "1" \
  "$(jq -r --arg d "$v_today_day" --arg m "$haiku" \
     '[.by_day[] | select(.day == $d and .model == $m and .none_selected == 1
                          and .corroborated == 0 and .rejected == 0)] | length' <<<"$vdata")"
# A cycle records its verdict once. Requirement 3v writes a `corroboration`
# *and* a `none-selected` for the same verdict, and counting both would inflate
# every denominator by exactly the cycles that stood down cleanly.
assert_eq "a cycle that logged both records is one verdict, not two" "4" \
  "$(jq -r --arg m "$haiku" '.by_model[] | select(.model == $m) | .corroborated' <<<"$vdata")"

# Changing `coordinator_model` on one node must produce separately
# attributable rates — the whole reason the split exists.
assert_eq "the model that was rejected twice carries both" "2" \
  "$(jq -r '.by_model[] | select(.model == "claude-sonnet-5") | .rejected' <<<"$vdata")"
assert_eq "at its own rate" "1" \
  "$(jq -r '.by_model[] | select(.model == "claude-sonnet-5") | .rate' <<<"$vdata")"
assert_eq "and the other model is counted apart from it" "2" \
  "$(jq -r --arg m "$haiku" '.by_model[] | select(.model == $m) | .rejected' <<<"$vdata")"
assert_eq "at its own rate too" "0.5" \
  "$(jq -r --arg m "$haiku" '.by_model[] | select(.model == $m) | .rate' <<<"$vdata")"
assert_eq "a selection is attributed to the Co-Ordinator model, never the Implementor one" "0" \
  "$(jq -r '[.by_model[] | select(.model == "claude-opus-5")] | length' <<<"$vdata")"
assert_eq "a verdict written before 3v is still attributed by its own cycle" "3" \
  "$(jq -r --arg m "$haiku" '.by_model[] | select(.model == $m) | .none_selected' <<<"$vdata")"
assert_eq "and the Script fallback is attributed to the model it had to rescue" "1" \
  "$(jq -r '.by_model[] | select(.model == "claude-sonnet-5") | .fallbacks' <<<"$vdata")"

assert_eq "the day the fallback happened carries it" "1" \
  "$(jq -r --arg d "$v_today_day" \
     '.by_day[] | select(.day == $d and .model == "claude-sonnet-5") | .fallbacks' <<<"$vdata")"
assert_eq "and the day it did not, does not" "0" \
  "$(jq -r --arg d "$v_yest_day" --arg m "$haiku" \
     '.by_day[] | select(.day == $d and .model == $m) | .fallbacks' <<<"$vdata")"

# The example beneath the rate, and what became of the cycle it happened on.
assert_eq "the newest rejection names its cycle" "${v_today_day}T060000Z-nodeV-5" \
  "$(jq -r '.last_rejection.cycle' <<<"$vdata")"
assert_eq "and which of the cycle's two attempts it was" "2" \
  "$(jq -r '.last_rejection.attempt' <<<"$vdata")"
assert_eq "and the model that produced it" "claude-sonnet-5" \
  "$(jq -r '.last_rejection.model' <<<"$vdata")"
assert_eq "carrying the eligible total it failed to account for" "9" \
  "$(jq -r '.last_rejection.eligible_total' <<<"$vdata")"
assert_eq "the unaccounted refs, from the corroboration record itself" "2" \
  "$(jq -r '.last_rejection.unaccounted | length' <<<"$vdata")"
assert_eq "with the record's own count beside them, not the shown one" "3" \
  "$(jq -r '.last_rejection.unaccounted_total' <<<"$vdata")"
assert_eq "and what the fleet did about it — a contradiction is no longer a lost cycle" \
  "recovered-by-fallback" "$(jq -r '.last_rejection.outcome' <<<"$vdata")"

# --- Co-Ordinator verdict quality: the per-band tally (issue #345) --------------
# Counts, not a rate: which band a rejection named, and how many items in it
# went unaccounted, summed across every rejected verdict in the window — never
# per-verdict figures, since a verdict rejected over one band is not "a
# verdict about that band" and has no sound per-band denominator. V1's one
# rejection names `tech-debt` alone; V5's two rejections both name `issues`
# (summed across attempts) and its second also names `tech-debt` again
# (summed with V1's); V3 is a rejection recorded before spec 3x's `bands`
# object existed and must land under an explicit `unknown` bucket rather than
# vanishing or being folded into a real band — carrying the count of its
# sibling `warning`'s `unaccounted` refs, since a pre-3v `none-selected`
# carries no figure of its own (the same sibling `last_rejection` reads).
assert_eq "a band named by two different rejections sums across them" "2" \
  "$(jq -r '.by_band[] | select(.band == "issues") | .rejected' <<<"$vdata")"
assert_eq "and its unaccounted count sums the same way" "2" \
  "$(jq -r '.by_band[] | select(.band == "issues") | .unaccounted' <<<"$vdata")"
assert_eq "a band named by rejections on two different verdicts also sums" "2" \
  "$(jq -r '.by_band[] | select(.band == "tech-debt") | .rejected' <<<"$vdata")"
assert_eq "unaccounted 1 (V1) + 2 (V5 attempt 2)" "3" \
  "$(jq -r '.by_band[] | select(.band == "tech-debt") | .unaccounted' <<<"$vdata")"
assert_eq "a rejection from before spec 3x's bands lands under an explicit unknown bucket" "1" \
  "$(jq -r '.by_band[] | select(.band == "unknown") | .rejected' <<<"$vdata")"
assert_eq "whose unaccounted count comes from the sibling warning the event predates" "1" \
  "$(jq -r '.by_band[] | select(.band == "unknown") | .unaccounted' <<<"$vdata")"
assert_eq "ranked most-rejected first" "issues" \
  "$(jq -r '.by_band[0].band' <<<"$vdata")"
assert_eq "with exactly the three bands this window saw" "3" \
  "$(jq -r '.by_band | length' <<<"$vdata")"

# The window is the retained log union and says so, so a short log cannot pass
# for a clean history.
assert_eq "the window names its own oldest event" "${v_yest}T02:00:00Z" \
  "$(jq -r '.window_from' <<<"$vdata")"
assert_eq "and its newest" "${v_today}T06:05:03Z" "$(jq -r '.window_to' <<<"$vdata")"
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
w_preclaimed="${today_day}T070000Z-preclaimed"
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
  # Stood down without a single attempt: every candidate was one the cycle's
  # own gather had already seen claimed (spec 17a's claim-skipped, 3q's
  # residue) — a selection defect, never contention.
  printf '{"ts":"2026-07-28T03:00:00Z","cycle":"%s","node":"nodeW","event":"cycle-start"}\n' "$w_preclaimed"
  printf '{"ts":"2026-07-28T03:00:01Z","cycle":"%s","node":"nodeW","event":"claim-skipped","repo":"o/a","item":"5","source":"tech-debt","cause":"pre-claimed"}\n' "$w_preclaimed"
  printf '{"ts":"2026-07-28T03:00:02Z","cycle":"%s","node":"nodeW","event":"stand-down","reason":"every candidate was already claimed before this cycle'"'"'s Co-Ordinator ran — skipped without an attempt","candidates":1,"cause":"pre-claimed","race_losses":0,"claim_skips":1}\n' "$w_preclaimed"
  printf '{"ts":"2026-07-28T03:00:03Z","cycle":"%s","node":"nodeW","event":"cycle-end"}\n' "$w_preclaimed"
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
assert_eq "a cycle whose every candidate was skipped stands down pre-claimed" "pre-claimed" \
  "$(cycle_field "$wdata" "$w_preclaimed" standdown_cause)"
assert_eq "and is not marked raced — a skip is a selection defect, not contention" "false" \
  "$(cycle_field "$wdata" "$w_preclaimed" raced)"
assert_eq "nor does a skip count as a race loss" "0" \
  "$(cycle_field "$wdata" "$w_preclaimed" race_losses)"
# All four cycles carry a `claim-lost` or `claim-skipped` beyond the bare
# no-op shape, so #271's filter must leave every one of them its detail row
# and count none of them.
assert_eq "a stand-down that carries more than the no-op shape is never aggregated" "0" \
  "$(jq -r '.noop_ticks.total' <<<"$wdata")"

# --- A past-the-cap void extract still publishes (requirement 4g) ----------------
# On 2026-08-14 the void extract reached 132539 bytes and the assemble's
# `--argjson void` died at `execve` with `Argument list too long` — on every node
# at once, because the extract is a property of the shared log, not of a node.
# jq never ran, so the write that followed emitted `window.DASHBOARD_DATA = ;`:
# a JavaScript syntax error, which froze every dashboard on the fleet while each
# tick went on logging a successful write.
#
# The pin is the input rather than the plumbing, and the assertion beside it
# proves the input is genuinely past MAX_ARG_STRLEN — otherwise a reintroduced
# `--argjson` would pass here and fail on the fleet.
v="$(new_home nodeV)"
vlog="$v/.local/state/poetic-agents/log.jsonl"
: > "$vlog"
vpad="$(printf 'x%.0s' {1..220})"
i=0
while (( i < 600 )); do
  printf '{"ts":"2026-07-26T00:00:00Z","event":"item-void","repo":"Poetic-Poems/agent-ops","item":"TD-BULK-%03d","stage":"coordinator","detail":"%s","evidence":"merged in #1"}\n' \
    "$i" "$vpad" >> "$vlog"
  i=$(( i + 1 ))
done

run_publish "$v"
assert_eq "a publish whose void extract is past the cap exits 0" "0" "$?"
vdata="$(data_of "$v")"
jq -e . <<<"$vdata" >/dev/null 2>&1
assert_eq "its data.js payload is valid JSON, not an empty assignment" "0" "$?"
assert_eq "the void extract really is past MAX_ARG_STRLEN (131072 bytes)" "1" \
  "$(( $(jq -c '.void' <<<"$vdata" | wc -c) > 131072 ))"
assert_eq "and every voided item survives into data.js" "600" \
  "$(jq '.void | length' <<<"$vdata")"

# --- The github_json build's own argv cap (requirement 4g, TD-PPagop-26081503) --
# `$prs` and `$claims` are the whole cross-repo PR index and claims cache, both
# of which grow with the fleet, and used to ride into this build as two more
# `--argjson` values.
#
# Not reached by driving the real script over its own CLI: two earlier,
# unconverted folds (`prs_json`'s own per-repo accumulation and its
# queue-answers merge, both outside TD-PPagop-26081503's four enumerated
# sites) take the same accumulator as their own `--argjson` first, so an
# accumulated `$prs_json` large enough to reach this build past the cap would
# already have died at one of those two calls before ever getting here — the
# same "cannot be driven end-to-end" situation
# test/gather-human-visibility-hygiene.test.sh documents for its own
# survivors-accumulator append. So the build is lifted by its own literal
# lines instead, the same extract_block technique, and driven directly with
# an oversized $prs_json.
extract_block() {  # extract_block <start-literal> <end-literal>
  awk -v s="$1" -v e="$2" \
    'index($0, s) == 1 { on = 1 } on { print } on && index($0, e) > 0 { exit }' \
    "$SCRIPT_DIR/scripts/publish-dashboard.sh"
}

# shellcheck disable=SC2016  # both single-quoted args are literal source text to match, not meant to expand
github_json_block="$(extract_block '  github_json="$(jq -n' 'claims_json")"')"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$github_json_block" != *'input as $prs | input as $claims'* ]]; then
  printf 'FAIL - could not extract the github_json build from scripts/publish-dashboard.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
run_github_json_block() {  # run_github_json_block <prs-json> <claims-json>
  # prs_json/claims_json/gh_ok/gh_err/now_iso/inputs_json/pr_index_file are
  # consumed only by the eval'd github_json_block, invisible to shellcheck.
  # shellcheck disable=SC2034
  ( prs_json="$1" claims_json="$2" gh_ok=true gh_err="" now_iso="2026-08-15T00:00:00Z" \
    inputs_json='{}' pr_index_file="$tmp_dir/empty-pr-index.json"
    printf '{}' > "$pr_index_file"
    eval "$github_json_block"
    # shellcheck disable=SC2154  # set by the eval'd github_json_block
    printf '%s' "$github_json" )
}
big_prs_json="$(jq -nc '[range(1300) | {repo: "o/a", number: ., title: ("pad " + ("x" * 100))}]')"
assert_eq "the oversized prs fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_prs_json" | wc -c) > 131072 ))"
built_github_json="$(run_github_json_block "$big_prs_json" '[]')"
jq -e . <<<"$built_github_json" >/dev/null 2>&1
assert_eq "a prs array past the argv cap still builds valid github_json" "0" "$?"
assert_eq "  ... carrying every one of the 1300 pull requests" \
  "1300" "$(jq '.prs | length' <<<"$built_github_json")"

big_claims_json="$(jq -nc '[range(1300) | {repo: "o/a", ts: "2026-08-15T00:00:00Z", detail: ("pad " + ("x" * 100))}]')"
assert_eq "the oversized claims fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_claims_json" | wc -c) > 131072 ))"
built_github_json="$(run_github_json_block '[]' "$big_claims_json")"
assert_eq "a claims array past the argv cap still builds valid github_json" "1300" \
  "$(jq '.claims | length' <<<"$built_github_json")"
assert_eq "  ... with ok/error/fetched_at and inputs still intact" "true  2026-08-15T00:00:00Z" \
  "$(jq -r '"\(.ok) \(.error) \(.fetched_at)"' <<<"$built_github_json")"

# --- The per-repo prs_json fold's own argv cap (requirement 4g, TD-PPagop-26081506) --
# `$prs_json` here is the running fleet-wide accumulator this same per-repo
# loop has already folded every earlier repo's page into, and `$prs` is the
# page just fetched for one more repo; both used to ride into this fold as
# `--argjson` values.
#
# Not reached by driving the real script over its own CLI: an accumulated
# `$prs_json` big enough to reach here past the cap would already have died at
# this very call, one repo earlier in the same per-repo loop — there is no
# separate downstream site to observe the death at, unlike `github_json`
# above. So the fold is lifted by its own literal lines, the same
# extract_block technique, and driven directly with an oversized `$prs_json`.
#
# The fold's own filter calls `checks_of`, which lives in `$PR_JQ` — lifted
# the same way, by its own start/end markers, so the extracted fold runs with
# the exact function the real script prepends to it.
extract_var_block() {  # extract_var_block <start-literal> <end-literal>
  awk -v s="$1" -v e="$2" '
    index($0, s) == 1 { on = 1; print; next }
    on { print }
    on && index($0, e) > 0 { exit }
  ' "$SCRIPT_DIR/scripts/publish-dashboard.sh"
}
pr_jq_start="PR_JQ='"
pr_jq_end="'"
pr_jq_def="$(extract_var_block "$pr_jq_start" "$pr_jq_end")"
if [[ "$pr_jq_def" != *'def checks_of:'* ]]; then
  printf 'FAIL - could not extract PR_JQ from scripts/publish-dashboard.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
# The fold's own opening/closing lines, as literal source text — the closing
# line's `\n` is doubled (`\\n`) so awk's own `-v` escape processing collapses
# it back to a single backslash before the substring match runs, rather than
# turning it into a real newline that can never match.
prs_fold_start="    prs_json=\"\$(jq -nc --arg slug \"\$slug\" \"\$PR_JQ\"'"
prs_fold_end="<<<\"\$prs_json\"\$'\\\\n'\"\$prs\")\""
prs_fold_block="$(extract_block "$prs_fold_start" "$prs_fold_end")"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$prs_fold_block" != *'input as $cur | input as $add'* ]]; then
  printf 'FAIL - could not extract the per-repo prs_json fold from scripts/publish-dashboard.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
run_prs_fold_block() {  # run_prs_fold_block <prs_json-accumulator> <prs-page>
  # PR_JQ/prs_json/prs/slug are consumed only by the eval'd definitions,
  # invisible to shellcheck.
  # shellcheck disable=SC2034
  ( eval "$pr_jq_def"
    prs_json="$1" prs="$2" slug="o/new"
    eval "$prs_fold_block"
    printf '%s' "$prs_json" )
}
big_prs_accum="$(jq -nc '[range(1300) | {repo: "o/a", number: ., title: ("pad " + ("x" * 100))}]')"
assert_eq "the oversized prs_json accumulator fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_prs_accum" | wc -c) > 131072 ))"
new_repo_page='[{"number":9001,"title":"new","url":"u","isDraft":false,"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"h","createdAt":"2026-08-15T00:00:00Z","reviewDecision":"","statusCheckRollup":[]}]'
folded_prs_json="$(run_prs_fold_block "$big_prs_accum" "$new_repo_page")"
jq -e . <<<"$folded_prs_json" >/dev/null 2>&1
assert_eq "an accumulator past the argv cap still folds a new repo's page" "0" "$?"
assert_eq "  ... carrying every one of the 1300 prior pull requests" \
  "1301" "$(jq 'length' <<<"$folded_prs_json")"
assert_eq "  ... plus the newly folded one, under the folding repo's own slug" \
  "o/new" "$(jq -r '.[-1].repo' <<<"$folded_prs_json")"

# --- The queue-answers merge's own argv cap (requirement 4g, TD-PPagop-26081506) --
# By this point in the tick `$prs_json` is the whole cross-repo PR index —
# the per-repo loop above has finished folding every repo in — and it used to
# ride into this merge as another `--argjson` value. `$queue_answers` is
# already a filename the real script builds (the merge-queue probe's own tsv
# scratch file), so it travels as `--rawfile`, a file jq reads itself rather
# than an argv element, and is unaffected by this conversion.
#
# Not reached by driving the real script over its own CLI, for the same
# reason as the fold above: an oversized `$prs_json` would already have died
# at that earlier call. So this merge, too, is lifted by its own literal
# lines and driven directly.
queue_merge_start="  prs_json=\"\$(jq -nc --rawfile qa \"\$queue_answers\" '"
queue_merge_end="<<<\"\$prs_json\" 2>/dev/null)\""
queue_merge_block="$(extract_block "$queue_merge_start" "$queue_merge_end")"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$queue_merge_block" != *'input as $prs'* ]]; then
  printf 'FAIL - could not extract the queue-answers merge from scripts/publish-dashboard.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
run_queue_merge_block() {  # run_queue_merge_block <prs-json> <queue-answers-file>
  # prs_json/queue_answers are consumed only by the eval'd queue_merge_block,
  # invisible to shellcheck.
  # shellcheck disable=SC2034
  ( prs_json="$1" queue_answers="$2"
    eval "$queue_merge_block"
    printf '%s' "$prs_json" )
}
big_prs_index="$(jq -nc '[range(1300) | {repo: "o/a", number: ., isDraft: false, title: ("pad " + ("x" * 100))}]')"
assert_eq "the oversized cross-repo prs index fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_prs_index" | wc -c) > 131072 ))"
qa_file="$tmp_dir/queue-answers-oversized.tsv"
printf 'o/a#0\ttrue\tfalse\ttrue\tfalse\n' > "$qa_file"
merged_prs_json="$(run_queue_merge_block "$big_prs_index" "$qa_file")"
jq -e . <<<"$merged_prs_json" >/dev/null 2>&1
assert_eq "a cross-repo index past the argv cap still merges valid queue answers" "0" "$?"
assert_eq "  ... carrying every one of the 1300 pull requests" \
  "1300" "$(jq 'length' <<<"$merged_prs_json")"
assert_eq "  ... with the one queued answer applied to the pull request it names" \
  "true" "$(jq -r '.[0].queued' <<<"$merged_prs_json")"
assert_eq "  ... and every other pull request left unqueued, not defaulted queued" \
  "null" "$(jq -r '.[1].queued' <<<"$merged_prs_json")"

# --- An assemble that failed is not published (the 2026-08-14 outage) ------------
# The cap was the cause; publishing the wreckage is what hid it for 75 minutes.
# Whatever kills the assemble — the cap, a malformed input, the OOM killer —
# `set -e` is off here, so jq's death leaves an empty `$data_json` behind rather
# than stopping the script. Writing that out replaces a working page with an
# unparseable one; keeping the last good data.js lets the page age visibly
# against its own `generated_at` instead, and the non-zero exit puts the reason
# in cron.log.
g="$(new_home nodeG)"
make_cycle "$g" "${today_day}T040000Z-21" 0.25 model-a
run_publish "$g"
g_data_js="$g/.local/state/poetic-agents/dashboard/data.js"
g_good="$(cat "$g_data_js")"

# Fail the assemble and nothing else: it is the one jq call bound to
# `generated_at`. As in the process-budget pin above, an exported function is
# the only way to reach a jq the publisher looks up on a PATH it hardens for
# cron itself.
(
  jq() {
    local a
    for a in "$@"; do [[ "$a" == "generated_at" ]] && return 126; done
    command jq "$@"
  }
  export -f jq
  env HOME="$g" "$PUBLISH" --no-github >/dev/null 2>"$tmp_dir/assemble.err"
)
assert_eq "a publish that cannot assemble its payload exits non-zero" "1" "$(( $? != 0 ))"
assert_contains "and says why" "could not assemble" "$(cat "$tmp_dir/assemble.err")"
assert_eq "and leaves the last good data.js untouched" "$g_good" "$(cat "$g_data_js")"
assert_lacks "so no page is ever served an empty assignment" \
  "window.DASHBOARD_DATA = ;" "$(cat "$g_data_js")"

# --- lock_stale_after agrees with the lock a running cycle actually holds (#357) -
# scripts/publish-dashboard.sh derives config.lock_stale_after by calling
# stage_budget_lock_seconds itself — the same function agent-cycle.sh calls to
# size the cycle lock and scripts/doctor.sh calls to report it — but it once
# passed a literal '{}' for OVERRIDES_JSON instead of stage_budget_all_overrides,
# so it silently ignored every timeout_<actor> / stage_timeouts config override
# the other two callers honour (the drift #326 / #348 already fixed for
# doctor.sh). CONFIG_FILE resolves relative to publish-dashboard.sh's own
# location with no override flag, so this exercises the override path by
# running a full copy of the checkout against a config.json this test controls,
# rather than hand-listing the libs the script sources (which would silently
# stop covering a real dependency the moment the script gained one).
h_app="$tmp_dir/overrides-app"
mkdir -p "$h_app"
tar -C "$SCRIPT_DIR" --exclude=.git -cf - . | tar -C "$h_app" -xf -
jq '.timeout_implementor = 500
    | .repos[0].stage_timeouts = ((.repos[0].stage_timeouts // {}) + {reviewer: 710})' \
  "$SCRIPT_DIR/config.json" > "$h_app/config.json"

h="$(new_home nodeH)"
env HOME="$h" "$h_app/scripts/publish-dashboard.sh" --no-github >/dev/null 2>&1
assert_eq "a publish against a config with overrides still exits 0" "0" "$?"
hdata="$(data_of "$h")"
# coordinator 20 + implementor 500 (plain timeout_ override, wider than its
# 150 min prior) + reviewer 710 (per-repo stage_timeouts override, wider than
# its 90 min prior) + enabler 30 + refiner 30 + 30 min slack = 1320 min, an
# exact number of hours so the assertion needs no float rounding — the same
# sum scripts/doctor.sh reports and agent-cycle.sh actually locks for, given
# the same overrides (test/stage-budget.test.sh's 9a covers the shared
# derivation itself; this covers that the dashboard script actually calls it).
assert_eq "the dashboard's derived lock threshold honours a plain timeout_<actor> override and a wider per-repo one" \
  "$(( (20 + 500 + 710 + 30 + 30 + 30) / 60 ))" \
  "$(jq -r '.config.lock_stale_after' <<<"$hdata")"

# --- Merge-queue awareness: queued badge, sticky dequeued warning (agent-ops#375) -
# lib/merge-queue.sh's own probe is unit-tested elsewhere (test/merge-queue.test.sh);
# this is the Publisher's integration of it — the queued/dequeued fields
# `.github.prs[]` carries, and that the dequeued warning persists across ticks
# until the pull request is queued again or merges/closes, not just the one tick
# it started on. Driven through DASHBOARD_GH_CMD like the GitHub-tick suite
# above, with a stub that answers `gh api graphql` (merge_queue_probe's own
# call) as well as the ordinary `pr list`/`issue list`/`run list`/`api` shapes.
q="$(new_home nodeQ)"
q_calls="$tmp_dir/gh-calls-q"
q_stub="$tmp_dir/stub-gh-queue.sh"
cat > "$q_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "$1 $2" in
  "pr list")
    case "$4" in
      "Poetic-Poems/agent-ops")
        printf '[{"number":300,"title":"land it via the queue","url":"https://github.com/Poetic-Poems/agent-ops/pull/300","state":"OPEN","isDraft":false,"createdAt":"2026-08-14T00:00:00Z","mergedAt":null,"closedAt":null,"mergeCommit":null,"author":{"login":"agent-ops-bot"},"labels":[{"name":"autonomous-agent"}],"reviewDecision":"APPROVED","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"agent/300","statusCheckRollup":[]},{"number":301,"title":"still a draft","url":"https://github.com/Poetic-Poems/agent-ops/pull/301","state":"OPEN","isDraft":true,"createdAt":"2026-08-14T00:00:00Z","mergedAt":null,"closedAt":null,"mergeCommit":null,"author":{"login":"agent-ops-bot"},"labels":[{"name":"autonomous-agent"}],"reviewDecision":"","baseRefName":"main","mergeable":"","mergeStateStatus":"","headRefName":"agent/301","statusCheckRollup":[]}]'
        ;;
      *) printf '[]' ;;
    esac ;;
  "issue list") printf '[]' ;;
  "run list")  printf '[]' ;;
  "api graphql")
    case "$*" in
      *"number=300"*)
        case "${QMQ_STATE:-queued}" in
          queued)   printf '{"queued":true,"dequeued_at":null,"dequeue_reason":null}' ;;
          unqueued) printf '{"queued":false,"dequeued_at":"2026-08-14T01:00:00Z","dequeue_reason":"checks failed"}' ;;
          fail)     echo "gh: something went wrong" >&2; exit 1 ;;
        esac ;;
      *) echo "unexpected merge-queue probe: $*" >&2; exit 1 ;;
    esac ;;
  "api --paginate")
    case "$3" in
      "repos/"*"/dependabot/alerts"*)     printf '[]' ;;
      "repos/"*"/code-scanning/alerts"*)  printf '[]' ;;
      *) exit 1 ;;
    esac ;;
  "api "*)
    case "$2" in
      "repos/"*"/issues?"*) printf '[]' ;;
      "repos/"*"/contents/tech-debt")
        printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1 ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$q_stub"

run_q_publish() {  # run_q_publish <QMQ_STATE>
  : > "$q_calls"
  env HOME="$q" NODE_NAME=nodeQ-self GH_CALL_LOG="$q_calls" QMQ_STATE="$1" \
      DASHBOARD_GH_CMD="$q_stub" "$PUBLISH" >/dev/null 2>&1
}

run_q_publish queued
assert_eq "a GitHub publish exits 0 against the queue stub" "0" "$?"
qdata="$(data_of "$q")"
assert_eq "a currently-queued pull request is badged queued" "true" \
  "$(jq -r '.github.prs[] | select(.number==300) | .queued' <<<"$qdata")"
assert_eq "and carries no dequeued warning" "false" \
  "$(jq -r '.github.prs[] | select(.number==300) | .dequeued' <<<"$qdata")"
assert_eq "a draft pull request is never probed for queue state" "0" \
  "$(grep -c 'number=301' "$q_calls")"
assert_eq "and reads not-queued by construction — a draft can never be enqueued" "false" \
  "$(jq -r '.github.prs[] | select(.number==301) | .queued' <<<"$qdata")"

run_q_publish unqueued
qdata="$(data_of "$q")"
assert_eq "removed from the queue without merging reads not-queued" "false" \
  "$(jq -r '.github.prs[] | select(.number==300) | .queued' <<<"$qdata")"
assert_eq "and raises the dequeued warning the tick it happens" "true" \
  "$(jq -r '.github.prs[] | select(.number==300) | .dequeued' <<<"$qdata")"

run_q_publish unqueued
qdata="$(data_of "$q")"
assert_eq "the warning is sticky: still unqueued a tick later still warns" "true" \
  "$(jq -r '.github.prs[] | select(.number==300) | .dequeued' <<<"$qdata")"

run_q_publish queued
qdata="$(data_of "$q")"
assert_eq "queued again clears the warning" "false" \
  "$(jq -r '.github.prs[] | select(.number==300) | .dequeued' <<<"$qdata")"
assert_eq "and the state badge reads queued once more" "true" \
  "$(jq -r '.github.prs[] | select(.number==300) | .queued' <<<"$qdata")"

# A probe that cannot answer must never be read as "definitely not queued" —
# the one direction that could wrongly clear or wrongly raise the warning — so
# it carries the prior tick's answer forward, badge and cache alike, and it
# never trips the page-wide "GitHub unavailable" alarm on its own: this one
# probe is best-effort, the same treatment sweep-human-visibility.sh gives it.
run_q_publish fail
qdata="$(data_of "$q")"
assert_eq "an unreadable probe carries the prior queued answer forward" "true" \
  "$(jq -r '.github.prs[] | select(.number==300) | .queued' <<<"$qdata")"
assert_eq "and never sets gh_ok false purely for a merge-queue read failing" "true" \
  "$(jq -r '.github.ok' <<<"$qdata")"

# --- Repositories without a merge queue render exactly as before -----------------
# isInMergeQueue is always false and no RemovedFromMergeQueueEvent ever fires for
# a repository with no queue, so the probe alone is enough: no repo-level
# detection is needed, and an ordinary open pull request never carries a queued
# or dequeued badge.
r="$(new_home nodeR)"
r_calls="$tmp_dir/gh-calls-r"
r_stub="$tmp_dir/stub-gh-noqueue.sh"
cat > "$r_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "$1 $2" in
  "pr list")
    case "$4" in
      "Poetic-Poems/agent-ops")
        printf '[{"number":400,"title":"an ordinary open pull request","url":"https://github.com/Poetic-Poems/agent-ops/pull/400","state":"OPEN","isDraft":false,"createdAt":"2026-08-14T00:00:00Z","mergedAt":null,"closedAt":null,"mergeCommit":null,"author":{"login":"agent-ops-bot"},"labels":[{"name":"autonomous-agent"}],"reviewDecision":"","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"agent/400","statusCheckRollup":[]}]'
        ;;
      *) printf '[]' ;;
    esac ;;
  "issue list") printf '[]' ;;
  "run list")  printf '[]' ;;
  "api graphql") printf '{"queued":false,"dequeued_at":null,"dequeue_reason":null}' ;;
  "api --paginate")
    case "$3" in
      "repos/"*"/dependabot/alerts"*)     printf '[]' ;;
      "repos/"*"/code-scanning/alerts"*)  printf '[]' ;;
      *) exit 1 ;;
    esac ;;
  "api "*)
    case "$2" in
      "repos/"*"/issues?"*) printf '[]' ;;
      "repos/"*"/contents/tech-debt")
        printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1 ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$r_stub"
: > "$r_calls"
env HOME="$r" NODE_NAME=nodeR-self GH_CALL_LOG="$r_calls" DASHBOARD_GH_CMD="$r_stub" "$PUBLISH" >/dev/null 2>&1
assert_eq "a publish against a repo with no merge queue exits 0" "0" "$?"
rdata="$(data_of "$r")"
assert_eq "its open pull request reads not-queued" "false" \
  "$(jq -r '.github.prs[] | select(.number==400) | .queued' <<<"$rdata")"
assert_eq "and never dequeued" "false" \
  "$(jq -r '.github.prs[] | select(.number==400) | .dequeued' <<<"$rdata")"

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
