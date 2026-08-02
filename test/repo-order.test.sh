#!/usr/bin/env bash
#
# test/repo-order.test.sh — regression test for lib/repo-order.sh
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 3, acceptance check 1l).
#
# Requirement 3's repo walk decides which repo the Co-Ordinator looks at
# first, every cycle, forever — and per-repo `nice` (config.json's
# `repos[].nice`, default 0, range -19..19) turns that from a plain
# least-recently-updated sort into a weighted one:
#
#   effective_age = (now − epoch(ts)) × 1.25^(−nice)
#
# A mis-weighted walk fails exactly like the system's signature failure mode
# (see the spec's Gotchas table on the fingerprint/back-pressure side of this
# codebase): silently. Nothing errors, nothing logs a mistake — the fleet's
# attention is just spent in the wrong place, cycle after cycle, and the only
# way anyone would notice is a repo that never seems to get picked despite a
# negative nice, or one that hogs every cycle despite a positive one. The
# neutral path (every nice absent or 0) carries the heaviest burden of proof
# of all: it must be provably identical to the old ascending-ISO `sort` this
# replaces, because every repo running today has no `nice` key at all, and a
# neutral-path regression would silently reorder every fleet's walk on the
# same day this ships.
#
# No `gh` stub appears anywhere below, and none is needed: the ordering was
# deliberately extracted out of agent-cycle.sh into the pure function this
# file tests, so the whole of requirement 3's weighting can be verified on
# fixed timestamps and a fixed clock, with no process spawned and no network
# reached.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/repo-order.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/repo-order.sh
. "$SCRIPT_DIR/lib/repo-order.sh"

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

# A fixed clock throughout: 2026-08-01T00:00:00Z. Never `date +%s` — a test
# whose fixtures shift with the day it happens to run is not a regression
# test.
now=1785542400

# --- 1. Neutral default order preservation ---
#
# Four repos, distinct timestamps, no `nice` key anywhere in repos_json.
# Ages against `now`: repo-d 61d, repo-a 47d, repo-c 31d, repo-b 12d — most-
# overdue (oldest timestamp) first is exactly ascending-ISO order, so the
# result must be byte-identical to `LC_ALL=C sort` of the same input lines.
neutral_input=$'2026-07-20T00:00:00Z\torg/repo-b\tmain\n2026-06-01T00:00:00Z\torg/repo-d\tmain\n2026-07-01T00:00:00Z\torg/repo-c\tmain\n2026-06-15T00:00:00Z\torg/repo-a\tmain'
neutral_repos='[{"slug":"org/repo-a"},{"slug":"org/repo-b"},{"slug":"org/repo-c"},{"slug":"org/repo-d"}]'
assert_eq "neutral: output is byte-identical to LC_ALL=C sort of the input" \
  "$(printf '%s' "$neutral_input" | LC_ALL=C sort)" \
  "$(printf '%s' "$neutral_input" | repo_order_by_effective_age "$now" "$neutral_repos")"

# --- 2. Neutral tie-break ---
#
# Two lines, identical timestamp, different slugs, no `nice` anywhere. The
# tie breaks on slug, ascending — which is also what a whole-line `sort`
# does once the timestamp field is equal.
tie_input=$'2026-07-15T00:00:00Z\torg/zzz\tmain\n2026-07-15T00:00:00Z\torg/aaa\tmain'
assert_eq "neutral tie-break: byte-identical to LC_ALL=C sort of the input" \
  "$(printf '%s' "$tie_input" | LC_ALL=C sort)" \
  "$(printf '%s' "$tie_input" | repo_order_by_effective_age "$now" '[]')"

