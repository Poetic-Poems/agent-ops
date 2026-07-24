#!/usr/bin/env bash
#
# lib/noop-skip.sh — the no-op short-circuit (requirement 3b): deciding whether
# engaging the Co-Ordinator could possibly produce a different answer than the
# last time it found nothing to do.
#
# Sourced by agent-cycle.sh and scripts/publish-dashboard.sh, so the rule and
# what the dashboard reports about it are one definition (requirement 34a).
#
# ## What this claims, and what it does not
#
# The Co-Ordinator is a pure function of its inputs, give or take model
# variance. If none of those inputs has moved since it last returned
# `{"selected": false}`, running it again buys the same answer at the same
# price. On an idle repository that is 24 answers a day, every day, none of
# which does anything.
#
# So the claim this rule makes is deliberately narrow:
#
#     Every input to the Co-Ordinator's verdict is byte-identical to when it
#     last declined, therefore its verdict would be the same.
#
# It is *not* the claim "there is no work". Nobody here can know that — only
# the Co-Ordinator can, and this rule exists precisely to avoid asking it. The
# distinction is what makes the rule safe: it never has to be right about the
# repository, only about whether anything changed.
#
# ## The fingerprint must cover every input, or the pipeline silently stalls
#
# This is the dangerous half. A source left out of the fingerprint is a source
# that can gain work without waking the pipeline, and the symptom is nothing at
# all: no error, no alert, just PRs that stop appearing while the log fills
# with tidy `stand-down` events saying everything is fine. That is this
# system's signature failure (see the Gotchas table) and this rule is an
# excellent way to build a new one.
#
# The inputs, and what covers each:
#
#   tech-debt, implementation-plan, project-review, code | head_sha
#   security, code-quality                               | findings (verbatim)
#   review-feedback                                      | review_feedback (verbatim)
#   merge-conflicts                                      | merge_conflicts (verbatim)
#   abandoned-drafts                                     | abandoned_drafts (verbatim)
#   issues                                               | issues digest
#   failed-runs                                          | workflows digest
#   claims (requirement 16.3)                            | open_prs digest
#   blocked / void skip-lists                            | repo|item projections
#   which repos, which sources, which models             | selection_config
#   the selection rules themselves                       | coordinator_prompt_sha
#
# `review_feedback` is hashed verbatim, like `findings`, and that gets the rule
# right for free in both directions: its entries only exist while it is the
# agent's turn to answer a review (see scripts/gather-review-feedback.sh), so a
# new review round adds one, and the agent's own push removes it. The
# alternative — digesting the PR's `reviewDecision` — would be stably
# CHANGES_REQUESTED before *and* after the fix, because the agent cannot dismiss
# a review on its own PR.
#
# `abandoned_drafts` is hashed verbatim for a sharper reason: it is one of two
# candidate rules that turn on something *no event on the PR itself carries*. A
# draft PR becomes abandoned merely by sitting untouched past the threshold, which
# moves no commit, issue, alert or even the PR's own `updated_at` — so the
# `open_prs` digest alone would sit unchanged across the exact moment the work
# appears, and the pipeline would skip it until the forced recheck.
# gather-abandoned-drafts.sh computes candidacy against the clock and this array
# carries the result, so a draft crossing the threshold *adds an entry* and busts
# the fingerprint the cycle it goes stale. Without this line the whole source is a
# silent stall waiting to happen.
#
# `merge_conflicts` is hashed verbatim for the same class of reason. A ready PR
# turns CONFLICTING when its *base* advances — someone merges another PR to `main`
# — which is not an event on this PR: its head does not move and its `updated_at`
# does not change, so the `open_prs` digest (which keys on number, updated_at,
# head ref and draft flag) does not move for it. Worse, the base advance and the
# conflict appearing are two separate cycles: the cycle the base moves, the repo's
# head SHA changes and busts the fingerprint, but GitHub has not yet recomputed
# mergeability (`UNKNOWN`), so nothing is gathered; a later cycle mergeability
# resolves to CONFLICTING with the repo head SHA unchanged since — so without this
# array the fingerprint would match the earlier none-selected and skip the very
# cycle the work becomes visible. gather-merge-conflicts.sh samples mergeability
# and this array carries the result, so the flip to CONFLICTING *adds an entry*
# and busts the fingerprint. Same failure shape as abandoned-drafts; same fix.
#
# The last two are easy to forget and cost the most when forgotten: without
# them, editing prompts/coordinator.md or adding a source to config.json would
# have no effect until something unrelated happened to change in a repo. You
# would be debugging your edit, and your edit would be fine.
#
# ## Where a fingerprint match is judged
#
# Against the most recent `none-selected` event carrying a fingerprint, and
# nothing else. There is no need to reason about what happened in between: any
# cycle that selected an item necessarily changed something the fingerprint
# covers (it opens a PR, or blocks the item, or voids it), so a match with an
# older `none-selected` means the Co-Ordinator's world has genuinely returned
# to that state — and returning to a state in which it declined is grounds to
# expect it to decline again.
#
# ## The forced recheck is the safety valve, not a nicety
#
# `none_selected_recheck_hours` bounds how long a fingerprint bug — or a source
# nobody thought of, or a Co-Ordinator that would have decided differently on a
# second look — can hold the pipeline down. Setting it to 0 disables the valve
# and makes fingerprint coverage load-bearing forever. Don't.

