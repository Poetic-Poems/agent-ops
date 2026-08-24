#!/usr/bin/env bash
#
# test/workspace-reap.test.sh — `workspace_root` is reclaimed from the cycles
# that died without cleaning up, and never from one that is still alive
# (agent-ops#605).
#
# What this guards. Every cycle deletes its clone in an exit trap, and a trap
# is what a `SIGKILL` does not run — so a cycle the machine kills leaks its
# whole clone, permanently. Measured 2026-08-24: 17 orphans and 4.2 GB across
# the two ockham nodes (oldest 32 days), 5 more and ~2.5 GB on VM1. The leak
# is invisible until the volume is full and is then the reason it is full.
#
# The properties below are each one that fails silently if lost:
#
#   the rule is mtime       not the `<cycle-id>` naming convention. The two
#                           largest orphans found in the field were named
#                           `scratch-implementor/` and `scratch/` — created by
#                           the *stage agents*, following the target repo's own
#                           dedicated-clone rule, with names the pipeline never
#                           chose and cannot predict.
#   the tree, not the dir   a clone's top-level mtime is stamped once by git
#                           and never moves again; reading it alone reaps the
#                           workspace of a cycle that is five hours into its
#                           Implementer and writing constantly.
#   the fleet stores stay   `.agent-ops-state` and `.agent-ops-peers` live in
#                           the same directory, are bounded by their own
#                           retentions, and a fetch that has not run today
#                           must not cost the node its peers.
#   the reclamation is said `bytes` is the entire point, and `names` is what
#                           tells a reader which cycles are dying — a node
#                           reaping every cycle is a node being killed every
#                           cycle, a fault nothing else reports.
#
# No network and no clock dependence: mtimes are set explicitly with `touch`
# and "now" is passed in, so this cannot flake on a slow runner.
#
# Run directly: ./test/workspace-reap.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/workspace.sh
. "$SCRIPT_DIR/lib/workspace.sh"

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

NOW=1756000000            # a fixed "now", so nothing here depends on the clock
DAY=86400
WINDOW=$(( 4 * 3600 ))    # a cycle-lock-sized window, deliberately below the floor

exists() { test -e "$1" && echo 1 || echo 0; }

# `touch -d @epoch` on every path in the tree, deepest last, so the directory's
# own mtime is not bumped by writing the file inside it.
age_tree() {  # age_tree DIR EPOCH
  find "$1" -depth -exec touch -h -d "@$2" {} + 2>/dev/null
}

# --- The window ---------------------------------------------------------------
# The derived cycle-lock window is used when it is the wider of the two; the
# 24-hour floor is what actually binds in practice, because every lock window
# the pipeline derives today is hours, not days.
assert_eq "a short derived window is floored at 24 h" "$DAY" \
  "$(workspace_reap_window "$WINDOW")"
assert_eq "a window wider than the floor is kept" "$(( 30 * 3600 ))" \
  "$(workspace_reap_window "$(( 30 * 3600 ))")"
assert_eq "no derived window at all still gets the floor" "$DAY" \
  "$(workspace_reap_window 0)"
assert_eq "a nonsense derived window does not defeat the floor" "$DAY" \
  "$(workspace_reap_window "not-a-number")"

# --- The reap -----------------------------------------------------------------
root="$tmp_dir/workspaces"
mkdir -p "$root"

# An orphan named the way the pipeline names them: a cycle killed mid-flight.
mkdir -p "$root/20260725T225500Z-poetic-1-705411/.git"
printf 'residue\n' > "$root/20260725T225500Z-poetic-1-705411/README.md"
age_tree "$root/20260725T225500Z-poetic-1-705411" $(( NOW - 30 * DAY ))

# The orphans a reaper keyed on that convention walks straight past. Both
# shapes were found in the field: a bare name an agent chose for itself, and a
# cycle id with a suffix the pipeline never appends.
mkdir -p "$root/scratch-implementor/poetic"
printf 'residue\n' > "$root/scratch-implementor/poetic/x"
age_tree "$root/scratch-implementor" $(( NOW - 21 * DAY ))
mkdir -p "$root/20260803T105100Z-poetic-1-675091-scratch/poetic"
printf 'residue\n' > "$root/20260803T105100Z-poetic-1-675091-scratch/poetic/x"
age_tree "$root/20260803T105100Z-poetic-1-675091-scratch" $(( NOW - 20 * DAY ))

# The workspace of a cycle that is running right now — and the case that makes
# the rule the *tree's* mtime rather than the directory's: the directory itself
# is stamped a week ago (git stamps it once, at clone) while the Implementer
# has been writing inside it seconds ago.
mkdir -p "$root/20260824T025100Z-poetic-1-12076/src"
printf 'live\n' > "$root/20260824T025100Z-poetic-1-12076/src/live.c"
age_tree "$root/20260824T025100Z-poetic-1-12076" $(( NOW - 7 * DAY ))
touch -d "@$(( NOW - 30 ))" "$root/20260824T025100Z-poetic-1-12076/src/live.c"

