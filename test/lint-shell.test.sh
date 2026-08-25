#!/usr/bin/env bash
#
# test/lint-shell.test.sh — the shell linter's driver, which is the gate every
# pull request is judged by and the one an Implementer runs before pushing.
#
# The properties that matter, all of them consequences of #770 — where a lone
# linter process spanning the whole tree was OOM-killed on one oversized file,
# taking the other 253 scripts' coverage and sometimes the Implementer with it:
#
#   - one process per file, so a script that cannot be linted costs only
#     itself and every other script is still checked;
#   - `-x` is used, so a `source` is followed rather than raising SC1091;
#   - a file large enough to be dangerous is judged against the memory actually
#     available: followed when there is room, linted without `-x` when there is
#     less, and not run at all when there is too little — because the failure
#     mode being avoided is not a bad report, it is a dead cycle;
#   - every degraded or skipped file is announced, since silence would read as
#     coverage that did not happen;
#   - findings anywhere still fail the run, and a skip on its own does not.
#
# `shellcheck` is stubbed, so this runs with no shellcheck installed, straight
# out of the checkout, exactly like the rest of the suite.
#
# Run directly: ./test/lint-shell.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$SCRIPT_DIR/scripts/lint-shell.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- A repository to lint, and a stub linter to lint it with ---------------
repo="$tmp_dir/repo"
mkdir -p "$repo/scripts"
cp "$LINT" "$repo/scripts/lint-shell.sh"
chmod +x "$repo/scripts/lint-shell.sh"

# three ordinary scripts, one of them oversized, one of them with a finding
printf '#!/usr/bin/env bash\ntrue\n'                         > "$repo/small.sh"
printf '#!/usr/bin/env bash\ntrue\n'                         > "$repo/findme.sh"
{ printf '#!/usr/bin/env bash\n'; for _ in $(seq 1 40); do printf 'true\n'; done; } > "$repo/big.sh"
# one script with no extension, discovered by its shebang
printf '#!/bin/sh\ntrue\n'                                   > "$repo/hook-like"
chmod +x "$repo/hook-like"

git -C "$repo" init --quiet
# deliberately not `add -A`: the driver under test lives in this repo but must
# not be part of the file set it discovers, or the fixtures stop being the fixtures.
git -C "$repo" add small.sh findme.sh big.sh hook-like
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m init

bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"
invocations="$tmp_dir/invocations"
cat > "$bin_dir/shellcheck" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.10.0\n'
  exit 0
fi
printf '%s\n' "\$*" >> "$invocations"
for a in "\$@"; do
  [[ "\$a" == *findme.sh ]] && exit 1
done
exit 0
STUB
chmod +x "$bin_dir/shellcheck"
export PATH="$bin_dir:$PATH"

# run_lint TIER — TIER is follow | degraded | skip, forced by moving the
# thresholds rather than by pretending about the machine's real memory.
run_lint() {
  local tier="$1" follow plain
  case "$tier" in
    follow)   follow=1 ;         plain=1 ;;
    degraded) follow=99999999 ;  plain=1 ;;
    skip)     follow=99999999 ;  plain=99999999 ;;
  esac
  : > "$invocations"
  ( cd "$repo" && LINT_SHELL_LARGE_LINES=10 \
                  LINT_SHELL_FOLLOW_MIB="$follow" \
                  LINT_SHELL_PLAIN_MIB="$plain" \
                  ./scripts/lint-shell.sh 2>&1 )
}

# --- One process per file, not one for the lot -----------------------------
out="$(run_lint follow)"
rc_follow=$?
assert_eq "one shellcheck process per file, not one invocation for all of them" \
  "4" "$(wc -l < "$invocations" | tr -d ' ')"
assert_contains "the run says so, so the change is visible in its own output" \
  "one process each" "$out"

