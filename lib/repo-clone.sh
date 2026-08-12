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
clone_repo() {
  "$CLONE_GIT" clone --quiet "https://github.com/$1.git" "$2"
}
