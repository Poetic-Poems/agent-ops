#!/usr/bin/env bash
#
# test/expensive-gather-cache.test.sh — regression test for
# lib/expensive-gather-cache.sh (docs/IMPLEMENTATION-PIPELINE-SPEC.md
# requirement 48, agent-ops#1086): the per-node cache that lets
# `gather_ordered_repos` read one configured repo's expensive bands fresh
# per cycle and reuse every other one's last read.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/expensive-gather-cache.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/expensive-gather-cache.sh
. "$SCRIPT_DIR/lib/expensive-gather-cache.sh"

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

tmp_state="$(mktemp -d)"
trap 'rm -rf "$tmp_state"' EXIT

repos_ab='[{"slug":"o/a"},{"slug":"o/b"}]'
repos_abc='[{"slug":"o/a"},{"slug":"o/b"},{"slug":"o/c"}]'

# --- Nothing cached yet: ties break on slug, ascending ----------------------
assert_eq "with two never-cached repos, the alphabetically first slug wins the tie" \
  "o/a" "$(expensive_gather_pick_repo "$tmp_state" "$repos_ab")"

# --- A cache load before any save returns nothing ---------------------------
assert_eq "loading an uncached repo prints nothing" \
  "" "$(expensive_gather_cache_load "$tmp_state" "o/a")"

# --- Save, then pick rotates to the other repo ------------------------------
snapshot_a='{"gathered_at":"2026-08-30T00:00:00Z","issues_raw":[{"ref":"1"}]}'
assert_eq "save reports success" "0" \
  "$(expensive_gather_cache_save "$tmp_state" "o/a" "$snapshot_a"; echo "$?")"
assert_eq "once o/a is cached, o/b (never cached) is picked next" \
  "o/b" "$(expensive_gather_pick_repo "$tmp_state" "$repos_ab")"

# --- Load round-trips exactly what was saved --------------------------------
assert_eq "load round-trips the saved object" \
  "$(jq -c . <<<"$snapshot_a")" \
  "$(expensive_gather_cache_load "$tmp_state" "o/a")"

# --- Saving o/b, then the oldest-mtime repo (o/a) is picked again -----------
sleep 1
assert_eq "save o/b succeeds" "0" \
  "$(expensive_gather_cache_save "$tmp_state" "o/b" '{"gathered_at":"2026-08-30T00:01:00Z"}'; echo "$?")"
assert_eq "with both cached, the older cache file (o/a) is picked" \
  "o/a" "$(expensive_gather_pick_repo "$tmp_state" "$repos_ab")"

# --- A third, never-cached repo always outranks two already-cached ones ----
assert_eq "a never-cached repo (o/c) is picked over two already-cached ones" \
  "o/c" "$(expensive_gather_pick_repo "$tmp_state" "$repos_abc")"

# --- A repo with no configured entries picks nothing ------------------------
assert_eq "an empty repo set picks nothing" \
  "" "$(expensive_gather_pick_repo "$tmp_state" "[]")"

# --- A single configured repo is always picked, cached or not (--repo) -----
sleep 1
expensive_gather_cache_save "$tmp_state" "o/a" '{"gathered_at":"2026-08-30T00:02:00Z"}' >/dev/null
assert_eq "the one repo in a --repo-filtered set is always picked" \
  "o/a" "$(expensive_gather_pick_repo "$tmp_state" '[{"slug":"o/a"}]')"

# --- A corrupt cache file loads as nothing, not a crash ---------------------
printf 'not json' > "$tmp_state/expensive-gather/o_a.json"
assert_eq "a corrupt cache file loads as empty, not a parse error" \
  "" "$(expensive_gather_cache_load "$tmp_state" "o/a")"

# --- Saving is atomic: no partial file is ever visible mid-write -----------
assert_eq "save leaves no stray .tmp file behind" \
  "0" "$(find "$tmp_state/expensive-gather" -name '*.tmp.*' | wc -l)"

# --- The pick does not slice its sorted stream with a reader that quits -----
# agent-ops#806's own shape: the pick's `sort` cannot emit until it has read
# every candidate, so a reader that closes the pipe on its first line takes
# SIGPIPE, `pipefail` promotes the 141 to the whole pipeline, and the
# caller's `$(…)` under `set -e` (lib/candidate-gather.sh) aborts the gather
# and with it the cycle. It only bites once the sorted output outgrows the
# 64 KiB pipe buffer, which no live `repositories` list approaches — which is
# exactly why the shape has to be pinned rather than reasoned about. This set
# is deliberately past that buffer: with `head -n1` the caller below exits
# 141, with a reader that consumes its input (`sed -n '1p'`) it exits 0.
#
# The caller runs as its own `bash -c` rather than a subshell here, and that
# is load-bearing: a `( … ) || status=$?` would put the subshell in a context
# where bash suppresses `set -e` *inside* it too, so the failing assignment
# would be ignored and this assertion would pass against either reader. A
# separate process, with `$?` read on the next line, reproduces the real
# caller's errexit rather than a defanged copy of it.
# The set travels as a file, not as an argument: 2000 slugs is past Linux's
# own 128 KiB ceiling on a single argv string, and an `Argument list too long`
# would fail this assertion for a reason that has nothing to do with the pick.
jq -nc '[range(2000)
  | {slug: ("o/repo-with-a-deliberately-long-name-to-outgrow-the-buffer-\(.)")}]' \
  > "$tmp_state/big-repos.json"
bash -c '
  set -euo pipefail
  . "$1/lib/expensive-gather-cache.sh"
  picked="$(expensive_gather_pick_repo "$2" "$(cat "$3")")"
  [[ -n "$picked" ]]' _ "$SCRIPT_DIR" "$tmp_state" "$tmp_state/big-repos.json" >/dev/null 2>&1
big_status=$?
assert_eq "a repo set larger than one pipe buffer picks cleanly, never SIGPIPE" \
  "0" "$big_status"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
