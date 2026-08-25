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
# the size of what it analyses, and what `-x` analyses is not one file: it is
# the union of that file and everything it sources, parsed as a single program.
# `agent-cycle.sh` is what makes the point. It was 10,136 lines when the guard
# was written and is 2,865 now (#771), but it names all fifty `lib/*.sh`
# modules in `# shellcheck source=` directives, so `-x` still parses 26,262
# lines for it and still needs more than 4.5 GiB — while the same file without
# `-x` needs 634 MiB, and `review-cycle.sh`, whose union is 4,945 lines, is
# followed in 396 MiB. The scheduler container is capped at 1,536 MiB and VM1
# has 3 GB in total, so on a node this does not OOM the linter so much as the
# cycle — the kernel picks a victim from the whole cgroup, and the Implementer
# is often the one it takes (#770).
#
# So the guard measures the union (`analysed_lines` below), never the file's
# own length: the split that shrank `agent-cycle.sh` moved lines from it into
# the modules it sources, and `-x` re-inlines every one of them. A file whose
# union is above the threshold is linted WITHOUT `-x`, which costs the
# analysis of its source targets and nothing else. Three checks are suppressed
# for those files alone, because all three are artefacts of the degradation
# rather than findings about the code: SC1091 ("not following") fires on every
# source line, and SC2154/SC2034 fire on every variable that crosses the
# boundary in either direction — read here and assigned in a module, or
# assigned here for a module to read. All three are checked properly wherever
# there is room to follow (CI has it), which is what makes suppressing them
# here a deferral rather than a hole.
#
# This is still a real reduction in coverage, so it is announced on every run
# rather than left to be discovered. What the guard can no longer say is that
# it will one day apply to nothing: the union it measures is the whole of this
# pipeline's code, and following it will always cost what following it costs.
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

# A script whose *analysed union* (see `analysed_lines`) is at or above this
# many lines is "large" for the purposes of the guard above. Chosen to separate
# the one offender from the rest of the tree rather than to tune anything:
# agent-cycle.sh's union is 26,262 lines and the next largest is
# scripts/publish-dashboard.sh's at 7,522, so anything in this range picks out
# the same single file. It also sits below the point where the pinned linter's
# cost starts to climb steeply — a 161-line entry point over the same fifty
# modules, 24,000 lines of union, costs 2.0 GiB; agent-cycle.sh's own 26,262
# passed 4.5 GiB before the kernel stopped it — rather than inside it.
LARGE_LINES="${LINT_SHELL_LARGE_LINES:-10000}"

# What a large file costs, in MiB of headroom, as measured with the pinned
# 0.10.0 linter on agent-cycle.sh at 2,865 lines and a 26,262-line union: it
# reached 4,543 MiB with `-x` before the kernel killed it, and completed
# without `-x` in 634 MiB. The first is a floor, not a peak — the run never
# finished — and the GHC collector expands to fill what it is given, so both
# figures below add the headroom that turns a measurement into a decision.
FOLLOW_MIB="${LINT_SHELL_FOLLOW_MIB:-6144}"    # enough to lint a large file with -x
PLAIN_MIB="${LINT_SHELL_PLAIN_MIB:-1024}"      # enough to lint one at all

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

# analysed_lines FILE
# How much shell source `shellcheck -x` will actually parse for FILE: its own
# lines plus those of every file it names in a `# shellcheck source=`
# directive, transitively, each counted once however many files source it.
# This, not FILE's own length, is what decides the memory — `-x` analyses the
# union as a single program — and it is why the guard above measures it: after
# #771 `agent-cycle.sh` is 2,865 lines and its union is 26,262, and it is the
# 26,262 that costs the memory.
#
# Directive targets are repository-root-relative, which is where this script
# has already `cd`-ed. A target that does not exist is counted as nothing
# rather than treated as an error: a wrong path is shellcheck's own SC1091 to
# report, not this estimate's to fail on.
analysed_lines() {  # <file>
  local -A seen=()
  local -a queue=( "$1" )
  local i=0 f target n total=0
  while (( i < ${#queue[@]} )); do
    f="${queue[i]}"; i=$(( i + 1 ))
    [[ -z "${seen[$f]:-}" ]] || continue
    seen["$f"]=1
    [[ -f "$f" ]] || continue
    n="$(wc -l < "$f" 2>/dev/null || echo 0)"
    total=$(( total + n ))
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      queue+=( "$target" )
    done < <(sed -n 's/^# shellcheck source=//p' "$f" 2>/dev/null)
  done
  printf '%s\n' "$total"
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

declare -A union_lines=()
for f in "${files[@]}"; do
  union_lines["$f"]="$(analysed_lines "$f")"
  if (( union_lines["$f"] < LARGE_LINES )); then
    shellcheck -x "$@" -- "$f" || rc=1
    continue
  fi

  # Large. What we can afford decides how much of it gets looked at.
  if (( budget >= FOLLOW_MIB )); then
    shellcheck -x "$@" -- "$f" || rc=1
  elif (( budget >= PLAIN_MIB )); then
    degraded+=( "$f" )
    # SC2154/SC2034 alongside SC1091: all three are artefacts of not following
    # the sources, never findings about the code. Without `-x` shellcheck sees
    # no module this file sources, so every variable that crosses the boundary
    # reads as unassigned (SC2154) or as assigned and never used (SC2034) —
    # 25 of them in agent-cycle.sh, against nothing wrong with any of them.
    # They are checked in full wherever there is room to follow, which is why
    # this is a deferral and not a hole.
    shellcheck -e SC1091,SC2154,SC2034 "$@" -- "$f" || rc=1
  else
    skipped+=( "$f" )
  fi
done

for f in "${degraded[@]}"; do
  printf 'lint-shell: WARNING: %s (%s lines, %s including everything it sources) was linted WITHOUT -x — its source targets were not analysed, and SC1091/SC2154/SC2034 were suppressed for it because they say nothing about the code once they are not. %s MiB available, %s MiB needed to follow them. See #771.\n' \
    "$f" "$(wc -l < "$f")" "${union_lines[$f]}" "$budget" "$FOLLOW_MIB" >&2
done
for f in "${skipped[@]}"; do
  printf 'lint-shell: WARNING: %s (%s lines, %s including everything it sources) was NOT LINTED AT ALL — shellcheck cannot analyse it in %s MiB and would be OOM-killed trying, taking the cycle with it. CI has the memory and does check it. See #770, #771.\n' \
    "$f" "$(wc -l < "$f")" "${union_lines[$f]}" "$budget" >&2
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
