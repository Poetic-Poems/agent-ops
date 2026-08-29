#!/usr/bin/env bash
#
# test/approver-wiring.test.sh — regression test for `run_approver_stage` and
# `approver_stage_complexity`, the code in agent-cycle.sh that turns the
# Approver's tier, refuse streak and verdict into the one GitHub review this
# stage posts (requirements 8b/8c, acceptance check 8s; D18 WI-5,
# agent-ops#408, agent-ops#470).
#
# `test/approver.test.sh` covers lib/approver.sh's own primitives — the tier
# and model lookups, the refuse-streak derivation, the review post. None of
# that says anything about the wiring those primitives hang off, which is
# where this stage's own decisions actually live:
#
#   - **At `human`, nothing happens at all** — no token minted, no review
#     posted, no event logged. The product default must be byte-for-byte the
#     behaviour that shipped before this stage existed, and the only thing
#     standing between the two is one `merge_autonomy_effective_level` read.
#   - **`complexity:low` approves deterministically** — an `APPROVE` review
#     with no model launched at all, which is the whole reason the Trivial
#     tier exists (zero tokens on the tier that carries no behaviour change).
#   - **A refuse streak of two routes to `approver_model_critical`**,
#     *regardless* of what the complexity grade alone would have picked — the
#     disagreement, not the diff, chooses the adjudication tier, so a
#     `complexity:low` pull request on a streak of two must reach Critical
#     and not the deterministic path above.
#   - **The ordinary tiers pick their own model** — `medium` on
#     `approver_model_default`, `high` on `approver_model_complex` — and a
#     refusal's `reasons` become the `REQUEST_CHANGES` body a human and the
#     next Implementer read.
#   - **Every failure costs a missing review, never a stranded pull request**:
#     the stage disabled, a verdict that would not parse, or a review GitHub
#     refused, each log a `warning` and return 0.
#   - **The Approver's prompt takes no overrides** — the harness's
#     `prompt_overrides_json` deliberately carries an `approver` key, and
#     `run_approver_stage` must hand `stage_prompt_text` an empty overrides
#     object anyway (requirement 4a, agent-ops#469): the adversarial prompt
#     is the trust gate, and no installation may extend or replace it.
#   - **The tier is resolved after the Reviewer, not before it**
#     (`approver_stage_complexity`, requirement 8b, agent-ops#470): a
#     mid-round `complexity:medium` → `complexity:high` label correction the
#     Reviewer itself made reaches the same round's Approver, raise-never-
#     lower against the pre-Reviewer grade, with an unreadable label leaving
#     the pre-Reviewer grade untouched.
#
# `run_approver_stage` and `approver_stage_complexity` are lifted verbatim out
# of agent-cycle.sh, the same way test/human-reviewer-handoff-wiring.test.sh
# and test/closing-keyword-wiring.test.sh lift their own blocks, so the
# assertions are about the shipped code rather than a copy of its logic.
# lib/approver.sh's pure lookups and lib/cycle-state.sh's `reviewer_complexity`
# (which `approver_stage_complexity` calls to apply the raise-never-lower
# comparison) are sourced for real; everything that talks to GitHub, launches
# a model or writes the log is stubbed and recorded.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/approver-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# assembled file unexpanded; the single-quoted here-doc below is deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/lib/approver.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- Extraction ---------------------------------------------------------------

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$CYCLE"
}

block="$(extract run_approver_stage)"
post_block="$(extract approver_post_or_warn)"
complexity_block="$(extract approver_stage_complexity)"
if [[ -z "$block" || "$block" != *"approver_post_or_warn"* ]]; then
  echo "FAIL - could not extract run_approver_stage from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if [[ -z "$post_block" || "$post_block" != *"approver_post_review"* ]]; then
  echo "FAIL - could not extract approver_post_or_warn from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if [[ -z "$complexity_block" || "$complexity_block" != *"reviewer_complexity"* ]]; then
  echo "FAIL - could not extract approver_stage_complexity from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# --- Assembly -----------------------------------------------------------------
