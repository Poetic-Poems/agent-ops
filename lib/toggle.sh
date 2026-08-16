#!/usr/bin/env bash
#
# lib/toggle.sh — the pipelines' enable/disable switch (requirement 2.3), and
# the fleet flags that lift it and the usage-limit stand-down to every node
# at once (requirements 2.3a and 2.1 — see the fleet section below).
#
# Sourced by agent-cycle.sh, review-cycle.sh, scripts/publish-dashboard.sh and
# scripts/state-sync.sh, so what stops a cycle, what `--status` prints, what
# the dashboard shows and what a node publishes about itself to the fleet are
# one definition rather than four that agree until they don't
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
#     "reason":      "editing lib/toggle.sh",
#     "actor":       "wallen@host",            // toggle_actor — never "unknown"
#     "kind":        "manual",                 // manual | auto (requirement 2.3)
#     "scope":       "node"                    // node | fleet (requirement 2.3)
#   }
#
# `actor` and `kind` exist because a reader of a stand-down flag must be able
# to tell an operator's deliberate stop from a detector's inference: a probe
# may clear an automatic stand-down early, and must never clear a manual one
# (#244 — the 2026-08-05 operator stand-down whose actor read as a bare
# container id was initially misread as a runaway automatic freeze).
#
# `scope` answers the neighbouring question — *which* decision is this record.
# A fleet-wide `--disable` writes this file too (requirement 2.3a: local
# first, because that always works), so without it the node that issued a
# fleet stand-down is indistinguishable from one an operator deliberately
# stood down alone with `--disable --this-node`. That node wore the
# dashboard's node-scoped `disabled` badge and `--status` announced a
# node-scoped disable nobody had asked for; worse, `--enable` run from
# *another* node clears the fleet flag but cannot reach this file, leaving one
# node down on its own, indefinitely under `--for forever`, blamed on a
# decision that was never made. `scope: "fleet"` marks the record as a
# *mirror* of the fleet switch rather than a stand-down in its own right, and
# every reader of it says so.
#
# A record with no `scope` reads as `node`: that is what every record written
# before this field existed effectively was, and — as everywhere else here —
# it is the reading that keeps a node down rather than one that talks itself
# out of a stand-down.
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

