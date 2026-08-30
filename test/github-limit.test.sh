#!/usr/bin/env bash
#
# test/github-limit.test.sh — regression test for lib/github-limit.sh: the
# GitHub API budget check of requirement 2.0, the `gh` retry wrapper of
# requirement 2.0a, and the listing bound both PR-listing gatherers and the
# back-pressure gate share.
#
# Each of these has a direction it must never fail in, and each of those
# directions has a live incident behind it:
#
#   - The budget verdict must never read an *unknown* budget as an exhausted
#     one. `unknown` is what a node with a network fault produces, and turning
#     that into a fleet-wide stand-down would give a blip the same face as a
#     spent account — the exact confusion requirement 2.1's `reset_known` was
#     added to stop making in the Claude case.
#   - The wait plan must never wait longer than it was told to. The cycle holds
#     a lock and runs on a `cycle_interval_minutes` tick; a wrapper that slept
#     out a primary limit would still be sleeping when the next tick fired.
#   - The wrapper must never emit a retried call's stdout twice. `gh api
#     --paginate` streams each page as it arrives, so a limit met partway
#     through would otherwise duplicate the pages already printed and hand the
#     caller a document that is not JSON.
#   - `github_pr_list_truncated` must fire exactly at the cap, because the
#     back-pressure gate treats a truncated listing as a trip: a false negative
#     there opens a gate whose whole purpose is to stay shut (requirement 2.2).
#
# Run directly:
#
#   ./test/github-limit.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

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

# --- The budget verdict (requirement 2.0) ---

# The shape `gh api rate_limit` returns, trimmed to the two resources the
# verdict reads. `reset` is an epoch, as GitHub sends it.
snapshot() {  # <core-remaining> <core-reset> <graphql-remaining> <graphql-reset>
  jq -nc --argjson cr "$1" --argjson ck "$2" --argjson gr "$3" --argjson gk "$4" \
    '{resources: {core: {limit: 5000, remaining: $cr, reset: $ck},
                  graphql: {limit: 5000, remaining: $gr, reset: $gk}}}'
}

assert_eq "both resources above their floors is ok" \
  "ok" "$(github_limit_verdict "$(snapshot 4900 1786573579 4800 1786571720)" 300 100 | cut -f1)"

assert_eq "graphql below its floor is exhausted" \
  "exhausted" "$(github_limit_verdict "$(snapshot 4900 1786573579 12 1786571720)" 300 100 | cut -f1)"
assert_eq "…and names graphql as the binding resource" \
  "graphql" "$(github_limit_verdict "$(snapshot 4900 1786573579 12 1786571720)" 300 100 | cut -f2)"
assert_eq "…and carries its remaining points" \
  "12" "$(github_limit_verdict "$(snapshot 4900 1786573579 12 1786571720)" 300 100 | cut -f3)"
assert_eq "…and states GitHub's reset as a UTC timestamp, not an estimate" \
  "2026-08-12T21:55:20Z" "$(github_limit_verdict "$(snapshot 4900 1786573579 12 1786571720)" 300 100 | cut -f4)"

# The live shape of the 2026-08-12 incident: graphql spent while core still had
# 96% of its hour. Exactly the case a single-pool check would have missed.
assert_eq "core alone below its floor is exhausted, and names core" \
  "core" "$(github_limit_verdict "$(snapshot 40 1786573579 4800 1786571720)" 300 100 | cut -f2)"

# Both below: the later reset binds, so the stand-down derived from it covers
# both pools. Picking the earlier one would wake the cycle into a budget still
# exhausted on the other resource — and it would spend a Co-Ordinator finding
# that out. Asserted in both orders so the answer cannot come from the loop's
# iteration order.
assert_eq "both below: the later-resetting resource binds (core later)" \
  "core" "$(github_limit_verdict "$(snapshot 40 1786573579 12 1786571720)" 300 100 | cut -f2)"
assert_eq "both below: the later-resetting resource binds (graphql later)" \
  "graphql" "$(github_limit_verdict "$(snapshot 40 1786571720 12 1786573579)" 300 100 | cut -f2)"

# A floor of 0 turns that resource off — the documented way to disable half the
# check without disabling the other half.
assert_eq "a floor of 0 never trips, however little is left" \
  "ok" "$(github_limit_verdict "$(snapshot 0 1786573579 0 1786571720)" 0 0 | cut -f1)"
