#!/usr/bin/env bash
#
# lib/drain.sh — at-rest detection and reporting for the `--drain` switch
# mode (requirement 2.9). `lib/toggle.sh` owns the switch itself, including
# the `mode` field a `--drain` record carries (requirement 2.3d); this file
# is everything downstream of "a drain is active", read only by
# `agent-cycle.sh` and the management/status/dashboard/heartbeat readers of
# its output — never by `review-cycle.sh`, which has no finishing set of its
# own and stands down under either mode exactly as it always has (requirement
# R2a, docs/REVIEW-PIPELINE-SPEC.md).
#
# "At rest" (2.2a's own finishing set, applied unconditionally rather than
# only when back-pressure trips): every repo's four finishing bands —
# `review_feedback`, `merge_conflicts`, `dequeued`, `abandoned_drafts` — are
# empty, *and* no live claim (requirement 17a) names a finishing-source ref.
# The second half exists because a claim can be taken moments before its PR
# is opened; a cycle's own gather sees no PR yet, but the work is not
# actually finished, and a `drained` event fired on that gap would be a false
# "we are done" for anyone watching the dashboard for it.
#
# Sourced by agent-cycle.sh, after lib/toggle.sh (for `_toggle_iso`) and
# lib/claim.sh (for `do_claims`) and lib/fleet.sh (for `fleet_logs`) — none of
# which this file re-sources, since `#771`'s own convention is that
# agent-cycle.sh sources every lib/*.sh once into one process and each file
# documents what it needs rather than fetching it itself.

# A finishing-source claim ref, per requirement 17a: `pr-<n>-review-…`,
# `pr-<n>-conflict-…`, `pr-<n>-dequeued-…`, `pr-<n>-abandoned-…`.
_drain_finishing_ref_pattern='^pr-[0-9]+-(review|conflict|dequeued|abandoned)-'

# drain_live_finishing_claims REPOS_JSON
# Every live claim, across every repo named in REPOS_JSON (an `.[].slug`
# array — the same shape ordered_repos_json/all_repos_json already carry),
# whose `item` names a finishing-source ref. One `lib/claim.sh claims` call
# per repo — the same per-repo listing the Script already pays for elsewhere
# in the cycle (requirement 3o) — filtered down to the four finishing kinds.
# `lib/claim.sh` is a standalone script, not sourced (#771's own split keeps
# claim-taking out of the long-lived cycle process), so this shells out to it
# exactly as every other claim-listing call site does; `CLAIM_GH` passes
# through whatever `gh` override the caller's environment already set (the
# test suite's own stub), since a subprocess does not inherit a sourced
# function's `TOGGLE_GH`-style substitution any other way.
drain_live_finishing_claims() {
  local repos_json="${1:-[]}" slug claims out='[]'
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    claims="$("$AGENT_OPS_ROOT/lib/claim.sh" claims "$slug" 2>/dev/null || printf '[]')"
    out="$(jq -c --argjson a "$out" --arg slug "$slug" --arg pat "$_drain_finishing_ref_pattern" \
      '$a + [.[] | select(.item | test($pat)) | {slug: $slug, item, kind}]' \
      <<<"$claims" 2>/dev/null || printf '%s' "$out")"
  done < <(jq -r '.[].slug' <<<"$repos_json" 2>/dev/null)
  printf '%s' "$out"
}

# drain_remaining_count REPOS_JSON
# How many finishing-source items a drain is still waiting on: the larger of
# (a) the four finishing bands' combined length in REPOS_JSON and (b) the
# live finishing-claim count above. Not a sum — the common case is a claim
# whose PR this same cycle's gather already counted in (a), and adding both
# would double it — so this is a floor on how much work remains, not an exact
# count; a claim outstanding with no matching band entry yet (the gap the
# header describes) still surfaces, because the claim count alone exceeds the
# (zero) band count in that case.
drain_remaining_count() {
  local repos_json="${1:-[]}" band_count claim_count
  band_count="$(jq '[.[].review_feedback[]?, .[].merge_conflicts[]?, .[].dequeued[]?, .[].abandoned_drafts[]?] | length' \
    <<<"$repos_json" 2>/dev/null)"
  [[ "$band_count" =~ ^[0-9]+$ ]] || band_count=0
  claim_count="$(jq 'length' <<<"$(drain_live_finishing_claims "$repos_json")" 2>/dev/null)"
  [[ "$claim_count" =~ ^[0-9]+$ ]] || claim_count=0
  printf '%d' "$(( band_count > claim_count ? band_count : claim_count ))"
}

