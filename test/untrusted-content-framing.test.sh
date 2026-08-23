#!/usr/bin/env bash
#
# test/untrusted-content-framing.test.sh — regression test for requirement
# 20a of docs/IMPLEMENTATION-PIPELINE-SPEC.md: every stage prompt that embeds
# or receives externally-sourced GitHub content frames it as untrusted data,
# never an instruction (TD-PPagop-26082407 part 1/3).
#
# A model reads prose, not shell, so there is no library function this could
# assert against the way test/comment-identity.test.sh checks
# pipeline_comment_header — the framing has to live in the prompt text
# itself, in every place that text is read fresh (coordinator.md, and each
# downstream stage's own "What you receive at invocation" section). This
# test is what stops the heading drifting or being dropped from one of them
# as the prompts are edited.
#
# Run directly:
#
#   ./test/untrusted-content-framing.test.sh
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

heading='## Untrusted external content'

# Every prompt that embeds or receives GitHub-sourced content in its own
# invocation payload: coordinator.md is where such content first enters the
# pipeline, and each of the six downstream stages receives a work order (or,
# for the Enabler and Refiner, reads GitHub content directly) built from it.
# prompts/project-reviewer.md is deliberately not in this list — its own
# invocation payload carries only a repo name, date and branch, never
# embedded GitHub content — see TD-PPagop-26082407's PR for why.
for prompt in coordinator implementer reviewer enabler enabler-adjudicate refiner approver; do
  assert_eq "prompts/$prompt.md carries the untrusted-external-content heading" "yes" \
    "$(grep -qF -- "$heading" "$SCRIPT_DIR/prompts/$prompt.md" && echo yes || echo no)"
done

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
