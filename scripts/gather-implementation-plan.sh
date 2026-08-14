#!/usr/bin/env bash
#
# gather-implementation-plan.sh — deterministically pre-fetch the open
# (unchecked) tasks in a repo's implementation-plan document, for the
# Refiner (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 3y;
# TD-PPagop-26081307).
#
# Usage: gather-implementation-plan.sh <owner/repo> <default-branch> <path>
#
# Prints a JSON array; each entry is one candidate task:
#
#   {
#     "source": "implementation-plan",
#     "ref": "W10-breach-handling",   // the task's own id, as it appears in the document
#     "id": "W10-breach-handling",
#     "title": "…the text after the id on the task-list line…",
#     "url": "https://github.com/…/blob/main/docs/IMPLEMENTATION-PLAN.md",
#     "body": "…the whole task-list line, verbatim…"
#   }
#
# In document order (the plan's own task sequence, not sorted).
#
# ## Deliberately narrower than gather-tech-debt.sh
#
# This does not decide which task is *next* (the Co-Ordinator's own live
# read, prompts/coordinator.md, does that — "the next unblocked task(s) in
# that repo's plan document") and does not follow any dependency between
# tasks: every open task-list line is a candidate, in document order, and
# the usual `refinement_policy`/refined/blocked/void/claimed exclusions in
# `refiner_candidate_items` decide the rest.
#
# ## Only a whole-word id, in the same shape work-gone.sh already commits to
#
# A task-list line counts only when it opens with a bullet and an empty
# checkbox (`- [ ]`, `* [ ]`, `1. [ ]`) followed by an id matching
# `WORK_GONE_PLAN_RE` (lib/work-gone.sh) — the same shape
# `work_gone_plan_ids` uses to route a blocked ref back to this document, so
# an id this gatherer mints is always one a later block on it can be
# resolved against. A line whose leading token isn't that shape is not a
# task this pipeline can track by id, and is skipped rather than guessed at.
#
# Degrades to `[]` (exit 0) on any failure, like gather-tech-debt.sh: a
# missing or unreadable document (a repo's `implementation_plan_path`
# pointing at a file since deleted or renamed) is silent; a genuine API
# failure is loud on stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/../lib/github-limit.sh"
# WORK_GONE_PLAN_RE — the one definition of what a plan task id looks like,
# shared with the reconciliation pass that later routes a blocked ref back
# to this same document (lib/work-gone.sh).
# shellcheck source=lib/work-gone.sh
. "$SCRIPT_DIR/../lib/work-gone.sh"

slug="${1:-}"
default_branch="${2:-}"
path="${3:-}"
if [[ -z "$slug" || -z "$default_branch" || -z "$path" ]]; then
  echo "usage: gather-implementation-plan.sh <owner/repo> <default-branch> <path>" >&2
  exit 64
fi

degrade() {
  echo "gather-implementation-plan: $slug: $*" >&2
  printf '[]\n'
  exit 0
}

work="$(mktemp -d)" || degrade "could not create a scratch directory"
trap 'rm -rf "$work"' EXIT

# The one place a missing plan is normal rather than a fault: a repo's
# `implementation_plan_path` can point at a file since deleted or renamed.
# A 404 is that answer and is silent; anything else — auth, rate limit,
# network — is diagnosed on stderr.
content_json="$(gh api "repos/$slug/contents/$path?ref=$default_branch" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  if [[ "$(jq -r '.status // ""' <<<"$content_json" 2>/dev/null)" != "404" ]]; then
    cat "$work/gh.err" >&2
  fi
  printf '[]\n'
  exit 0
fi

blob="$(jq -r '.content // ""' <<<"$content_json" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null || true)"
if [[ -z "$blob" ]]; then
  printf '[]\n'
  exit 0
fi

# open_tasks — read the plan document on stdin, print one TSV record per open
# task-list line: id, title (the text after "id:", trimmed), then the whole
# original line (tab-separated; `read` below assigns the remainder of the
# line, tabs and all, to the third variable, so an embedded tab in the
# original line cannot desynchronise the first two fields). Only a bullet
# (`-`/`*`/`N.`) followed by an *empty* checkbox counts — a done task
# (`[x]`/`[X]`) needs no forward specification.
open_tasks() {
  awk '
    /^[ \t]*([-*]|[0-9]+\.)[ \t]*\[ \]/ {
      orig = $0
      line = $0
      sub(/^[ \t]*([-*]|[0-9]+\.)[ \t]*\[ \][ \t]*/, "", line)
      colon = index(line, ":")
      if (colon > 0) {
        id = substr(line, 1, colon - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", id)
        title = substr(line, colon + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", title)
        if (id != "") printf "%s\t%s\t%s\n", id, title, orig
      }
    }
  '
}

out='[]'
while IFS=$'\t' read -r id title body; do
  [[ -n "$id" ]] || continue
  [[ "$id" =~ $WORK_GONE_PLAN_RE ]] || continue
  entry="$(jq -nc --arg id "$id" --arg title "$title" \
    --arg url "https://github.com/$slug/blob/$default_branch/$path" --arg body "$body" \
    '{source: "implementation-plan", ref: $id, id: $id, title: $title, url: $url, body: $body}')" \
    || degrade "entry assembly failed for $id"
  # Same stdin accumulation as gather-tech-debt.sh (requirement 4g) — never
  # in argv.
  out="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$out"$'\n'"$entry")" \
    || degrade "array assembly failed for $id"
done < <(printf '%s\n' "$blob" | open_tasks)

printf '%s\n' "$out"