# The harness sources lib/approver.sh for the real tier/model lookups and
# lib/cycle-state.sh for the real `reviewer_complexity` (the raise-never-lower
# comparison `approver_stage_complexity` calls), then overrides every function
# that reaches outside the process. Each stub records what it was asked to do
# under $tmp_dir, so an assertion can read the calls rather than the
# function's (deliberately always-zero) exit status.
#
# Case inputs arrive as environment variables, so one harness serves every
# case: LEVEL, STREAK, VERDICT (the model's final JSON, or empty for "no
# parseable verdict"), POST_RC, the three model tier values, and
# POST_REVIEW_LABEL/GH_LABEL_RC for the post-Reviewer label read
# `approver_stage_complexity` makes.

cat >"$tmp_dir/harness.sh" <<'HARNESS'
set -euo pipefail

. "$SCRIPT_DIR/lib/approver.sh"
. "$SCRIPT_DIR/lib/cycle-state.sh"
# docs/FLOW-SCHEMA.md, requirement 47, issue #596: run_approver_stage's own
# stage-end site calls lib/rework.sh's rework_stage_rerun_maybe. Sourced for
# real (it is pure and cheap) rather than stubbed, so this file keeps
# verifying the shipped wiring rather than a stand-in for it.
. "$SCRIPT_DIR/lib/rework.sh"

# --- Cycle globals the block reads -------------------------------------------
selected_repo="Poetic-Poems/agent-ops"
selected_item="408"
state_repo="Poetic-Poems/agent-ops"
state_dir="$T/state"
DEFAULTED_CONFIG='{}'
PROMPTS_DIR="$SCRIPT_DIR/prompts"
# Poisoned on purpose: requirement 4a locks the Approver's prompt, so
# run_approver_stage must hand stage_prompt_text an empty overrides object
# no matter what the installation configured (agent-ops#469). The
# stage_prompt_text stub records the overrides argument it was given.
prompt_overrides_json='{"approver":{"replace":"/nonexistent/poison.md"}}'
cycle_dir="$T/cycle"
clone_dir="$T/clone"
cycle_id="20260816T000000Z-test-1"
node_name="test-node"
work_order_json='{"item":"408"}'
impl_status_json='{"status":"complete"}'
rev_status_json='{"status":"ready"}'
stage_backstop_min=30
stage_inactivity_min=10
stage_kill_reason=""
stage_gaps_json='[]'
ONCE=0
approver_model_default="$MODEL_DEFAULT"
approver_model_complex="$MODEL_COMPLEX"
approver_model_critical="$MODEL_CRITICAL"
mkdir -p "$cycle_dir" "$clone_dir" "$state_dir"

# --- Stubs: everything that reaches outside this process ----------------------
# Records its own argv (issue #513, PR #506 review follow-up) so a test can
# confirm run_approver_stage asks for a FRESH read of the level rather than
# the process-lifetime memo every advisory reader uses — this stage posts a
# real GitHub review under the answer, so a kill set mid-cycle must stop it
# at this stage boundary, not wait for the next cycle's process.
merge_autonomy_effective_level() { printf '%s\n' "$*" >>"$T/mal_calls"; printf '%s' "$LEVEL"; }
approver_token_credential_present() { [[ "${CREDENTIAL:-1}" == "1" ]]; }
approver_token_identity_login() { printf 'pullwright-approver[bot]'; }
approver_refuse_streak() { printf '%s' "$STREAK"; }
# agent-ops#945: the first call is the pre-engagement gate (line 488 in
# lib/approver.sh), the second is the fresh mint read once the model
# engagement returns, spent on every write from there on. Distinguishing
# GATE_TOKEN/WRITE_TOKEN (defaulting to the same value every case before this
# fix already relied on) lets a case prove the two are genuinely different
# reads rather than the same value threaded through twice; *_RC lets a case
# simulate either read failing outright. The count is kept in a file, not a
# shell variable: `token="$(approver_token_get "")"` runs this function in a
# command-substitution subshell, whose writes to a plain variable never reach
# the caller back.
approver_token_get() {
  local calls
  calls=$(( $(cat "$T/token_calls_count" 2>/dev/null || printf '0') + 1 ))
  printf '%s' "$calls" >"$T/token_calls_count"
  printf '%s\n' "$calls" >>"$T/token_calls"
  if (( calls == 1 )); then
    [[ "${GATE_TOKEN_RC:-0}" == "0" ]] || return "${GATE_TOKEN_RC}"
    printf '%s' "${GATE_TOKEN:-a-minted-token}"
  else
    [[ "${WRITE_TOKEN_RC:-0}" == "0" ]] || return "${WRITE_TOKEN_RC}"
    printf '%s' "${WRITE_TOKEN:-a-minted-token}"
  fi
}
approver_prior_refusal_bodies() { printf '### earlier\n\nthe first refusal'; }
# D18 WI-12 (agent-ops#415): the one classifier a protected-path engagement
# reads to force the critical tier — PROTECTED_RC defaults to 1 (no
# protected path touched), so every case below this file already had keeps
# its previous tier/model assertions unless a case sets it explicitly.
landing_protected_paths_hit() {
  printf '%s\n' "$*" >>"$T/protected_calls"
  if [[ "${PROTECTED_RC:-1}" == "0" ]]; then
    printf '%s\n' "${PROTECTED_PATH:-lib/landing.sh}"
    return 0
  fi
  return "${PROTECTED_RC:-1}"
}
stage_prompt_text() { printf '%s\n' "${4-}" >>"$T/prompt_override_args"; printf 'THE APPROVER PROMPT'; }
stage_budget_apply() { :; }
stage_watchdog_warning() { printf ''; }
metering_fields() { printf '{}'; }
dump_stage_output() { :; }
stage_salvage_result() { return 1; }
extract_json_result() { [[ -n "${1// /}" ]] || return 1; jq -c . <<<"$1"; }

