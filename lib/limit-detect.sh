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
# would waste a retry roughly every 3 hours for days.
#
# It is an *upper bound*, not a prediction — and since the probe of
# requirement 2.1b, not the exit either. Every limit clears on its own at the
# plan's rollover, and this system has no way to learn when that is when the
# message does not say; so while an estimated stand-down is in force, every
# hourly cycle asks the API directly (see `limit_probe_verdict` and the 2.1b
# block in agent-cycle.sh) and retires the stand-down the moment the account
# answers. What this constant bounds is how long the *record* can outlive the
# limit when every probe comes back inconclusive — a node whose probes cannot
# reach the API at all is a node whose cycles could not have run anyway. What
# it must never do is present the guess as a deadline — see `reset_known`
# below.
LIMIT_LONG_COOLDOWN_HOURS=24

# limit_decide TEXT COOLDOWN_DEFAULT_HOURS
# Pure decision function (given a text blob, no file I/O): prints
# "<resume_at>\t<class>\t<reset_known>" — the exact fields
# detect_and_log_limit_hit() (agent-cycle.sh) logs on a limit-hit event.
#   - resume_at:   parsed from an ISO-8601 timestamp if present, else from a
#                  human-readable weekly reset clause, else a fallback
#                  COOLDOWN_DEFAULT_HOURS (or LIMIT_LONG_COOLDOWN_HOURS for
#                  weekly/monthly phrasing) hours from now.
#   - class:       weekly | monthly | other (see limit_class_of).
#   - reset_known: true only when a reset time was actually stated in the
#                  message. False means `resume_at` is this system's own
#                  guess and carries no information about the real reset.
#
# `reset_known` replaced an earlier `needs_human` flag, which claimed the
# spend-cap case "clears only when a human raises the cap". That was wrong in
# a way that mattered: a hit limit has *two* exits — wait for the plan's
# rollover (no human involved) or raise the cap (a human, and only if they
# want it back sooner). Calling the first exit nonexistent turned an unknown
# reset time into an apparent dead end, and left the pipeline standing down on
# a fabricated deadline with no supported way to lift it. What the detector
# actually knows is narrower and is all this field now claims: whether the
# message stated a reset time.
limit_decide() {
  local text="$1" cooldown_default_hours="$2" resume_at="" class reset_known=true

  resume_at="$(grep -oihE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z' <<<"$text" | head -n1 || true)"
  if [[ -z "$resume_at" ]]; then
    resume_at="$(limit_parse_human_reset "$text" 2>/dev/null || true)"
  fi

  class="$(limit_class_of "$text")"

  if [[ -z "$resume_at" ]]; then
    reset_known=false
    if [[ "$class" == "weekly" || "$class" == "monthly" ]]; then
      resume_at="$(date -u -d "+${LIMIT_LONG_COOLDOWN_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
    else
      resume_at="$(date -u -d "+${cooldown_default_hours} hours" +%Y-%m-%dT%H:%M:%SZ)"
    fi
  fi

  printf '%s\t%s\t%s\n' "$resume_at" "$class" "$reset_known"
}

# limit_decide_structured INFO_JSON COOLDOWN_DEFAULT_HOURS
# The same `<resume_at>\t<class>\t<reset_known>` triple `limit_decide` prints,
# but read off the runner's own `rate_limit_info` object rather than parsed out
# of prose. Returns 1 with no output when the object says nothing usable.
#
# This is the better source wherever it exists, and worth saying why: the
# prose path exists because a limit used to be knowable only from the sentence
# the model printed, and a sentence has to be pattern-matched, may not state a
# reset time at all (the spend-cap message never does), and states it in a
# named zone that has to be resolved. `resetsAt` is an epoch. Where it is
# present the stand-down is a fact rather than an estimate, which is exactly
# the distinction `reset_known` was added to carry — and an estimated
# stand-down costs the fleet a probe every cycle until it clears.
#
# The class mapping follows what the fallback cooldown is for, not what the
# limit is called: a `seven_day*` limit is the long kind that
# `LIMIT_LONG_COOLDOWN_HOURS` exists for, and `five_hour` is not. It only
# matters when there is no `resetsAt` to use.
limit_decide_structured() {
  local info="${1:-}" cooldown_default_hours="${2:-3}" resets_at class reset_known resume_at
  [[ -n "$info" ]] || return 1
  jq -e 'type == "object"' <<<"$info" >/dev/null 2>&1 || return 1

  class="$(jq -r '
    (.rateLimitType // "" | tostring)
    | if startswith("seven_day") then "weekly" else "other" end' <<<"$info" 2>/dev/null)" || return 1

  resets_at="$(jq -r '.resetsAt // empty | tostring' <<<"$info" 2>/dev/null || true)"
  if [[ "$resets_at" =~ ^[0-9]+$ ]] && (( resets_at > 0 )); then
    resume_at="$(date -u -d "@$resets_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  fi
  if [[ -n "${resume_at:-}" ]]; then
    reset_known=true
  else
    # No stated reset: fall back exactly as the prose path does, so the two
    # sources cannot produce differently-shaped stand-downs.
    reset_known=false
    if [[ "$class" == "weekly" ]]; then
      resume_at="$(date -u -d "+${LIMIT_LONG_COOLDOWN_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
    else
      resume_at="$(date -u -d "+${cooldown_default_hours} hours" +%Y-%m-%dT%H:%M:%SZ)"
    fi
  fi

  printf '%s\t%s\t%s\n' "$resume_at" "$class" "$reset_known"
}

# limit_probe_verdict OUT_TEXT [ERR_TEXT]
# Classify the transcript of one minimal probe invocation (requirement 2.1b:
# agent-cycle.sh spends it while an *estimated* stand-down is in force, asking
# the only authority on whether the limit is still real). OUT_TEXT is the
# probe's stdout — the headless JSON envelope — and ERR_TEXT its stderr; they
# arrive as two arguments because stray stderr diagnostics concatenated into
# the envelope would break the JSON parse (the same reason run_claude_stage
# keeps the two files apart). Prints exactly one of:
#   clear         the account answered — the limit behind the stand-down is
#                 gone, and the caller may retire it (both carriers)
#   limited       the transcript carries a limit phrase: still standing down
#   inconclusive  anything else — a timeout, a network failure, an empty or
#                 unparseable transcript. Says nothing about the limit, so
#                 the caller must change nothing on it.
#
# The phrase check runs first, over both streams, unconditionally: a limited
# probe's envelope is still well-formed JSON (the limit message arrives *in*
# `result`), and the one mistake this function must never make is reading
# "you've hit your … limit" as the account answering. Pure text-in,
# verdict-out — the `claude` invocation itself stays in agent-cycle.sh with
# every other one — so this can be regression-tested against canned
# transcripts.
limit_probe_verdict() {
  local out_text="$1" err_text="${2:-}"
  if grep -qiE "$LIMIT_PHRASE_REGEX" <<<"$out_text"$'\n'"$err_text"; then
    printf 'limited'
    return 0
  fi
  # The emptiness guard is not decoration: under jq 1.6, `jq -e` on empty
  # input exits 0 (fixed to exit 4 in 1.7), so without it an empty transcript
  # — the shape of every timeout — would read as the account answering.
  if [[ -n "${out_text//[[:space:]]/}" ]] \
     && jq -e 'type == "object" and (.is_error == false) and ((.result // "") != "")' \
       <<<"$out_text" >/dev/null 2>&1; then
    printf 'clear'
    return 0
  fi
  printf 'inconclusive'
}

# limit_union_record  < JSONL on stdin
# The usage-limit stand-down the fleet's event stream currently implies: print
# the governing `limit-hit` record, or nothing when none is in force.
#
# The reduction is most-recent-wins over *both* limit events, so a
# `limit-cleared` written after a `limit-hit` supersedes it. Without that, an
# operator who resolved the limit had no way to say so: the stand-down is
# checked before any stage runs, so no cycle could ever succeed and clear it
# from the inside. The stream is time-ordered by `fleet_logs`.
#
# One definition, because four readers need it — agent-cycle.sh's stand-down,
# review-cycle.sh's two, and the dashboard — and a reader that missed
# `limit-cleared` would keep standing its node down after the fleet resumed.
limit_union_record() {
  jq -cs '[.[] | select(.event == "limit-hit" or .event == "limit-cleared")] | last
          | if . == null or .event == "limit-cleared" then empty else . end' \
    2>/dev/null || true
}

# limit_union_resume_at  < JSONL on stdin
# Just the governing `resume_at`, for the readers that need no more than that.
limit_union_resume_at() {
  limit_union_record | jq -r '.resume_at // empty' 2>/dev/null || true
}

# limit_standdown_since  < JSONL on stdin
# The `ts` of the earliest `limit-hit` in the current uninterrupted stand-down
# window — everything after the last `limit-cleared`, if any — or nothing when
# no live hit exists. This is how long the fleet has been frozen, as distinct
# from when the freeze was last *extended* (the governing record's own `ts`),
# and is what the automatic-freeze escalation ages against (requirement 2;
# #244): a freeze that keeps re-confirming itself must not keep resetting the
# clock that decides when a human hears about it.
limit_standdown_since() {
  jq -rs '[.[] | select(.event == "limit-hit" or .event == "limit-cleared")]
          | (map(.event) | rindex("limit-cleared")) as $i
          | (if $i == null then . else .[($i + 1):] end)
          | map(select(.event == "limit-hit"))
          | (first | .ts) // empty' 2>/dev/null || true
}

# limit_later_record RECORD...
# Requirement 2.1's "later resume wins", over the records of both carriers —
# the log union and fleet/limit.json. Prints the governing record, or nothing
# when none of them names a resume time. Empty and unparseable arguments are
# skipped, so a caller can pass a carrier that is simply clear.
#
# Shared because three callers need the same answer — the stand-down check,
# `--status`, and `--clear-limit` — and a `--status` that disagreed with the
# check would be worse than no `--status` at all (requirement 34a).
limit_later_record() {
  local rec cand cand_epoch best="" best_epoch=0
  for rec in "$@"; do
    [[ -n "$rec" ]] || continue
    cand="$(jq -r '.resume_at // empty' <<<"$rec" 2>/dev/null || true)"
    [[ -n "$cand" ]] || continue
    cand_epoch="$(date -d "$cand" +%s 2>/dev/null || echo 0)"
    if (( cand_epoch > best_epoch )); then
      best_epoch="$cand_epoch"
      best="$rec"
    fi
  done
  if [[ -n "$best" ]]; then printf '%s' "$best"; fi
  return 0
}

# limit_reset_known RECORD
# Whether a limit-hit event or fleet/limit.json record stated a real reset
# time. Reads the superseded `needs_human` when `reset_known` is absent, so a
# node running this code reports a peer's older event correctly during a
# rollout rather than silently calling every one of them authoritative.
limit_reset_known() {
  jq -r 'if has("reset_known") then .reset_known
         elif has("needs_human") then (.needs_human | not)
         else true end' <<<"${1:-{\}}" 2>/dev/null || printf 'true'
}

# limit_describe RESUME_AT CLASS RESET_KNOWN
# The one-line human explanation of a stand-down, shared by the dashboard
# banner and `--status` so they cannot describe the same state differently.
limit_describe() {
  local resume_at="$1" class="$2" reset_known="$3"
  if [[ "$reset_known" == "true" ]]; then
    printf 'until %s' "$resume_at"
    return 0
  fi
  printf 'with no stated reset; each hourly cycle probes whether it has lifted — %s is only the estimated upper bound' "$resume_at"
  if [[ "$class" == "weekly" || "$class" == "monthly" ]]; then
    printf "%s" "; it clears at the plan's rollover — the next probe notices on its own — or sooner if you raise the cap; 'agent-cycle.sh --clear-limit' remains the manual override"
  fi
}