assert_eq "…and the other resource's floor still applies" \
  "core" "$(github_limit_verdict "$(snapshot 40 1786573579 0 1786571720)" 300 0 | cut -f2)"

# The direction that matters. Every one of these is a *missing* answer, and
# none of them is evidence that the budget is spent.
assert_eq "an empty snapshot is unknown, not exhausted" \
  "unknown" "$(github_limit_verdict "" 300 100 | cut -f1)"
assert_eq "an unparseable snapshot is unknown, not exhausted" \
  "unknown" "$(github_limit_verdict "not json at all" 300 100 | cut -f1)"
assert_eq "a snapshot with no resources object is ok, not exhausted" \
  "ok" "$(github_limit_verdict '{"message":"Bad credentials"}' 300 100 | cut -f1)"
assert_eq "a resource whose remaining is absent is not read as zero" \
  "ok" "$(github_limit_verdict '{"resources":{"core":{"reset":1786573579}}}' 300 100 | cut -f1)"

# The stand-down's own words. It has to say the reset is GitHub's, because the
# neighbouring Claude stand-down's reset often is not, and an operator reading
# the log needs to know which kind they are looking at without checking.
describe="$(github_limit_describe graphql 12 100 2026-08-12T21:55:20Z)"
assert_eq "the description names the resource, the shortfall and the reset" \
  "yes" "$(if [[ "$describe" == *"graphql has 12 point(s) left"* \
                 && "$describe" == *"below the 100"* \
                 && "$describe" == *"2026-08-12T21:55:20Z"* ]]; then echo yes; else echo no; fi)"
assert_eq "…and says the reset is stated rather than estimated" \
  "yes" "$(if [[ "$describe" == *"Stated by GitHub, not estimated"* ]]; then echo yes; else echo no; fi)"

# --- The meter is the headers, not the endpoint's body (agent-ops#1087) ---
#
# The live shape of 2026-08-30: `GET /rate_limit` read cold answers a full
# bucket with a reset exactly an hour from now, while the headers on any
# metered call show the bucket draining. The snapshot must be built from the
# headers, and a body that carries the empty-window signature must never be
# read as `ok`.
raw_headers="$(printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Remaining: 4882\r\nX-RateLimit-Reset: 1788076235\r\nX-RateLimit-Resource: core\r\nX-RateLimit-Used: 118\r\n\r\n{"verifiable_password_authentication":false}\n')"
assert_eq "core is read from a metered response's x-ratelimit headers" \
  '{"limit":5000,"used":118,"remaining":4882,"reset":1788076235}' \
  "$(github_limit_headers_to_resource "$raw_headers")"
assert_eq "…case-insensitively, and a refused call's headers still count" \
  '{"limit":5000,"used":5000,"remaining":0,"reset":1788076235}' \
  "$(github_limit_headers_to_resource "$(printf 'HTTP/2.0 403 Forbidden\r\nx-ratelimit-limit: 5000\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1788076235\r\nx-ratelimit-resource: core\r\nx-ratelimit-used: 5000\r\n\r\n{"message":"API rate limit exceeded for user ID 2049303."}\n')")"
assert_eq "a response without the headers yields nothing, not zeros" \
  "" "$(github_limit_headers_to_resource "$(printf 'HTTP/2.0 200 OK\r\nContent-Type: text/plain\r\n\r\nKeep it logically awesome.\n')")"
assert_eq "another pool's headers are not read as core's" \
  "" "$(github_limit_headers_to_resource "$(printf 'HTTP/2.0 200 OK\r\nX-RateLimit-Remaining: 29\r\nX-RateLimit-Reset: 1788076235\r\nX-RateLimit-Resource: search\r\nX-RateLimit-Used: 1\r\n\r\n{}\n')")"
assert_eq "graphql is read from the rateLimit object, resetAt as an epoch" \
  '{"limit":5000,"used":38,"remaining":4962,"reset":1788076295}' \
  "$(github_limit_graphql_resource '{"data":{"rateLimit":{"limit":5000,"cost":1,"used":38,"remaining":4962,"resetAt":"2026-08-30T07:51:35Z"}}}')"
