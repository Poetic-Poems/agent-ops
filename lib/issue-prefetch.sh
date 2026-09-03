#!/usr/bin/env bash
#
# lib/issue-prefetch.sh — the issue-walking engine shared by
# scripts/gather-issues.sh and scripts/gather-tech-debt.sh (issue #875, D15 as
# revised by #869): both fetch a repo's open issues, drop what requirement
# 16's issue-exclusion bullet always drops deterministically — a pull request
# the issues endpoint interleaves, an assigned issue, an issue labelled
# `blocked` (any case), or one naming a still-open `Blocked-by:` reference
# (requirement 34j) — and fetch each survivor's whole comment thread to
# resolve that last check. They differ only in which issues qualify for
# candidacy at all (every open issue for `issues`; only those labelled
# `pw::type:tech-debt` for `tech-debt`), so that is the one thing left to each
# caller's own jq `select`, not a second copy of the shared walk.
#
# `issue_prefetch_open_issues` below is that walk itself (agent-ops#1085): one
# paginated GraphQL query fetching every open issue's whole comment thread
# alongside it, replacing what was one REST listing call plus one further
# REST call per surviving candidate for its comments — see that function's
# own header for the point-cost measurement and the exact REST fields its
# output mirrors so neither caller's own jq needed to change shape.
#
# Sourced, never executed: like lib/dependency-gate.sh, it sets no shell
# options and expects the caller already running under `set -uo pipefail`.
# `issue_blocked_by_ref` below calls `dependency_refs`
# (lib/dependency-gate.sh), which the caller must source first.

