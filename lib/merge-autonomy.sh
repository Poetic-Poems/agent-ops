#!/usr/bin/env bash
#
# lib/merge-autonomy.sh — the `merge_autonomy` trust ladder (D18,
# docs/reviews/2026-08-14-autonomy-investigation.md §5.1) and its fleet-wide
# kill switch (§6, WI-2 of umbrella #402).
#
# `merge_autonomy` is a top-level config key with a per-repo override inside
# `repos[]` — the `stage_timeouts`/`stage_inactivity` precedence pattern
# (requirement 4f) applied to one scalar instead of a per-actor object: a
# repo's own entry wins when present, the top-level key otherwise, `human`
# (today's behaviour, byte-for-byte) failing that. `merge_autonomy_configured_level`
# is that resolution and nothing else — it does not know about the kill
# switch below.
#
# The kill switch forces every repo to `human` immediately, fleet-wide,
# without touching `config.json` or restarting a container — the "something
# is landing that should not be" lever WI-5/WI-7's own gates cannot
# substitute for, since it has to work even if the classifier or the Approver
# stage itself is what is misbehaving. It reuses `lib/toggle.sh`'s generic
# fleet-flag machinery outright (`fleet_flag_fetch_status`/`_write`/`_delete`,
# the same CAS-guarded contents-API file `fleet/disabled.json` already uses one
# level up) under its own flag name, `fleet/merge-autonomy-kill.json`, rather
# than the pipeline's own `disabled` flag: killing merge autonomy must not
# stop cycles running, only force every level back to `human`, and the two
# concerns need independent switches or an operator could never disable one
# without the other. `merge_autonomy_effective_level` is the one function
# that knows about both — every future WI that arms an approval or a landing
# must call it, never `merge_autonomy_configured_level` directly, so the kill
# switch actually overrides what it promises to.
#
# `run_approver_stage` (WI-5, the Approver stage) and `run_landing_stage`
# (WI-7, the arming step, requirement 8d) are this file's two
# behaviour-affecting callers of `merge_autonomy_effective_level` —
# `scripts/doctor.sh` is a third, but it validates the *configured* level,
# deliberately ignoring the kill switch (see its own comment): a config that
# is invalid the moment the switch is cleared is worth failing on now, not
# only once someone clears it. The kill switch's own read fails closed on a
# fresh node that cannot reach the state repo (TD-PPagop-26081507, see
# merge_autonomy_kill_state below) — a defence written at WI-2, before either
# real caller existed, on the reasoning that the day they would was already
# certain and a node answering the wrong thing on that day is the one this
# switch exists to prevent.
#
# WI-6 (D18 §5.4, `docs/reviews/2026-08-14-autonomy-investigation.md`,
# `lib/merge-budget.sh`) adds a second, narrower override alongside the kill
# switch: a per-repo merge-budget freeze caps `merge_autonomy_effective_level`
# at `agent-approves` — never all the way to `human` — for the one repo the
# freeze names, when a counting anomaly shows more pull requests landed in a
# rolling 24h window than `merge_budget_per_day` ever permitted. The kill
# switch is checked first and still wins outright: a repo already forced to
# `human` gains nothing from also being frozen. See lib/merge-budget.sh's own
# header for the freeze's flag shape and why its own reachability, unlike the
# kill switch's, fails open.

# shellcheck source=lib/toggle.sh
# shellcheck source=lib/merge-budget.sh
# (Sourced by every caller of this file already; the functions below —
# fleet_flag_fetch_status, fleet_flag_write_outcome, fleet_flag_delete_outcome,
# _toggle_eval, _toggle_iso, toggle_actor — come from lib/toggle.sh, and
# merge_budget_freeze_state comes from lib/merge-budget.sh, not from here.)

MERGE_AUTONOMY_LEVELS=(human agent-approves agent-merges-routine agent-merges-all)
MERGE_AUTONOMY_KILL_FLAG="merge-autonomy-kill"

# merge_autonomy_rank LEVEL
# The ladder position of LEVEL (0 = human), or nothing at all for a value
# outside MERGE_AUTONOMY_LEVELS — the schema is what rejects a bad level;
# this only ever compares two already-valid ones.
merge_autonomy_rank() {
  local level="$1" i
  for i in "${!MERGE_AUTONOMY_LEVELS[@]}"; do
    if [[ "${MERGE_AUTONOMY_LEVELS[$i]}" == "$level" ]]; then
      printf '%d' "$i"
      return 0
    fi
  done
  return 1
}

