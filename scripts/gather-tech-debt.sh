#!/usr/bin/env bash
#
# gather-tech-debt.sh — deterministically pre-fetch one repo's open
# `pw::type:tech-debt`-labelled issues for the Co-Ordinator's runtime input
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 3t).
#
# Usage: gather-tech-debt.sh <owner/repo>
#
# Prints a JSON array; each entry is one candidate tech-debt item, issue-shaped
# exactly like a scripts/gather-issues.sh candidate but tagged `tech-debt`:
#
#   {
#     "source": "tech-debt",
#     "ref": "42",                    // the bare issue number — the item ref
#     "number": 42,
#     "url": "https://github.com/…/issues/42",
#     "title": "…",
#     "labels": ["pw::type:tech-debt", "…"],
#     "author": "…",
#     "created_at": "…", "updated_at": "…",
#     "body": "…verbatim…",
#     "comments": [{"author": "…", "created_at": "…", "body": "…verbatim…"}]
#   }
#
# Sorted by issue number ascending — "the oldest item, the one that has
# waited longest, is kept first" (lib/coordinator-input.sh's own
# `keep_order_tech_debt`), the same "lowest-id-first" rule the register-backed
# gatherer this replaces always applied, restated over issue numbers instead
# of register ids.
#
# ## The store moved from the register to labelled issues (D15 as revised, #869)
#
# Debt used to live as one `tech-debt/<id>.md` file per record; this gatherer
# used to read the register tarball and pick out every `status: open` row.
# D15 as revised (issue #875) moves the store to GitHub Issues carrying the
# product-managed label `pw::type:tech-debt` — the D24 trust anchor: only a
# collaborator with triage can apply it, so an issue's membership of this band
# is trustable even though its body stays framed as untrusted data, exactly
# like an `issues` source entry. Selection is on the label alone; nothing here
# re-derives whether an issue "looks like" debt.
#
# This gatherer now shares its deterministic filter and its `Blocked-by:`
# live-check with scripts/gather-issues.sh, via lib/issue-prefetch.sh: an
# issue that is assigned, labelled `blocked`, or names a still-open
# `Blocked-by:` reference (requirement 34j) is dropped here on the same terms
# `issues` drops it, rather than by a second copy of that logic. A pull
# request never carries this label in practice, but is dropped anyway, the
# same defensive way `issues` drops one.
#
# **Transition note, accepted deliberately (issue #875):** between this
# landing and a repo's own register migration, that repo's unmigrated
# register items are invisible to this band — this gatherer never reads a
# register file, only the label. The migrations follow immediately in the
# dependency chain (#880 and the sibling issues in other repos), and debt is
# a low-urgency band, so a repo with no `pw::type:tech-debt` issues yet simply
# contributes `[]`, indistinguishable from a repo with no open debt at all.
#
# ## Why this source is pre-fetched at all (issue #310)
#
# The tech-debt band used to be the Co-Ordinator's own read: the prompt told it
# to unpack the register tarball itself and `grep -l '^status: open'` for the
# candidate set, then cross-reference each one against `blocked`/`void`/`claimed`
# by its own judgement. That contract failed exactly the way every other
# self-read source failed before it (issues, findings, review-feedback,
# merge-conflicts, abandoned-drafts, register-hygiene): between 2026-08-10 and
# 2026-08-12, with ~30 eligible open items sitting in the register, the
# Co-Ordinator returned `none-selected` with reasons like "remaining tech-debt
# candidates require per-item evaluation against blocked/void/claimed records"
# and "open tech-debt heavily voided or blocked" — neither true, and the second
# one factually contradicted by the register it was describing. A `none-selected`
# fingerprint then froze the fleet on that wrong answer for a full day. Handing
# the candidates over pre-fetched, exactly as every drifted source before it got,
# removes the judgement step that kept getting reasoned past — an item filtered
# out (or simply listed) before the model sees it cannot be misdescribed.
#
# Claimed/blocked/void exclusion is deliberately **not** done here: like
# `exclude_claimed_items` for every other pre-fetched array, that is applied by
# agent-cycle.sh once this repo's fresh `claimed`/`blocked`/`void` extracts are
# in hand, so there is one definition of each exclusion rather than one per
# gatherer.
#
# Degrades to `[]` (exit 0) on any failure, like gather-findings.sh — and like
# gather-issues.sh, whose own degraded result is
# `{"candidates":[],"excluded":null}`
# rather than a bare array: this output *is* the Co-Ordinator's input, so an empty
# array faithfully records what it saw, and a repo's `head_sha` (already in the
# no-op fingerprint) still busts the fingerprint when a real commit changes the
# candidate set out from under a transient failure. Failures are loud on stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"
# The deterministic filter and the Blocked-by live-check, shared with
# scripts/gather-issues.sh — see lib/issue-prefetch.sh.
# shellcheck source=lib/issue-prefetch.sh
. "$SCRIPT_DIR/lib/issue-prefetch.sh"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-tech-debt.sh <owner/repo>" >&2
  exit 64
