#!/usr/bin/env bash
#
# lib/report-directory.sh — resolving a configurable `report_directory` (issue
# #761): a GNU date(1) format string naming where the review pipeline writes
# its report set, and discovering which of its past instances already exist
# on a repository's default branch.
#
# `date -u +"<format>"` answers "where does today's report go" in one call —
# that part needs no help. What this file adds is the other direction: "which
# directories matching this format's shape already exist, and which is the
# most recent". A fixed layout (`reviews/project-review-YYYY-MM-DD`) used to
# answer that with one hardcoded regex; a configurable format string cannot,
# because the date component can sit anywhere in the path (an installation's
# override may template a whole leading segment, e.g. `%Y/repo-review`) and
# the surrounding literal text is arbitrary.
#
# ## Design: list once, then test days locally
#
# `report_directory_find_dirs` turns FORMAT into a small set of *existing*
# candidate directories with one targeted GitHub listing (occasionally a
# few, for a format with more than one dynamic path segment) — every leading
# segment free of a `%` specifier is folded into a single static path prefix
# first, so the common case (the whole dynamic part is the final segment, as
# both the shipped default and every example in the issue are shaped) costs
# exactly the one listing call the fixed layout already made.
#
# `report_directory_most_recent` then finds which day each candidate belongs
# to not by parsing the candidate's name back into a date (which would need a
# second, position-tracking regex, one considerably fiddlier to get right for
# an arbitrary format), but by resolving FORMAT for each of the last LOOKBACK
# days and checking whether that resolved string is one of the candidates.
# Every one of those checks is a local `date` call — no network cost beyond
# the listing above — so a generous lookback (400 days; comfortably longer
# than any realistic gap between reviews) costs nothing worth economising.

# The report directory's own ultimate fallback (issue #761): used by both
# pipelines wherever a repository configures neither its own
# `project_review.repos[].report_directory` nor
# `project_review.defaults.report_directory` — today's layout, unchanged. Not
# a schema `default` (config.schema.json's `reportDirectory` $def
# deliberately carries none): a schema-level default would be injected by
# config_defaults and read as a configured override, permanently hiding the
# distinction between "genuinely unset" and "set to this value" that
# render-config-table.sh's "*(unset)*" cells depend on.
# shellcheck disable=SC2034  # read by review-cycle.sh, lib/eligibility.sh and scripts/gather-project-review.sh, which source this file
REPORT_DIRECTORY_DEFAULT="reviews/project-review-%Y-%m-%d"

# report_directory_regex FORMAT
# A POSIX ERE fragment (no anchors) matching any string `date -u +FORMAT`
# could produce. Recognises the specifiers a report-directory format
# plausibly uses — %Y %y %m %d %H %M %S %j, and %% for a literal percent —
# converting each to a digit-count character class; every other character is
# regex-escaped if it is a metacharacter, copied through otherwise. A
# specifier this does not recognise degrades to `.*` (still matches, just
# without narrowing what it matches), never to a hard failure — the
# directories such a format is producing are exactly the ones this must
# still be able to find.
report_directory_regex() {
  local format="$1" out="" i=0 c next len
  len=${#format}
  while (( i < len )); do
    c="${format:$i:1}"
    if [[ "$c" == "%" && $(( i + 1 )) -lt $len ]]; then
      next="${format:$(( i + 1 )):1}"
      case "$next" in
        Y) out+="[0-9]{4}" ;;
        y) out+="[0-9]{2}" ;;
        m) out+="[0-9]{2}" ;;
        d) out+="[0-9]{2}" ;;
        H) out+="[0-9]{2}" ;;
        M) out+="[0-9]{2}" ;;
        S) out+="[0-9]{2}" ;;
        j) out+="[0-9]{3}" ;;
        '%') out+="%" ;;
        *) out+=".*" ;;
      esac
      i=$(( i + 2 ))
      continue
    fi
    case "$c" in
      '.'|'*'|'+'|'?'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|'|\\) out+="\\$c" ;;
      *) out+="$c" ;;
    esac
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

