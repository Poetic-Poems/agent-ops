#!/usr/bin/env bash
#
# test/check-tech-debt-open-rewrites.test.sh — regression tests for
# scripts/check-tech-debt-open-rewrites.pl (issue #468), mirroring the
# coverage its canonical copy carries in Poetic-Poems/poetic's
# test/tech-debt-scripts.test.js. Wired into
# .github/workflows/tech-debt-register.yml as the "Open item bodies are
# append-only while status is unchanged" step.
#
# Behaviours asserted, each of which fails silently if broken:
#
#   - **Flags a body rewrite on an item whose `status:` stays `open`** — the
#     failure mode a stale-clone writer produces when it overwrites an
#     already-resolved item as an ordinary content modification, which
#     neither the deletion/rename guard nor `td-check.pl` would notice.
#   - **Allows a strict append** to an open item's body — new text (e.g. a
#     "Referenced from:" note) is always allowed.
#   - **Flags a same-length rewrite** even though it is not a whole-body
#     swap — the check is "is this a strict append", not "did the length
#     change".
#   - **Allows a claim** (status moves to `in-progress`, body unchanged) and
#     **a resolution** (status moves to `resolved`, body unchanged) — a
#     status move is exactly what licenses a body change under this rule.
#   - **Ignores newly added items** and **a diff with no register changes**.
#   - **Rejects an append when the base body is empty** — an empty body has
#     no prefix to extend, so any new text is a rewrite, not an append.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/check-tech-debt-open-rewrites.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPEN_REWRITES="$SCRIPT_DIR/scripts/check-tech-debt-open-rewrites.pl"

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

# Isolate git from any developer/CI-runner global config, so runs are
# deterministic everywhere.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Agent-Ops Test"
export GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="Agent-Ops Test"
export GIT_COMMITTER_EMAIL="test@example.invalid"

item_file() {  # item_file <id> <status> <body-line...> -- extra frontmatter
               # (e.g. "resolved: 2026-08-13") comes via $EXTRA_FRONTMATTER,
               # one line per array entry. Assign it on its own line before
               # the call, never as a command prefix: bash has no array form
               # of a prefix assignment, so `EXTRA_FRONTMATTER=(…) item_file`
               # would quietly hand the function the *string* "(…)" and emit
               # it verbatim as a bogus frontmatter line.
  local id="$1" status="$2"; shift 2
  {
    echo "---"
    echo "id: $id"
    echo "title: Title for $id"
    echo "status: $status"
    echo "filed: 2026-08-01"
    local line
    for line in "${EXTRA_FRONTMATTER[@]:-}"; do
      [[ -n "$line" ]] && echo "$line"
    done
    echo "---"
    echo
    printf '%s\n' "$@"
  }
}

# make_rewrite_repo -- a repo on main carrying one open item with a known
# body. Prints the repo's path.
make_rewrite_repo() {
  local dir="$tmp_dir/rewrite-$RANDOM"
  git init -q -b main "$dir"
  mkdir -p "$dir/tech-debt"
  EXTRA_FRONTMATTER=()
  item_file TD-PPtest-26080101 open "Original body." \
    > "$dir/tech-debt/TD-PPtest-26080101.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m base
  printf '%s\n' "$dir"
}

run_open_rewrites() {  # run_open_rewrites <dir> <args...>
  local dir="$1"; shift
  (cd "$dir" && perl "$OPEN_REWRITES" "$@")
}

# --- flags a body change on an item whose status stays open ------------------------
dir="$(make_rewrite_repo)"
git -C "$dir" checkout -q -b overwrite
EXTRA_FRONTMATTER=()
item_file TD-PPtest-26080101 open "A completely different body." \
  > "$dir/tech-debt/TD-PPtest-26080101.md"
git -C "$dir" commit -q -am overwrite
out="$(run_open_rewrites "$dir" main overwrite)"
rc=$?
assert_eq "a body rewrite on an open item is flagged" "1" "$rc"
assert_eq "…naming the file as a BODY REWRITE" "1" \
  "$(grep -cE 'BODY REWRITE\s+tech-debt/TD-PPtest-26080101\.md' <<<"$out")"

# --- allows a strict append to an open item's body ----------------------------------
dir="$(make_rewrite_repo)"
git -C "$dir" checkout -q -b append
EXTRA_FRONTMATTER=()
item_file TD-PPtest-26080101 open "Original body." "Referenced from: src/foo.js" \
  > "$dir/tech-debt/TD-PPtest-26080101.md"
