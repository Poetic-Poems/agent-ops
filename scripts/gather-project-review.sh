#!/usr/bin/env bash
#
# gather-project-review.sh — deterministically pre-fetch the most recent
# weekly project review's recommendations, for the Refiner
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 3y; TD-PPagop-26081307).
#
# Usage: gather-project-review.sh <owner/repo> [default-branch]
#
# Prints a JSON array; each entry is one candidate recommendation:
#
#   {
#     "source": "project-review",
#     "ref": "review-2026-08-10-R-03",   // the recommendation's own stable ref
#     "id": "R-03",
#     "review_date": "2026-08-10",
#     "title": "…",
#     "url": "https://github.com/…/blob/main/reviews/project-review-2026-08-10/03-recommendations.md",
#     "body": "…the whole `## R-03 — …` section of 03-recommendations.md, verbatim…",
#     "improvement_prompt": "…the fenced prompt body from 04-improvement-prompts.md, verbatim…"
#   }
#
# Sorted by recommendation number ascending — the review's own priority order.
#
# ## Deliberately narrower than gather-tech-debt.sh
#
# This does not replace the Co-Ordinator's own live read of `reviews/…`
# (prompts/coordinator.md, "Project-review recommendations"): it does not
# dedup against a mirrored tech-debt entry or issue, does not check for an
# existing open/merged pull request, and does not apply the "Large/gated"
# exclusion — all of that stays the Co-Ordinator's live judgement at
# selection time. What this hands the Refiner is just enough to write a
# specification without a second fetch: the recommendation's own detail
# section and its ready-to-run improvement prompt.
#
# ## Only the most recent review folder
#
# `reviews/project-review-YYYY-MM-DD/` folders accumulate one per week; only
# the latest is ever live, so only it is read (same rule the Co-Ordinator's
# own live read already applies).
#
# Degrades to `[]` (exit 0) on any failure, like gather-tech-debt.sh:
# a repository with no `reviews/` folder at all, or whose latest folder is
# missing `03-recommendations.md`, contributes `[]` silently — a project
# without this pipeline stage yet is normal, not an error. A genuine API
# failure still prints `[]` but is loud on stderr.

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
  echo "usage: gather-project-review.sh <owner/repo> [default-branch]" >&2
  exit 64
fi

degrade() {
  echo "gather-project-review: $slug: $*" >&2
  printf '[]\n'
  exit 0
}

work="$(mktemp -d)" || degrade "could not create a scratch directory"
trap 'rm -rf "$work"' EXIT

# One directory listing answers "is there a review at all?" — a repo with
# none contributes [] silently, the same normal answer gather-tech-debt.sh
# gives for a missing register.
listing_json="$(gh api "repos/$slug/contents/reviews?ref=$default_branch" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  if [[ "$(jq -r '.status // ""' <<<"$listing_json" 2>/dev/null)" == "404" ]]; then
    printf '[]\n'
    exit 0
  fi
  cat "$work/gh.err" >&2
  printf '[]\n'
  exit 0
fi

folder="$(jq -r '[ .[] | select(.type == "dir")
                       | .name
                       | select(test("^project-review-[0-9]{4}-[0-9]{2}-[0-9]{2}$")) ]
                  | sort | last // ""' <<<"$listing_json" 2>/dev/null || true)"
if [[ -z "$folder" ]]; then
  printf '[]\n'
  exit 0
fi
review_date="${folder#project-review-}"

fetch_file() {  # fetch_file PATH -> decoded content on stdout, "" on 404
  local path="$1" content_json rc
  content_json="$(gh api "repos/$slug/contents/$path?ref=$default_branch" 2>"$work/gh.err")"
  rc=$?
  if (( rc != 0 )); then
    if [[ "$(jq -r '.status // ""' <<<"$content_json" 2>/dev/null)" != "404" ]]; then
      cat "$work/gh.err" >&2
    fi
    return 0
  fi
  jq -r '.content // ""' <<<"$content_json" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null || true
}

recommendations_md="$(fetch_file "reviews/$folder/03-recommendations.md")"
if [[ -z "$recommendations_md" ]]; then
  printf '[]\n'
  exit 0
fi
prompts_md="$(fetch_file "reviews/$folder/04-improvement-prompts.md")"

# Split 03-recommendations.md into one file per `## R-<NN> — …` section,
# named by the recommendation's own id (the header line's second
# whitespace-delimited field). Everything before the first such heading (the
# intro paragraph and the summary table) is discarded — it is not any one
# recommendation's own detail.
recs_dir="$work/recs"
mkdir -p "$recs_dir"
awk -v outdir="$recs_dir" '
  /^## R-[0-9]+([ \t]|$)/ {
    if (out) close(out)
    id = $2
    out = outdir "/" id ".md"
    print > out
    next
  }
  out { print > out }
' <<<"$recommendations_md"

# Split 04-improvement-prompts.md the same way, keyed by the same id (the
# fourth field of "## Prompt for R-<NN> — …").
prompts_dir="$work/prompts"
mkdir -p "$prompts_dir"
if [[ -n "$prompts_md" ]]; then
  awk -v outdir="$prompts_dir" '
    /^## Prompt for R-[0-9]+([ \t]|$)/ {
      if (out) close(out)
      id = $4
      out = outdir "/" id ".md"
      print > out
      next
    }
    out { print > out }
  ' <<<"$prompts_md"
fi

# fence_body FILE — the text between the first pair of ``` fence lines in
# FILE (the prompt's own fenced ```text block), regardless of the fence's
# language tag. Prints nothing if FILE does not exist or has no closed fence.
fence_body() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    /^```/ { if (infence) { infence = 0; next } else { infence = 1; next } }
    infence { print }
  ' "$f"
}

out='[]'
shopt -s nullglob
for f in "$recs_dir"/R-*.md; do
  id="$(basename "$f" .md)"
  ref="review-$review_date-$id"
  header_line="$(head -n1 "$f")"
  title="$(sed -E 's/^## R-[0-9]+ — //' <<<"$header_line")"
  body="$(cat "$f")"
  prompt_body="$(fence_body "$prompts_dir/$id.md")"
  entry="$(jq -nc --arg id "$id" --arg ref "$ref" --arg rd "$review_date" \
    --arg title "$title" \
    --arg url "https://github.com/$slug/blob/$default_branch/reviews/$folder/03-recommendations.md" \
    --arg body "$body" --arg prompt "$prompt_body" \
    '{source: "project-review", ref: $ref, id: $id, review_date: $rd, title: $title,
      url: $url, body: $body, improvement_prompt: $prompt}')" \
    || degrade "entry assembly failed for $id"
  # $entry and the accumulator both arrive on stdin, one document per line,
  # bound positionally with `input as $name` (requirement 4g) — never in
  # argv, the same reason gather-tech-debt.sh avoids it.
  out="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$out"$'\n'"$entry")" \
    || degrade "array assembly failed for $id"
done
shopt -u nullglob

out="$(jq -c 'sort_by(.id | ltrimstr("R-") | (tonumber? // 0))' <<<"$out" 2>/dev/null || printf '%s' "$out")"
printf '%s\n' "$out"
