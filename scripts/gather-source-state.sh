#!/usr/bin/env bash
#
# gather-source-state.sh — sample the cheap change-detection signals for one
# repo's work sources (docs/IMPLEMENTATION-PIPELINE-SPEC.md,
# requirement 3b).
#
# Given a repo slug and its default branch, print one JSON object digesting
# everything the Co-Ordinator's verdict depends on but does *not* receive in
# its runtime input — the things it would go and read for itself. The Script
# hashes this (with the inputs it does pass) into the no-op fingerprint that
# decides whether engaging the Co-Ordinator at all could possibly produce a
# different answer than last time.
#
# Usage: gather-source-state.sh <owner/repo> <default-branch>
#
# Output shape:
#   {
#     "slug": "Poetic-Poems/poetic",
#     "ok": true,
#     "head_sha": "…",                                       // tech-debt, plan, review, code
#     "issues":    [{"n":7,"u":"…","l":["bug"],"a":""}],     // issues source
#     "workflows": [{"w":123,"c":"failure"}],                // failed-runs source
#     "open_prs":  [{"n":9,"u":"…","h":"agent/x","d":true}]  // claim signals
#   }
#
# ## `ok` is the whole safety argument
#
# Each signal is fetched with `gh api`, which exits non-zero on an HTTP error
# but zero on a legitimately empty result. The distinction matters enormously
# here, and in a way it does not for gather-findings.sh:
#
#   - gather-findings.sh may degrade to `[]`, because its output is *given to
#     the Co-Ordinator*. If the alerts API is down, the Co-Ordinator sees no
#     findings and declines — and a fingerprint saying "no findings" is a
#     faithful record of the input the Co-Ordinator actually got. The skip and
#     the model agree, which is exactly the contract.
#   - This script must not, because its output is a *proxy* for reads the
#     Co-Ordinator performs itself. A failing issues API that degraded to `[]`
#     would produce a stable, wrong "nothing changed" digest while the
#     Co-Ordinator, reading the API directly, would have found live work. Two
#     consecutive failures would then match each other and skip the cycle —
#     and go on skipping for as long as the API stayed down. Silent, green,
#     and indefinitely idle: the exact failure this system is prone to.
#
# So an API error sets `ok: false` and the Script refuses to fingerprint at
# all: no skip, and no fingerprint recorded against a `none-selected`. The cost
# of a false `ok: false` is one Co-Ordinator run — which is what we would have
# paid anyway.
#
# Never exits non-zero: it always prints a valid object, marking `ok: false`
# when it could not sample cleanly. A gatherer that aborted the cycle would
# make cost control a reliability risk, which is a bad trade at any saving.

set -uo pipefail

slug="${1:-}"
branch="${2:-}"
if [[ -z "$slug" || -z "$branch" ]]; then
  echo "usage: gather-source-state.sh <owner/repo> <default-branch>" >&2
  exit 64
fi

# api_json FALLBACK JQ_FILTER API_PATH
# Print the API result filtered by JQ_FILTER, and return 0. On any failure —
# HTTP error, unparseable body, a filter that yields nothing — print FALLBACK
# and return 1.
#
# The status is the caller's signal to flip `ok`; it cannot be flipped in here,
# because every call site is a command substitution and an assignment made in
# that subshell dies with it. (That bug is invisible: the script keeps printing
# a well-formed object which always claims `ok: true`, and the fingerprint it
# feeds would then trust digests built from failed calls — precisely the case
# `ok` exists to catch.)
#
# JQ_FILTER must yield JSON, not a bare string: `gh api --jq` prints string
# results raw, so a filter of `.sha` emits `abc123`, which is not JSON and
# would fail the validation below on every healthy call. Pipe scalars through
# `@json` (`.sha | @json`).
api_json() {
  local fallback="$1" filter="$2" path="$3" out
  if out="$(gh api "$path" --jq "$filter" 2>/dev/null)" \
     && [[ -n "$out" ]] \
     && jq -e . <<<"$out" >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  printf '%s' "$fallback"
  return 1
}

