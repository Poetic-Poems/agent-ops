#!/usr/bin/env bash
#
# test/refiner-verdicts.test.sh — regression test for `maybe_run_refiner`'s
# verdict switch in agent-cycle.sh (requirements 39c, 39d, 39e), the piece
# that translates a Refiner engagement's JSON verdicts into log events,
# labels and blocks.
#
# Issues #287/#289: nothing in test/ ever called `maybe_run_refiner`.
# `test/refiner-eligibility.test.sh` covers the candidate set on the other
# side of the loop; nothing drove the switch that consumes the verdicts. That
# gap is exactly how a field-name mismatch between `prompts/refiner.md` (which
# said `spec`) and the switch's consumer (`refinement_record_fields`, which
# reads `refined_spec`) survived to human review on PR #283: a `refined`
# verdict written the way the prompt asked would have been silently degraded
# to `refined-uncorroborated` on every engagement, the specification the
# expensive pass produced discarded, while every event in the log read like an
# ordinary examination. Case (d) below is that defect, pinned from both sides:
# a payload keyed `spec` must not be recorded, and the shipped prompt must
# name `refined_spec`.
#
# The harness follows test/enabler-verdicts.test.sh, the same shape of test
# for `maybe_run_enabler`: the functions under test are lifted whole out of
# agent-cycle.sh with awk, so this cannot pass against a copy the script has
# since moved on from, and the library functions the switch actually depends
# on for correctness — `refinement_record_fields`, `refinement_entry_problem`,
# `refinement_issue_number`, `refinement_block_fields`,
# `refiner_engagement_set` (lib/refinement.sh), `item_event_fields`
# (lib/cycle-state.sh), `label_own_action_fields` (lib/label-marker.sh),
# `pipeline_actor_label` (lib/pipeline-marker.sh) — are sourced for real, so
# what is exercised is the genuine recording path rather than a paraphrase of
# it. Everything with a side effect outside the process — `claude` itself,
# `gh` (via the REFINEMENT_GH hook the library already exposes for tests),
# the state-repo claim registry — is stubbed.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/refiner-verdicts.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$SCRIPT_DIR"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                 %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- Lift the functions under test verbatim ---------------------------------
#
# Lifted, not restated: this cannot pass against a copy the script has since
# moved on from, the same guarantee test/enabler-verdicts.test.sh's extraction
# gives `maybe_run_enabler`.
extract_fn() {
  local start_pat="$1" file="$2"
  awk -v start="$start_pat" '
    $0 == start { on = 1 }
    on          { print }
    on && /^}$/ { exit }
  ' "$file"
}

maybe_run_refiner_fn="$(extract_fn 'maybe_run_refiner() {' "$SCRIPT_DIR/agent-cycle.sh")"
record_needs_refinement_block_fn="$(extract_fn 'record_needs_refinement_block() {' "$SCRIPT_DIR/agent-cycle.sh")"
refiner_claim_key_fn="$(extract_fn 'refiner_claim_key() {' "$SCRIPT_DIR/agent-cycle.sh")"
extract_json_result_fn="$(extract_fn 'extract_json_result() {' "$SCRIPT_DIR/agent-cycle.sh")"

if [[ "$maybe_run_refiner_fn" != *"refiner-examined"* ]]; then
  printf 'FAIL - maybe_run_refiner could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$record_needs_refinement_block_fn" != *"attempt-failed"* ]]; then
  printf 'FAIL - record_needs_refinement_block could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$refiner_claim_key_fn" != *"__"* ]]; then
  printf 'FAIL - refiner_claim_key could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$extract_json_result_fn" != *"awk"* ]]; then
  printf 'FAIL - extract_json_result could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi

eval "$extract_json_result_fn"
eval "$refiner_claim_key_fn"
eval "$record_needs_refinement_block_fn"
eval "$maybe_run_refiner_fn"

# --- A claim.sh stub that always wins, so the claim step needs no network ---
# It echoes its arguments, which the call site redirects into
# $cycle_dir/claim.log — how the containment cases assert that a discarded
# engagement's claims were expired rather than released.
fake_root="$tmp_dir/fake-root"
mkdir -p "$fake_root/lib"
cat > "$fake_root/lib/claim.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*"
exit 0
STUB
chmod +x "$fake_root/lib/claim.sh"

