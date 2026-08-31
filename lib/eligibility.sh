#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/eligibility.sh — what this cycle is allowed to act on, once the
# gatherers have finished and before anything is offered to a model: which
# pre-fetched bands survive the blocked/void skip-lists (requirements 3t/3u),
# which repositories' issues the Enabler may be judged against (35a/35b), the
# Refiner's own two extra pre-fetched sources (3y), and the Refiner's
# candidate set (39a).
#
# Split out of agent-cycle.sh (#771). One seam rather than four files because
# the four blocks answer one question between them — who is eligible for what
# this cycle — over the same inputs (`ordered_repos_json`,
# `source_states_json`, `blocked_json`/`void_json`, `claimed_json`), in an
# order that matters: the Enabler's eligible set and the Refiner's candidate
# set are both computed from the extracts the band pass has just settled, so
# an Enabler engagement and a Refiner engagement in the same cycle can never
# disagree about what is already spoken for.
#
# Sourced by agent-cycle.sh only, and its four functions called once each, in
# place, from where this text used to sit. Like `run_standdown_checks`
# (lib/standdown.sh) they declare nothing `local` and read and write the
# cycle's own globals directly — `refinements_json`, `decisions_json`,
# `enabler_eligible_json`, `enabler_allowed`, `refiner_repos_json`,
# `refiner_candidates_json`, `refiner_allowed`, `open_issues_json`,
# `live_pr_refs_json`, `stale_enabler_refs_json`/`_n` — so each call is
# indistinguishable, to the
# rest of the cycle, from the inline block it replaces. Their bodies keep the
# original top-level indentation for the same reason `lib/candidate-gather.sh`
# does: these were never functions, and reformatting them would bury the move
# in whitespace.

# compute_band_eligibility — requirement 3t (issue #310), extended to every
# other pre-fetched band by requirement 3u (issue #320). Called once from
# `agent-cycle.sh`, after `compute_skip_lists` and before anything reads a
# band (#771).
compute_band_eligibility() {
# --- 35e's snapshot, taken before this function's own subtraction below ---
# (requirement 35e, issue #1119). `compute_enabler_eligible_set` needs this
# cycle's actual fresh `merge_conflicts`/`dequeued`/`abandoned_drafts` gather
# to test a blocked SHA-scoped PR ref for staleness — but every entry in those
# three bands that is itself blocked is exactly what the subtraction loop
# below (`exclude_blocked_or_void_items`) is about to remove from
# `ordered_repos_json`, and the Enabler is only ever eligible for items that
# are blocked. Deriving the staleness test's live set from `ordered_repos_json`
# after that loop runs, as requirement 35e once read, would therefore always
# find the ref missing and mark it stale — forever, for every blocked ref,
# since the one array it could ever appear in has already had it removed.
# Taking this snapshot first, from the untouched gather, is what lets a
# blocked ref that is still at its live head SHA reach the Enabler at all.
live_pr_refs_json="$(jq -c \
  '[.[] | .slug as $s | ((.merge_conflicts // []) + (.dequeued // []) + (.abandoned_drafts // []))[] | ($s + "#" + .ref)]' \
  <<<"$ordered_repos_json" 2>/dev/null || true)"

