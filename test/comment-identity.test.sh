#!/usr/bin/env bash
#
# test/comment-identity.test.sh — regression test for the visible attribution
# every pull-request or issue comment this system posts opens with (the
# `pipeline_comment_header`/`pipeline_actor_label` helpers in
# lib/pipeline-marker.sh), and for the prompts that spell that header out
# literally because a model reads prose, not shell.
#
# Every pipeline write lands under `warwickallen`, the human's own GitHub
# account (requirement 3e), so the author field alone cannot tell a human's
# comment from the pipeline's — including which comments are the human's own.
# The header exists to answer that; this test is what stops it drifting from
# what the three commenting stages actually type out. The invisible marker's
# own regression coverage — including the fixture proving an older,
# actor-less marker and a newer, actor-carrying one both still exclude a
# comment from gather-abandoned-drafts.sh's activity clock — lives in
# test/abandoned-drafts.test.sh; this file does not duplicate it.
#
# Run directly:
#
#   ./test/comment-identity.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

# --- pipeline_actor_label: the token→display map, and its fail-open case ---

assert_eq "script's display name" "Script" "$(pipeline_actor_label script)"
assert_eq "coordinator's display name" "Co-Ordinator" "$(pipeline_actor_label coordinator)"
assert_eq "implementor's display name" "Implementor" "$(pipeline_actor_label implementor)"
assert_eq "reviewer's display name" "Reviewer" "$(pipeline_actor_label reviewer)"
assert_eq "enabler's display name" "Enabler" "$(pipeline_actor_label enabler)"
assert_eq "review-script's display name" "Review Script" "$(pipeline_actor_label review-script)"
assert_eq "project-reviewer's display name" "Project Reviewer" "$(pipeline_actor_label project-reviewer)"

# An Actor token this map has not learned about yet must degrade to its bare
# token rather than vanish from a comment — the same convention
# dashboard/index.html documents for its own actor map.
assert_eq "an unknown token fails open to its own bare form" \
  "some-future-actor" "$(pipeline_actor_label some-future-actor)"

# --- pipeline_comment_header: the leading, visible line ---

# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
assert_eq "the header names the actor's display and the node, verbatim" \
  '**Implementor** · autonomous pipeline · node `poetic-2`' \
  "$(pipeline_comment_header implementor poetic-2)"
# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
assert_eq "an unknown actor still produces a header, via the fail-open token" \
  '**some-future-actor** · autonomous pipeline · node `poetic-1`' \
  "$(pipeline_comment_header some-future-actor poetic-1)"

# --- pipeline_comment_marker: cycle and actor both travel ---

assert_eq "the marker carries both the cycle id and the actor token" \
  '<!-- agent-ops:pipeline-comment cycle=20260807T010000Z-poetic-1-123 actor=implementor -->' \
  "$(pipeline_comment_marker 20260807T010000Z-poetic-1-123 implementor)"
assert_eq "every marker still starts with the fixed, greppable prefix" \
  "yes" \
  "$(pipeline_comment_marker 20260807T010000Z-poetic-1-123 implementor \
     | grep -qF -- "$PIPELINE_COMMENT_MARKER_PREFIX" && echo yes || echo no)"

# --- The prompts cannot drift from the header the library produces ---
#
# A model reads prose, not shell, so prompts/implementor.md, prompts/enabler.md
# and prompts/reviewer.md are three of the only places (with the fixtures in
# test/abandoned-drafts.test.sh) allowed to spell the header's literal form out
# rather than sourcing it. Each instructs its stage to substitute a real node
# name for the literal placeholder `<node>`, so that placeholder form — exactly
# what pipeline_comment_header produces for the actor token `<node>` stands in
# for — is the string every prompt must still carry.
declare -A actor_of=( [implementor]=implementor [enabler]=enabler [reviewer]=reviewer )
for prompt in implementor enabler reviewer; do
  header="$(pipeline_comment_header "${actor_of[$prompt]}" '<node>')"
  assert_eq "prompts/$prompt.md spells out the literal header its stage must open comments with" "yes" \
    "$(grep -qF -- "$header" "$SCRIPT_DIR/prompts/$prompt.md" && echo yes || echo no)"
done

# --- The Reviewer's completion comment is unconditional (requirement 30b) ---
#
# No shell test can drive a real review of a clean PR and assert a comment
# appeared — there is no Reviewer harness, and this file does not attempt to
# build one. What it can pin, the same way it pins the header above, is that
# the instruction to post a completion comment on every run — not only when
# there is a finding to report — is actually present in the prompt the stage
# reads.
assert_eq "prompts/reviewer.md instructs an unconditional completion comment" "yes" \
  "$(grep -qF -- "Report completion, always." "$SCRIPT_DIR/prompts/reviewer.md" && echo yes || echo no)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