# --- The gh stub, through the library's own REFINEMENT_GH hook --------------
# The same stub shape as test/needs-refinement.test.sh: label edits append to
# $tmp_dir/label-calls, assignee edits (only ever `refinement_assignee_remove`
# now — nothing here adds an assignment any more) to $tmp_dir/assignee-calls.
# Stubbing here rather than overriding `refinement_label_add` keeps the label
# projections themselves under test.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
[[ "$1" == "issue" && "$2" == "edit" ]] || exit 1
number="$3"; shift 3
repo=""; action=""; label=""; assignee=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) repo="$2"; shift 2 ;;
    --add-label) action="add"; label="$2"; shift 2 ;;
    --remove-label) action="remove"; label="$2"; shift 2 ;;
    --add-assignee) action="assign"; assignee="$2"; shift 2 ;;
    --remove-assignee) action="unassign"; assignee="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$label" ]] && printf '%s %s %s %s\n' "$action" "$repo" "$number" "$label" >> "$d/label-calls"
[[ -n "$assignee" ]] && printf '%s %s %s %s\n' "$action" "$repo" "$number" "$assignee" >> "$d/assignee-calls"
exit 0
STUB
chmod +x "$tmp_dir/gh"
export REFINEMENT_GH="$tmp_dir/gh"

# --- Stubs for every dependency whose own correctness is not this test's job -
#
# log_event, run_claude_stage, stage_prompt_text, stage_budget_apply,
# metering_fields, stage_watchdog_warning, fleet_limit_resume_at,
# detect_and_log_limit_hit, stage_salvage_result: each has (or belongs to) its
# own test elsewhere (metering.test.sh, limit-detection.test.sh,
# salvage.test.sh); wiring the real ones in here would make this file a second
# copy of those, coupled to their internals for no assertion this file makes.
calls_log=""
record() { printf '%s\n' "$*" >> "$calls_log"; }

log_event() { record "event $1 $2"; }
stage_prompt_text() { printf 'stub prompt'; }
stage_budget_apply() { :; }
metering_fields() { printf '{}'; }
stage_watchdog_warning() { printf ''; }
fleet_limit_resume_at() { printf ''; }
detect_and_log_limit_hit() { return 0; }
stage_salvage_result() { return 1; }

# run_claude_stage's stand-in for the Claude CLI: writes the canned verdict
# envelope `$STUB_REFINED_JSON` — `{"refined": [...]}`, the Refiner's own
# envelope key, deliberately not the Enabler's `examined` (a stub writing that
# shape would make every case below pass vacuously with zero verdicts) — to
# OUT_FILE as `{"result": "<that envelope, as text>"}`, exactly the shape
# extract_json_result parses a real transcript's final message out of.
# $STUB_RESULT_RAW substitutes unparseable prose for the containment case.
# Also sets the two globals the real run_claude_stage sets as a side effect
# (stage_gaps_json, stage_kill_reason), since the caller reads them
# immediately afterward.
run_claude_stage() {
  local out_file="$5"
  if [[ -n "${STUB_RESULT_RAW:-}" ]]; then
    jq -nc --arg r "$STUB_RESULT_RAW" '{result: $r, session_id: "stub-session"}' > "$out_file"
  else
    jq -nc --argjson env "$STUB_REFINED_JSON" '{result: ($env | tostring), session_id: "stub-session"}' \
      > "$out_file"
  fi
  # shellcheck disable=SC2034  # read by the eval'd maybe_run_refiner, not visible here
  stage_gaps_json="null"
  # shellcheck disable=SC2034
  stage_kill_reason=""
  return "${STUB_RUN_RC:-0}"
}

# --- Fixed globals every call to maybe_run_refiner needs --------------------
mkdir -p "$fake_root/prompts"
: > "$fake_root/prompts/refiner.md"