assert_eq "a GraphQL error document yields nothing" \
  "" "$(github_limit_graphql_resource '{"errors":[{"message":"API rate limit already exceeded"}]}')"

# The signature itself, judged against a fixed clock: full, unused, and a
# reset within slack of now + 3600.
pristine='{"resources":{"core":{"limit":5000,"used":0,"remaining":5000,"reset":1788079600},"graphql":{"limit":5000,"used":0,"remaining":5000,"reset":1788079600}}}'
assert_eq "a full bucket whose reset is exactly an hour from now is the empty window" \
  "yes" "$(if github_limit_resource_pristine "$pristine" core 1788076000; then echo yes; else echo no; fi)"
assert_eq "…the same bucket an hour into a real window is not" \
  "no" "$(if github_limit_resource_pristine "$pristine" core 1788077800; then echo yes; else echo no; fi)"
assert_eq "…and a header reading, with its own probe used, is not" \
  "no" "$(if github_limit_resource_pristine '{"resources":{"core":{"limit":5000,"used":1,"remaining":4999,"reset":1788079600}}}' core 1788076000; then echo yes; else echo no; fi)"
assert_eq "a snapshot made only of empty windows is unknown, never ok" \
  "unknown" "$(github_limit_verdict "$pristine" 300 100 1788076000 | cut -f1)"
assert_eq "…while one real pool beside an empty window is judged on the real one" \
  "exhausted" "$(github_limit_verdict '{"resources":{"core":{"limit":5000,"used":0,"remaining":5000,"reset":1788079600},"graphql":{"limit":5000,"used":4990,"remaining":10,"reset":1788078000}}}' 300 100 1788076000 | cut -f1)"
assert_eq "…and a header-derived reading below the floor is exhausted" \
  "core" "$(github_limit_verdict '{"resources":{"core":{"limit":5000,"used":4900,"remaining":100,"reset":1788078000}}}' 300 100 1788076000 | cut -f2)"

# The snapshot assembled from the two reads, against a stub that answers them
# the way GitHub does (verified live 2026-08-30).
snap_stub_bin="$tmp_dir/snap-bin"
mkdir -p "$snap_stub_bin"
cat > "$snap_stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${SNAP_STUB_MODE:-ok}" in
  ok)
    if [[ "${1:-}" == "api" && "${2:-}" == "-i" && "${3:-}" == "meta" ]]; then
      printf 'HTTP/2.0 200 OK\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Remaining: 4450\r\nX-RateLimit-Reset: 1788076235\r\nX-RateLimit-Resource: core\r\nX-RateLimit-Used: 550\r\n\r\n{}\n'
      exit 0
    fi
    if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
      printf '{"data":{"rateLimit":{"limit":5000,"cost":1,"used":38,"remaining":4962,"resetAt":"2026-08-30T07:51:35Z"}}}\n'
      exit 0
    fi ;;
  rest-only)
    if [[ "${1:-}" == "api" && "${2:-}" == "-i" ]]; then
      printf 'HTTP/2.0 200 OK\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Remaining: 4450\r\nX-RateLimit-Reset: 1788076235\r\nX-RateLimit-Resource: core\r\nX-RateLimit-Used: 550\r\n\r\n{}\n'
      exit 0
    fi
    echo 'gh: Could not resolve host' >&2; exit 1 ;;
  down)
    echo 'gh: Could not resolve host: api.github.com' >&2; exit 1 ;;
esac
exit 1
STUB
chmod +x "$snap_stub_bin/gh"
snap_probe="$(PATH="$snap_stub_bin:$PATH" SNAP_STUB_MODE=ok github_limit_snapshot)"
assert_eq "the snapshot carries both pools, read from headers and rateLimit" \
  '{"core":{"limit":5000,"used":550,"remaining":4450,"reset":1788076235},"graphql":{"limit":5000,"used":38,"remaining":4962,"reset":1788076295}}' \
  "$(github_limit_budget_fields "$snap_probe")"
assert_eq "…and the verdict reads it as it always did" \
  "ok" "$(github_limit_verdict "$snap_probe" 300 100 | cut -f1)"
assert_eq "one pool unreadable leaves the other in the snapshot" \
  '{"core":{"limit":5000,"used":550,"remaining":4450,"reset":1788076235},"graphql":null}' \
  "$(github_limit_budget_fields "$(PATH="$snap_stub_bin:$PATH" SNAP_STUB_MODE=rest-only github_limit_snapshot)")"
