#!/usr/bin/env bash
#
# gather-register-hygiene.sh — pre-fetch a repo's tech-debt register when it
# has fallen out of internal consistency (requirement 3i): in the legacy
# single-file format, a resolved item whose body was never removed, an open
# item with no body, a duplicated or malformed Ledger row; in the per-item
# format, an item file whose frontmatter disagrees with its filename, its
# repository's declared scope, or itself.
#
# Given a repo slug, print a JSON array holding at most one candidate: the
# repo's register, if `scripts/td-check.pl` says it disagrees with itself.
#
# Usage: gather-register-hygiene.sh <owner/repo> [default-branch]
#
# Candidate shape:
#   {
#     "source": "register-hygiene",
#     "ref": "register-hygiene-413128de0d60",   // scoped to THIS register state
#     "url": "https://github.com/…/blob/main/TECH-DEBT.md",   // legacy, or
#            "https://github.com/…/tree/main/tech-debt",      // per-item
#     "blob_sha": "413128de0d60d9502bf469348bc70fbbacccf569",
#     "problems": ["STALE BODY     TD26071203  body:96 ledger:412 (resolved)  …"],
#     "body": "…the whole of td-check.pl's output, verbatim…"
#   }
# `blob_sha` carries the register's identity object: the file's blob SHA in
# the legacy format, the `tech-debt/` tree SHA in the per-item format.
#
# ## What the register promises, and how it breaks
#
# Every repo here keeps its deferred work in a tech-debt register, in one of
# two formats the tooling detects for itself:
#   - **legacy**: a single `TECH-DEBT.md` — live items as `### <id> <title>`
#     sections under `## Current Items`, every id ever allocated keeping a row
#     in the permanent `## Ledger` table. Resolving removes the body and
#     leaves the row, so the two halves are a cross-check on each other.
#   - **per-item**: one file per item under `tech-debt/`, frontmatter carrying
#     what the Ledger row used to (id, status, dates, ref), with the root
#     `TECH-DEBT.md` holding only policy and the repository's declared scope.
#     Here the checkable promises are per file: the id matches the filename
#     and the declared scope, the status is recognised, and the resolution
#     fields agree with it.
# `scripts/td-check.pl` is both sets of promises written down; it reads
# whichever format it is given.
#
# It goes wrong quietly. In July 2026 twelve items across the three repos were
# flipped to `resolved` with their bodies left in place — so `## Current Items`
# advertised a dozen pieces of work that were already done, to humans and to
# this pipeline alike. prompts/implementor.md has prescribed the removal since
# it was first written; the drift accumulated anyway, because resolutions also
# arrive from humans and from interactive sessions that no prompt governs.
# (The per-item format retires that particular failure — resolution is a
# frontmatter flip, with no second edit to forget — but keeps its own smaller
# surface: a copy-pasted id, a wrong scope, a status typo.)
#
# Hence two layers, and this script is the second of them:
#   1. Each consumer repo runs `td-check.pl` on its own register in CI
#      (`.github/workflows/tech-debt-register.yml`), so the pull request that
#      *creates* drift fails its own checks and never lands.
#   2. This source detects and repairs whatever lands anyway — a register that
#      predates the guard, a direct push, a merge that reintroduces a body.
# The first layer is what makes this one cheap: with the guards in place the
# volume trends to zero, and an empty array costs two API reads.
#
# ## Why the Script fetches this and not the Co-Ordinator
#
# The same three reasons as gather-review-feedback.sh (requirement 3c) and
# gather-merge-conflicts.sh (requirement 3g):
#   1. Cost: the answer is one register read and one Perl run. Asking a model
#      to cross-check a register against its own rules — for three repos,
#      every cycle, almost always to conclude "consistent" — is paying model
#      tokens for `diff`.
#   2. Determinism, which matters more here than for any other source: the
#      candidate rule *is* `td-check.pl`'s exit status, and that same script is
#      what the consumer repos' CI runs and what the Implementor re-runs until
#      it passes. One definition, three consumers (requirement 34a). A model
#      re-deriving the rule would be a fourth opinion about what a consistent
#      register looks like, and the one that disagreed would be the one nobody
#      noticed.
#   3. The checker's output is the Implementor's brief and must reach it
#      verbatim — every problem line names an id and where the problem sits,
#      which is the whole of what makes the repair mechanical.
#
# ## The candidate rule
#
# The register is a candidate iff `td-check.pl` exits 1 against it — that is,
# iff it reports at least one problem in its format's vocabulary (legacy:
# STALE BODY, MISSING BODY, DUPLICATE BODY, NO LEDGER ROW, DUPLICATE ROW,
# BAD ROW; per-item: BAD NAME, BAD FRONTMATTER, MISSING FIELD, BAD FIELD,
# BAD STATUS, BAD SCOPE, NO SCOPE, ID MISMATCH, DATE MISMATCH, STALE FIELD,
# DUPLICATE ID). There is no severity ordering and no partial candidacy: the
# register is either consistent or it is not, and the repair is one pull
# request either way. At most one candidate per repo, for the same reason —
# there is only one register.
#
# A repo with no register at all — no `TECH-DEBT.md` and no `tech-debt/` —
# contributes `[]`, and that is a normal answer, not an error: not every repo
# this fleet touches keeps one.
#
# ## Why the ref is scoped to the register's identity
#
# `register-hygiene-<12 hex>`, not a bare `register-hygiene`. An item recorded
# blocked (requirement 34) stays blocked until something clears it, so a bare
# ref that an Implementor once failed to repair would still be blocked after
# the register had moved on — and the new state, which might be trivially
# repairable, would never be looked at again. Scoping the ref to the register's
# content means each distinct *state* is its own item that no older block
# covers; a repair changes the state and so retires the ref; drift re-detected
# against an unchanged register keeps the same ref and stays correctly blocked;
# and a commit that touches anything else in the repo leaves the item exactly
# as it was. Same expiry-by-irrelevance reasoning as merge-conflicts' and
# abandoned-drafts' per-head refs.
#
# In the legacy format the identity is the file's blob SHA and the ref is its
# first 12 characters, unchanged. In the per-item format the register's state
# is two git objects — the `tech-debt/` tree *and* the policy file that
# declares the scope (a NO SCOPE/BAD SCOPE repair edits only the latter) — so
# the ref is the first 12 of a sha256 over both SHAs, and a repair to either
# half retires it.
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
# This source has no such problem. Drift is a pure function of the register's
# content, so it can only appear on a commit to the default branch, and a
# commit moves the repo's `head_sha` — which the fingerprint already covers.
# There is no transition here that the existing signals would sleep through.
#
# The array is still fed to the fingerprint verbatim, alongside the other
# three, for two reasons. First, uniformity: a per-source exception in the
# fingerprint is a thing to remember, and "this one is covered by something
# else" is exactly how a source ends up covered by nothing (see
# lib/noop-skip.sh). Second, and concretely, candidacy depends on the *checker*
# as well as the register — editing `scripts/td-check.pl` here can add or
# remove problems with no commit to the target repo at all, and only this
# array carries that.
#
# Fails safe: always prints a valid JSON array and exits 0. A consistent
# register contributes `[]`; a repo with no register contributes `[]` silently
# (normal); an API that will not answer contributes `[]` too, but with `gh`'s
# own diagnosis left on stderr rather than swallowed — an unexplained `[]` on
# error is the trap in the Gotchas table that cost the sibling gatherers a
# debugging round, and the distinction between "no register" and "no answer"
# is precisely what was missing that day.

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