# Every one of these is consumed only by the eval'd maybe_run_refiner or
# record_needs_refinement_block, which static analysis cannot see into — the
# same reason test/enabler-verdicts.test.sh disables SC2034 around its own
# eval'd globals.
# shellcheck disable=SC2034
lock_acquired=1
# shellcheck disable=SC2034
refiner_allowed=1
# shellcheck disable=SC2034
DRY_RUN=0
# shellcheck disable=SC2034
limit_hit_this_cycle=0
# shellcheck disable=SC2034
refiner_model="claude-test-model"
# shellcheck disable=SC2034
PROMPTS_DIR="$fake_root/prompts"
# shellcheck disable=SC2034
refiner_max_per_engagement=10
# shellcheck disable=SC2034
refined_label="refined-by-agent"
# shellcheck disable=SC2034
needs_refinement_label="needs-refinement"
# shellcheck disable=SC2034
enabler_assignee="tester"
# shellcheck disable=SC2034
blocked_json='[]'
# shellcheck disable=SC2034
refinements_json='{}'
# shellcheck disable=SC2034
state_repo=""
state_dir="$tmp_dir/state"
# shellcheck disable=SC2034
node_name="test-node"
# shellcheck disable=SC2034
cycle_id="test-cycle"
# shellcheck disable=SC2034
prompt_overrides_json="{}"
# shellcheck disable=SC2034
stage_backstop_min=1
# shellcheck disable=SC2034
stage_inactivity_min=1
# shellcheck disable=SC2034
ONCE=0
SCRIPT_DIR="$fake_root"
mkdir -p "$state_dir"

# run_case DESC CANDIDATES_JSON VERDICTS_JSON
# One isolated engagement: a fresh cycle_dir and calls.log, the given
# candidate set claimed in full (the stub claim.sh never loses), the given
# verdicts returned as if the model produced them, and on stdout: the event
# log, the gh stub's label and assignee calls (prefixed `gh-label` /
# `gh-assignee`), the claim registry calls (prefixed `claimlog`), and
# maybe_run_refiner's own return code as `refiner-rc N`.
run_case() {
  local desc="$1" candidates_json="$2" verdicts_json="$3" rc_val
  cycle_dir="$(mktemp -d "$tmp_dir/case.XXXXXX")"
  calls_log="$cycle_dir/calls.log"
  : > "$calls_log"
  rm -f "$tmp_dir/label-calls" "$tmp_dir/assignee-calls"
  # shellcheck disable=SC2034  # read only by the eval'd maybe_run_refiner
  refiner_candidates_json="$candidates_json"
  STUB_REFINED_JSON="$(jq -nc --argjson v "$verdicts_json" '{refined: $v}')"
  maybe_run_refiner 0 >/dev/null 2>&1
  rc_val=$?
  printf 'refiner-rc %s\n' "$rc_val" >> "$calls_log"
  cat "$calls_log"
  sed 's/^/gh-label /' "$tmp_dir/label-calls" 2>/dev/null || true
  sed 's/^/gh-assignee /' "$tmp_dir/assignee-calls" 2>/dev/null || true
  sed 's/^/claimlog /' "$cycle_dir/claim.log" 2>/dev/null || true
}

events_named() {  # events_named LOG NAME -> each matching event's JSON payload, one per line
  grep -E "^event $2 " <<<"$1" | sed -E "s/^event $2 //"
}

issue_candidates='[{"repo":"o/r","source":"issues","item":"55"}]'
td_candidates='[{"repo":"o/r","source":"tech-debt","item":"TD26080101"}]'

# ============================================================================
# (a) refined, source issues, comment posted: recorded, labelled
# ============================================================================
verdicts='[{"repo":"o/r","item":"55","verdict":"refined","reason":"specified in one comment",
            "comments_posted":["https://github.com/o/r/issues/55#issuecomment-1"]}]'
calls="$(run_case "refined issue" "$issue_candidates" "$verdicts")"

assert_eq "refined issue: exactly one item-refined event" "1" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
ir_evt="$(events_named "$calls" item-refined | head -n1)"
assert_eq "refined issue: item-refined is attributed by: refiner" "refiner" "$(jq -r '.by' <<<"$ir_evt")"
assert_eq "refined issue: item-refined carries the comment URL" \
  "https://github.com/o/r/issues/55#issuecomment-1" "$(jq -r '.comment_url' <<<"$ir_evt")"
