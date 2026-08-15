#!/usr/bin/env bash
#
# mine-merge-history.sh — repeatable merged-PR history miner and Stage 0
# autonomy baseline (issue #404, WI-1 of D18's rollout umbrella #402).
#
# Usage:
#   scripts/mine-merge-history.sh [--config FILE] [--repo OWNER/REPO ...]
#                                  [--label LABEL] [--out-dir DIR]
#
# With no flags, reads the repo list from config.json's `repos[].slug` and the
# pull-request label from config.json's `pr_label` (both next to this script),
# and writes a dated Markdown baseline to docs/reviews/. One or more --repo
# overrides the config-file repo list entirely (each still filtered by
# --label, default "autonomous-agent"); --config points at a different
# config file; --out-dir changes where the baseline is written.
#
# For each repo, over every merged pull request carrying the label, this
# reports: the count; every formal human review, tallied by
# (reviewer account, state); open→merge and ready→merge latency
# (median and p90, in hours); and post-merge outcome — whether a revert or
# follow-up fix landed within 48 h (see "Post-merge outcome" below for
# exactly what that checks and what it does not).
#
# Design: docs/reviews/2026-08-14-autonomy-investigation.md §3 (the first
# cut this formalises) and §6 (Stage 0, which this baseline satisfies).
#
# ## REST over search, and the shared rate pool
#
# The 2026-08-14 first cut used the search API (`search/issues`) to find
# labelled merged PRs. This miner uses REST instead: `GET
# /repos/{slug}/issues?labels=...&state=closed` returns exactly the same
# candidates (a PR is an issue with a `pull_request` object; merged ones carry
# `pull_request.merged_at`), and REST's cost is a flat 1 point per page
# against `gh`'s `core` budget, versus search's own separate (tighter) budget
# — for a script meant to be re-run repeatedly, sharing the larger, better-
# understood pool the rest of this codebase already meters is the safer
# default. `lib/github-limit.sh`'s `gh` wrapper (sourced below) waits out a
# transient refusal on every call this script makes, the same as every other
# script in this repository that reads GitHub.
#
# Every per-page `--jq` filter is a bare `.[] | ...` (never `[.[] | ...]`), and
# every multi-page read is slurped with `jq -s -c '.'` afterwards — the
# streaming discipline scripts/gather-review-feedback.sh's own header
# explains: `--paginate` re-runs a `[...]`-wrapping filter once per page and
# prints one array per page, which silently keeps only the last page's worth
# once naively parsed as one document.
#
# ## Post-merge outcome
#
# "References the PR" is read from GitHub's own `cross-referenced` timeline
# events on the merged PR's issue — populated whenever another issue or pull
# request mentions it by number in a body or comment, including GitHub's own
# "Revert" button flow, which auto-inserts a `Reverts owner/repo#N` line. A
# cross-referencing pull request merged within 48 h of the original is
# classified `revert` if its title starts with "revert" (case-insensitive),
# else `follow-up-fix`.
#
# "Touching the same files" is checked too, but only against *other PRs
# carrying the same label in the same repo* merged in the same 48 h window —
# not against every merged PR in the repository. Detecting file overlap
# against the whole merge history would need a changed-files listing for
# every PR ever merged, not just the labelled ones this script already reads
# one of per candidate; that is a materially larger read for a check this
# script already reports adequately via label scope (this pipeline is, by
# construction, the fleet's own follow-up author — see the investigation
# report §3, "The two interventions are instructive"). A same-file follow-up
# authored outside the label, and never referencing the original PR either, is
# therefore not detected by this pass; the per-repo "Scope" note in the
# generated baseline says so again next to the numbers it qualifies.
#
# ## Output and idempotency
#
# One Markdown file per run, at `<out-dir>/<UTC-date>-merge-autonomy-
# baseline.md`, `<out-dir>` defaulting to docs/reviews/. Re-running the same
# day overwrites that same file rather than accumulating a new one; re-running
# against unchanged GitHub state reproduces the same content byte-for-byte
# (nothing here reads the wall clock beyond the date in the filename and
# title). A machine-readable copy of every number in the tables — the same
# figures, not a summary of them — is embedded as a fenced JSON block at the
# end of the file, for whatever later stage's exit criteria wants to diff two
# runs without re-deriving the tables.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

