#!/usr/bin/env bash
#
# lib/limit-detect.sh — shared usage-limit / spend-cap detection.
#
# Sourced by both agent-cycle.sh and scripts/publish-dashboard.sh so the
# phrase pattern and reset-time parsing live in exactly one place and the two
# detectors can't drift apart again (see TD26071401).
#
# Claude emits (at least) two distinct "you've hit a limit" messages, and they
# need different downstream handling:
#   - Weekly/rolling usage limit — "You've hit your weekly limit · resets Jul
#     17, 4am (Pacific/Auckland)". Carries a parseable reset time: stand down
#     until exactly then.
#   - Monthly spend cap — "You've hit your monthly spend limit · raise it at
#     claude.ai/settings/usage". Carries no reset time; clears only when a
#     human raises the cap (or the billing month rolls over) — auto-retry
#     cannot fix it.
# Both share the stem "You've hit your ... limit", so a single case-insensitive
# `hit your .* limit` term catches every observed variant, alongside the
# original terms this project has looked for from the start.

# Case-insensitive ERE fed to `grep -E`. This is the one place either script's
# limit-phrase pattern comes from — do not inline a copy elsewhere.
LIMIT_PHRASE_REGEX='hit your .* limit|usage limit|rate limit|usage cap|quota exceeded'

# limit_phrase_in FILE...
# True if any of the given files (missing files are silently ignored) contain
# a limit/quota phrase.
limit_phrase_in() {
  grep -qihE "$LIMIT_PHRASE_REGEX" "$@" 2>/dev/null
}

# limit_class_of TEXT
# Echoes "weekly", "monthly", or "other" depending on which class of limit the
# text describes. The class decides both which reset-time parse applies and
# how long the fallback cooldown should be when no reset time can be parsed.
limit_class_of() {
  local text="$1"
  if grep -qiE 'weekly' <<<"$text"; then
    echo weekly
  elif grep -qiE 'monthly' <<<"$text"; then
    echo monthly
  else
    echo other
  fi
}

# limit_parse_human_reset TEXT
# Parses a human-readable "resets <Month> <day>, <time> (<Named/Zone>)" clause
# (e.g. "resets Jul 17, 4am (Pacific/Auckland)") to a concrete UTC ISO-8601
# timestamp on stdout. Returns 1 with no output if no such clause is present.
#
# The message never states a year, so this assumes the next upcoming
# occurrence of that month/day, rolling forward a year if the naive parse
# would fall in the past.
#
# The named zone must be applied via TZ, not left in the string: `date -d`
# fed the whole "<time> (<Zone>)" text does not understand the parenthesised
# zone and silently ignores it. It must also NOT be combined with `date -u`
# in the same call — `-u` operates as though TZ were UTC0, which would
# override (not compose with) the named zone. So this parses in two steps:
# first resolve the local wall-clock time to an epoch under `TZ=<Zone>` with
# no `-u`, then format that epoch in UTC as a separate `date -u -d @<epoch>`
# call.
limit_parse_human_reset() {
  local text="$1" clause month day time tz year epoch now_epoch
  clause="$(grep -oiE "resets?[[:space:]]+[A-Za-z]+[[:space:]]+[0-9]{1,2},[[:space:]]*[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m[[:space:]]*\([A-Za-z_/+-]+\)" <<<"$text" | head -n1 || true)"
  [[ -n "$clause" ]] || return 1

  shopt -s nocasematch
  if [[ "$clause" =~ ^resets?[[:space:]]+([A-Za-z]+)[[:space:]]+([0-9]{1,2}),[[:space:]]*([0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m)[[:space:]]*\(([A-Za-z_/+-]+)\)$ ]]; then
    month="${BASH_REMATCH[1]}"
    day="${BASH_REMATCH[2]}"
    time="${BASH_REMATCH[3]}"
    tz="${BASH_REMATCH[5]}"
  else
    shopt -u nocasematch
    return 1
  fi
  shopt -u nocasematch

  year="$(date -u +%Y)"
  epoch="$(TZ="$tz" date -d "$month $day $year $time" +%s 2>/dev/null)" || return 1
  now_epoch="$(date +%s)"
  if (( epoch < now_epoch )); then
    epoch="$(TZ="$tz" date -d "$month $day $((year + 1)) $time" +%s 2>/dev/null)" || return 1
  fi
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

# LIMIT_LONG_COOLDOWN_HOURS: fallback stand-down for a weekly/monthly limit
# whose reset time couldn't be parsed at all (e.g. the spend-cap message,
# which never states one). `limit_cooldown_default` (a few hours) is sized
# for a transient rate limit, not a weekly or monthly one — at that cadence it
# would waste a retry roughly every 3 hours for days. One day is still just a
# fallback upper bound (agent-cycle.sh re-checks and clears it the moment the
# pipeline succeeds again), not a promise the block lasts that long.
LIMIT_LONG_COOLDOWN_HOURS=24

# limit_decide TEXT COOLDOWN_DEFAULT_HOURS
# Pure decision function (given a text blob, no file I/O): prints
# "<resume_at>\t<class>\t<needs_human>" — the exact fields
# detect_and_log_limit_hit() (agent-cycle.sh) logs on a limit-hit event.
#   - resume_at:   parsed from an ISO-8601 timestamp if present, else from a
#                  human-readable weekly reset clause, else a fallback
#                  COOLDOWN_DEFAULT_HOURS (or LIMIT_LONG_COOLDOWN_HOURS for
#                  weekly/monthly phrasing) hours from now.
#   - class:       weekly | monthly | other (see limit_class_of).
#   - needs_human: true only when no reset time could be parsed AND the
#                  phrasing says weekly/monthly — i.e. the spend-cap case,
#                  which auto-retry cannot fix. A plain "other" match with no
#                  timestamp keeps the original (transient-rate-limit)
#                  assumption and does not need a human.
limit_decide() {
  local text="$1" cooldown_default_hours="$2" resume_at="" class needs_human=false

  resume_at="$(grep -oihE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z' <<<"$text" | head -n1 || true)"
  if [[ -z "$resume_at" ]]; then
    resume_at="$(limit_parse_human_reset "$text" 2>/dev/null || true)"
  fi

  class="$(limit_class_of "$text")"

  if [[ -z "$resume_at" ]]; then
    if [[ "$class" == "weekly" || "$class" == "monthly" ]]; then
      needs_human=true
      resume_at="$(date -u -d "+${LIMIT_LONG_COOLDOWN_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
    else
      resume_at="$(date -u -d "+${cooldown_default_hours} hours" +%Y-%m-%dT%H:%M:%SZ)"
    fi
  fi

  printf '%s\t%s\t%s\n' "$resume_at" "$class" "$needs_human"
}