# --- 3. Negative nice reorders ---
#
# o/aaa: ts 2026-07-01, nice 0  -> age 31d, effective 31d.
# o/bbb: ts 2026-07-20, nice -5 -> age 12d, effective 12d * 1.25^5 = 12 *
#        3.0517578125 =~ 36.62d. 36.62d > 31d, so bbb overtakes aaa despite
#        being chronologically newer.
neg_input=$'2026-07-01T00:00:00Z\to/aaa\tmain\n2026-07-20T00:00:00Z\to/bbb\tmain'
neg_repos='[{"slug":"o/aaa","nice":0},{"slug":"o/bbb","nice":-5}]'
neg_out="$(printf '%s' "$neg_input" | repo_order_by_effective_age "$now" "$neg_repos")"
assert_eq "negative nice -5: bbb sorts first" "o/bbb" "$(printf '%s' "$neg_out" | head -1 | cut -f2)"
assert_eq "negative nice -5: aaa sorts second" "o/aaa" "$(printf '%s' "$neg_out" | tail -1 | cut -f2)"

# It is a bias, not a jump: nice -3 (factor 1.953125) gives bbb an effective
# age of 12d * 1.953125 =~ 23.44d, still short of aaa's plain 31d, so aaa
# stays first.
neg3_repos='[{"slug":"o/aaa","nice":0},{"slug":"o/bbb","nice":-3}]'
neg3_out="$(printf '%s' "$neg_input" | repo_order_by_effective_age "$now" "$neg3_repos")"
assert_eq "nice -3 is not enough to overtake: aaa stays first" \
  "o/aaa" "$(printf '%s' "$neg3_out" | head -1 | cut -f2)"

# --- 4. Positive nice reorders ---
#
# o/aaa: ts 2026-07-01, nice 5 -> age 31d, effective 31d * 1.25^-5 = 31 *
#        0.32768 =~ 10.16d.
# o/bbb: ts 2026-07-20, nice 0 -> age 12d, effective 12d.
# 12d > 10.16d, so bbb — chronologically newer and unweighted — outranks
# aaa's discounted age.
pos_input=$'2026-07-01T00:00:00Z\to/aaa\tmain\n2026-07-20T00:00:00Z\to/bbb\tmain'
pos_repos='[{"slug":"o/aaa","nice":5},{"slug":"o/bbb","nice":0}]'
pos_out="$(printf '%s' "$pos_input" | repo_order_by_effective_age "$now" "$pos_repos")"
assert_eq "positive nice 5: bbb sorts first" "o/bbb" "$(printf '%s' "$pos_out" | head -1 | cut -f2)"
assert_eq "positive nice 5: aaa's age is discounted behind it" \
  "o/aaa" "$(printf '%s' "$pos_out" | tail -1 | cut -f2)"

# --- 5. Boundary values -19 and 19 ---
#
# o/aaa: ts 2026-07-31 (age 1d), nice -19 -> factor 1.25^19 =~ 69.39,
#        effective =~ 69.39d.
# o/bbb: ts 2026-01-01 (age 212d), nice 19 -> factor 1.25^-19 =~ 0.014412,
#        effective =~ 3.06d.
# Both extremes are accepted (no error, no clamp) and the arithmetic flips
# what a plain-age comparison would give: aaa, only a day old, outranks a
# 212-day-old repo once the boundary weights are applied.
boundary_input=$'2026-07-31T00:00:00Z\to/aaa\tmain\n2026-01-01T00:00:00Z\to/bbb\tmain'
boundary_repos='[{"slug":"o/aaa","nice":-19},{"slug":"o/bbb","nice":19}]'
boundary_out="$(printf '%s' "$boundary_input" | repo_order_by_effective_age "$now" "$boundary_repos")"
boundary_rc=$?
assert_eq "boundary nice -19/19 does not error" "0" "$boundary_rc"
assert_eq "boundary nice -19 (1d) outranks boundary nice 19 (212d)" \
  "o/aaa" "$(printf '%s' "$boundary_out" | head -1 | cut -f2)"

