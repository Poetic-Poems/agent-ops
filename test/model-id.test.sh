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
  "$(resolve_model_id implementor_model_trivial "claude-haiku-4-5-20251001")"

# --- An `anthropic/`-qualified id is accepted and stripped to the bare id
#     `claude --model` expects. ---
assert_eq "an anthropic/-qualified id is stripped to its bare id" "claude-sonnet-5" \
  "$(resolve_model_id implementor_model_default "anthropic/claude-sonnet-5")"

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

echo
if (( failures == 0 )); then
  echo "All model-id assertions passed."
  exit 0
else
  echo "$failures model-id assertion(s) FAILED."
  exit 1
fi
