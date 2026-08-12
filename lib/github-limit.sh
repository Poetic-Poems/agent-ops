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
# ## Why the budget check is free
#
# `GET /rate_limit` is exempt from the limits it reports — a call to it does
# not increment `core.used`, which is what makes a check-before-you-spend gate
# affordable at the top of every cycle. Verified 2026-08-12 by bracketing a
# metered call with two of them and observing the delta of exactly 1.
#
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
# requests sitting in the human's merge queue carry that label without counting
# against the cap, so the listing genuinely can exceed 30 while the gate's own
# sum stays small. Truncated, it undercounts, and the gate opens when it should
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

# github_limit_snapshot
# The `/rate_limit` document, or nothing if it cannot be read. Free (see the
# header), so callers may take one whenever they would otherwise guess.
#
# `command gh`, so this reaches the binary rather than recursing into the
# wrapper below — and so a test's `PATH` stub answers it, which is the only
# substitution any caller needs.
#
# stderr is discarded because every caller's fallback is the same and none of
# them can act on the diagnosis. A snapshot that cannot be taken is reported as
# the `unknown` verdict, which is never grounds to stand a cycle down — an
# unreadable meter says nothing about the budget, and standing down on it would
# invent a failure mode GitHub never had.
github_limit_snapshot() {
  local out
  out="$(command gh api rate_limit 2>/dev/null)" || return 1
  jq -e 'type == "object" and has("resources")' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s' "$out"
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

# github_limit_verdict SNAPSHOT MIN_CORE MIN_GRAPHQL
# The cycle-start budget check, pure: prints
# "<verdict>\t<resource>\t<remaining>\t<reset_at>".
#   - ok         both resources hold at least their floor. `resource` is empty.
#   - exhausted  one or both are below. `resource` names the binding one, and
#                `reset_at` is a real ISO-8601 UTC time GitHub stated — never
#                an estimate, so a caller may treat it as a deadline.
#   - unknown    the snapshot is missing or unreadable. Says nothing about the
#                budget; the caller must carry on rather than stand down.
#
# When both resources are below their floor the one with the **later** reset
# binds, so the stand-down a caller derives from it covers both. Picking the
# earlier one would let a cycle wake into a budget that is still exhausted on
# the other resource and spend a Co-Ordinator discovering it.
github_limit_verdict() {
  local snapshot="${1:-}" min_core="${2:-0}" min_graphql="${3:-0}"
  local res rem reset best_res="" best_rem="" best_reset=0

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
    (( rem < floor )) || continue
    reset="$(github_limit_reset_epoch "$snapshot" "$res")"
    [[ "$reset" =~ ^[0-9]+$ ]] || reset=0
    if [[ -z "$best_res" ]] || (( reset > best_reset )); then
      best_res="$res"; best_rem="$rem"; best_reset="$reset"
    fi
  done

  if [[ -z "$best_res" ]]; then
    printf 'ok\t\t\t\n'
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
  local out_file err_file rc kind reset_epoch wait snapshot
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
      if [[ "$kind" == "primary" ]]; then
        # Which resource was refused is not stated in the message, so take the
        # earlier of the two resets that are still ahead of us: whichever
        # resource this call spends, it can be retried once that time passes.
        snapshot="$(github_limit_snapshot 2>/dev/null || true)"
        local now_epoch core_reset graphql_reset reset
        now_epoch="$(date +%s)"
        core_reset="$(github_limit_reset_epoch "$snapshot" core)"
        graphql_reset="$(github_limit_reset_epoch "$snapshot" graphql)"
        for reset in "$core_reset" "$graphql_reset"; do
          [[ "$reset" =~ ^[0-9]+$ ]] || continue
          (( reset > now_epoch )) || continue
          if (( reset_epoch == 0 )) || (( reset < reset_epoch )); then reset_epoch="$reset"; fi
        done
      fi
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