assert_eq "both unreadable is no snapshot at all" \
  "rc=1:" "$(out="$(PATH="$snap_stub_bin:$PATH" SNAP_STUB_MODE=down github_limit_snapshot)"; echo "rc=$?:$out")"

# --- The record's arithmetic (requirement 2.0d), pure ---
earlier='{"resources":{"core":{"limit":5000,"used":550,"remaining":4450,"reset":1788076235},"graphql":{"limit":5000,"used":38,"remaining":4962,"reset":1788076295}}}'
later='{"resources":{"core":{"limit":5000,"used":610,"remaining":4390,"reset":1788076235},"graphql":{"limit":5000,"used":40,"remaining":4960,"reset":1788076295}}}'
rolled='{"resources":{"core":{"limit":5000,"used":7,"remaining":4993,"reset":1788079835},"graphql":{"limit":5000,"used":40,"remaining":4960,"reset":1788076295}}}'
assert_eq "movement within one window is the difference in used" \
  '{"core":60,"graphql":2,"window_rolled":false}' "$(github_limit_budget_delta "$earlier" "$later")"
assert_eq "across a roll it is the new window's used, and says so" \
  '{"core":7,"graphql":0,"window_rolled":true}' "$(github_limit_budget_delta "$later" "$rolled")"
assert_eq "a count that went backwards inside one window is null, not negative" \
  '{"core":null,"graphql":null,"window_rolled":false}' "$(github_limit_budget_delta "$later" "$earlier")"
assert_eq "no previous reading is no movement" \
  '{"core":null,"graphql":null,"window_rolled":false}' "$(github_limit_budget_delta "" "$later")"
assert_eq "a pool missing on one side is null for that pool only" \
  '{"core":60,"graphql":null,"window_rolled":false}' \
  "$(github_limit_budget_delta "$earlier" '{"resources":{"core":{"limit":5000,"used":610,"remaining":4390,"reset":1788076235}}}')"

# The recorder end to end: a `log_event` of the sourcing script's shape, the
# stub above, and three readings in a row.
record_log="$tmp_dir/record.jsonl"
log_event() {  # <event> <fields-json> — the shape agent-cycle.sh writes
  jq -nc --arg event "$1" --argjson fields "${2:-{\}}" '{event: $event} + $fields' >>"$record_log"
}
GITHUB_BUDGET_LAST_SNAPSHOT=""
GITHUB_BUDGET_CYCLE_OPEN=0
PATH="$snap_stub_bin:$PATH" SNAP_STUB_MODE=ok github_budget_record cycle-start
PATH="$snap_stub_bin:$PATH" SNAP_STUB_MODE=ok github_budget_record stage reviewer
PATH="$snap_stub_bin:$PATH" SNAP_STUB_MODE=down github_budget_record cycle-end
assert_eq "cycle-start opens the cycle's record" "1" "$GITHUB_BUDGET_CYCLE_OPEN"
assert_eq "three readings, three github-budget events" \
  "3" "$(jq -r 'select(.event == "github-budget") | .phase' "$record_log" | wc -l | tr -d ' ')"
assert_eq "the opening reading has no previous to move from" \
  'cycle-start true null' "$(jq -r 'select(.phase == "cycle-start") | "\(.phase) \(.readable) \(.since_previous.core)"' "$record_log")"
assert_eq "the stage reading names its stage and its movement (zero here: same stub answer)" \
  'stage reviewer 0 550' "$(jq -r 'select(.phase == "stage") | "\(.phase) \(.stage) \(.since_previous.core) \(.core.used)"' "$record_log")"
assert_eq "an unreadable reading is recorded as such, not skipped" \
  'cycle-end false' "$(jq -r 'select(.phase == "cycle-end") | "\(.phase) \(.readable)"' "$record_log")"
assert_eq "…and leaves the last good snapshot in place for the next delta" \
  "550" "$(jq -r '.resources.core.used' <<<"$GITHUB_BUDGET_LAST_SNAPSHOT")"
unset -f log_event