assert_eq "refined issue: an issue item's record is the pointer, not a spec" "absent" \
  "$(jq -r '.spec // "absent"' <<<"$ir_evt")"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "refined issue: refiner-examined outcome is refined" "refined" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "refined issue: ...carrying the claimed entry's source" "issues" "$(jq -r '.source' <<<"$xmn_evt")"
assert_eq "refined issue: exactly one own-label-action for the add" "1" \
  "$(grep -cE '^event own-label-action ' <<<"$calls")"
ola_evt="$(events_named "$calls" own-label-action | head -n1)"
assert_eq "refined issue: the own-label-action is an add of refined_label" "add refined-by-agent" \
  "$(jq -r '"\(.action) \(.label)"' <<<"$ola_evt")"
assert_contains "refined issue: the label reached gh" "gh-label add o/r 55 refined-by-agent" "$calls"

# ============================================================================
# (b) refined, source issues, no comment posted: degraded, never recorded
# ============================================================================
verdicts='[{"repo":"o/r","item":"55","verdict":"refined","reason":"wrote a spec but posted nothing",
            "refined_spec":"## A spec with no comment behind it"}]'
calls="$(run_case "refined issue, uncorroborated" "$issue_candidates" "$verdicts")"

assert_eq "uncorroborated issue: no item-refined is ever written" "0" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "uncorroborated issue: the warning says nothing was posted" \
  "carries no comment" "$(jq -r '.detail' <<<"$warn_evt")"
assert_contains "uncorroborated issue: ...and that nothing was recorded" \
  "not recorded as refined" "$(jq -r '.detail' <<<"$warn_evt")"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "uncorroborated issue: refiner-examined outcome is exactly refined-uncorroborated" \
  "refined-uncorroborated" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "uncorroborated issue: no label write either" "0" \
  "$(grep -cE '^event own-label-action ' <<<"$calls")"
assert_not_contains "uncorroborated issue: gh never saw a label call" "gh-label" "$calls"

# ============================================================================
# (c) refined, non-issue source, refined_spec carried: the spec itself travels
# ============================================================================
verdicts='[{"repo":"o/r","item":"TD26080101","verdict":"refined","reason":"specified in place",
            "refined_spec":"## Refined\nScope: only the parser."}]'
calls="$(run_case "refined tech-debt" "$td_candidates" "$verdicts")"

assert_eq "refined tech-debt: exactly one item-refined event" "1" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
ir_evt="$(events_named "$calls" item-refined | head -n1)"
assert_eq "refined tech-debt: item-refined carries the spec verbatim" "## Refined
Scope: only the parser." "$(jq -r '.spec' <<<"$ir_evt")"
assert_eq "refined tech-debt: attributed by: refiner" "refiner" "$(jq -r '.by' <<<"$ir_evt")"
assert_eq "refined tech-debt: no comment_url for an item with no thread" "absent" \
  "$(jq -r '.comment_url // "absent"' <<<"$ir_evt")"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "refined tech-debt: refiner-examined outcome is refined" "refined" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "refined tech-debt: only an issues-source item gets the label" "0" \
  "$(grep -cE '^event own-label-action ' <<<"$calls")"
assert_not_contains "refined tech-debt: gh never saw a label call" "gh-label" "$calls"

# ============================================================================
# (d) refined, non-issue source, payload keyed `spec` instead of `refined_spec`
# — the exact defect fixed in 0a46cd7 (PR #283), and the case whose absence
# from test/ let it reach human review. The switch reads what
# `refinement_record_fields` extracts, and that reads `.refined_spec`; a
# verdict keyed `spec` must degrade, never be recorded as refined.
# ============================================================================
verdicts='[{"repo":"o/r","item":"TD26080101","verdict":"refined","reason":"specified in place",
            "spec":"## A spec under the wrong field name"}]'
calls="$(run_case "refined tech-debt, wrong field name" "$td_candidates" "$verdicts")"

assert_eq "spec-vs-refined_spec: a payload keyed spec records NO item-refined" "0" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "spec-vs-refined_spec: the warning names the missing spec" \
  "carries no spec" "$(jq -r '.detail' <<<"$warn_evt")"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "spec-vs-refined_spec: refiner-examined outcome is refined-uncorroborated" \
  "refined-uncorroborated" "$(jq -r '.outcome' <<<"$xmn_evt")"