# The only `gh` call `approver_stage_complexity` makes: reading the PR's
# post-Reviewer `complexity:*` label. GH_LABEL_RC nonzero simulates an
# unreadable label list (the best-effort read contributes nothing);
# POST_REVIEW_LABEL, when set, stands in for the one grade word the real
# `--jq` filter would have printed per matching label.
gh() {
  if [[ "${GH_LABEL_RC:-0}" != "0" ]]; then
    return "$GH_LABEL_RC"
  fi
  [[ -n "${POST_REVIEW_LABEL:-}" ]] && printf '%s\n' "$POST_REVIEW_LABEL"
  return 0
}

log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

approver_post_review() {
  printf 'url=%s\tevent=%s\tbody=%s\ttoken=%s\n' "$1" "$2" "$3" "$4" >>"$T/posts"
  return "${POST_RC:-0}"
}

approver_escalate() {
  printf 'url=%s\treasons=%s\n' "$1" "$2" >>"$T/escalations"
}

# The one model launch. Records the model it was asked for, and writes the
# `.out` file the block then reads a verdict out of. An empty VERDICT stands
# for a stage that returned nothing parseable.
run_claude_stage() {
  printf '%s\n' "$3" >>"$T/launches"
  if [[ -n "${VERDICT:-}" ]]; then
    jq -nc --arg r "$VERDICT" '{result: $r}' >"$5"
  else
    printf '{"result": ""}\n' >"$5"
  fi
  return "${STAGE_RC:-0}"
}

HARNESS

{
  printf '%s\n' "$post_block"
  printf '%s\n' "$complexity_block"
  printf '%s\n' "$block"
  printf 'resolved="$(approver_stage_complexity "$PR_URL" "$COMPLEXITY" 0)"\n'
  printf '%s\n' 'printf '"'"'%s'"'"' "$resolved" >"$T/resolved_complexity"'
  printf 'run_approver_stage "$PR_URL" "$resolved"\n'
} >>"$tmp_dir/harness.sh"

URL="https://github.com/Poetic-Poems/agent-ops/pull/463"

