#!/usr/bin/env bash
#
# lib/human-visibility-hygiene.sh — which of requirement 38c's sweep warnings
# are still live, read from the fleet's log union (requirement 38e).
#
# `scripts/sweep-human-visibility.sh` self-heals almost every human-visibility
# violation it finds, in the same pass it finds it. The residual case — a `gh`
# read or the review-request POST itself failing — becomes a `warning` event
# and nothing more: no selectable work, nothing that tracks whether it recurs
# (tech-debt/TD-PPagop-26080801.md). This file is the read-back half of the
# fix: a pure reduction over the log union, exactly like `blocked_items` and
# `void_items` (lib/cycle-state.sh), that turns those `warning` events back
# into the set of violations still standing.
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail`.

# `human_visibility_violations` groups the sweep's own events by identity —
# a pull request's `pr_url` where one is named, the bare `repo` for a
# listing failure that names no pull request at all — and replays each
# identity's events in order, tracking one standing violation at a time: a
# `warning` always becomes the new standing violation, regardless of what
# came before, the same "latest detail wins" rule `_latest_unresolved`
# applies to a block and its clearance (lib/cycle-state.sh).
#
# Clearing an `ok` event (`human-review-requested`, `human-nudged`,
# `human-dequeue-notice` — the sweep succeeding at something for that same
# identity) is narrower: it only clears the identity's *standing* violation
# when the two share a family — `review-request`, `nudge` or
# `dequeue-notice`, matched between a warning's own detail text and the
# action that produced the `ok` event. Three distinct actions can now fire
# for one pull request inside a single sweep pass (agent-ops#374, #388), and
# succeeding at one proves nothing about whether either of the other two
# would have: posting a merge-queue-dequeue notice says nothing about
# whether the review-request POST that also failed this pass would now
# succeed. Before this family split, any later `ok` event cleared *any*
# standing warning for the identity — so a dequeue notice posting
# successfully could silently mask a same-pass `could not request review
# from …` warning, invisible until the human noticed the review was never
# actually requested (agent-ops#393).
#
# A warning shape none of the three families recognises — most often "could
# not read the pull request's state …", the read that gates every
# downstream check this sweep makes for that pull request — keeps the
# original, wider rule: any `ok` event for the identity clears it, since
# every one of those three actions depends on the same read having worked.
# This is the fail-safe direction: a family split that is too eager to
# distinguish would leave a resolved "I can't even read this pull request"
# warning stuck forever behind a family match that can never come, which is
# worse than the over-clearing this fix removes.
#
# A repo-level listing failure (empty `pr_url`) has no such per-PR success to
# clear it — a listing that succeeds with nothing to act on logs nothing at
# all — so this alone would leave a one-off blip flagged forever. It is
# still worth returning: the caller (scripts/gather-human-visibility-hygiene.sh)
# re-runs the listing live before treating it as a candidate, which is the
# check this reduction cannot make from a log alone.
#
# human_visibility_violations [LOG_FILE]
# Print, as a JSON array, one entry per identity whose standing
# human-visibility violation has not been family-cleared: {repo, pr_url,
# detail, ts}. `pr_url` is "" for a repo-level (listing) violation. Reads
# LOG_FILE, or stdin if it is omitted or "-". Always succeeds, printing []
# for a missing, empty or unreadable log, or one with no human-visibility
# events at all.
# shellcheck disable=SC2016  # jq's $m/$r, not the shell's.
HUMAN_VISIBILITY_VIOLATIONS_JQ='
  def warning_family:
    if startswith("could not request review from")
       or startswith("no legal review-request candidate")
       or startswith("could not re-request review after an answered round")
       or startswith("could not tell whether the blocking review round was answered")
      then "review-request"
    elif startswith("could not post the idle nudge comment") then "nudge"
    elif startswith("could not post the merge-queue-dequeued notice") then "dequeue-notice"
    else "generic"
    end;
  [ .[] | select(
      (.event == "warning" and ((.detail // "") | startswith("human-visibility sweep (")))
      or .event == "human-review-requested"
      or .event == "human-nudged"
      or .event == "human-dequeue-notice") ]
  | map(
      if .event == "warning" then
        (.detail | capture("^human-visibility sweep \\((?<repo>[^)]+)\\): (?<rest>.*)$")?) as $m
        | if $m == null then empty else
            ($m.rest | fromjson? // {}) as $r
            | {repo: $m.repo, pr_url: ($r.pr_url // ""), kind: "warning",
               family: (($r.detail // "") | warning_family),
               detail: ($r.detail // ""), ts: (.ts // "")}
          end
      elif .event == "human-review-requested" then
        {repo: (.repo // ""), pr_url: (.pr_url // ""), kind: "ok",
         family: "review-request", detail: "", ts: (.ts // "")}
      elif .event == "human-nudged" then
        {repo: (.repo // ""), pr_url: (.pr_url // ""), kind: "ok",
         family: "nudge", detail: "", ts: (.ts // "")}
      else
        {repo: (.repo // ""), pr_url: (.pr_url // ""), kind: "ok",
         family: "dequeue-notice", detail: "", ts: (.ts // "")}
      end)
  | map(select(.repo != ""))
  | group_by(if .pr_url != "" then .pr_url else .repo end)
  | map(sort_by(.ts)
        | reduce .[] as $e (null;
            if $e.kind == "warning" then $e
            elif . != null and (.family == $e.family or .family == "generic") then null
            else .
            end))
  | map(select(. != null))
  | map({repo, pr_url, detail, ts})
'
human_visibility_violations() {
  local src="${1:--}" out=""
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$HUMAN_VISIBILITY_VIOLATIONS_JQ" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$HUMAN_VISIBILITY_VIOLATIONS_JQ" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}