# --- Classifying a refusal (requirement 2.0a) ---
#
# The three messages observed in the wild. The secondary test runs first in the
# implementation because GitHub's secondary message contains "rate limit" too,
# and the two take different waits — a secondary limit states no reset.
assert_eq "GraphQL's primary refusal, the one the fleet met on 2026-08-12" \
  "primary" "$(github_limit_kind 'GraphQL: API rate limit already exceeded for user ID 2049303.')"
assert_eq "REST's primary refusal" \
  "primary" "$(github_limit_kind 'HTTP 403: API rate limit exceeded for user ID 2049303. (https://api.github.com/repos/x/y)')"
assert_eq "a secondary limit is not classed as primary" \
  "secondary" "$(github_limit_kind 'You have exceeded a secondary rate limit. Please wait a few minutes before you try again.')"
assert_eq "an ordinary failure is not a rate limit" \
  "none" "$(github_limit_kind 'HTTP 404: Not Found (https://api.github.com/repos/x/y)')"
assert_eq "an empty diagnostic is not a rate limit" \
  "none" "$(github_limit_kind '')"

# --- The wait plan (requirement 2.0a), pure: no clock, no network ---

GITHUB_LIMIT_MAX_WAIT_SECONDS=60
GITHUB_LIMIT_TOTAL_WAIT_SECONDS=120
GITHUB_LIMIT_SECONDARY_WAIT_SECONDS=20

assert_eq "a primary limit waits until GitHub's stated reset, plus one second" \
  "31" "$(github_limit_wait_plan primary 1000030 1000000 0)"
assert_eq "a reset beyond the per-call bound is not waited for at all" \
  "" "$(github_limit_wait_plan primary 1000600 1000000 0)"
assert_eq "a reset already in the past is not waited for" \
  "" "$(github_limit_wait_plan primary 999999 1000000 0)"
assert_eq "an unknown reset is not waited for — a guess is 2.0's business" \
  "" "$(github_limit_wait_plan primary 0 1000000 0)"
assert_eq "a secondary limit waits its fixed fallback, GitHub having stated none" \
  "20" "$(github_limit_wait_plan secondary 0 1000000 0)"
assert_eq "a non-rate-limit failure waits not at all" \
  "" "$(github_limit_wait_plan none 1000030 1000000 0)"

# The per-process budget. A gatherer that meets a limit on its first call must
# not be able to spend the whole cycle's patience on its remaining fifty.
assert_eq "the wait is clamped to what is left of the process budget" \
  "10" "$(github_limit_wait_plan primary 1000030 1000000 110)"
assert_eq "a spent process budget stops waiting entirely" \
  "" "$(github_limit_wait_plan primary 1000030 1000000 120)"
assert_eq "…and an overspent one does too, rather than going negative" \
  "" "$(github_limit_wait_plan primary 1000030 1000000 130)"

# --- The listing bound (requirements 2.2, 3c, 3e) ---

assert_eq "a listing at the cap is truncated" \
  "yes" "$(if github_pr_list_truncated 60 60; then echo yes; else echo no; fi)"
assert_eq "a listing below the cap is not" \
  "no" "$(if github_pr_list_truncated 59 60; then echo yes; else echo no; fi)"
assert_eq "a listing past the cap is truncated too, not silently accepted" \
  "yes" "$(if github_pr_list_truncated 61 60; then echo yes; else echo no; fi)"
assert_eq "an empty listing is not truncated" \
  "no" "$(if github_pr_list_truncated 0 60; then echo yes; else echo no; fi)"
assert_eq "a non-numeric count is not truncated" \
  "no" "$(if github_pr_list_truncated "" 60; then echo yes; else echo no; fi)"
assert_eq "the default cap is the shared constant, not gh's undeclared 30" \
  "yes" "$(if github_pr_list_truncated "$GITHUB_PR_LIST_LIMIT"; then echo yes; else echo no; fi)"

