#!/usr/bin/env bash
#
# lib/toggle.sh — the pipelines' enable/disable switch (requirement 2.3), and
# the fleet flags that lift it and the usage-limit stand-down to every node
# at once (requirements 2.3a and 2.1 — see the fleet section below).
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
  local f
  f="$(toggle_file "$1")"
  if [[ ! -f "$f" ]]; then
    printf '{"state":"enabled"}'
    return 0
  fi
  # The file exists, so something meant to disable: an empty or unreadable
  # record resolves toward disabled inside _toggle_eval via the sentinel.
  _toggle_eval "$(cat "$f" 2>/dev/null || true)" present
}

# _toggle_eval RAW [present]
# Evaluate the raw bytes of a switch record into the state object above.
# Shared by toggle_state (local file) and fleet_disabled_state (fetched flag).
# With no RAW there are two readings, and the caller says which applies:
# `present` means "the record exists but is empty/unreadable" (disabled — see
# the header: recovering enabled from a truncated write is the wrong
# direction); otherwise no record exists at all (enabled).
_toggle_eval() {
  local raw="$1" presence="${2:-}" rec exp exp_epoch now
  rec="$(jq -c '.' <<<"$raw" 2>/dev/null || true)"
  if [[ -z "$rec" || "$rec" == "null" ]]; then
    if [[ -z "$raw" && "$presence" != "present" ]]; then
      printf '{"state":"enabled"}'
    else
      printf '%s' '{"state":"disabled","record":{"reason":"unreadable disable record — treating as disabled","expires_at":null,"by":"","disabled_at":""}}'
    fi
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

# ===== Fleet flags (requirements 2.3a and 2.1) ================================
#
# The switch above stops one node. A fleet of active nodes needs two signals
# that reach all of them at once, without waiting for the next state-sync
# fetch interval:
#
#   fleet/disabled.json — the switch, one level up. Same record shape as
#     state_dir/disabled.json; set and cleared by `agent-cycle.sh
#     --disable/--enable`, which writes both levels.
#   fleet/limit.json — a usage-limit stand-down. Every node spends the same
#     Claude account, so the first node to hit the limit publishes
#     {resume_at, class, needs_human, node, ts} and the rest stop trying.
#     Writers may only ever *extend* resume_at, never shorten it — two nodes
#     hitting the limit in the same minute must converge on the later resume,
#     whatever order their writes land in.
#
# Both live as files on the state repository's main branch, written through
# the contents API — the same CAS the claim registry uses (requirement 17a):
# a PUT with a stale sha loses, and the loser re-reads before retrying. There
# is no single writer and no chore to elect one; every operation here is
# idempotent, so "whoever gets there first" is the whole protocol.
#
# Failure directions, chosen deliberately:
#   404             → the flag is clear. Definitive, not an error.
#   unreachable     → fall back to the copy cached at the last successful
#     fetch (stale beats blind), and to *enabled* when there is none. Failing
#     open here is safe because it is not the last line of defence: a node
#     that charges ahead while GitHub is down meets per-item claims that fail
#     closed (requirement 17a) and stands itself down anyway.
#   present-but-garbage → disabled, exactly as for the local record: the flag
#     exists because something meant to stop the fleet.
#
# `TOGGLE_GH` substitutes for `gh` in the tests, like CLAIM_GH/STATE_SYNC_GH.
# An empty state-repo slug turns every function here into a quiet no-op: with
# no state repository this is a single-node operation and the local switch
# already covers it.

_fleet_gh() { "${TOGGLE_GH:-gh}" "$@"; }

# fleet_flag_path NAME
fleet_flag_path() { printf 'fleet/%s.json' "$1"; }

# fleet_cache_file STATE_DIR NAME
# Where the last successfully fetched copy of a flag lives locally.
fleet_cache_file() { printf '%s/fleet-cache/%s.json' "$1" "$2"; }

# fleet_flag_fetch STATE_REPO STATE_DIR NAME
# Print the flag's raw bytes, or nothing when it is clear. Always returns 0;
# the caller cannot tell "clear" from "unreachable with no cache", which is
# the point — both read as "nothing stands you down" (see the header for why
# that is safe).
fleet_flag_fetch() {
  local repo="$1" state_dir="$2" name="$3" cache resp raw
  [[ -n "$repo" ]] || return 0
  cache="$(fleet_cache_file "$state_dir" "$name")"
  mkdir -p "${cache%/*}" 2>/dev/null || true
  if resp="$(_fleet_gh api "repos/$repo/contents/$(fleet_flag_path "$name")?ref=main" 2>"$cache.err")"; then
    raw="$(jq -r '.content // ""' <<<"$resp" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null || true)"
    printf '%s' "$raw" > "$cache"
    printf '%s' "$raw"
    return 0
  fi
  if grep -qiE 'HTTP 404|Not Found' "$cache.err" 2>/dev/null; then
    rm -f "$cache"
    return 0
  fi
  [[ -f "$cache" ]] && cat "$cache"
  return 0
}

# fleet_flag_write STATE_REPO NAME BODY MESSAGE
# One CAS attempt: read the current sha, PUT against it. Returns non-zero on
# a lost race or an unreachable repo — the caller decides whether to re-read
# and retry (the limit publisher does) or to warn (the disable path does).
fleet_flag_write() {
  local repo="$1" name="$2" body="$3" msg="$4" path payload sha
  [[ -n "$repo" ]] || return 0
  path="$(fleet_flag_path "$name")"
  payload="$(printf '%s\n' "$body" | base64 -w0)"
  sha="$(_fleet_gh api "repos/$repo/contents/$path?ref=main" --jq '.sha' 2>/dev/null || true)"
  if [[ -n "$sha" ]]; then
    _fleet_gh api -X PUT "repos/$repo/contents/$path" -f message="$msg" \
      -f content="$payload" -f branch=main -f sha="$sha" >/dev/null 2>&1
  else
    _fleet_gh api -X PUT "repos/$repo/contents/$path" -f message="$msg" \
      -f content="$payload" -f branch=main >/dev/null 2>&1
  fi
}

# fleet_flag_delete STATE_REPO STATE_DIR NAME
# Clear a flag. Absent (404) already counts as cleared; anything else that
# stops the delete returns non-zero, because "cleared" reported for a flag
# that is still set keeps the whole fleet standing down after the operator
# believes they resumed it. A successful clear also drops the local cache —
# a stale cached copy must not resurrect a flag the fleet no longer has.
fleet_flag_delete() {
  local repo="$1" state_dir="$2" name="$3" path errf resp sha
  [[ -n "$repo" ]] || return 0
  path="$(fleet_flag_path "$name")"
  errf="$(fleet_cache_file "$state_dir" "$name").err"
  mkdir -p "${errf%/*}" 2>/dev/null || true
  if ! resp="$(_fleet_gh api "repos/$repo/contents/$path?ref=main" 2>"$errf")"; then
    grep -qiE 'HTTP 404|Not Found' "$errf" 2>/dev/null || return 1
    rm -f "$(fleet_cache_file "$state_dir" "$name")"
    return 0
  fi
  sha="$(jq -r '.sha // empty' <<<"$resp" 2>/dev/null || true)"
  [[ -n "$sha" ]] || return 1
  _fleet_gh api -X DELETE "repos/$repo/contents/$path" \
    -f message="fleet: clear $name" -f branch=main -f sha="$sha" >/dev/null 2>&1 || return 1
  rm -f "$(fleet_cache_file "$state_dir" "$name")"
  return 0
}

# fleet_disabled_state STATE_REPO STATE_DIR
# The fleet switch, in exactly toggle_state's vocabulary — the pipelines
# handle both switches with the same case statement.
fleet_disabled_state() {
  local raw
  raw="$(fleet_flag_fetch "$1" "$2" disabled)"
  if [[ -z "$raw" ]]; then
    printf '{"state":"enabled"}'
    return 0
  fi
  _toggle_eval "$raw" present
}

# fleet_limit_resume_at STATE_REPO STATE_DIR
# Print fleet/limit.json's resume_at, or nothing. Garbage prints nothing: a
# limit flag is machine-written, and an unreadable one failing open costs at
# most one wasted attempt that re-hits the limit and republishes it.
fleet_limit_resume_at() {
  local raw
  raw="$(fleet_flag_fetch "$1" "$2" limit)"
  [[ -n "$raw" ]] || return 0
  jq -r '.resume_at // empty' <<<"$raw" 2>/dev/null || true
  return 0
}

# fleet_limit_publish STATE_REPO STATE_DIR RESUME_AT CLASS NEEDS_HUMAN NODE
# Publish a usage-limit stand-down, extend-only: a flag already resuming at
# or after RESUME_AT is left alone. Two attempts — re-read between them — so
# losing the CAS to a peer publishing the same limit converges instead of
# failing. Returns non-zero only when the flag could not be written at all;
# the caller logs that and relies on the log union to carry the signal.
fleet_limit_publish() {
  local repo="$1" state_dir="$2" resume_at="$3" class="$4" needs_human="$5" node="$6"
  local new_epoch body cur cur_at cur_epoch
  [[ -n "$repo" ]] || return 0
  new_epoch="$(date -d "$resume_at" +%s 2>/dev/null || echo 0)"
  (( new_epoch > 0 )) || return 0
  body="$(jq -nc --arg r "$resume_at" --arg c "$class" --argjson h "${needs_human:-false}" \
    --arg n "$node" --arg ts "$(_toggle_iso)" \
    '{resume_at: $r, class: $c, needs_human: $h, node: $n, ts: $ts}')"
  for _ in 1 2; do
    cur="$(fleet_flag_fetch "$repo" "$state_dir" limit)"
    if [[ -n "$cur" ]]; then
      cur_at="$(jq -r '.resume_at // empty' <<<"$cur" 2>/dev/null || true)"
      if [[ -n "$cur_at" ]]; then
        cur_epoch="$(date -d "$cur_at" +%s 2>/dev/null || echo 0)"
        (( cur_epoch >= new_epoch )) && return 0
      fi
    fi
    fleet_flag_write "$repo" limit "$body" \
      "fleet: usage limit hit on $node — stand down until $resume_at" && return 0
  done
  return 1
}
