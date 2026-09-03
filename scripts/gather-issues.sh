#!/usr/bin/env bash
#
# gather-issues.sh — deterministically pre-fetch one repo's open issues, whole
# threads included, for the Co-Ordinator's runtime input
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 3j).
#
# Usage: gather-issues.sh <owner/repo>
#
# Prints one JSON object, `{"candidates": […], "excluded": […]|null}`:
#
# `candidates` — one entry per candidate issue:
#
#   {
#     "source": "issues",
#     "ref": "125",                  // the bare issue number — the item ref
#     "number": 125,
#     "url": "https://github.com/…/issues/125",
#     "title": "…",
#     "priority": "Medium",          // the Priority band, default Medium (15e)
#     "priority_set": false,         // true iff any option is set on the field, even one
#                                     // outside the four recognised names (requirement 39g)
#     "labels": ["…"],
#     "author": "…",
#     "created_at": "…", "updated_at": "…",
#     "body": "…verbatim…",
#     "comments": [{"author": "…", "created_at": "…", "body": "…verbatim…"}]
#   }
#
# `excluded` — one entry per issue the deterministic filter below dropped
# (requirement 16.4's deterministic half; agent-ops#447), each
# `{"number": 125, "reason": "assigned" | "blocked-label" | "blocked-by: <ref>"}`
# — never a PR the issues endpoint interleaves, which is dropped unreported
# because it was never a candidate issue to begin with. This is what lets a
# caller report "N issues excluded, and why" instead of a drop nothing else
# ever recorded: before this, the three deterministic drops removed an issue
# from candidacy with nothing on stdout, nothing on stderr, and nothing in
# the shared log to say it had happened. `excluded` is `null`, never `[]`,
# when the deterministic filter did not run to completion (see "Degrading"
# below) — an empty array asserts "gathered, and nothing was excluded",
# which a failed or partial gather does not know to be true (review decision
# on agent-ops#452 concern 3).
#
# An issue labelled `pw::type:tech-debt` is dropped from `candidates` too
# (D15 as revised, #869; issue #875), on the same unreported terms as a pull
# request: it belongs to the `tech-debt` band instead
# (scripts/gather-tech-debt.sh), so it was never an `issues` candidate to
# begin with, and keeping the two bands disjoint is not a deterministic-filter
# drop `excluded` needs to explain.
#
# ## Why issues are pre-fetched at all
#
# The issues source used to be the Co-Ordinator's own read: the prompt said
# "query the issues API yourself", and nothing in the runtime input carried a
# single issue. That contract turned out to fail closed in the worst way: a
# cycle was observed (20260727T145500Z-poetic-1-1431114) in which the
# Co-Ordinator, seeing pre-fetched arrays for every *other* source, reasoned
# "no issue data provided in input; per the prompt, I do not re-query" — a
# rule that never existed — and skipped the entire issues walk while six
# selectable issues sat open. A source the model can silently decline to read
# is the model-side twin of the fingerprint gap requirement 3b warns about:
# no error, no alert, just tidy none-selected events over live work. Handing
# the candidates over pre-fetched, like every source that has drifted this
# way before (findings, review-feedback, merge-conflicts, abandoned-drafts,
# register-hygiene), removes the ambiguity instead of wording it away.
#
# ## What is filtered here, and what is not
#
# Requirement 16's issue exclusion has two halves. The *deterministic* half —
# an issue that is assigned, or labelled `blocked` (case-insensitive), or
# names an unresolved `Blocked-by:` dependency (requirement 34j, checked
# further down once each candidate's thread is in hand) — is applied here, so
# the Co-Ordinator never spends judgement on entries no rule would let it
# pick; pull requests (which the issues endpoint also returns) are dropped
# the same way. The *judgement* half — "a question or discussion rather than
# actionable work", read over the whole thread — cannot be a jq filter, and
# stays the Co-Ordinator's (requirement 16.4), which is exactly why
# requirement 3x obliges it to *report* that judgement in `needs_refinement`
# rather than skip in silence: it is the one decline in any pre-fetched band
# nothing here can record, and an unrecorded decline is a band the Script's
# own verdict corroboration cannot check. Items blocked in the shared
# log are NOT dropped here: the Co-Ordinator holds the blocked list and
# requirement 18a's re-check needs the issue's thread and `updated_at` in
# front of it to decide whether fresh evidence unblocks it.
#
# The `priority` field is read exactly as gather-source-state.sh reads it for
# the fingerprint digest — same field, same four names, same Medium default —
# because if the two disagreed, the digest would be stable while the
# candidate set changed (or the reverse), which is the failure requirement 3b
# exists to prevent. `priority_set` is this script's own addition, not
# gather-source-state.sh's, and reads the field more broadly than `priority`
# does on purpose: `priority` alone collapses "unset", "unreadable" and
# "explicitly Medium" into the same value (deliberately — it must agree with
# the Co-Ordinator's own default), so the Refiner's triage candidate rule
# (requirement 39g, `refiner_candidate_items`) needs this second boolean to
# tell an untriaged issue from a deliberately-Medium one at all — and it must
# be true for *any single-select option* a human or agent chose, including
# one outside the four names this pipeline ranks (an org admin can add a
# fifth at any time), or that issue reads as untriaged forever and never
# leaves the triage queue even once someone has banded it (agent-ops#509).
# A `Priority` field value carrying no `single_select_option` at all (GitHub
# also emits text/date/etc. field-value shapes; an admin can retype the
# field to a different type) contributes nothing to `$priority_names` — the
# `select(. != null)` guard drops it — so it reads as unset, not set
# (agent-ops#527).
#
# ## Degrading, and the 100-item windows
#
# Like gather-findings.sh — and unlike gather-source-state.sh — this output
# is *given to* the Co-Ordinator, so degrading `candidates` to `[]` (exit 0)
# on any API failure is safe: the fingerprint then faithfully records "the
# Co-Ordinator saw no issues", and the source-state issues digest, sampled
# independently, still busts the fingerprint when a real issue changes.
# `excluded` degrades to `null`, not `[]` — the caller's on-change
# `issues-excluded` logging (agent-cycle.sh, requirement 33) treats `null` as
# "unknown, do not compare" rather than as a release from exclusion, which an
# empty array would otherwise fabricate on every ordinary `gh` hiccup (review
# decision on agent-ops#452 concern 3). Failures are loud on stderr (teed
# into the cycle record as issues-<repo>.err) for the same reason
# gather-review-feedback.sh's are: an empty result indistinguishable from "no
# open issues" once cost a debugging round.
#
# `issue_prefetch_open_issues` (lib/issue-prefetch.sh, agent-ops#1085) pages
# the open-issues walk itself up to its own stated cap (2000 issues); each
# issue's own comment thread takes one 100-comment window, the newest 100
# where a thread runs longer — a thread past that, or a repository past the
# page cap, is a repo-hygiene problem before it is a gathering one, but both
# bounds are stated in that function's own header so nobody has to
# rediscover either from a truncated thread.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"
# The deterministic filter and the Blocked-by live-check, shared with
# scripts/gather-tech-debt.sh — see lib/issue-prefetch.sh.
# shellcheck source=lib/issue-prefetch.sh
. "$SCRIPT_DIR/lib/issue-prefetch.sh"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-issues.sh <owner/repo>" >&2
  exit 64
