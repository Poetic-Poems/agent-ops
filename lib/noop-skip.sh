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
#   implementation-plan, project-review, code             | head_sha
#   tech-debt                                            | tech_debt (verbatim)
#   security, code-quality                               | findings (verbatim)
#   review-feedback                                      | review_feedback (verbatim)
#   merge-conflicts                                      | merge_conflicts (verbatim)
#   dequeued                                             | dequeued (verbatim)
#   abandoned-drafts                                     | abandoned_drafts (verbatim)
#   register-hygiene                                     | register_hygiene (verbatim)
#   human-visibility                                     | human_visibility (verbatim)
#   issues (incl. their Priority band, req. 15e)         | issues (verbatim) + issues digest
#   failed-runs                                          | workflows digest
#   claims (requirement 16.3)                            | open_prs digest
#   the fleet's active claims (requirement 3o)           | claimed, repo|item projection
#   blocked / void skip-lists                            | repo|item projections
#   refinements carried forward (requirement 3h)         | repo|item|ts projection
#   which repos, which sources, which models, attention weights | selection_config
#   the selection rules themselves                       | coordinator_prompt_sha
#   the repo/work-sources table the Co-Ordinator reads    | coordinator_work_sources_table
#   the Enabler's eligible set (requirement 35b)         | repo|item|reason projection
#   the Enabler's model and thresholds                   | enabler_config
#   the Enabler's own rules                              | enabler_prompt_sha
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
# `dequeued` (TD-PPagop-26081409) is hashed verbatim for an even sharper version
# of the same reason. A merge-group checks-failure dequeue moves *nothing* the
# `open_prs` digest samples — not the head (no commit lands), not `updated_at`
# (GitHub does not touch it), not even `mergeable`, which is what merge_conflicts
# above rides on. The only trace is a `RemovedFromMergeQueueEvent` on the pull
# request's own timeline, read live each cycle by `lib/merge-queue.sh`'s
# `merge_queue_probe` — a fact that exists nowhere else in this system's state.
# gather-dequeued.sh samples that probe and this array carries the result, so a
# fresh dequeue *adds an entry* and busts the fingerprint, and a re-queue that
# resolves it removes the entry the same way. Same failure shape as
# merge_conflicts and abandoned_drafts; same fix.
#
# A *fix* removes the entry too, but by a different route worth knowing here,
# because it is the one case where this array's churn is not the signal it looks
# like: the dequeue itself never clears (the timeline event is permanent), so
# what drops the pull request is gather-dequeued.sh's answered clause noticing
# the Implementer's marked reply. Until that clause was added, a fix merely
# re-keyed the entry to the new head SHA — busting this fingerprint on every
# round while nothing had actually changed, which is precisely the wake-up this
# file exists to avoid paying for twice.
#
# `claimed` (requirement 3o) is hashed too, projected to `repo|item` like
# `blocked`/`void`, for the same class of gap `abandoned_drafts` and
# `merge_conflicts` close: a peer node claiming an item — winning a branch
# create-ref, or writing a registry entry for a file claim — moves no commit,
# issue, alert, or (until its PR exists) the `open_prs` digest above. Without
# this line a claim appearing or a claim ageing past `claim_ttl_hours` (both
# add or remove an entry) could sit unnoticed behind a matching fingerprint
# until the forced recheck, which is exactly the silent-stall shape this rule
# exists to close — and the reason `claimed` was introduced in the first
# place (issue #175) was to stop the model's own live check from being the
# only thing that ever noticed a peer's claim.
#
# `register_hygiene` is hashed verbatim too, but for a weaker reason, and saying
# so is the point: unlike the two above, this source needs no rescuing. A
# register drifts only when somebody commits to `TECH-DEBT.md`, and that moves
# the repo's `head_sha` — which is already here. There is no transition the
# existing signals would sleep through. It is hashed anyway because a
# per-source exception is a thing to remember, and "covered by something else"
# is precisely how a source ends up covered by nothing; and because candidacy
# depends on the checker as well as the file, so an edit to
# `scripts/td-check.pl` can add or retire the item with no commit to the target
# repo at all, and only this array carries that.
#
# `human_visibility` is hashed verbatim for the same class of reason
# `abandoned_drafts` and `merge_conflicts` are (requirement 38e): a violation
# becomes live re-checkable candidacy off a `warning` event
# scripts/sweep-human-visibility.sh already logged, which moves no commit,
# issue, alert or open-PR digest field of its own — and the live re-check
# scripts/gather-human-visibility-hygiene.sh performs (a merged, closed or
# now-reviewed pull request drops it) is itself a transition nothing else
# here samples. Without this line a violation appearing, or quietly
# resolving, would sit unnoticed behind a matching fingerprint until the
# forced recheck.
#
# `tech_debt` (requirement 3t, issue #310) is hashed verbatim for the same
# weaker-but-still-real reason as `register_hygiene`: an item's `status:`
# frontmatter changes only on a commit to the target repo, which already moves
# `head_sha`, so there is no transition here that `head_sha` alone would sleep
# through. It is hashed anyway for uniformity, and because this array is what
# lets requirement 3t's machine corroboration compare the Co-Ordinator's verdict
# against the Script's own eligible count — a fingerprint that dropped this
# array could match an old none-selected event from before a blocked or void
# item's exclusion changed which items were even offered.
#
# `issues` (the pre-fetched array of requirement 3j) is hashed verbatim, and
# it is the only cover for one real transition: an *edit* to an existing
# comment. GitHub moves the issue's `updated_at` for a new comment, a label, a
# title edit or an assignment — the digest sees all of those — but editing a
# comment in place moves only the comment's own timestamp, which the digest
# does not sample. The Co-Ordinator reads the thread verbatim from this array,
# so a re-scoped instruction edited into an old comment changes its verdict
# while every digest field sits still; only the array's bytes carry it. The
# `state.issues` digest stays alongside rather than being retired: it is
# sampled independently of the array (see gather-source-state.sh on why its
# failure mode must differ), so a cycle whose issues fetch degraded to `[]`
# still gets its fingerprint busted by the digest when a real issue moves.
#
# `enabler_eligible` is hashed for the same class of reason again (requirement
# 35b). An item becomes eligible for the Enabler when the fleet has run its
# third Co-Ordinator since the block — which moves no commit, issue, alert or
# PR — so without this line a quiet fleet would skip straight through the cycle
# the escalation became due and go on skipping until the forced recheck. The
# projection keeps the `reason` alongside `repo|item`, which is what carries the
# transition that matters most: an escalation issue the human closes takes the
# entry from ineligible to `issue-closed`, and closing the issue is the entire
# protocol that issue asked of them. After an engagement the examined markers
# empty the set again and skipping resumes — the same shape as a stalled draft
# being finished.
#
# `refinements` is hashed because a refinement the Enabler wrote is an input to
# the Co-Ordinator's next verdict (requirement 3h) — it is the whole of what a
# non-issue item's work order will say. In practice an `item-refined` event
# always travels with the `unblocked` that returns the item to the pool, so the
# `blocked` projection above would bust the fingerprint anyway; it is listed
# separately rather than left to that coincidence, because "covered by something
# else" is how a source ends up covered by nothing.
#
# `enabler_config` and `enabler_prompt_sha` are the Enabler's half of the two
# lines below, with one deliberate difference in what they buy: editing
# prompts/enabler.md busts the fingerprint, so a quiet fleet notices the edit,
# but it does not re-open items already examined — those are gated by
# `enabler_recheck_hours`, which is the lever for "read this one again".
#
# `coordinator_work_sources_table` is hashed verbatim, and it is not the same
# claim as `repos[].sources` above (issue #78). That array is `ordered_repos_
# json`'s view, which back-pressure (requirement 2.2a) narrows to just the
# four finishing sources for a repo with work waiting; the table the
# Co-Ordinator actually reads is always rendered from the plain, unrestricted
# `config.json` (`lib/coordinator-brief.sh`), because the table's own job is
# to show each repo's full configured priority regardless of this cycle's
# restrictions. During a back-pressure cycle those two views diverge by
# construction, so a config edit to a non-finishing source would bust neither
# `repos[].sources` nor (being config, not a commit) `coordinator_prompt_sha`
# — only this line carries it, and without it such an edit would sit
# unnoticed until back-pressure lifted.
#
# The last three are easy to forget and cost the most when forgotten: without
# them, editing prompts/coordinator.md, adding a source to config.json, or
# reordering one during a back-pressure cycle would have no effect until
# something unrelated happened to change in a repo. You would be debugging
# your edit, and your edit would be fine.
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
# keys — the Enabler's eligible set to repo+item+reason, since there the reason
# is the change — so that the fingerprint tracks meaning rather than incidental
# order or the timestamps and prose that ride along on a log event. `jq -S` then
# sorts every object key, making the serialisation canonical.
#
# The three `enabler_*` keys, `refinements`, `claimed`, and
# `coordinator_work_sources_table` all default to empty, so an input that
# predates them canonicalises exactly as one that carries them empty:
# replaying an older cycle's input yields its original fingerprint, and a
# node whose config sets no Enabler keys agrees with itself.
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
        dequeued: (.dequeued // []),
        abandoned_drafts: (.abandoned_drafts // []),
        register_hygiene: (.register_hygiene // []),
        human_visibility: (.human_visibility // []),
        tech_debt: (.tech_debt // []),
        issues_prefetched: (.issues // []),
        head_sha: (.state.head_sha // ""),
        issues: (.state.issues // []),
        workflows: (.state.workflows // []),
        open_prs: (.state.open_prs // [])
      }] | sort_by(.slug)),
      blocked: ([.blocked[]? | ((.repo // "") + "|" + (.item // ""))] | sort | unique),
      void: ([.void[]? | ((.repo // "") + "|" + (.item // ""))] | sort | unique),
      claimed: ([.claimed[]? | ((.repo // "") + "|" + (.item // ""))] | sort | unique),
      refinements: ([(.refinements // {}) | to_entries[]
                     | .key as $repo
                     | (.value // {}) | to_entries[]
                     | ($repo + "|" + .key + "|" + ((.value.ts // "") | tostring))]
                    | sort | unique),
      enabler_eligible: ([.enabler_eligible[]?
                          | ((.repo // "") + "|" + (.item // "") + "|" + (.reason // ""))]
                         | sort | unique),
      selection_config: (.selection_config // {}),
      coordinator_prompt_sha: (.coordinator_prompt_sha // ""),
      enabler_config: (.enabler_config // {}),
      enabler_prompt_sha: (.enabler_prompt_sha // ""),
      coordinator_work_sources_table: (.coordinator_work_sources_table // "")
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
