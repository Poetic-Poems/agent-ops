#!/usr/bin/env bash
#
# lib/model-id.sh — provider-qualified model identifiers (D12 groundwork,
# docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 1a).
#
# Every model key in config.json (coordinator_model, implementor_model_*,
# reviewer_model_*, enabler_model, review.model) accepts either a bare model
# id (`claude-sonnet-5`) or one qualified with a provider prefix
# (`anthropic/claude-sonnet-5`). Anthropic is the only executable provider
# today (decision D12 in docs/ROADMAP.md), so the two forms are the same
# value; a qualifier naming any other provider fails fast here, at config
# read time, rather than reaching `claude --model` mid-cycle.
#
# Sourced by agent-cycle.sh and review-cycle.sh.

# resolve_model_id KEY VALUE
# Prints the bare model id `claude --model` expects. An unqualified VALUE
# (including empty, which some keys use to disable a stage) passes through
# unchanged; an `anthropic/`-qualified VALUE has the qualifier stripped. Any
# other qualifier prints a message naming KEY and the offending provider to
# stderr and returns 1 without printing a value.
resolve_model_id() {
  local key="$1" value="$2" provider
  case "$value" in
    */*)
      provider="${value%%/*}"
      if [[ "$provider" == "anthropic" ]]; then
        printf '%s\n' "${value#*/}"
      else
        # Prefixed with the library's own name, not a script's: review-cycle.sh
        # sources this too, and an error blaming agent-cycle for `review.model`
        # sends the operator to the wrong script. Matches lib/toggle.sh.
        echo "model-id: $key: provider '$provider' not yet supported (only 'anthropic' is executable today) — got '$value'" >&2
        return 1
      fi
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}
