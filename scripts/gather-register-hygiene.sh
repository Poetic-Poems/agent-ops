#!/usr/bin/env bash
#
# gather-register-hygiene.sh — pre-fetch a repo's `TECH-DEBT.md` when it has
# fallen out of internal consistency: a resolved item whose body was never
# removed, an open item with no body, a duplicated or malformed Ledger row
# (requirement 3i).
#
# Given a repo slug, print a JSON array holding at most one candidate: the
# repo's register, if `scripts/td-check.pl` says it disagrees with itself.
#
# Usage: gather-register-hygiene.sh <owner/repo> [default-branch]
#
# Candidate shape:
#   {
#     "source": "register-hygiene",
#     "ref": "register-hygiene-413128de0d60",   // scoped to THIS blob
#     "url": "https://github.com/…/blob/main/TECH-DEBT.md",
#     "blob_sha": "413128de0d60d9502bf469348bc70fbbacccf569",
#     "problems": ["STALE BODY     TD26071203  body:96 ledger:412 (resolved)  …"],
#     "body": "…the whole of td-check.pl's output, verbatim…"
#   }
#
# ## What the register promises, and how it breaks
#
# Every repo here keeps its deferred work in `TECH-DEBT.md` under one
# convention: live items are `### <id> <title>` sections under
# `## Current Items`, and *every* id ever allocated keeps a row in the permanent
# `## Ledger` table. Resolving an item removes its body and leaves its row, so
# the file reads as "what is outstanding" while the Ledger stays the full
# history. The two halves are therefore a cross-check on each other, and
# `scripts/td-check.pl` is that cross-check written down.
#
# It goes wrong quietly. In July 2026 twelve items across the three repos were
# flipped to `resolved` with their bodies left in place — so `## Current Items`
# advertised a dozen pieces of work that were already done, to humans and to
# this pipeline alike. prompts/implementor.md has prescribed the removal since
# it was first written; the drift accumulated anyway, because resolutions also
# arrive from humans and from interactive sessions that no prompt governs.
#
# Hence two layers, and this script is the second of them:
#   1. Each consumer repo runs `td-check.pl` on its own register in CI
#      (`.github/workflows/tech-debt-register.yml`), so the pull request that
#      *creates* drift fails its own checks and never lands.
#   2. This source detects and repairs whatever lands anyway — a register that
#      predates the guard, a direct push, a merge that reintroduces a body.
# The first layer is what makes this one cheap: with the guards in place the
# volume trends to zero, and an empty array costs one API call.
#
# ## Why the Script fetches this and not the Co-Ordinator
#
# The same three reasons as gather-review-feedback.sh (requirement 3c) and
# gather-merge-conflicts.sh (requirement 3g):
#   1. Cost: the answer is one file read and one Perl run. Asking a model to
#      cross-reference a Ledger table against a list of headings — for three
#      repos, every cycle, almost always to conclude "consistent" — is paying
#      model tokens for `diff`.
#   2. Determinism, which matters more here than for any other source: the
#      candidate rule *is* `td-check.pl`'s exit status, and that same script is
#      what the consumer repos' CI runs and what the Implementor re-runs until
#      it passes. One definition, three consumers (requirement 34a). A model
#      re-deriving the rule would be a fourth opinion about what a consistent
#      register looks like, and the one that disagreed would be the one nobody
#      noticed.
#   3. The checker's output is the Implementor's brief and must reach it
#      verbatim — every problem line names an id and a line number, which is the
#      whole of what makes the repair mechanical.
#
# ## The candidate rule
#
# The register is a candidate iff `td-check.pl` exits 1 against it — that is,
# iff it reports at least one of STALE BODY, MISSING BODY, DUPLICATE BODY,
# NO LEDGER ROW, DUPLICATE ROW or BAD ROW. There is no severity ordering and no
# partial candidacy: the file is either consistent or it is not, and the repair
# is one pull request either way. At most one candidate per repo, for the same
# reason — there is only one register.
#
# A repo with no `TECH-DEBT.md` at all contributes `[]`, and that is a normal
# answer, not an error: not every repo this fleet touches keeps a register.
#
# ## Why the ref is scoped to the blob SHA
#
# `register-hygiene-<blob-sha[:12]>`, not a bare `register-hygiene`. An item
# recorded blocked (requirement 34) stays blocked until something clears it, so
# a bare ref that an Implementor once failed to repair would still be blocked
# after the register had moved on — and the new state, which might be trivially
# repairable, would never be looked at again. Scoping the ref to the blob SHA
# means each distinct *content* of the file is its own item that no older block
# covers; a repair changes the file and so retires the ref; drift re-detected
# against an unchanged file keeps the same ref and stays correctly blocked; and
# a commit that touches anything else in the repo leaves the blob — and
# therefore the item — exactly as it was, so unrelated activity never
# resurrects a block or forks a new item. Same expiry-by-irrelevance reasoning
# as merge-conflicts' and abandoned-drafts' per-head refs.
#
# ## Why this array needs no fingerprint argument of its own — and is
# ## fingerprinted verbatim regardless
#
# The other pre-fetched arrays exist partly because their candidacy turns on
# something no repo signal carries: a draft going stale is the passage of time,
# and a ready PR turning CONFLICTING is GitHub recomputing mergeability a cycle
# after some *other* PR merged. Neither moves anything else the no-op
# fingerprint (requirement 3b) hashes.
#
# This source has no such problem. Drift is a pure function of one file's
# content, so it can only appear on a commit to the default branch, and a commit
# moves the repo's `head_sha` — which the fingerprint already covers. There is
# no transition here that the existing signals would sleep through.
#
# The array is still fed to the fingerprint verbatim, alongside the other three,
# for two reasons. First, uniformity: a per-source exception in the fingerprint
# is a thing to remember, and "this one is covered by something else" is exactly
# how a source ends up covered by nothing (see lib/noop-skip.sh). Second, and
# concretely, candidacy depends on the *checker* as well as the file — editing
# `scripts/td-check.pl` here can add or remove problems with no commit to the
# target repo at all, and only this array carries that.
#
# Fails safe: always prints a valid JSON array and exits 0. A consistent
# register contributes `[]`; a repo with no register contributes `[]` silently
# (normal); an API that will not answer contributes `[]` too, but with `gh`'s
# own diagnosis left on stderr rather than swallowed — an unexplained `[]` on
# error is the trap in the Gotchas table that cost the sibling gatherers a
# debugging round, and the distinction between "no register" and "no answer" is
# precisely what was missing that day.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

