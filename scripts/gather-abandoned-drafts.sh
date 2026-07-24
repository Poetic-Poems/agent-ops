#!/usr/bin/env bash
#
# gather-abandoned-drafts.sh — pre-fetch a repo's draft pull requests this system
# raised and then abandoned (requirement 3e).
#
# Given a repo slug, print a JSON array of abandoned-draft candidates: open,
# *draft* PRs this system raised whose head has not moved for at least
# <stale-hours>. Each is a nearly-finished piece of work an Implementor stage
# started, claimed with a draft PR, and never carried to `ready` — because the
# stage timed out, hit a usage limit, or died. Finishing one costs less than
# starting fresh and frees the back-pressure slot the stalled PR occupies.
#
# Usage: gather-abandoned-drafts.sh <owner/repo> <pr-label> <branch-prefix> [stale-hours]
#
# Candidate shape:
#   {
#     "source": "abandoned-drafts",
#     "ref": "pr-80-abandoned-1a2b3c4d5e6f", // stable, and scoped to THIS head
#     "number": 80,
#     "pr_number": 80,
#     "url": "https://github.com/…/pull/80",
#     "pr_url": "https://github.com/…/pull/80",
#     "title": "fix(cache): …",
#     "branch": "agent/td26072001-…",
#     "item": "TD26072001",                  // the originating item, if inferable
#     "head_sha": "1a2b3c4d5e6f…",
#     "updated_at": "2026-07-24T03:00:00Z",
#     "body": "…the draft PR's own description, the original plan, verbatim…"
#   }
#
# ## Why the Script fetches this and not the Co-Ordinator
#
# Same three reasons as gather-review-feedback.sh (requirement 3c), and the third
# is again the one that matters:
#   1. Cost, as with gather-findings.sh (requirement 3a): the staleness test is a
#      timestamp comparison against the clock, not something worth a model turn.
#   2. The draft PR's own body is the original plan and must reach the Implementor
#      verbatim, not summarised.
#   3. The candidate rule below has to exist in the fingerprint (requirement 3b)
#      regardless, and requirement 34a says a rule two components compute gets one
#      definition. This script is it — and this source is the reason draft
#      staleness is fingerprinted at all (see the note on the clock below).
#
# ## The candidate rule
#
# A PR is a candidate iff all of:
#   - it is open and **is** a draft. A draft is precisely the Implementor's own
#     claim marker (requirement 23): a draft that has been sitting untouched is a
#     claim whose owner never came back. A *ready* PR is finished work waiting on
#     the human and is not ours to touch (that is review-feedback's job).
#   - it carries <pr-label> and its head branch starts with <branch-prefix> (or
#     `td/`, the tech-debt claim branch) — i.e. this system raised it. The Human
#     Gate reserves every other branch for humans; an abandoned draft on a human's
#     branch is the human's to finish, not ours to force-push.
#   - its head has not moved for at least <stale-hours>: `updatedAt` is older than
#     `now − stale-hours`. `updatedAt` advances on a push, a comment, a label or a
#     title edit, so any activity at all — a peer node still working it, a human
#     poking it — resets the clock and keeps it off this list. The default
#     threshold is `abandoned_draft_after_hours` (3 h), comfortably beyond a whole
#     cycle (90 min Implementor + 30 min Reviewer) so a draft that is merely being
#     worked never qualifies.
#
# ## Why staleness must be sampled here, against the clock
#
# This is the one candidate rule in the system that turns on the passage of time
# rather than on an event. `updatedAt` does not change as the hours pass, so a
# draft crossing the threshold moves *nothing* in gather-source-state.sh's
# open-PR digest — the fingerprint (requirement 3b) would sit unchanged across
# exactly the moment work appears, and the no-op short-circuit would skip it
# until the forced recheck. Computing candidacy here, with `date`, and feeding
# the resulting array into the fingerprint verbatim (as agent-cycle.sh does for
# review_feedback) is what makes the transition visible: the array gains an entry
# the cycle the draft goes stale, and that busts the fingerprint. See
# lib/noop-skip.sh.
#
# ## Why the ref is scoped to the head SHA
#
# `pr-<n>-abandoned-<head-sha>`, not `pr-<n>-abandoned`. An item recorded blocked
# (requirement 34) stays blocked until something clears it, so a bare
# `pr-<n>-abandoned` that an Implementor once failed on would still be blocked
# after fresh commits landed on the branch — and the new state, which might be
# perfectly finishable, would never be looked at again. Scoping the ref to the
# head SHA means each distinct abandoned state is its own item that no older block
# covers, while a draft abandoned again at the *same* head keeps the same ref and
# stays correctly blocked. Same reasoning as review-feedback's per-round
# `pr-<n>-review-<id>` refs: an unattended system expires items by irrelevance.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo with no
# abandoned drafts contributes `[]`; an API that will not answer contributes `[]`
# too (the source simply does not fire this cycle) — but note gather-source-state.sh
# must NOT be so relaxed about the same PRs, for the reason it documents.

