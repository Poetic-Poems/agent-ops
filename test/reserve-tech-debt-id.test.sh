#!/usr/bin/env bash
#
# test/reserve-tech-debt-id.test.sh — regression tests for
# scripts/reserve-tech-debt-id.pl (issue #468), mirroring the coverage its
# canonical copy carries in Poetic-Poems/poetic's
# test/tech-debt-scripts.test.js.
#
# Behaviours asserted, each of which fails silently if broken:
#
#   - **Allocates the next free id and pushes its `td/<id>` branch** on
#     origin — the reservation itself, not just a printed id.
#   - **The reservation commit's subject passes the Conventional Commits
#     check** (`.githooks/check-commit-format.sh`): it sits in the filing
#     branch's history until the pull request is squash-merged, so
#     `commit-format.yml` sees it too.
#   - **Skips an id already reserved by an unmerged `td/*` branch** — the
#     half of the fix `next-tech-debt-id.pl`'s bare scan could never cover.
#   - **Sequential reservations from independent clones never collide.**
#   - **A rejected push retries the next NN instead of moving the existing
#     branch** — the regression test for the collision this item exists to
#     fix (agent-ops PRs #346/#350 both minted `TD-PPagop-26081401`): a
#     pre-created `td/<id>` branch that is an ancestor of `origin/main`
#     would fast-forward under a plain push, silently stealing the
#     reservation; `--force-with-lease` must refuse it instead.
#   - **Concurrent reservations for the same date never collide**, run for
#     real against overlapping clones.
#   - **Works against a register that has not filed its first item yet.**
#   - **Dies without a git remote named `origin`, and rejects a malformed
#     date or a stray extra argument.**
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/reserve-tech-debt-id.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESERVE="$SCRIPT_DIR/scripts/reserve-tech-debt-id.pl"
COMMIT_FORMAT_SCRIPT="$SCRIPT_DIR/.githooks/check-commit-format.sh"

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

policy() {
  cat <<'EOF'
---
scope: PPtest
---

# Tech debt

Policy only; items live in tech-debt/, one file each.
EOF
}

item_file() {  # item_file <id>
  local id="$1"
  local filed="20${id:10:2}-${id:12:2}-${id:14:2}"
  cat <<EOF
---
id: $id
title: Title for $id
status: open
filed: $filed
---

A body.
EOF
}