# One listing read answers both "which format?" and "what identity?": the root
# tree names `tech-debt` (a tree — the per-item register) and/or `TECH-DEBT.md`
# (a blob), each with the SHA the ref will be derived from.
tree_json="$(gh api "repos/$slug/git/trees/$default_branch" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  # A 404 is the ordinary "this repo (or branch) is gone", reported by the API
  # body, not by guessing at gh's wording. Anything else — auth, rate limit,
  # network — is a failure, and its diagnosis goes to stderr where
  # agent-cycle.sh captures it per cycle. Both answers are `[]`; only one of
  # them is silent.
  if [[ "$(jq -r '.status // ""' <<<"$tree_json" 2>/dev/null)" != "404" ]]; then
    cat "$work/gh.err" >&2
  fi
  printf '[]'
  exit 0
fi

dir_sha="$(jq -r '[.tree[] | select(.path == "tech-debt" and .type == "tree") | .sha] | first // ""' <<<"$tree_json" 2>/dev/null || true)"
policy_sha="$(jq -r '[.tree[] | select(.path == "TECH-DEBT.md" and .type == "blob") | .sha] | first // ""' <<<"$tree_json" 2>/dev/null || true)"

# No register in either format is a normal, silent [].
if [[ -z "$dir_sha" && -z "$policy_sha" ]]; then
  printf '[]'
  exit 0