# --- 6. Epoch-0 sentinel outranks a fresh repo at extreme negative nice ---
#
# gh-failure timestamps arrive as "1970-01-01T00:00:00Z". At neutral nice
# its effective age is `now` itself (now - 0), astronomically larger than
# any real repo's age even after a nice -19 boost, so it still sorts first.
sentinel_input=$'1970-01-01T00:00:00Z\to/aaa\tmain\n2026-08-01T00:00:00Z\to/bbb\tmain'
sentinel_repos='[{"slug":"o/aaa","nice":0},{"slug":"o/bbb","nice":-19}]'
sentinel_out="$(printf '%s' "$sentinel_input" | repo_order_by_effective_age "$now" "$sentinel_repos")"
assert_eq "1970 sentinel at nice 0 beats a fresh repo at nice -19" \
  "o/aaa" "$(printf '%s' "$sentinel_out" | head -1 | cut -f2)"

# --- 7. Unparseable timestamp degrades to epoch 0; ties break by slug ---
#
# A garbage timestamp fails fromdateiso8601 and falls back to epoch 0 via
# `// 0`, exactly as the 1970 sentinel does. At equal nice the two then tie
# on effective age, and the tie breaks on slug — same as the neutral path.
garbage_input=$'not-a-timestamp\to/zzz\tmain\n1970-01-01T00:00:00Z\to/aaa\tmain'
garbage_out="$(printf '%s' "$garbage_input" | repo_order_by_effective_age "$now" '[]')"
assert_eq "garbage timestamp orders as epoch 0, tying the 1970 sentinel" \
  "o/aaa" "$(printf '%s' "$garbage_out" | head -1 | cut -f2)"
assert_eq "the garbage-timestamp line loses the tie by slug, not dropped" \
  "o/zzz" "$(printf '%s' "$garbage_out" | tail -1 | cut -f2)"

# --- 8. Permutation / no-starvation ---
#
# Five repos, extreme mixed weights, one slug (org/v) entirely absent from
# repos_json. Whatever order they come out in, no line may be added,
# dropped or altered: `sort` of the output must equal `sort` of the input.
perm_input=$'2026-01-01T00:00:00Z\torg/w\tmain\n2026-02-01T00:00:00Z\torg/x\tdev\n2026-03-01T00:00:00Z\torg/y\tmain\n2026-04-01T00:00:00Z\torg/z\tmain\n2026-05-01T00:00:00Z\torg/v\tmain'
perm_repos='[{"slug":"org/w","nice":19},{"slug":"org/x","nice":-19},{"slug":"org/y","nice":5},{"slug":"org/z","nice":-5}]'
assert_eq "extreme mixed weights permute lines but never lose or gain one" \
  "$(printf '%s' "$perm_input" | LC_ALL=C sort)" \
  "$(printf '%s' "$perm_input" | repo_order_by_effective_age "$now" "$perm_repos" | LC_ALL=C sort)"

# --- 9. A slug missing from repos_json is treated as nice 0 ---
#
# o/aaa appears nowhere in repos_json at all (not even with an explicit
# `"nice":0`). Its output, against o/bbb's explicit nice -5, must be
# byte-identical to the same input run against a repos_json that names
# o/aaa with nice 0 explicitly.
missing_input=$'2026-07-01T00:00:00Z\to/aaa\tmain\n2026-07-20T00:00:00Z\to/bbb\tmain'
missing_repos='[{"slug":"o/bbb","nice":-5}]'
explicit_zero_repos='[{"slug":"o/bbb","nice":-5},{"slug":"o/aaa","nice":0}]'
assert_eq "a slug absent from repos_json behaves exactly as nice 0" \
  "$(printf '%s' "$missing_input" | repo_order_by_effective_age "$now" "$explicit_zero_repos")" \
  "$(printf '%s' "$missing_input" | repo_order_by_effective_age "$now" "$missing_repos")"

# --- 10. Timestamps pass through byte-identical ---
#
# The whole line — ISO timestamp, slug, default branch — must reappear on
# stdout exactly as given: no reformatting, no truncation, no float ever
# printed in its place.
one_line=$'2026-07-15T12:34:56Z\torg/repo-x\tfeature/foo'
assert_eq "a single line passes through byte-identical" \
  "$one_line" \
  "$(printf '%s' "$one_line" | repo_order_by_effective_age "$now" '[]')"

