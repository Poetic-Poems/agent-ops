#!/usr/bin/env bash
#
# gather-unvoid-requests.sh — pre-fetch the voids a human has asked, on GitHub,
# to be reopened (requirement 34f).
#
# Given a repo slug, print a JSON array of unvoid requests: the issues and pull
# requests in that repo carrying <label>, each resolved to the item ids it names
# and the moment the label was applied.
#
# Usage: gather-unvoid-requests.sh <owner/repo> [label]
#
# Request shape:
#   {
#     "repo": "Poetic-Poems/poetic",
#     "number": 92,
#     "url": "https://github.com/…/pull/92",
#     "kind": "pr",                          // or "issue"
#     "labelled_at": "2026-07-25T21:40:28Z", // when the label was applied
#     "items": ["TD26072114"]                // every item id the thing names
#   }
#
# ## Why this source exists
#
# Requirement 34c is emphatic that only a human may clear a void, and gives no
# agent a way to do it. That is the right rule, and it has one practical hole:
# the interface it leaves the human is a line appended by hand to
# `state_dir/log.jsonl`, and the human is not where that file is. The nodes are
# containers; `state_dir` is a Docker volume inside one. A maintainer who wants
# to reopen an item is holding a browser, looking at the pull request the void
# is about.
#
# So the escape hatch the whole design depends on was, in practice, out of
# reach — and the failure was silent in the worst way. Faced with a void on
# `TD26072114`, the maintainer did the obvious, discoverable thing and applied a
# label called `unvoided` to PR #92. Nothing read it. The item stayed void, the
# fleet went on standing down hourly, and the label sat there looking like the
# action had been taken. That instinct was not wrong, either: labelling a PR
# `autonomous-agent` already hands it to this pipeline, so a label *is* the
# established way to tell this system something from GitHub.
#
# This does not weaken requirement 34c. Only a human can apply the label — the
# Landing Gate reserves that, and no stage here labels anything with it — so
# "only a human may clear a void" holds exactly as before. What changes is
# where the human has to be standing.
#
# ## The requests are not the decision
#
# This script reports what carries the label; `lib/unvoid-label.sh` decides
# which of those actually clear anything, and it is deliberately narrow: a
# request clears a void only if that item is void *now* and the void was
# recorded *before* the label went on. Two properties follow, and both matter
# more than they look:
#
#   - **It is idempotent without touching the label.** A void already cleared is
#     not cleared again, so nothing needs removing and no cycle logs a duplicate.
#     That is why the label is never removed here: a self-limiting rule needs no
#     cleanup, and label edits are this system writing to its own bookkeeping
#     surface — the abandoned-drafts source discounts them for exactly that
#     reason (requirement 3e), so the only thing removal could achieve is churn
#     on the pull request a human is trying to unstick.
#   - **A label left behind cannot become a standing gag-removal.** A void
#     recorded *after* the label was applied is a fresh verdict the label never
#     saw, and it stands. Without that test an old label would silently
#     auto-clear every future void on the same item, which is a worse failure
#     than the one this fixes: it would look like nothing at all.
#
# ## The item ids
#
# Resolved the same way the other gatherers resolve theirs — `grep -oiE` over the
# branch name, title and body — so a label on the PR that is *about* an item
# reaches that item without the human having to know the register's spelling.
# An issue additionally names itself: its own number is an item id in this
# system (the `issues` source), and a human labelling an issue means that issue.
#
# All the ids found are reported, not just the first: a pull request may
# legitimately name two, and reporting one arbitrarily would work until the day
# it picked the wrong one. Over-reporting is bounded by the decision rule above
# — an id that is not void clears nothing — so the cost of a spurious id is nil
# and the cost of a missing one is the silence this source exists to end.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo with no
# labelled issues contributes `[]`; an API that will not answer contributes `[]`
# too, and the request is seen next cycle instead.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
label="${2:-unvoided}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-unvoid-requests.sh <owner/repo> [label]" >&2
  exit 64