# run_case LEVEL COMPLEXITY STREAK VERDICT [KEY=VALUE ...]
# Runs the block once and leaves
# $tmp_dir/{events,posts,escalations,launches,resolved_complexity} holding
# what it did. Prints the block's own exit status. COMPLEXITY is the
# pre-Reviewer grade (requirement 8a's own `rev_complexity`); each case leaves
# POST_REVIEW_LABEL and GH_LABEL_RC unset unless it needs to simulate the
# Reviewer's own post-review label correction.
run_case() {
  local level="$1" complexity="$2" streak="$3" verdict="$4"
  shift 4
  : >"$tmp_dir/events"; : >"$tmp_dir/posts"
  : >"$tmp_dir/escalations"; : >"$tmp_dir/launches"
  : >"$tmp_dir/resolved_complexity"; : >"$tmp_dir/prompt_override_args"
  : >"$tmp_dir/mal_calls"; : >"$tmp_dir/protected_calls"
  : >"$tmp_dir/token_calls"; rm -f "$tmp_dir/token_calls_count"
  rm -rf "${tmp_dir:?}/cycle" "${tmp_dir:?}/clone" "${tmp_dir:?}/state"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" PR_URL="$URL" \
    LEVEL="$level" COMPLEXITY="$complexity" STREAK="$streak" VERDICT="$verdict" \
    MODEL_DEFAULT="model-default" MODEL_COMPLEX="model-complex" \
    MODEL_CRITICAL="model-critical" \
    "$@" \
    bash "$tmp_dir/harness.sh" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
  printf '%s' "$?"
}

protected_calls() { cat "$tmp_dir/protected_calls"; }
mal_calls() { cat "$tmp_dir/mal_calls"; }
posts() { cat "$tmp_dir/posts"; }
launches() { cat "$tmp_dir/launches"; }
escalations() { cat "$tmp_dir/escalations"; }
resolved_complexity() { cat "$tmp_dir/resolved_complexity"; }
token_calls() { wc -l <"$tmp_dir/token_calls" | tr -d ' '; }
count() { local f="$tmp_dir/$1"; [[ -s "$f" ]] && wc -l <"$f" | tr -d ' ' || printf '0'; }
verdict_event() { grep -m1 $'^approver-verdict\t' "$tmp_dir/events" | cut -f2-; }
warnings() { grep $'^warning\t' "$tmp_dir/events" | cut -f2- || true; }

# --- At `human`, nothing runs (requirement 8b) --------------------------------

rc="$(run_case human medium 0 '{"verdict":"approve","reasons":["fine"]}')"
assert_eq "at human the stage returns 0" "0" "$rc"
assert_eq "  ... posts no review" "0" "$(count posts)"
assert_eq "  ... launches no model" "0" "$(count launches)"
assert_eq "  ... and logs nothing at all" "0" "$(count events)"
assert_eq "  ... but still asks merge_autonomy_effective_level for a FRESH read (issue #513)" \
  "fresh" "$(mal_calls | awk '{print $NF}')"

# --- Trivial tier: deterministic, no model (requirement 8b) -------------------

rc="$(run_case agent-approves low 0 '')"
assert_eq "a complexity:low PR returns 0" "0" "$rc"
assert_eq "  ... launches no model at all" "0" "$(count launches)"
assert_eq "  ... and posts exactly one review" "1" "$(count posts)"
assert_contains "  ... an APPROVE" "event=APPROVE" "$(posts)"
assert_contains "  ... under the Approver's own minted token" "token=a-minted-token" "$(posts)"
assert_eq "  ... logged as the trivial tier" '"trivial"' "$(jq -c '.tier' <<<"$(verdict_event)")"
assert_eq "  ... with an approve verdict" '"approve"' "$(jq -c '.verdict' <<<"$(verdict_event)")"
assert_eq "  ... and not an adjudication" 'false' "$(jq -c '.adjudication' <<<"$(verdict_event)")"
assert_eq "  ... carrying the repo (agent-ops#573)" '"Poetic-Poems/agent-ops"' "$(jq -c '.repo' <<<"$(verdict_event)")"
assert_eq "  ... with no model — the trivial tier never launches one" '""' "$(jq -c '.model' <<<"$(verdict_event)")"
assert_eq "  ... and posted:true — the review really reached GitHub" 'true' "$(jq -c '.posted' <<<"$(verdict_event)")"

# --- Standard and High tiers pick their own model (requirement 8b) ------------

run_case agent-approves medium 0 '{"verdict":"approve","reasons":["read it, found nothing"]}' >/dev/null
assert_eq "complexity:medium launches approver_model_default" "model-default" "$(launches)"
assert_contains "  ... and posts an APPROVE" "event=APPROVE" "$(posts)"
assert_eq "  ... logged as the standard tier" '"standard"' "$(jq -c '.tier' <<<"$(verdict_event)")"
assert_eq "  ... carrying the model it launched (agent-ops#573)" '"model-default"' "$(jq -c '.model' <<<"$(verdict_event)")"
assert_eq "  ... and posted:true" 'true' "$(jq -c '.posted' <<<"$(verdict_event)")"
assert_eq "  ... its prompt assembled with no overrides despite the poisoned config (requirement 4a)" \
  "{}" "$(cat "$tmp_dir/prompt_override_args")"