# --- Empty stdin ---
empty_out="$(printf '' | repo_order_by_effective_age "$now" '[]')"
empty_rc=$?
assert_eq "empty stdin produces empty output" "" "$empty_out"
assert_eq "empty stdin exits 0" "0" "$empty_rc"

# --- 11. repo_nice_selection_config: the fingerprint producer's half ---
#
# The ordering above decides who goes first; this decides whether the no-op
# fingerprint can *see* that the deciding changed. lib/noop-skip.sh's canon
# hashes `selection_config` wholesale, so `{}` and an omitted `repo_nice`
# key are different bytes — and the shipped config, which sets no `nice`
# anywhere, must keep producing the omitted form, or every running fleet's
# none-selected fingerprint busts once for a behaviour change that never
# happened. test/noop-skip.test.sh pins the canon side of that contract;
# these cases pin the producer side.

# Neutral in every spelling — no nice, explicit 0, null, negative zero —
# produces a bare {} with no repo_nice key at all.
assert_eq "producer: neutral config (absent, 0, null, -0) yields bare {}" \
  "{}" \
  "$(repo_nice_selection_config '[{"slug":"org/a"},{"slug":"org/b","nice":0},{"slug":"org/c","nice":null},{"slug":"org/d","nice":-0}]')"

# Non-zero entries carry through — and only they do.
assert_eq "producer: only the non-zero entries are carried" \
  '{"repo_nice":{"org/a":-5,"org/c":19}}' \
  "$(repo_nice_selection_config '[{"slug":"org/a","nice":-5},{"slug":"org/b"},{"slug":"org/c","nice":19}]')"

# An integer-valued float spelling is admitted by the startup guard below
# (floor == self), so the producer floor-normalises it: `5.0` and `5` in
# config must fingerprint byte-identically on every jq version.
assert_eq "producer: an integer-valued float (5.0) is emitted as 5" \
  '{"repo_nice":{"org/x":5}}' \
  "$(repo_nice_selection_config '[{"slug":"org/x","nice":5.0}]')"

# --- 12. Startup guard: an invalid `nice` fails fast, before any repo is
#         touched ---
#
# The pure functions above are only part of requirement 3: config.json's
# `repos[].nice` also has to survive being *authored* — and a string, a
# fraction or a value outside -19..19 would otherwise be silently coerced by
# the ordering function's own `// 0` fallback into an order nobody asked for,
# with nothing on the page to say so. agent-cycle.sh guards against that at
# startup, the same way it already guards enabler_assignee and
# implementation_plan_path: fail loudly, name every offending slug, before
# the first `gh` call.
#
# That guard lives in agent-cycle.sh, not lib/repo-order.sh, so exercising it
# means driving the real entry point rather than a sourced function — with a
# stubbed `claude`/`gh` standing in for "never reached", exactly as
# test/role.test.sh drives agent-cycle.sh end to end. The one complication is
# CONFIG_FILE: it is `$SCRIPT_DIR/config.json`, derived from the running
# script's own directory (agent-cycle.sh:28), and this repository's real
# config.json must stay untouched — so a doctored `nice` can only be tested
# against a throwaway copy of the whole app tree. No `gh` call happens before
# the guard either way, so all of this stays fully offline.

guard_tmp="$(mktemp -d)"
trap 'rm -rf "$guard_tmp"' EXIT
guard_app="$guard_tmp/app"
mkdir -p "$guard_app"
cp "$SCRIPT_DIR/agent-cycle.sh" "$guard_app/"
cp -r "$SCRIPT_DIR/lib" "$SCRIPT_DIR/prompts" "$SCRIPT_DIR/scripts" "$guard_app/"

guard_home="$guard_tmp/home"
mkdir -p "$guard_home/.local/bin"
# Reaching either stub would mean the guard let a cycle through — which would
# otherwise spend real money or hit the real network before the guard has
# anything to say about it. $HOME/.local/bin is on agent-cycle.sh's own PATH
# construction (its "cron's environment is minimal" preamble) *after* the
# system directories, so on a machine with a real claude/gh installed the
# stub does not shadow them — it exists for the bare CI container, where
# nothing else satisfies the script's required-binary preflight. The real
# protection is that every case below asserts its exit came from a startup
# guard's message, all of which fire before any claude or gh invocation.
for stub in claude gh; do
  printf '#!/bin/sh\necho "%s stub: the nice guard should have prevented this" >&2\nexit 1\n' "$stub" \
    > "$guard_home/.local/bin/$stub"
  chmod +x "$guard_home/.local/bin/$stub"
