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
# All of them in ONE invocation, which matters: shellcheck resolves a `source`
# only to a file it was also given, so linting them one at a time raises SC1091
# ("not following") on every library the pipelines share. `-x` follows those
# sources for real.
#
# Exit 0 iff shellcheck reports nothing at all — info findings included, which
# is what the specs mean by "clean". Where a finding is a false positive, the
# fix is a `# shellcheck disable=...` in the file that carries it, with a
# comment saying why; there are deliberately no exclusions here, because an
# exclusion here would silently cover code that has not been looked at.
#
# Arguments are passed through to shellcheck (e.g. `-f gcc`, `--severity=error`).

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

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

printf 'lint-shell: %s\n' "$(shellcheck --version | sed -n 's/^version: /shellcheck /p')"
printf 'lint-shell: checking %d shell scripts\n' "${#files[@]}"

shellcheck -x "$@" -- "${files[@]}"
rc=$?

if (( rc == 0 )); then
  printf 'lint-shell: clean\n'
else
  printf 'lint-shell: shellcheck exited %d — see the findings above\n' "$rc" >&2
fi
exit "$rc"
