#!/usr/bin/env bash
#
# test/tech-debt-file.test.sh — regression tests for lib/tech-debt-file.sh
# (agent-ops#631): filing a tech-debt record or a GitHub issue on the
# Script's own behalf, for the Approver and Enabler stages, which must never
# write to GitHub or a branch themselves.
#
# Behaviours asserted:
#
#   - **techdebt_file_debt reserves a real id against origin/main**, via the
#     genuine scripts/reserve-tech-debt-id.pl extracted from the fixture
#     remote's own origin/main — never reimplemented, never read from
#     GIT_DIR's checked-out branch (simulated here as a *different*,
#     deliberately-broken copy, so a test that read the checkout by mistake
#     would fail loudly instead of silently passing).
#   - **... and opens exactly one pull request** carrying the new
#     tech-debt/<id>.md, via the branch-then-contents-then-PR sequence, and
#     prints "<id>\t<pr-url>".
#   - **A TOKEN, given, is used for every gh call** (git/refs, contents, pr
#     create) — never the ordinary login.
#   - **Any step failing (no reserve script on origin/main, the branch-create
#     call, the contents-write call, the PR-create call) fails the whole
#     call, returns 1, and prints nothing.**
#   - **techdebt_file_issue returns an existing issue that already covers
#     ITEM_REF** rather than filing a duplicate, and creates one when none
#     exists; a failed create returns 1 and prints nothing.
#
# `gh` is stubbed through a fake executable on PATH, recording every
# invocation to a file for assertions — the technique
# test/merge-queue.test.sh's stub uses for its own `gh api` calls. Git
# operations run for real against a local bare "remote", the technique
# test/reserve-tech-debt-id.test.sh uses for reserve-tech-debt-id.pl itself.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/tech-debt-file.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESERVE_SRC="$SCRIPT_DIR/scripts/reserve-tech-debt-id.pl"
# shellcheck source=lib/tech-debt-file.sh
. "$SCRIPT_DIR/lib/tech-debt-file.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"

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

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Agent-Ops Test"
export GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="Agent-Ops Test"
export GIT_COMMITTER_EMAIL="test@example.invalid"

# make_remote [broken-reserve-script:0|1] -- a bare "origin" on main, carrying
# a scoped policy and the real reserve-tech-debt-id.pl (or, if the argument is
# 1, a deliberately-broken stand-in) at scripts/. Prints the remote's path.
make_remote() {
  local broken="${1:-0}" root remote seed
  root="$(mktemp -d "$tmp_dir/remote-XXXXXX")"
  remote="$root/remote.git"
  seed="$root/seed"
  git init -q -b main --bare "$remote"
  git init -q -b main "$seed"
  cat > "$seed/TECH-DEBT.md" <<'EOF'
---
scope: PPtest
---

# Tech debt

Policy only; items live in tech-debt/, one file each.
EOF
  mkdir -p "$seed/scripts"
  if [[ "$broken" == "1" ]]; then
    printf '#!/usr/bin/perl\ndie "should never run this copy\\n";\n' > "$seed/scripts/reserve-tech-debt-id.pl"
  else
    cp "$RESERVE_SRC" "$seed/scripts/reserve-tech-debt-id.pl"
  fi
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m fixture >/dev/null
  git -C "$seed" push -q origin main
  printf '%s\n' "$remote"
}

# a_git_dir REMOTE -- a fresh directory with `origin` pointed at REMOTE and,
# deliberately, a *different*, broken reserve-tech-debt-id.pl checked out
# locally, so techdebt_file_debt reading the working tree instead of
# origin/main directly would fail loudly.
a_git_dir() {
  local remote="$1" dir
  dir="$(mktemp -d "$tmp_dir/gitdir-XXXXXX")"
  git -C "$dir" init -q -b main
  git -C "$dir" remote add origin "$remote"
  mkdir -p "$dir/scripts"
  printf '#!/usr/bin/perl\ndie "must never run the checked-out copy\\n";\n' > "$dir/scripts/reserve-tech-debt-id.pl"
  printf '%s\n' "$dir"
}

# --- The stub gh -------------------------------------------------------------
# $tmp_dir/calls               every invocation's argv, one per line
# $tmp_dir/pr-url               printed by `pr create` (empty -> fails)
# $tmp_dir/issue-url            printed by `issue create` (empty -> fails)
# $tmp_dir/issue-list-response  printed by `issue list --json ...`
# $tmp_dir/fail-refs            present -> the git/refs POST fails
# $tmp_dir/fail-contents        present -> the contents PUT fails
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s %s\n' "${GH_TOKEN:-<none>}" "$*" >> "$d/calls"

if [[ "$1" == "api" && "$2" == "-X" && "$3" == "POST" && "$4" == *"/git/refs" ]]; then
  [[ -f "$d/fail-refs" ]] && exit 1
  exit 0
fi
if [[ "$1" == "api" && "$2" == "-X" && "$3" == "PUT" && "$4" == *"/contents/"* ]]; then
  [[ -f "$d/fail-contents" ]] && exit 1
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "create" ]]; then
  [[ -s "$d/pr-url" ]] || exit 1
  cat "$d/pr-url"
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "create" ]]; then
  [[ -s "$d/issue-url" ]] || exit 1
  cat "$d/issue-url"
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "list" ]]; then
  cat "$d/issue-list-response" 2>/dev/null || echo '[]'
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"
export PATH="$tmp_dir:$PATH"

reset_stub() {
  : > "$tmp_dir/calls"
  rm -f "$tmp_dir/fail-refs" "$tmp_dir/fail-contents"
  echo "https://github.com/o/r/pull/99" > "$tmp_dir/pr-url"
  echo "https://github.com/o/r/issues/77" > "$tmp_dir/issue-url"
  echo '[]' > "$tmp_dir/issue-list-response"
}