run_case agent-approves high 0 '{"verdict":"approve","reasons":["read it, found nothing"]}' >/dev/null
assert_eq "complexity:high launches approver_model_complex" "model-complex" "$(launches)"
assert_eq "  ... logged as the high tier" '"high"' "$(jq -c '.tier' <<<"$(verdict_event)")"
assert_eq "  ... carrying the model it launched" '"model-complex"' "$(jq -c '.model' <<<"$(verdict_event)")"

# --- Refuse-wins: the reasons become the review body (requirement 8c) ---------

run_case agent-approves medium 0 \
  '{"verdict":"refuse","reasons":["lib/foo.sh:42 drops the lock","no test covers it"]}' >/dev/null
assert_contains "a refusal posts REQUEST_CHANGES" "event=REQUEST_CHANGES" "$(posts)"
assert_contains "  ... carrying the first reason" "- lib/foo.sh:42 drops the lock" "$(posts)"
assert_contains "  ... and the second" "- no test covers it" "$(posts)"
assert_eq "  ... and raises no escalation on its own" "0" "$(count escalations)"
assert_eq "  ... and is itself logged as posted:true (agent-ops#573)" 'true' "$(jq -c '.posted' <<<"$(verdict_event)")"

# --- A streak of two routes to Critical, whatever the grade (requirement 8c) --

run_case agent-approves low 2 '{"verdict":"escalate","reasons":["a genuine design call"]}' >/dev/null
assert_eq "a streak of two launches approver_model_critical" "model-critical" "$(launches)"
assert_eq "  ... even for complexity:low, which alone would have skipped the model" \
  "1" "$(count launches)"
assert_eq "  ... logged as an adjudication" 'true' "$(jq -c '.adjudication' <<<"$(verdict_event)")"
assert_eq "  ... carrying the streak it was chosen by" '2' "$(jq -c '.refuse_streak' <<<"$(verdict_event)")"
assert_eq "  ... and names refuse-streak as the critical_reason, not protected-path" \
  '"refuse-streak"' "$(jq -c '.critical_reason' <<<"$(verdict_event)")"
assert_eq "  ... an escalate verdict posts no review" "0" "$(count posts)"
assert_eq "  ... and raises the escalation instead" "1" "$(count escalations)"
assert_contains "  ... carrying the adjudication's own reasons" \
  "a genuine design call" "$(escalations)"
assert_eq "  ... still carries the model an escalate verdict actually launched (agent-ops#573)" \
  '"model-critical"' "$(jq -c '.model' <<<"$(verdict_event)")"
assert_eq "  ... but posted:false — an escalate verdict reaches no GitHub review" \
  'false' "$(jq -c '.posted' <<<"$(verdict_event)")"

run_case agent-approves high 2 '{"verdict":"land","reasons":["both refusals are answered"]}' >/dev/null
assert_contains 'an adjudication land posts an APPROVE' "event=APPROVE" "$(posts)"
assert_eq "  ... and raises no escalation" "0" "$(count escalations)"
assert_eq "  ... and is logged as posted:true" 'true' "$(jq -c '.posted' <<<"$(verdict_event)")"

run_case agent-approves high 2 '{"verdict":"refuse","reasons":["the same defect, moved"]}' >/dev/null
assert_contains 'an adjudication refuse posts REQUEST_CHANGES' "event=REQUEST_CHANGES" "$(posts)"
assert_eq "  ... and also escalates" "1" "$(count escalations)"
assert_eq "  ... and is logged as posted:true" 'true' "$(jq -c '.posted' <<<"$(verdict_event)")"

rc="$(run_case agent-approves medium 2 '')"
assert_eq "an unparseable adjudication verdict still returns 0" "0" "$rc"
assert_eq "  ... posts no review" "0" "$(count posts)"
assert_eq "  ... escalates, since \"cannot settle\" is not \"nothing wrong\"" \
  "1" "$(count escalations)"

# --- Every failure costs a review, never a pull request (requirements 8b/43) --

