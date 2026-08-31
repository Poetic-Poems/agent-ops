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
#   effective_age = (now − epoch(ts)) × 2^(−nice/3)
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
# o/bbb: ts 2026-07-20, nice -5 -> age 12d, effective 12d * 2^(5/3) =~ 12 *
#        3.1748021039 =~ 38.10d. 38.10d > 31d, so bbb overtakes aaa despite
#        being chronologically newer.
neg_input=$'2026-07-01T00:00:00Z\to/aaa\tmain\n2026-07-20T00:00:00Z\to/bbb\tmain'
neg_repos='[{"slug":"o/aaa","nice":0},{"slug":"o/bbb","nice":-5}]'
neg_out="$(printf '%s' "$neg_input" | repo_order_by_effective_age "$now" "$neg_repos")"
assert_eq "negative nice -5: bbb sorts first" "o/bbb" "$(printf '%s' "$neg_out" | head -1 | cut -f2)"
assert_eq "negative nice -5: aaa sorts second" "o/aaa" "$(printf '%s' "$neg_out" | tail -1 | cut -f2)"

# It is a bias, not a jump: nice -3 (factor 2) gives bbb an effective
# age of 12d * 2 = 24d, still short of aaa's plain 31d, so aaa
# stays first.
neg3_repos='[{"slug":"o/aaa","nice":0},{"slug":"o/bbb","nice":-3}]'
neg3_out="$(printf '%s' "$neg_input" | repo_order_by_effective_age "$now" "$neg3_repos")"
assert_eq "nice -3 is not enough to overtake: aaa stays first" \
  "o/aaa" "$(printf '%s' "$neg3_out" | head -1 | cut -f2)"

# --- 4. Positive nice reorders ---
#
# o/aaa: ts 2026-07-01, nice 5 -> age 31d, effective 31d * 2^(-5/3) =~ 31 *
#        0.31498 =~ 9.76d.
# o/bbb: ts 2026-07-20, nice 0 -> age 12d, effective 12d.
# 12d > 9.76d, so bbb — chronologically newer and unweighted — outranks
# aaa's discounted age.
pos_input=$'2026-07-01T00:00:00Z\to/aaa\tmain\n2026-07-20T00:00:00Z\to/bbb\tmain'
pos_repos='[{"slug":"o/aaa","nice":5},{"slug":"o/bbb","nice":0}]'
pos_out="$(printf '%s' "$pos_input" | repo_order_by_effective_age "$now" "$pos_repos")"
assert_eq "positive nice 5: bbb sorts first" "o/bbb" "$(printf '%s' "$pos_out" | head -1 | cut -f2)"
assert_eq "positive nice 5: aaa's age is discounted behind it" \
  "o/aaa" "$(printf '%s' "$pos_out" | tail -1 | cut -f2)"

# --- 5. Boundary values -19 and 19 ---
#
# o/aaa: ts 2026-07-31 (age 1d), nice -19 -> factor 2^(19/3) =~ 80.63,
#        effective =~ 80.63d.
# o/bbb: ts 2026-01-01 (age 212d), nice 19 -> factor 2^(-19/3) =~ 0.012402,
#        effective =~ 2.63d.
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

# An integer-valued float spelling is admitted by the schema gate
# (config.schema.json's `nice` is an integer -19..19, and `5.0 == floor(5.0)`
# satisfies jq's own integer test), so the producer floor-normalises it: `5.0`
# and `5` in config must fingerprint byte-identically on every jq version.
assert_eq "producer: an integer-valued float (5.0) is emitted as 5" \
  '{"repo_nice":{"org/x":5}}' \
  "$(repo_nice_selection_config '[{"slug":"org/x","nice":5.0}]')"

# A `nice` outside -19..19, non-integer or otherwise malformed is now caught
# by the schema gate (config.schema.json, docs/IMPLEMENTATION-PIPELINE-SPEC.md
# requirement 1b) before agent-cycle.sh reads a single repos[] entry, rather
# than by a hand-written startup guard in this script — so the end-to-end
# "agent-cycle.sh actually refuses to start" case lives in
# test/config-schema.test.sh alongside the schema's own unit cases (10 above
# already pins the boundary values -19/19/absent/null against the pure
# ordering functions).

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
