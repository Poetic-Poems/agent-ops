#!/usr/bin/env bash
#
# gather-merge-conflicts.sh — pre-fetch a repo's pull requests that are otherwise
# ready for review or ready to merge but blocked by a conflict with their base
# (requirement 3g), plus Dependabot's own conflicted bumps (requirement 3s,
# issue #250).
#
# Given a repo slug, print a JSON array of merge-conflict candidates: open,
# *non-draft* PRs whose `mergeable` is definitively CONFLICTING, and which are
# either ours (this system raised them) or Dependabot's own. Each is
# finished-looking work that a human is (implicitly or explicitly) waiting to
# land, held up only by the base branch having advanced underneath it — a
# rebase-and-resolve away from mergeable again, or (for Dependabot's own PRs,
# which this system does not force-push) a bot-aware nudge-then-takeover away.
#
# Usage: gather-merge-conflicts.sh <owner/repo> <pr-label> <branch-prefix> [tech-debt-branch-prefix]
#
# Candidate shape (our own PRs):
#   {
#     "source": "merge-conflicts",
#     "ref": "pr-57-conflict-1a2b3c4d5e6f", // stable, scoped to THIS head; a
#                                             // Dependabot candidate superseded
#                                             // by a newer bump instead mints
#                                             // "pr-57-superseded-1a2b3c4d5e6f"
#                                             // (see the "superseded_by" note below)
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
#     "body": "…the PR's own description, verbatim…",
#     "bot": false
#   }
#
# A Dependabot candidate carries the same shape plus three fields
# (requirement 3s):
#   "bot": true,
#   "rebase_requested": false,   // has this system already asked Dependabot
#                                 // to rebase THIS head, and it is still
#                                 // conflicting? (a marker comment, scoped to
#                                 // the head SHA — see lib/dependabot-bump.sh)
#   "superseded_by": null        // another open Dependabot PR's number, when
#                                 // it bumps the same dependency to a newer
#                                 // version than this one — this PR is moot.
#                                 // When set, `ref` above mints the distinct
#                                 // "pr-<n>-superseded-<head-sha>" shape
#                                 // instead of "pr-<n>-conflict-<head-sha>",
#                                 // so requirement 34k can close this PR on
#                                 // the void without re-admitting an
#                                 // unrelated, merely-conflicted PR of ours
#                                 // that happens to share the conflict shape
#   "superseded_evidence": null  // present only when superseded_by is —
#                                 // pre-formatted, corroboration-safe evidence
#                                 // text a Co-Ordinator can copy verbatim into
#                                 // a `voided` entry (see the note below)
#
# ## Why the Script fetches this and not the Co-Ordinator
#
# Same three reasons as gather-review-feedback.sh (requirement 3c) and
# gather-abandoned-drafts.sh (requirement 3e), and — as there — the third is the
# one that matters:
#   1. Cost, as with gather-findings.sh (requirement 3a): mergeability is a field
#      on the PR list, not something worth a model turn to reason out.
#   2. The PR's own body is the brief the Implementer finishes against, and must
#      reach it verbatim, not summarised.
#   3. The candidate rule below has to exist in the fingerprint (requirement 3b)
#      regardless, and requirement 34a says a rule two components compute gets one
#      definition. This script is it — and, as with abandoned-drafts, this source
#      is the reason PR mergeability is fingerprinted at all (see the note on the
#      clock-like transition below).
#
# ## The candidate rule
#
# A PR is a candidate iff it is open, **not** a draft, and `mergeable` is
# exactly `CONFLICTING` (never the transient `UNKNOWN` — GitHub computes
# mergeability asynchronously, so a PR whose base just moved reads UNKNOWN for
# a beat; treating that as a conflict would send the Implementer to rebase a
# PR that may not even conflict), and either:
#   - **ours**: it carries <pr-label> and its head branch starts with
#     <branch-prefix> (or `td/`, the tech-debt claim branch) — i.e. this
#     system raised it. The Landing Gate reserves every other branch for
#     humans; force-pushing a rebase onto a human's branch because it had
#     drifted would be a memorable way to learn that. Or,
#   - **Dependabot's own**: its author is `app/dependabot`
#     (`$DEPENDABOT_LOGIN`, lib/dependabot-bump.sh). Dependabot's branches
#     carry neither <pr-label> nor <branch-prefix> — they are the bot's, not
#     ours — so this half of the rule is authorship-based, not label-based.
#     This system never force-pushes a Dependabot branch (see
#     scripts/nudge-dependabot-rebase.sh); a `bot` candidate's `branch`
#     stays the bot's own, informational only.
#
# ## Rebase-requested and supersession, for a `bot` candidate
#
# `rebase_requested` is read, never written, here: it is true iff a comment
# already on the PR carries `dependabot_rebase_marker` for *this exact* head
# SHA (12 hex chars) — the same scoping the `ref` below uses, so a rebase that
# actually moves the head (successful or not) retires the old marker's
# relevance and a fresh conflict at the same head still matches the marker
# already there instead of asking again. scripts/nudge-dependabot-rebase.sh is
# what posts that comment and only for a candidate this script reports
# `rebase_requested: false` for — one definition of the rule (requirement
# 34a), read by one script and acted on by the other.
#
# `superseded_by` compares this PR's Dependabot branch against every other
# open Dependabot PR in the same read (`dependabot_newer_open_pr`,
# lib/dependabot-bump.sh): same family (dependency + package manager, read off
# the branch name), strictly newer target version. When set, `superseded_evidence`
# is pre-formatted so a Co-Ordinator can paste it into a `voided` entry's
# `evidence` **verbatim** rather than composing its own citation: the guard
# that corroborates a void (lib/void-guard.sh) treats "PR #N" — bare, or as a
# `.../pull/N` URL, either one resolved live (issue #300) — as a claim that PR
# *implements* the item, and checks its body and branch for the item's own id
# — which the superseding PR will never carry (it is a different, independent
# bump). Citing this PR's *own* number is what the guard trusts on the id
# alone for a `pr-<n>-…` item cited in the entry's own repo, as a bare
# citation always is (its id is minted from that very PR), so the
# pre-formatted text below cites this PR's number for that reason and names
# the superseding PR only by its branch name — neither "PR #N" nor a
# `.../pull/N` URL, both of which the guard would fetch live and refuse, since
# a different, independent bump never carries this item's id — precise, not
# evasive: the claim being corroborated is "this PR (its own number) is
# superseded", not "that PR did this PR's work".
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
# A `bot` candidate's `rebase_requested` flip (false -> true, the cycle after
# scripts/nudge-dependabot-rebase.sh posts its comment) is exactly the same
# kind of transition: no commit lands, `updatedAt` barely moves, but the
# candidate becomes a *takeover* candidate the Co-Ordinator can select. Reading
# this array here, unconditionally, every cycle, is what makes both transitions
# visible to the no-op fingerprint.
#
# ## Why the ref is scoped to the head SHA
#
# `pr-<n>-conflict-<head-sha>`, not `pr-<n>-conflict`. An item recorded blocked
# (requirement 34) stays blocked until something clears it, so a bare
# `pr-<n>-conflict` that an Implementer once failed to resolve would still be
# blocked after fresh commits landed on the branch — and the new state, which
# might be trivially resolvable, would never be looked at again. Scoping the ref
# to the head SHA means each distinct conflicted state is its own item that no
# older block covers, while a resolution (which moves the head) naturally retires
# the ref, and a conflict re-detected at the *same* head keeps the same ref and
# stays correctly blocked. Same reasoning as abandoned-drafts' per-head refs and
# review-feedback's per-round refs: an unattended system expires items by
# irrelevance.
#
# The same head-sha scoping applies to the `pr-<n>-superseded-<head-sha>` shape
# a superseded Dependabot candidate mints instead: a fresh commit on that PR's
# branch (a rebase, say) mints a fresh ref just as it would for the conflict
# shape, so a stale void of an earlier head never suppresses a state nobody has
# looked at.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo with no
# conflicted PRs contributes `[]`; an API that will not answer contributes `[]`
# too (the source simply does not fire this cycle) — but note gather-source-state.sh
# must NOT be so relaxed about the same PRs, for the reason it documents.
#
# Environment: MERGE_CONFLICTS_GH overrides `gh` (tests stub it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
GH="${MERGE_CONFLICTS_GH:-gh}"

