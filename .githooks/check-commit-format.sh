#!/bin/bash
#
# check-commit-format.sh — validate a commit subject line against
# Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/).
#
# Shared source of truth for:
#   - .githooks/commit-msg (local commit-msg hook, one message at a time,
#     opt-in per clone via `git config core.hooksPath .githooks`)
#   - .github/workflows/commit-format.yml (CI backstop, one call per commit
#     pushed to a pull request, so the check applies even in a clone that
#     never enabled the local hook)
#
# Usage:
#   .githooks/check-commit-format.sh "<subject line>"
#   echo "<subject line>" | .githooks/check-commit-format.sh
#
# Exit status: 0 if the subject line is exempt (Merge/fixup!/squash!, which
# aren't held to the format) or matches Conventional Commits; 1 otherwise,
# with an explanation on stderr.

set -euo pipefail

first_line="${1:-$(cat)}"

# Merge commits and fixup/squash commits (meant to be squashed before
# merging) aren't held to the format.
if [[ "$first_line" =~ ^(Merge |fixup!|squash!) ]]; then
  exit 0
fi

types='build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test'
pattern="^(${types})(\([a-zA-Z0-9_./-]+\))?!?: .+"

if [[ ! "$first_line" =~ $pattern ]]; then
  cat >&2 <<EOF
Commit message does not follow Conventional Commits format:

  <type>[(scope)][!]: <description>

Allowed types: build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test

Example: feat(poem-to-yaml): support multi-line titles

Your subject line was:
  $first_line
EOF
  exit 1
fi

exit 0