# merge_autonomy_configured_level CONFIG_JSON SLUG
# The level `config.json` (already schema-defaulted, or not — an absent
# top-level key reads as "human" either way) names for SLUG: that repo's own
# `merge_autonomy` entry in `repos[]` when set, else the top-level key, else
# `human`. Pure config resolution — see the header for why the kill switch is
# a separate function rather than folded in here.
merge_autonomy_configured_level() {
  local config_json="$1" slug="$2" repo_level top_level
  repo_level="$(jq -r --arg slug "$slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_autonomy // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_level" && "$repo_level" != "null" ]]; then
    printf '%s' "$repo_level"
    return 0
  fi
  top_level="$(jq -r '.merge_autonomy // "human"' <<<"$config_json" 2>/dev/null)"
  [[ -n "$top_level" && "$top_level" != "null" ]] || top_level="human"
  printf '%s' "$top_level"
}

# merge_autonomy_resolution_source CONFIG_JSON SLUG
# Which of `merge_autonomy_configured_level`'s two inputs actually produced
# SLUG's configured level: `repo-override` when SLUG's own `repos[]` entry
# sets `merge_autonomy`, `top-level-default` otherwise (including the
# hard-coded `human` fallback nobody configured at all). Pure config
# resolution, mirroring `merge_autonomy_configured_level`'s own precedence
# exactly rather than threaded out of that function — every existing caller
# of the level wants only the level, and the one caller that also wants the
# source (the D18 landing audit record, requirement 8x, agent-ops#578) reads
# it here instead, at gate 1 of `_landing_stage_attempt`. Read only once that
# gate has already confirmed the effective level is `agent-merges-routine` or
# `agent-merges-all` — at that point the kill switch is known clear and no
# budget freeze can be binding (both cap at `agent-approves` or below), so
# the configured/effective split is the only source distinction left to draw;
# this function does not itself re-check either flag.
merge_autonomy_resolution_source() {
  local config_json="$1" slug="$2" repo_level
  repo_level="$(jq -r --arg slug "$slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_autonomy // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_level" && "$repo_level" != "null" ]]; then
    printf 'repo-override'
  else
    printf 'top-level-default'
  fi
}