# The fleet's own stores, which share this directory and must never be reaped.
# Aged well past the window on purpose: a node whose last fetch was days ago is
# a stale node, not one that should lose its peers.
mkdir -p "$root/.agent-ops-state/cycles" "$root/.agent-ops-peers/poetic-2"
printf 'state\n' > "$root/.agent-ops-state/cycles/keep"
printf 'peer\n'  > "$root/.agent-ops-peers/poetic-2/log.jsonl"
: > "$root/.agent-ops-state.lock"
age_tree "$root/.agent-ops-state" $(( NOW - 40 * DAY ))
age_tree "$root/.agent-ops-peers" $(( NOW - 40 * DAY ))
touch -d "@$(( NOW - 40 * DAY ))" "$root/.agent-ops-state.lock"

summary="$(workspace_reap_summary "$root" "$DAY" "$NOW")"

assert_eq "three orphans are reclaimed" "3" "$(jq -r '.reaped' <<<"$summary")"
assert_eq "the window it used is recorded" "$DAY" "$(jq -r '.window_sec' <<<"$summary")"
assert_eq "the bytes reclaimed are reported, not merely the count" "1" \
  "$(jq -r 'if .bytes > 0 then 1 else 0 end' <<<"$summary")"

assert_eq "a dead cycle's workspace is gone" "0" \
  "$(exists "$root/20260725T225500Z-poetic-1-705411")"
assert_eq "an agent-named orphan is gone too — the rule is not the convention" "0" \
  "$(exists "$root/scratch-implementor")"
assert_eq "…and a cycle id with a suffix the pipeline never appends" "0" \
  "$(exists "$root/20260803T105100Z-poetic-1-675091-scratch")"
assert_eq "all three are named in the record" "3" \
  "$(jq -r '[.names[] | select(. != null)] | length' <<<"$summary")"

assert_eq "the running cycle's workspace survives" "1" \
  "$(exists "$root/20260824T025100Z-poetic-1-12076/src/live.c")"
assert_eq "the state mirror survives, however stale" "1" \
  "$(exists "$root/.agent-ops-state/cycles/keep")"
assert_eq "the peers survive too" "1" \
  "$(exists "$root/.agent-ops-peers/poetic-2/log.jsonl")"
assert_eq "…and the mirror lock beside them" "1" \
  "$(exists "$root/.agent-ops-state.lock")"

# --- Nothing to do ------------------------------------------------------------
# The ordinary case on a healthy node, and the one whose summary the caller
# uses to decide not to write an event at all.
summary="$(workspace_reap_summary "$root" "$DAY" "$NOW")"
assert_eq "a second pass finds nothing left to reap" "0" "$(jq -r '.reaped' <<<"$summary")"
assert_eq "…and reports zero bytes rather than null" "0" "$(jq -r '.bytes' <<<"$summary")"
assert_eq "…with an empty name list" "0" "$(jq -r '.names | length' <<<"$summary")"

# A root that does not exist yet is not an error: the first cycle on a fresh
# node reaps before anything has created one.
summary="$(workspace_reap_summary "$tmp_dir/no-such-root" "$DAY" "$NOW")"
assert_eq "a missing workspace root reaps nothing and does not fail" "0" \
  "$(jq -r '.reaped' <<<"$summary")"

# --- Clone validation ---------------------------------------------------------
# `clone_repo` discards whatever is already at its target rather than
# inspecting it. The residue that matters most is a *complete but dirty*
# clone — a dead cycle's working tree, which every "is this a valid repo at
# the right remote" check would wave through.
# shellcheck source=lib/repo-clone.sh
. "$SCRIPT_DIR/lib/repo-clone.sh"

stub="$tmp_dir/bin"
mkdir -p "$stub"
cat > "$stub/git" <<'STUB'
#!/usr/bin/env bash
# `git clone --quiet URL DIR` — fails if DIR exists and is non-empty, exactly
# as the real one does, so a test that stops discarding residue goes red here.
dir="${!#}"
if [[ -e "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
  echo "fatal: destination path '$dir' already exists and is not an empty directory." >&2
  exit 128
fi
mkdir -p "$dir/.git"
printf 'fresh\n' > "$dir/README.md"
STUB
chmod +x "$stub/git"
CLONE_GIT="$stub/git"

target="$tmp_dir/clone-target"

# A partial clone: git died part-way through writing it.
mkdir -p "$target/.git"
printf 'half\n' > "$target/.git/HEAD"
clone_repo "Poetic-Poems/agent-ops" "$target"
assert_eq "a partial clone is discarded and re-cloned" "fresh" \
  "$(cat "$target/README.md" 2>/dev/null)"

# A complete but dirty clone — the case a validity check cannot catch.
printf 'a dead cycle was working here\n' >> "$target/UNCOMMITTED.md"
clone_repo "Poetic-Poems/agent-ops" "$target"
assert_eq "a complete-but-dirty clone is discarded too" "0" \
  "$(exists "$target/UNCOMMITTED.md")"
assert_eq "…and replaced by a fresh one" "fresh" \
  "$(cat "$target/README.md" 2>/dev/null)"

# The ordinary path is unchanged: nothing there, clone lands.
rm -rf "$target"
clone_repo "Poetic-Poems/agent-ops" "$target"
assert_eq "an absent target clones exactly as before" "fresh" \
  "$(cat "$target/README.md" 2>/dev/null)"

printf '\n----------------------------------------\n'
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
else
  printf '%d assertion(s) failed.\n' "$failures"
fi
exit $(( failures > 0 ))