# --- The wrapper itself, against a stub `gh` (requirement 2.0a) ---
#
# The stub counts its own calls in a file, so "was it retried?" is an
# observation rather than an inference. It answers `api rate_limit` too,
# because the wrapper consults it to find a primary limit's reset — and the
# reset it reports is deliberately in the near future, so the retry path is
# exercised without the test sitting through a real GitHub window.
#
# "Near" is three seconds and not one, because the wrapper reads its own clock
# twice after this stub read its clock once (`now_epoch` for the still-ahead
# filter, then `date +%s` again for `github_limit_wait_plan`), and both compare
# strictly: `(( reset > now ))`. A reset one second out is therefore invalidated
# by a single second elapsing between those reads — not by anything slow, just
# by the second boundary happening to fall in the gap — and the wrapper then
# plans no wait, makes no retry, and the three assertions below all fail
# together. That is a coin toss on a loaded runner, and it lost twice running on
# CI's amd64 leg. Three seconds is still one clock read's worth of window
# (`wait` comes to 4, inside the 5-second `GITHUB_LIMIT_MAX_WAIT_SECONDS` bound
# set below) and costs the suite two more seconds of real sleep.
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
# $GH_STUB_MODE decides what the first call does; every later call succeeds.
count_file="$GH_STUB_COUNT"
# Not counted: the wrapper's own reset lookup is not the caller's call. The
# snapshot reads the `core` meter off a metered probe's headers and the
# `graphql` meter off the `rateLimit` object — a refused probe still answers
# with headers, which is the case the wrapper is in.
if [[ "${1:-}" == "api" && "${2:-}" == "-i" ]]; then
  printf 'HTTP/2.0 403 Forbidden\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Used: 5000\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: %s\r\nX-RateLimit-Resource: core\r\n\r\n{"message":"API rate limit exceeded"}\n' \
    "$(( $(date +%s) + 3 ))"
  exit 1
fi
if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
  printf '{"data":{"rateLimit":{"limit":5000,"cost":1,"used":5000,"remaining":0,"resetAt":"%s"}}}\n' \
    "$(date -u -d "@$(( $(date +%s) + 3 ))" +%Y-%m-%dT%H:%M:%SZ)"
  exit 0
fi
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"
if (( n == 1 )); then
  case "$GH_STUB_MODE" in
    primary)
      echo 'GraphQL: API rate limit already exceeded for user ID 2049303.' >&2
      exit 1 ;;
    secondary)
      echo 'You have exceeded a secondary rate limit. Please wait a few minutes.' >&2
      exit 1 ;;
    notfound)
      echo 'HTTP 404: Not Found (https://api.github.com/repos/x/y)' >&2
      exit 1 ;;
  esac
fi
echo "page-one"
echo "page-two"
STUB
chmod +x "$stub_bin/gh"
export PATH="$stub_bin:$PATH"
export GH_STUB_COUNT="$tmp_dir/gh-calls"

# Short waits: the policy is asserted above, in the pure function. What is
# under test here is the wrapper's plumbing, and it should not cost 20 seconds
# to check.
GITHUB_LIMIT_SECONDARY_WAIT_SECONDS=1
GITHUB_LIMIT_MAX_WAIT_SECONDS=5
GITHUB_LIMIT_TOTAL_WAIT_SECONDS=10

run_wrapped() {  # <mode> — resets the counter, returns "<rc>|<stdout>|<calls>"
  local mode="$1" out rc
  : > "$GH_STUB_COUNT"
  GITHUB_LIMIT_WAITED_SECONDS=0
  out="$(GH_STUB_MODE="$mode" gh pr list -R owner/repo 2>/dev/null)" && rc=0 || rc=$?
  printf '%s|%s|%s' "$rc" "$(tr '\n' ',' <<<"$out")" "$(cat "$GH_STUB_COUNT" 2>/dev/null || echo 0)"
}

primary_result="$(run_wrapped primary)"
assert_eq "a primary refusal is retried once and then succeeds" \
  "0" "$(cut -d'|' -f1 <<<"$primary_result")"
assert_eq "…the caller's gh was called exactly twice" \
  "2" "$(cut -d'|' -f3 <<<"$primary_result")"
# The whole reason stdout is buffered: the failed attempt printed nothing here,
# but a `--paginate` call would have printed its early pages, and emitting them
# alongside the retry's would hand the caller a document that is not JSON.
assert_eq "…and the successful attempt's stdout is emitted exactly once" \
  "page-one,page-two," "$(cut -d'|' -f2 <<<"$primary_result")"

secondary_result="$(run_wrapped secondary)"
assert_eq "a secondary refusal is retried once and then succeeds" \
  "0" "$(cut -d'|' -f1 <<<"$secondary_result")"
