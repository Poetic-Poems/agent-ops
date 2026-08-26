#!/usr/bin/env bash
#
# test/model-id.test.sh — self-contained regression test for
# lib/model-id.sh (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 1a).
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/model-id.test.sh
#
# Exit status is 0 iff every assertion passed.

# Version 0.10 of the linter traces this file's control flow to the end of a
# helper that never returns to it, and concludes the assertion helpers below are
# unreachable. They are reached — from inside the command substitutions the
# assertions are written as, which is the "invoked indirectly" case SC2317
# itself names.
# shellcheck disable=SC2317

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"

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

assert_true() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_false() {
  local desc="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

# --- A bare id is unchanged, and full backward compatibility means bare ids
#     never go near the provider check. ---
assert_eq "a bare id passes through unchanged" "claude-sonnet-5" \
  "$(resolve_model_id coordinator_model "claude-sonnet-5")"
assert_eq "a bare id with digits and dashes passes through unchanged" \
  "claude-haiku-4-5-20251001" \
  "$(resolve_model_id implementer_model_trivial "claude-haiku-4-5-20251001")"

# --- An `anthropic/`-qualified id is accepted and stripped to the bare id
#     `claude --model` expects. ---
assert_eq "an anthropic/-qualified id is stripped to its bare id" "claude-sonnet-5" \
  "$(resolve_model_id implementer_model_default "anthropic/claude-sonnet-5")"

# --- Empty stays empty: reviewer_model_complex and enabler_model both use an
#     empty string to switch a stage/escalation off, and that must survive
#     resolution untouched. ---
assert_eq "an empty value (disables a stage) passes through unchanged" "" \
  "$(resolve_model_id enabler_model "")"

# --- A non-anthropic qualifier is the fail-fast case: it must not print a
#     value, and it must fail, so a caller assigning the result under `set -e`
#     aborts rather than ever handing the qualified string to `claude --model`. ---
assert_false "a non-anthropic qualifier fails" \
  resolve_model_id reviewer_model_default "openai/gpt-5"
assert_eq "a non-anthropic qualifier prints nothing on stdout" "" \
  "$(resolve_model_id reviewer_model_default "openai/gpt-5" 2>/dev/null)"

err="$(resolve_model_id enabler_model "openai/gpt-5" 2>&1 >/dev/null)"
case "$err" in
  *"enabler_model"*"openai"*) printf 'ok   - %s\n' "the error names the offending key and provider" ;;
  *)
    printf 'FAIL - the error names the offending key and provider\n     actual: %s\n' "$err"
    failures=$(( failures + 1 ))
    ;;
esac

# --- Exercised in the same caller context production code uses: an
#     assignment under `set -euo pipefail` must abort the script on a
#     rejected qualifier, exactly like a real cfg read that fails validation
#     (the failure mode a plain `assert_false` above cannot observe, since a
#     bare function call is not inside an assignment). ---
abort_probe="$(bash -euo pipefail -c '
  source "'"$SCRIPT_DIR"'/lib/model-id.sh"
  echo before
  bad="$(resolve_model_id coordinator_model "openai/gpt-5")"
  echo "unreachable: $bad"
' 2>/dev/null || true)"
assert_eq "a rejected qualifier aborts the script when assigned under set -e" \
  "before" "$abort_probe"

# --- Model-tier ordering (requirement 1c; agent-ops#822): the fleet's four
#     currently configured models, ranked haiku < sonnet < opus < fable. ---
assert_eq "haiku ranks below sonnet" "1" "$(model_tier_rank claude-haiku-4-5-20251001)"
assert_eq "sonnet ranks above haiku, below opus" "2" "$(model_tier_rank claude-sonnet-5)"
assert_eq "opus ranks above sonnet, below fable" "3" "$(model_tier_rank claude-opus-5)"
assert_eq "fable ranks highest" "4" "$(model_tier_rank claude-fable-5)"
assert_false "an unranked model prints nothing and fails" \
  model_tier_rank claude-nonexistent-9
assert_eq "an unranked model's rank is empty" "" \
  "$(model_tier_rank claude-nonexistent-9 2>/dev/null)"

assert_true "model_tier_known accepts empty (a disabled stage)" model_tier_known ""
assert_true "model_tier_known accepts a ranked model" model_tier_known claude-sonnet-5
assert_false "model_tier_known rejects an unranked model" model_tier_known claude-nonexistent-9

assert_true "haiku is below sonnet" model_tier_below claude-haiku-4-5-20251001 claude-sonnet-5
assert_false "sonnet is not below sonnet (equal tier clears the floor)" \
  model_tier_below claude-sonnet-5 claude-sonnet-5
assert_false "opus is not below sonnet" model_tier_below claude-opus-5 claude-sonnet-5
assert_false "an empty candidate never reports below (a different check's business)" \
  model_tier_below "" claude-sonnet-5
assert_false "an empty floor never reports below (a different check's business)" \
  model_tier_below claude-haiku-4-5-20251001 ""
assert_false "an unranked candidate never reports below — 'cannot verify', not 'fails'" \
  model_tier_below claude-nonexistent-9 claude-sonnet-5
assert_false "an unranked floor never reports below either" \
  model_tier_below claude-haiku-4-5-20251001 claude-nonexistent-9

echo
if (( failures == 0 )); then
  echo "All model-id assertions passed."
  exit 0
else
  echo "$failures model-id assertion(s) FAILED."
  exit 1
fi