git -C "$dir" commit -q -am append
out="$(run_open_rewrites "$dir" main append)"
rc=$?
assert_eq "a strict append to an open item's body is allowed" "0" "$rc"
assert_eq "…and is reported clean" "1" "$(grep -c 'no open-item body rewrites' <<<"$out")"

# --- flags a same-length rewrite even though it is not a whole-body swap -----------
dir="$(make_rewrite_repo)"
git -C "$dir" checkout -q -b samelength
EXTRA_FRONTMATTER=()
item_file TD-PPtest-26080101 open "Original bodz." \
  > "$dir/tech-debt/TD-PPtest-26080101.md"
git -C "$dir" commit -q -am samelength
out="$(run_open_rewrites "$dir" main samelength)"
rc=$?
assert_eq "a same-length rewrite is flagged" "1" "$rc"
assert_eq "…naming the file as a BODY REWRITE" "1" \
  "$(grep -cE 'BODY REWRITE\s+tech-debt/TD-PPtest-26080101\.md' <<<"$out")"

# --- allows a claim (status changes, body unchanged) --------------------------------
dir="$(make_rewrite_repo)"
git -C "$dir" checkout -q -b claim
EXTRA_FRONTMATTER=()
item_file TD-PPtest-26080101 in-progress "Original body." \
  > "$dir/tech-debt/TD-PPtest-26080101.md"
git -C "$dir" commit -q -am claim
out="$(run_open_rewrites "$dir" main claim)"
rc=$?
assert_eq "a claim (status move, body unchanged) is allowed" "0" "$rc"

# --- allows a resolution (status changes to resolved) --------------------------------
dir="$(make_rewrite_repo)"
git -C "$dir" checkout -q -b resolve
EXTRA_FRONTMATTER=("resolved: 2026-08-13" "ref: #123")
item_file TD-PPtest-26080101 resolved "Original body." \
  > "$dir/tech-debt/TD-PPtest-26080101.md"
git -C "$dir" commit -q -am resolve
out="$(run_open_rewrites "$dir" main resolve)"
rc=$?
assert_eq "a resolution (status move to resolved) is allowed" "0" "$rc"

# --- ignores newly added items -------------------------------------------------------
dir="$(make_rewrite_repo)"
git -C "$dir" checkout -q -b addition
EXTRA_FRONTMATTER=()
item_file TD-PPtest-26080102 open "A new item." \
  > "$dir/tech-debt/TD-PPtest-26080102.md"
git -C "$dir" add -A
git -C "$dir" commit -q -m addition
out="$(run_open_rewrites "$dir" main addition)"
rc=$?
assert_eq "a newly added item is ignored" "0" "$rc"

# --- a clean diff exits 0 -------------------------------------------------------------
dir="$(make_rewrite_repo)"
git -C "$dir" checkout -q -b noop
echo hi > "$dir/unrelated.txt"
git -C "$dir" add -A
git -C "$dir" commit -q -m unrelated
out="$(run_open_rewrites "$dir" main noop)"
rc=$?
assert_eq "a diff with no register changes exits 0" "0" "$rc"

# --- rejects an append when the base body is empty ------------------------------------
dir="$tmp_dir/rewrite-empty-$RANDOM"
git init -q -b main "$dir"
mkdir -p "$dir/tech-debt"
EXTRA_FRONTMATTER=()
item_file TD-PPtest-26080201 open "" \
  > "$dir/tech-debt/TD-PPtest-26080201.md"
git -C "$dir" add -A
git -C "$dir" commit -q -m base-empty
git -C "$dir" checkout -q -b append-to-empty
EXTRA_FRONTMATTER=()
item_file TD-PPtest-26080201 open "New body text." \
  > "$dir/tech-debt/TD-PPtest-26080201.md"
git -C "$dir" commit -q -am append
out="$(run_open_rewrites "$dir" main append-to-empty)"
rc=$?
assert_eq "an append onto an empty base body is flagged" "1" "$rc"
assert_eq "…naming the file as a BODY REWRITE" "1" \
  "$(grep -cE 'BODY REWRITE\s+tech-debt/TD-PPtest-26080201\.md' <<<"$out")"

# ---------------------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