# drain_at_rest REPOS_JSON
# "1" iff drain_remaining_count is zero, "0" otherwise.
drain_at_rest() {
  [[ "$(drain_remaining_count "$1")" == "0" ]] && printf '1' || printf '0'
}

# drain_state_file STATE_DIR
drain_state_file() { printf '%s/drain-state.json' "$1"; }

# drain_write_state STATE_DIR DISABLED_AT REMAINING AT_REST
# Cache the last cycle's own at-rest check, so --status, the heartbeat and
# the dashboard can report "draining (N left)"/"drained" instantly rather
# than paying a fresh gather — the same reason fleet-cache exists for the
# fleet switch (lib/toggle.sh). Written only by a cycle that actually ran the
# check (agent-cycle.sh, while draining); a stale file from a since-cleared
# drain is told apart by its `disabled_at` no longer matching the live
# record's — readers key on that, not merely on the file's presence.
drain_write_state() {
  local state_dir="$1" disabled_at="$2" remaining="$3" at_rest="$4" f
  f="$(drain_state_file "$state_dir")"
  mkdir -p "$state_dir"
  jq -n --arg d "$disabled_at" --argjson r "$remaining" --argjson ar "$([[ "$at_rest" == 1 ]] && echo true || echo false)" \
    --arg ts "$(_toggle_iso)" \
    '{disabled_at: $d, remaining: $r, at_rest: $ar, checked_at: $ts}' > "$f"
}

# drain_read_state STATE_DIR
# The cached record above, or `null` if none exists yet (no drain-carrying
# cycle has run on this node since the state directory was last empty).
drain_read_state() {
  local f
  f="$(drain_state_file "$1")"
  [[ -f "$f" ]] && cat "$f" 2>/dev/null || printf 'null'
}

# drain_status_line STATE_DIR RECORD
# The `--status` line naming where a drain has got to, given the switch
# RECORD already known to carry `mode: "drain"` (toggle_status_report's own
# caller checks that). Falls back honestly when no cached check exists yet —
# a freshly-issued drain has not had a cycle run against it, and guessing a
# count would be worse than saying so.
drain_status_line() {
  local state_dir="$1" record="$2" disabled_at cached cached_at remaining at_rest
  disabled_at="$(jq -r '.disabled_at // ""' <<<"$record")"
  cached="$(drain_read_state "$state_dir")"
  if [[ "$cached" == "null" ]] || [[ "$(jq -r '.disabled_at // ""' <<<"$cached")" != "$disabled_at" ]]; then
    printf 'drain:    no cycle has checked yet — remaining work unknown until the next one runs\n'
    return 0
  fi
  remaining="$(jq -r '.remaining // 0' <<<"$cached")"
  at_rest="$(jq -r '.at_rest // false' <<<"$cached")"
  cached_at="$(jq -r '.checked_at // "?"' <<<"$cached")"
  if [[ "$at_rest" == "true" ]]; then
    printf 'drain:    DRAINED — at rest as of %s; waiting for --enable or expiry\n' "$cached_at"
  else
    printf 'drain:    DRAINING — %s finishing-source item(s) left, as of %s\n' "$remaining" "$cached_at"
  fi
}

# drain_event_logged UNION_LOG_JSONL DISABLED_AT
# "1" iff UNION_LOG_JSONL (fleet_logs' own output — one JSON object per line)
# already carries a `drained` event keyed on DISABLED_AT, "0" otherwise. Slurp
# rather than stream (`jq -s`): the union log this reads is the same one
# `current_limit_record`/`landing_approver_adjudication_history` already
# slurp for their own once-per-record dedup, and this is the same shape of
# check.
drain_event_logged() {
  local union="$1" disabled_at="$2" n
  n="$(jq -s --arg d "$disabled_at" \
    '[.[] | select(.event == "drained" and .disabled_at == $d)] | length' \
    <<<"$union" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && printf '1' || printf '0'
}