# merge_autonomy_kill_state STATE_REPO STATE_DIR [FRESH] [RETRY]
# The kill switch, in toggle_state's own vocabulary
# (`{"state":"enabled"}` / `{"state":"disabled","record":{...}}`) — "enabled"
# here means merge autonomy runs at its configured level; "disabled" means
# the switch has forced everything to `human`. Diverges from
# fleet_disabled_state in exactly one failure direction (TD-PPagop-26081507):
# an unreachable state repo falls back to the last-fetched cache same as
# every other fleet flag, but with no cache at all — a fresh node, or one
# whose cache never held a copy because the flag has never been set — this
# resolves to "disabled", not "enabled". That confines the fail-closed blast
# radius (a state-repo outage silently forcing every repo to `human`) to
# exactly the population that cannot know whether an operator has pulled the
# lever, and is the one caller of fleet_flag_fetch_status in this codebase
# that needs the distinction — see its own comment in lib/toggle.sh for why
# fleet_disabled_state and the limit flag are unaffected and still fail open.
# "Unreachable" covers two cases underneath, both fail-closed here: a
# transport-level failure fetching the flag file itself, and a repo-level 404
# — the state repo missing, or invisible to this token — which the `probe-404`
# mode this caller (alone in the codebase) asks of fleet_flag_fetch_status
# tells apart from the flag file's own 404 (TD-PPagop-26081602). Only a probe
# that confirms the repo is visible reads as clear; a misconfigured
# state_repo slug or a token whose scopes lost access now fails closed the
# same as a DNS failure would.
# present-but-garbage reads as set, not clear, the same as every other flag
# lib/toggle.sh evaluates.
#
# The synthesised fail-closed record names itself — `kind: "fail-closed"`,
# written here and nowhere else — so a reader can tell "nobody could read the
# switch" from "somebody set the switch" without inferring it from the
# absence of `kind: "manual"`: a flag file set by hand through GitHub's web
# editor, and the present-but-garbage record above, are both genuine kills
# and neither carries a `kind` at all (scripts/doctor.sh is the reader that
# needs this).
#
# FRESH (issue #513, PR #506 review follow-up) is threaded straight through
# to `fleet_flag_fetch_status`'s own FRESH: a non-empty value skips this
# process's memo of the switch and always asks GitHub, for a caller that is
# about to act on the answer rather than merely compute with it. Leave it
# empty for every advisory read — the back-pressure count and
# `void_obsolete_ctx_json` both do, and stay memoised.
#
# RETRY (agent-ops#1081) opts into one further attempt when the read fails
# closed with no cached copy at all — the fresh-node case the header above
# and TD-PPagop-26081507 already fail closed for. A lone rate-limited
# refusal is by far the common cause of that (agent-ops#1101's own three call
# sites hit the identical shape on the same node within the hour): before
# returning the fail-closed record, a non-empty RETRY classifies whatever
# `fleet_flag_fetch_status` left in `$cache.err` via `github_limit_kind`
# (lib/github-limit.sh — reused, not reclassified) and, only when the cause
# was rate-limiting, waits out `github_limit_wait_plan`'s own wait/backoff
# and asks GitHub once more. Empty (the default) preserves this function's
# exact prior behaviour for every caller that does not pass it —
# `scripts/doctor.sh`, `lib/manage.sh`, `scripts/publish-dashboard.sh` and
# `landing_autonomy_refusal_reason`'s own diagnostic re-read all leave this
# unset, since a wait of up to a minute has no business inside a status
# report or a heartbeat-budgeted dashboard tick. `run_approver_stage`
# (lib/approver.sh) is the one caller that opts in — the stage that posts a
# real GitHub review under this answer, and had no retry of its own at all
# before this.
#
# Every returned document now also carries a top-level `retried` boolean —
# `true` iff RETRY was passed *and* the wait/retry was actually taken (never
# merely requested — a non-rate-limit cause, or one not worth waiting for,
# leaves this `false`), `false` otherwise (including every call that never
# passes RETRY at all, so no existing caller sees a shape it did not already
# handle). A caller telling a fail-closed `human` apart from a genuinely
# configured or manually killed one still reads `.record.kind` exactly as
# before — a global would not survive this function being called inside a
# `$(...)` command substitution (every real call site's own shape, needed to
# capture the printed document at all), which a subshell's own writes to a
# process-wide variable never reach the caller back — so both facts travel
# in the one document this function already returns, never a side channel.
merge_autonomy_kill_state() {
  local repo="$1" state_dir="$2" fresh="${3:-}" retry="${4:-}"
  local combined status raw retried_bool="false"
  combined="$(fleet_flag_fetch_status "$repo" "$state_dir" "$MERGE_AUTONOMY_KILL_FLAG" probe-404 "$fresh")"
  # Parameter expansion, not `IFS=$'\t' read` — see fleet_flag_fetch_status's
  # own comment: RAW is a file from the state repository and may be several
  # lines, which a `read` would truncate to the first one.
  status="${combined%%$'\t'*}"
  raw="${combined#*$'\t'}"
  if [[ -z "$raw" && "$status" == "unreachable" && -n "$retry" ]]; then
    local cache cause kind now reset_epoch wait
    cache="$(fleet_cache_file "$state_dir" "$MERGE_AUTONOMY_KILL_FLAG")"
    cause="$(cat "${cache}.err" 2>/dev/null || true)"
    kind="none"
    declare -F github_limit_kind >/dev/null 2>&1 && kind="$(github_limit_kind "$cause")"
    if [[ "$kind" != "none" ]] && declare -F github_limit_wait_plan >/dev/null 2>&1; then
      now="$(date +%s)"
      reset_epoch=0
      if [[ "$kind" == "primary" ]] && declare -F github_limit_primary_reset_epoch >/dev/null 2>&1; then
        reset_epoch="$(github_limit_primary_reset_epoch "$now")"
      fi
      wait="$(github_limit_wait_plan "$kind" "$reset_epoch" "$now" "${GITHUB_LIMIT_WAITED_SECONDS:-0}")"
      if [[ -n "$wait" ]]; then
        retried_bool="true"
        sleep "$wait"
        GITHUB_LIMIT_WAITED_SECONDS=$(( ${GITHUB_LIMIT_WAITED_SECONDS:-0} + wait ))
        combined="$(fleet_flag_fetch_status "$repo" "$state_dir" "$MERGE_AUTONOMY_KILL_FLAG" probe-404 "$fresh")"
        status="${combined%%$'\t'*}"
        raw="${combined#*$'\t'}"
      fi
    fi
  fi
  if [[ -z "$raw" ]]; then
    if [[ "$status" == "unreachable" ]]; then
      jq -nc --argjson r "$retried_bool" \
        '{state: "disabled", retried: $r, record: {reason: "state repo unreachable and no cached copy of the kill switch — failing closed to human until a fetch succeeds (TD-PPagop-26081507)", expires_at: null, by: "", disabled_at: "", kind: "fail-closed"}}'
      return 0
    fi
    jq -nc --argjson r "$retried_bool" '{state: "enabled", retried: $r}'
    return 0
  fi
  jq -c --argjson r "$retried_bool" '. + {retried: $r}' <<<"$(_toggle_eval "$raw" present)"
}

