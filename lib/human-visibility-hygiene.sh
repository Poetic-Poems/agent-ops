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
# listing failure that names no pull request at all — and keeps only the
# latest event per identity, the same "most recent wins" rule
# `_latest_unresolved` applies to a block and its clearance. A `warning` is
# the violation; `human-review-requested` and `human-nudged` are the sweep
# succeeding for that same identity afterwards, and either clears it — the
# sweep needs no dedicated "resolved" event of its own, because succeeding
# at the *next* thing it would have done for that pull request already
# proves the read it once could not make now works.
#
# A repo-level listing failure (empty `pr_url`) has no such per-PR success to
# clear it — a listing that succeeds with nothing to act on logs nothing at
# all — so this alone would leave a one-off blip flagged forever. It is
# still worth returning: the caller (scripts/gather-human-visibility-hygiene.sh)
# re-runs the listing live before treating it as a candidate, which is the
# check this reduction cannot make from a log alone.
#
# human_visibility_violations [LOG_FILE]
# Print, as a JSON array, one entry per identity whose latest human-visibility
# sweep event is still a `warning`: {repo, pr_url, detail, ts}. `pr_url` is ""
# for a repo-level (listing) violation. Reads LOG_FILE, or stdin if it is
# omitted or "-". Always succeeds, printing [] for a missing, empty or
# unreadable log, or one with no human-visibility events at all.
# shellcheck disable=SC2016  # jq's $m/$r, not the shell's.
HUMAN_VISIBILITY_VIOLATIONS_JQ='
  [ .[] | select(
      (.event == "warning" and ((.detail // "") | startswith("human-visibility sweep (")))
      or .event == "human-review-requested"
      or .event == "human-nudged") ]
  | map(
      if .event == "warning" then
        (.detail | capture("^human-visibility sweep \\((?<repo>[^)]+)\\): (?<rest>.*)$")?) as $m
        | if $m == null then empty else
            ($m.rest | fromjson? // {}) as $r
            | {repo: $m.repo, pr_url: ($r.pr_url // ""), kind: "warning",
               detail: ($r.detail // ""), ts: (.ts // "")}
          end
      else
        {repo: (.repo // ""), pr_url: (.pr_url // ""), kind: "ok", detail: "", ts: (.ts // "")}
      end)
  | map(select(.repo != ""))
  | group_by(if .pr_url != "" then .pr_url else .repo end)
  | map(sort_by(.ts) | last)
  | map(select(.kind == "warning"))
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