# _report_directory_walk PREFIX SLUG BRANCH SEGMENT [SEGMENT ...]
# Internal to report_directory_find_dirs. Lists PREFIX (repo root when empty)
# on BRANCH, keeps entries of type dir whose name matches SEGMENT's resolved
# shape, and either prints each match (no segments remain) or recurses into
# it for the next one. Degrades to nothing wherever `gh api` fails (a missing
# parent directory, an unreadable repository) — the same silent-empty
# discovery result an absent `reviews/` folder already produced.
_report_directory_walk() {
  local prefix="$1" slug="$2" branch="$3"; shift 3
  local seg="$1"; shift
  local regex api_path listing name next_prefix
  regex="^$(report_directory_regex "$seg")\$"
  if [[ -z "$prefix" ]]; then api_path="contents"; else api_path="contents/$prefix"; fi
  listing="$(gh api "repos/$slug/$api_path?ref=$branch" 2>/dev/null)" || return 0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -z "$prefix" ]]; then next_prefix="$name"; else next_prefix="$prefix/$name"; fi
    if (( $# == 0 )); then
      printf '%s\n' "$next_prefix"
    else
      _report_directory_walk "$next_prefix" "$slug" "$branch" "$@"
    fi
  done < <(jq -r --arg re "$regex" '.[]? | select(.type == "dir") | select(.name | test($re)) | .name' <<<"$listing" 2>/dev/null)
}

# report_directory_find_dirs SLUG BRANCH FORMAT
# Every existing directory on BRANCH whose path matches FORMAT's resolved
# shape, one per line (empty if none). See the file header for the folding
# and listing strategy.
report_directory_find_dirs() {
  local slug="$1" branch="$2" format="$3"
  local -a segments
  IFS='/' read -r -a segments <<<"$format"
  (( ${#segments[@]} > 0 )) || return 0
  local static_prefix="" i=0
  while (( i < ${#segments[@]} - 1 )) && [[ "${segments[$i]}" != *%* ]]; do
    if [[ -z "$static_prefix" ]]; then static_prefix="${segments[$i]}"; else static_prefix+="/${segments[$i]}"; fi
    i=$(( i + 1 ))
  done
  local -a remaining=("${segments[@]:$i}")
  _report_directory_walk "$static_prefix" "$slug" "$branch" "${remaining[@]}"
}

# report_directory_most_recent SLUG BRANCH FORMAT [LOOKBACK_DAYS]
# Prints "<YYYY-MM-DD>\t<resolved-path>" for the most recent existing report
# directory FORMAT could name, or nothing if none exist within LOOKBACK_DAYS
# (default 400). See the file header for why the date is found by testing
# candidates against each of the last LOOKBACK_DAYS days rather than parsed
# back out of the directory name.
#
# Each probe below resolves FORMAT with the *current* time of day
# (`date -u -d "-$d day"`), so FORMAT must be day-granular — the
# `reportDirectory` schema $def documents this requirement. A format
# embedding a time-of-day specifier (%H/%M/%S) essentially never matches the
# time-of-day baked into an existing directory's name, and discovery
# silently returns nothing.
report_directory_most_recent() {
  local slug="$1" branch="$2" format="$3" lookback="${4:-400}"
  local candidates
  candidates="$(report_directory_find_dirs "$slug" "$branch" "$format")"
  [[ -n "$candidates" ]] || return 0
  local d resolved
  for (( d = 0; d <= lookback; d++ )); do
    resolved="$(date -u -d "-$d day" +"$format")"
    if grep -qxF "$resolved" <<<"$candidates"; then
      printf '%s\t%s\n' "$(date -u -d "-$d day" +%Y-%m-%d)" "$resolved"
      return 0
    fi
  done
}
