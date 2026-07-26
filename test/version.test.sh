#!/usr/bin/env bash
#
# test/version.test.sh — regression tests for lib/version.sh.
#
# What version a node is running is reported on the dashboard's fleet cards and
# published in every heartbeat, and it has the failure mode that matters most:
# it is silent. A stamp this reader cannot parse does not raise anything — the
# card says "version unknown", which is indistinguishable from a peer that has
# not been heard from, and the fleet's "behind" marker (which is how a stalled
# watchtower becomes visible at all) simply stops appearing. So each of the
# three answers it can give gets a test:
#
#   the CI stamp     an image built by .github/workflows/build-image.yml
#   git HEAD         a developer's clone, or the legacy WSL install
#   nothing          neither — `null`, never a half-filled guess
#
# No network. Run directly:
#
#   ./test/version.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"

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

v_of() { agent_ops_version "$1" | jq -r "$2"; }

# --- The subject parser ---------------------------------------------------------
# Every change here is squash-merged as `<subject> (#N)`, so this one regex is
# what makes "the last pull request in this build" knowable at all.
assert_eq "a squash-merge subject yields its pull request" "89" \
  "$(version_pr_from_subject 'fix(deploy): defer a watchtower roll (#89)')"
assert_eq "trailing whitespace does not hide it" "7" \
  "$(version_pr_from_subject 'docs: tidy (#7)  ')"
assert_eq "a bare subject yields nothing" "" \
  "$(version_pr_from_subject 'wip: pushed straight to main')"
# An issue reference mid-subject is not the merge marker, and reading it as one
# would put a wrong — but entirely plausible — version on a node's card.
assert_eq "a mid-subject reference is not a merge marker" "" \
  "$(version_pr_from_subject 'fix: close (#12) properly, at last')"

assert_eq "an https remote yields its slug" "Poetic-Poems/agent-ops" \
  "$(version_slug_from_remote 'https://github.com/Poetic-Poems/agent-ops.git')"
assert_eq "an ssh remote yields the same slug" "Poetic-Poems/agent-ops" \
  "$(version_slug_from_remote 'git@github.com:Poetic-Poems/agent-ops.git')"
assert_eq "a remote that is not GitHub yields nothing" "" \
  "$(version_slug_from_remote 'https://git.example.com/thing.git')"

# --- The CI stamp ---------------------------------------------------------------
img="$tmp_dir/image"
mkdir -p "$img"
printf '{"commit":"aa53d62f1b0c4e9a7d2839fbc5104e6a8d7b3f21","pr":"89","built_at":"2026-07-26T11:21:00Z","repo":"Poetic-Poems/agent-ops"}\n' \
  > "$img/build-info.json"
assert_eq "a stamped image reports its build"   "image"   "$(v_of "$img" .source)"
assert_eq "and the pull request, as a number"   "89"      "$(v_of "$img" .pr)"
assert_eq "and the commit, abbreviated"         "aa53d62" "$(v_of "$img" .short)"
assert_eq "and when it was built" "2026-07-26T11:21:00Z"  "$(v_of "$img" .built_at)"
assert_eq "an image is never dirty"             "false"   "$(v_of "$img" .dirty)"

# A build containing no merged pull request must say so rather than invent one:
# the card then shows the commit alone, which is the truth.
printf '{"commit":"deadbee0000000000000000000000000000cafe","pr":"","built_at":"","repo":""}\n' \
  > "$img/build-info.json"
assert_eq "a build with no merged PR reports none" "null" "$(v_of "$img" .pr)"
assert_eq "but still reports its commit"        "deadbee" "$(v_of "$img" .short)"
assert_eq "and null rather than empty strings"  "null"    "$(v_of "$img" .built_at)"

# --- Falling through to git -----------------------------------------------------
# A locally built image gets build-info.json with every value empty (the build
# args are CI's). That must read as "no stamp" and fall through, or every
# developer build would report a version of nothing.
repo="$tmp_dir/checkout"
mkdir -p "$repo"
git -C "$repo" init --quiet
git -C "$repo" remote add origin git@github.com:Poetic-Poems/agent-ops.git
printf 'x\n' > "$repo/file"
git -C "$repo" add file
git -C "$repo" -c user.name=t -c user.email=t@e commit --quiet -m 'feat: a thing (#42)'
head_sha="$(git -C "$repo" rev-parse HEAD)"

printf '{"commit":"","pr":"","built_at":"","repo":""}\n' > "$repo/build-info.json"
assert_eq "an empty stamp falls through to git" "checkout" "$(v_of "$repo" .source)"
assert_eq "the checkout's pull request is parsed from HEAD" "42" "$(v_of "$repo" .pr)"
assert_eq "and its commit is HEAD"       "${head_sha:0:7}" "$(v_of "$repo" .short)"
assert_eq "and its repo comes from the remote" "Poetic-Poems/agent-ops" "$(v_of "$repo" .repo)"
assert_eq "a clean checkout is not dirty" "false" "$(v_of "$repo" .dirty)"

# Uncommitted work means the checkout is not the commit it names — worth saying,
# on the one kind of node that can be edited in place.
printf 'y\n' > "$repo/file"
assert_eq "a modified checkout says so" "true" "$(v_of "$repo" .dirty)"

# --- Neither -------------------------------------------------------------------
bare="$tmp_dir/bare"
mkdir -p "$bare"
assert_eq "with no stamp and no git, there is no version" "null" \
  "$(agent_ops_version "$bare")"

# --- Under `set -e` --------------------------------------------------------------
# scripts/state-sync.sh runs `set -euo pipefail` and calls this on every push,
# so a read that legitimately fails here must not take a node's heartbeat down
# with it — and a node that stops pushing is one the whole fleet loses sight of.
# Each case below is a real repository state, not a contrived one.
under_set_e() {  # under_set_e <app-dir> -> prints the version, or "ABORTED"
  ( set -euo pipefail; agent_ops_version "$1" ) 2>/dev/null || printf 'ABORTED'
}

nocommits="$tmp_dir/nocommits"          # `git init`, nothing committed yet
mkdir -p "$nocommits"; git -C "$nocommits" init --quiet
assert_eq "a repository with no commits does not abort a set -e caller" "null" \
  "$(under_set_e "$nocommits")"

noremote="$tmp_dir/noremote"            # a clone with no `origin`
mkdir -p "$noremote"; git -C "$noremote" init --quiet
printf 'x\n' > "$noremote/f"; git -C "$noremote" add f
git -C "$noremote" -c user.name=t -c user.email=t@e commit --quiet -m 'feat: no remote (#5)'
assert_eq "nor does a clone with no origin remote" "5" \
  "$(under_set_e "$noremote" | jq -r .pr)"
assert_eq "it just reports no repo" "null" "$(under_set_e "$noremote" | jq -r .repo)"

torn="$tmp_dir/torn"                    # a stamp truncated mid-write
mkdir -p "$torn"; printf '{"commit":' > "$torn/build-info.json"
assert_eq "nor does a stamp that does not parse" "null" "$(under_set_e "$torn")"

assert_eq "and a good checkout still answers under set -e" "42" \
  "$(under_set_e "$repo" | jq -r .pr)"

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