# The other side of the same boundary: the shipped prompt must instruct the
# field name the consumer reads. `prompts/refiner.md` saying `spec` while
# `refinement_record_fields` reads `refined_spec` is precisely the mismatch
# the case above records the consequence of.
refiner_prompt="$repo_root/prompts/refiner.md"
backtick='`'
assert_eq "prompt/consumer agreement: prompts/refiner.md names refined_spec" "yes" \
  "$(grep -q 'refined_spec' "$refiner_prompt" && echo yes || echo no)"
assert_eq "prompt/consumer agreement: ...and never a bare spec field" "0" \
  "$(grep -cE "\"spec\"[[:space:]]*:|${backtick}spec${backtick}" "$refiner_prompt")"
assert_eq "prompt/consumer agreement: refinement_record_fields reads refined_spec" "yes" \
  "$(grep -q '\.refined_spec' "$repo_root/lib/refinement.sh" && echo yes || echo no)"

# ============================================================================
# (e) needs-refinement, complete entry, not already blocked: recorded as a
# refiner-attributed block with both projections
# ============================================================================
verdicts='[{"repo":"o/r","item":"55","verdict":"needs-refinement","reason":"no acceptance criteria",
            "missing":"a scope bound and acceptance criteria",
            "evidence":"issue 55 body and all comments, read in full"}]'
calls="$(run_case "needs-refinement recorded" "$issue_candidates" "$verdicts")"

assert_eq "decline: exactly one attempt-failed block" "1" \
  "$(grep -cE '^event attempt-failed ' <<<"$calls")"
af_evt="$(events_named "$calls" attempt-failed | head -n1)"
assert_eq "decline: the block is attributed stage: refiner" "refiner" "$(jq -r '.stage' <<<"$af_evt")"
assert_eq "decline: marked as the refinement kind" "needs-refinement" "$(jq -r '.kind' <<<"$af_evt")"
assert_eq "decline: missing is promoted to the unblock condition" \
  "a scope bound and acceptance criteria" "$(jq -r '.unblock_condition' <<<"$af_evt")"
assert_eq "decline: the applied label is recorded on the block" "needs-refinement" \
  "$(jq -r '.needs_refinement_label' <<<"$af_evt")"
assert_eq "decline: the applied blocked label is recorded on the block" "blocked" \
  "$(jq -r '.blocked_label' <<<"$af_evt")"
assert_eq "decline: the applied reason label is recorded on the block" "blocked:needs-refinement" \
  "$(jq -r '.blocked_reason_label' <<<"$af_evt")"
assert_contains "decline: the label reached gh" "gh-label add o/r 55 needs-refinement" "$calls"
assert_contains "decline: the blocked label reached gh" "gh-label add o/r 55 blocked" "$calls"
assert_contains "decline: the reason label reached gh" "gh-label add o/r 55 blocked:needs-refinement" "$calls"
assert_not_contains "decline: nothing is ever assigned any more" "gh-assignee" "$calls"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "decline: refiner-examined outcome is needs-refinement" \
  "needs-refinement" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "decline: ...with the block recorded" "1" "$(jq -r '.recorded' <<<"$xmn_evt")"

# ============================================================================
# (f) needs-refinement with `missing` empty: refused by the completeness bar
# ============================================================================
verdicts='[{"repo":"o/r","item":"55","verdict":"needs-refinement","reason":"under-specified",
            "missing":"","evidence":"issue 55 body, read in full"}]'
calls="$(run_case "needs-refinement refused: no missing" "$issue_candidates" "$verdicts")"

assert_eq "refused decline: no block is recorded" "0" \
  "$(grep -cE '^event attempt-failed ' <<<"$calls")"
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "refused decline: the warning names the dropped entry, attributed to the Refiner" \
  "Refiner needs_refinement entry dropped" "$(jq -r '.detail' <<<"$warn_evt")"
assert_contains "refused decline: ...and says what it is short of" \
  "says nothing about what is missing" "$(jq -r '.detail' <<<"$warn_evt")"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "refused decline: refiner-examined outcome is needs-refinement-refused" \
  "needs-refinement-refused" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "refused decline: ...with nothing recorded" "0" "$(jq -r '.recorded' <<<"$xmn_evt")"

