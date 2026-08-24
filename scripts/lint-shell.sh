#!/usr/bin/env bash
#
# scripts/lint-shell.sh — shellcheck every shell script in the repository.
#
# The specs have long required a clean shellcheck, and nothing ran it, so it
# drifted: four findings accumulated in the Publisher unnoticed (#104). This is
# what `.github/workflows/shellcheck.yml` runs on every pull request, and what
# you should run before opening one:
#
#   ./scripts/lint-shell.sh
#
# The file set and the invocation live here rather than in the workflow, for the
# same reason the Conventional Commits pattern lives in
# .githooks/check-commit-format.sh: CI and a developer must be checking the same
# thing, and two copies of a rule are one copy too many.
#
# Which files: every tracked file named *.sh, plus every tracked file whose
# first line is a sh or bash shebang — the init scripts and git hooks that
# carry no extension. Discovered rather than listed, so a script added tomorrow
# is covered without anyone remembering to add it here.
#
# ONE FILE PER PROCESS, which is not how this started. It used to lint the whole
# set in a single invocation, on the stated grounds that `-x` needs its sources
# among the inputs to follow them. That is not so: `-x` follows a `source` by
# path whether or not the target was also passed in, and each of `lib/claim.sh`,
# `lib/fleet.sh` and `review-cycle.sh` lints clean on its own. What the single
# invocation did do was couple every script's fate to every other's: when the
# linter died on one file, the run died with it and the other 253 scripts went
# unchecked (#770). Per file, a script that cannot be linted costs only itself.
#
# THE SIZE GUARD exists because shellcheck 0.10.0's memory grows sharply with
# file size: `agent-cycle.sh` (10,136 lines) needs more than 3 GiB with `-x`,
# where every other script in the tree fits in a fraction of that. The scheduler
# container is capped at 1,536 MiB and VM1 has 3 GB in total, so on a node this
# does not OOM the linter so much as the cycle — the kernel picks a victim from
# the whole cgroup, and the Implementer is often the one it takes (#770).
#
# So a file above the threshold is linted WITHOUT `-x`, which costs the analysis
# of its `source` targets and nothing else; SC1091 ("not following") is
# suppressed for those files alone, because without `-x` it fires on every
# source line and says nothing about the code. This is a real reduction in
# coverage, so it is announced on every run rather than left to be discovered.
# The threshold is not tuning: it is a statement that a shell script this large
# is a defect in itself, tracked as #771, and when that is fixed this guard
# stops applying to anything and can go.
#
# Exit 0 iff shellcheck reports nothing at all — info findings included, which
# is what the specs mean by "clean". Where a finding is a false positive, the
# fix is a `# shellcheck disable=...` in the file that carries it, with a
# comment saying why; there are deliberately no per-check exclusions here,
# because an exclusion here would silently cover code that has not been looked
# at. The SC1091 suppression above is the one exception, and it is confined to
# files the guard has already announced.
#
# Arguments are passed through to shellcheck (e.g. `-f gcc`, `--severity=error`).

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

# A script at or above this many lines is "large" for the purposes of the guard
# above. Chosen to separate the one offender from the rest of the tree rather
# than to tune anything: agent-cycle.sh is 10,136 lines and the next largest
# script is 2,548, so anything in this range picks out the same single file.
LARGE_LINES="${LINT_SHELL_LARGE_LINES:-3000}"

# What a large file costs, in MiB of headroom, as measured with the pinned
# 0.10.0 linter on agent-cycle.sh: killed at a 3,072 MiB cap with `-x`, and
# killed at 1,536 MiB — the scheduler's whole ceiling — even without it. Both
# figures are floors, because the GHC collector expands to fill what it is
# given; these add the headroom that turns a floor into a decision.
FOLLOW_MIB="${LINT_SHELL_FOLLOW_MIB:-4096}"    # enough to lint a large file with -x
PLAIN_MIB="${LINT_SHELL_PLAIN_MIB:-3072}"      # enough to lint one at all

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "lint-shell: shellcheck is not installed." >&2
  echo "  Debian/Ubuntu: sudo apt-get install shellcheck" >&2
  echo "  or see https://github.com/koalaman/shellcheck#installing" >&2
  exit 127