# merge_autonomy_kill_set STATE_REPO REASON BY [ACTOR]
# Set the kill switch and print the fleet_flag_write_outcome word
# (ok/failed/unconfigured). No `expires_at`: unlike a `--disable` stand-down,
# this is described as "a permanent operational control, not scaffolding"
# (docs/reviews/2026-08-14-autonomy-investigation.md §6) — indefinite until
# `merge_autonomy_kill_clear`, never a TTL an operator might forget was
# shorter than they meant.
merge_autonomy_kill_set() {
  local state_repo="$1" reason="$2" by="$3" actor="${4:-}" body
  [[ -n "$actor" ]] || actor="$(toggle_actor)"
  body="$(jq -nc --arg at "$(_toggle_iso)" --arg by "$by" --arg r "$reason" \
    --arg actor "$actor" \
    '{disabled_at: $at, expires_at: null, by: $by, reason: $r,
      actor: $actor, kind: "manual"}')"
  fleet_flag_write_outcome "$state_repo" "$MERGE_AUTONOMY_KILL_FLAG" "$body" \
    "fleet: merge-autonomy kill switch set by $by — $reason"
}

# merge_autonomy_kill_clear STATE_REPO STATE_DIR
# Clear the kill switch and print the fleet_flag_delete_outcome word
# (ok/failed/unconfigured).
merge_autonomy_kill_clear() {
  fleet_flag_delete_outcome "$1" "$2" "$MERGE_AUTONOMY_KILL_FLAG"
}

# merge_autonomy_effective_level CONFIG_JSON SLUG STATE_REPO STATE_DIR [FRESH] [RETRY]
# What SLUG is actually governed by right now: `human` whenever the kill
# switch is set (or its own state cannot be read as clear — see
# merge_autonomy_kill_state); else, capped at `agent-approves` whenever
# SLUG's own merge-budget freeze is set (D18 WI-6,
# `merge_budget_freeze_state`, lib/merge-budget.sh — sourced by every caller
# of this file already, see that file's own header) and the configured
# level ranks above it; else merge_autonomy_configured_level unchanged. This
# is the function every future arming/approval path must call — the kill
# switch and the per-repo freeze both only actually override anything
# because every such path reads this function and never
# merge_autonomy_configured_level directly.
#
# The rank is checked before the freeze flag is ever fetched (PR #499 review
# follow-up): the freeze can only lower a level that ranks above
# agent-approves, so a repository configured at agent-approves or below never
# needs the freeze's own answer — its value would go unread either way. A
# repository governed at `human` (requirement 2's own default, and every
# repository's until an operator opts one up) is the common case this skips
# a fetch for on every single read.
#
# FRESH (issue #513, PR #506 review follow-up) reaches *both* flag reads — the
# kill switch's and the per-repo freeze's. An acting site must see either one
# set from outside this process at the moment it decides rather than replaying
# the answer this cycle's first read memoised (requirement 2.3a):
# `run_approver_stage` was the one such site when FRESH arrived, D18 WI-7's
# arming step is the second, and this function is what both of them read, so a
# freeze that bound only on the next cycle would quietly break the promise the
# arming step's own eligibility bullet makes. A caller passing no FRESH is
# unaffected — both reads stay memoised, leaving the back-pressure loop's N→1
# saving (PR #499 review follow-up, asserted in
# test/backpressure-wiring.test.sh) untouched — and the rank check below still
# skips the freeze fetch outright for every repository at `agent-approves` or
# below, fresh or not.
# RETRY (agent-ops#1081) is threaded straight through to
# `merge_autonomy_kill_state`'s own RETRY — see that function's header for
# what it does and why every caller but `run_approver_stage` leaves it
# unset. This function still returns one word, never a cause: a caller that
# needs to distinguish a fail-closed `human` from a genuinely configured or
# manually killed one calls `merge_autonomy_kill_state` itself instead of
# this function (`run_approver_stage` does, ahead of this one) and reads
# `.record.kind` off its own returned document.
merge_autonomy_effective_level() {
  local config_json="$1" slug="$2" state_repo="$3" state_dir="$4" fresh="${5:-}" retry="${6:-}"
  local kill_state configured configured_rank cap_rank freeze_state
  kill_state="$(jq -r '.state' <<<"$(merge_autonomy_kill_state "$state_repo" "$state_dir" "$fresh" "$retry")" 2>/dev/null)"
  if [[ "$kill_state" != "enabled" ]]; then
    printf 'human'
    return 0
  fi
  configured="$(merge_autonomy_configured_level "$config_json" "$slug")"
  configured_rank="$(merge_autonomy_rank "$configured" 2>/dev/null)" || configured_rank=0
  cap_rank="$(merge_autonomy_rank agent-approves)"
  if (( configured_rank > cap_rank )); then
    freeze_state="$(jq -r '.state' <<<"$(merge_budget_freeze_state "$state_repo" "$state_dir" "$slug" "$fresh")" 2>/dev/null)"
    if [[ "$freeze_state" != "enabled" ]]; then
      printf 'agent-approves'
      return 0
    fi
  fi
  printf '%s' "$configured"
}