fi

if [[ -z "$dir_sha" ]]; then
  # --- Legacy format: one file, one blob -------------------------------------
  #
  # One REST read, which returns the file's content *and* its blob SHA
  # together — so the ref is derived from the same response the check ran
  # against, and cannot name a revision this cycle never saw.
  raw="$(gh api "repos/$slug/contents/TECH-DEBT.md" 2>"$work/gh.err")"
  rc=$?
  if (( rc != 0 )); then
    # The listing named the file moments ago, so a 404 here is a race with a
    # deletion — still a normal []; anything else is diagnosed on stderr.
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
  # Implementor would type — rather than a mktemp path that means nothing by
  # the time the work order is read. The contents API base64 arrives wrapped
  # across lines; `base64 -d` copes with that.
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
  ident="$blob_sha"
  ref="register-hygiene-${blob_sha:0:12}"
  url="https://github.com/$slug/blob/$default_branch/TECH-DEBT.md"
else
  # --- Per-item format: a directory of item files ----------------------------
  #
  # The whole register arrives in one read via the tarball endpoint — cheaper
  # and simpler than a blob fetch per item, and the extraction root carries
  # both halves the checker needs: `tech-debt/` and the policy file beside it
  # that declares the repository's scope.
  if ! gh api "repos/$slug/tarball/$default_branch" > "$work/register.tar.gz" 2>"$work/gh.err"; then
    cat "$work/gh.err" >&2
    printf '[]'
    exit 0
  fi
  if ! tar -xzf "$work/register.tar.gz" -C "$work" 2>/dev/null; then
    echo "gather-register-hygiene: $slug: could not extract the tarball" >&2
    printf '[]'
    exit 0
  fi
  root=""
  for d in "$work"/*/; do
    [[ -d "$d" ]] && root="${d%/}" && break
  done
  if [[ -z "$root" || ! -d "$root/tech-debt" ]]; then
    echo "gather-register-hygiene: $slug: tarball held no tech-debt/ directory" >&2
    printf '[]'
    exit 0
  fi

  # Checked from the extraction root, so the output names `tech-debt/…` — the
  # paths a human or an Implementor would type.
  out="$(cd "$root" && perl "$SCRIPT_DIR/td-check.pl" tech-debt 2>&1)"
  check_rc=$?
  ident="$dir_sha"
  ref="register-hygiene-$(printf '%s:%s' "$dir_sha" "$policy_sha" | sha256sum | cut -c1-12)"
  url="https://github.com/$slug/tree/$default_branch/tech-debt"
fi

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
# Implementor. The labels are td-check.pl's own — both formats' vocabularies —
# keep the two in step.
problems="$(grep -E '^[[:space:]]+(STALE BODY|MISSING BODY|DUPLICATE BODY|NO LEDGER ROW|DUPLICATE ROW|BAD ROW|BAD NAME|BAD FRONTMATTER|MISSING FIELD|BAD FIELD|BAD STATUS|BAD SCOPE|NO SCOPE|ID MISMATCH|DATE MISMATCH|STALE FIELD|DUPLICATE ID)' <<<"$out" \
            | jq -Rn '[inputs | sub("^ +"; "")]' 2>/dev/null || true)"
[[ -n "$problems" ]] || problems='[]'

jq -nc \
  --arg ref "$ref" \
  --arg url "$url" \
  --arg blob_sha "$ident" \
  --argjson problems "$problems" \
  --arg body "$out" \
  '[{source: "register-hygiene",
     ref: $ref,
     url: $url,
     blob_sha: $blob_sha,
     problems: $problems,
     body: $body}]'