fi

if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "lint-shell: not a git repository — the file set comes from git ls-files." >&2
  exit 1
fi

# budget_mib
# How much memory a single shellcheck may actually use here, in MiB: the
# smaller of this process's cgroup ceiling and what the host says is available.
# The cgroup matters because inside the scheduler container /proc/meminfo still
# reports the host's memory, and it is the cgroup that does the killing; the
# host figure matters because a developer's machine has no cgroup limit worth
# reading. An unreadable or absent limit is not treated as zero — it means "no
# constraint found", and only a constraint we actually read may lower this.
budget_mib() {
  local budget=0 v
  if [[ -r /sys/fs/cgroup/memory.max ]]; then                     # cgroup v2
    v="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
    [[ "$v" =~ ^[0-9]+$ ]] && budget=$(( v / 1048576 ))
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then # cgroup v1
    v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
    # v1 spells "unlimited" as a number near 2^63, not as a word
    [[ "$v" =~ ^[0-9]+$ ]] && (( v < 4611686018427387904 )) && budget=$(( v / 1048576 ))
  fi
  v="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then
    (( budget == 0 || v < budget )) && budget=$v
  fi
  # Nothing readable anywhere: assume room rather than degrade silently on a
  # platform whose accounting we simply do not know how to read.
  (( budget == 0 )) && budget=$FOLLOW_MIB
  printf '%s\n' "$budget"
}

files=()
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue          # a deleted-but-staged path lists too
  if [[ "$f" == *.sh ]]; then
    files+=( "$f" )
  elif head -n1 -- "$f" 2>/dev/null | grep -qE '^#!.*[ /](ba)?sh( |$)'; then
    files+=( "$f" )
  fi
done < <(git ls-files -z)

if (( ${#files[@]} == 0 )); then
  echo "lint-shell: found no shell scripts to check — that cannot be right." >&2
  exit 1
fi

budget="$(budget_mib)"

printf 'lint-shell: %s\n' "$(shellcheck --version | sed -n 's/^version: /shellcheck /p')"
printf 'lint-shell: checking %d shell scripts, one process each, %s MiB available\n' \
  "${#files[@]}" "$budget"

rc=0
degraded=()
skipped=()

for f in "${files[@]}"; do
  lines="$(wc -l < "$f" 2>/dev/null || echo 0)"
  if (( lines < LARGE_LINES )); then
    shellcheck -x "$@" -- "$f" || rc=1
    continue
  fi

  # Large. What we can afford decides how much of it gets looked at.
  if (( budget >= FOLLOW_MIB )); then
    shellcheck -x "$@" -- "$f" || rc=1
  elif (( budget >= PLAIN_MIB )); then
    degraded+=( "$f" )
    shellcheck -e SC1091 "$@" -- "$f" || rc=1
  else
    skipped+=( "$f" )
  fi
done

for f in "${degraded[@]}"; do
  printf 'lint-shell: WARNING: %s (%s lines) was linted WITHOUT -x — its source targets were not analysed. %s MiB available, %s MiB needed to follow them. See #771.\n' \
    "$f" "$(wc -l < "$f")" "$budget" "$FOLLOW_MIB" >&2
done
for f in "${skipped[@]}"; do
  printf 'lint-shell: WARNING: %s (%s lines) was NOT LINTED AT ALL — shellcheck cannot analyse it in %s MiB and would be OOM-killed trying, taking the cycle with it. CI has the memory and does check it. See #770, #771.\n' \
    "$f" "$(wc -l < "$f")" "$budget" >&2
done

if (( rc == 0 )); then
  if (( ${#skipped[@]} > 0 || ${#degraded[@]} > 0 )); then
    printf 'lint-shell: clean, with %d file(s) skipped and %d not fully followed — see the warnings above\n' \
      "${#skipped[@]}" "${#degraded[@]}"
  else
    printf 'lint-shell: clean\n'
  fi
else
  printf 'lint-shell: shellcheck reported findings — see above\n' >&2
fi
exit "$rc"
