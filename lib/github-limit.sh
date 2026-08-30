#!/usr/bin/env bash
#
# lib/github-limit.sh — GitHub's own rate limits: the budget check that decides
# whether a cycle is worth starting, and the `gh` wrapper that waits out a
# refusal instead of failing on it.
#
# Not to be confused with lib/limit-detect.sh, which is about *Claude's* usage
# limits. The two are unrelated systems that happen to share a word, and the
# distinction is worth stating because the handling differs in the one way that
# matters: a Claude limit's reset time is often unknown and has to be probed,
# whereas GitHub states its reset on every single response. Nothing here ever
# guesses a reset time, and nothing here ever needs to.
#
# ## Why this exists
#
# On 2026-08-12 both nodes exhausted the GraphQL budget within the same hour.
# What that cost was not the failed calls — it was everything the pipeline did
# either side of them. `ockham-2` logged seven consecutive sweep warnings, each
# a source degrading to "could not list … — skipping this pass";
# `ockham-container` ran a full Co-Ordinator engagement, took a claim, and then
# died at `gh repo clone` with `GraphQL: API rate limit already exceeded for
# user ID 2049303`. The model tokens were spent before the cycle discovered it
# could not read GitHub.
#
# Two mechanisms follow from that, and they divide the problem by reset
# distance rather than by call site:
#
#   - `github_limit_verdict` — the cycle-start budget check (requirement 2.0).
#     A *primary* limit resets on the hour boundary GitHub chose, which is
#     minutes to an hour away: far too long to wait inside a cycle, and the
#     right answer is to stand the cycle down before it spends anything.
#   - `gh` (the wrapper below) — a *secondary* limit, or a primary one whose
#     reset happens to be seconds away, is a short wait, and the right answer
#     is to take it and retry rather than degrade a work source to `[]`.
#
# A third failure shares the same free call but not its shape: on 2026-08-22 a
# node's `GH_TOKEN` expired mid-day, and every cycle for the next ~3 hours ran
# a full Co-Ordinator engagement before every claim failed with `cause:
# "unreachable"` — five cycles, $1.05, for a token that was never going to
# start working again on its own (agent-ops#691). `github_limit_verdict`'s own
# `unknown` folds a 401 in with a network blip on purpose (neither is evidence
# about the *budget*), so pulling it back out needed a probe of its own —
# `github_auth_probe`, checked ahead of the budget verdict for the same
# "before it spends anything" reason.
#
# ## Why the meter is read from response headers, not from `GET /rate_limit`
#
# `GET /rate_limit` is exempt from the limits it reports, which made it the
# obvious probe when this file was written (2026-08-12: a metered call
# bracketed by two of them moved `core.used` by exactly one). It is also, read
# cold, not a reading. On 2026-08-30 three metered calls seven seconds apart,
# each followed within the same second by the endpoint, showed the response
# headers draining the shared user bucket — `x-ratelimit-used` 92, 105, 118
# against one fixed `x-ratelimit-reset` — while the endpoint's body answered
# `used: 0, remaining: 5000` every time, with a `reset` exactly 3600 s from
# *now* and sliding with the clock; the endpoint's own `x-ratelimit-*` headers
# said the same. It is intermittently right (one read immediately after a
# metered call by the same token showed the true aggregate), and nothing in
# the answer says which kind it is. The cycle-start check's snapshot was the
# first call a cycle made, so it read that empty window essentially always,
# answered `ok`, and fired zero times across 95 recorded refusals in 48 hours
# (agent-ops#1087).
#
# The `x-ratelimit-*` headers on any *metered* response are computed on the
# request and describe the bucket GitHub enforces — the user's aggregate, so
# the whole fleet's, the publisher's and the owner's own shell together — and
# GraphQL's `rateLimit` object is the same kind of reading for that pool. So
# `github_limit_snapshot` spends one `core` point (`GET /meta`,
# `GITHUB_LIMIT_PROBE_PATH`) and one GraphQL point per reading, and builds
# from the two the same `{resources: {core, graphql}}` document the verdict
# always consumed. A body-shaped snapshot that carries the empty-window
# signature — `remaining == limit`, nothing used, `reset` within
# `GITHUB_LIMIT_PRISTINE_SLACK` seconds of now + 3600 — is classified
# `unknown`, never `ok` (`github_limit_resource_pristine`), so a caller that
# still hands the verdict an endpoint body cannot be told the bucket is full
# by a document that says nothing. `GET /rate_limit` remains what the
# credential probe (2.0b) and the token-expiry read use: both want the call's
# status and headers, not its budget figures.
#
# ## The record (requirement 2.0d)
#
# `github_budget_record` takes a snapshot and logs it as a `github-budget`
# event — at cycle start (the same reading the verdict judges), after every
# model stage (`lib/stage-run.sh`) and at cycle end — carrying both pools'
# `limit/used/remaining/reset` and `since_previous`, the bucket's movement
# since this process's last reading. That movement is the *bucket's*, not this
# node's: while every node authenticates as one user (D25 unprovisioned) the
# figure is an upper bound on what the segment itself spent, exact only once
# identities are per node or a per-call ledger exists (agent-ops#1084).
# `scripts/github-budget-report.sh` sums the events. This is the measurement
# D25 names as the trigger for a per-node App — "until the shared budget is
# *measured* to bind".

