#!/usr/bin/env bash
#
# lib/repo-clone.sh — how both pipelines take their ephemeral clone.
#
# One definition, because the two cycles must clone identically (requirement
# 34a) and because the way they clone is a decision with a reason:
#
# `git clone`, not `gh repo clone`. The two fetch the same objects over the
# same transport, but `gh` resolves the repository through a GraphQL query
# first, and that query is billed against the API budget. It is also the last
# thing a cycle does before its expensive stage — the Co-Ordinator engagement
# and the claim are already paid for by then — so a refusal there wastes
# everything and produces nothing. That is not hypothetical: on
# 2026-08-12T20:52Z a cycle died exactly there, with `GraphQL: API rate limit
# already exceeded for user ID 2049303`. Git's own transport is not
# rate-limited, so this step cannot fail that way.
#
# Authentication is unchanged. `deploy/docker/entrypoint.sh` runs `gh auth
# setup-git`, so the credential helper serves this HTTPS remote exactly as it
# serves the push that follows.
#
# `CLONE_GIT` substitutes a stub for tests, the same seam `CLAIM_GH`,
# `SWEEP_GH` and `TOGGLE_GH` provide for their own callers — and it is the
# reason this is a function at all rather than a line in each pipeline. A test
# that wants the clone to fail used to get that from the fail-fast `gh` shim on
# `PATH`; `git` is not that shim, and a clone that reaches the network turns
# such a test into one that passes or fails on whether the runner has egress.
# `test/review-claim.test.sh` found this the hard way, in CI, having passed on
# a machine that happened to be offline.

CLONE_GIT="${CLONE_GIT:-git}"

# clone_repo SLUG DIR
# Clone `owner/name` into DIR. Returns git's exit status; stderr is git's own,
# left for the caller to show or redirect to the `clone*.err` file it records.
#
# A directory already at DIR is **residue, always** — discarded rather than
# inspected (agent-ops#605). Both callers derive DIR from an id minted moments
# earlier and unique to the run (`<cycle-id>`, `<review-id>-<repo>`), so
# nothing legitimate can be sitting there: what can is the partial clone of a
# cycle the machine killed mid-`git clone`, or of one whose host ran out of
# disk part-way through writing it.
#
# Discarding unconditionally is deliberately stronger than validating. A check
# that the directory "is a complete repository at the expected remote and
# revision" passes on a clone that is complete and *dirty* — the working tree
# of a dead cycle, carrying its half-finished edits and its branch — which is
# the residue most likely to mislead the stage that inherits it, and the one
# hardest to tell from a good clone. The unconditional discard has no such
# blind spot, needs no git invocation to reach its verdict, and cannot be
# wrong about a repository shape it has not met before.
#
# Left to itself, `git clone` into a non-empty directory fails, so before this
# the residue did not corrupt a cycle — it killed it, at the last cheap step
# before the expensive one, and then stayed on the disk.
clone_repo() {
  local slug="$1" dir="$2"
  [[ -e "$dir" ]] && rm -rf -- "${dir:?}"
  "$CLONE_GIT" clone --quiet "https://github.com/$slug.git" "$dir"
}