done

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# run_guard CONFIG_JSON — writes CONFIG_JSON as the doctored app's
# config.json and runs the copied agent-cycle.sh against it: AGENT_OPS_ROLE
# active so the role guard (which runs first) does not short-circuit before
# ours does, and a throwaway HOME so nothing here can touch this machine's
# real state_dir. Sets $guard_out (combined stdout+stderr) and $guard_rc.
run_guard() {
  printf '%s' "$1" > "$guard_app/config.json"
  guard_out="$(env AGENT_OPS_ROLE=active HOME="$guard_home" "$guard_app/agent-cycle.sh" 2>&1)"
  guard_rc=$?
}

# --- Failure: one invalid shape at a time ---

run_guard '{"repos": [{"slug": "o/frac", "nice": 2.5}]}'
assert_eq "a non-integer nice exits 1" "1" "$guard_rc"
assert_contains "a non-integer nice names the fault" "invalid nice" "$guard_out"
assert_contains "a non-integer nice names the slug" "o/frac" "$guard_out"

run_guard '{"repos": [{"slug": "o/str", "nice": "3"}]}'
assert_eq "a string nice exits 1" "1" "$guard_rc"
assert_contains "a string nice names the fault" "invalid nice" "$guard_out"
assert_contains "a string nice names the slug" "o/str" "$guard_out"

run_guard '{"repos": [{"slug": "o/toolow", "nice": -20}]}'
assert_eq "nice below -19 exits 1" "1" "$guard_rc"
assert_contains "nice below -19 names the fault" "invalid nice" "$guard_out"
assert_contains "nice below -19 names the slug" "o/toolow" "$guard_out"

run_guard '{"repos": [{"slug": "o/toohigh", "nice": 20}]}'
assert_eq "nice above 19 exits 1" "1" "$guard_rc"
assert_contains "nice above 19 names the fault" "invalid nice" "$guard_out"
assert_contains "nice above 19 names the slug" "o/toohigh" "$guard_out"

# Two bad repos in one config: both must be named in the one failure, not
# just the first — an operator fixing one and re-running should not
# discover the second only by hitting the guard a second time.
run_guard '{"repos": [{"slug": "o/bad1", "nice": 2.5}, {"slug": "o/bad2", "nice": -20}]}'
assert_eq "two bad repos in one config exits 1" "1" "$guard_rc"
assert_contains "two bad repos: the first slug is named" "o/bad1" "$guard_out"
assert_contains "two bad repos: the second slug is named" "o/bad2" "$guard_out"

# --- Boundary and pass: -19, 19, absent and null all clear the guard ---
#
# A deliberately malformed `prompt_overrides` rides along in the same
# config. That guard sits immediately after this one in agent-cycle.sh, so a
# config built entirely of valid `nice` values still has to fail — for that
# *other* reason — proving this guard did not itself misfire on values it
# must accept, rather than merely proving it stayed quiet.
pass_config='{
  "repos": [
    {"slug": "o/lo", "nice": -19},
    {"slug": "o/hi", "nice": 19},
    {"slug": "o/absent"},
    {"slug": "o/null", "nice": null}
  ],
  "prompt_overrides": {"coordinator": "x"}
}'
run_guard "$pass_config"
assert_eq "boundary, absent and null nice values still exit 1 (a later guard, not this one)" \
  "1" "$guard_rc"
assert_contains "the failure is the prompt_overrides shape error, not the nice guard" \
  "prompt_overrides" "$guard_out"
assert_not_contains "valid nice values never trip the invalid-nice message" \
  "invalid nice" "$guard_out"

rm -rf "$guard_tmp"
trap - EXIT

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