# Sourced by the pipelines, `lib/claim.sh` and the `scripts/gather-*`,
# `scripts/sweep-*` family — see the wrapper's own header for what sourcing it
# does to a script.

# ## Bounding what one listing may cost, and noticing when it truncates
#
# `gh pr list` asks GraphQL for `--limit` pull requests and is charged for the
# nodes it *asks* for, not the ones that come back: measured 2026-08-12 against
# a repository with three open pull requests, `--json number,commits` cost 3
# points at `--limit 3`, 10 at `--limit 10` and 30 at `--limit 30`. Every call
# in this repository inherited `gh`'s undeclared default of 30.
#
# That default is also a silent correctness bug, and the more serious half of
# this. A listing that comes back at its cap is indistinguishable from a
# complete one: `gh` says nothing, and the caller counts what it was given. The
# back-pressure gate (requirement 2.2) counts open pull requests carrying
# `pr_label` to decide whether the fleet may start more work — and pull
# requests sitting in whichever queue requirement 2.2's merge_autonomy-aware
# exclusion currently parks them in carry that label without counting against
# the cap, so the listing genuinely can exceed 30 while the gate's own sum
# stays small. Truncated, it undercounts, and the gate opens when it should
# have held.
#
# So the cap is stated rather than inherited, and every caller checks whether
# it was reached. What a caller then does with that differs by direction of
# harm, and each site says which it chose: a work source that misses a
# candidate has merely not fired this cycle, whereas a gate that undercounts
# has let work through it should have stopped.
GITHUB_PR_LIST_LIMIT="${GITHUB_PR_LIST_LIMIT:-60}"

# github_pr_list_truncated COUNT [LIMIT]
# True when a listing of COUNT items came back at the cap, and may therefore be
# missing entries. Deliberately `>=` rather than `==`: a future caller passing
# its own smaller limit must not slip past this because it asked for fewer.
github_pr_list_truncated() {
  local count="${1:-0}" limit="${2:-$GITHUB_PR_LIST_LIMIT}"
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  [[ "$limit" =~ ^[0-9]+$ ]] || return 1
  (( count >= limit ))
}

# How long one `gh` call may wait for a limit to clear before giving up, and
# how long a whole process may spend waiting across all of its calls. Both are
# bounds on lateness, not targets: the cycle runs on a 15-minute tick and holds
# a lock while it does, so a wrapper that waited out a primary limit would
# collide with the next tick. Anything longer than these is the budget check's
# problem, not the wrapper's.
GITHUB_LIMIT_MAX_WAIT_SECONDS="${GITHUB_LIMIT_MAX_WAIT_SECONDS:-60}"
GITHUB_LIMIT_TOTAL_WAIT_SECONDS="${GITHUB_LIMIT_TOTAL_WAIT_SECONDS:-120}"
# A secondary limit states no reset anywhere `gh` surfaces, so this is the one
# wait in this file that is a guess. GitHub's own guidance is to wait at least
# a minute; this is deliberately shorter because the total budget above has to
# cover more than one call.
GITHUB_LIMIT_SECONDARY_WAIT_SECONDS="${GITHUB_LIMIT_SECONDARY_WAIT_SECONDS:-20}"

# Wall-clock seconds this process has already spent waiting on rate limits.
# Module state, deliberately: the budget is per process, so a gatherer that
# meets a limit on its first call cannot spend the whole cycle's patience on
# its remaining fifty.
GITHUB_LIMIT_WAITED_SECONDS=0

