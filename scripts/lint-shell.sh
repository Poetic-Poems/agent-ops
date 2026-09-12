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
# *estimated* cost (see `estimated_follow_mib`) exceeds what is available is
# linted WITHOUT `-x`, which costs the analysis of its source targets and
# nothing else. Three checks are suppressed for those files alone, because all
# three are artefacts of the degradation rather than findings about the code:
# SC1091 ("not following") fires on every source line, and SC2154/SC2034 fire
# on every variable that crosses the boundary in either direction — read here
# and assigned in a module, or assigned here for a module to read. All three
# are checked properly wherever there is room to follow (CI has it), which is
# what makes suppressing them here a deferral rather than a hole.
#
# THE GUARD APPLIES TO EVERY FILE, not only ones above some fixed line count —
# this used to gate on a 10,000-line threshold (`LARGE_LINES`) and let every
# smaller file run unconditionally, whatever the budget. `scripts/doctor.sh` is
# what that costs: a 9,367-line union, comfortably under the old gate, and an
# estimated 772 MiB to follow — against the 768 MiB a node bound by a parent
# cgroup's `memory.high` (deploy/docker/compose.yaml,
# `scripts/cgroup-parent-setup.sh`) actually has (agent-ops#1305). What "large
# enough to matter" means depends on what the node running this actually has,
# not on a line count picked in advance — so every file's estimated cost is
# compared against the budget, and a small file on a small enough budget
# degrades exactly like a large one on a starved one.
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
# THE DEFAULT `set` CONVENTION: a new script starts `set -uo pipefail`, matching
# the majority of this repository's scripts. `-e` is an opt-in, not a default —
# reach for it only when a script's author has a specific reason, and comment
# why at the point it's set. `-e`'s hazard is documented once, in
# docs/IMPLEMENTATION-PIPELINE-SPEC.md's Gotchas table ("A helper returns
# non-zero for a legitimately empty result, and the script runs under `set
# -e`"); this comment does not repeat it.
#
# Arguments are passed through to shellcheck (e.g. `-f gcc`, `--severity=error`)
# — except any argument that names a file that actually exists, which selects
# that file to lint instead of the full sweep. Given one or more of those, the
# git ls-files discovery below is skipped entirely and only the named files
# are checked — through the same one-process-per-file loop, so the size guard
# and the confined SC1091/SC2154/SC2034 handling apply to them exactly as they
# do to the sweep. An argument that looks like a file but does not exist is
# not a selector: it falls through and is forwarded to shellcheck as an
# option, same as always, so this never grows new error handling for a typo'd
# path. Argless stays the full sweep, unchanged.

set -uo pipefail

# Captured before the cd below, so a relative file-selector argument (the
# common case: run from the repo root, name a path from there) resolves
# against where the caller actually stood rather than against repo_root.
invocation_dir="$PWD"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

# The window this container's own cgroup cannot see: an ancestor cgroup's
# `memory.high`, bind-mounted read-only where `deploy/docker/compose.yaml`
# puts it (the same file `lib/memory.sh`'s `memory_cgroup_parent_high` reads,
# for the same reason — a cgroup namespace makes this container's own cgroup
# the root of what it can see, so a parent ceiling is otherwise invisible from
# in here). Overridable so the test suite can point it at a fixture instead of
# the real mount.
PARENT_HIGH_FILE="${LINT_SHELL_PARENT_HIGH_FILE:-/run/cgroup-parent/memory.high}"

# What a shellcheck invocation costs to follow a file's sources with `-x`, in
# MiB, is estimated by interpolating/extrapolating between three points
# measured with the pinned 0.10.0 linter (see `estimated_follow_mib` below):
# review-cycle.sh's 4,945-line union at 396 MiB, a 172-line entry point over
# the same `lib/*.sh` modules at 23,569 lines / 1,983 MiB, and agent-cycle.sh's
# own 26,262-line union, which passed 4,543 MiB before the kernel killed it —
# a floor, not a peak, since that run never finished. Overridable in pairs so
# the test suite can shrink the whole curve onto a small fixture file rather
# than construct one many thousand lines long to exercise it for real.
COST_P1_LINES="${LINT_SHELL_COST_P1_LINES:-4945}";   COST_P1_MIB="${LINT_SHELL_COST_P1_MIB:-396}"
COST_P2_LINES="${LINT_SHELL_COST_P2_LINES:-23569}";  COST_P2_MIB="${LINT_SHELL_COST_P2_MIB:-1983}"
COST_P3_LINES="${LINT_SHELL_COST_P3_LINES:-26262}";  COST_P3_MIB="${LINT_SHELL_COST_P3_MIB:-4543}"

