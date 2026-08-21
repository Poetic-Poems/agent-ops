#!/usr/bin/env bash
#
# gather-review-status.sh — whether a project-review recommendation's own ref
# is named by a merged pull request on the default branch (requirement 34i's
# project-review half).
#
# Given a repo slug, its default branch and one or more recommendation refs
# (`review-<date>-R-NN`), print a JSON object mapping each ref it could confirm
# a merged pull request against to `"merged"`:
#
#   {"review-2026-07-11-R-02": "merged"}
#
# Usage: gather-review-status.sh <owner/repo> <default-branch> <ref> [<ref>…]
#
# ## The same test requirement 16 already applies
#
# A `project-review` recommendation is already excluded from the Co-Ordinator's
# candidates once "a *merged* pull request references its ref"
# (`docs/IMPLEMENTATION-PIPELINE-SPEC.md`, requirement 16) — the review folder
# itself is a point-in-time record and is never edited to say a recommendation
# is done (requirement 25), so a merged PR naming the ref, put there by the
# Implementer that closed it out (the Implementer prompt's `source: project-review`
# section), is the only fact anywhere that can answer "is this one finished?".
# This reads that same fact, so a block can clear on it without paying for a
# Co-Ordinator to notice.
#
# ## Only the refs asked for, and only when they are blocked
#
# Like `gather-register-status.sh`, this answers one question about a handful
# of named items and the Script calls it only for the blocked items whose refs
# are project-review refs, which is nearly always none. A fleet with no blocked
# project-review items spends nothing here.
#
# ## Sampled, not exhaustive
#
# The search is the repo's 100 most-recently-closed pull requests, the same
# page size every gatherer uses. A recommendation closed by a PR that has since
# aged off that page answers nothing here — the safe direction, since the block
# then simply waits for the Enabler exactly as it always did.
#
# Never exits non-zero: it always prints a valid object. A gatherer that
# aborted the cycle would make a tidy-up a reliability risk.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
branch="${2:-}"
shift 2 2>/dev/null || true
if [[ -z "$slug" || -z "$branch" ]]; then
  echo "usage: gather-review-status.sh <owner/repo> <default-branch> <ref> [<ref>…]" >&2
  printf '{}'
  exit 0
fi
if (( $# == 0 )); then
  printf '{}'
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

closed="$(gh api "repos/$slug/pulls?state=closed&base=$branch&per_page=100" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  cat "$work/gh.err" >&2
  printf '{}'
  exit 0
fi

# One newline-joined haystack of every merged PR's title and body, searched
# per ref below with a literal (non-regex) match — a recommendation's ref is a
# fixed slug, never a pattern, and a literal match cannot be tripped up by any
# regex metacharacter a title or body happens to contain.
merged_text="$(jq -r '[ .[] | select(.merged_at != null)
                            | ((.title // "") + "\n" + (.body // "")) ]
                       | join("\n")' <<<"$closed" 2>/dev/null || true)"

out="{}"
for ref in "$@"; do
  [[ -n "$ref" ]] || continue
  if [[ -n "$merged_text" ]] && grep -Fq -- "$ref" <<<"$merged_text"; then
    out="$(jq -c --arg k "$ref" '. + {($k): "merged"}' <<<"$out" 2>/dev/null || printf '%s' "$out")"
  fi
done

printf '%s' "$out"