fi

# Print the degraded shape and exit 0, having said why on stderr: a gatherer
# that aborted the cycle would make cost control a reliability risk.
# `excluded: null`, not `[]` — see "Degrading" above.
degrade() {
  echo "gather-issues: $slug: $*" >&2
  printf '{"candidates":[],"excluded":null}\n'
  exit 0
}

# issue_prefetch_open_issues (lib/issue-prefetch.sh, agent-ops#1085) is one
# paginated GraphQL walk fetching every open issue's whole comment thread
# alongside it, replacing what was this REST listing call plus one further
# REST call per surviving candidate below — see that function's own header
# for the point-cost measurement. Exit 2 means its own page cap was reached
# before the repository's own open-issue count was: the array it still
# printed is used rather than discarded, the same "a truncated set is still
# useful, and the caller decides its own direction of harm" judgement
# `github_pr_list_truncated`'s own call sites already make explicit — a
# missed issue here is simply not offered as a candidate this cycle, not a
# gate silently letting something through it should have stopped.
issues_raw="$(issue_prefetch_open_issues "$slug")"; issues_raw_rc=$?
if (( issues_raw_rc == 1 )); then
  degrade "issues list fetch failed"
elif (( issues_raw_rc == 2 )); then
  echo "gather-issues: $slug: issue_prefetch_open_issues hit its own page cap — some open issues may be missing this cycle" >&2
fi
jq -e 'type == "array"' <<<"$issues_raw" >/dev/null 2>&1 \
  || degrade "issues list payload is not an array"