# LINT_SHELL_FOLLOW_MIB set to exactly `0` disables the guard outright: every
# file is followed with `-x` whatever the estimate above says. This is CI's
# own escape hatch (.github/workflows/shellcheck.yml) — a runner has the
# memory, and the gate's coverage should not quietly track how much RAM GitHub
# happens to give it this month. Any other value never decides a tier — the
# estimator above is what a real run compares the budget against, and the
# `LINT_SHELL_COST_P*` pairs are how a test moves that estimate instead. It is
# read in one other place only, as `budget_mib`'s "nothing readable anywhere"
# fallback: on a host with neither a cgroup nor a `/proc/meminfo` to read, the
# budget becomes this number so the run assumes room rather than degrading
# every file on an accounting scheme we simply cannot read.
FOLLOW_MIB="${LINT_SHELL_FOLLOW_MIB:-6144}"
# What running shellcheck on any one file WITHOUT `-x` costs, in MiB — roughly
# constant regardless of that file's own size, unlike the union-scaled
# estimate above: measured at 634 MiB for agent-cycle.sh's own 2,865 lines.
PLAIN_MIB="${LINT_SHELL_PLAIN_MIB:-1024}"

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
# How much memory a single shellcheck may actually use here, in MiB, and which
# ceiling it came from (as a second word: container | parent | host | none) —
# the smallest of this process's own cgroup ceiling, the parent cgroup's
# `memory.high` (PARENT_HIGH_FILE, invisible to this container's own cgroup
# reads — see that variable's own header), and what the host says is
# available. The container figure matters because inside the scheduler
# container /proc/meminfo still reports the host's memory, and it is the
# cgroup that does the killing; the parent figure matters because a scheduler
# bounded by a parent's `memory.high` throttles well below its own
# `memory.max`, and a shellcheck invocation sized to the container alone is
# exactly the shape of stage that wedged agent-ops#1305's node; the host
# figure matters because a developer's machine has no cgroup limit worth
# reading. An unreadable or absent limit is not treated as zero — it means "no
# constraint found", and only a constraint we actually read may lower this.
# Read via `read -r budget budget_source <<<"$(budget_mib)"`, never by command
# substitution assigning straight to two variables — bash has no such form.
budget_mib() {
  local budget=0 v source=none
  if [[ -r /sys/fs/cgroup/memory.max ]]; then                     # cgroup v2
    v="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
    if [[ "$v" =~ ^[0-9]+$ ]]; then budget=$(( v / 1048576 )); source=container; fi
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then # cgroup v1
    v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
    # v1 spells "unlimited" as a number near 2^63, not as a word
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v < 4611686018427387904 )); then
      budget=$(( v / 1048576 )); source=container
    fi
  fi
  v="$(cat "$PARENT_HIGH_FILE" 2>/dev/null)"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    v=$(( v / 1048576 ))
    if (( budget == 0 || v < budget )); then budget=$v; source=parent; fi
  fi
  v="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then
    if (( budget == 0 || v < budget )); then budget=$v; source=host; fi
  fi
  # Nothing readable anywhere: assume room rather than degrade silently on a
  # platform whose accounting we simply do not know how to read.
  if (( budget == 0 )); then budget=$FOLLOW_MIB; source=none; fi
  printf '%s %s\n' "$budget" "$source"
}

# budget_source_phrase SOURCE
# The reader-facing name of whichever ceiling budget_mib found smallest, so a
# degraded/skipped warning can name it: without this, an operator reading a
# 1,536 MiB container and a 768 MiB verdict has no way to tell the number came
# from the parent cgroup rather than a broken container reading.
budget_source_phrase() {
  case "${1:-none}" in
    container) printf "this container's memory.max" ;;
    parent)    printf "the parent cgroup's memory.high" ;;
    host)      printf 'MemAvailable' ;;
    *)         printf 'no constraint found' ;;
  esac
}

