#!/usr/bin/env bash
#
# lib/toggle.sh — the pipelines' enable/disable switch (requirement 2.3).
#
# Sourced by agent-cycle.sh, review-cycle.sh and scripts/publish-dashboard.sh,
# so what stops a cycle, what `--status` prints, and what the dashboard shows
# are one definition rather than three that agree until they don't
# (requirement 34a).
#
# Why this exists: both cron pipelines *execute code out of the agent-ops
# working tree*. An agent editing agent-cycle.sh, lib/, or prompts/ is editing
# the very files the next cron tick will source — a cycle firing mid-edit runs
# half of one revision and half of another, and the resulting failure is
# attributed to whatever the agent happened to be writing. The switch lets an
# agent (or a human) stand the pipelines down for the duration of its work.
#
# The switch is a single file, `state_dir/disabled.json`, holding one record:
#
#   {
#     "disabled_at": "2026-07-17T09:00:00Z",
#     "expires_at":  "2026-07-17T13:00:00Z",   // null means "until --enable"
#     "by":          "wallen@host pid 4242",
#     "reason":      "editing lib/toggle.sh"
#   }
#
# It lives in `state_dir`, not in the repo, for two reasons: the repo is the
# thing being edited (a switch tracked in git would arrive and depart with
# branch checkouts, and could be committed by accident), and `state_dir` is
# already where this system keeps everything that outlives a cycle.
#
# ## Expiry is the point, not a convenience
#
# A disable defaults to a TTL (`disable_default_ttl`) and only becomes
# indefinite when someone explicitly asks for `--for forever`. This is the
# same defensive shape as the stale-lock rule in requirement 1, and for the
# same reason: the characteristic failure of this system is not a crash, it is
# a silent, confident no-op (see the Gotchas table). An agent that disables the
# pipeline and then dies — killed, timed out, context exhausted, or simply
# finished and forgetful — leaves behind a file that stops every future cycle
# for as long as nobody looks. Nothing would alert; PRs would just stop. A TTL
# turns "forgot to re-enable" from a permanent outage into a few lost cycles.
#
# Everything ambiguous resolves toward *disabled*, never toward enabled: an
# unreadable record, or one whose `expires_at` cannot be parsed, keeps the
# pipeline down. The file exists because something meant to stop the pipeline;
# recovering "enabled" from a truncated write would be the one wrong direction
# — it would run the cycle the switch was set to prevent.

# _toggle_now
# The current epoch, via `TOGGLE_NOW_EPOCH` when set. The indirection exists so
# the tests can pin the clock and assert expiry without sleeping.
_toggle_now() {
  printf '%s' "${TOGGLE_NOW_EPOCH:-$(date +%s)}"
}

_toggle_iso() {
  date -u -d "@$(_toggle_now)" +%Y-%m-%dT%H:%M:%SZ
}

# toggle_file STATE_DIR
# Print the path of the switch record.
toggle_file() {
  printf '%s' "$1/disabled.json"
}

# toggle_parse_ttl SPEC DEFAULT_HOURS
# Print the ISO-8601 instant a disable given SPEC should expire at, or nothing
# at all for an indefinite one. SPEC is `<n>[smhd]` (a bare number means
# hours), or `forever`/`never`/`indefinite`. An empty SPEC means DEFAULT_HOURS.
#
# Returns 64 on an unparseable spec rather than falling back to a default: a
# typo'd `--for 4hours` must not quietly become either 4 hours or forever. The
# two failure directions are a pipeline that resumes while an agent is still
# editing, and a pipeline that never resumes at all; guessing risks both.
toggle_parse_ttl() {
  local spec="${1:-}" default_hours="$2" n unit secs
  [[ -n "$spec" ]] || spec="${default_hours}h"
  case "$spec" in
    forever|never|indefinite) return 0 ;;
  esac
  if [[ "$spec" =~ ^([0-9]+)([smhd]?)$ ]]; then
    n="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]:-h}"
  else
    echo "toggle: unparseable duration '$spec' (want e.g. 90m, 4h, 2d, or 'forever')" >&2
    return 64
  fi
  case "$unit" in
    s) secs=$(( n )) ;;
    m) secs=$(( n * 60 )) ;;
    h) secs=$(( n * 3600 )) ;;
    d) secs=$(( n * 86400 )) ;;
    *) echo "toggle: unparseable duration unit in '$spec'" >&2; return 64 ;;
  esac
  if (( secs <= 0 )); then
    echo "toggle: duration must be greater than zero (use 'forever' for an indefinite disable, not 0)" >&2
    return 64
  fi
  date -u -d "@$(( $(_toggle_now) + secs ))" +%Y-%m-%dT%H:%M:%SZ
}