# toggle_actor
# The identity a stand-down record carries as `actor`: NODE_NAME when set (a
# node acting), else the invoking user at this host. Falls through `id -un`
# and finally the numeric uid rather than ever printing "unknown" — an
# actorless flag is unattributable, and attribution is what tells a manual
# stand-down from an automatic one.
toggle_actor() {
  if [[ -n "${NODE_NAME:-}" ]]; then
    printf '%s' "$NODE_NAME"
    return 0
  fi
  local u
  u="${USER:-}"
  [[ -n "$u" ]] || u="$(id -un 2>/dev/null || true)"
  [[ -n "$u" ]] || u="uid-$(id -u 2>/dev/null || echo '?')"
  printf '%s@%s' "$u" "$(hostname 2>/dev/null || echo '?')"
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

# toggle_parse_until SPEC
# Print the ISO-8601 instant named by SPEC, a GNU `date`-compatible absolute
# timestamp (anything `date -d` accepts, e.g. '2026-08-10 18:00', 'tomorrow
# 12:00', '2026-08-10T18:00:00Z') — the --until counterpart to
# toggle_parse_ttl's relative SPEC.
#
# Returns 64 on an unparseable SPEC, or on one that names an instant that has
# already passed: an unparseable --until must be an error rather than a
# guess, for the same reason toggle_parse_ttl's typo case is (see its
# comment above), and a --until already in the past would read to whoever
# set it as having taken effect while actually disabling nothing.
toggle_parse_until() {
  local spec="${1:-}" epoch now
  epoch="$(date -d "$spec" +%s 2>/dev/null)"
  if [[ -z "$epoch" ]]; then
    echo "toggle: unparseable timestamp '$spec' (want anything GNU date -d accepts, e.g. '2026-08-10 18:00', 'tomorrow 12:00')" >&2
    return 64
  fi
  now="$(_toggle_now)"
  if (( epoch <= now )); then
    echo "toggle: --until '$spec' names an instant that has already passed" >&2
    return 64
  fi
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

# toggle_resolve_disable_spec FOR_SPEC UNTIL_SPEC DEFAULT_HOURS
# Reconcile --for and --until into a single TTL_SPEC in toggle_parse_ttl's
# own vocabulary, so a caller that already speaks that vocabulary
# (toggle_disable) needs not learn a second one. UNTIL_SPEC is an absolute
# timestamp (toggle_parse_until's vocabulary); FOR_SPEC is a relative
# duration (toggle_parse_ttl's).
#
# With only one supplied, it passes through unchanged (FOR_SPEC verbatim;
# UNTIL_SPEC converted to the equivalent "<n>s" offset from now, so the
# instant it names survives the round trip through toggle_parse_ttl even
# though _toggle_now may have ticked on by the time that runs). With both,
# whichever resolves to the LATER instant wins — `forever` always beats any
# UNTIL_SPEC, since indefinite outlasts every timestamp — and a warning
# naming both goes to stderr: a human who gave two deadlines is entitled to
# know which one bound. With neither, prints nothing, so toggle_parse_ttl's
# own DEFAULT_HOURS fallback still applies.
#
# Returns 64 if either supplied spec is unparseable, printing nothing —
# the same failure contract the two parse functions this composes share.
toggle_resolve_disable_spec() {
  local for_spec="$1" until_spec="$2" default_hours="$3"
  local until_exp until_epoch for_exp for_epoch now

  [[ -n "$until_spec" ]] || { printf '%s' "$for_spec"; return 0; }

  until_exp="$(toggle_parse_until "$until_spec")" || return $?
  now="$(_toggle_now)"
  until_epoch="$(date -d "$until_exp" +%s)"

  if [[ -z "$for_spec" ]]; then
    printf '%ds' "$(( until_epoch - now ))"
    return 0
  fi

  for_exp="$(toggle_parse_ttl "$for_spec" "$default_hours")" || return $?

  if [[ -z "$for_exp" ]]; then
    echo "toggle: both --for and --until given; --for forever is the later deadline, using it (--until $until_spec resolves to $until_exp)" >&2
    printf 'forever'
    return 0
  fi

  for_epoch="$(date -d "$for_exp" +%s)"
  if (( for_epoch >= until_epoch )); then
    echo "toggle: both --for and --until given; using --for $for_spec ($for_exp), the later deadline (--until $until_spec resolves to $until_exp)" >&2
    printf '%s' "$for_spec"
  else
    echo "toggle: both --for and --until given; using --until $until_spec ($until_exp), the later deadline (--for $for_spec resolves to $for_exp)" >&2
    printf '%ds' "$(( until_epoch - now ))"
  fi
  return 0
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

# toggle_disable STATE_DIR REASON TTL_SPEC DEFAULT_HOURS BY [ACTOR] [KIND] [SCOPE]
# Set the switch and print the record written. Returns 64 if TTL_SPEC does not
# parse (nothing is written in that case — a half-set switch is worse than
# none, since the operator believes the pipeline is down and it is not).
# ACTOR defaults through toggle_actor and KIND to `manual` — the only kind a
# switch set by this entry point can be; `auto` is reserved for a detector
# that writes its own evidence-bearing record. SCOPE defaults to `node`; the
# caller passes `fleet` only when this record is the local half of a
# fleet-wide stand-down (see the header, and toggle_mark_scope below for what
# happens when the fleet half then fails).
toggle_disable() {
  local state_dir="$1" reason="$2" spec="$3" default_hours="$4" by="$5"
  local actor="${6:-}" kind="${7:-manual}" scope="${8:-node}" f exp rc
  [[ -n "$actor" ]] || actor="$(toggle_actor)"
  exp="$(toggle_parse_ttl "$spec" "$default_hours")" || { rc=$?; return "$rc"; }
  mkdir -p "$state_dir"
  f="$(toggle_file "$state_dir")"
  jq -n --arg at "$(_toggle_iso)" --arg exp "$exp" --arg by "$by" --arg r "$reason" \
    --arg actor "$actor" --arg kind "$kind" --arg scope "$scope" \
    '{disabled_at: $at,
      expires_at: (if $exp == "" then null else $exp end),
      by: $by,
      reason: $r,
      actor: $actor,
      kind: $kind,
      scope: $scope}' > "$f"
  jq -c '.' "$f"
}

# toggle_scope RECORD
# The scope a record claims, defaulting to `node` for one written before the
# field existed. One reader, because "did anyone tag this?" is a question three
# call sites would otherwise each answer their own way.
toggle_scope() {
  jq -r '.scope // "node"' <<<"${1:-{\}}" 2>/dev/null || printf 'node'
}

# toggle_mark_scope STATE_DIR SCOPE
# Retag an existing record in place, leaving every other field — `disabled_at`
# above all — exactly as written.
#
# This exists for one caller: a fleet-wide `--disable` whose fleet publish then
# fails. The local record is written first and optimistically tagged `fleet`,
# because it must be on disk before anything talks to GitHub; when the fleet
# write does not land, that node really is standing down alone and the record
# has to say `node` or it describes a fleet switch that was never set. Rewriting
# through toggle_disable would move `disabled_at` to now and lose the very
# instant the operator stopped the pipeline, so this edits the one field.
#
# Always succeeds: a missing or unreadable record leaves nothing to retag, and
# the caller is already warning loudly about a worse problem than a stale tag.
toggle_mark_scope() {
  local state_dir="$1" scope="$2" f tmp
  f="$(toggle_file "$state_dir")"
  [[ -f "$f" ]] || return 0
  tmp="$f.tmp.$$"
  if jq -c --arg s "$scope" '.scope = $s' "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
  return 0
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

# toggle_switch_summary STATE_DIR
# The node-scoped switch, flattened to the compact shape both
# scripts/publish-dashboard.sh (`status.switch`) and scripts/state-sync.sh's
# heartbeat (`switch`, issue #379) render from — one definition so a peer's
# card and this node's own banner cannot disagree about what the switch says
# (requirement 34a). `scope` travels with the rest: a peer's card has to be
# able to tell that node's own stand-down from its mirror of the fleet's, and
# only the node holding the record knows which it is.
toggle_switch_summary() {
  local s
  s="$(toggle_state "$1")"
  jq -nc --argjson s "$s" \
    '{disabled: ($s.state == "disabled"),
      reason: ($s.record.reason // ""),
      by: ($s.record.by // ""),
      actor: ($s.record.actor // ""),
      kind: ($s.record.kind // "manual"),
      scope: ($s.record.scope // "node"),
      since: ($s.record.disabled_at // ""),
      expires_at: ($s.record.expires_at // null)}'
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
#     {resume_at, class, reset_known, node, ts} and the rest stop trying.
#     Writers may only ever *extend* resume_at, never shorten it — two nodes
#     hitting the limit in the same minute must converge on the later resume,
#     whatever order their writes land in. `agent-cycle.sh --clear-limit`
#     deletes it instead, which is how a human ends a stand-down early
#     without breaking that rule.
#
# Both live as files on the state repository's main branch, written through
# the contents API — the same CAS the claim registry uses (requirement 17a):
# a PUT with a stale sha loses, and the loser re-reads before retrying. There
# is no single writer and no chore to elect one; every operation here is
# idempotent, so "whoever gets there first" is the whole protocol.
#
# Failure directions, chosen deliberately:
#   404 (flag file) → the flag is clear. Definitive, not an error — for this
#     level's own fail-open flags. The contents API answers "this repository
#     does not exist, or is invisible to this token" with the same 404 as
#     "the flag file does not exist" (TD-PPagop-26081602), and for these
#     flags the collapse is accepted: mistaking an invisible repo for a
#     clear flag fails open, which is their chosen direction anyway. A
#     caller whose flag must not fail open asks fleet_flag_fetch_status for
#     its probing mode instead, which resolves the ambiguity before calling
#     either 404 clear — see its header below.
#   unreachable     → fall back to the copy cached at the last successful
#     fetch (stale beats blind), and to *enabled* when there is none. Failing
#     open here is safe because it is not the last line of defence: a node
#     that charges ahead while GitHub is down meets per-item claims that fail
#     closed (requirement 17a) and stands itself down anyway.
#   present-but-garbage → disabled, exactly as for the local record: the flag
#     exists because something meant to stop the fleet.
#
# That "fail open, unreachable-with-no-cache included" direction is
# `fleet_flag_fetch`'s own default and stays right for `fleet/disabled.json`
# and the limit flag. A flag whose risk profile inverts once something arms a
# behaviour-affecting decision on it needs to tell that case apart from a
# clear-flag 404 — `fleet_flag_fetch_status` below is what such a caller
# reads instead (`merge_autonomy_kill_state`, TD-PPagop-26081507).
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

# fleet_repo_visible STATE_REPO ERR_FILE
# The repo-existence probe (TD-PPagop-26081602): `repos/<repo>`, no
# `/contents/` — succeeds iff the repo exists and this token can see it,
# which is what turns a flag file's ambiguous 404 into a definitive one.
# One shared helper, so the clear path's own 404 ambiguity can reuse it
# rather than grow a second probe that drifts (TD-PPagop-26081604).
fleet_repo_visible() {
  _fleet_gh api "repos/$1" >/dev/null 2>"$2"
}

# fleet_flag_fetch_status STATE_REPO STATE_DIR NAME [MODE]
# fleet_flag_fetch's own body, printing STATUS<TAB>RAW instead of RAW alone —
# STATUS<TAB>RAW travels as one string on stdout, the same compound-return
# idiom lib/review-gate.sh's own functions use. Split it with parameter
# expansion, never `IFS=$'\t' read`, which review-gate.sh can use only because
# both of its fields are single-line: RAW here is a file fetched from the state
# repository, so it holds whatever bytes that file holds, and a `read` would
# silently truncate a pretty-printed record to its first line — leaving the
# caller to read a valid flag as unparseable and lose the operator's own reason
# from `--status` and scripts/doctor.sh. So:
#   status="${combined%%$'\t'*}"
#   raw="${combined#*$'\t'}"
# STATUS is one of:
#   clear        — no state repo configured, or a 404 on the flag file: the
#                  flag does not exist. In the default mode that is the
#                  contents API's word alone, which cannot tell a missing
#                  flag file from a missing-or-invisible repo — accepted for
#                  the fail-open flags (the header's 404 entry). With MODE
#                  `probe-404` a 404 resolves to clear only after
#                  fleet_repo_visible confirms the repo, so the 404 was
#                  definitively the flag file's own (TD-PPagop-26081602)
#   live         — the fetch against the state repo just succeeded
#   cached       — the state repo — or, under `probe-404`, a flag-file 404's
#                  repo probe — was unreachable; RAW is the last
#                  successfully fetched copy
#   unreachable  — the same, with no cached copy at all
# fleet_flag_fetch is a thin wrapper over this that keeps its own RAW-only
# contract byte-for-byte unchanged for its three existing callers
# (fleet_disabled_state, fleet_limit_resume_at, fleet_limit_publish), which by
# design cannot tell "clear" from "unreachable" apart — see the header for why
# that is safe for them. It never passes `probe-404`: that is what keeps the
# contract byte-identical (a flag-file 404 stays terminal, cache dropped) and
# spends no probe call on the fail-open flags' steady state, whose 404 is the
# common case. merge_autonomy_kill_state is the one caller that needs the
# distinction (TD-PPagop-26081507): "clear" and "unreachable" both print an
# empty RAW, but only "unreachable" must make the kill switch fail closed —
# and it is the one caller that asks for `probe-404`, because a fail-closed
# flag mistaken for clear is the exact harm TD-PPagop-26081602 closes.
fleet_flag_fetch_status() {
  local repo="$1" state_dir="$2" name="$3" mode="${4:-}" cache resp raw
  [[ -n "$repo" ]] || { printf 'clear\t'; return 0; }
  cache="$(fleet_cache_file "$state_dir" "$name")"
  mkdir -p "${cache%/*}" 2>/dev/null || true
  if resp="$(_fleet_gh api "repos/$repo/contents/$(fleet_flag_path "$name")?ref=main" 2>"$cache.err")"; then
    raw="$(jq -r '.content // ""' <<<"$resp" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null || true)"
    printf '%s' "$raw" > "$cache"
    printf 'live\t%s' "$raw"
    return 0
  fi
  if grep -qiE 'HTTP 404|Not Found' "$cache.err" 2>/dev/null; then
    # The flag file's own 404 is ambiguous at the contents API — it means
    # either "this file does not exist" or "this repository does not exist,
    # or is invisible to this token" (deliberately, so a private repo stays
    # indistinguishable from a missing one). The default mode accepts the
    # collapse and stays terminal — these flags fail open, and the ambiguity
    # only adds one more way of doing so (the header's 404 entry). A
    # fail-closed caller passes `probe-404` and pays one probe of the repo
    # itself to tell the two apart (TD-PPagop-26081602): only a repo the
    # token can actually see turns this into a genuine "flag file missing"
    # clear. Any probe failure — 404, 403, a timeout, anything short of
    # success — falls through to the same cached-or-unreachable handling a
    # transport failure gets below, rather than being read as clear.
    if [[ "$mode" != "probe-404" ]] || fleet_repo_visible "$repo" "$cache.repo-err"; then
      rm -f "$cache"
      printf 'clear\t'
      return 0
    fi
  fi
  if [[ -f "$cache" ]]; then
    printf 'cached\t'
    cat "$cache"
  else
    printf 'unreachable\t'
  fi
  return 0
}

# fleet_flag_fetch STATE_REPO STATE_DIR NAME
# Print the flag's raw bytes, or nothing when it is clear. Always returns 0;
# the caller cannot tell "clear" from "unreachable with no cache", which is
# the point — both read as "nothing stands you down" (see the header for why
# that is safe). fleet_flag_fetch_status above is the same fetch for the one
# caller that does need the distinction.
fleet_flag_fetch() {
  local combined
  combined="$(fleet_flag_fetch_status "$1" "$2" "$3")"
  printf '%s' "${combined#*$'\t'}"
}

# fleet_flag_write STATE_REPO NAME BODY MESSAGE
# One CAS attempt: read the current sha, PUT against it. Returns non-zero on
# a lost race or an unreachable repo — the caller decides whether to re-read
# and retry (the limit publisher does) or to warn (the disable path does).
#
# STATE_DIR is optional and does one thing: on a successful write, drop the
# body into the local cache, the way a successful fetch does. Without it the
# writer is the one node in the fleet with *no* local copy of a flag it just
# set — so if the state repo goes down in the next minute, its own reads fall
# through to "nothing stands you down" (this level fails open) while every
# peer that has fetched once reads the flag from cache and stops. The
# symmetry is already half there: fleet_flag_delete drops the cache on
# success, and this is the other half.
fleet_flag_write() {
  local repo="$1" name="$2" body="$3" msg="$4" state_dir="${5:-}" path payload sha cache
  [[ -n "$repo" ]] || return 0
  path="$(fleet_flag_path "$name")"
  payload="$(printf '%s\n' "$body" | base64 -w0)"
  sha="$(_fleet_gh api "repos/$repo/contents/$path?ref=main" --jq '.sha' 2>/dev/null || true)"
  if [[ -n "$sha" ]]; then
    _fleet_gh api -X PUT "repos/$repo/contents/$path" -f message="$msg" \
      -f content="$payload" -f branch=main -f sha="$sha" >/dev/null 2>&1 || return 1
  else
    _fleet_gh api -X PUT "repos/$repo/contents/$path" -f message="$msg" \
      -f content="$payload" -f branch=main >/dev/null 2>&1 || return 1
  fi
  if [[ -n "$state_dir" ]]; then
    cache="$(fleet_cache_file "$state_dir" "$name")"
    mkdir -p "${cache%/*}" 2>/dev/null || true
    printf '%s\n' "$body" > "$cache" 2>/dev/null || true
  fi
  return 0
}

# fleet_flag_delete STATE_REPO STATE_DIR NAME
# Clear a flag. Absent (no state repo at all, or a flag-file 404 confirmed by
# `fleet_repo_visible` — TD-PPagop-26081604) already counts as cleared;
# anything else that stops the delete returns non-zero, because "cleared"
# reported for a flag that is still set keeps the whole fleet standing down
# after the operator believes they resumed it. A successful clear also drops
# the local cache — a stale cached copy must not resurrect a flag the fleet no
# longer has.
#
# The read-for-sha's own 404 is the same ambiguous contents-API 404
# `fleet_flag_fetch_status`'s `probe-404` mode resolves for the fetch side
# (TD-PPagop-26081602): it means either "the flag file does not exist" or
# "this repository does not exist, or is invisible to this token". The fetch
# side gets to accept that collapse for its fail-open flags; the delete side
# never can, because "absent" here is a claim that the flag has been cleared,
# not merely that nothing stands the fleet down — so every 404 is probed with
# `fleet_repo_visible`, unconditionally, and only a confirmed-visible repo
# resolves to `absent`. Unlike the fetch side there is no cached copy to fall
# back to on an unresolved 404 or any other failure — the delete simply
# failed, and the caller is told so via a return of 1.
#
# Prints one word on success, distinguishing the two ways "succeeded" can
# happen — `deleted` (a flag was actually removed) or `absent` (there was
# nothing to remove) — because a caller logging the outcome (issue #426) needs
# to know which, and a bare 0 return told it only that neither counts as a
# failure. Prints nothing on a return of 1.
fleet_flag_delete() {
  local repo="$1" state_dir="$2" name="$3" path errf resp sha
  [[ -n "$repo" ]] || { printf 'absent'; return 0; }
  path="$(fleet_flag_path "$name")"
  errf="$(fleet_cache_file "$state_dir" "$name").err"
  mkdir -p "${errf%/*}" 2>/dev/null || true
  if ! resp="$(_fleet_gh api "repos/$repo/contents/$path?ref=main" 2>"$errf")"; then
    if grep -qiE 'HTTP 404|Not Found' "$errf" 2>/dev/null && fleet_repo_visible "$repo" "$errf.repo-err"; then
      rm -f "$(fleet_cache_file "$state_dir" "$name")"
      printf 'absent'
      return 0
    fi
    return 1
  fi
  sha="$(jq -r '.sha // empty' <<<"$resp" 2>/dev/null || true)"
  [[ -n "$sha" ]] || return 1
  _fleet_gh api -X DELETE "repos/$repo/contents/$path" \
    -f message="fleet: clear $name" -f branch=main -f sha="$sha" >/dev/null 2>&1 || return 1
  rm -f "$(fleet_cache_file "$state_dir" "$name")"
  printf 'deleted'
  return 0
}

# fleet_flag_write_outcome STATE_REPO NAME BODY MESSAGE [STATE_DIR]
# fleet_flag_write, translated into the `ok`/`failed`/`unconfigured`
# vocabulary the `disabled`/`enabled` log events carry as `fleet_flag` (issue
# #426): `unconfigured` when there is no state repo to write to
# (fleet_flag_write's own quiet no-op), `ok`/`failed` for a real attempt's
# result. One definition so the write side and the delete side below cannot
# drift onto different words for the same three outcomes. Every argument is
# passed through, STATE_DIR included, so a caller that wants the write to
# prime the local cache gets that here too rather than having to choose
# between the outcome word and the cache.
fleet_flag_write_outcome() {
  [[ -n "$1" ]] || { printf 'unconfigured'; return 0; }
  if fleet_flag_write "$@"; then printf 'ok'; else printf 'failed'; fi
}

# fleet_flag_delete_outcome STATE_REPO STATE_DIR NAME
# fleet_flag_delete, translated the same way: `ok` when a flag was actually
# removed, `unconfigured` when there was nothing to remove (already absent, or
# no state repo), `failed` when a flag exists but could not be cleared.
fleet_flag_delete_outcome() {
  local word
  if word="$(fleet_flag_delete "$1" "$2" "$3")"; then
    [[ "$word" == "deleted" ]] && printf 'ok' || printf 'unconfigured'
  else
    printf 'failed'
  fi
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

# fleet_limit_publish STATE_REPO STATE_DIR RESUME_AT CLASS RESET_KNOWN NODE [EVIDENCE]
# Publish a usage-limit stand-down, extend-only: a flag already resuming at
# or after RESUME_AT is left alone. Two attempts — re-read between them — so
# losing the CAS to a peer publishing the same limit converges instead of
# failing. Returns non-zero only when the flag could not be written at all;
# the caller logs that and relies on the log union to carry the signal.
#
# The record carries `kind: "auto"` and `actor` (the node), because every
# writer of this flag is a detector responding to an observed limit — and
# EVIDENCE is that observation (the API's own response, truncated), so an
# extension is always accompanied by the fresh evidence that justified it
# (requirement 2; #244). A `kind: "manual"` record only ever enters this file
# by an operator's hand, and nothing here writes or extends one.
#
# Extend-only has exactly one exception, and it is not a write: a human
# lifting the stand-down through `agent-cycle.sh --clear-limit`, which deletes
# the flag outright (requirement 2.1). Shortening it here would let a node
# that parsed a shorter reset undercut a peer's longer one, which is the race
# extend-only exists to prevent.
fleet_limit_publish() {
  local repo="$1" state_dir="$2" resume_at="$3" class="$4" reset_known="$5" node="$6"
  local evidence="${7:-}"
  local new_epoch body cur cur_at cur_epoch
  [[ -n "$repo" ]] || return 0
  new_epoch="$(date -d "$resume_at" +%s 2>/dev/null || echo 0)"
  (( new_epoch > 0 )) || return 0
  # Bounded: the flag is one small file the whole fleet re-reads every cycle,
  # and the first line of a limit message identifies it; a whole transcript
  # would not identify it better.
  evidence="${evidence:0:400}"
  body="$(jq -nc --arg r "$resume_at" --arg c "$class" --argjson k "${reset_known:-false}" \
    --arg n "$node" --arg ts "$(_toggle_iso)" --arg e "$evidence" \
    '{resume_at: $r, class: $c, reset_known: $k, node: $n, ts: $ts,
      kind: "auto", actor: $n,
      evidence: (if $e == "" then null else $e end)}')"
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
      "fleet: usage limit hit on $node — stand down until $resume_at" "$state_dir" && return 0
  done
  return 1
}
