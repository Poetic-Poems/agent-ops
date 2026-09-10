#!/usr/bin/env bash
#
# lib/claim-key.sh — the one place a claim-registry path component is
# sanitised.
#
# `san()` turns a slug or branch name that may itself contain `/` into
# something safe to use as a single path segment, by replacing every `/`
# with `__`. `lib/claim.sh`'s `registry_path()` and
# `scripts/sweep-orphan-branches.sh`'s own registry lookup both build a path
# under `claims/<repo>/<key>.json` in the state repository from the same
# `san()`-encoded shape; sourcing this file from both is what keeps that
# encoding a single definition rather than two that could silently drift —
# a drift here would make one of the two miss a real claim, in
# `sweep-orphan-branches.sh`'s case letting it delete a branch a peer node
# still owns.

san() { local s="$1"; printf '%s' "${s//\//__}"; }
