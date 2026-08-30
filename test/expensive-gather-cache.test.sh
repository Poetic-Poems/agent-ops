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

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