# make_remote [item-id...] -- a bare "remote" plus its seed commit, carrying
# a scoped policy and one item file per id argument. Prints the remote's path.
make_remote() {
  local root remote seed
  root="$(mktemp -d "$tmp_dir/remote-XXXXXX")"
  remote="$root/remote.git"
  seed="$root/seed"
  git init -q -b main --bare "$remote"
  git init -q -b main "$seed"
  policy > "$seed/TECH-DEBT.md"
  if (( $# )); then
    mkdir -p "$seed/tech-debt"
    local id
    for id in "$@"; do
      item_file "$id" > "$seed/tech-debt/$id.md"
    done
  fi
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m fixture
  git -C "$seed" push -q origin main
  printf '%s\n' "$remote"
}

# clone_remote <remote-dir> <name> -- a fresh clone; reservation races are
# only meaningful between independent clones. Prints the clone's path.
clone_remote() {
  local dir="$tmp_dir/clone-$2-$RANDOM"
  git clone -q "$1" "$dir" >/dev/null 2>&1
  printf '%s\n' "$dir"
}

run_reserve() {  # run_reserve <clone-dir> <args...>
  local dir="$1"; shift
  (cd "$dir" && perl "$RESERVE" "$@")
}

# --- allocates the next free id and pushes its td/<id> branch ----------------------
remote="$(make_remote TD-PPtest-26071901 TD-PPtest-26072001 TD-PPtest-26072002)"
clone="$(clone_remote "$remote" w1)"
id="$(run_reserve "$clone" 260720)"
assert_eq "reserve allocates the next free id" "TD-PPtest-26072003" "$id"
assert_eq "reserve pushes the td/<id> branch on origin" "refs/heads/td/$id" \
  "$(git -C "$remote" for-each-ref --format='%(refname)' "refs/heads/td/$id")"

# --- the reservation commit passes the Conventional Commits check ------------------
if [[ -f "$COMMIT_FORMAT_SCRIPT" ]]; then
  subject="$(git -C "$remote" log -1 --format=%s "refs/heads/td/$id")"
  bash "$COMMIT_FORMAT_SCRIPT" "$subject" >/dev/null 2>&1
  assert_eq "the reservation commit subject passes Conventional Commits check" "0" "$?"
fi

# --- skips ids already reserved by an unmerged td/* branch -------------------------
remote="$(make_remote TD-PPtest-26071901 TD-PPtest-26072001 TD-PPtest-26072002)"
seeder="$(clone_remote "$remote" seeder)"
git -C "$seeder" push -q origin main:refs/heads/td/TD-PPtest-26072003
clone="$(clone_remote "$remote" w1)"
id="$(run_reserve "$clone" 260720)"
assert_eq "reserve skips an id already reserved by an unmerged branch" \
  "TD-PPtest-26072004" "$id"

# --- sequential reservations from independent clones never collide -----------------
remote="$(make_remote TD-PPtest-26071901 TD-PPtest-26072001 TD-PPtest-26072002)"
seq_ids=()
for name in w1 w2 w3; do
  clone="$(clone_remote "$remote" "$name")"
  seq_ids+=("$(run_reserve "$clone" 260720)")
done
assert_eq "sequential reservations from independent clones never collide" \
  "TD-PPtest-26072003 TD-PPtest-26072004 TD-PPtest-26072005" "${seq_ids[*]}"

# --- a rejected push retries the next NN instead of moving the existing branch -----
# Regression test for the collision this item (issue #468) exists to fix:
# pre-create the exact branch a naive scan-then-push would target, pointing
# at a commit that is an ancestor of origin/main (so a plain push would
# succeed as an ordinary fast-forward and silently steal the reservation).
remote="$(make_remote TD-PPtest-26071901 TD-PPtest-26072001 TD-PPtest-26072002)"
seeder="$(clone_remote "$remote" seeder)"
collision_id="TD-PPtest-26072003"
git -C "$seeder" push -q origin "main:refs/heads/td/$collision_id"
stolen_sha="$(git -C "$remote" rev-parse "refs/heads/td/$collision_id")"
clone="$(clone_remote "$remote" w1)"
id="$(run_reserve "$clone" 260720)"
assert_eq "a rejected push moves on to the next id" "TD-PPtest-26072004" "$id"
assert_eq "the pre-existing reservation is left untouched" "$stolen_sha" \
  "$(git -C "$remote" rev-parse "refs/heads/td/$collision_id")"

# --- concurrent reservations for the same date never collide -----------------------
remote="$(make_remote)"
n=6
concurrent_clones=()
for i in $(seq 1 "$n"); do
  concurrent_clones+=("$(clone_remote "$remote" "c$i")")
done
concurrent_pids=()
for i in $(seq 1 "$n"); do
  ( run_reserve "${concurrent_clones[$((i-1))]}" 260801 > "$tmp_dir/out-$i" 2>"$tmp_dir/err-$i" ) &
  concurrent_pids+=("$!")
done
concurrent_ok=1
for pid in "${concurrent_pids[@]}"; do
  wait "$pid" || concurrent_ok=0
done
concurrent_ids=()
for i in $(seq 1 "$n"); do
  concurrent_ids+=("$(cat "$tmp_dir/out-$i")")
done
assert_eq "every concurrent reservation succeeded" "1" "$concurrent_ok"
unique_count="$(printf '%s\n' "${concurrent_ids[@]}" | sort -u | wc -l | tr -d ' ')"
assert_eq "concurrent reservations for the same date never collide" "$n" "$unique_count"
branch_count="$(git -C "$remote" for-each-ref --format='%(refname)' 'refs/heads/td/*' | wc -l | tr -d ' ')"
assert_eq "each concurrent reservation pushed its own branch" "$n" "$branch_count"

# --- works against a register that has not filed its first item --------------------
remote="$(make_remote)"
clone="$(clone_remote "$remote" w1)"
id="$(run_reserve "$clone" 260801)"
assert_eq "reserve works against an empty register" "TD-PPtest-26080101" "$id"

# --- dies without a git remote named origin -----------------------------------------
noorigin_dir="$tmp_dir/noorigin"
git init -q -b main "$noorigin_dir"
run_reserve "$noorigin_dir" 260801 >/dev/null 2>&1
noorigin_rc=$?
assert_eq "reserve dies without an origin remote" "1" "$([[ $noorigin_rc -ne 0 ]] && echo 1 || echo 0)"

# --- rejects a malformed date and a stray extra argument ---------------------------
remote="$(make_remote TD-PPtest-26071901 TD-PPtest-26072001 TD-PPtest-26072002)"
clone="$(clone_remote "$remote" w1)"

baddate_err="$(run_reserve "$clone" 2607 2>&1 >/dev/null)"
baddate_rc=$?
assert_eq "a malformed date is rejected" "1" "$([[ $baddate_rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "…with an explanatory message" "1" "$(grep -c 'Invalid date' <<<"$baddate_err")"

extra_err="$(run_reserve "$clone" 260720 extra 2>&1 >/dev/null)"
extra_rc=$?
assert_eq "a stray extra argument is rejected" "1" "$([[ $extra_rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "…with an explanatory message" "1" "$(grep -c 'Unexpected extra argument' <<<"$extra_err")"

# -------------------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
