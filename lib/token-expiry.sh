#!/usr/bin/env bash
#
# lib/token-expiry.sh — the fine-grained PAT expiry warning (agent-ops#694).
#
# GitHub states a fine-grained personal access token's own expiry on every
# API response it authenticates, in the `GitHub-Authentication-Token-
# Expiration` response header (e.g. "2026-08-22 09:35:00 UTC"). On
# 2026-08-22 ~09:35Z the fleet's tokens expired with zero warning: every
# node lost GitHub at once, misdiagnosed as an outage (agent-ops#691), and an
# operator noticed only hours later. The expiry date was knowable a month
# out — one header read a day (here, doctor.sh's own existing hourly
# cadence) would have flagged it.
#
# Out of scope: an absent header or a 401 (an already-dead token) is
# agent-ops#691's own territory, handled by `github_auth_probe`
# (lib/github-limit.sh). This file is only the warning before that cliff.
#
# The read and the escalation are deliberately split across two processes
# with different cost budgets: `scripts/doctor.sh` reads the header (a GET,
# its own read-only rule, requirement 2.6a) and writes {expires_at,
# days_remaining} into `.doctor-status.json` once an hour; `agent-cycle.sh`
# reads that file back — no GitHub call of its own — and escalates. This is
# the same split doctor.sh's fails/warns already use with the dashboard
# (`scripts/publish-dashboard.sh` reads rather than recomputes), so the one
# component with an hourly GitHub-call budget to protect is the only one
# that ever spends it.

# How many days' notice is worth a human's attention. Not a config key —
# agent-ops#694's own refinement calls this "a reasonable default, not a
# decision that needs a human" — a fixed constant shared by doctor.sh's own
# warn/ok split and agent-cycle.sh's escalation decision, so the two can
# never drift apart.
TOKEN_EXPIRY_WARN_DAYS="${TOKEN_EXPIRY_WARN_DAYS:-7}"

# token_expiry_header
# Runs `gh api rate_limit --include` — the same free, GET-only `/rate_limit`
# endpoint requirement 2.0/2.0b already read (`github_limit_snapshot`,
# `github_auth_probe`; lib/github-limit.sh) — and prints the raw
# `GitHub-Authentication-Token-Expiration` header value, or nothing if the
# call failed or the header is absent: a classic PAT, an installation token,
# or any other credential GitHub states no expiry for. A caller must read
# nothing the same "no evidence" way an unreadable `/rate_limit` snapshot
# already is elsewhere in this file's sibling, never as "expires now".
#
# `command gh`, matching lib/github-limit.sh's own convention, so a test's
# stubbed `gh` earlier on `PATH` still answers this. Not sourced through
# that file's own `gh` wrapper — this file defines no such wrapper, and
# deliberately does not source lib/github-limit.sh, so that scripts/doctor.sh
# (read-only by its own declared contract) can source this file without also
# picking up a wrapper that waits out and retries refusals.
token_expiry_header() {
  command gh api rate_limit --include 2>/dev/null \
    | tr -d '\r' \
    | grep -i '^github-authentication-token-expiration:' \
    | tail -1 \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]+$//'
}

# token_expiry_parse HEADER_VALUE [NOW_EPOCH]
# Prints "<expires_at ISO-8601 UTC>\t<days_remaining>" for a raw
# `GitHub-Authentication-Token-Expiration` header value, or nothing (and a
# non-zero exit) if it cannot be parsed as a date — which a caller must read
# the same "no evidence" way an absent header already is, never as an
# expiry of zero. `NOW_EPOCH` is exposed for tests to pin the clock; a real
# caller omits it and gets the wall clock.
#
# `days_remaining` floors toward zero rather than going negative: a token
# already past its own expiry has stopped authenticating at all, which
# `github_auth_probe` already reports (agent-ops#691's own territory, not
# this file's) — so a token with six hours left reads 0 days, not 1 and
# never -1, because "under the warning threshold" must not read a same-day
# expiry as still safe.
#
# Always newline-terminated on success, for the same reason
# `github_auth_probe` (lib/github-limit.sh) is: a caller reads this with
# `IFS=$'\t' read -r a b < <(token_expiry_parse …)`, and `read` reports
# failure — though it still populates both variables — for a final line
# with no trailing newline. A caller must not mistake that for "could not
# parse" and discard values that actually parsed fine.
token_expiry_parse() {
  local raw="${1:-}" now="${2:-}" epoch expires_at days
  [[ -n "$raw" ]] || return 1
  epoch="$(date -u -d "$raw" +%s 2>/dev/null)" || return 1
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$now" ]] || now="$(date +%s)"
  expires_at="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 1
  days=$(( (epoch - now) / 86400 ))
  (( days < 0 )) && days=0
  printf '%s\t%s\n' "$expires_at" "$days"
}

# token_expiry_escalated_for NODE EXPIRES_AT < union.jsonl
# Exit 0 when a `token-expiry-escalated` event for this NODE naming this
# exact EXPIRES_AT already exists in the log on stdin — this token's
# threshold crossing has already been escalated — and 1 otherwise.
#
# Keyed on the expiry timestamp itself rather than a run-start marker the
# way `crash_loop_escalated_since` needs one (lib/crash-loop.sh): a
# fine-grained PAT's expiry is a fixed fact about one credential, not a
# recurring failure with no natural id. A human closing the escalation issue
# without actually rotating the token must not reopen the gate — every
# cycle would then refile it until the token is rotated. The gate reopens
# only once the token actually is rotated, which is exactly when
# EXPIRES_AT changes.
token_expiry_escalated_for() {
  local node="$1" expires_at="$2" hits
  hits="$(jq -r -R -s --arg n "$node" --arg e "$expires_at" '
    [ splits("\n") | select(length > 0) | (fromjson? // empty)
      | select(.event == "token-expiry-escalated"
               and (.node // "") == $n
               and (.expires_at // "") == $e) ]
    | length
  ' 2>/dev/null || echo 0)"
  [[ "$hits" =~ ^[0-9]+$ ]] && (( hits > 0 ))
}