fi

degrade() {
  echo "gather-tech-debt: $slug: $*" >&2
  printf '[]\n'
  exit 0
}

issues_raw="$(gh api "repos/$slug/issues?labels=pw::type:tech-debt&state=open&per_page=100")" \
  || degrade "issues list fetch failed"
jq -e 'type == "array"' <<<"$issues_raw" >/dev/null 2>&1 \
  || degrade "issues list payload is not an array"

# The deterministic filter — see lib/issue-prefetch.sh's own comment. A pull
# request never carries this label in practice, so `issue_deterministic_ok`'s
# PR check is defensive rather than load-bearing here.
candidates="$(jq -c "$ISSUE_DETERMINISTIC_FILTER_JQ"'
  [.[]
   | select(issue_deterministic_ok)
   | {number: .number,
      url: .html_url,
      title: .title,
      labels: ([.labels[]?.name] | sort),
      author: (.user.login // ""),
      created_at: .created_at,
      updated_at: .updated_at,
      body: (.body // "")}]
  | sort_by(.number)' <<<"$issues_raw" 2>/dev/null)" \
  || degrade "issues filter failed"

out='[]'
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  n="$(jq -r '.number' <<<"$candidate")"
  comments="$(gh api "repos/$slug/issues/$n/comments?per_page=100" \
      --jq '[.[] | {author: (.user.login // ""), created_at: .created_at, body: (.body // "")}]')" \
    || degrade "comments fetch failed for issue #$n"
  jq -e 'type == "array"' <<<"$comments" >/dev/null 2>&1 \
    || degrade "comments payload for issue #$n is not an array"

  # Requirement 34j, exactly as gather-issues.sh applies it: a `Blocked-by:`
  # reference still open anywhere in the thread holds this candidate back,
  # before the comparatively expensive comments payload above is put to any
  # other use.
  thread_text="$(jq -r '.body' <<<"$candidate")
$(jq -r '[.[].body] | join("\n")' <<<"$comments")"
  if [[ -n "$(issue_blocked_by_ref "$slug" "$thread_text")" ]]; then
    continue
  fi

  # $candidate and $comments arrive on stdin, bound positionally with `input
  # as $name` in the order printed (requirement 4g) — never in argv: a single
  # issue thread past MAX_ARG_STRLEN must not degrade this repo's whole
  # tech_debt array to `[]`.
  entry="$(jq -nc 'input as $candidate | input as $comments |
    {source: "tech-debt", ref: ($candidate.number | tostring)} + $candidate + {comments: $comments}' \
    <<<"$candidate"$'\n'"$comments")" || degrade "entry assembly failed for issue #$n"
  out="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$out"$'\n'"$entry")" \
    || degrade "array assembly failed at issue #$n"
done < <(jq -c '.[]' <<<"$candidates")

printf '%s\n' "$out"
