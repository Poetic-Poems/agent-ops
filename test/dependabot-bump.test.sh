#!/usr/bin/env bash
#
# test/dependabot-bump.test.sh — regression test for lib/dependabot-bump.sh
# (requirement 3s, issue #250): the rule shared by gather-merge-conflicts.sh
# and nudge-dependabot-rebase.sh for classifying a Dependabot PR, deciding
# whether it has already been asked to rebase, and deciding whether a newer
# bump of the same dependency has made it moot.
#
# Run directly:
#
#   ./test/dependabot-bump.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dependabot-bump.sh
. "$SCRIPT_DIR/lib/dependabot-bump.sh"

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

# --- The bot login ---
assert_eq "Dependabot's GraphQL-flavoured login is app/dependabot" \
  "app/dependabot" "$DEPENDABOT_LOGIN"

# --- The rebase marker: scoped to the head SHA, like the ref ---
assert_eq "the marker embeds the 12-char head SHA it was requested against" \
  '<!-- agent-ops:dependabot-rebase-requested head=c96c8ef9d31a -->' \
  "$(dependabot_rebase_marker c96c8ef9d31a)"

# --- Family/version parsing off the branch name ---
assert_eq "npm_and_yarn family strips the trailing version" \
  "dependabot/npm_and_yarn/eslint" \
  "$(dependabot_bump_family dependabot/npm_and_yarn/eslint-10.8.0)"
assert_eq "  ... and the version is what was stripped" \
  "10.8.0" "$(dependabot_bump_version dependabot/npm_and_yarn/eslint-10.8.0)"

assert_eq "github_actions family strips a nested action's version" \
  "dependabot/github_actions/github/codeql-action" \
  "$(dependabot_bump_family dependabot/github_actions/github/codeql-action-4.37.3)"
assert_eq "  ... and the version" \
  "4.37.3" "$(dependabot_bump_version dependabot/github_actions/github/codeql-action-4.37.3)"

assert_eq "a two-part version parses" \
  "9.39" "$(dependabot_bump_version dependabot/npm_and_yarn/eslint-9.39)"
assert_eq "a pre-release suffix is kept as part of the version" \
  "5.0.0-beta.1" "$(dependabot_bump_version dependabot/npm_and_yarn/foo-5.0.0-beta.1)"

assert_eq "a branch with no version-shaped tail yields no version" \
  "" "$(dependabot_bump_version dependabot/npm_and_yarn/no-version-here)"

# --- Supersession: the newest strictly-greater version among open PRs wins ---
all_open='[
  {"number": 129, "headRefName": "dependabot/npm_and_yarn/eslint-10.8.0"},
  {"number": 135, "headRefName": "dependabot/npm_and_yarn/eslint-10.9.0"},
  {"number": 170, "headRefName": "dependabot/github_actions/github/codeql-action-4.37.3"}
]'
assert_eq "a newer open bump of the same family supersedes the older one" \
  "135" "$(dependabot_newer_open_pr 129 dependabot/npm_and_yarn/eslint-10.8.0 "$all_open")"
assert_eq "the newest PR itself has nothing newer than it" \
  "" "$(dependabot_newer_open_pr 135 dependabot/npm_and_yarn/eslint-10.9.0 "$all_open")"
assert_eq "a different family (different dependency) never supersedes" \
  "" "$(dependabot_newer_open_pr 170 dependabot/github_actions/github/codeql-action-4.37.3 "$all_open")"

three_way='[
  {"number": 1, "headRefName": "dependabot/npm_and_yarn/eslint-9.0.0"},
  {"number": 2, "headRefName": "dependabot/npm_and_yarn/eslint-10.0.0"},
  {"number": 3, "headRefName": "dependabot/npm_and_yarn/eslint-10.8.0"}
]'
assert_eq "the strictly-highest version wins, not merely a later PR number" \
  "3" "$(dependabot_newer_open_pr 1 dependabot/npm_and_yarn/eslint-9.0.0 "$three_way")"

assert_eq "an unparseable branch (no version tail) is never superseded" \
  "" "$(dependabot_newer_open_pr 1 dependabot/npm_and_yarn/no-version-here "$all_open")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