slug="${1:-}"
default_branch="${2:-main}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-register-hygiene.sh <owner/repo> [default-branch]" >&2
  exit 64
fi

work="$(mktemp -d)" || { printf '[]'; exit 0; }
trap 'rm -rf "$work"' EXIT

# One REST read, which returns the file's content *and* its blob SHA together —
# so the ref is derived from the same response the check ran against, and cannot
# name a revision this cycle never saw.
raw="$(gh api "repos/$slug/contents/TECH-DEBT.md" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  # A 404 is the ordinary "this repo keeps no register" (or the repo itself is
  # gone), and is reported by the API body, not by guessing at gh's wording.
  # Anything else — auth, rate limit, network, a field gh rejects — is a
  # failure, and its diagnosis goes to stderr where agent-cycle.sh captures it
  # per cycle. Both answers are `[]`; only one of them is silent.
  if [[ "$(jq -r '.status // ""' <<<"$raw" 2>/dev/null)" != "404" ]]; then
    cat "$work/gh.err" >&2
  fi
  printf '[]'
  exit 0
fi

blob_sha="$(jq -r '.sha // ""' <<<"$raw" 2>/dev/null || true)"
if [[ -z "$blob_sha" ]]; then
  echo "gather-register-hygiene: $slug: no blob sha in the contents response" >&2
  printf '[]'
  exit 0
fi

# Written under its real name in a scratch directory, and checked from inside
# it, so td-check.pl's output names `TECH-DEBT.md` — the path a human or an
# Implementor would type — rather than a mktemp path that means nothing by the
# time the work order is read. The contents API base64 arrives wrapped across
# lines; `base64 -d` is content with that.
if ! jq -r '.content // ""' <<<"$raw" 2>/dev/null | base64 -d > "$work/TECH-DEBT.md" 2>/dev/null \
   || [[ ! -s "$work/TECH-DEBT.md" ]]; then
  # `encoding: "none"` (a file over the contents API's size limit) lands here
  # too. Neither case is a drifted register; both are "we could not look".
  echo "gather-register-hygiene: $slug: could not decode TECH-DEBT.md" >&2
  printf '[]'
  exit 0
fi

out="$(cd "$work" && perl "$SCRIPT_DIR/td-check.pl" TECH-DEBT.md 2>&1)"
check_rc=$?
# 0 is a consistent register — the answer this source expects to give almost
# every cycle. Anything above 1, or a report with nothing in it, is td-check.pl
# failing to run at all (usage, I/O), which is our problem and not the
# register's: say so and contribute nothing, rather than filing a repair on
# behalf of a checker that never checked.
if (( check_rc == 0 )); then
  printf '[]'
  exit 0
fi
if (( check_rc > 1 )) || [[ -z "$out" ]]; then
  printf '%s\n' "$out" >&2
  printf '[]'
  exit 0
fi

# The problem lines, split out of the report so the Co-Ordinator can price the
# item without parsing prose, while `body` keeps the report whole for the
# Implementor. The labels are td-check.pl's own; keep the two in step.
problems="$(grep -E '^[[:space:]]+(STALE BODY|MISSING BODY|DUPLICATE BODY|NO LEDGER ROW|DUPLICATE ROW|BAD ROW)' <<<"$out" \
            | jq -Rn '[inputs | sub("^ +"; "")]' 2>/dev/null || true)"
[[ -n "$problems" ]] || problems='[]'

jq -nc \
  --arg ref "register-hygiene-${blob_sha:0:12}" \
  --arg url "https://github.com/$slug/blob/$default_branch/TECH-DEBT.md" \
  --arg blob_sha "$blob_sha" \
  --argjson problems "$problems" \
  --arg body "$out" \
  '[{source: "register-hygiene",
     ref: $ref,
     url: $url,
     blob_sha: $blob_sha,
     problems: $problems,
     body: $body}]'
