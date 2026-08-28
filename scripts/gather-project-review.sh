#!/usr/bin/env bash
#
# gather-project-review.sh — deterministically pre-fetch the most recent
# repository review's recommendations, for the Refiner
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 3y; TD-PPagop-26081307).
#
# Usage: gather-project-review.sh <owner/repo> [default-branch] [report-directory-format]
#
# report-directory-format is the repository's own resolved
# project_review.repos[].report_directory (or project_review.defaults', or
# the pipeline's ultimate fallback) — a GNU date(1) format string, exactly as
# review-cycle.sh resolves and passes it. Defaults to
# `reviews/project-review-%Y-%m-%d` — today's layout — so an existing caller
# passing only the first two arguments is unaffected (issue #761).
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
# Report directories accumulate one per week; only the latest is ever live,
# so only it is read (same rule the Co-Ordinator's own live read already
# applies).
#
# Degrades to `[]` (exit 0) on any failure, like gather-tech-debt.sh:
# a repository with no report directory at all, or whose latest one is
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
# report_directory_most_recent, for the configurable report_directory
# (issue #761) — see the file header for what discovery this replaced.
# shellcheck source=lib/report-directory.sh
. "$SCRIPT_DIR/../lib/report-directory.sh"

slug="${1:-}"
default_branch="${2:-main}"
report_directory_format="${3:-reviews/project-review-%Y-%m-%d}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-project-review.sh <owner/repo> [default-branch] [report-directory-format]" >&2
  exit 64
fi

degrade() {
  echo "gather-project-review: $slug: $*" >&2
  printf '[]\n'
  exit 0
}

work="$(mktemp -d)" || degrade "could not create a scratch directory"
trap 'rm -rf "$work"' EXIT

# The same static-prefix fold report_directory_find_dirs applies internally
# (every leading path segment free of a `%` specifier, joined into one) —
# duplicated here, rather than left entirely to the library, so this one
# directory listing can answer "is there a report directory at all?" with the
# loud-on-real-failure/silent-on-404 distinction the rest of this script
# already gave every other listing: a repo with none contributes [] silently,
# the same normal answer gather-tech-debt.sh gives for a missing register,
# while a genuine API failure still surfaces on stderr. The library's own walk
# (below) repeats this one call — a second point of network cost this script
# accepts in exchange for one shared discovery implementation with
# review-cycle.sh, rather than two that could drift apart.
IFS='/' read -r -a _rd_segments <<<"$report_directory_format"
_rd_prefix=""
_rd_i=0
while (( _rd_i < ${#_rd_segments[@]} - 1 )) && [[ "${_rd_segments[$_rd_i]}" != *%* ]]; do
  if [[ -z "$_rd_prefix" ]]; then _rd_prefix="${_rd_segments[$_rd_i]}"; else _rd_prefix+="/${_rd_segments[$_rd_i]}"; fi
  _rd_i=$(( _rd_i + 1 ))
done
if [[ -z "$_rd_prefix" ]]; then
  listing_json="$(gh api "repos/$slug/contents?ref=$default_branch" 2>"$work/gh.err")"
else
  listing_json="$(gh api "repos/$slug/contents/$_rd_prefix?ref=$default_branch" 2>"$work/gh.err")"
fi
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

review_date_and_dir="$(report_directory_most_recent "$slug" "$default_branch" "$report_directory_format" 2>/dev/null)"
if [[ -z "$review_date_and_dir" ]]; then
  printf '[]\n'
  exit 0
fi
review_date="$(cut -f1 <<<"$review_date_and_dir")"
report_dir="$(cut -f2 <<<"$review_date_and_dir")"

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

recommendations_md="$(fetch_file "$report_dir/03-recommendations.md")"
if [[ -z "$recommendations_md" ]]; then
  printf '[]\n'
  exit 0
fi
prompts_md="$(fetch_file "$report_dir/04-improvement-prompts.md")"

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

# fence_body FILE — the text between the *first* and the *last* ``` fence line
# in FILE (the prompt's own fenced ```text block), regardless of the fence's
# language tag. Prints nothing if FILE does not exist or holds fewer than two
# fence lines.
#
# First-to-last rather than first-pair, because an improvement prompt may
# legitimately contain a fenced block of its own — the project-review skill's
# own prompt-writing guidance presents its mandatory cost-policy block as a
# ```text fence, so a prompt that quotes a patch, a command transcript or that
# block has four fence lines in its section, not two. Closing at the first
# fence after the opening one would silently truncate such a prompt at its
# nested block, and the Refiner would write a specification from the half it
# was left with, with nothing to signal the loss. Treating the interior fence
# lines as content instead keeps the prompt whole and preserves the fences the
# author wrote; for the two-fence section the template produces, the two rules
# are identical, and for any section whose fences balance this one strictly
# adds. A section with an odd fence count is malformed either way — it renders
# wrongly on GitHub too — and this rule answers it by keeping the prompt's own
# opening and dropping whatever trails the last fence.
fence_body() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    /^```/ { if (!first) first = NR; last = NR }
    { line[NR] = $0 }
    END {
      if (!first || last <= first) exit 0
      for (i = first + 1; i < last; i++) print line[i]
    }
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
    --arg url "https://github.com/$slug/blob/$default_branch/$report_dir/03-recommendations.md" \
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
