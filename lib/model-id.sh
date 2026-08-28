#!/usr/bin/env bash
#
# lib/model-id.sh — provider-qualified model identifiers (D12 groundwork,
# docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 1a).
#
# Every model key in config.json (coordinator_model, implementer_model_*,
# reviewer_model_*, enabler_model, project_review.defaults.model and its
# per-repo overrides) accepts either a bare model
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
        # sources this too, and an error blaming agent-cycle for
        # `project_review.defaults.model` sends the operator to the wrong
        # script. Matches lib/toggle.sh.
        echo "model-id: $key: provider '$provider' not yet supported (only 'anthropic' is executable today) — got '$value'" >&2
        return 1
      fi
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

# Model-tier ordering (agent-ops#822, docs/IMPLEMENTATION-PIPELINE-SPEC.md
# requirement 1c). #815 (fixed by #819) and #821 both trace to the same root
# cause: nothing stopped a cheaper model from authoring a work order
# specification a more capable Implementer then executed. This table is what
# makes "cheaper" and "more capable" checkable in code rather than by
# convention — the fleet's four currently configured model ids, ranked by
# capability (confirmed by Anthropic's own relative pricing: haiku < sonnet
# < opus < fable). A model this table has never heard of — a future release,
# a typo the modelId pattern still accepts — ranks unknown rather than lowest
# or highest, and every function below treats "unknown" as "cannot verify",
# never as "fails" or "passes": scripts/doctor.sh warns separately so an
# unranked model is never silently invisible to the checks that use this.
declare -gA MODEL_TIER_RANK=(
  [claude-haiku-4-5-20251001]=1
  [claude-sonnet-5]=2
  [claude-opus-5]=3
  [claude-fable-5]=4
)

# model_tier_rank MODEL_ID
# Prints MODEL_ID's integer tier rank (higher is more capable) and returns 0,
# or prints nothing and returns 1 for a model MODEL_TIER_RANK does not know —
# an empty or absent MODEL_ID included, since "not ranked" is exactly what an
# unset `modelIdOrEmpty` key is. That empty case is guarded explicitly rather
# than left to the lookup: bash rejects an empty associative-array subscript
# outright ("bad array subscript"), which under `set -e` aborts the calling
# script instead of returning the 1 this promises. Both callers below already
# screen empties before they get here, but this is shared library code and the
# next caller may not.
# Takes an already-resolved bare id, as every caller here has already stripped
# any `anthropic/` qualifier for its own purposes (requirement 1a).
model_tier_rank() {
  local id="${1:-}"
  [[ -n "$id" ]] || return 1
  if [[ -n "${MODEL_TIER_RANK[$id]+set}" ]]; then
    printf '%s\n' "${MODEL_TIER_RANK[$id]}"
  else
    return 1
  fi
}

# model_tier_known MODEL_ID
# True (exit 0) iff MODEL_ID is empty (the "this stage is disabled" value
# every `modelIdOrEmpty` key uses) or ranked in MODEL_TIER_RANK.
model_tier_known() {
  local id="${1:-}"
  [[ -z "$id" ]] && return 0
  model_tier_rank "$id" >/dev/null 2>&1
}

# model_tier_below CANDIDATE FLOOR
# True (exit 0) iff both CANDIDATE and FLOOR are ranked and CANDIDATE's tier
# is strictly below FLOOR's. False whenever either side is empty (an empty
# model id means that stage is disabled — a different check's business) or
# unranked (an unranked model can never be placed relative to anything, so it
# never fails this predicate on that account alone).
model_tier_below() {
  local candidate="${1:-}" floor="${2:-}" cr fr
  [[ -n "$candidate" && -n "$floor" ]] || return 1
  cr="$(model_tier_rank "$candidate")" || return 1
  fr="$(model_tier_rank "$floor")" || return 1
  (( cr < fr ))
}