ok=true

# The default branch's head. One SHA covers every file-backed source at once —
# TECH-DEBT.md, docs/IMPLEMENTATION-PLAN.md, reviews/, CLAUDE.md and the code
# itself — because none of them can change without it changing.
head_sha="$(api_json '""' '.sha | @json' "repos/$slug/commits/$branch")" || ok=false

# Open issues. `updated_at` moves on a comment, a label, a title edit or an
# assignment, and labels/assignee are themselves exclusion criteria
# (requirement 16.4) — so a triage action that makes an issue selectable, or
# stops it being, always moves this digest.
#
# `repos/<slug>/issues` returns pull requests too; they are dropped here and
# sampled properly below.
issues="$(api_json '[]' \
  '[.[] | select(has("pull_request") | not)
        | {n: .number, u: .updated_at, l: ([.labels[].name] | sort), a: (.assignee.login // "")}]
   | sort_by(.n)' \
  "repos/$slug/issues?state=open&per_page=100")" || ok=false

# The conclusion of each workflow's latest *completed* run on the default
# branch. This is the one source whose state can change with no commit at all:
# a scheduled run, or a re-run, can turn `main` red (or green) while every SHA
# stays put. Keyed on the workflow, taking the highest run id, mirroring
# requirement 15's rule that only the *most recent* run of a workflow counts.
#
# The run id is deliberately *not* part of the digest, only the conclusion it
# reached. Requirement 15's candidate is "this workflow's latest run is a
# failure" — a fact about the conclusion. A green workflow running again is a
# new id and the same answer, so digesting the id would report a change that
# cannot affect any verdict.
#
# This is not hypothetical tidiness. `poetic` schedules sync-framework.yml at
# `0 * * * *` — hourly, the same cadence as this pipeline. Digesting run ids
# made that one workflow bust the fingerprint on every single cycle, which
# quietly reduced the whole short-circuit to a no-op that still paid for a
# Co-Ordinator every hour: the feature would have looked installed, logged
# nothing unusual, and saved nothing. Any repo with a scheduled workflow does
# this; ours does.
#
# Incomplete runs are dropped rather than digested as an empty conclusion. A
# run in flight is not yet a failure (so it is not yet a candidate), and
# sampling one mid-flight would otherwise register two changes per run — one
# when it starts, one when it lands — for a workflow that ends up exactly where
# it began.
#
# The 100-run window can drop a long-dormant workflow's last run, which changes
# the digest and buys a Co-Ordinator run. That is the safe direction, and it
# only happens on a repo busy enough to have had 100 runs since.
workflows="$(api_json '[]' \
  '[.workflow_runs[] | select((.conclusion // "") != "")
                     | {w: .workflow_id, id: .id, c: .conclusion}]
   | group_by(.w) | map(max_by(.id) | {w: .w, c: .c}) | sort_by(.w)' \
  "repos/$slug/actions/runs?branch=$branch&per_page=100")" || ok=false

# Open PRs, whose existence is how this system marks a claim (requirement
# 16.3). Closing a PR releases its claim and makes the item selectable again
# without touching a commit, an issue, or an alert — so without this signal a
# fingerprint could sit unchanged across exactly the event that created work.
open_prs="$(api_json '[]' \
  '[.[] | {n: .number, u: .updated_at, h: .head.ref, d: .draft}] | sort_by(.n)' \
  "repos/$slug/pulls?state=open&per_page=100")" || ok=false

jq -nc \
  --arg slug "$slug" \
  --argjson ok "$ok" \
  --argjson head "$head_sha" \
  --argjson issues "$issues" \
  --argjson workflows "$workflows" \
  --argjson open_prs "$open_prs" \
  '{slug: $slug, ok: $ok, head_sha: $head, issues: $issues, workflows: $workflows, open_prs: $open_prs}'