assert_eq "…the caller's gh was called exactly twice" \
  "2" "$(cut -d'|' -f3 <<<"$secondary_result")"

notfound_result="$(run_wrapped notfound)"
assert_eq "a 404 is not a rate limit and is returned unretried" \
  "1" "$(cut -d'|' -f1 <<<"$notfound_result")"
assert_eq "…the caller's gh was called exactly once" \
  "1" "$(cut -d'|' -f3 <<<"$notfound_result")"

# gh's own diagnosis must survive the wrapper: every call site in this
# repository either shows it or redirects it to a named file, and a wrapper
# that swallowed it would turn each of those into a silent failure.
: > "$GH_STUB_COUNT"
GITHUB_LIMIT_WAITED_SECONDS=0
notfound_err="$(GH_STUB_MODE=notfound gh pr list -R owner/repo 2>&1 >/dev/null)"
assert_eq "gh's stderr reaches the caller verbatim" \
  "yes" "$(if [[ "$notfound_err" == *"HTTP 404: Not Found"* ]]; then echo yes; else echo no; fi)"

# A process that has already spent its patience stops waiting, which is the
# clamp asserted purely above, observed here through the wrapper: the call is
# made once and the refusal returned.
: > "$GH_STUB_COUNT"
GITHUB_LIMIT_WAITED_SECONDS="$GITHUB_LIMIT_TOTAL_WAIT_SECONDS"
GH_STUB_MODE=primary gh pr list -R owner/repo >/dev/null 2>&1 && spent_rc=0 || spent_rc=$?
assert_eq "a process out of patience returns the refusal instead of waiting" \
  "1" "$spent_rc"
assert_eq "…having called gh exactly once" \
  "1" "$(cat "$GH_STUB_COUNT" 2>/dev/null || echo 0)"

# The wrapper is sourced into scripts running under `set -e`. A bare failing
# `command gh` inside it would abort the *caller* mid-wrapper — before the temp
# files are cleaned up and before gh's diagnosis is replayed — so the failure
# path is exercised under `set -e` at the real call-site shape, not just on the
# function alone. Same lesson as the Gotchas table's `set -e` row.
strict_probe="$(
  set -e
  # shellcheck source=lib/github-limit.sh
  . "$SCRIPT_DIR/lib/github-limit.sh"
  GITHUB_LIMIT_WAITED_SECONDS=0
  : > "$GH_STUB_COUNT"
  export GH_STUB_MODE=notfound
  out="$(gh pr list -R owner/repo 2>/dev/null)" || true
  echo "STRICT_MODE_SURVIVED:$out"
)"
assert_eq "a failing call under set -e returns to its caller instead of aborting it" \
  "STRICT_MODE_SURVIVED:" "$strict_probe"

# --- github_auth_probe (requirement 2.0b, agent-ops#691) ---
#
# The live incident this guards: a node's `GH_TOKEN` expired, and every cycle
# for ~3 hours ran a full Co-Ordinator engagement before every claim failed
# with `cause: "unreachable"` — a 401 folded into the same bucket as a network
# blip. `github_auth_probe` has to pull it back out, on the same free call, so
# a caller can tell "this will never clear itself" from "try again later".
auth_stub_bin="$tmp_dir/auth-bin"
mkdir -p "$auth_stub_bin"
cat > "$auth_stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" == "rate_limit" ]]; then
  case "${GH_AUTH_STUB_MODE:-ok}" in
    ok)
      printf '{"resources":{"core":{"remaining":100,"reset":0},"graphql":{"remaining":100,"reset":0}}}\n'
      exit 0 ;;
    unauthorized)
      echo 'gh: Bad credentials (HTTP 401)' >&2
      exit 1 ;;
    unreachable)
      echo 'gh: Could not resolve host: api.github.com' >&2
      exit 1 ;;
    notoken)
      # gh's real wording (verified against gh 2.98.0) when GH_TOKEN and
      # GITHUB_TOKEN are both unset/empty and there is no `gh auth login`
      # session either — it never sends a request, so there is no HTTP
      # status at all, unlike the `unauthorized` mode above.
      printf 'To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n' >&2
      exit 4 ;;
  esac