# The canonical form the fingerprint is taken over. Emits nothing at all — an
# unfingerprintable cycle — when any repo's source state could not be sampled
# cleanly (`ok: false`), because a digest built from a failed API call is a
# stable lie: it would match the next equally-failed sample and skip cycles for
# as long as the outage lasted (see scripts/gather-source-state.sh).
#
# Arrays are sorted, and blocked/void are projected down to their repo+item
# keys, so that the fingerprint tracks meaning rather than incidental order or
# the timestamps and prose that ride along on a log event. `jq -S` then sorts
# every object key, making the serialisation canonical.
# shellcheck disable=SC2016  # jq's syntax, not the shell's.
NOOP_CANON_JQ='
  if ([.repos[]?.state.ok] | all) | not then empty
  else
    {
      repos: ([.repos[]? | {
        slug: .slug,
        sources: (.sources // [] | sort),
        findings: (.findings // []),
        review_feedback: (.review_feedback // []),
        merge_conflicts: (.merge_conflicts // []),
        abandoned_drafts: (.abandoned_drafts // []),
        head_sha: (.state.head_sha // ""),
        issues: (.state.issues // []),
        workflows: (.state.workflows // []),
        open_prs: (.state.open_prs // [])
      }] | sort_by(.slug)),
      blocked: ([.blocked[]? | ((.repo // "") + "|" + (.item // ""))] | sort | unique),
      void: ([.void[]? | ((.repo // "") + "|" + (.item // ""))] | sort | unique),
      selection_config: (.selection_config // {}),
      coordinator_prompt_sha: (.coordinator_prompt_sha // "")
    }
  end
'

# noop_fingerprint  (reads the input object on stdin)
# Print the cycle's fingerprint, or nothing if this cycle cannot be
# fingerprinted. Always succeeds: "not fingerprintable" is a normal outcome
# (it simply means the Co-Ordinator runs), and a non-zero return here would
# kill an `errexit` caller at the call site — the trap in the Gotchas table.
noop_fingerprint() {
  local canon
  canon="$(jq -S -c "$NOOP_CANON_JQ" 2>/dev/null || true)"
  [[ -n "$canon" ]] || return 0
  printf '%s' "$canon" | sha256sum | cut -d' ' -f1
}

# noop_last_none_selected LOG_FILE
# Print "<fingerprint>\t<ts>" for the most recent `none-selected` event that
# carried a fingerprint, or nothing. Always succeeds; a missing, empty or
# malformed log simply pins no fingerprint (and so skips nothing).
#
# Events without a fingerprint are ignored rather than treated as a mismatch:
# they predate this rule, or were recorded on a cycle that could not be
# fingerprinted. Either way they say nothing about the current state.
noop_last_none_selected() {
  local src="${1:--}" out=""
  # shellcheck disable=SC2016  # jq's $ vars.
  local filter='[.[] | select(.event == "none-selected" and (.fingerprint // "") != "")]
                | last
                | if . == null then empty else (.fingerprint + "\t" + (.ts // "")) end'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null | jq -rs "$filter" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null | jq -rs "$filter" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# noop_skip_reason FINGERPRINT LOG_FILE RECHECK_HOURS [NOW_EPOCH]
# Print the reason this cycle may skip the Co-Ordinator, or nothing if it may
# not. Always succeeds — the overwhelmingly common answer is "no", which is not
# an error.
#
# Skips only when all of:
#   - the cycle is fingerprintable (every source sampled cleanly);
#   - the last fingerprinted `none-selected` carries the same fingerprint;
#   - that event is younger than RECHECK_HOURS (0 disables the forced recheck),
#     and its timestamp parses — an unreadable `ts` cannot be aged, and an
#     unbounded skip is the one outcome worth paying a Co-Ordinator to avoid.
noop_skip_reason() {
  local fp="$1" log="$2" recheck_hours="$3" now="${4:-}"
  local last last_fp last_ts ts_epoch age

  [[ -n "$fp" ]] || return 0
  last="$(noop_last_none_selected "$log")"
  [[ -n "$last" ]] || return 0
  IFS=$'\t' read -r last_fp last_ts <<<"$last"
  [[ "$last_fp" == "$fp" ]] || return 0

  [[ -n "$now" ]] || now="$(date +%s)"
  ts_epoch="$(date -d "$last_ts" +%s 2>/dev/null || echo 0)"
  (( ts_epoch > 0 )) || return 0
  age=$(( now - ts_epoch ))
  if (( recheck_hours > 0 && age >= recheck_hours * 3600 )); then
    return 0
  fi

  printf 'no-op short-circuit: no work source has changed since the Co-Ordinator found nothing to do at %s (fingerprint %s, age %dh%02dm)' \
    "$last_ts" "${fp:0:12}" "$(( age / 3600 ))" "$(( (age % 3600) / 60 ))"
  return 0
}