# The deterministic filter and the entry shape. `issue_deterministic_ok`
# (lib/issue-prefetch.sh, shared with scripts/gather-tech-debt.sh) drops the
# PRs the issues endpoint interleaves — never reported in `excluded`, since a
# PR was never a candidate issue to begin with — assigned issues (requirement
# 16.4's deterministic half — this also covers the Enabler's escalation
# issues, which are always assigned), and issues labelled `blocked` whatever
# their case. A `pw::type:tech-debt`-labelled issue is dropped too, the same
# way a PR is: it belongs to the `tech-debt` band instead (scripts/
# gather-tech-debt.sh), so keeping the two bands disjoint (D15 as revised,
# #869) is not a candidacy exclusion to report in `excluded` any more than a
# PR's own drop is — it was never an `issues` candidate to begin with.
# `priority`'s parse mirrors gather-source-state.sh verbatim; `priority_set`
# reads the same field more broadly, from the raw option names
# (`$priority_names`) rather than the filtered `$priority_values`, so it is
# true for any single-select option at all, not only the four ranked names —
# but not for a `Priority` value with no `single_select_option` at all, which
# `$priority_names` drops.
#
# `excluded` mirrors the assigned/blocked-label drops only, reason-tagged
# (agent-ops#447): assigned wins the tag when an issue is somehow both
# assigned and `blocked`-labelled, matching the order `issue_exclude_reason`
# checks them in.
#
# A third, structured drop happens below, once each candidate's whole thread
# is in hand: a `Blocked-by:` reference (requirement 34j) naming a still-open
# issue or pull request holds the candidate back the same way —
# deterministically, before the Co-Ordinator ever sees it — so an item
# declaring a dependency never earns a judgement, or an `attempt-failed`,
# while that dependency stands. It is appended to `excluded` in the loop
# below, once the unresolved reference is known.
candidates="$(jq -c "$ISSUE_DETERMINISTIC_FILTER_JQ"'
  [.[]
   | select(issue_deterministic_ok)
   | select(([.labels[]?.name] | index("pw::type:tech-debt")) == null)
   | ([.issue_field_values[]? | select(.issue_field_name == "Priority")
                              | .single_select_option.name
                              | select(. != null)]) as $priority_names
   | ($priority_names | map(select(. == "Urgent" or . == "High"
                                    or . == "Medium" or . == "Low"))) as $priority_values
   | {number: .number,
      url: .html_url,
      title: .title,
      priority: (($priority_values | first) // "Medium"),
      priority_set: (($priority_names | length) > 0),
      labels: ([.labels[]?.name] | sort),
      author: (.user.login // ""),
      created_at: .created_at,
      updated_at: .updated_at,
      body: (.body // ""),
      comments: [(.comments // [])[] | {author: (.user.login // ""), created_at: .created_at, body: (.body // "")}]}]
  | sort_by(.number)' <<<"$issues_raw" 2>/dev/null)" \
  || degrade "issues filter failed"

excluded="$(jq -c "$ISSUE_DETERMINISTIC_FILTER_JQ"'
  [.[]
   | select(has("pull_request") | not)
   | select(issue_exclude_reason != null)
   | {number: .number, reason: issue_exclude_reason}]
  | sort_by(.number)' <<<"$issues_raw" 2>/dev/null)" \
  || degrade "issues excluded-filter failed"

out='[]'
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  n="$(jq -r '.number' <<<"$candidate")"

  # Requirement 34j: a `Blocked-by:` reference, in the body or any comment,
  # holds this candidate back until every reference it names is closed —
  # checked live, right here, because this is the one place that has both
  # the whole thread and a `gh` budget for it. `issue_blocked_by_ref`
  # (lib/issue-prefetch.sh, shared with scripts/gather-tech-debt.sh) is the
  # live check; a printed reference drops the candidate entirely. `$candidate`
  # already carries its own thread (`issue_prefetch_open_issues` fetched it
  # alongside the listing itself, agent-ops#1085), so no further `gh` call is
  # made to get it.
  thread_text="$(jq -r '.body' <<<"$candidate")
$(jq -r '[.comments[].body] | join("\n")' <<<"$candidate")"
  ref_display="$(issue_blocked_by_ref "$slug" "$thread_text")"
  if [[ -n "$ref_display" ]]; then
    excl_entry="$(jq -nc --argjson n "$n" --arg ref "$ref_display" \
      '{number: $n, reason: ("blocked-by: " + $ref)}')" || degrade "excluded entry assembly failed for issue #$n"
    excluded="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$excluded"$'\n'"$excl_entry")" \
      || degrade "excluded array assembly failed at issue #$n"
    continue
  fi

  # $candidate already carries its own whole issue thread (requirement 3d/
  # #118) — unbounded past this call (requirement 4g, TD-PPagop-26081406) —
  # so it arrives on stdin, never in argv.
  entry="$(jq -c '{source: "issues", ref: (.number | tostring)} + .' \
    <<<"$candidate")" || degrade "entry assembly failed for issue #$n"
  # $entry and the accumulator both arrive on stdin the same way — never in
  # argv, where a single issue thread past MAX_ARG_STRLEN would abort this
  # append.
  out="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$out"$'\n'"$entry")" \
    || degrade "array assembly failed at issue #$n"
done < <(jq -c '.[]' <<<"$candidates")

# $out and $excluded both arrive on stdin, never as --argjson: both are
# unbounded past this call the same way requirement 4g already treats every
# other aggregate this script builds.
printf '%s\n' "$out" "$excluded" \
  | jq -nc 'input as $c | input as $e | {candidates: $c, excluded: ($e | sort_by(.number))}'