set -uo pipefail

slug="${1:-}"
pr_label="${2:-autonomous-agent}"
branch_prefix="${3:-agent/}"
stale_hours="${4:-3}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-abandoned-drafts.sh <owner/repo> [pr-label] [branch-prefix] [stale-hours]" >&2
  exit 64
fi

# The staleness cutoff, computed once against the clock: a PR whose `updatedAt`
# is older than this has been untouched for at least stale_hours. An unparseable
# threshold is a bug in the caller, not grounds to hand back a wrong answer, so
# fail safe to an empty list rather than treating every draft as abandoned.
if ! [[ "$stale_hours" =~ ^[0-9]+$ ]]; then
  printf '[]'
  exit 0
fi
cutoff="$(date -u -d "${stale_hours} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
if [[ -z "$cutoff" ]]; then
  printf '[]'
  exit 0
fi

# The open, agent-raised, draft PRs, with their commits so the head SHA arrives
# in the same call. stderr is shown, not swallowed: a `gh` that rejects a field
# name otherwise degrades to an empty array indistinguishable from "no abandoned
# drafts", and the source silently never fires — the `[]`-on-error trap in the
# Gotchas table that cost gather-review-feedback.sh a debugging round.
# Heads may be `agent/…` or — for tech-debt items, whose claim branch is the
# human protocol's own `td/<ID>` — `td/…`; the label filter is the primary
# "ours" signal either way.
prs="$(gh pr list -R "$slug" --state open --label "$pr_label" \
        --json number,title,headRefName,commits,isDraft,updatedAt,url,body \
        --jq "[.[] | select(.isDraft)
                   | select(.updatedAt < \"$cutoff\")
                   | select((.headRefName | startswith(\"$branch_prefix\"))
                            or (.headRefName | startswith(\"td/\")))]" \
        || true)"
if [[ -z "$prs" ]] || ! jq -e 'type == "array"' <<<"$prs" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi

out='[]'
while IFS= read -r pr; do
  [[ -n "$pr" ]] || continue
  number="$(jq -r '.number' <<<"$pr")"
  head_sha="$(jq -r '.commits[-1].oid // ""' <<<"$pr")"
  [[ -n "$head_sha" ]] || continue

  # The originating item, so the Implementor can find the tech-debt entry, issue,
  # or finding this PR came from. Best-effort: a ref in the branch name or body.
  # Absence is normal and must not disqualify the candidate — the PR body and its
  # diff are the brief, not the register entry.
  item="$(jq -r '(.headRefName + " " + (.body // ""))' <<<"$pr" \
          | grep -oiE '\b(TD[0-9]{8}|dependabot-alert-[0-9]+|code-scanning-alert-[0-9]+|review-[0-9]{4}-[0-9]{2}-[0-9]{2}-R-?[0-9]+)\b' \
          | head -n1 || true)"

  cand="$(jq -nc \
    --argjson pr "$pr" \
    --arg ref "pr-${number}-abandoned-${head_sha:0:12}" \
    --arg item "$item" \
    --arg head_sha "$head_sha" \
    '{source: "abandoned-drafts",
      ref: $ref,
      number: $pr.number,
      pr_number: $pr.number,
      url: $pr.url,
      pr_url: $pr.url,
      title: $pr.title,
      branch: $pr.headRefName,
      item: (if $item == "" then null else $item end),
      head_sha: $head_sha,
      updated_at: $pr.updatedAt,
      body: ($pr.body // "")}')"
  out="$(jq -c --argjson c "$cand" '. + [$c]' <<<"$out")"
done < <(jq -c '.[]' <<<"$prs" 2>/dev/null || true)

# Longest-abandoned first: the draft that has been untouched longest goes first,
# so the most-stalled work (and the back-pressure slot it holds) clears soonest.
jq -c 'sort_by(.updated_at)' <<<"$out"
