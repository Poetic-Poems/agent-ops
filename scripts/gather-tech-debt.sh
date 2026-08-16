#!/usr/bin/env bash
#
# gather-tech-debt.sh — deterministically pre-fetch one repo's open tech-debt
# register items for the Co-Ordinator's runtime input
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 3t).
#
# Usage: gather-tech-debt.sh <owner/repo> [default-branch]
#
# Prints a JSON array; each entry is one candidate tech-debt item:
#
#   {
#     "source": "tech-debt",
#     "ref": "TD-PPagop-26080801",   // the item's own id — the item ref
#     "id": "TD-PPagop-26080801",
#     "title": "…",
#     "filed": "2026-08-08",
#     "url": "https://github.com/…/blob/main/tech-debt/TD-PPagop-26080801.md",
#     "body": "…the whole item file, frontmatter and all, verbatim…"
#   }
#
# Sorted by id ascending — "lowest tech-debt ID first" (prompts/coordinator.md's
# "Selection algorithm").
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
# ## Only `status: open` items are candidates
#
# `in-progress` is somebody's (possibly a stale) claim, `resolved` and
# `not-debt` are finished business — none of those are ever selectable, and the
# register keeps them (append-only) for its own audit trail. Only `open` items
# are printed.
#
# ## One tarball read, not one blob fetch per item
#
# Same shape as scripts/gather-register-hygiene.sh and for the same reason: a
# mature register can hold well over a hundred items, and reading each one's
# blob individually would be a `gh api` call per file for what is, most cycles,
# a handful of open rows. The tarball endpoint answers the whole register in one
# read.
#
# Degrades to `[]` (exit 0) on any failure, like gather-findings.sh — and like
# gather-issues.sh, whose own degraded result is
# `{"candidates":[],"excluded":null}`
# rather than a bare array: this output *is* the Co-Ordinator's input, so an empty
# array faithfully records what it saw, and a repo's `head_sha` (already in the
# no-op fingerprint) still busts the fingerprint when a real commit changes the
# register out from under a transient failure. Failures are loud on stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/../lib/github-limit.sh"

slug="${1:-}"
default_branch="${2:-main}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-tech-debt.sh <owner/repo> [default-branch]" >&2
  exit 64
fi

degrade() {
  echo "gather-tech-debt: $slug: $*" >&2
  printf '[]\n'
  exit 0
}

work="$(mktemp -d)" || degrade "could not create a scratch directory"
trap 'rm -rf "$work"' EXIT

# One listing read answers "is there a register at all?" — a repo with none
# contributes [] silently, the same normal answer gather-register-hygiene.sh
# gives for the same fact.
tree_json="$(gh api "repos/$slug/git/trees/$default_branch" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  if [[ "$(jq -r '.status // ""' <<<"$tree_json" 2>/dev/null)" == "404" ]]; then
    printf '[]\n'
    exit 0
  fi
  cat "$work/gh.err" >&2
  printf '[]\n'
  exit 0
fi

dir_sha="$(jq -r '[.tree[] | select(.path == "tech-debt" and .type == "tree") | .sha] | first // ""' \
  <<<"$tree_json" 2>/dev/null || true)"
if [[ -z "$dir_sha" ]]; then
  printf '[]\n'
  exit 0
fi

if ! gh api "repos/$slug/tarball/$default_branch" > "$work/register.tar.gz" 2>"$work/gh.err"; then
  cat "$work/gh.err" >&2
  printf '[]\n'
  exit 0
fi
if ! tar -xzf "$work/register.tar.gz" -C "$work" 2>/dev/null; then
  degrade "could not extract the tarball"
fi
root=""
for d in "$work"/*/; do
  [[ -d "$d" ]] && root="${d%/}" && break
done
if [[ -z "$root" || ! -d "$root/tech-debt" ]]; then
  degrade "tarball held no tech-debt/ directory"
fi

# item_frontmatter — read an item file on stdin, print its `id`, `title`,
# `status` and `filed`, one per line, empty when the file does not carry them.
# The same shape scripts/td-check.pl and scripts/gather-register-status.sh
# parse: a leading `---`, `key: value` lines with the key case-folded, a
# closing `---`.
item_frontmatter() {
  awk '
    NR == 1                { if ($0 !~ /^---[ \t\r]*$/) exit; next }
    /^---[ \t\r]*$/        { exit }
    /^[A-Za-z][A-Za-z-]*:/  {
      key = tolower(substr($0, 1, index($0, ":") - 1))
      val = substr($0, index($0, ":") + 1)
      gsub(/\t/, " ", val); sub(/^[ ]+/, "", val); sub(/[ \r]+$/, "", val)
      if      (key == "id")     id     = val
      else if (key == "title")  title  = val
      else if (key == "status") status = val
      else if (key == "filed")  filed  = val
    }
    END { printf "%s\n%s\n%s\n%s\n", id, title, status, filed }
  '
}

out='[]'
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  f="$root/tech-debt/$name"
  [[ -f "$f" ]] || continue
  { read -r f_id; read -r f_title; read -r f_status; read -r f_filed; } \
    < <(item_frontmatter < "$f")
  [[ "$f_status" == "open" ]] || continue
  [[ -n "$f_id" ]] || continue
  body="$(cat "$f")"
  entry="$(jq -nc --arg id "$f_id" --arg title "$f_title" --arg filed "$f_filed" \
    --arg url "https://github.com/$slug/blob/$default_branch/tech-debt/$name" --arg body "$body" \
    '{source: "tech-debt", ref: $id, id: $id, title: $title, filed: $filed, url: $url, body: $body}')" \
    || degrade "entry assembly failed for $name"
  # $entry and the accumulator both arrive on stdin, one document per line,
  # bound positionally with `input as $name` in the order printed (requirement
  # 4g) — never in argv: a single item file past MAX_ARG_STRLEN must not
  # degrade this repo's entire tech_debt array to `[]`.
  out="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$out"$'\n'"$entry")" \
    || degrade "array assembly failed at $name"
done < <(cd "$root/tech-debt" && find . -maxdepth 1 -name '*.md' -printf '%f\n' 2>/dev/null | sort)

out="$(jq -c 'sort_by(.id)' <<<"$out" 2>/dev/null || printf '%s' "$out")"
printf '%s\n' "$out"