# ============================================================================
# techdebt_file_debt
# ============================================================================

# --- Full success path -------------------------------------------------------
remote="$(make_remote 0)"
gd="$(a_git_dir "$remote")"
reset_stub
out="$(techdebt_file_debt "o/r" "A finding worth filing" "The body." "while reviewing PR #618" "" "$gd")"
rc=$?
assert_eq "file_debt success: exit 0" "0" "$rc"
id="$(cut -f1 <<<"$out")"
url="$(cut -f2 <<<"$out")"
assert_eq "  ... id looks right" "1" "$([[ "$id" =~ ^TD-PPtest-[0-9]{6}[0-9a-z][0-9]$ ]] && echo 1 || echo 0)"
assert_eq "  ... pr url returned" "https://github.com/o/r/pull/99" "$url"
assert_eq "  ... exactly one git/refs POST" "1" \
  "$(grep -c 'api -X POST repos/o/r/git/refs' "$tmp_dir/calls")"
assert_eq "  ... exactly one contents PUT" "1" \
  "$(grep -c "api -X PUT repos/o/r/contents/tech-debt/$id.md" "$tmp_dir/calls")"
assert_eq "  ... exactly one pr create" "1" \
  "$(grep -c '^<none> pr create ' "$tmp_dir/calls")"
assert_eq "  ... branch is td-record/<id>, not td/<id>" "1" \
  "$(grep -c "ref=refs/heads/td-record/$id" "$tmp_dir/calls")"

# --- A token is used for every gh call --------------------------------------
remote="$(make_remote 0)"
gd="$(a_git_dir "$remote")"
reset_stub
techdebt_file_debt "o/r" "Another finding" "Body." "while approving PR #7" "app-token-123" "$gd" >/dev/null
assert_eq "file_debt with token: every call carries it" "0" \
  "$(grep -vc '^app-token-123 ' "$tmp_dir/calls")"

# --- No reserve script on origin/main -> fails cleanly ----------------------
remote="$(make_remote 0)"
# Overwrite the seed's remote with one whose origin/main carries no
# scripts/ directory at all.
root2="$(mktemp -d "$tmp_dir/noreserve-XXXXXX")"
git init -q -b main --bare "$root2/remote.git"
git init -q -b main "$root2/seed"
echo "no policy here" > "$root2/seed/README.md"
git -C "$root2/seed" remote add origin "$root2/remote.git"
git -C "$root2/seed" add -A
git -C "$root2/seed" commit -q -m fixture >/dev/null
git -C "$root2/seed" push -q origin main
gd="$(a_git_dir "$root2/remote.git")"
reset_stub
out="$(techdebt_file_debt "o/r" "T" "B" "P" "" "$gd")"; rc=$?
assert_eq "file_debt: no reserve script on origin/main -> exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"
assert_eq "  ... no gh calls made" "" "$(cat "$tmp_dir/calls")"

# --- git/refs POST fails -> whole call fails --------------------------------
remote="$(make_remote 0)"
gd="$(a_git_dir "$remote")"
reset_stub
: > "$tmp_dir/fail-refs"
out="$(techdebt_file_debt "o/r" "T" "B" "P" "" "$gd")"; rc=$?
assert_eq "file_debt: branch-create fails -> exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"
assert_eq "  ... no contents PUT attempted" "0" \
  "$(grep -c 'contents/' "$tmp_dir/calls")"

# --- contents PUT fails -> whole call fails ---------------------------------
remote="$(make_remote 0)"
gd="$(a_git_dir "$remote")"
reset_stub
: > "$tmp_dir/fail-contents"
out="$(techdebt_file_debt "o/r" "T" "B" "P" "" "$gd")"; rc=$?
assert_eq "file_debt: contents-write fails -> exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"
assert_eq "  ... no pr create attempted" "0" "$(grep -c 'pr create' "$tmp_dir/calls")"

# --- pr create fails -> whole call fails ------------------------------------
remote="$(make_remote 0)"
gd="$(a_git_dir "$remote")"
reset_stub
: > "$tmp_dir/pr-url"
out="$(techdebt_file_debt "o/r" "T" "B" "P" "" "$gd")"; rc=$?
assert_eq "file_debt: pr-create fails -> exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"

# ============================================================================
# techdebt_file_issue
# ============================================================================

# --- No existing issue -> creates one ---------------------------------------
reset_stub
out="$(techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" \
        <(echo "body") "")"
rc=$?
assert_eq "file_issue: created, exit 0" "0" "$rc"
assert_eq "  ... number/url" "77	https://github.com/o/r/issues/77" "$out"

# --- Existing issue already covers the item ref -> returned, no create -----
reset_stub
jq -nc --arg item "TD26082201" \
  '[{number: 42, url: "https://github.com/o/r/issues/42", body: ("covers " + $item)}]' \
  > "$tmp_dir/issue-list-response"
out="$(techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" <(echo "body") "")"
rc=$?
assert_eq "file_issue: dedup hit, exit 0" "0" "$rc"
assert_eq "  ... existing number/url returned" "42	https://github.com/o/r/issues/42" "$out"
assert_eq "  ... no create attempted" "0" "$(grep -c 'issue create' "$tmp_dir/calls")"

# --- Create fails -> returns 1 ----------------------------------------------
reset_stub
: > "$tmp_dir/issue-url"
out="$(techdebt_file_issue "o/r" "TD26082201" "A gap worth noting" <(echo "body") "")"
rc=$?
assert_eq "file_issue: create fails -> exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$failures test(s) failed."
  exit 1
fi
