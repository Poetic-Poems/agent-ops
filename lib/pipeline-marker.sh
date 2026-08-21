#!/usr/bin/env bash
#
# lib/pipeline-marker.sh — the whole envelope every pull-request or issue
# comment this system posts wraps its own prose in: a visible header naming
# which Actor wrote it and from which node (requirement 3f), and an invisible
# marker proving to gather-abandoned-drafts.sh that the write was the
# pipeline's own (requirement 3e; TD26072605).
#
# The header exists because every pipeline write lands under `warwickallen`,
# the human's own GitHub account — filtering by comment author cannot tell a
# human's comment from the pipeline's, so a human scanning a PR or issue
# thread has no other way to tell who said what, including which comments are
# their own. `pipeline_comment_header` prints that leading line; a prompt
# cannot source it (a model reads prose, not shell), so it is one of the three
# places that spell its literal form out — see test/comment-identity.test.sh.
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
# One definition (requirement 34a): agent-cycle.sh and review-cycle.sh stamp
# their own PR comments by calling pipeline_comment_marker and
# pipeline_comment_header, and scripts/gather-abandoned-drafts.sh sources this
# same file and matches on PIPELINE_COMMENT_MARKER_PREFIX, so that write side
# and the read side cannot drift apart. The Implementer's, Enabler's,
# Reviewer's and Refiner's comment instructions (prompts/implementer.md,
# prompts/enabler.md, prompts/reviewer.md, prompts/refiner.md) are the one
# place the strings have to be spelled out rather than sourced, so
# test/abandoned-drafts.test.sh and test/comment-identity.test.sh assert all
# four prompts still carry the forms defined here, which is what stops a change
# to them silently un-marking (or un-attributing) every comment those four
# stages write.
#
# An HTML comment renders invisibly on GitHub; the header is deliberately the
# opposite — GitHub always renders the top of a comment and truncates the
# middle of a long one, so leading with it is the only placement reliably
# visible without expanding anything.

# The fixed, greppable prefix every marker starts with. Match on this
# substring, never on the full pipeline_comment_marker output (which also
# carries a cycle id and an actor) — a fresh cycle id must not stop a comment
# being recognised as the pipeline's own, and neither must an actor token this
# file's own map has not learned about yet.
PIPELINE_COMMENT_MARKER_PREFIX='<!-- agent-ops:pipeline-comment'

# pipeline_actor_label TOKEN
# The display name for an Actor token, matching the two specs' *Actors*
# sections and the vocabulary dashboard/index.html's ACTOR map already uses.
# Fails open on an unknown token — prints it raw — the same convention
# dashboard/index.html documents for its own actor map, so an Actor added
# later degrades to its bare token rather than vanishing from a comment.
pipeline_actor_label() {
  case "$1" in
    script) printf 'Script' ;;
    coordinator) printf 'Co-Ordinator' ;;
    implementer) printf 'Implementer' ;;
    reviewer) printf 'Reviewer' ;;
    enabler) printf 'Enabler' ;;
    refiner) printf 'Refiner' ;;
    review-script) printf 'Review Script' ;;
    project-reviewer) printf 'Project Reviewer' ;;
    *) printf '%s' "$1" ;;
  esac
}

# pipeline_comment_header ACTOR NODE
# Print the leading, visible line every comment this system posts opens with.
# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
pipeline_comment_header() {
  printf '**%s** · autonomous pipeline · node `%s`' "$(pipeline_actor_label "$1")" "$2"
}

# pipeline_comment_marker CYCLE_ID ACTOR
# Print the invisible marker to append to a comment body this system posts.
# The cycle id travels for traceability only — which cycle wrote this — and
# the actor for the same reason the header carries it visibly: detection
# needs nothing but PIPELINE_COMMENT_MARKER_PREFIX above, so an older marker
# carrying no actor= field still matches.
pipeline_comment_marker() {
  printf '%s cycle=%s actor=%s -->' "$PIPELINE_COMMENT_MARKER_PREFIX" "$1" "$2"
}

# The fixed, greppable prefix a reconciliation citation starts with (the one
# new convention requirement 31c, agent-ops#533, adds, on the Reviewer's
# side): before flipping a draft pull request ready, the Reviewer answers
# every standing human comment and cites it with a
# `pipeline_reconciles_marker`-shaped line in its completion comment.
# lib/reconciliation-gate.sh is the reader; match on this prefix, never on
# the whole line, same rule PIPELINE_COMMENT_MARKER_PREFIX already gives.
PIPELINE_RECONCILES_MARKER_PREFIX='<!-- agent-ops:reconciles'

# pipeline_reconciles_marker COMMENT_ID
# Print the citation line a pipeline comment carries to mark a standing human
# comment (by its own issue-comment id) as reconciled — implemented or
# explicitly contested, never silently dropped.
pipeline_reconciles_marker() {
  printf '%s comment=%s -->' "$PIPELINE_RECONCILES_MARKER_PREFIX" "$1"
}
