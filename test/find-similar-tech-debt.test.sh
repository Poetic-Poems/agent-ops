#!/usr/bin/env bash
#
# test/find-similar-tech-debt.test.sh — regression tests for
# scripts/find-similar-tech-debt.sh (agent-ops#631): the dedup check a stage
# runs before reserving a new tech-debt id, per TECH-DEBT.md's "Filing
# alongside other work".
#
# Behaviours asserted:
#
#   - **An exact normalised-title match against an `open` or `in-progress`
#     record is found**, printed as `<id>\t<title>`, and the script exits 1.
#   - **A containment match (either direction) is found too**, once *both*
#     the normalised needle and the normalised candidate title reach eight
#     characters.
#   - **A `resolved` or `not-debt` record with the same title is not
#     matched** — only `open`/`in-progress` records are live duplicates.
#   - **A title under the eight-character floor matches only exactly**, never
#     by containment, on either side of the comparison — short generic
#     titles would otherwise swamp the register with noise, whichever side
#     they're on.
#   - **An unrelated title finds nothing and exits 0.**
#   - **An empty `tech-debt/` directory (or none at all) is not an error.**
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/find-similar-tech-debt.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIND="$SCRIPT_DIR/scripts/find-similar-tech-debt.sh"

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

# a_repo -- a fresh scratch git repo with a tech-debt/ directory, so
# find-similar-tech-debt.sh's own `git rev-parse --show-toplevel` resolves
# somewhere real. Prints its path.
a_repo() {
  local dir
  dir="$(mktemp -d "$tmp_dir/repo-XXXXXX")"
  git -C "$dir" init -q
  mkdir -p "$dir/tech-debt"
  printf '%s\n' "$dir"
}

item() {  # item <dir> <id> <status> <title>
  local dir="$1" id="$2" status="$3" title="$4"
  cat > "$dir/tech-debt/$id.md" <<EOF
---
id: $id
title: $title
status: $status
filed: 2026-08-22
---

Body.
EOF
}

run_find() { ( cd "$1" && "$FIND" "$2" ); }

# --- Exact match against an open record -------------------------------------
repo="$(a_repo)"
item "$repo" TD-PPtest-26082201 open "The retry loop in lib/foo.sh never backs off"
out="$(run_find "$repo" "The retry loop in lib/foo.sh never backs off")"; rc=$?
assert_eq "exact match: exit 1" "1" "$rc"
assert_eq "  ... prints the matching id and title" \
  "TD-PPtest-26082201	The retry loop in lib/foo.sh never backs off" "$out"

# --- Containment match, either direction ------------------------------------
repo="$(a_repo)"
item "$repo" TD-PPtest-26082202 in-progress "lib/foo.sh's retry loop never backs off under load"
out="$(run_find "$repo" "lib/foo.sh's retry loop never backs off")"; rc=$?
assert_eq "containment match (needle inside title): exit 1" "1" "$rc"
assert_eq "  ... found the in-progress record" "1" "$(grep -c '^TD-PPtest-26082202' <<<"$out")"

repo="$(a_repo)"
item "$repo" TD-PPtest-26082203 open "the retry loop never backs off"
out="$(run_find "$repo" "the retry loop never backs off, even under sustained load")"; rc=$?
assert_eq "containment match (title inside needle): exit 1" "1" "$rc"

# --- resolved/not-debt records are not matched ------------------------------
repo="$(a_repo)"
item "$repo" TD-PPtest-26082204 resolved "The retry loop in lib/foo.sh never backs off"
item "$repo" TD-PPtest-26082205 not-debt "The retry loop in lib/foo.sh never backs off"
out="$(run_find "$repo" "The retry loop in lib/foo.sh never backs off")"; rc=$?
assert_eq "resolved/not-debt records ignored: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"

# --- Below the length floor: exact only, never containment ------------------
# The floor gates both the query's own normalised length and the candidate
# title's — a short query ("fix bug") must not match a longer, unrelated
# existing title merely because it contains that short phrase.
repo="$(a_repo)"
item "$repo" TD-PPtest-26082206 open "please fix bug now"
out="$(run_find "$repo" "fix bug")"; rc=$?
assert_eq "short needle: no containment match, exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"

item "$repo" TD-PPtest-26082209 open "fix bug"
out="$(run_find "$repo" "fix bug")"; rc=$?
assert_eq "short needle: exact match still works, exit 1" "1" "$rc"

# The floor gates the *candidate title's* own normalised length too, not just
# the query's — a short existing title ("fix bug") must not match a longer,
# unrelated query merely because the query happens to contain that short
# phrase.
repo="$(a_repo)"
item "$repo" TD-PPtest-26082210 open "fix bug"
out="$(run_find "$repo" "please fix bug in the retry loop before release")"; rc=$?
assert_eq "short candidate title: no containment match, exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"

# --- Unrelated title finds nothing -------------------------------------------
repo="$(a_repo)"
item "$repo" TD-PPtest-26082207 open "The retry loop in lib/foo.sh never backs off"
out="$(run_find "$repo" "a wholly unrelated gap about purple elephants dancing")"; rc=$?
assert_eq "unrelated title: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"

# --- No tech-debt directory at all is not an error --------------------------
repo="$(mktemp -d "$tmp_dir/norepo-XXXXXX")"
git -C "$repo" init -q
out="$(run_find "$repo" "anything at all")"; rc=$?
assert_eq "no tech-debt directory: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$failures test(s) failed."
  exit 1
fi
