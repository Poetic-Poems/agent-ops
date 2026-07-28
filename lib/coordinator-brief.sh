#!/usr/bin/env bash
#
# lib/coordinator-brief.sh — the Co-Ordinator's repo/work-sources table,
# generated from config.json (issue #78, docs/IMPLEMENTATION-PIPELINE-SPEC.md
# requirement 4b).
#
# prompts/coordinator.md used to carry a hand-written copy of each configured
# repo's slug and ordered `sources` — the same data config.json's `repos`
# array already declares. That copy went stale the moment a consumer edited
# `config.json`, contradicting the README's claim that adding a repo or
# reordering its sources is a config-only change. This module renders the
# table from config.json instead, so the prompt file names no consumer repo.
#
# Sourced by agent-cycle.sh.

# coordinator_work_sources_table REPOS_JSON
# Prints a GitHub-flavoured Markdown table — one row per entry in REPOS_JSON
# (the shape of config.json's `repos` array: each entry at least `slug` and
# `sources`), numbering that entry's `sources` in the order given. Built from
# the plain, unfiltered config list (`all_repos_json` in agent-cycle.sh), not
# a cycle's back-pressure-restricted `ordered_repos_json`, so it always shows
# each repo's full configured priority — see the prompt's own note on why
# the runtime input's `repos[].sources` can legitimately be narrower for one
# cycle without the table being stale.
coordinator_work_sources_table() {
  local repos_json="$1"
  jq -r '
    ["| Repo | Work sources, in priority order |", "|---|---|"]
    + [ .[] | "| `" + .slug + "` | "
        + ( [ .sources | to_entries[] | "\(.key + 1). `\(.value)`" ] | join(" · ") )
        + " |" ]
    | .[]
  ' <<<"$repos_json"
}