# github_limit_kind TEXT
# Which class of rate-limit refusal a `gh` diagnostic describes: `secondary`,
# `primary`, or `none`. The three messages this has to recognise, as `gh`
# prints them on stderr:
#
#   REST primary       HTTP 403: API rate limit exceeded for user ID 2049303.
#   GraphQL primary    GraphQL: API rate limit already exceeded for user ID 2049303.
#   secondary          You have exceeded a secondary rate limit. Please wait …
#
# The `already exceeded` variant is GraphQL's phrasing for a request rejected
# before it was costed at all, and is the one the fleet actually met on
# 2026-08-12. Secondary is tested first because GitHub's secondary message
# contains the words "rate limit" too, and the two need different waits — a
# secondary limit states no reset anywhere to read one from.
#
# This is the only place either pattern is written. A second copy is how
# lib/limit-detect.sh's two detectors drifted apart (TD26071401), and the
# failure would be the same shape here: a wrapper that stopped recognising a
# refusal would silently go back to reporting it.
github_limit_kind() {
  local text="${1:-}"
  if grep -qiE 'secondary rate limit' <<<"$text"; then
    printf 'secondary'
  elif grep -qiE 'rate limit exceeded|rate limit already exceeded' <<<"$text"; then
    printf 'primary'
  else
    printf 'none'
  fi
}

# The metered REST call whose response headers carry the `core` meter. `/meta`
# is public, tiny, one point, and its headers were verified truthful against
# a draining bucket on 2026-08-30; a caller with a repository in hand may pass
# its own path. Not `/rate_limit`: see the header.
GITHUB_LIMIT_PROBE_PATH="${GITHUB_LIMIT_PROBE_PATH:-meta}"
# How far from an exact now + 3600 a `reset` may sit and still be read as the
# endpoint's synthetic empty window. The clock is read once here and once by
# GitHub, so a few seconds of slack; a real window's reset is fixed for the
# hour and drifts away from now + 3600 by one second per second.
GITHUB_LIMIT_PRISTINE_SLACK="${GITHUB_LIMIT_PRISTINE_SLACK:-15}"

# github_limit_headers_to_resource RAW
# RAW is `gh api -i` output — status line and headers, a blank line, the body.
# Prints the resource object `{limit, used, remaining, reset}` built from the
# `x-ratelimit-*` headers, or nothing when they are absent or not `core`'s.
# Header names are matched case-insensitively and a CR is tolerated, since
# `gh` prints the headers as GitHub sent them. A refused call (403, 404) still
# carries the headers, which is what lets the wrapper below read a reset off
# the very refusal it is handling.
github_limit_headers_to_resource() {
  local raw="${1:-}" hdrs limit used remaining reset resource
  [[ -n "$raw" ]] || return 0
  hdrs="$(printf '%s\n' "$raw" | tr -d '\r' | awk 'NF == 0 { exit } { print }' | tr '[:upper:]' '[:lower:]')"
  resource="$(sed -n 's/^x-ratelimit-resource: *//p' <<<"$hdrs" | tail -1)"
  [[ -z "$resource" || "$resource" == "core" ]] || return 0
  limit="$(sed -n 's/^x-ratelimit-limit: *//p' <<<"$hdrs" | tail -1)"
  used="$(sed -n 's/^x-ratelimit-used: *//p' <<<"$hdrs" | tail -1)"
  remaining="$(sed -n 's/^x-ratelimit-remaining: *//p' <<<"$hdrs" | tail -1)"
  reset="$(sed -n 's/^x-ratelimit-reset: *//p' <<<"$hdrs" | tail -1)"
  [[ "$used" =~ ^[0-9]+$ && "$remaining" =~ ^[0-9]+$ && "$reset" =~ ^[0-9]+$ ]] || return 0
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=null
  jq -nc --argjson l "$limit" --argjson u "$used" --argjson r "$remaining" --argjson k "$reset" \
    '{limit: $l, used: $u, remaining: $r, reset: $k}'
}