# estimated_follow_mib UNION_LINES
# The MiB a shellcheck -x invocation is estimated to cost for a file whose
# analysed union (see `analysed_lines`) is UNION_LINES — piecewise-linear
# through the three measured points named by the COST_P* pair above, and
# extrapolated past the last of them using that final segment's own slope,
# since the true curve climbs steeper still there (a 2,693-line difference
# between the last two measured points cost more than twice the memory) and
# under-estimating is the one way this guard can fail unsafely. This is
# frankly an estimate, not a measurement — shellcheck's memory use depends on
# more than line count — but it is the only figure cheap enough to compute
# per file on every run, and erring high is the safe direction to be wrong in.
estimated_follow_mib() {  # <union-lines>
  awk -v u="${1:-0}" \
      -v x1="$COST_P1_LINES" -v y1="$COST_P1_MIB" \
      -v x2="$COST_P2_LINES" -v y2="$COST_P2_MIB" \
      -v x3="$COST_P3_LINES" -v y3="$COST_P3_MIB" '
    BEGIN {
      if (u <= x1)      { printf "%d", (y1 / x1) * u }
      else if (u <= x2) { printf "%d", y1 + ((y2 - y1) / (x2 - x1)) * (u - x1) }
      else              { printf "%d", y2 + ((y3 - y2) / (x3 - x2)) * (u - x2) }
    }'
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

# Split the arguments into file selectors (paths that actually exist) and
# everything else, which stays destined for shellcheck as an option (see this
# file's own header). Tried first as-is against repo_root, which this script
# has already cd-ed into — the common case, invoked from the repo root with a
# repo-root-relative path, needs no rewriting and keeps that path exactly as
# given rather than expanded to an absolute one. Only a path that doesn't
# resolve there falls back to invocation_dir, for a caller standing somewhere
# else and naming a path relative to itself.
selected=()
opts=()
for a in "$@"; do
  if [[ -f "$a" ]]; then
    selected+=( "$a" )
  else
    candidate="$a"
    [[ "$candidate" == /* ]] || candidate="$invocation_dir/$candidate"
    if [[ -f "$candidate" ]]; then
      selected+=( "$candidate" )
    else
      opts+=( "$a" )
    fi
  fi
done

files=()
if (( ${#selected[@]} > 0 )); then
  files=( "${selected[@]}" )
else
  while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue          # a deleted-but-staged path lists too
    if [[ "$f" == *.sh ]]; then
      files+=( "$f" )
    elif head -n1 -- "$f" 2>/dev/null | grep -qE '^#!.*[ /](ba)?sh( |$)'; then
      files+=( "$f" )
    fi
  done < <(git ls-files -z)
fi

if (( ${#files[@]} == 0 )); then
  echo "lint-shell: found no shell scripts to check — that cannot be right." >&2
  exit 1
fi

read -r budget budget_source <<<"$(budget_mib)"
budget_phrase="$(budget_source_phrase "$budget_source")"

printf 'lint-shell: %s\n' "$(shellcheck --version | sed -n 's/^version: /shellcheck /p')"
printf 'lint-shell: checking %d shell scripts, one process each, %s MiB available (%s)\n' \
  "${#files[@]}" "$budget" "$budget_phrase"

rc=0
degraded=()
skipped=()

declare -A union_lines=()
declare -A follow_cost_mib=()
for f in "${files[@]}"; do
  union_lines["$f"]="$(analysed_lines "$f")"

  if (( FOLLOW_MIB == 0 )); then
    # The CI escape hatch (see FOLLOW_MIB's own header): every file follows,
    # whatever the estimate below would have said.
    shellcheck -x "${opts[@]}" -- "$f" || rc=1
    continue
  fi

  follow_cost_mib["$f"]="$(estimated_follow_mib "${union_lines[$f]}")"
  # What we can afford decides how much of this file gets looked at — checked
  # for every file, not only ones above some line-count threshold: a file well
  # under any such threshold still costs real memory to follow, and a budget
  # starved enough (a parented container, agent-ops#1305) can be below even
  # that.
  if (( follow_cost_mib["$f"] <= budget )); then
    shellcheck -x "${opts[@]}" -- "$f" || rc=1
  elif (( budget >= PLAIN_MIB )); then
    degraded+=( "$f" )
    # SC2154/SC2034 alongside SC1091: all three are artefacts of not following
    # the sources, never findings about the code. Without `-x` shellcheck sees
    # no module this file sources, so every variable that crosses the boundary
    # reads as unassigned (SC2154) or as assigned and never used (SC2034) —
    # 25 of them in agent-cycle.sh, against nothing wrong with any of them.
    # They are checked in full wherever there is room to follow, which is why
    # this is a deferral and not a hole.
    shellcheck -e SC1091,SC2154,SC2034 "${opts[@]}" -- "$f" || rc=1
  else
    skipped+=( "$f" )
  fi
done

for f in "${degraded[@]}"; do
  printf 'lint-shell: WARNING: %s (%s lines, %s including everything it sources) was linted WITHOUT -x — its source targets were not analysed, and SC1091/SC2154/SC2034 were suppressed for it because they say nothing about the code once they are not. %s MiB available (%s), an estimated %s MiB needed to follow them. See #771, #1305.\n' \
    "$f" "$(wc -l < "$f")" "${union_lines[$f]}" "$budget" "$budget_phrase" "${follow_cost_mib[$f]}" >&2
done
for f in "${skipped[@]}"; do
  printf 'lint-shell: WARNING: %s (%s lines, %s including everything it sources) was NOT LINTED AT ALL — shellcheck cannot analyse it in %s MiB (%s) and would be OOM-killed trying, taking the cycle with it. CI has the memory and does check it. See #770, #771, #1305.\n' \
    "$f" "$(wc -l < "$f")" "${union_lines[$f]}" "$budget" "$budget_phrase" >&2
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
