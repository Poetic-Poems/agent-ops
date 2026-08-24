#!/usr/bin/env bash
#
# test/prompt-untrusted-framing.test.sh — the untrusted-external-content
# framing (IMPLEMENTATION-PIPELINE-SPEC.md requirement 45,
# REVIEW-PIPELINE-SPEC.md R18) is present in every prompt that reads
# forge-authored text, and every copy — the spec's canonical one included —
# is byte-identical.
#
# What this guards: the framing is one rule with nine copies, which is the
# shape the final-message parser already taught this repo to distrust
# (test/extract-json-result.test.sh): copies drift. A prompt whose copy has
# drifted is enforcing a different rule from the one the spec states; a
# prompt that lost its markers has lost the section entirely — and the
# framing is the one D24 containment that is only words, so the words being
# the decided ones is the whole control. Every copy is lifted from its file
# at run time, never restated here, so this cannot pass against text the
# files have moved on from.
#
# The spec's canonical copy sits indented inside requirement 45a's fenced
# block; the lift strips each copy's own leading indentation (taken from its
# start-marker line) before comparing, so indentation is presentation and
# the words are the contract.
#
# Run directly: ./test/prompt-untrusted-framing.test.sh — exit 0 iff all
# passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0

# Print the text between the untrusted-content markers of file $1, with the
# start marker's own leading indentation stripped from every line. Nothing
# is printed when the markers are absent.
lift_block() {
  awk '
    /^[[:space:]]*<!-- untrusted-content:end -->$/   { on = 0 }
    on                                               { print substr($0, ind + 1) }
    /^[[:space:]]*<!-- untrusted-content:start -->$/ { on = 1; ind = index($0, "<") - 1 }
  ' "$1"
}

# Whole-line marker occurrences (indentation allowed) — inline mentions of
# the marker string, as in the specs' own prose, deliberately do not count.
count_markers() {
  grep -cE '^[[:space:]]*<!-- untrusted-content:start -->$' "$1"
}

canon="$(lift_block "$SCRIPT_DIR/docs/IMPLEMENTATION-PIPELINE-SPEC.md")"
if [[ -z "$canon" ]]; then
  echo "FAIL - could not lift the canonical block from IMPLEMENTATION-PIPELINE-SPEC.md (requirement 45a)"
  exit 1
fi
if [[ "$(count_markers "$SCRIPT_DIR/docs/IMPLEMENTATION-PIPELINE-SPEC.md")" != 1 ]]; then
  echo "FAIL - IMPLEMENTATION-PIPELINE-SPEC.md must carry exactly one whole-line start marker (requirement 45a's)"
  exit 1
fi
printf 'ok   - canonical block lifted from requirement 45a (%s lines)\n' "$(wc -l <<<"$canon")"

# Requirement 45's implementation-pipeline prompts, plus
# project-reviewer.md under REVIEW-PIPELINE-SPEC.md R18.
prompts=(coordinator implementer reviewer approver enabler enabler-adjudicate
         approver-adjudicate-open-question refiner project-reviewer)

for p in "${prompts[@]}"; do
  f="$SCRIPT_DIR/prompts/$p.md"
  n="$(count_markers "$f")"
  if [[ "$n" == 0 ]]; then
    printf 'FAIL - prompts/%s.md carries no marker-delimited untrusted-content block\n' "$p"
    failures=$(( failures + 1 ))
    continue
  fi
  if [[ "$n" != 1 ]]; then
    printf 'FAIL - prompts/%s.md carries %s start markers; requirement 45b allows exactly one\n' "$p" "$n"
    failures=$(( failures + 1 ))
    continue
  fi
  got="$(lift_block "$f")"
  if [[ "$got" == "$canon" ]]; then
    printf 'ok   - prompts/%s.md matches the canonical block\n' "$p"
  else
    printf 'FAIL - prompts/%s.md block differs from the canonical copy:\n' "$p"
    diff <(printf '%s\n' "$canon") <(printf '%s\n' "$got") | sed 's/^/       /'
    failures=$(( failures + 1 ))
  fi
done

exit "$(( failures > 0 ))"
