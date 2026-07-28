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
# One definition (requirement 34a): agent-cycle.sh's own PR comments and the
# comment instructions in prompts/enabler.md and prompts/reviewer.md all stamp
# what they post with pipeline_comment_marker, and
# scripts/gather-abandoned-drafts.sh sources this same file and matches on
# PIPELINE_COMMENT_MARKER_PREFIX, so the write side and the read side cannot
# drift apart.
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