# github_limit_graphql_resource [DOC]
# The `graphql` pool's own meter: from DOC, a `{ rateLimit { limit cost used
# remaining resetAt } }` response document, or — with no argument at all —
# from that query made live (one point). Prints `{limit, used, remaining,
# reset}` with `resetAt` converted to an epoch, or nothing when unreadable.
# shellcheck disable=SC2120  # DOC is for tests and future callers; the live read passes none.
github_limit_graphql_resource() {
  local doc="${1-}"
  if (( $# == 0 )); then
    doc="$(command gh api graphql -f query='{ rateLimit { limit cost used remaining resetAt } }' 2>/dev/null)" || doc=""
  fi
  [[ -n "$doc" ]] || return 0
  jq -ec '.data.rateLimit
          | select(type == "object")
          | select((.used | type) == "number" and (.remaining | type) == "number")
          | {limit: .limit, used: .used, remaining: .remaining,
             reset: ((.resetAt // "") | try fromdateiso8601 catch null)}' <<<"$doc" 2>/dev/null || true
}

# github_limit_snapshot [PROBE_PATH]
# The budget document `github_limit_verdict` consumes — `{resources: {core:
# {limit, used, remaining, reset}, graphql: {…}}, read_at, source}` — read from
# the headers of one metered REST call and the GraphQL `rateLimit` object (see
# the header for why not `GET /rate_limit`). Either pool may be absent when
# its read failed; nothing at all, and exit 1, when both did, which the
# verdict reads as `unknown` — never grounds to stand a cycle down.
#
# `command gh`, so this reaches the binary rather than recursing into the
# wrapper below — and so a test's `PATH` stub answers it, which is the only
# substitution any caller needs. stderr is discarded because every caller's
# fallback is the same and none of them can act on the diagnosis. The probe's
# own exit status is ignored on purpose: a refused probe still answers with
# the headers, and the headers are the reading.
# shellcheck disable=SC2120  # PROBE_PATH is optional; every in-repo caller takes the default.
github_limit_snapshot() {
  local probe="${1:-$GITHUB_LIMIT_PROBE_PATH}" raw core graphql now
  now="$(date -u +%s)"
  raw="$(command gh api -i "$probe" 2>/dev/null)" || true
  core="$(github_limit_headers_to_resource "$raw")"
  # shellcheck disable=SC2119  # the live read, deliberately argument-less
  graphql="$(github_limit_graphql_resource)"
  [[ -n "$core" || -n "$graphql" ]] || return 1
  jq -nc --argjson c "${core:-null}" --argjson g "${graphql:-null}" --argjson t "$now" \
    '{resources: ((if $c then {core: $c} else {} end) + (if $g then {graphql: $g} else {} end)),
      read_at: $t, source: "headers"}'
}

# github_auth_probe
# The free `/rate_limit` call — the one `github_limit_snapshot` no longer
# reads its figures from (see the header) — kept for what it says about the
# *credentials* rather than the budget: prints
# "<verdict>\t<detail>" —
#
#   - ok            a real `/rate_limit` document came back. The token works.
#   - unauthorized  either GitHub answered HTTP 401 — it read the request and
#                   rejected the credentials outright, `detail` is its own
#                   response trimmed to one line — or `gh` never sent the
#                   request at all because it has no credentials to send:
#                   `GH_TOKEN`/`GITHUB_TOKEN` unset or empty and no `gh auth
#                   login` session either, `detail` then starts with "no token
#                   present" rather than carrying a GitHub response. Both are
#                   persistent: unlike a rate limit or a network blip, no wait
#                   and no retry clears an expired, revoked or absent token,
#                   and every call this process makes from here on fails the
#                   same way.
#   - unreachable   the call failed for any other reason (DNS, a timeout, a
#                   transient 5xx). Says nothing about the credentials — the
#                   same "no evidence" reading `github_limit_snapshot`'s
#                   plain failure already gets.
#
# Separate from `github_limit_verdict` because that verdict's `unknown` folds
# every failure together on purpose (requirement 2.0 must never mistake a
# network blip for an exhausted budget); a 401 needs pulling back out of that
# fold rather than adding a fourth case to it, and no caller of the budget
# check needs to know why the meter was unreadable, only that it was.
#
# Always newline-terminated, unlike a bare `printf '%s\t%s'` would be: a
# caller reads this with `read -r v d < <(github_auth_probe)`, and `read`
# reports failure — non-zero, though it still populates both variables —
# for a final line with no trailing newline. Sourced into scripts running
# under `set -e` (agent-cycle.sh itself foremost), so that "failure" would
# otherwise abort the whole cycle right there, every time, regardless of
# what the probe actually found.
github_auth_probe() {
  local out err rc detail
  err="$(mktemp)" || { printf 'unreachable\t\n'; return 0; }
  out="$(command gh api rate_limit 2>"$err")" && rc=0 || rc=$?
  if (( rc == 0 )) && jq -e 'type == "object" and has("resources")' <<<"$out" >/dev/null 2>&1; then
    rm -f "$err"
    printf 'ok\t\n'
    return 0
  fi
  detail="$(tr '\n' ' ' < "$err" 2>/dev/null | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//')"
  rm -f "$err"
  if grep -qiE 'HTTP 401|Bad credentials' <<<"$detail"; then
    printf 'unauthorized\t%s\n' "$detail"
  elif grep -qiE 'gh auth login' <<<"$detail"; then
    # `gh` never sent a request here — it refused locally because it has no
    # credentials at all (GH_TOKEN/GITHUB_TOKEN unset or empty, and no `gh
    # auth login` session either). Folding this into `unreachable` is the
    # fault TD-PPagop-26082306 filed: a missing token reads exactly like a
    # network blip, so a node whose token was dropped from the environment
    # still ran a full Co-Ordinator engagement every cycle before every claim
    # failed. The leading "no token present" (rather than gh's own wording,
    # which never mentions HTTP 401) is what lets a caller's stand-down
    # reason and escalation body describe the true cause instead of
    # defaulting to language written for a rejected token.
    printf 'unauthorized\tno token present (gh: %s)\n' "$detail"
  else
    printf 'unreachable\t%s\n' "$detail"
  fi
}

# github_limit_remaining SNAPSHOT RESOURCE
# Points left in `core` or `graphql`. Prints nothing when the snapshot does not
# carry that resource, which a caller must read as "unknown", never as zero.
github_limit_remaining() {
  jq -r --arg r "${2:-core}" '.resources[$r].remaining // empty' <<<"${1:-}" 2>/dev/null || true
}

# github_limit_reset_epoch SNAPSHOT RESOURCE
# When that resource's window rolls over, as a Unix epoch; nothing if unknown.
github_limit_reset_epoch() {
  jq -r --arg r "${2:-core}" '.resources[$r].reset // empty' <<<"${1:-}" 2>/dev/null || true
}

# github_limit_resource_pristine SNAPSHOT RESOURCE [NOW]
# True when that resource carries the empty-window signature `GET /rate_limit`
# answers with when read cold (see the header): `remaining == limit`, nothing
# used, and `reset` within `GITHUB_LIMIT_PRISTINE_SLACK` seconds of NOW + 3600.
# A header-derived reading can never look like this — the probe that produced
# it is itself one point used — so the verdict skips a pristine resource as
# "no evidence" rather than reading it as a full bucket.
github_limit_resource_pristine() {
  local snapshot="${1:-}" res="${2:-core}" now="${3:-}"
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date -u +%s)"
  [[ -n "$snapshot" ]] || return 1
  jq -e --arg r "$res" --argjson now "$now" --argjson slack "$GITHUB_LIMIT_PRISTINE_SLACK" '
    .resources[$r] as $x
    | ($x | type) == "object"
      and ($x.limit | type) == "number"
      and $x.remaining == $x.limit
      and (($x.used // 0) == 0)
      and ($x.reset | type) == "number"
      and (($x.reset - ($now + 3600)) | fabs) <= $slack' <<<"$snapshot" >/dev/null 2>&1
}

# github_limit_budget_fields SNAPSHOT
# The two pools as the `github-budget` event carries them: `{core: {limit,
# used, remaining, reset} | null, graphql: {…} | null}`. Pure.
github_limit_budget_fields() {
  jq -c '{core: (.resources.core // null | if . == null then null else {limit, used, remaining, reset} end),
          graphql: (.resources.graphql // null | if . == null then null else {limit, used, remaining, reset} end)}' \
    <<<"${1:-}" 2>/dev/null || printf '{"core":null,"graphql":null}'
}

# github_limit_budget_delta PREVIOUS CURRENT
# The bucket's movement between two snapshots, per pool: `{core: n | null,
# graphql: n | null, window_rolled: bool}`. Within one window it is
# `current.used - previous.used`; across a roll (the two `reset`s differ) it is
# `current.used` — a lower bound, flagged — since whatever was spent before
# the roll is gone with the old window; `null` where either side lacks a
# `used` figure or the count went backwards. Pure.
github_limit_budget_delta() {
  local prev="${1:-}" cur="${2:-}" out
  if [[ -n "$prev" && -n "$cur" ]] \
     && out="$(jq -nc --argjson p "$prev" --argjson c "$cur" '
       def d($r): ($p.resources[$r]) as $a | ($c.resources[$r]) as $b
         | if ($a | type) != "object" or ($b | type) != "object"
              or ($a.used | type) != "number" or ($b.used | type) != "number"
             then {spent: null, rolled: false}
           elif $a.reset != $b.reset then {spent: $b.used, rolled: true}
           elif $b.used >= $a.used then {spent: ($b.used - $a.used), rolled: false}
           else {spent: null, rolled: false} end;
       d("core") as $dc | d("graphql") as $dg
       | {core: $dc.spent, graphql: $dg.spent, window_rolled: ($dc.rolled or $dg.rolled)}' 2>/dev/null)" \
     && [[ -n "$out" ]]; then
    printf '%s' "$out"
  else
    printf '{"core":null,"graphql":null,"window_rolled":false}'
  fi
}

# The last snapshot this process recorded, for `since_previous`; and whether
# a cycle-start reading has been taken, which is what lets the cycle-end
# reading stay silent for an ending that never read GitHub at all (a disabled
# switch must cost nothing, requirement 2.3).
GITHUB_BUDGET_LAST_SNAPSHOT="${GITHUB_BUDGET_LAST_SNAPSHOT:-}"
GITHUB_BUDGET_CYCLE_OPEN="${GITHUB_BUDGET_CYCLE_OPEN:-0}"

# github_budget_record PHASE [STAGE]
# Take a snapshot and log it as a `github-budget` event (requirement 2.0d):
# `{phase: cycle-start | stage | cycle-end, stage?, readable, core, graphql,
# since_previous}`. Needs the sourcing script's `log_event`; without one it
# does nothing, and it never fails its caller. The snapshot is left in
# `GITHUB_BUDGET_LAST_SNAPSHOT` so the cycle-start verdict judges the very
# reading that was recorded rather than paying for a second one.
github_budget_record() {
  local phase="${1:-}" stage="${2:-}" snap fields delta
  declare -F log_event >/dev/null 2>&1 || return 0
  [[ "$phase" != "cycle-start" ]] || GITHUB_BUDGET_CYCLE_OPEN=1
  # shellcheck disable=SC2119  # the default probe, deliberately
  snap="$(github_limit_snapshot 2>/dev/null || true)"
  if [[ -z "$snap" ]]; then
    log_event "github-budget" "$(jq -nc --arg p "$phase" --arg s "$stage" \
      '{phase: $p, readable: false} + (if $s == "" then {} else {stage: $s} end)')" || true
    return 0
  fi
  fields="$(github_limit_budget_fields "$snap")"
  delta="$(github_limit_budget_delta "$GITHUB_BUDGET_LAST_SNAPSHOT" "$snap")"
  log_event "github-budget" "$(jq -nc --arg p "$phase" --arg s "$stage" --argjson f "$fields" --argjson d "$delta" \
    '{phase: $p, readable: true} + (if $s == "" then {} else {stage: $s} end) + $f + {since_previous: $d}')" || true
  GITHUB_BUDGET_LAST_SNAPSHOT="$snap"
  return 0
}

# github_limit_verdict SNAPSHOT MIN_CORE MIN_GRAPHQL
# The cycle-start budget check, pure: prints
# "<verdict>\t<resource>\t<remaining>\t<reset_at>".
#   - ok         both resources hold at least their floor. `resource` is empty.
#   - exhausted  one or both are below. `resource` names the binding one, and
#                `reset_at` is a real ISO-8601 UTC time GitHub stated — never
#                an estimate, so a caller may treat it as a deadline.
#   - unknown    the snapshot is missing or unreadable — or carries nothing but
#                the endpoint's empty-window answer (`github_limit_resource_pristine`).
#                Says nothing about the budget; the caller must carry on rather
#                than stand down. NOW (epoch) is for that classification; it
#                defaults to the clock.
#
# When both resources are below their floor the one with the **later** reset
# binds, so the stand-down a caller derives from it covers both. Picking the
# earlier one would let a cycle wake into a budget that is still exhausted on
# the other resource and spend a Co-Ordinator discovering it.
github_limit_verdict() {
  local snapshot="${1:-}" min_core="${2:-0}" min_graphql="${3:-0}" now="${4:-}"
  local res rem reset best_res="" best_rem="" best_reset=0 saw_pristine=0 saw_evidence=0

  if [[ -z "$snapshot" ]] || ! jq -e 'type == "object"' <<<"$snapshot" >/dev/null 2>&1; then
    printf 'unknown\t\t\t\n'
    return 0
  fi

  for res in graphql core; do
    local floor
    if [[ "$res" == "core" ]]; then floor="$min_core"; else floor="$min_graphql"; fi
    rem="$(github_limit_remaining "$snapshot" "$res")"
    # An absent figure is unknown, not zero: a snapshot that does not mention
    # a resource is no evidence that the resource is spent.
    [[ "$rem" =~ ^[0-9]+$ ]] || continue
    # The endpoint's cold answer — a full bucket with a reset exactly an hour
    # from now — is no evidence either (see the header), and is skipped the
    # same way; a snapshot made only of such answers is `unknown`, not `ok`.
    if github_limit_resource_pristine "$snapshot" "$res" "$now"; then saw_pristine=1; continue; fi
    saw_evidence=1
    (( rem < floor )) || continue
    reset="$(github_limit_reset_epoch "$snapshot" "$res")"
    [[ "$reset" =~ ^[0-9]+$ ]] || reset=0
    if [[ -z "$best_res" ]] || (( reset > best_reset )); then
      best_res="$res"; best_rem="$rem"; best_reset="$reset"
    fi
  done

  if [[ -z "$best_res" ]]; then
    if (( saw_pristine == 1 && saw_evidence == 0 )); then
      printf 'unknown\t\t\t\n'
    else
      printf 'ok\t\t\t\n'
    fi
    return 0
  fi
  local reset_at=""
  (( best_reset > 0 )) && reset_at="$(date -u -d "@$best_reset" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  printf 'exhausted\t%s\t%s\t%s\n' "$best_res" "$best_rem" "$reset_at"
}

# github_limit_describe RESOURCE REMAINING FLOOR RESET_AT
# The one-line explanation a stand-down logs, shared so the cycle's reason and
# any future reader of the same state cannot word it differently. Says how far
# away the reset is as well as when it is, because "resets at 21:55Z" answers a
# different question from "in 26 minutes" and an operator reading a log at
# 03:00 wants the second one.
github_limit_describe() {
  local resource="${1:-}" remaining="${2:-}" floor="${3:-}" reset_at="${4:-}"
  printf 'GitHub API budget exhausted: %s has %s point(s) left, below the %s this cycle needs' \
    "$resource" "$remaining" "$floor"
  if [[ -n "$reset_at" ]]; then
    local in_seconds
    in_seconds=$(( $(date -d "$reset_at" +%s 2>/dev/null || echo 0) - $(date +%s) ))
    if (( in_seconds > 0 )); then
      printf '; GitHub resets it at %s (in %dm)' "$reset_at" $(( (in_seconds + 59) / 60 ))
    else
      printf '; GitHub resets it at %s' "$reset_at"
    fi
    printf '. Stated by GitHub, not estimated — no probe is needed and none runs'
  fi
}

# github_limit_wait_plan KIND RESET_EPOCH NOW_EPOCH WAITED_SECONDS
# How long to wait before retrying one refused call — pure, so the policy can
# be regression-tested without a clock or a network. Prints a whole number of
# seconds, or nothing when waiting is not worth it. Reads the module's three
# bounds as globals so a caller cannot apply one of them and forget another.
#
#   - `none`      never waits. Not every failure is a rate limit.
#   - `secondary` waits the fixed fallback: GitHub states no reset for these.
#   - `primary`   waits until GitHub's own stated reset, plus one second so the
#                 retry lands after the boundary rather than on it. A reset
#                 further out than the per-call bound is not waited for at all
#                 — that is a stand-down, not a retry, and the caller's cycle
#                 has a budget check for it.
#
# The total-wait budget is checked last and clamps rather than refuses: a
# process with 10 seconds of patience left spends them, because a call that
# succeeds after a short wait is still cheaper than a source degrading to `[]`.
github_limit_wait_plan() {
  local kind="${1:-none}" reset_epoch="${2:-0}" now_epoch="${3:-0}" waited="${4:-0}" wait=0
  case "$kind" in
    secondary) wait="$GITHUB_LIMIT_SECONDARY_WAIT_SECONDS" ;;
    primary)
      [[ "$reset_epoch" =~ ^[0-9]+$ ]] || return 0
      [[ "$now_epoch" =~ ^[0-9]+$ ]] || return 0
      (( reset_epoch > now_epoch )) || return 0
      wait=$(( reset_epoch - now_epoch + 1 ))
      ;;
    *) return 0 ;;
  esac
  (( wait > 0 )) || return 0
  (( wait <= GITHUB_LIMIT_MAX_WAIT_SECONDS )) || return 0
  local left=$(( GITHUB_LIMIT_TOTAL_WAIT_SECONDS - waited ))
  (( left > 0 )) || return 0
  (( wait <= left )) || wait="$left"
  printf '%s' "$wait"
}

# github_limit_primary_reset_epoch [NOW_EPOCH]
# Which resource a primary-limit refusal actually named is not stated in the
# message, so this spends one fresh probe (`github_limit_snapshot`) and
# returns the earlier of `core`'s and `graphql`'s own reset that is still
# ahead of NOW_EPOCH (defaulting to the clock) — whichever resource the
# refused call spent, it can be retried once that time passes. The snapshot's
# own probe is refused too under a primary limit, and that is fine: the
# refusal carries the `x-ratelimit-reset` header the probe itself reads.
# Prints `0` (never empty) when neither resource offers a future reset, so a
# caller can hand this straight to `github_limit_wait_plan` without an
# emptiness check of its own. Pulled out of the `gh` wrapper below so a
# caller that already knows *why* a call failed — `approver_post_or_warn`
# (lib/approver.sh, agent-ops#1082), retrying a refused review write the
# wrapper's own single attempt already gave up on — can ask the same
# question without re-deriving it.
# shellcheck disable=SC2120  # NOW_EPOCH is optional; the `gh` wrapper omits it.
github_limit_primary_reset_epoch() {
  local now_epoch="${1:-}" snapshot core_reset graphql_reset reset reset_epoch=0
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch="$(date +%s)"
  # shellcheck disable=SC2119  # the default probe, deliberately
  snapshot="$(github_limit_snapshot 2>/dev/null || true)"
  core_reset="$(github_limit_reset_epoch "$snapshot" core)"
  graphql_reset="$(github_limit_reset_epoch "$snapshot" graphql)"
  for reset in "$core_reset" "$graphql_reset"; do
    [[ "$reset" =~ ^[0-9]+$ ]] || continue
    (( reset > now_epoch )) || continue
    if (( reset_epoch == 0 )) || (( reset < reset_epoch )); then reset_epoch="$reset"; fi
  done
  printf '%s' "$reset_epoch"
}

# gh [args...]
# `gh`, but a rate-limit refusal is waited out once instead of returned.
#
# ## What sourcing this file does to a script
#
# It shadows the `gh` binary for the sourcing shell and its subshells, so every
# existing `gh …` call in that script becomes rate-limit-aware with no edit to
# the call site. That is the entire point: there are over a hundred `gh` calls
# across this repository's pipelines, gatherers and sweeps, and a wrapper that
# had to be threaded through each of them by hand would be adopted at some of
# them and forgotten at the rest — which is the state this replaces.
#
# Three consequences worth knowing:
#
#   1. The binary is reached with `command gh`, so a test that puts a stub `gh`
#      earlier on `PATH` still gets its stub; the wrapper wraps the stub. The
#      indirections some scripts use for exactly that purpose — `GH`,
#      `CLAIM_GH`, `SWEEP_GH` and friends — also keep working, because a bare
#      `gh` reached through `"$GH"` is still resolved as a function.
#   2. A call invoked through `timeout`, `env`, `xargs` or any other exec-ing
#      wrapper bypasses this, because those run the binary directly. That is
#      correct, not a gap: `scripts/publish-dashboard.sh` deliberately puts
#      every call under `timeout` to keep the heartbeat inside its window, and
#      a wrapper that could add a minute to one of them would break it.
#   3. stdout is captured and emitted only when the call is finished with. A
#      retry would otherwise re-emit whatever the failed attempt had already
#      streamed — `gh api --paginate` emits each page as it arrives, so a
#      limit met on page three would leave pages one and two on stdout twice.
#      The side benefit is that a failed call now prints nothing rather than a
#      truncated half-document, which is the shape callers already assume.
#
# stderr is captured for the same reason (the diagnosis has to be read before
# it is passed on) and then replayed verbatim onto stderr, so a caller's own
# `2>"$file"` redirect still receives exactly what `gh` said.
gh() {
  local out_file err_file rc kind reset_epoch wait
  out_file="$(mktemp)" || { command gh "$@"; return $?; }
  err_file="$(mktemp)" || { rm -f "$out_file"; command gh "$@"; return $?; }

  # `&& rc=0 || rc=$?`, never a bare call followed by `rc=$?`: this function is
  # sourced into scripts running under `set -e`, and a bare failing command
  # would abort the caller here — inside the wrapper, before the temp files are
  # cleaned up and before `gh`'s own diagnosis has been replayed to stderr. The
  # caller would lose the error message it was about to be given.
  command gh "$@" >"$out_file" 2>"$err_file" && rc=0 || rc=$?

  if (( rc != 0 )); then
    kind="$(github_limit_kind "$(cat "$err_file" 2>/dev/null || true)")"
    if [[ "$kind" != "none" ]]; then
      reset_epoch=0
      # shellcheck disable=SC2119  # the default (now-relative) NOW_EPOCH, deliberately
      [[ "$kind" == "primary" ]] && reset_epoch="$(github_limit_primary_reset_epoch)"
      wait="$(github_limit_wait_plan "$kind" "$reset_epoch" "$(date +%s)" "$GITHUB_LIMIT_WAITED_SECONDS")"
      if [[ -n "$wait" ]]; then
        printf 'gh: %s rate limit; waiting %ss and retrying once\n' "$kind" "$wait" >&2
        sleep "$wait"
        GITHUB_LIMIT_WAITED_SECONDS=$(( GITHUB_LIMIT_WAITED_SECONDS + wait ))
        : >"$out_file"; : >"$err_file"
        command gh "$@" >"$out_file" 2>"$err_file" && rc=0 || rc=$?
      fi
    fi
  fi

  cat "$out_file"
  cat "$err_file" >&2
  rm -f "$out_file" "$err_file"
  return "$rc"
}