# shellcheck source=lib/dependabot-bump.sh
. "$SCRIPT_DIR/lib/dependabot-bump.sh"

slug="${1:-}"
pr_label="${2:-autonomous-agent}"
branch_prefix="${3:-agent/}"
tech_debt_branch_prefix="${4-td/}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-merge-conflicts.sh <owner/repo> [pr-label] [branch-prefix] [tech-debt-branch-prefix]" >&2
  exit 64
fi

# Say so, then carry on. Deliberately *not* `degrade` as scripts/gather-tech-debt.sh
# and scripts/gather-issues.sh define it: theirs prints that script's own empty
# result (`[]` and `{"candidates":[],"excluded":null}` respectively) and exits,
# which is
# right where the failure is the whole band's (a register listing that would not
# answer) and wrong here, where it is one candidate's — losing a pull request
# this gather could not assemble is a far smaller thing than losing every other
# conflicted pull request alongside it. What the two idioms share is the only
# part that matters: neither is silent. This is the band whose whole job is
# visibility, so a candidate that drops out of it leaves a trace, and jq's own
# message on stderr goes with it rather than into `2>/dev/null`.
warn() {
  echo "gather-merge-conflicts: $slug: $*" >&2
}

# The open, agent-raised PRs, fetched raw — the filter runs afterwards, so the
# truncation check below counts what GitHub returned rather than what the
# filter kept. `headRefOid`, not the `commits` collection, for requirement 3e's
# two reasons: the collection read costs `--limit`-slots × 100 nodes where the
# scalar measures 1 point (the Gotchas table's slots-not-rows entry, and the
# bulk of the 2026-08-12 budget exhaustion), and at the collection's 100-item
# cap `commits[-1]` was the hundredth commit rather than the head — the scalar
# is the head at any branch length. stderr is shown, not swallowed: a `gh` that
# rejects a field name otherwise degrades to an empty array indistinguishable
# from "no conflicts", and the source silently never fires — the `[]`-on-error
# trap in the Gotchas table that cost the sibling gatherers a debugging round.
ours_all="$("$GH" pr list -R "$slug" --state open --label "$pr_label" \
        --limit "$GITHUB_PR_LIST_LIMIT" \
        --json number,title,headRefName,headRefOid,baseRefName,isDraft,mergeable,updatedAt,url,body \
        || true)"
