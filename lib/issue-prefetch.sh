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
