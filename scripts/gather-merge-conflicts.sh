#!/usr/bin/env bash
#
# gather-merge-conflicts.sh — pre-fetch a repo's pull requests that are otherwise
# ready for review or ready to merge but blocked by a conflict with their base
# (requirement 3g).
#
# Given a repo slug, print a JSON array of merge-conflict candidates: open,
# *non-draft* PRs this system raised whose `mergeable` is definitively
# CONFLICTING. Each is finished-looking work that a human is (implicitly or
# explicitly) waiting to land, held up only by the base branch having advanced
# underneath it — a rebase-and-resolve away from mergeable again.
#
# Usage: gather-merge-conflicts.sh <owner/repo> <pr-label> <branch-prefix>
#
# Candidate shape:
#   {
#     "source": "merge-conflicts",
#     "ref": "pr-57-conflict-1a2b3c4d5e6f", // stable, and scoped to THIS head
#     "number": 57,
#     "pr_number": 57,
#     "url": "https://github.com/…/pull/57",
#     "pr_url": "https://github.com/…/pull/57",
#     "title": "fix(cache): …",
#     "branch": "agent/td26072001-…",
#     "base": "main",                        // the branch it conflicts with
#     "item": "TD26072001",                  // the originating item, if inferable
#     "head_sha": "1a2b3c4d5e6f…",
#     "updated_at": "2026-07-24T03:00:00Z",
#     "body": "…the PR's own description, verbatim…"
#   }
#
# ## Why the Script fetches this and not the Co-Ordinator
#
# Same three reasons as gather-review-feedback.sh (requirement 3c) and
# gather-abandoned-drafts.sh (requirement 3e), and — as there — the third is the
# one that matters:
#   1. Cost, as with gather-findings.sh (requirement 3a): mergeability is a field
#      on the PR list, not something worth a model turn to reason out.
#   2. The PR's own body is the brief the Implementor finishes against, and must
#      reach it verbatim, not summarised.
#   3. The candidate rule below has to exist in the fingerprint (requirement 3b)
#      regardless, and requirement 34a says a rule two components compute gets one
#      definition. This script is it — and, as with abandoned-drafts, this source
#      is the reason PR mergeability is fingerprinted at all (see the note on the
#      clock-like transition below).
#
# ## The candidate rule
#
# A PR is a candidate iff all of:
#   - it is open and **not** a draft. A draft is the Implementor's own claim
#     marker (requirement 23); a draft's conflict is finished by abandoned-drafts
#     (which resolves the conflict as part of finishing the draft) if the draft
#     has gone stale, never here. This source is only for PRs that are otherwise
#     *ready* — for review or for merge — where the sole blocker is the conflict.
#   - it carries <pr-label> and its head branch starts with <branch-prefix> (or
#     `td/`, the tech-debt claim branch) — i.e. this system raised it. The Human
#     Gate reserves every other branch for humans; force-pushing a rebase onto a
#     human's PR because it had drifted would be a memorable way to learn that.
#   - its `mergeable` is exactly `CONFLICTING`. Not `UNKNOWN` — GitHub computes
#     mergeability asynchronously, so a PR whose base has just moved reports
#     UNKNOWN for a beat before it resolves to CONFLICTING or MERGEABLE. Treating
#     UNKNOWN as a conflict would send the Implementor to rebase a PR that may not
#     even conflict; treating it as a candidate at all is guessing. So UNKNOWN is
#     skipped and the PR is reconsidered next cycle, by which point GitHub has
#     settled the answer — and because the candidate array is fingerprinted
#     (below), the flip to CONFLICTING busts the fingerprint and wakes the cycle
#     even if nothing else moved.
#
# ## Why mergeability must be sampled here, and fed to the fingerprint verbatim
#
# A PR turns CONFLICTING when its base advances — someone merged another PR to
# `main` — but that is not an event on *this* PR: no commit lands on its head, its
# `updatedAt` does not move, and gather-source-state.sh's open-PR digest (which
# keys on number, updated_at, head ref and draft flag) sits unchanged. Worse, the
# base advance and the conflict appearing are two separate moments: the cycle the
# base moved, the repo head SHA changed and the fingerprint busted, but GitHub had
# not yet recomputed mergeability (UNKNOWN), so nothing was gathered; a later cycle
# the mergeability resolves to CONFLICTING with the repo head SHA unchanged since —
# so without this array the fingerprint would match the earlier none-selected and
# the pipeline would skip the very cycle the work becomes visible, until the forced
# recheck. Computing candidacy here and feeding the resulting array into the
# fingerprint verbatim (as agent-cycle.sh does for review_feedback and
# abandoned_drafts) is what makes the transition visible: the array gains an entry
# the cycle mergeability resolves to CONFLICTING, and that busts the fingerprint.
# Same shape as abandoned-drafts' clock-based candidacy. See lib/noop-skip.sh.
#
# ## Why the ref is scoped to the head SHA
#
# `pr-<n>-conflict-<head-sha>`, not `pr-<n>-conflict`. An item recorded blocked
# (requirement 34) stays blocked until something clears it, so a bare
# `pr-<n>-conflict` that an Implementor once failed to resolve would still be
# blocked after fresh commits landed on the branch — and the new state, which
# might be trivially resolvable, would never be looked at again. Scoping the ref
# to the head SHA means each distinct conflicted state is its own item that no
# older block covers, while a resolution (which moves the head) naturally retires
# the ref, and a conflict re-detected at the *same* head keeps the same ref and
# stays correctly blocked. Same reasoning as abandoned-drafts' per-head refs and
# review-feedback's per-round refs: an unattended system expires items by
# irrelevance.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo with no
# conflicted PRs contributes `[]`; an API that will not answer contributes `[]`
# too (the source simply does not fire this cycle) — but note gather-source-state.sh
# must NOT be so relaxed about the same PRs, for the reason it documents.