fi
echo "unexpected call: $*" >&2
exit 1
STUB
chmod +x "$auth_stub_bin/gh"
# Prepended ahead of the wrapper-test stub above, whose own `api rate_limit`
# branch (line ~204) answers unconditionally and would otherwise shadow this
# one for every mode.
export PATH="$auth_stub_bin:$PATH"

probe_result="$(GH_AUTH_STUB_MODE=ok github_auth_probe)"
assert_eq "working credentials probe as ok" "ok" "$(cut -f1 <<<"$probe_result")"
assert_eq "…with no detail carried" "" "$(cut -f2 <<<"$probe_result")"

probe_result="$(GH_AUTH_STUB_MODE=unauthorized github_auth_probe)"
assert_eq "a 401 probes as unauthorized, not unreachable" \
  "unauthorized" "$(cut -f1 <<<"$probe_result")"
assert_eq "…and carries GitHub's own response as detail" \
  "yes" "$(if [[ "$(cut -f2 <<<"$probe_result")" == *"Bad credentials (HTTP 401)"* ]]; then echo yes; else echo no; fi)"

probe_result="$(GH_AUTH_STUB_MODE=unreachable github_auth_probe)"
assert_eq "a network fault probes as unreachable, not unauthorized" \
  "unreachable" "$(cut -f1 <<<"$probe_result")"

# TD-PPagop-26082306: a missing/empty GH_TOKEN (and no `gh auth login`
# session) makes gh refuse locally before it ever sends a request — no HTTP
# status at all — which used to match neither the 401 pattern above nor
# anything else, so it fell through to `unreachable` and bought a full
# Co-Ordinator engagement every cycle exactly as an expired token did before
# agent-ops#691.
probe_result="$(GH_AUTH_STUB_MODE=notoken github_auth_probe)"
assert_eq "a missing token probes as unauthorized, not unreachable" \
  "unauthorized" "$(cut -f1 <<<"$probe_result")"
assert_eq "…and the detail names the missing token rather than an HTTP status" \
  "yes" "$(if [[ "$(cut -f2 <<<"$probe_result")" == "no token present"* ]]; then echo yes; else echo no; fi)"
assert_eq "…and never claims an HTTP 401 the way a rejected token would" \
  "no" "$(if [[ "$(cut -f2 <<<"$probe_result")" == *"HTTP 401"* ]]; then echo yes; else echo no; fi)"

# Every caller reads this with `read -r v d < <(github_auth_probe)`, and
# `read` fails — non-zero, though it still populates both variables — for a
# final line with no trailing newline. agent-cycle.sh sources this file and
# runs under `set -e`, so that "failure" would silently abort the whole
# cycle right at the read, on every call, regardless of what the probe
# found — exactly the shape of a real regression this caught (agent-ops#691:
# the first cut of this function had no trailing newline, and every stood-up
# cycle died at requirement 2.0b before 2.1's usage-limit check ever ran).
# Same lesson as the `gh` wrapper's own "returns to its caller instead of
# aborting it" assertion above, aimed at this function instead.
for probe_mode in ok unauthorized unreachable; do
  strict_probe="$(
    set -e
    v="" d=""
    # shellcheck disable=SC2034  # $d is read to consume the field, never used
    IFS=$'\t' read -r v d < <(GH_AUTH_STUB_MODE="$probe_mode" github_auth_probe)
    echo "SURVIVED_SET_E:$v"
  )"
  assert_eq "github_auth_probe's $probe_mode output survives a read under set -e" \
    "SURVIVED_SET_E:$probe_mode" "$strict_probe"
done

# Same check for `notoken`, kept out of the loop above since its stub mode
# name and its verdict differ (`notoken` probes as `unauthorized`, not
# `notoken`).
strict_probe="$(
  set -e
  v="" d=""
  # shellcheck disable=SC2034  # $d is read to consume the field, never used
  IFS=$'\t' read -r v d < <(GH_AUTH_STUB_MODE=notoken github_auth_probe)
  echo "SURVIVED_SET_E:$v"
)"
assert_eq "github_auth_probe's notoken output survives a read under set -e" \
  "SURVIVED_SET_E:unauthorized" "$strict_probe"

echo
if (( failures == 0 )); then
  echo "All github-limit assertions passed."
  exit 0
else
  echo "$failures github-limit assertion(s) FAILED."
  exit 1
fi
