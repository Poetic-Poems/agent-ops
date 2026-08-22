#!/usr/bin/env bash
#
# scripts/find-similar-tech-debt.sh <title>
#
# Prints the id and title of any open or in-progress tech-debt/*.md record
# whose own title is a close match for <title> — normalized (lower-cased,
# punctuation folded to spaces, runs of whitespace collapsed) and compared
# for equality or containment either way — so a stage about to reserve a new
# id can check first whether the gap it noticed is already tracked ("Filing
# alongside other work", TECH-DEBT.md). Exits 1 if any match was printed, 0
# if the title is clear to file. Reads the working tree, not any particular
# ref — run it against a checkout of the branch you intend to file on
# (ordinarily default_branch, freshly fetched).
#
# Deliberately a substring/normalized-equality check, not a fuzzy or semantic
# one: a real duplicate phrased quite differently is a false negative this
# script will not catch, the same gap grepping the register by hand already
# has today. A short, generic title matching an unrelated record's title is a
# false positive that costs nothing — a hit is a prompt to go read the
# candidate before reserving, never an automatic refusal — but the
# containment check is gated symmetrically: it only ever runs between a
# needle and a candidate title that are *both* at least eight normalized
# characters, equality-only below that floor on either side. Gating on the
# needle alone would still let a short existing title ("fix bug") match by
# containment inside a long, unrelated query — the exact false positive the
# floor exists to rule out, just from the other direction.

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <title>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
title="$1"
[[ -n "$title" ]] || usage

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
dir="$repo_root/tech-debt"
[[ -d "$dir" ]] || exit 0

normalize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

needle="$(normalize "$title")"
[[ -n "$needle" ]] || usage

allow_contains=0
[[ ${#needle} -ge 8 ]] && allow_contains=1

found=0
shopt -s nullglob
for f in "$dir"/*.md; do
  status="$(sed -n 's/^status:[[:space:]]*//p' "$f" | head -n1 | tr -d '[:space:]')"
  [[ "$status" == "open" || "$status" == "in-progress" ]] || continue

  candidate_title="$(sed -n 's/^title:[[:space:]]*//p' "$f" | head -n1)"
  [[ -n "$candidate_title" ]] || continue
  hay="$(normalize "$candidate_title")"
  [[ -n "$hay" ]] || continue

  match=0
  [[ "$hay" == "$needle" ]] && match=1
  if [[ $match -eq 0 && $allow_contains -eq 1 && ${#hay} -ge 8 ]]; then
    [[ "$hay" == *"$needle"* || "$needle" == *"$hay"* ]] && match=1
  fi
  [[ $match -eq 1 ]] || continue

  id="$(sed -n 's/^id:[[:space:]]*//p' "$f" | head -n1 | tr -d '[:space:]')"
  printf '%s\t%s\n' "${id:-$(basename "$f" .md)}" "$candidate_title"
  found=1
done

[[ $found -eq 0 ]]