# toggle_state STATE_DIR
# Print one JSON object describing the switch:
#
#   {"state": "enabled"}
#   {"state": "disabled", "record": {…}}
#   {"state": "expired",  "record": {…}}
#
# Always succeeds and always prints an object, so a caller running under
# `set -e` can write `s="$(toggle_state "$d")"` without the absence of a switch
# — the normal case — killing the run two lines before it logs anything (the
# `set -e` trap in the Gotchas table).
#
# `expired` is reported, not silently treated as `enabled`, because clearing an
# expired switch is a state change worth logging: an operator seeing cycles
# resume deserves to find out why in the log.
toggle_state() {
  local f rec exp exp_epoch now
  f="$(toggle_file "$1")"
  if [[ ! -f "$f" ]]; then
    printf '{"state":"enabled"}'
    return 0
  fi
  rec="$(jq -c '.' "$f" 2>/dev/null || true)"
  if [[ -z "$rec" ]]; then
    printf '%s' '{"state":"disabled","record":{"reason":"unreadable disable record — treating as disabled","expires_at":null,"by":"","disabled_at":""}}'
    return 0
  fi
  exp="$(jq -r '.expires_at // ""' <<<"$rec" 2>/dev/null || true)"
  if [[ -n "$exp" ]]; then
    exp_epoch="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
    now="$(_toggle_now)"
    # exp_epoch of 0 means the timestamp did not parse. Staying disabled is the
    # safe reading: a switch whose expiry is gibberish has no expiry.
    if (( exp_epoch > 0 && exp_epoch <= now )); then
      jq -nc --argjson r "$rec" '{state: "expired", record: $r}'
      return 0
    fi
  fi
  jq -nc --argjson r "$rec" '{state: "disabled", record: $r}'
}

# toggle_disable STATE_DIR REASON TTL_SPEC DEFAULT_HOURS BY
# Set the switch and print the record written. Returns 64 if TTL_SPEC does not
# parse (nothing is written in that case — a half-set switch is worse than
# none, since the operator believes the pipeline is down and it is not).
toggle_disable() {
  local state_dir="$1" reason="$2" spec="$3" default_hours="$4" by="$5" f exp rc
  exp="$(toggle_parse_ttl "$spec" "$default_hours")" || { rc=$?; return "$rc"; }
  mkdir -p "$state_dir"
  f="$(toggle_file "$state_dir")"
  jq -n --arg at "$(_toggle_iso)" --arg exp "$exp" --arg by "$by" --arg r "$reason" \
    '{disabled_at: $at,
      expires_at: (if $exp == "" then null else $exp end),
      by: $by,
      reason: $r}' > "$f"
  jq -c '.' "$f"
}

# toggle_clear STATE_DIR
# Remove the switch. Print the record removed, or nothing if there was none.
#
# Always succeeds: "it was already enabled" is a normal outcome of asking for
# it to be enabled, and reserving non-zero for real errors is what keeps this
# usable from a `set -e` caller.
toggle_clear() {
  local f rec
  f="$(toggle_file "$1")"
  [[ -f "$f" ]] || return 0
  rec="$(jq -c '.' "$f" 2>/dev/null || true)"
  rm -f "$f"
  [[ -n "$rec" ]] && printf '%s' "$rec"
  return 0
}

# toggle_describe RECORD
# One line summarising a switch record, for a log `detail` or a human.
toggle_describe() {
  jq -r '"\(.reason // "no reason given") (set \(.disabled_at // "?") by \(.by // "?"); "
         + (if .expires_at == null or .expires_at == "" then "no expiry — needs --enable" else "expires \(.expires_at)" end)
         + ")"' <<<"$1" 2>/dev/null || printf 'disabled'
}

# toggle_lock_held LOCK_FILE
# Print a one-line description of the pipeline lock LOCK_FILE if it is held by
# a live process, or nothing if it is free. Always succeeds.
#
# Staleness is deliberately not judged here — that is requirement 1's business,
# and it needs `lock_stale_after`. This answers only the question `--status`
# actually asks: is something running right now that I would be racing?
toggle_lock_held() {
  local f="$1" pid started_at
  [[ -f "$f" ]] || return 0
  pid="$(jq -r '.pid // empty' "$f" 2>/dev/null || true)"
  started_at="$(jq -r '.started_at // "?"' "$f" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    printf 'held by pid %s since %s' "$pid" "$started_at"
  fi
  return 0
}

# toggle_status_report STATE_DIR NAME=LOCK_FILE...
# Print the human-facing `--status` block: the switch, then whether each named
# pipeline is running. Always succeeds; prints to stdout.
#
# The two facts are reported together because they answer one question between
# them. Disabling stops the *next* cycle; it does not touch a cycle already
# running. An agent that disables the pipeline and starts editing while a cycle
# is mid-flight has achieved nothing, and would have no way to know.
toggle_status_report() {
  local state_dir="$1"; shift
  local st state rec spec name lock held any_held=0

  st="$(toggle_state "$state_dir")"
  state="$(jq -r '.state' <<<"$st")"
  rec="$(jq -c '.record // {}' <<<"$st")"

  case "$state" in
    enabled)
      printf 'switch:   ENABLED — cycles will run\n'
      ;;
    expired)
      printf 'switch:   ENABLED — the disable set at %s expired at %s and will be cleared by the next cycle\n' \
        "$(jq -r '.disabled_at // "?"' <<<"$rec")" "$(jq -r '.expires_at // "?"' <<<"$rec")"
      ;;
    disabled)
      printf 'switch:   DISABLED — %s\n' "$(toggle_describe "$rec")"
      ;;
  esac
  printf 'record:   %s\n' "$(toggle_file "$state_dir")"

  for spec in "$@"; do
    name="${spec%%=*}"
    lock="${spec#*=}"
    held="$(toggle_lock_held "$lock")"
    if [[ -n "$held" ]]; then
      printf '%-9s RUNNING — %s\n' "$name:" "$held"
      any_held=1
    else
      printf '%-9s idle\n' "$name:"
    fi
  done

  if [[ "$state" == "disabled" && "$any_held" == "1" ]]; then
    printf '\nNote: disabling stops the next cycle; it does not stop one already running.\n'
    printf 'Wait for the running cycle to finish before editing files it reads.\n'
  fi
  return 0
}
