#!/usr/bin/env bash
#
# scripts/check-closing-keyword.sh — deterministic check that an issue-sourced
# agent PR actually links its issue (requirement 25a).
#
# PR #206 wrote "Implements #198" in its body instead of a GitHub closing
# keyword. GitHub only auto-closes an issue on merge for a recognised keyword
# (close(s|d), fix(es|ed), resolve(s|d)) immediately followed by "#N", so
# #198 stayed open for three days after its own fix merged, and was
# re-selected and re-voided twice in the meantime — prose describing the same
# intent is invisible to GitHub and to this check alike. Prompt instruction
# alone had already asked for this and been silently skipped, so this cannot
# be enforced by prompt alone (issue #240) — it has to be a fact CI checks.
#
# The Implementor stamps an issue-sourced PR body with an invisible marker
# naming which issue it claims to close:
#
#   <!-- agent-ops:closes-issue item=198 -->
#
# (`prompts/implementor.md`'s Procedure step 2). This script's whole job is
# to fail when that marker is present without a matching closing keyword for
# the same number — it says nothing about a PR that carries no marker at
# all, which covers every non-issue-sourced source (tech-debt, register-
# hygiene, security, project-review, …) that has nothing to close.
#
# Usage: check-closing-keyword.sh <pr-body-text>
# Exit 0: no marker, or a marker with a matching closing keyword.
# Exit 1: a marker with no matching closing keyword, printing why.

set -uo pipefail

body="${1:-}"

# Every marker this PR body carries, one item number per line. A PR could in
# principle carry more than one (unusual, but the check must not silently
# check only the first).
mapfile -t items < <(grep -oE '<!-- agent-ops:closes-issue item=[0-9]+ -->' <<<"$body" \
  | grep -oE '[0-9]+')

(( ${#items[@]} > 0 )) || exit 0

status=0
for item in "${items[@]}"; do
  # GitHub's own closing-keyword list: close(s|d), fix(es|ed), resolve(s|d),
  # case-insensitive, immediately followed by "#N" (optionally ": #N") for
  # the same number the marker names.
  #
  # The keyword has to be a word of its own, as it is to GitHub's own parser —
  # "unclosed #198" and "discloses #198" contain "closed" and "closes" but
  # close nothing, and a check that accepted them would pass exactly the PR
  # it exists to fail. Markdown emphasis, backticks and hyphens are all
  # non-alphanumeric, so "**Closes #198**" still passes.
  if ! grep -qiE "(^|[^[:alnum:]])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#${item}([^0-9]|\$)" <<<"$body"; then
    echo "::error::PR body names issue #${item} (agent-ops:closes-issue marker) but has no closing keyword (Closes/Fixes/Resolves #${item}) for it" >&2
    status=1
  fi
done

exit "$status"