rc="$(run_case agent-approves medium 0 '' MODEL_DEFAULT='')"
assert_eq "an empty approver_model_default returns 0" "0" "$rc"
assert_eq "  ... launches nothing" "0" "$(count launches)"
assert_eq "  ... posts nothing" "0" "$(count posts)"
assert_contains "  ... and warns that the stage is disabled" \
  "the Approver stage is disabled" "$(warnings)"

rc="$(run_case agent-approves medium 0 '' CREDENTIAL=0)"
assert_eq "an absent Approver credential returns 0" "0" "$rc"
assert_eq "  ... and posts nothing" "0" "$(count posts)"
assert_contains "  ... warning that the credential is missing" \
  "runtime credential is not present" "$(warnings)"

rc="$(run_case agent-approves medium 0 '')"
assert_eq "an unparseable ordinary verdict returns 0" "0" "$rc"
assert_eq "  ... posts no review" "0" "$(count posts)"
assert_eq "  ... and raises no escalation, since only adjudication escalates" \
  "0" "$(count escalations)"
assert_contains "  ... warning that no verdict was returned" \
  "did not return a parseable verdict" "$(warnings)"

rc="$(run_case agent-approves medium 0 '{"verdict":"maybe","reasons":[]}')"
assert_eq "an unrecognised verdict returns 0" "0" "$rc"
assert_eq "  ... and posts no review either way" "0" "$(count posts)"
assert_contains "  ... warning which verdict it could not read" \
  "unrecognised verdict" "$(warnings)"
assert_eq "  ... and its own approver-verdict event is posted:false (agent-ops#573)" \
  'false' "$(jq -c '.posted' <<<"$(verdict_event)")"

rc="$(run_case agent-approves medium 0 '{"verdict":"approve","reasons":["fine"]}' POST_RC=1)"
assert_eq "a review GitHub refused still returns 0" "0" "$rc"
assert_contains "  ... and is logged as a warning rather than passing silently" \
  "could not be posted" "$(warnings)"
assert_eq "  ... and the approver-verdict event records posted:false despite an approve verdict (agent-ops#573)" \
  'false' "$(jq -c '.posted' <<<"$(verdict_event)")"

# --- The tier is resolved after the Reviewer, not before it (requirement 8b, --
# --- agent-ops#470) ------------------------------------------------------------

run_case agent-approves medium 0 '{"verdict":"approve","reasons":["fine"]}' \
  POST_REVIEW_LABEL=high >/dev/null
assert_eq "a mid-round medium -> high label correction resolves to high" \
  "high" "$(resolved_complexity)"
assert_eq "  ... and reaches the Approver's own tier choice" \
  "model-complex" "$(launches)"
assert_eq "  ... logged as the high tier, not the pre-Reviewer medium" \
  '"high"' "$(jq -c '.tier' <<<"$(verdict_event)")"

run_case agent-approves high 0 '{"verdict":"approve","reasons":["fine"]}' \
  POST_REVIEW_LABEL=low >/dev/null
assert_eq "raise-never-lower: a high pre-Reviewer grade survives a lower label" \
  "high" "$(resolved_complexity)"
assert_eq "  ... and still launches approver_model_complex" \
  "model-complex" "$(launches)"

run_case agent-approves medium 0 '{"verdict":"approve","reasons":["fine"]}' \
  GH_LABEL_RC=1 >/dev/null
assert_eq "an unreadable post-review label leaves the pre-Reviewer grade untouched" \
  "medium" "$(resolved_complexity)"
assert_eq "  ... and still launches approver_model_default" \
  "model-default" "$(launches)"

# --- D18 WI-12 (agent-ops#415): a protected path forces the critical tier,
# regardless of complexity — including complexity:low, which alone would
# have short-circuited to a deterministic approval with no model call at all.

run_case agent-approves low 0 '{"verdict":"approve","reasons":["read it, protected but fine"]}' \
  PROTECTED_RC=0 >/dev/null
assert_eq "a protected-path complexity:low PR launches a real model engagement" \
  "model-critical" "$(launches)"