fi

# One call for both kinds: the issues endpoint returns pull requests too (a hit
# carrying `pull_request` is one), which is the whole reason it is used here
# instead of `gh issue list` plus `gh pr list`. `state=all` because a human may
# well label the thing after closing it — "this was voided wrongly" is a verdict
# about the past.
hits="$(gh api --paginate \
          "repos/$slug/issues?labels=$label&state=all&per_page=100" \
          --jq '[.[] | {number, title: (.title // ""), body: (.body // ""),
                        url: (.html_url // ""),
                        kind: (if .pull_request then "pr" else "issue" end)}]' \
        2>/dev/null || true)"
if [[ -z "$hits" ]] || ! jq -e 'type == "array"' <<<"$hits" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi

out='[]'
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  number="$(jq -r '.number' <<<"$hit")"
  kind="$(jq -r '.kind' <<<"$hit")"
  [[ "$number" =~ ^[0-9]+$ ]] || continue

  # When the label went on. The timeline is the only place this exists — the
  # issue itself carries the label but not when it arrived — and the *latest*
  # application is the one that counts: a human who removes and re-applies a
  # label is asking again, about everything up to now.
  labelled_at="$(gh api --paginate "repos/$slug/issues/$number/timeline" \
                   --jq "[.[] | select(.event == \"labeled\" and .label.name == \"$label\")]
                         | sort_by(.created_at) | last | .created_at // empty" \
                 2>/dev/null || true)"
  # No timeline, no request. Guessing a timestamp here would defeat the one test
  # that stops a stale label clearing tomorrow's voids.
  [[ -n "$labelled_at" ]] || continue

  # A pull request's branch names its item more reliably than its prose does
  # (`td/TD26072114`), and costs one call on a hit that is rare by construction.
  branch=""
  if [[ "$kind" == "pr" ]]; then
    branch="$(gh api "repos/$slug/pulls/$number" --jq '.head.ref // ""' 2>/dev/null || true)"
  fi

  items="$(printf '%s %s' "$branch" "$(jq -r '.title + " " + .body' <<<"$hit")" \
           | grep -oiE '\b(TD[0-9]{8}|dependabot-alert-[0-9]+|code-scanning-alert-[0-9]+|review-[0-9]{4}-[0-9]{2}-[0-9]{2}-R-?[0-9]+|failed-run-[A-Za-z0-9._-]+)\b' \
           | jq -Rsc 'split("\n") | map(select(length > 0)) | unique' 2>/dev/null || printf '[]')"
  [[ -n "$items" ]] || items='[]'
  # An issue is its own item id (the `issues` source keys on the number), so a
  # human labelling issue 52 means issue 52 even if its text names nothing.
  if [[ "$kind" == "issue" ]]; then
    items="$(jq -c --arg n "$number" '. + [$n] | unique' <<<"$items" 2>/dev/null || printf '%s' "$items")"
  fi
  [[ "$(jq 'length' <<<"$items" 2>/dev/null || echo 0)" != "0" ]] || continue

  # $hit (the whole issue/PR listing hit) and $items (its matched item refs)
  # arrive on stdin, bound positionally with `input as $name` in the order
  # printed (requirement 4g, TD-PPagop-26081406) — never in argv.
  req="$(jq -nc --arg repo "$slug" --arg at "$labelled_at" \
    'input as $hit | input as $items |
     {repo: $repo, number: $hit.number, url: $hit.url, kind: $hit.kind,
      labelled_at: $at, items: $items}' <<<"$hit"$'\n'"$items")"
  # $req and the accumulator both arrive on stdin the same way.
  out="$(jq -nc 'input as $arr | input as $r | $arr + [$r]' <<<"$out"$'\n'"$req")"
done < <(jq -c '.[]' <<<"$hits" 2>/dev/null || true)

jq -c 'sort_by(.labelled_at)' <<<"$out"