# --- 3c/3u. Pre-fetched-band eligibility, decided (requirement 3t, issue ---
# --- #310; extended to every other pre-fetched band by requirement 3u, ---
# --- issue #320) ---
# Deferred from step 3 for the same reason 2.2a's back-pressure decision and
# 3b's no-op fingerprint are deferred from their own numbers: the repo loop
# (section 3) attached each repo's pre-fetched bands, claim-filtered, before
# `blocked_json`/`void_json` existed to filter them further. Now that both
# are final — void_json has had every reconciliation pass and its own
# retirement applied — finish the job for every band the Script hands the
# Co-Ordinator whole: drop any entry this repo's own blocked or void record
# names, exactly as exclude_claimed_items already dropped claimed ones.
# `findings`, `review_feedback`, `abandoned_drafts`, `merge_conflicts`,
# `dequeued`, `register_hygiene`, `human_visibility` and `tech_debt` all get the identical
# second pass `exclude_blocked_or_void_items` first gave `tech_debt` alone
# (issue #310) — there is nothing about that exclusion tech-debt-specific,
# only tech-debt was the band it was first proven on. Every band the repo
# entry carries is in this list but `issues`; a band added to that entry and
# not to this list would keep handing the Co-Ordinator blocked and void
# candidates it has no list left to check them against, which is why
# `test/cycle-state.test.sh` pins the list itself.
#
# `issues` gets its own, narrower pass
# below instead, via `exclude_blocked_or_void_issues`: unlike every other
# band, a blocked issue can carry fresh evidence requirement 18a obliges the
# Co-Ordinator to re-read live, so dropping it here — before that re-read can
# ever happen — would silently retire the mandatory re-check rather than
# apply it (see that function's own comment).
#
# What remains in each band after this block is the Script's own answer to
# "what could the Co-Ordinator actually select from this band" — open,
# unclaimed, unblocked (or, for `issues`, blocked-but-due-a-re-read), not
# void — with no per-item judgement left for it to apply, and no room for a
# verdict like "requires per-item evaluation against blocked/void/claimed
# records" to be true of any of them.
for eligibility_band in findings review_feedback abandoned_drafts merge_conflicts dequeued register_hygiene human_visibility tech_debt; do
  while IFS= read -r eb_slug; do
    [[ -n "$eb_slug" ]] || continue
    eb_current="$(jq -c --arg s "$eb_slug" --arg f "$eligibility_band" \
      'map(select(.slug == $s)) | .[0][$f] // []' <<<"$ordered_repos_json" 2>&1)" \
      || { guard_warn "eb_current:$eb_slug:$eligibility_band" "$eb_current"; eb_current='[]'; }
    # shellcheck disable=SC2154  # blocked_json/void_json are assigned by
    # compute_skip_lists (lib/candidate-gather.sh, #771), called above.
    eb_filtered="$(exclude_blocked_or_void_items "$eb_current" "$eb_slug" "$blocked_json" "$void_json")"
    ordered_repos_json="$(jq -c --arg r "$eb_slug" --arg f "$eligibility_band" --argjson v "$eb_filtered" \
      'map(if .slug == $r then .[$f] = $v else . end)' \
      <<<"$ordered_repos_json" 2>/dev/null || printf '%s' "$ordered_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
  done < <(jq -r --arg f "$eligibility_band" \
           '[.[] | select(((.[$f] // []) | length) > 0) | .slug] | unique[]' \
           <<<"$ordered_repos_json" 2>/dev/null || true)
done

while IFS= read -r iss_slug; do
  [[ -n "$iss_slug" ]] || continue
  iss_current="$(jq -c --arg s "$iss_slug" 'map(select(.slug == $s)) | .[0].issues // []' \
    <<<"$ordered_repos_json" 2>&1)" \
    || { guard_warn "iss_current:$iss_slug" "$iss_current"; iss_current='[]'; }
  iss_filtered="$(exclude_blocked_or_void_issues "$iss_current" "$iss_slug" "$blocked_json" "$void_json")"
  ordered_repos_json="$(jq -c --arg r "$iss_slug" --argjson iss "$iss_filtered" \
    'map(if .slug == $r then .issues = $iss else . end)' \
    <<<"$ordered_repos_json" 2>/dev/null || printf '%s' "$ordered_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -r '[.[] | select(((.issues // []) | length) > 0) | .slug] | unique[]' \
         <<<"$ordered_repos_json" 2>/dev/null || true)

# The third extract (requirement 3h): what a previous Enabler engagement
# specified for an item nobody had specified well enough to work on. For an
# issue the refinement is a comment and travels in the thread the Co-Ordinator
# already pastes; for every other item type this map is the only place it
# exists, and without it the refinement would be written, the item unblocked,
# and the next work order composed as if nothing had been settled.
refinements_json="$(refinements_map "$union_log")"

# A fourth, sibling extract (agent-ops#936, requirement 36d): a tactical
# decision a `decide-tactical` pass took in place of escalating, beside — not
# folded into — `refinements_json` above, since a decision settles a policy
# question rather than supplying a specification; the Refiner is what turns
# one into the other, the same way it would turn a human's own answer on a
# closed escalation into one.
decisions_json="$(decisions_map "$union_log")"
}