set -uo pipefail

slug="${1:-}"
pr_label="${2:-autonomous-agent}"
branch_prefix="${3:-agent/}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-merge-conflicts.sh <owner/repo> [pr-label] [branch-prefix]" >&2
  exit 64
fi

# The open, agent-raised, non-draft, definitively-conflicting PRs, with their
# commits so the head SHA arrives in the same call. stderr is shown, not
# swallowed: a `gh` that rejects a field name otherwise degrades to an empty
# array indistinguishable from "no conflicts", and the source silently never
# fires — the `[]`-on-error trap in the Gotchas table that cost the sibling
# gatherers a debugging round. `mergeable` is selected against `== "CONFLICTING"`
# exactly (never UNKNOWN — see the header). Heads may be `agent/…` or — for
# tech-debt items, whose claim branch is the human protocol's own `td/<ID>` —
# `td/…`; the label filter is the primary "ours" signal either way.
prs="$(gh pr list -R "$slug" --state open --label "$pr_label" \
        --json number,title,headRefName,baseRefName,commits,isDraft,mergeable,updatedAt,url,body \
        --jq "[.[] | select(.isDraft | not)
                   | select(.mergeable == \"CONFLICTING\")
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
    --arg ref "pr-${number}-conflict-${head_sha:0:12}" \
    --arg item "$item" \
    --arg head_sha "$head_sha" \
    '{source: "merge-conflicts",
      ref: $ref,
      number: $pr.number,
      pr_number: $pr.number,
      url: $pr.url,
      pr_url: $pr.url,
      title: $pr.title,
      branch: $pr.headRefName,
      base: $pr.baseRefName,
      item: (if $item == "" then null else $item end),
      head_sha: $head_sha,
      updated_at: $pr.updatedAt,
      body: ($pr.body // "")}')"
  out="$(jq -c --argjson c "$cand" '. + [$c]' <<<"$out")"
done < <(jq -c '.[]' <<<"$prs" 2>/dev/null || true)

# Longest-waiting first: the PR that has been sitting conflicted longest (oldest
# `updated_at`) goes first, so the work a human has been blocked on longest clears
# soonest.
jq -c 'sort_by(.updated_at)' <<<"$out"
