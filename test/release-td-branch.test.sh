#!/usr/bin/env bash
#
# test/release-td-branch.test.sh — regression tests for
# scripts/release-td-branch.sh (agent-ops#631), the workflow-triggered half of
# "Filing alongside other work" (TECH-DEBT.md): once a tech-debt/<id>.md
# record lands on main via any pull request, its td/<id> reservation branch
# is no longer needed, and this script is what retires it — the other half of
# scripts/sweep-orphan-branches.sh's own deliberate blind spot (issue #545),
# which never deletes a reservation-only branch because it cannot tell
# whether the id has since been filed elsewhere.
#
# Behaviours asserted:
#
#   - **A newly added tech-debt/<id>.md whose td/<id> branch still exists is
#     deleted**, and reported "deleted".
#   - **An id whose branch is already gone reports "absent"**, not an error —
#     the ordinary case, since "Claiming an item"'s own branch is retired by
#     GitHub's delete-on-merge setting before this workflow ever runs.
#   - **A delete call that fails reports "warning" and the run still exits
#     0** — a branch this script fails to delete must not fail the push to
#     main it is reacting to.
#   - **A file that is not a well-formed tech-debt id is ignored** — modified
#     or renamed tech-debt files (not "added"), and anything outside
#     tech-debt/ entirely.
#   - **Two records added by the same push each get their own line.**
#   - **An all-zero before-SHA (force-push/new-branch) is a no-op**, calling
#     `gh` not at all, rather than diffing against a ref that does not exist.
#
# `gh` is stubbed through GH, matching the technique
# test/merge-queue.test.sh's stub uses for its own `gh api` calls.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/release-td-branch.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="$SCRIPT_DIR/scripts/release-td-branch.sh"

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

# --- The stub gh -------------------------------------------------------------
# $tmp_dir/added.json        JSON array of {"filename":...,"status":...} for
#                             the compare call
# $tmp_dir/absent-branches    newline-separated branch names that 404 on the
#                             ref-existence check
# $tmp_dir/delete-fails       newline-separated branch names whose DELETE call
#                             fails
# $tmp_dir/calls              every invocation's argv, one per line — asserted
#                             empty for the all-zero-before case
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >> "$d/calls"

if [[ "$1" == "api" && "$2" == *"/compare/"* ]]; then
  cat "$d/added.json" 2>/dev/null || echo '{"files":[]}'
  exit 0
fi

if [[ "$1" == "api" && "$2" == *"/git/ref/heads/"* ]]; then
  branch="${2##*/git/ref/heads/}"
  grep -qxF "$branch" "$d/absent-branches" 2>/dev/null && exit 1
  echo '{}'
  exit 0
fi

if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" ]]; then
  branch="${4##*/git/refs/heads/}"
  grep -qxF "$branch" "$d/delete-fails" 2>/dev/null && exit 1
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/gh"

reset_stub() {
  : > "$tmp_dir/calls"
  : > "$tmp_dir/absent-branches"
  : > "$tmp_dir/delete-fails"
  echo '{"files":[]}' > "$tmp_dir/added.json"
}

added_files() {  # added_files <filename:status> ...
  local args=() f
  for f in "$@"; do
    args+=("$(jq -nc --arg fn "${f%%:*}" --arg st "${f##*:}" '{filename:$fn, status:$st}')")
  done
  jq -sc '{files: .}' <<<"$(printf '%s\n' "${args[@]}")" > "$tmp_dir/added.json"
}

run() { GH="$tmp_dir/gh" "$RELEASE" "$@"; }

# --- Existing branch is deleted ----------------------------------------------
reset_stub
added_files "tech-debt/TD-PPagop-26082207.md:added"
out="$(run o/r before1 after1)"; rc=$?
assert_eq "existing branch: exit 0" "0" "$rc"
assert_eq "  ... id" "TD-PPagop-26082207" "$(jq -r '.id' <<<"$out")"
assert_eq "  ... branch" "td/TD-PPagop-26082207" "$(jq -r '.branch' <<<"$out")"
assert_eq "  ... action deleted" "deleted" "$(jq -r '.action' <<<"$out")"

# --- Already-absent branch reports absent, not an error --------------------
reset_stub
added_files "tech-debt/TD-PPagop-26082201.md:added"
echo "td/TD-PPagop-26082201" > "$tmp_dir/absent-branches"
out="$(run o/r before2 after2)"; rc=$?
assert_eq "absent branch: exit 0" "0" "$rc"
assert_eq "  ... action absent" "absent" "$(jq -r '.action' <<<"$out")"

# --- A failing delete call reports warning and still exits 0 ---------------
reset_stub
added_files "tech-debt/TD-PPagop-26082202.md:added"
echo "td/TD-PPagop-26082202" > "$tmp_dir/delete-fails"
out="$(run o/r before3 after3)"; rc=$?
assert_eq "delete fails: exit 0" "0" "$rc"
assert_eq "  ... action warning" "warning" "$(jq -r '.action' <<<"$out")"

# --- Modified (not added) tech-debt files are ignored -----------------------
reset_stub
added_files "tech-debt/TD-PPagop-26082203.md:modified"
out="$(run o/r before4 after4)"; rc=$?
assert_eq "modified file: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"

# --- Non-tech-debt and malformed-id files are ignored -----------------------
reset_stub
added_files "README.md:added" "tech-debt/not-a-real-id.md:added"
out="$(run o/r before5 after5)"; rc=$?
assert_eq "unrelated/malformed files: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"

# --- Two records added by the same push each get their own line -------------
reset_stub
added_files "tech-debt/TD-PPagop-26082204.md:added" "tech-debt/TD-PPagop-26082205.md:added"
out="$(run o/r before6 after6)"; rc=$?
n="$(jq -s 'length' <<<"$out")"
assert_eq "two records: exit 0" "0" "$rc"
assert_eq "  ... two lines emitted" "2" "$n"

# --- All-zero before-SHA is a no-op, and never calls gh ----------------------
reset_stub
added_files "tech-debt/TD-PPagop-26082206.md:added"
out="$(run o/r 0000000000000000000000000000000000000000 after7)"; rc=$?
assert_eq "all-zero before: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"
assert_eq "  ... gh never called" "" "$(cat "$tmp_dir/calls")"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$failures test(s) failed."
  exit 1
fi
