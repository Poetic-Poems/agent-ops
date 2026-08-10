#!/usr/bin/env bash
#
# lib/dependabot-bump.sh — the Dependabot-PR classification rule shared by
# scripts/gather-merge-conflicts.sh (which reports it on a merge-conflicts
# candidate) and scripts/nudge-dependabot-rebase.sh (which acts on that same
# candidate the moment it reads it): one definition, per requirement 34a, so
# the two readers cannot silently drift on what counts as "the same bump" or
# "already asked to rebase" (issue #250).
#
# Sourced, never executed: it sets no shell options, because every caller
# already runs under `set -uo pipefail` (or stricter) of its own.

# GitHub's GraphQL API — which every `gh --json` read goes through — reports
# Dependabot's own pull requests under this login, not the REST-flavoured
# "dependabot[bot]" some other GitHub surfaces use.
# shellcheck disable=SC2034  # read by scripts/gather-merge-conflicts.sh, which sources this file
DEPENDABOT_LOGIN='app/dependabot'

# dependabot_rebase_marker HEAD_SHA12
# The invisible marker this system stamps its own "@dependabot rebase"
# request with, scoped to the exact head SHA it was asked against (12 hex
# chars, matching gather-merge-conflicts.sh's own `pr-<n>-conflict-<sha>`
# ref) — the same reasoning as that ref: a rebase (successful or not) moves
# the head, so a marker scoped to the old head cannot be mistaken for one
# already covering a new state, and a conflict re-detected at the *same* head
# still matches the marker already there instead of asking again.
dependabot_rebase_marker() {
  printf '<!-- agent-ops:dependabot-rebase-requested head=%s -->' "$1"
}

# dependabot_bump_family HEAD_REF_NAME
# The Dependabot branch name with its trailing target-version segment
# stripped, e.g. `dependabot/npm_and_yarn/eslint-10.8.0` ->
# `dependabot/npm_and_yarn/eslint`. Two open Dependabot PRs share a "family"
# iff they are bumping the same dependency via the same package manager —
# Dependabot's own branch-naming convention is the only manager-agnostic
# signal available without parsing every ecosystem's manifest format.
dependabot_bump_family() {
  sed -E 's/-[0-9]+(\.[0-9]+){0,3}(-[A-Za-z0-9.]+)?$//' <<<"$1"
}

# dependabot_bump_version HEAD_REF_NAME
# The trailing target-version segment `dependabot_bump_family` strips, e.g.
# `10.8.0`. Empty if the branch does not end in a version-shaped segment —
# callers must treat that as "cannot compare" rather than guessing.
dependabot_bump_version() {
  grep -oE '[0-9]+(\.[0-9]+){0,3}(-[A-Za-z0-9.]+)?$' <<<"$1" || true
}

# dependabot_newer_open_pr THIS_NUMBER THIS_HEAD_REF ALL_OPEN_JSON
# ALL_OPEN_JSON: [{"number": N, "headRefName": "…"}, …] — every open
# Dependabot PR in the repo, from the same read THIS_NUMBER came from. Prints
# the PR number of another open PR bumping the same family to a strictly
# newer version, if one exists (the newest wins when more than one does) —
# empty otherwise.
#
# `sort -V` is what "newer" means here: Dependabot's target versions are not
# always strict semver (build/pre-release suffixes), and a version-aware sort
# degrades gracefully to lexical order on anything it cannot parse — the same
# direction as being over-cautious about a close call.
dependabot_newer_open_pr() {
  local this_number="$1" this_head="$2" all_json="$3"
  local family this_version best_number="" best_version
  family="$(dependabot_bump_family "$this_head")"
  this_version="$(dependabot_bump_version "$this_head")"
  [[ -n "$this_version" ]] || return 0
  best_version="$this_version"
  while IFS=$'\t' read -r number head; do
    [[ -n "$number" ]] || continue
    [[ "$(dependabot_bump_family "$head")" == "$family" ]] || continue
    local v
    v="$(dependabot_bump_version "$head")"
    [[ -n "$v" ]] || continue
    local newest
    newest="$(printf '%s\n%s\n' "$v" "$best_version" | sort -V | tail -1)"
    if [[ "$newest" == "$v" && "$v" != "$best_version" ]]; then
      best_version="$v"; best_number="$number"
    fi
  done < <(jq -r --arg n "$this_number" \
             '.[] | select((.number | tostring) != $n) | [(.number | tostring), .headRefName] | @tsv' \
             <<<"$all_json" 2>/dev/null || true)
  printf '%s' "$best_number"
}