# ISSUE_DETERMINISTIC_FILTER_JQ — two jq function definitions, meant to be
# concatenated ahead of a `[.[] | select(issue_deterministic_ok) | ...]`
# program:
#
#   - `issue_deterministic_ok` — true for an issue object (`.`) that is not a
#     pull request, not assigned, and not labelled `blocked` (whatever the
#     case).
#   - `issue_exclude_reason` — for an issue object `issue_deterministic_ok`
#     rejected on one of the two *reportable* grounds, which of
#     `"assigned"`/`"blocked-label"` applies (matching the order
#     `issue_deterministic_ok` itself checks them in); `null` otherwise — a
#     pull request is dropped by both scripts without ever being reported,
#     since it was never a candidate issue to begin with.
#
# Defined once so gather-issues.sh's own three drops and gather-tech-debt.sh's
# copy of them cannot drift apart.
# shellcheck disable=SC2034  # read by scripts/gather-issues.sh and scripts/gather-tech-debt.sh, which source this file
read -r -d '' ISSUE_DETERMINISTIC_FILTER_JQ <<'JQ' || true
def issue_deterministic_ok:
  (has("pull_request") | not)
  and (((.assignees // []) | length) == 0)
  and (([.labels[]?.name | ascii_downcase] | index("blocked")) | not);
def issue_exclude_reason:
  if ((.assignees // []) | length) > 0 then "assigned"
  elif (([.labels[]?.name | ascii_downcase] | index("blocked")) != null) then "blocked-label"
  else null end;
JQ

# issue_blocked_by_ref SLUG THREAD_TEXT
# Print the display form (`#195` for a same-repo reference, `owner/repo#42`
# for a cross-repo one) of THREAD_TEXT's first still-open `Blocked-by:`
# reference (requirement 34j), or print nothing — and return 0 either way —
# when it names none, or every one it names is already closed. A reference
# whose live state cannot be read counts as still-open, the same fail-safe
# direction every other deterministic exclusion in this file takes.
issue_blocked_by_ref() {
  local slug="$1" thread_text="$2" dep_refs ref ref_repo ref_n ref_state ref_display
  dep_refs="$(dependency_refs "$thread_text")"
  [[ "$(jq 'length' <<<"$dep_refs" 2>/dev/null || echo 0)" != "0" ]] || return 0
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    if [[ "$ref" == */* ]]; then
      ref_repo="${ref%%#*}"
      ref_n="${ref##*#}"
    else
      ref_repo="$slug"
      ref_n="$ref"
    fi
    ref_state="$(gh api "repos/$ref_repo/issues/$ref_n" --jq '.state' 2>/dev/null || true)"
    if [[ "$ref_state" != "closed" ]]; then
      ref_display="$ref"; [[ "$ref_display" == */* ]] || ref_display="#$ref_display"
      printf '%s\n' "$ref_display"
      return 0
    fi
  done < <(jq -r '.[]' <<<"$dep_refs")
  return 0
}

# How many 100-issue pages `issue_prefetch_open_issues` will walk before
# giving up on a repository whose open-issue count keeps paging past it —
# stated and checked the same way `lib/github-limit.sh`'s own header requires
# of any listing that could otherwise silently truncate (`GITHUB_PR_LIST_LIMIT`
# there, this here): a configured repository past 2000 open issues has a
# hygiene problem this cap is not trying to solve, and the cap being reached
# is reported to the caller (exit 2) rather than read as a complete walk.
ISSUE_PREFETCH_MAX_PAGES="${ISSUE_PREFETCH_MAX_PAGES:-20}"

# issue_prefetch_open_issues SLUG
# Print every open issue in SLUG, each carrying its own whole comment thread
# — one paginated GraphQL walk (agent-ops#1085) replacing what was one REST
# listing call (`repos/<slug>/issues?state=open&per_page=100`, capped at its
# first page with no further pagination) plus one further REST call per
# surviving candidate for its comments
# (`repos/<slug>/issues/<n>/comments?per_page=100`, itself capped at its
# first page) — agent-ops alone had 151 of those in the 48 hours the issue
# that drove this migration measured. Measured live, 2026-08-31, against
# this repository's own 165 open issues: `rateLimit{cost}` on the identical
# selection set reports 4 per 100-issue page, 8 total here — against what
# was, at minimum, one REST `core` point per surviving issue for its
# comments alone, on top of the listing itself.
#
# Each element is shaped to match the REST fields both callers already read
# from `/repos/<slug>/issues` and `/repos/<slug>/issues/<n>/comments`, so
# `$ISSUE_DETERMINISTIC_FILTER_JQ` and each caller's own candidate-shaping
# filter needed no change of their own to keep reading it:
#
#   {number, html_url, title, user: {login}, created_at, updated_at, body,
#    labels: [{name}],
#    assignees: [{} …one placeholder element per assignee — only the count is
#                ever read, by issue_deterministic_ok above],
#    issue_field_values: [{issue_field_name, single_select_option: {name}}],
#    comments: [{user: {login}, created_at, body}]}
#
# No `pull_request` key is ever present — the REST shape's own signal that an
# entry is a pull request rather than an issue — because GraphQL's `issues`
# connection never returns one to begin with; `issue_deterministic_ok`'s own
# `has("pull_request") | not` test reads that permanent absence exactly as it
# read a real REST issue's own.
#
# `comments(last:100)`, not the REST predecessor's own uncontrolled
# `per_page=100` (which took the *oldest* 100 comments, with no further
# pagination past them): the newest 100 is the more useful bound where a
# thread runs longer than that, since clarifications and corrected
# requirements accumulate at the end of a thread, not its start — the same
# reasoning `prompts/implementer.md`'s own "read the whole thread" instruction
# gives for `gh issue view --comments` over a bare view. `labels`/
# `issueFieldValues` take one generous page each (100/20) no repository's own
# issue has ever approached.
#
# Paginated over `issues(states:OPEN, first:100, after:$cursor)` up to
# `ISSUE_PREFETCH_MAX_PAGES` above. Prints the array gathered so far and
# returns 2 if that cap is hit before the walk's own last page — a caller may
# still use a capped set, knowing it might be incomplete, the same
# `github_pr_list_truncated` direction-of-harm judgement call sites elsewhere
# in this repository already make explicit rather than leaving to a silent
# truncation. Prints nothing and returns 1 when the read fails outright (bad
# arguments, an unreachable API, a malformed response) — the same "could not
# ask" contract every other GraphQL reader in this repository follows.
issue_prefetch_open_issues() {
  local slug="${1:-}" gh_bin="${ISSUE_PREFETCH_GH:-gh}"
  local owner repo cursor="" page=0 out='[]' resp nodes has_next
  [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
  owner="${slug%%/*}"; repo="${slug#*/}"

  while (( page < ISSUE_PREFETCH_MAX_PAGES )); do
    page=$(( page + 1 ))
    local -a args=(-f owner="$owner" -f repo="$repo")
    [[ -n "$cursor" ]] && args+=(-f cursor="$cursor")
    # shellcheck disable=SC2016  # GraphQL's own variables, not the shell's.
    resp="$("$gh_bin" api graphql \
      -f query='query($owner:String!,$repo:String!,$cursor:String){
        repository(owner:$owner,name:$repo){
          issues(states:OPEN, first:100, after:$cursor){
            pageInfo{ hasNextPage endCursor }
            nodes{
              number title url createdAt updatedAt body
              author{ login }
              labels(first:100){ nodes{ name } }
              assignees(first:1){ totalCount }
              issueFieldValues(first:20){
                nodes{
                  __typename
                  ... on IssueFieldSingleSelectValue {
                    name
                    field{ __typename ... on IssueFieldSingleSelect { name } }
                  }
                }
              }
              comments(last:100){ nodes{ author{ login } createdAt body } }
            }
          }
        }
      }' \
      "${args[@]}" \
      --jq '.data.repository.issues
            | {hasNextPage: .pageInfo.hasNextPage, endCursor: (.pageInfo.endCursor // ""),
               nodes: [.nodes[] | {
                 number: .number, html_url: .url, title: .title,
                 user: {login: (.author.login // "")},
                 created_at: .createdAt, updated_at: .updatedAt, body: (.body // ""),
                 labels: [.labels.nodes[] | {name: .name}],
                 assignees: [range(0; .assignees.totalCount) | {}],
                 issue_field_values: [.issueFieldValues.nodes[]
                   | select(.__typename == "IssueFieldSingleSelectValue")
                   | {issue_field_name: (.field.name // ""),
                      single_select_option: {name: .name}}],
                 comments: [.comments.nodes[] | {
                   user: {login: (.author.login // "")},
                   created_at: .createdAt, body: (.body // "")}]}]}' \
      2>/dev/null)" || return 1
    nodes="$(jq -c '.nodes' <<<"$resp" 2>/dev/null)" || return 1
    has_next="$(jq -r '.hasNextPage' <<<"$resp" 2>/dev/null)" || return 1
    cursor="$(jq -r '.endCursor' <<<"$resp" 2>/dev/null)" || return 1
    out="$(jq -nc 'input as $a | input as $b | $a + $b' <<<"$out"$'\n'"$nodes")" || return 1
    if [[ "$has_next" != "true" ]]; then
      printf '%s' "$out"
      return 0
    fi
    [[ -n "$cursor" ]] || break
  done
  printf '%s' "$out"
  return 2
}
