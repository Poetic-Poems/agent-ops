#!/usr/bin/env bash
#
# lib/pipeline-marker.sh — the invisible marker every pull-request or issue
# comment this system posts carries (requirement 3e; TD26072605).
#
# `updatedAt` on a pull request moves for anything at all — a push, a comment,
# a label edit — and gather-abandoned-drafts.sh used to trust it wholesale as
# "somebody is on this". But when *this system* is the one touching the PR,
# that is usually evidence the opposite just happened: a stage gave up and
# left a note, or an Enabler diagnosed a stall and said so. Filtering by
# comment author cannot separate the two cases — every write happens under the
# same GitHub account this system runs as — so the marker stamps *what the
# pipeline itself wrote*, the way the Vercel bot marks its own comments
# idempotent. gather-abandoned-drafts.sh discounts marker-carrying comments
# when computing a PR's last real activity; label edits are discounted
# unconditionally there; a human's comment carries no marker and always
# counts.
#
# One definition (requirement 34a): agent-cycle.sh stamps its own PR comments
# by calling pipeline_comment_marker, and scripts/gather-abandoned-drafts.sh
# sources this same file and matches on PIPELINE_COMMENT_MARKER_PREFIX, so that
# write side and the read side cannot drift apart. The Enabler's and Reviewer's
# comment instructions (prompts/enabler.md, prompts/reviewer.md) are the one
# place the string has to be spelled out rather than sourced — a prompt is read
# by a model, not a shell — so test/abandoned-drafts.test.sh asserts both
# prompts still carry the prefix defined here, which is what stops a change to
# it silently un-marking every comment those two stages write.
#
# An HTML comment renders invisibly on GitHub.

# The fixed, greppable prefix every marker starts with. Match on this
# substring, never on the full pipeline_comment_marker output (which also
# carries a cycle id) — a fresh cycle id must not stop a comment being
# recognised as the pipeline's own.
PIPELINE_COMMENT_MARKER_PREFIX='<!-- agent-ops:pipeline-comment'

# pipeline_comment_marker CYCLE_ID
# Print the invisible marker to append to a comment body this system posts.
# The cycle id travels for traceability only — which cycle wrote this —
# detection needs nothing but PIPELINE_COMMENT_MARKER_PREFIX above.
pipeline_comment_marker() {
  printf '%s cycle=%s -->' "$PIPELINE_COMMENT_MARKER_PREFIX" "$1"
}
