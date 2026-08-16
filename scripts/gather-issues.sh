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
# The `Priority` band is read exactly as gather-source-state.sh reads it for
# the fingerprint digest — same field, same four names, same Medium default —
# because if the two disagreed, the digest would be stable while the
# candidate set changed (or the reverse), which is the failure requirement 3b
# exists to prevent.
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
# Both reads take one 100-item page, like every gatherer here. More than 100
# open unassigned issues, or a thread past 100 comments, is a repo-hygiene
# problem before it is a gathering one — but the bound is stated here so
# nobody has to rediscover it from a truncated thread.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"
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

# Print the empty shape and exit 0, having said why on stderr: a gatherer
# that aborted the cycle would make cost control a reliability risk.
# `excluded: null`, not `[]` — see "Degrading" above.
degrade() {
  echo "gather-issues: $slug: $*" >&2
  printf '{"candidates":[],"excluded":null}\n'
  exit 0
}

issues_raw="$(gh api "repos/$slug/issues?state=open&per_page=100")" \
  || degrade "issues list fetch failed"
jq -e 'type == "array"' <<<"$issues_raw" >/dev/null 2>&1 \
  || degrade "issues list payload is not an array"

# The deterministic filter and the entry shape. `has("pull_request")` drops
# the PRs the issues endpoint interleaves — never reported in `excluded`,
# since a PR was never a candidate issue to begin with; the assignees check
# drops assigned issues (requirement 16.4's deterministic half — this also
# covers the Enabler's escalation issues, which are always assigned); the
# label check drops `blocked` whatever its case. The Priority parse mirrors
# gather-source-state.sh verbatim.
#
# `excluded` mirrors the same two drops, reason-tagged (agent-ops#447):
# assigned wins the tag when an issue is somehow both assigned and
# `blocked`-labelled, matching the order the filter below checks them in.
#
# A third, structured drop happens below, once each candidate's whole thread
# is in hand: a `Blocked-by:` reference (requirement 34j) naming a still-open
# issue or pull request holds the candidate back the same way —
# deterministically, before the Co-Ordinator ever sees it — so an item
# declaring a dependency never earns a judgement, or an `attempt-failed`,
# while that dependency stands. It is appended to `excluded` in the loop
# below, once the unresolved reference is known.
candidates="$(jq -c '
  [.[]
   | select(has("pull_request") | not)
   | select(((.assignees // []) | length) == 0)
   | select(([.labels[]?.name | ascii_downcase] | index("blocked")) | not)
   | {number: .number,
      url: .html_url,
      title: .title,
      priority: (([.issue_field_values[]? | select(.issue_field_name == "Priority")
                                          | .single_select_option.name
                                          | select(. == "Urgent" or . == "High"
                                                   or . == "Medium" or . == "Low")] | first) // "Medium"),
      labels: ([.labels[]?.name] | sort),
      author: (.user.login // ""),
      created_at: .created_at,
      updated_at: .updated_at,
      body: (.body // "")}]
  | sort_by(.number)' <<<"$issues_raw" 2>/dev/null)" \
  || degrade "issues filter failed"

excluded="$(jq -c '
  [.[]
   | select(has("pull_request") | not)
   | select(((.assignees // []) | length) > 0
            or (([.labels[]?.name | ascii_downcase] | index("blocked")) != null))
   | {number: .number,
      reason: (if ((.assignees // []) | length) > 0 then "assigned" else "blocked-label" end)}]
  | sort_by(.number)' <<<"$issues_raw" 2>/dev/null)" \
  || degrade "issues excluded-filter failed"

out='[]'
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  n="$(jq -r '.number' <<<"$candidate")"
  comments="$(gh api "repos/$slug/issues/$n/comments?per_page=100" \
      --jq '[.[] | {author: (.user.login // ""), created_at: .created_at, body: (.body // "")}]')" \
    || degrade "comments fetch failed for issue #$n"
  jq -e 'type == "array"' <<<"$comments" >/dev/null 2>&1 \
    || degrade "comments payload for issue #$n is not an array"

  # Requirement 34j: a `Blocked-by:` reference, in the body or any comment,
  # holds this candidate back until every reference it names is closed —
  # checked live, right here, because this is the one place that has both
  # the whole thread and a `gh` budget for it. Any reference still open (or
  # unreadable — an unknown reference decides nothing, the same direction
  # every other deterministic exclusion here fails safe in) drops the
  # candidate entirely, before the comparatively expensive comments payload
  # above is put to any other use.
  thread_text="$(jq -r '.body' <<<"$candidate")
$(jq -r '[.[].body] | join("\n")' <<<"$comments")"
  dep_refs="$(dependency_refs "$thread_text")"
  if [[ "$(jq 'length' <<<"$dep_refs" 2>/dev/null || echo 0)" != "0" ]]; then
    dep_unresolved=0
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      if [[ "$ref" == */* ]]; then
        ref_repo="${ref%%#*}"
        ref_n="${ref##*#}"
      else
        ref_repo="$slug"
        ref_n="$ref"
      fi
      ref_state="$(gh api "repos/$ref_repo/issues/$ref_n" --jq '.state' 2>/dev/null || true)"
      if [[ "$ref_state" != "closed" ]]; then
        dep_unresolved=1
        break
      fi
    done < <(jq -r '.[]' <<<"$dep_refs")
    if (( dep_unresolved == 1 )); then
      # $ref still names the one unresolved reference the loop above broke
      # on — bash keeps a loop variable's value past its own `break`. It is
      # bare (`195`) for a same-repo reference and already qualified
      # (`owner/repo#42`) for a cross-repo one (see dependency_refs); a
      # display form always carries the `#` a reader expects.
      ref_display="$ref"; [[ "$ref_display" == */* ]] || ref_display="#$ref_display"
      excl_entry="$(jq -nc --argjson n "$n" --arg ref "$ref_display" \
        '{number: $n, reason: ("blocked-by: " + $ref)}')" || degrade "excluded entry assembly failed for issue #$n"
      excluded="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' <<<"$excluded"$'\n'"$excl_entry")" \
        || degrade "excluded array assembly failed at issue #$n"
      continue
    fi
  fi

  # $comments is a whole issue thread — requirement 3d/#118 pre-fetches every
  # comment — unbounded past this call (requirement 4g, TD-PPagop-26081406).
  # $candidate and $comments arrive on stdin, bound positionally with `input
  # as $name` in the order printed, never in argv.
  entry="$(jq -nc 'input as $candidate | input as $comments |
    {source: "issues", ref: ($candidate.number | tostring)} + $candidate + {comments: $comments}' \
    <<<"$candidate"$'\n'"$comments")" || degrade "entry assembly failed for issue #$n"
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