# ============================================================================
# (g) needs-refinement for an item already blocked: no second block, so the
# Enabler threshold keeps running from the original one
# ============================================================================
# shellcheck disable=SC2034  # read by the eval'd record_needs_refinement_block
blocked_json='[{"repo":"o/r","item":"55"}]'
verdicts='[{"repo":"o/r","item":"55","verdict":"needs-refinement","reason":"no acceptance criteria",
            "missing":"a scope bound and acceptance criteria",
            "evidence":"issue 55 body and all comments, read in full"}]'
calls="$(run_case "needs-refinement refused: already blocked" "$issue_candidates" "$verdicts")"
# shellcheck disable=SC2034
blocked_json='[]'

assert_eq "already blocked: no second block is recorded" "0" \
  "$(grep -cE '^event attempt-failed ' <<<"$calls")"
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "already blocked: the warning says why it was left alone" \
  "already blocked" "$(jq -r '.detail' <<<"$warn_evt")"
assert_not_contains "already blocked: no label write for a refused block" "gh-label" "$calls"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "already blocked: refiner-examined outcome is needs-refinement-refused" \
  "needs-refinement-refused" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "already blocked: ...with nothing recorded" "0" "$(jq -r '.recorded' <<<"$xmn_evt")"

# ============================================================================
# (h) an unrecognised verdict: recorded, acted on in no way
# ============================================================================
verdicts='[{"repo":"o/r","item":"55","verdict":"sideways","reason":"confused"}]'
calls="$(run_case "unknown verdict" "$issue_candidates" "$verdicts")"

warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "unknown verdict: the warning names it" \
  "unrecognised verdict 'sideways'" "$(jq -r '.detail' <<<"$warn_evt")"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "unknown verdict: refiner-examined outcome is unknown-verdict" \
  "unknown-verdict" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "unknown verdict: no item-refined, no block" "0" \
  "$(grep -cE '^event (item-refined|attempt-failed) ' <<<"$calls")"
assert_not_contains "unknown verdict: no label or assignee write" "gh-" "$calls"

# ============================================================================
# (i) requirement 39e's two mismatches: a verdict for an unclaimed item is
# discarded, a claimed item the envelope never mentions is warned about
# ============================================================================
verdicts='[{"repo":"other/repo","item":"99","verdict":"refined","reason":"not ours to act on",
            "comments_posted":["https://github.com/other/repo/issues/99#issuecomment-1"]}]'
calls="$(run_case "unclaimed verdict, unmentioned claim" "$issue_candidates" "$verdicts")"

assert_contains "unclaimed: a warning names the ignored item" \
  "did not claim (other/repo 99)" "$calls"
assert_eq "unclaimed: no refiner-examined at all" "0" \
  "$(grep -cE '^event refiner-examined ' <<<"$calls")"
assert_eq "unclaimed: no item-refined either" "0" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
assert_contains "unmentioned claim: a warning names the claimed-but-unanswered item" \
  "no verdict for claimed item o/r 55" "$calls"

# ============================================================================
# Failure containment (requirement 39e): a discarded engagement records no
# verdict events, expires its claims, and never disturbs the cycle's outcome
# ============================================================================
key55="$(refiner_claim_key "o/r" "issues" "55")"

STUB_RESULT_RAW="I examined the items but wrote prose instead of the object."
calls="$(run_case "unparseable final message" "$issue_candidates" '[]')"
STUB_RESULT_RAW=""

assert_contains "unparseable: maybe_run_refiner still returns 0" "refiner-rc 0" "$calls"
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "unparseable: the warning names the failure" \
  "refiner returned an unparseable final message" "$(jq -r '.detail' <<<"$warn_evt")"
assert_eq "unparseable: ...and the claimed items the engagement was given" "o/r 55" \
  "$(jq -r '.items[] | "\(.repo) \(.item)"' <<<"$warn_evt")"
assert_eq "unparseable: no refiner-examined, item-refined or attempt-failed at all" "0" \
  "$(grep -cE '^event (refiner-examined|item-refined|attempt-failed) ' <<<"$calls")"