# --- -x is used, so a source is followed rather than raising SC1091 --------
assert_contains "an ordinary file is followed with -x" "-x -- small.sh" "$(cat "$invocations")"
assert_contains "a shebang-only file is discovered and followed too" "-x -- hook-like" "$(cat "$invocations")"

# --- The size guard, tier by tier ------------------------------------------
assert_contains "with room to follow it, a large file is linted with -x like any other" \
  "-x -- big.sh" "$(cat "$invocations")"
assert_not_contains "and is not announced as degraded when nothing was given up" \
  "WITHOUT -x" "$out"

out="$(run_lint degraded)"
assert_contains "with less room, a large file is linted without -x" \
  "-e SC1091,SC2154,SC2034 -- big.sh" "$(cat "$invocations")"
assert_not_contains "and -x is not passed for it" "-x -- big.sh" "$(cat "$invocations")"
assert_contains "the reduction in coverage is announced, not left to be discovered" \
  "was linted WITHOUT -x" "$out"
assert_contains "the announcement names the file" "big.sh" "$out"
assert_contains "small files are still followed in the same run" \
  "-x -- small.sh" "$(cat "$invocations")"

out="$(run_lint skip)"
assert_not_contains "with too little room, shellcheck is never run on the large file at all" \
  "big.sh" "$(cat "$invocations")"
assert_contains "the skip is announced loudly" "NOT LINTED AT ALL" "$out"
assert_contains "and explains that the alternative was a dead cycle, not a bad report" \
  "OOM-killed" "$out"
assert_contains "and points at where it does get checked" "CI has the memory" "$out"
assert_eq "every other file is still linted — the whole point of one process each" \
  "3" "$(wc -l < "$invocations" | tr -d ' ')"

# --- Findings still fail the run, and a skip alone does not ----------------
assert_eq "a file with findings fails the run" "1" "$rc_follow"

git -C "$repo" rm --quiet findme.sh
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m drop
out="$(run_lint skip)"; rc_skip=$?
assert_eq "a skipped file on its own does not fail the run" "0" "$rc_skip"
assert_contains "though the run still reports what it did not fully check" \
  "skipped" "$out"

out="$(run_lint follow)"; rc_clean=$?
assert_eq "a wholly clean run exits 0" "0" "$rc_clean"
assert_contains "and says plainly that it is clean" "lint-shell: clean" "$out"

# --- "Large" is the union `-x` parses, not the file's own length -----------
# The distinction #771 turns on: splitting agent-cycle.sh moved lines out of it
# and into the modules it sources, and `-x` re-inlines every one of them — so a
# guard reading the file's own `wc -l` would have declared the problem solved
# and then OOM-killed the node it ran on. Two three-line entry points make the
# point without any memory being involved: they differ only in what they source.
printf '#!/usr/bin/env bash\n# shellcheck source=big.sh\n. ./big.sh\n'     > "$repo/wide-entry.sh"
printf '#!/usr/bin/env bash\n# shellcheck source=small.sh\n. ./small.sh\n' > "$repo/lone-entry.sh"
git -C "$repo" add wide-entry.sh lone-entry.sh
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m entries

out="$(run_lint degraded)"
assert_contains "a three-line file that sources a large one is treated as large" \
  "-e SC1091,SC2154,SC2034 -- wide-entry.sh" "$(cat "$invocations")"
assert_not_contains "and is not followed with -x" "-x -- wide-entry.sh" "$(cat "$invocations")"
assert_contains "a three-line file that sources a small one is followed as usual" \
  "-x -- lone-entry.sh" "$(cat "$invocations")"
assert_contains "the warning reports the union, not only the file's own length" \
  "3 lines, 44 including everything it sources" "$out"

printf '\n%s\n' "-----"
if (( failures == 0 )); then
  printf 'lint-shell.test.sh: all assertions passed\n'
  exit 0
fi
printf 'lint-shell.test.sh: %d assertion(s) failed\n' "$failures"
exit 1