jq -e 'type == "array"' <<<"$ours_all" >/dev/null 2>&1 || ours_all='[]'

# A listing at the cap may be missing entries (lib/github-limit.sh). Here the
# loss is a conflicted PR that is simply not offered this cycle — the safe
# direction every exclusion in this source takes — so it is said out loud and
# the run continues.
if github_pr_list_truncated "$(jq 'length' <<<"$ours_all")"; then
  echo "gather-merge-conflicts: $slug: the pull-request listing came back at its ${GITHUB_PR_LIST_LIMIT}-item cap; a conflict beyond it is not offered this cycle" >&2
fi

# `mergeable` is selected against `== "CONFLICTING"` exactly (never UNKNOWN —
# see the header). Heads may be `agent/…` or — for tech-debt items, whose claim
# branch is the human protocol's own `<tech_debt_branch_prefix><ID>` — `td/…`
# — the label filter is the primary "ours" signal either way.
#
# Empty tech_debt_branch_prefix disables the tech-debt namespace: the `or`
# clause is dropped rather than built with an empty startswith(""), which
# would match every head.
td_clause=""
if [[ -n "$tech_debt_branch_prefix" ]]; then
  td_clause=" or (.headRefName | startswith(\"$tech_debt_branch_prefix\"))"
fi
ours="$(jq -c "[.[] | select(.isDraft | not)
                    | select(.mergeable == \"CONFLICTING\")
                    | select((.headRefName | startswith(\"$branch_prefix\"))$td_clause)]" \
        <<<"$ours_all" 2>/dev/null || echo '[]')"
jq -e 'type == "array"' <<<"$ours" >/dev/null 2>&1 || ours='[]'

# Dependabot's whole active-bump set for this repo, every mergeable state, read
# once: the CONFLICTING ones below become candidates, and the full set is what
# decides whether one of them has been superseded by a later bump of the same
# dependency (lib/dependabot-bump.sh's `dependabot_newer_open_pr`). `comments`
# is fetched here (and nowhere in the `ours` call above) purely to compute
# `rebase_requested` — our own PRs have no such field to read.
dependabot_open="$("$GH" pr list -R "$slug" --state open --author "$DEPENDABOT_LOGIN" \
        --limit "$GITHUB_PR_LIST_LIMIT" \
        --json number,title,headRefName,headRefOid,baseRefName,isDraft,mergeable,updatedAt,url,body,comments \
        || true)"
jq -e 'type == "array"' <<<"$dependabot_open" >/dev/null 2>&1 || dependabot_open='[]'

# Truncation here can hide more than a candidate: a newer bump beyond the cap
# is not counted as superseding, so a conflicted bump it would have excused is
# minted as the conflict shape instead. Still cost, not damage — the conflict
# shape's treatment (nudge, then take over) closes nothing, and a supersession
# void is corroborated live by lib/void-guard.sh before anything closes.
if github_pr_list_truncated "$(jq 'length' <<<"$dependabot_open")"; then
  echo "gather-merge-conflicts: $slug: the Dependabot listing came back at its ${GITHUB_PR_LIST_LIMIT}-item cap; a bump beyond it is neither offered nor counted as superseding this cycle" >&2
fi

bot_conflicts="$(jq -c '[.[] | select(.isDraft | not) | select(.mergeable == "CONFLICTING")]' \
                 <<<"$dependabot_open" 2>/dev/null || echo '[]')"

out='[]'

emit() {  # <pr-json> <bot: true|false>
  local pr="$1" bot="$2" number head_sha item cand docs
  local rebase_requested="false" superseded_by="" superseded_evidence=""
  number="$(jq -r '.number' <<<"$pr")"
  head_sha="$(jq -r '.headRefOid // ""' <<<"$pr")"
  [[ -n "$head_sha" ]] || return 0

  # The originating item, so the Implementer can find the tech-debt entry, issue,
  # or finding this PR came from. Best-effort: a ref in the branch name or body.
  # Absence is normal and must not disqualify the candidate — the PR body and its
  # diff are the brief, not the register entry.
  item="$(jq -r '(.headRefName + " " + (.body // ""))' <<<"$pr" \
          | grep -oiE '\b(TD[0-9]{8}|dependabot-alert-[0-9]+|code-scanning-alert-[0-9]+|review-[0-9]{4}-[0-9]{2}-[0-9]{2}-R-?[0-9]+)\b' \
          | head -n1 || true)"

  if [[ "$bot" == "true" ]]; then
    if jq -e --arg m "$(dependabot_rebase_marker "${head_sha:0:12}")" \
         '(.comments // []) | any((.body // "") | contains($m))' <<<"$pr" >/dev/null 2>&1; then
      rebase_requested="true"
    fi
    superseded_by="$(dependabot_newer_open_pr "$number" "$(jq -r '.headRefName' <<<"$pr")" "$dependabot_open")"
    if [[ -n "$superseded_by" ]]; then
      local sup_head family version sup_version
      sup_head="$(jq -r --arg n "$superseded_by" '.[] | select((.number|tostring) == $n) | .headRefName' <<<"$dependabot_open")"
      family="$(dependabot_bump_family "$(jq -r '.headRefName' <<<"$pr")")"
      version="$(dependabot_bump_version "$(jq -r '.headRefName' <<<"$pr")")"
      sup_version="$(dependabot_bump_version "$sup_head")"
      superseded_evidence="PR #${number}'s own branch (${family} at ${version}) is superseded: a newer open Dependabot pull request on branch ${sup_head} bumps ${family} to ${sup_version}. Both cannot land — the older bump (this PR) is redundant now that the newer one exists."
    fi
  fi

  local ref_kind="conflict"
  [[ -n "$superseded_by" ]] && ref_kind="superseded"

  # requirement 4g: $pr carries a whole pull-request body (TD-PPagop-26081401),
  # unbounded by anything in this system, so it travels to jq on stdin — a
  # here-string, not a pipe, for requirement 4c's reason: under pipefail a
  # producer's SIGPIPE must not become this call's status — rather than as
  # the --argjson it used to be. Only the values requirement 4g leaves as
  # configuration-bounded (the minted ref, the extracted item, a head sha,
  # two booleans, the supersession strings) still travel as --arg/--argjson.
  # Fails open, and loudly: a candidate this build cannot parse is skipped
  # rather than aborting the whole gather, and says which one on stderr.
  cand="$(jq -nc \
    --arg ref "pr-${number}-${ref_kind}-${head_sha:0:12}" \
    --arg item "$item" \
    --arg head_sha "$head_sha" \
    --argjson bot "$bot" \
    --argjson rebase_requested "$rebase_requested" \
    --arg superseded_by "$superseded_by" \
    --arg superseded_evidence "$superseded_evidence" \
    'input as $pr | {source: "merge-conflicts",
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
      body: ($pr.body // ""),
      bot: $bot}
      + (if $bot then {
           rebase_requested: $rebase_requested,
           superseded_by: (if $superseded_by == "" then null else ($superseded_by | tonumber) end),
           superseded_evidence: (if $superseded_evidence == "" then null else $superseded_evidence end)
         } else {} end)' <<<"$pr")" \
    || { warn "candidate assembly failed for pr #$number"; return 0; }

  # The per-candidate array append: $out itself was already delivered on
  # stdin (it grows with every candidate this run has emitted so far), but
  # the new $cand rode in as a second --argjson — also past MAX_ARG_STRLEN
  # once its body is large enough. Both now arrive as one stdin document,
  # bound positionally, on the same fail-open-and-say-so terms as the build
  # above: the accumulator keeps what it already had, minus this candidate.
  docs="$(printf '%s\n' "$out" "$cand")"
  out="$(jq -nc '
    input as $out | input as $c
    | $out + [$c]
  ' <<<"$docs" || { warn "array assembly failed at pr #$number"; printf '%s' "$out"; })"
}

while IFS= read -r pr; do
  [[ -n "$pr" ]] || continue
  emit "$pr" false
done < <(jq -c '.[]' <<<"$ours" 2>/dev/null || true)

while IFS= read -r pr; do
  [[ -n "$pr" ]] || continue
  emit "$pr" true
done < <(jq -c '.[]' <<<"$bot_conflicts" 2>/dev/null || true)

# Longest-waiting first: the PR that has been sitting conflicted longest (oldest
# `updated_at`) goes first, so the work a human has been blocked on longest clears
# soonest.
jq -c 'sort_by(.updated_at)' <<<"$out"