assert_contains "unparseable: the claim is expired, not left to its TTL" \
  "claimlog expire refiner $key55" "$calls"

STUB_RUN_RC=3
verdicts='[{"repo":"o/r","item":"55","verdict":"refined","reason":"a verdict a failed stage must not land",
            "comments_posted":["https://github.com/o/r/issues/55#issuecomment-1"]}]'
calls="$(run_case "non-zero stage exit" "$issue_candidates" "$verdicts")"
STUB_RUN_RC=0

assert_contains "failed stage: maybe_run_refiner still returns 0" "refiner-rc 0" "$calls"
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "failed stage: the warning names the exit" \
  "refiner exited 3" "$(jq -r '.detail' <<<"$warn_evt")"
assert_eq "failed stage: even a parseable verdict from it records nothing" "0" \
  "$(grep -cE '^event (refiner-examined|item-refined|attempt-failed) ' <<<"$calls")"
assert_contains "failed stage: the claim is expired here too" \
  "claimlog expire refiner $key55" "$calls"

# ============================================================================
# The argv cap (requirement 4g, TD-PPagop-26081401): the claim accumulator
# ============================================================================
# The claim loop's own `claimed_json="$(jq -c --argjson e "$entry" ...)"`
# used to deliver each claimed candidate — body included — as a second
# --argjson, an argv entry capped at MAX_ARG_STRLEN. A 150000-byte candidate
# body (padding past what this pipeline ever produces on its own, but
# nothing here bounds one) proves the fold now survives it — not a crash,
# not a silently dropped claim.
printf 'x%.0s' $(seq 1 150000) > "$tmp_dir/big_body.txt"
td_candidates_big="$(jq -nc --rawfile b "$tmp_dir/big_body.txt" \
  '[{"repo":"o/r","source":"tech-debt","item":"TDBIG","body":$b}]')"
assert_eq "the oversized candidate fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$td_candidates_big" | wc -c) > 131072 ))"
verdicts_big='[{"repo":"o/r","item":"TDBIG","verdict":"refined","reason":"specified in place",
                "refined_spec":"## Refined\nScope: only the parser."}]'
calls="$(run_case "argv cap: oversized candidate body" "$td_candidates_big" "$verdicts_big")"
assert_eq "the oversized claim still reaches the claim fold: exactly one item-refined event" "1" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
ir_evt="$(events_named "$calls" item-refined | head -n1)"
assert_eq "  ... naming the oversized item, not dropped or corrupted" "TDBIG" "$(jq -r '.item' <<<"$ir_evt")"

# ============================================================================
# The argv cap (requirement 4g, TD-PPagop-26081401): the unparseable-verdict warning
# ============================================================================
# `items_named_json` — every claimed item trimmed to {repo, item} — used to
# ride into the "no verdicts recorded" warning as a second --argjson. Each
# entry is small, but the array still grows with the number of items this
# engagement claimed, so 50 claimed items with a heavily padded item ref
# prove the warning still carries every one of them, past the cap, on an
# unparseable stage result.
pad_ref="$(printf 'x%.0s' $(seq 1 2700))"
td_candidates_many="$(jq -nc --arg p "$pad_ref" \
  '[range(1; 51) | {repo: "o/r", source: "tech-debt", item: ("TD-" + $p + "-" + (. | tostring))}]')"
STUB_RESULT_RAW="I examined the items but wrote prose instead of the object."
saved_refiner_max_per_engagement="$refiner_max_per_engagement"
refiner_max_per_engagement=50
calls="$(run_case "unparseable final message, oversized claim set" "$td_candidates_many" '[]')"
refiner_max_per_engagement="$saved_refiner_max_per_engagement"
STUB_RESULT_RAW=""
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_eq "the oversized items_named_json fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(jq -c '.items' <<<"$warn_evt" | wc -c) > 131072 ))"
assert_eq "the warning still carries every one of the 50 claimed items" \
  "50" "$(jq '.items | length' <<<"$warn_evt")"
assert_eq "  ... and no refiner-examined/item-refined/attempt-failed at all" "0" \
  "$(grep -cE '^event (refiner-examined|item-refined|attempt-failed) ' <<<"$calls")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