CONFIG_FILE="$SCRIPT_DIR/config.json"
OUT_DIR="$SCRIPT_DIR/docs/reviews"
LABEL=""
declare -a REPOS=()

usage() {
  echo "usage: mine-merge-history.sh [--config FILE] [--repo OWNER/REPO ...] [--label LABEL] [--out-dir DIR]" >&2
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --repo) REPOS+=("$2"); shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [[ ${#REPOS[@]} -eq 0 ]]; then
  [[ -f "$CONFIG_FILE" ]] || { echo "mine-merge-history: config file not found: $CONFIG_FILE" >&2; exit 1; }
  mapfile -t REPOS < <(jq -r '.repos[].slug' "$CONFIG_FILE")
  [[ ${#REPOS[@]} -gt 0 ]] || { echo "mine-merge-history: $CONFIG_FILE names no repos" >&2; exit 1; }
  if [[ -z "$LABEL" ]]; then
    LABEL="$(jq -r '.pr_label // "autonomous-agent"' "$CONFIG_FILE")"
  fi
fi
[[ -n "$LABEL" ]] || LABEL="autonomous-agent"

mkdir -p "$OUT_DIR"

# --- One repo's every merged, labelled pull request, enriched -------------
#
# Prints one JSON array (never [] on total failure — an unreadable repo
# aborts the whole run loudly, since a silently-missing repo would corrupt a
# baseline meant to be compared against later) of:
#   {number, title, created_at, merged_at, ready_at (nullable),
#    reviews: [{user, state}, ...],
#    xrefs: [{number, title, merged_at}, ...],   // referencing PRs, merged
#    files: ["path", ...]}
mine_repo() {
  local slug="$1" label="$2"
  local listing prs
  listing="$(gh api --paginate \
    "repos/$slug/issues?labels=$label&state=closed&per_page=100" \
    --jq '.[] | select(.pull_request != null) | select(.pull_request.merged_at != null)
              | {number, title, created_at, merged_at: .pull_request.merged_at}')" \
    || { echo "mine-merge-history: $slug: merged-PR listing failed" >&2; return 1; }
  prs="$(jq -s -c 'sort_by(.merged_at)' <<<"$listing")" \
    || { echo "mine-merge-history: $slug: merged-PR listing did not parse" >&2; return 1; }

  local out='[]' pr n reviews timeline files ready_at xrefs entry
  while IFS= read -r pr; do
    [[ -n "$pr" ]] || continue
    n="$(jq -r '.number' <<<"$pr")"

    reviews="$(gh api --paginate "repos/$slug/pulls/$n/reviews?per_page=100" \
      --jq '.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "COMMENTED")
                | {user: (.user.login // "unknown"), state}')" \
      || { echo "mine-merge-history: $slug#$n: reviews fetch failed" >&2; return 1; }
    reviews="$(jq -s -c '.' <<<"$reviews")" || reviews='[]'

    timeline="$(gh api --paginate "repos/$slug/issues/$n/timeline?per_page=100" \
      --jq '.[] | {event, created_at,
                    xref_number: (.source.issue.number // null),
                    xref_title: (.source.issue.title // null),
                    xref_is_pr: (.source.issue.pull_request != null),
                    xref_merged_at: (.source.issue.pull_request.merged_at // null)}')" \
      || { echo "mine-merge-history: $slug#$n: timeline fetch failed" >&2; return 1; }
    timeline="$(jq -s -c '.' <<<"$timeline")" || timeline='[]'

    # `--jq` runs jq in raw-output mode, so a bare-string filter (`.filename`)
    # prints unquoted text that is not valid JSON to slurp back — unlike every
    # other read here, this one stays array-per-page (`[.[]...]`) and is
    # flattened the same way the top-level PR listing is, just below.
    files="$(gh api --paginate "repos/$slug/pulls/$n/files?per_page=100" \
      --jq '[.[].filename]')" \
      || { echo "mine-merge-history: $slug#$n: files fetch failed" >&2; return 1; }
    files="$(jq -s -c '[.[][]] | unique' <<<"$files")" || files='[]'

    ready_at="$(jq -r '[.[] | select(.event == "ready_for_review") | .created_at] | sort | first // empty' <<<"$timeline")"
    xrefs="$(jq -c '[.[] | select(.event == "cross-referenced" and .xref_is_pr and .xref_merged_at != null)
                          | {number: .xref_number, title: .xref_title, merged_at: .xref_merged_at}]' <<<"$timeline")"

    entry="$(jq -nc --argjson pr "$pr" --argjson reviews "$reviews" \
                 --argjson xrefs "$xrefs" --argjson files "$files" \
                 --arg ready_at "$ready_at" \
      '$pr + {ready_at: (if $ready_at == "" then null else $ready_at end),
              reviews: $reviews, xrefs: $xrefs, files: $files}')" \
      || { echo "mine-merge-history: $slug#$n: entry assembly failed" >&2; return 1; }
    # Accumulator arrives on stdin, never argv — the same MAX_ARG_STRLEN
    # discipline every other gatherer here follows (TD-PPagop-26081401/4g):
    # a repo's whole merged-agent-PR history, files lists included, is
    # unbounded past a single command line.
    out="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$out"$'\n'"$entry")" \
      || { echo "mine-merge-history: $slug#$n: array assembly failed" >&2; return 1; }
  done < <(jq -c '.[]' <<<"$prs")

  printf '%s' "$out"
}

# --- Per-repo aggregation, in jq ---------------------------------------------
#
# Takes one repo's enriched PR array on stdin, prints its stats object.
# Nearest-rank median/p90 (no interpolation) — adequate for a rounded
# baseline and simpler to reproduce by hand than an interpolated figure.
# shellcheck disable=SC2016  # jq's own $prs/$count/etc, not the shell's.
AGGREGATE_JQ='
def rank_pick(p):
  sort as $s
  | ($s | length) as $n
  | if $n == 0 then null
    else $s[ ( ( ($n - 1) * p ) | round ) ]
    end;

. as $prs
| ($prs | length) as $count
| ($prs | map(.reviews[]) | group_by([.user, .state])
   | map({user: .[0].user, state: .[0].state, n: length})) as $review_tally
| ($prs | map(((.merged_at | fromdate) - ((.created_at) | fromdate)) / 3600)) as $open_latencies
| ($prs | map(((.merged_at | fromdate) - ((.ready_at // .created_at) | fromdate)) / 3600)) as $ready_latencies
| ($prs | map(
    . as $pr
    | ($pr.merged_at | fromdate) as $m
    | ($m + 172800) as $end   # 48h in seconds — the post-merge outcome window
    | ([$pr.xrefs[] | select((.merged_at | fromdate) > $m and (.merged_at | fromdate) <= $end)]
       | sort_by(.merged_at) | first) as $xref_hit
    | ([$prs[] | select(.number != $pr.number)
               | select((.merged_at | fromdate) > $m and (.merged_at | fromdate) <= $end)
               | select((($pr.files // []) - (($pr.files // []) - (.files // []))) | length > 0)]
       | sort_by(.merged_at) | first) as $file_hit
    | if $xref_hit != null then
        {number: $pr.number,
         kind: (if ($xref_hit.title // "" | ascii_downcase | startswith("revert")) then "revert" else "follow-up-fix" end),
         reason: "reference", by: $xref_hit.number, by_title: $xref_hit.title,
         hours_after: (((($xref_hit.merged_at | fromdate) - $m) / 3600) | (. * 10 | round) / 10)}
      elif $file_hit != null then
        {number: $pr.number, kind: "follow-up-fix", reason: "file-overlap",
         by: $file_hit.number, by_title: $file_hit.title,
         hours_after: (((($file_hit.merged_at | fromdate) - $m) / 3600) | (. * 10 | round) / 10)}
      else null end
  ) | map(select(. != null))) as $outcomes
| {count: $count,
   review_tally: $review_tally,
   open_to_merge_hours: {median: ($open_latencies | rank_pick(0.5)), p90: ($open_latencies | rank_pick(0.9))},
   ready_to_merge_hours: {median: ($ready_latencies | rank_pick(0.5)), p90: ($ready_latencies | rank_pick(0.9))},
   post_merge: {
     reverts: ($outcomes | map(select(.kind == "revert")) | length),
     follow_up_fixes: ($outcomes | map(select(.kind == "follow-up-fix")) | length),
     clean: ($count - ($outcomes | length)),
     detail: $outcomes
   }}
'

render_repo_section() {
  local slug="$1" stats="$2"
  local count reverts followups clean
  count="$(jq -r '.count' <<<"$stats")"
  reverts="$(jq -r '.post_merge.reverts' <<<"$stats")"
  followups="$(jq -r '.post_merge.follow_up_fixes' <<<"$stats")"
  clean="$(jq -r '.post_merge.clean' <<<"$stats")"

  printf '### %s\n\n' "$slug"
  printf '%s merged, %s-labelled pull requests. Open→merge %sh median / %sh p90; ready→merge %sh median / %sh p90.\n\n' \
    "$count" "$LABEL" \
    "$(jq -r '.open_to_merge_hours.median // "n/a"' <<<"$stats")" \
    "$(jq -r '.open_to_merge_hours.p90 // "n/a"' <<<"$stats")" \
    "$(jq -r '.ready_to_merge_hours.median // "n/a"' <<<"$stats")" \
    "$(jq -r '.ready_to_merge_hours.p90 // "n/a"' <<<"$stats")"

  printf '| Reviewer | APPROVED | CHANGES_REQUESTED | COMMENTED |\n|---|---|---|---|\n'
  local reviewers
  reviewers="$(jq -r '[.review_tally[].user] | unique | .[]' <<<"$stats")"
  if [[ -z "$reviewers" ]]; then
    printf '| _none_ | 0 | 0 | 0 |\n'
  else
    while IFS= read -r reviewer; do
      [[ -n "$reviewer" ]] || continue
      printf '| %s | %s | %s | %s |\n' "$reviewer" \
        "$(jq -r --arg u "$reviewer" '[.review_tally[] | select(.user == $u and .state == "APPROVED") | .n] | add // 0' <<<"$stats")" \
        "$(jq -r --arg u "$reviewer" '[.review_tally[] | select(.user == $u and .state == "CHANGES_REQUESTED") | .n] | add // 0' <<<"$stats")" \
        "$(jq -r --arg u "$reviewer" '[.review_tally[] | select(.user == $u and .state == "COMMENTED") | .n] | add // 0' <<<"$stats")"
    done <<<"$reviewers"
  fi
  printf '\n'

  printf 'Post-merge outcome within 48 h: **%s** revert(s), **%s** follow-up fix(es), **%s** clean (no follow-up detected).\n\n' \
    "$reverts" "$followups" "$clean"
  local detail_count
  detail_count="$(jq -r '.post_merge.detail | length' <<<"$stats")"
  if [[ "$detail_count" != "0" ]]; then
    jq -r --arg slug "$slug" '.post_merge.detail[]
      | "- \($slug)#\(.number) \(if .kind == "revert" then "reverted" else "followed up" end) by \($slug)#\(.by) (\"\(.by_title)\", \(.reason), \(.hours_after)h later)"' \
      <<<"$stats"
    printf '\n'
  fi
}

date_str="$(date -u +%F)"
out_file="$OUT_DIR/${date_str}-merge-autonomy-baseline.md"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

declare -A REPO_STATS=()
rc=0
for slug in "${REPOS[@]}"; do
  echo "mine-merge-history: mining $slug ..." >&2
  enriched="$(mine_repo "$slug" "$LABEL")" || { rc=1; continue; }
  jq -e 'type == "array"' <<<"$enriched" >/dev/null 2>&1 || { echo "mine-merge-history: $slug: enriched data did not parse" >&2; rc=1; continue; }
  stats="$(jq -c "$AGGREGATE_JQ" <<<"$enriched")" || { echo "mine-merge-history: $slug: aggregation failed" >&2; rc=1; continue; }
  REPO_STATS["$slug"]="$stats"
done

if (( rc != 0 )); then
  echo "mine-merge-history: one or more repos could not be mined; no baseline written" >&2
  exit 1
fi

{
  printf '# Merge-Autonomy Baseline — %s\n\n' "$date_str"
  # shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
  printf 'Stage 0 baseline (D18, docs/reviews/2026-08-14-autonomy-investigation.md §3, §6), produced by `scripts/mine-merge-history.sh`. Every merged pull request in each repo below carrying the `%s` label, read from the GitHub REST API as of this run.\n\n' "$LABEL"
  printf '## Fleet summary\n\n'
  printf '| Repo | Merged PRs | Open→merge median/p90 (h) | Ready→merge median/p90 (h) | Reverts | Follow-up fixes |\n|---|---|---|---|---|---|\n'
  fleet_count=0
  for slug in "${REPOS[@]}"; do
    [[ -n "${REPO_STATS[$slug]:-}" ]] || continue
    stats="${REPO_STATS[$slug]}"
    c="$(jq -r '.count' <<<"$stats")"
    fleet_count=$((fleet_count + c))
    printf '| %s | %s | %s / %s | %s / %s | %s | %s |\n' "$slug" "$c" \
      "$(jq -r '.open_to_merge_hours.median // "n/a"' <<<"$stats")" \
      "$(jq -r '.open_to_merge_hours.p90 // "n/a"' <<<"$stats")" \
      "$(jq -r '.ready_to_merge_hours.median // "n/a"' <<<"$stats")" \
      "$(jq -r '.ready_to_merge_hours.p90 // "n/a"' <<<"$stats")" \
      "$(jq -r '.post_merge.reverts' <<<"$stats")" \
      "$(jq -r '.post_merge.follow_up_fixes' <<<"$stats")"
  done
  printf '| **Fleet total** | **%s** | | | | |\n\n' "$fleet_count"

  printf '## Per repo\n\n'
  for slug in "${REPOS[@]}"; do
    [[ -n "${REPO_STATS[$slug]:-}" ]] || continue
    render_repo_section "$slug" "${REPO_STATS[$slug]}"
  done

  printf '## Scope\n\n'
  # shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
  printf -- '- Review states are every formal review GitHub recorded (`APPROVED`/`CHANGES_REQUESTED`/`COMMENTED`), tallied per submission, not deduplicated per PR — a PR reviewed twice by the same account counts twice, which is why totals can exceed the merged-PR count.\n'
  # shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
  printf -- '- Open→merge is PR-created to merged; ready→merge is the first `ready_for_review` timeline event (or PR-created, if the PR was never a draft) to merged.\n'
  # shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
  printf -- '- Post-merge outcome checks two things within 48 h of merge: (a) any issue or pull request that GitHub cross-references to the merged PR and that itself merged in the window — a `revert` if its title starts with "revert", else a `follow-up-fix`; (b) file overlap against other `%s`-labelled pull requests merged in the same window. A same-file follow-up authored outside the label, and never referencing the original PR, is not detected.\n' "$LABEL"
  printf -- '- Nearest-rank median/p90 (no interpolation).\n\n'

  printf '## Raw data\n\n```json\n'
  raw='{}'
  for slug in "${REPOS[@]}"; do
    [[ -n "${REPO_STATS[$slug]:-}" ]] || continue
    raw="$(jq -c --arg slug "$slug" --argjson stats "${REPO_STATS[$slug]}" '. + {($slug): $stats}' <<<"$raw")"
  done
  jq -nc --arg label "$LABEL" --arg date "$date_str" --argjson repos "$raw" \
    '{generated: $date, label: $label, repos: $repos}'
  printf '\n```\n'
} > "$body_file"

cp "$body_file" "$out_file"
printf '%s\n' "$out_file"