assert_eq "  ... rather than the deterministic no-model approval" "1" "$(count launches)"
assert_eq "  ... logged as the critical tier" '"critical"' "$(jq -c '.tier' <<<"$(verdict_event)")"
assert_eq "  ... naming protected-path as the critical_reason" \
  '"protected-path"' "$(jq -c '.critical_reason' <<<"$(verdict_event)")"
assert_eq "  ... and not an adjudication (no refuse streak drove this)" \
  'false' "$(jq -c '.adjudication' <<<"$(verdict_event)")"
assert_contains "  ... having asked the one classifier, landing_protected_paths_hit" \
  "Poetic-Poems/agent-ops" "$(protected_calls)"

run_case agent-approves medium 0 '{"verdict":"approve","reasons":["fine, and protected"]}' \
  PROTECTED_RC=0 >/dev/null
assert_eq "a protected-path complexity:medium PR still routes to critical, not standard" \
  "model-critical" "$(launches)"
assert_eq "  ... logged as the critical tier" '"critical"' "$(jq -c '.tier' <<<"$(verdict_event)")"

# Fail-closed the opposite way from landing_eligible: an unreadable changed-
# file list (exit 2) routes *to* critical, the more expensive tier, never
# away from it.
run_case agent-approves low 0 '{"verdict":"approve","reasons":["fine"]}' \
  PROTECTED_RC=2 >/dev/null
assert_eq "an unreadable changed-file list (exit 2) also forces the critical tier" \
  "model-critical" "$(launches)"
assert_eq "  ... logged as the critical tier" '"critical"' "$(jq -c '.tier' <<<"$(verdict_event)")"

# An untouched protected path (the PROTECTED_RC=1 default every case above
# this block already relied on) leaves every tier exactly as before —
# regression-pinned directly rather than only implied by every other case's
# default.
run_case agent-approves low 0 '' >/dev/null
assert_eq "no protected path, complexity:low: still the deterministic trivial tier" \
  "0" "$(count launches)"
assert_eq "  ... logged as trivial, not critical" '"trivial"' "$(jq -c '.tier' <<<"$(verdict_event)")"
assert_eq "  ... with no critical_reason at all" \
  "null" "$(jq -c '.critical_reason // null' <<<"$(verdict_event)")"

# --- The write token is re-minted once the engagement returns (agent-ops#945) -

run_case agent-approves medium 0 '{"verdict":"approve","reasons":["fine"]}' \
  GATE_TOKEN=stage-entry-token WRITE_TOKEN=fresh-write-token >/dev/null
assert_eq "the pre-engagement token is spent nowhere" "0" \
  "$(grep -c 'stage-entry-token' "$tmp_dir/posts")"
assert_contains "  ... only the token re-minted once the engagement returns is" \
  "token=fresh-write-token" "$(posts)"
assert_eq "  ... exactly two mints: the pre-engagement gate and the post-engagement write" \
  "2" "$(token_calls)"

run_case agent-approves low 0 '' GATE_TOKEN=only-mint WRITE_TOKEN=never-used >/dev/null
assert_contains "the trivial tier's one deterministic write spends the pre-engagement mint" \
  "token=only-mint" "$(posts)"
assert_eq "  ... since no model engagement ran to make that value stale" "1" "$(token_calls)"

rc="$(run_case agent-approves medium 0 '{"verdict":"approve","reasons":["fine"]}' WRITE_TOKEN_RC=1)"
assert_eq "a token that cannot be re-minted once the engagement returns still returns 0" "0" "$rc"
assert_eq "  ... posts nothing" "0" "$(count posts)"
assert_contains "  ... and warns distinguishing entry-mintable from now-unmintable" \
  "still mintable at stage entry" "$(warnings)"
assert_eq "  ... without escalating — no adjudication was in progress" "0" "$(count escalations)"

run_case agent-approves medium 2 '{"verdict":"refuse","reasons":["the same defect, moved"]}' \
  WRITE_TOKEN_RC=1 >/dev/null
assert_eq "a re-mint failure mid-adjudication still escalates rather than stranding it" \
  "1" "$(count escalations)"
assert_contains "  ... carrying the adjudication's own reasons, not a generic placeholder" \
  "the same defect, moved" "$(escalations)"
assert_eq "  ... and posts no review, since no fresh token ever reached GitHub" \
  "0" "$(count posts)"

echo
if (( failures == 0 )); then
  echo "All approver-wiring assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