# compute_enabler_eligible_set — requirements 35a and 35b. Called once from
# `agent-cycle.sh`, immediately after `compute_band_eligibility` (#771).
# Ends by setting `enabler_allowed`, the flag the cleanup trap reads: before
# this point an early exit could not have engaged the Enabler at all.
compute_enabler_eligible_set() {
# --- The Enabler's eligible set (requirements 35a, 35b) ---
# Which repos' open issues this cycle can see, taken from the source-state
# digests of the repos that sampled cleanly. It is how "is that escalation issue
# still open?" gets answered without a `gh` call per escalation — the digest was
# fetched for the fingerprint anyway. A repo absent from it is one this cycle did
# not read cleanly, or did not look at (`--repo`), and its escalations are
# treated as possibly still open.
# shellcheck disable=SC2154  # source_states_json is assigned by
# gather_ordered_repos (lib/candidate-gather.sh, #771), called above.
open_issues_json="$(jq -c '[.[] | select(.ok == true)
                            | {key: .slug, value: [(.issues // [])[] | .n]}]
                           | from_entries' <<<"$source_states_json" 2>/dev/null || true)"
[[ -n "$open_issues_json" ]] || open_issues_json='{}'

enabler_eligible_json="$(enabler_eligible_items "$union_log" \
  "$enabler_after_coordinator_cycles" "$enabler_recheck_hours" "$open_issues_json" \
  "" "$refinement_after_coordinator_cycles")"

# Issue #238's third acceptance: a blocked `merge-conflicts`/`dequeued`/
# `abandoned-drafts` item's ref is scoped to the head SHA it was detected at
# (requirements 3e, 3g, 3z) precisely so a later push mints a fresh ref that
# no old block covers — but the old ref itself is never cleared, only
# superseded, so without this filter it would sit `enabler_eligible` forever,
# costing a full engagement every time its recheck clock came round only to be
# voided as stale (as happened to `pr-205-conflict-305ca060016d`, claimed and
# voided three minutes later). This cycle's own fresh
# `merge_conflicts`/`dequeued`/`abandoned_drafts` arrays — snapshotted into
# `live_pr_refs_json` by `compute_band_eligibility` above, before its own
# subtraction loop removes every blocked entry from those same bands in
# `ordered_repos_json` (requirement 35e, issue #1119) — are the current truth
# for every PR still in any of those states; a SHA-scoped ref absent from them
# has been superseded (a newer push), resolved, or requeued, either way stale.
# Only refs shaped `pr-<n>-conflict-<sha>`/`pr-<n>-superseded-<sha>`/
# `pr-<n>-dequeued-<sha>`/`pr-<n>-abandoned-<sha>` are tested — the
# merge-conflicts gather mints the first two (requirement 3g), both scoped to
# the same head SHA, so both go stale the same way, and a refused supersession
# void is recorded blocked under the second (requirement 32a) exactly as a
# refused conflict void is under the first. `pr-<n>-dequeued-<sha>` (the
# gather-dequeued.sh gather, requirement 3z) goes stale the identical way: a
# fresh push (a fix, or anyone else's) or a re-queue mints no *new* ref this
# script would test — it simply stops appearing in `dequeued`, which is what
# "absent from the live set" already means. Every other blocked item kind (a
# tech-debt id, an issue number, a review-feedback round) has no such
# re-detectable "current" state to compare against, and
# `test` on a plain id or number simply never matches the pattern. A jq
# failure leaves the set unfiltered: this is a cost saving, never the
# correctness gate (the Enabler still voids a stale item it does reach).
# An *empty* live set and a *failed* derivation of one are opposite facts, and
# only the guard below keeps them apart. Empty-on-success is meaningful — no PR
# is in either state this cycle, so every SHA-scoped ref really is superseded or
# resolved — but a jq failure knows nothing about any PR, and feeding its result
# in as an empty set would mark every eligible conflict/abandoned ref stale and
# drop the lot: maximal filtering, the exact opposite of the unfiltered
# degradation the comment above and requirement 35e both promise. Failure alone
# yields the empty *string* (jq prints nothing to stdout on error, and prints
# `[]` at minimum on success), so testing for it skips the filter outright.
#
# `as $repo`/`as $item` before piping into `$live`: `|` rebinds `.` to its
# right-hand side for everything downstream, `$live` included, so reading
# `.repo`/`.item` *after* `$live |` would read them off the live-refs array
# instead of off the eligible entry — jq has no other way to hold onto the
# outer `.` across a nested pipe.
stale_enabler_refs_json='[]'
[[ -z "$live_pr_refs_json" ]] || { stale_enabler_refs_json="$(jq -c --argjson live "$live_pr_refs_json" '
  [ .[] | (.repo // "") as $repo | (.item // "") as $item
        | select(($item | test("^pr-[0-9]+-(conflict|superseded|dequeued|abandoned)-[0-9a-f]+$"))
                 and (($live | index($repo + "#" + $item)) == null)) ]
  ' <<<"$enabler_eligible_json" 2>&1)" \
  || { guard_warn "stale_enabler_refs_json" "$stale_enabler_refs_json"; stale_enabler_refs_json='[]'; }; }
stale_enabler_refs_n="$(jq 'length' <<<"$stale_enabler_refs_json" 2>&1)" \
  || { guard_warn "stale_enabler_refs_n" "$stale_enabler_refs_n"; stale_enabler_refs_n=0; }
if [[ "$stale_enabler_refs_n" != "0" ]]; then
  # An *object* payload ({skipped: [...]}), never the bare array: log_event's
  # envelope merge can only add objects, and the bare-array form of this exact
  # line is what crash-looped the fleet on 2026-08-13 (issue #361).
  log_event "enabler-stale-refs-skipped" "$(jq -c '{skipped: [.[] | {repo, item}]}' <<<"$stale_enabler_refs_json")"
  enabler_eligible_json="$(jq -c --argjson stale "$stale_enabler_refs_json" '
    ($stale | map((.repo // "") + "#" + (.item // ""))) as $staleset
    | [ .[] | (.repo // "") as $repo | (.item // "") as $item
            | select(($staleset | index($repo + "#" + $item)) == null) ]
    ' <<<"$enabler_eligible_json" 2>/dev/null || printf '%s' "$enabler_eligible_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
fi

# Past this line the exit trap may engage the Enabler: every input it needs now
# exists, so `maybe_run_enabler`'s own guards are all that stand between this
# cycle and an engagement. Before it, an early exit could not have one.
enabler_allowed=1
}

# prefetch_refiner_sources — requirement 3y (TD-PPagop-26081307). Called once
# from `agent-cycle.sh`, after the Enabler set and before the Refiner's own
# candidate set (#771).
prefetch_refiner_sources() {
# --- Refiner-only pre-fetch: project-review and implementation-plan
# (requirement 3y; TD-PPagop-26081307) ---
# `ordered_repos_json` — the Co-Ordinator's own input — never gains these two
# arrays: the Co-Ordinator keeps reading `reviews/…` and the plan document
# live (prompts/coordinator.md's "Project-review recommendations" and
# "implementation-plan" bullets). `refiner_repos_json` is a separate copy,
# augmented per repo only where the read is worth paying for: this installation
# has a Refiner at all (`refiner_model` — `maybe_run_refiner`'s own first guard,
# so with it empty every read here buys an array no engagement can ever spend),
# the repo's own `sources` lists the source *and* `refinement_policy` for it is
# not exempt (nothing would ever read an exempt source's candidates), and for
# `implementation-plan`, only where `implementation_plan_path` is configured
# (the same startup guard that requires it already refused to run otherwise).
refiner_repos_json="$ordered_repos_json"
if [[ -n "$refiner_model" ]]; then
  # This repository's own resolved report_directory (its override in
  # project_review.repos, or project_review.defaults' otherwise, requirement
  # 342) — or, absent from project_review entirely (this repo may not even be
  # one review-cycle.sh reviews), the same ultimate fallback review-cycle.sh
  # itself falls back to (issue #761). Computed once, outside the loop: every
  # repository's own resolved value is a lookup against this, not a fresh
  # derivation.
  refiner_project_review_repos_json="$(config_project_review_repos "$DEFAULTED_CONFIG")"
  while IFS=$'\t' read -r rp_slug rp_branch; do
    [[ -n "$rp_slug" ]] || continue
    rp_entry="$(jq -c --arg s "$rp_slug" 'map(select(.slug == $s)) | .[0] // {}' \
      <<<"$ordered_repos_json" 2>&1)" || { guard_warn "refiner:rp_entry" "$rp_entry"; rp_entry='{}'; }
    rp_sources="$(jq -c '.sources // []' <<<"$rp_entry" 2>&1)" \
      || { guard_warn "refiner:rp_sources" "$rp_sources"; rp_sources='[]'; }
    rp_pr='[]'
    if jq -e 'any(.[]; . == "project-review")' <<<"$rp_sources" >/dev/null 2>&1 \
       && [[ "$(refiner_policy_value "project-review" "$refinement_policy_json")" != "exempt" ]]; then
      rp_report_directory="$(jq -r --arg s "$rp_slug" \
        'map(select(.slug == $s)) | .[0].report_directory // ""' \
        <<<"$refiner_project_review_repos_json" 2>/dev/null || true)"
      [[ -n "$rp_report_directory" ]] || rp_report_directory="$REPORT_DIRECTORY_DEFAULT"
      rp_pr="$(gather_project_review_candidates "$rp_slug" "$rp_branch" "$rp_report_directory")"
    fi
    rp_ip='[]'
    rp_path="$(jq -r '.implementation_plan_path // ""' <<<"$rp_entry" 2>/dev/null || true)"
    if jq -e 'any(.[]; . == "implementation-plan")' <<<"$rp_sources" >/dev/null 2>&1 \
       && [[ -n "$rp_path" ]] \
       && [[ "$(refiner_policy_value "implementation-plan" "$refinement_policy_json")" != "exempt" ]]; then
      rp_ip="$(gather_implementation_plan_candidates "$rp_slug" "$rp_branch" "$rp_path")"
    fi
    if [[ "$rp_pr" != "[]" || "$rp_ip" != "[]" ]]; then
      refiner_repos_json="$(jq -c --arg s "$rp_slug" --argjson pr "$rp_pr" --argjson ip "$rp_ip" \
        'map(if .slug == $s then . + {project_review: $pr, implementation_plan: $ip} else . end)' \
        <<<"$refiner_repos_json" 2>/dev/null || printf '%s' "$refiner_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
    fi
  done < <(jq -r '.[] | .slug + "\t" + .default_branch' <<<"$ordered_repos_json" 2>/dev/null || true)
fi
}

# compute_refiner_candidates — requirement 39a. Called once from
# `agent-cycle.sh`, last of the four (#771), and like the Enabler set it ends
# by setting the flag (`refiner_allowed`) the cleanup trap reads.
compute_refiner_candidates() {
# --- The Refiner's candidate set (requirement 39a) ---
# Every pre-fetched item this cycle's `refiner_repos_json` carries whose source
# is not `refinement_policy`-exempt, is not already refined, blocked, void, or
# claimed. Computed from the same extracts the Enabler's eligible set just
# used, so a Refiner engagement and an Enabler engagement in the same cycle
# never disagree about what is already spoken for. `refiner_repos_json`
# rather than `ordered_repos_json` only because it carries the two arrays
# above the Co-Ordinator's own input never gains — every other field is the
# same, so nothing else about the candidate rule below needs to know a
# separate array exists.
refiner_candidates_json="$(refiner_candidate_items "$refiner_repos_json" \
  "$refinement_policy_json" "$refinements_json" "$blocked_json" "$void_json" "$claimed_json" \
  "$decisions_json")"
# issue #511, extended by issue #542: drop this cycle's `triage_only`
# candidates from any repository whose `Priority` field this token cannot
# resolve at all, or which resolves carrying none of the four band names,
# before the engagement cap or any claim — a pre-flight, not a post-hoc
# latch, so field visibility, or a renamed option set, recovering needs no
# operator action. Run unconditionally whenever this installation has a
# Refiner (`refiner_model` set), including under --dry-run, so the
# fingerprint input below never differs between a dry-run and a live cycle
# for no reason. Skipped outright when `refiner_model` is empty — with no
# Refiner to spend an engagement on a triage-only candidate either way, the
# GraphQL read this performs, and any `refiner:` warning it can log, would
# cost every cycle for a stage that never runs (issue #567).
if [[ -n "$refiner_model" ]]; then
  refiner_candidates_json="$(refiner_filter_unbandable_triage "$refiner_candidates_json")"
fi
# Same reasoning as `enabler_allowed` above, for the same kind of exit-trap
# engagement.
refiner_allowed=1
}
