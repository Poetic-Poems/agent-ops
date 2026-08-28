#!/usr/bin/env bash
#
# scripts/run-tests.sh — run the `test/` suite the way CI runs it: inside a
# throwaway container built from this repository's image, with the working tree
# copied in and nothing of the host or of any running node reaching it.
#
# The suite is plain bash and will start anywhere, which is the problem this
# script exists for: it *starts* anywhere and *passes* only in the environment
# CI uses, and the two ways of getting that wrong both look like a broken
# branch rather than a broken invocation.
#
#   - **From the checkout.** The host's `jq` is whatever the host has. `jq` 1.6
#     and 1.7 disagree about enough for roughly nine of these files to fail on
#     an untouched `main`, and none of those failures says "wrong jq" — they
#     say the thing the assertion was about.
#
#   - **Through `docker exec` into a running node.** The obvious fix for the
#     first problem, and its own trap: that container's `/app` is whatever
#     commit it was last built from, not the working tree in front of you, so
#     a fix made here is invisible to a suite run there — a broken branch and
#     a stale container look identical from the failures alone.
#
# So: `docker run`, never `docker exec`; the image, never the host; the working
# tree, never `/app`'s copy of it (the point is to test the change in front of
# you, and the image ships the commit it was built from).
#
# Usage:
#   ./scripts/run-tests.sh                      # every test/*.test.sh
#   ./scripts/run-tests.sh cycle-state doctor   # only those whose name matches
#   AGENT_OPS_TEST_IMAGE=agent-ops:dev ./scripts/run-tests.sh
#   ./scripts/run-tests.sh --list                     # just the selected names, one per line
#   ./scripts/run-tests.sh --list doctor               # --list honours the same filters
#
# --list needs no Docker and starts no container: it applies the filter to the
# host's own `test/*.test.sh` and prints the matching basenames, so a caller
# that must keep any single invocation below a wall (the Reviewer stage's own
# 10-minute Bash-tool ceiling — prompts/reviewer.md) can list the suite once,
# split that list into groups sized to clear the wall, and run
# `./scripts/run-tests.sh <group's names...>` once per group instead of one
# unbounded call over the whole suite.
#
# Exit status is 0 only if every test selected passed. (--list's exit status
# reports only whether it could list — 0 for a non-empty match, 2 for none —
# never a verdict on the tests themselves, which it does not run.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${AGENT_OPS_TEST_IMAGE:-ghcr.io/pullwright/agent-ops:latest}"

usage() {
  sed -n '3,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

list_only=0
filters=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage 0 ;;
    --list)    list_only=1 ;;
    --image)   printf 'run-tests: --image takes its value as AGENT_OPS_TEST_IMAGE=… instead\n' >&2; exit 2 ;;
    -*)        printf 'run-tests: unknown option %s\n' "$arg" >&2; usage 2 ;;
    *)         filters+=("$arg") ;;
  esac
done

# Applied identically to the container's own loop below — a basename matches
# iff no filter was given, or at least one filter is a substring of it — so
# what --list prints is exactly what a docker run of the same arguments would
# select. Keep the two in sync if either changes.
if [[ "$list_only" -eq 1 ]]; then
  shopt -s nullglob
  selected=()
  for t in "$SCRIPT_DIR"/test/*.test.sh; do
    name="$(basename "$t")"
    if [[ ${#filters[@]} -gt 0 ]]; then
      keep=""
      for f in "${filters[@]}"; do
        [[ "$name" == *"$f"* ]] && keep=1
      done
      [[ -n "$keep" ]] || continue
    fi
    selected+=("$name")
  done
  if [[ ${#selected[@]} -eq 0 ]]; then
    printf 'run-tests: no test matched\n' >&2
    exit 2
  fi
  printf '%s\n' "${selected[@]}"
  exit 0
fi

command -v docker >/dev/null 2>&1 || {
  printf 'run-tests: docker is required — it is what makes this run the same suite CI runs\n' >&2
  exit 2
}

# Pull only when the image is not already local: the common case is a fleet
# host that already has it, and a network round trip per test run is a good way
# to stop anyone running the tests.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  printf 'run-tests: %s is not present locally, pulling\n' "$IMAGE" >&2
  docker pull "$IMAGE" >/dev/null || {
    printf 'run-tests: could not pull %s\n' "$IMAGE" >&2
    exit 2
  }
fi

# The filter is applied inside the container, against the basenames the loop
# walks, so `run-tests.sh doctor` and `run-tests.sh doctor.test.sh` both work
# and neither depends on the host's shell globbing the repository.
filter_str="$(printf '%s ' "${filters[@]+"${filters[@]}"}")"

printf 'run-tests: image %s\n' "$IMAGE" >&2
[[ ${#filters[@]} -eq 0 ]] || printf 'run-tests: filter %s\n' "$filter_str" >&2

# `--entrypoint bash` because the image's own entrypoint renders a crontab and
# announces a node role, none of which this is. `-i` because the working tree
# arrives on stdin as a tar: a bind mount would carry the host's uids and, when
# read-only, its own set of failures that are not the branch's fault either.
tar --exclude=.git --exclude=node_modules -cf - -C "$SCRIPT_DIR" . \
  | docker run --rm -i --entrypoint bash -e "RUN_TESTS_FILTER=$filter_str" "$IMAGE" -lc '
      set -uo pipefail
      work=/tmp/agent-ops-tests
      rm -rf "$work"; mkdir -p "$work"
      tar -xf - -C "$work" || { echo "run-tests: could not unpack the working tree" >&2; exit 2; }
      cd "$work" || exit 2

      shopt -s nullglob
      selected=()
      for t in test/*.test.sh; do
        if [[ -n "${RUN_TESTS_FILTER// /}" ]]; then
          keep=""
          for f in $RUN_TESTS_FILTER; do
            [[ "$(basename "$t")" == *"$f"* ]] && keep=1
          done
          [[ -n "$keep" ]] || continue
        fi
        selected+=("$t")
      done

      if [[ ${#selected[@]} -eq 0 ]]; then
        echo "run-tests: no test matched" >&2
        exit 2
      fi

      failed=0 passed=0
      failures=()
      for t in "${selected[@]}"; do
        if out="$(timeout 600 bash "$t" 2>&1)"; then
          printf "PASS  %s\n" "$(basename "$t")"
          passed=$(( passed + 1 ))
        else
          printf "FAIL  %s\n" "$(basename "$t")"
          printf "%s\n" "$out" | sed "s/^/      | /"
          failures+=("$(basename "$t")")
          failed=$(( failed + 1 ))
        fi
      done

      printf "\nrun-tests: %d passed, %d failed, %d total\n" "$passed" "$failed" "${#selected[@]}"
      if (( failed > 0 )); then
        printf "run-tests: failing: %s\n" "${failures[*]}"
        exit 1
      fi
    '
