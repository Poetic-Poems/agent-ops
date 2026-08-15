#!/usr/bin/env bash
#
# test/enabler-verdicts.test.sh — regression test for `maybe_run_enabler`'s
# verdict switch in agent-cycle.sh (requirements 36a, 36b), the piece that
# translates an Enabler engagement's JSON verdicts into log events.
#
# TD-PPagop-26080805: nothing in test/ ever called `maybe_run_enabler`.
# `test/enabler-eligibility.test.sh` feeds `enabler-examined` events in as log
# *fixtures* to exercise the eligibility extract on the other side of the
# loop; nothing drove the switch that produces them. Two outcomes matter most
# because they are the failure paths, not the happy ones:
#
#   - `void-refused`  — requirement 34d's shared corroboration guard refusing
#     the Enabler's own `void` (PR #258, issue #243).
#   - `refinement-refused` — requirement 36b's thrash guard refusing a second
#     refinement of an item already refined once since the last human touch.
#   - `complete_handoff` (requirements 31c/32b, agent-ops#440) — refused when
#     this item's recorded failure never reached the Reviewer stage (PR #433:
#     the Implementor failed, the Reviewer block never ran, and this recovery
#     path flipped the pull request to ready anyway) or when `handoff_
#     complete_review`'s (lib/handoff.sh) own gate finds a real fault — the
#     same gate the Reviewer's own handoff runs, genuinely shared rather than
#     skipped on this path. test/handoff.test.sh covers `handoff_complete_
#     review` itself; what this file proves is that `maybe_run_enabler` calls
#     it at all, and reacts to `safe: false` by refusing the flip rather than
#     performing it anyway.
#
# All three exist to keep a wrong *permanent* verdict — or a wrong *act*, for
# `complete_handoff` — from being recorded, and their whole value is in what
# they write (or refuse to do) instead of the verdict the model asked for. A
# silent regression here would put an item back where the guard exists to
# keep it out of, while every event in the log still read like an ordinary
# examination.
#
# The harness, not the assertions, is the work (per the tech-debt item's own
# suggested fix): `maybe_run_enabler` is lifted whole out of agent-cycle.sh
# with awk, the same technique test/signal-exit.test.sh uses for the signal
# block, and run with the library functions it actually depends on for
# correctness — `void_guard_reason` (lib/void-guard.sh),
# `refinement_second_pass_refused`/`refinement_engagement_set`
# (lib/refinement.sh), `item_event_fields` (lib/cycle-state.sh) — sourced for
# real, so this test exercises the genuine guards rather than a paraphrase of
# them. Everything with a side effect outside the process — `claude` itself,
# `gh`, the state-repo claim registry — is stubbed. The evidence and verdict
# text used throughout is deliberately free of `PR #`/`commit <sha>`
# citations and of `{ref,path,expect,pattern}`-shaped evidence, so
# `void_guard_reason` never needs to call out to `gh` at all: what is under
# test is the switch's wiring, not the citation checker (test/void-guard.test.sh
# already covers that in depth).
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/enabler-verdicts.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"

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

# --- Lift maybe_run_enabler (and its two small in-file helpers) verbatim ---
#
# Lifted, not restated: this cannot pass against a copy the script has since
# moved on from, the same guarantee test/signal-exit.test.sh's extraction
# gives the signal block.
extract_fn() {
  local start_pat="$1" file="$2"
  awk -v start="$start_pat" '
    $0 == start { on = 1 }
    on          { print }
    on && /^}$/ { exit }
  ' "$file"
}

maybe_run_enabler_fn="$(extract_fn 'maybe_run_enabler() {' "$SCRIPT_DIR/agent-cycle.sh")"
enabler_claim_key_fn="$(extract_fn 'enabler_claim_key() {' "$SCRIPT_DIR/agent-cycle.sh")"
extract_json_result_fn="$(extract_fn 'extract_json_result() {' "$SCRIPT_DIR/agent-cycle.sh")"

if [[ "$maybe_run_enabler_fn" != *"enabler-examined"* ]]; then
  printf 'FAIL - maybe_run_enabler could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$enabler_claim_key_fn" != *"__verify"* ]]; then
  printf 'FAIL - enabler_claim_key could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$extract_json_result_fn" != *"awk"* ]]; then
  printf 'FAIL - extract_json_result could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi

eval "$extract_json_result_fn"
eval "$enabler_claim_key_fn"
eval "$maybe_run_enabler_fn"

# --- A claim.sh stub that always wins, so the claim step needs no network ---
fake_root="$tmp_dir/fake-root"
mkdir -p "$fake_root/lib"
cat > "$fake_root/lib/claim.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$fake_root/lib/claim.sh"

# --- Stubs for every dependency whose own correctness is not this test's job ---
#
# log_event, run_claude_stage, stage_prompt_text, stage_budget_apply,
# metering_fields, stage_watchdog_warning, fleet_limit_resume_at,
# release_refinement_label, create_escalation_issue: each has (or belongs to)
# its own test elsewhere (metering.test.sh, stage-*.test.sh,
# needs-refinement.test.sh); wiring the real ones in here would make this
# file a second copy of those, coupled to their internals for no assertion
# this file makes.
calls_log=""
record() { printf '%s\n' "$*" >> "$calls_log"; }

log_event() { record "event $1 $2"; }
stage_prompt_text() { printf 'stub prompt'; }
stage_budget_apply() { :; }
metering_fields() { printf '{}'; }
stage_watchdog_warning() { printf ''; }
fleet_limit_resume_at() { printf ''; }
release_refinement_label() { record "release-refinement-label $1 $2"; }

# create_escalation_issue is overridden per-scenario below (success vs a
# filing failure), so it is not defined here.

# run_claude_stage's stand-in for the Claude CLI: writes the canned verdict
# envelope `$STUB_EXAMINED_JSON` — `{"examined": [...]}` — to OUT_FILE as
# `{"result": "<that envelope, as text>"}`, exactly the shape
# extract_json_result parses a real transcript's final message out of. Also
# sets the two globals the real run_claude_stage sets as a side effect
# (stage_gaps_json, stage_kill_reason), since the caller reads them
# immediately afterward.
run_claude_stage() {
  local out_file="$5"
  jq -nc --argjson env "$STUB_EXAMINED_JSON" '{result: ($env | tostring), session_id: "stub-session"}' \
    > "$out_file"
  # shellcheck disable=SC2034  # read by the eval'd maybe_run_enabler, not visible here
  stage_gaps_json="null"
  # shellcheck disable=SC2034
  stage_kill_reason=""
  return "${STUB_RUN_RC:-0}"
}

# --- Fixed globals every call to maybe_run_enabler needs (requirement 35's guards) ---
mkdir -p "$fake_root/prompts"
: > "$fake_root/prompts/enabler.md"

# Every one of these is consumed only by the eval'd maybe_run_enabler, which
# static analysis cannot see into — the same reason test/signal-exit.test.sh
# disables SC2034 around its own eval'd acquire_lock globals.
# shellcheck disable=SC2034
lock_acquired=1
# shellcheck disable=SC2034
enabler_allowed=1
# shellcheck disable=SC2034
DRY_RUN=0
# shellcheck disable=SC2034
limit_hit_this_cycle=0
# shellcheck disable=SC2034
enabler_model="claude-test-model"
# shellcheck disable=SC2034
PROMPTS_DIR="$fake_root/prompts"
# shellcheck disable=SC2034
refinement_max_per_engagement=5
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
# shellcheck disable=SC2034
enabler_escalation_label="enabler-escalation"
# shellcheck disable=SC2034
enabler_assignee="tester"
# shellcheck disable=SC2034
ordered_repos_json='[{"slug":"acme/widgets","default_branch":"main"}]'
SCRIPT_DIR="$fake_root"
mkdir -p "$state_dir"

# handoff_complete_review is overridden per-scenario below (agent-ops#440's
# complete_handoff gate); a default that fails loudly means a scenario that
# forgets to define it is caught rather than silently exercising whatever the
# previous scenario left behind.
# shellcheck disable=SC2317  # invoked only by the eval'd maybe_run_enabler
handoff_complete_review() {
  echo "FAIL - handoff_complete_review was called but no scenario stub was set" >&2
  exit 98
}

# run_case DESC ELIGIBLE_JSON EXAMINED_JSON [CYCLE_RC]
# One isolated engagement: a fresh cycle_dir and calls.log, the given eligible
# set claimed in full (the stub claim.sh never loses), the given verdicts
# returned as if the model produced them, and the resulting event log on
# stdout.
run_case() {
  local desc="$1" eligible_json="$2" examined_json="$3" cycle_rc="${4:-0}"
  cycle_dir="$(mktemp -d)"
  calls_log="$cycle_dir/calls.log"
  : > "$calls_log"
  # shellcheck disable=SC2034  # read only by the eval'd maybe_run_enabler
  enabler_eligible_json="$eligible_json"
  STUB_EXAMINED_JSON="$(jq -nc --argjson e "$examined_json" '{examined: $e}')"
  maybe_run_enabler "$cycle_rc" >/dev/null 2>&1
  cat "$calls_log"
}

events_named() {  # events_named LOG NAME -> each matching event's JSON payload, one per line
  grep -E "^event $2 " <<<"$1" | sed -E "s/^event $2 //"
}

# ============================================================================
# void: an evidenced, uncited claim is corroborated and recorded
# ============================================================================
eligible='[{"repo":"acme/widgets","item":"TD001","blocked_ts":"2026-08-01T00:00:00Z","kind":"","reason":"threshold"}]'
examined='[{"repo":"acme/widgets","item":"TD001","verdict":"void","reason":"already fixed upstream",
            "evidence":"The failing script was deleted in an earlier change and its only caller removed; nothing here remains to implement."}]'
calls="$(run_case "void: corroborated" "$eligible" "$examined")"

assert_eq "void: exactly one item-void event" "1" \
  "$(grep -cE '^event item-void ' <<<"$calls")"
void_evt="$(events_named "$calls" item-void | head -n1)"
assert_eq "void: item-void names the item" "TD001" "$(jq -r '.item' <<<"$void_evt")"
assert_eq "void: item-void carries the model's reason" "already fixed upstream" "$(jq -r '.detail' <<<"$void_evt")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "void: enabler-examined outcome is void, not void-refused" "void" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "void: no attempt-failed on the corroborated path" "0" \
  "$(grep -cE '^event attempt-failed ' <<<"$calls")"
assert_contains "void: the label is released on a cleared void" \
  "release-refinement-label TD001 acme/widgets" "$calls"

# ============================================================================
# void-refused: no evidence at all — requirement 34d's guard, degrading to
# attempt-failed + enabler-examined(outcome: void-refused), never a
# permanent item-void
# ============================================================================
examined='[{"repo":"acme/widgets","item":"TD001","verdict":"void","reason":"looks done to me","evidence":""}]'
calls="$(run_case "void: refused for want of evidence" "$eligible" "$examined")"

assert_eq "void-refused: no item-void is ever written" "0" \
  "$(grep -cE '^event item-void ' <<<"$calls")"
assert_eq "void-refused: exactly one attempt-failed" "1" \
  "$(grep -cE '^event attempt-failed ' <<<"$calls")"
af_evt="$(events_named "$calls" attempt-failed | head -n1)"
assert_eq "void-refused: attempt-failed names the item" "TD001" "$(jq -r '.item' <<<"$af_evt")"
assert_contains "void-refused: attempt-failed's detail explains the refusal" \
  "void refused" "$(jq -r '.detail' <<<"$af_evt")"
assert_contains "void-refused: ...and carries the guard's own reason (no evidence)" \
  "no evidence recorded" "$(jq -r '.detail' <<<"$af_evt")"
assert_eq "void-refused: attempt-failed leaves the item blocked-and-clearable" \
  "Establish from the repository itself whether this item describes any remaining work." \
  "$(jq -r '.unblock_condition' <<<"$af_evt")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "void-refused: enabler-examined's outcome is exactly void-refused" \
  "void-refused" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_not_contains "void-refused: never escalation-failed (36a's exempted outcome)" \
  "escalation-failed" "$xmn_evt"
assert_not_contains "void-refused: the label is not released — the item is still blocked" \
  "release-refinement-label" "$calls"

# ============================================================================
# unblocked: an ordinary (non-refinement) item
# ============================================================================
examined='[{"repo":"acme/widgets","item":"TD001","verdict":"unblocked","reason":"the dependency merged"}]'
calls="$(run_case "unblocked: ordinary item" "$eligible" "$examined")"

assert_eq "unblocked: exactly one unblocked event" "1" \
  "$(grep -cE '^event unblocked ' <<<"$calls")"
ub_evt="$(events_named "$calls" unblocked | head -n1)"
assert_eq "unblocked: by is enabler" "enabler" "$(jq -r '.by' <<<"$ub_evt")"
assert_eq "unblocked: no item-refined for a non-refinement item" "0" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "unblocked: enabler-examined outcome is unblocked" "unblocked" "$(jq -r '.outcome' <<<"$xmn_evt")"

# ============================================================================
# unblocked on a refinement item, first pass: specified, item-refined
# recorded, label released
# ============================================================================
refine_eligible='[{"repo":"acme/widgets","item":"ISSUE-42","blocked_ts":"2026-08-01T00:00:00Z",
                   "kind":"needs-refinement","reason":"threshold"}]'
examined='[{"repo":"acme/widgets","item":"ISSUE-42","verdict":"unblocked","reason":"specified now",
            "refined_spec":"## Refined\nScope: only the parser."}]'
calls="$(run_case "unblocked: first refinement" "$refine_eligible" "$examined")"

assert_eq "refinement unblocked: one unblocked event" "1" \
  "$(grep -cE '^event unblocked ' <<<"$calls")"
assert_eq "refinement unblocked: one item-refined event" "1" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
ir_evt="$(events_named "$calls" item-refined | head -n1)"
assert_eq "refinement unblocked: item-refined carries the spec" \
  "## Refined
Scope: only the parser." "$(jq -r '.spec' <<<"$ir_evt")"
assert_contains "refinement unblocked: the projected label is released" \
  "release-refinement-label ISSUE-42 acme/widgets" "$calls"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "refinement unblocked: enabler-examined outcome is unblocked, not refinement-refused" \
  "unblocked" "$(jq -r '.outcome' <<<"$xmn_evt")"

# ============================================================================
# refinement-refused: a second refinement of an item refined once already —
# requirement 36b's thrash guard, degrading to a warning + enabler-examined
# (outcome: refinement-refused), never a second unblock
# ============================================================================
refined_eligible='[{"repo":"acme/widgets","item":"ISSUE-43","blocked_ts":"2026-08-01T00:00:00Z",
                    "kind":"needs-refinement","reason":"threshold",
                    "refined_before":{"ts":"2026-07-01T00:00:00Z"}}]'
examined='[{"repo":"acme/widgets","item":"ISSUE-43","verdict":"unblocked","reason":"re-specified again",
            "refined_spec":"## Refined again"}]'
calls="$(run_case "unblocked: refused second refinement" "$refined_eligible" "$examined")"

assert_eq "refinement-refused: no unblocked event" "0" \
  "$(grep -cE '^event unblocked ' <<<"$calls")"
assert_eq "refinement-refused: no item-refined event" "0" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
assert_eq "refinement-refused: no attempt-failed either — 36b's own shape, unlike 34d's" "0" \
  "$(grep -cE '^event attempt-failed ' <<<"$calls")"
assert_eq "refinement-refused: exactly one warning" "1" \
  "$(grep -cE '^event warning ' <<<"$calls")"
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "refinement-refused: the warning names the refusal" \
  "second refinement of acme/widgets ISSUE-43 refused" "$(jq -r '.detail' <<<"$warn_evt")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "refinement-refused: enabler-examined's outcome is exactly refinement-refused" \
  "refinement-refused" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "refinement-refused: ...carrying the human hand-off condition" \
  "A human decides whether this item's specification is adequate; the Enabler has already refined it once." \
  "$(jq -r '.unblock_condition' <<<"$xmn_evt")"
assert_not_contains "refinement-refused: the label is not released — the item is still blocked" \
  "release-refinement-label" "$calls"

# --- The exemption: issue-closed authorises exactly one more refinement ---
exempt_eligible='[{"repo":"acme/widgets","item":"ISSUE-44","blocked_ts":"2026-08-01T00:00:00Z",
                   "kind":"needs-refinement","reason":"issue-closed",
                   "refined_before":{"ts":"2026-07-01T00:00:00Z"}}]'
examined='[{"repo":"acme/widgets","item":"ISSUE-44","verdict":"unblocked","reason":"answered by the human",
            "refined_spec":"## Refined after the human answered"}]'
calls="$(run_case "unblocked: issue-closed exempts a second refinement" "$exempt_eligible" "$examined")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "issue-closed: a refined_before item is not refused when the reason is issue-closed" \
  "unblocked" "$(jq -r '.outcome' <<<"$xmn_evt")"

# ============================================================================
# still-blocked
# ============================================================================
examined='[{"repo":"acme/widgets","item":"TD001","verdict":"still-blocked","reason":"waiting on a decision",
            "unblock_condition":"needs product sign-off"}]'
calls="$(run_case "still-blocked" "$eligible" "$examined")"

assert_eq "still-blocked: no unblocked/item-void/attempt-failed/escalated event" "0" \
  "$(grep -cE '^event (unblocked|item-void|attempt-failed|escalated) ' <<<"$calls")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "still-blocked: enabler-examined outcome is still-blocked" \
  "still-blocked" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "still-blocked: the refreshed condition travels on the examined event" \
  "needs product sign-off" "$(jq -r '.unblock_condition' <<<"$xmn_evt")"

# ============================================================================
# escalate: success and a filing failure — the one outcome 36a exempts from
# ordinary examination accounting
# ============================================================================
# shellcheck disable=SC2317  # called between here and its redefinition below, via the eval'd maybe_run_enabler
create_escalation_issue() { printf '42\thttps://github.com/acme/widgets/issues/42'; return 0; }
examined='[{"repo":"acme/widgets","item":"TD001","verdict":"escalate","reason":"needs a human call",
            "issue":{"title":"Decide the retry budget","body":"Please decide the retry budget for TD001."}}]'
calls="$(run_case "escalate: filed" "$eligible" "$examined")"

assert_eq "escalate: one escalated event" "1" \
  "$(grep -cE '^event escalated ' <<<"$calls")"
esc_evt="$(events_named "$calls" escalated | head -n1)"
assert_eq "escalate: names the filed issue number" "42" "$(jq -r '.issue_number' <<<"$esc_evt")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "escalate: enabler-examined outcome is escalate" "escalate" "$(jq -r '.outcome' <<<"$xmn_evt")"

create_escalation_issue() { return 1; }
calls="$(run_case "escalate: filing failed" "$eligible" "$examined")"

assert_eq "escalation-failed: no escalated event" "0" \
  "$(grep -cE '^event escalated ' <<<"$calls")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "escalation-failed: enabler-examined outcome is escalation-failed" \
  "escalation-failed" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_not_contains "escalation-failed: is never confused with void-refused or refinement-refused" \
  "-refused" "$xmn_evt"

# ============================================================================
# An item this cycle did not claim is ignored, not acted on
# ============================================================================
examined='[{"repo":"acme/widgets","item":"TD001","verdict":"unblocked","reason":"ours"},
           {"repo":"other/repo","item":"ZZZ","verdict":"unblocked","reason":"not ours to act on"}]'
calls="$(run_case "unclaimed item ignored" "$eligible" "$examined")"

assert_eq "unclaimed: one unblocked event (the claimed item only)" "1" \
  "$(grep -cE '^event unblocked ' <<<"$calls")"
assert_eq "unclaimed: one enabler-examined event (the claimed item only)" "1" \
  "$(grep -cE '^event enabler-examined ' <<<"$calls")"
assert_contains "unclaimed: a warning names the ignored item" \
  "other/repo ZZZ" "$calls"

# ============================================================================
# A claimed item the model never mentioned stays blocked, not silently dropped
# ============================================================================
calls="$(run_case "missing verdict" "$eligible" '[]')"

assert_eq "missing verdict: no enabler-examined at all" "0" \
  "$(grep -cE '^event enabler-examined ' <<<"$calls")"
assert_contains "missing verdict: a warning names the claimed-but-unanswered item" \
  "no verdict for claimed item acme/widgets TD001" "$calls"

# ============================================================================
# The argv cap (requirement 4g, TD-PPagop-26081401): the claim accumulator
# ============================================================================
# The claim loop's own `claimed_json="$(jq -c --argjson e "$entry" ...)"`
# used to deliver each blocked item's evidence payload as a second --argjson,
# an argv entry capped at MAX_ARG_STRLEN. A 150000-byte block reason (padding
# past a human ever writes, but nothing in this system bounds one) proves the
# fold now survives it — not a crash, not a silently dropped claim.
printf 'x%.0s' $(seq 1 150000) > "$tmp_dir/big_reason.txt"
eligible_big="$(jq -nc --rawfile r "$tmp_dir/big_reason.txt" \
  '[{"repo":"acme/widgets","item":"TDBIG","blocked_ts":"2026-08-01T00:00:00Z","kind":"","reason":$r}]')"
assert_eq "the oversized blocked-item fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$eligible_big" | wc -c) > 131072 ))"
examined_big='[{"repo":"acme/widgets","item":"TDBIG","verdict":"void","reason":"already fixed upstream",
                "evidence":"The failing script was deleted in an earlier change and its only caller removed."}]'
calls="$(run_case "argv cap: oversized blocked-item reason" "$eligible_big" "$examined_big")"
assert_eq "the oversized claim still reaches the claim fold: exactly one item-void event" "1" \
  "$(grep -cE '^event item-void ' <<<"$calls")"
void_evt="$(events_named "$calls" item-void | head -n1)"
assert_eq "  ... naming the oversized item, not dropped or corrupted" "TDBIG" "$(jq -r '.item' <<<"$void_evt")"

# ============================================================================
# The argv cap (requirement 4g, TD-PPagop-26081401): the unparseable-verdict warning
# ============================================================================
# `items_named_json` — every claimed item trimmed to {repo, item} — used to
# ride into the "no verdicts recorded" warning as a second --argjson. Ordinary
# blocked items are not capped per engagement (requirement 35d — only the
# refinement class is), so 50 claimed items with a heavily padded item ref
# prove the warning still carries every one of them, past the cap, when the
# stage itself fails outright.
pad_ref="$(printf 'x%.0s' $(seq 1 2700))"
eligible_many="$(jq -nc --arg p "$pad_ref" \
  '[range(1; 51) | {repo: "acme/widgets", item: ("TD-" + $p + "-" + (. | tostring)),
    blocked_ts: "2026-08-01T00:00:00Z", kind: "", reason: "threshold"}]')"
STUB_RUN_RC=3
calls="$(run_case "non-zero stage exit, oversized claim set" "$eligible_many" '[]')"
STUB_RUN_RC=0
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_eq "the oversized items_named_json fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(jq -c '.items' <<<"$warn_evt" | wc -c) > 131072 ))"
assert_eq "the warning still carries every one of the 50 claimed items" \
  "50" "$(jq '.items | length' <<<"$warn_evt")"
assert_eq "  ... and no enabler-examined/item-void/unblocked/attempt-failed at all" "0" \
  "$(grep -cE '^event (enabler-examined|item-void|unblocked|attempt-failed) ' <<<"$calls")"

# ============================================================================
# complete_handoff (requirements 31c/32b, agent-ops#440): refused when this
# item's recorded failure never reached the Reviewer stage — no Reviewer
# verdict is on record for the pull request at all, so nothing has confirmed
# it is even safe to hand off, let alone that CI is green (PR #433: the
# Implementor failed, the Reviewer block never ran, and complete_handoff
# flipped it to ready anyway on four preconditions that were all vacuously
# true for want of a Reviewer having ever examined it).
# ============================================================================
pr_eligible_no_reviewer='[{"repo":"acme/widgets","item":"PR433","blocked_ts":"2026-08-01T00:00:00Z","kind":"",
                           "reason":"threshold","stage":"implementor","pr_url":"https://github.com/acme/widgets/pull/433"}]'
examined='[{"repo":"acme/widgets","item":"PR433","verdict":"unblocked","reason":"the Implementor bug is fixed now",
            "complete_handoff":true}]'
calls="$(run_case "complete_handoff: stage never reached Reviewer" "$pr_eligible_no_reviewer" "$examined")"

assert_eq "no-reviewer: the unblock itself still stands" "1" \
  "$(grep -cE '^event unblocked ' <<<"$calls")"
assert_eq "no-reviewer: no pr-ready — nothing was flipped" "0" \
  "$(grep -cE '^event pr-ready ' <<<"$calls")"
assert_eq "no-reviewer: exactly one warning" "1" \
  "$(grep -cE '^event warning ' <<<"$calls")"
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "no-reviewer: the warning names the pull request" \
  "https://github.com/acme/widgets/pull/433" "$(jq -r '.pr_url' <<<"$warn_evt")"
assert_contains "no-reviewer: ...and says which stage the failure actually reached" \
  "never reached the Reviewer stage (stage: implementor)" "$(jq -r '.detail' <<<"$warn_evt")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "no-reviewer: enabler-examined records the refusal, not a flip word" \
  "refused-no-reviewer" "$(jq -r '.complete_handoff' <<<"$xmn_evt")"

# A block with no `stage` at all (an escalation, or a legacy record) reads
# exactly the same as any other non-Reviewer stage — never "reviewer" by
# accident.
pr_eligible_blank_stage='[{"repo":"acme/widgets","item":"PR434","blocked_ts":"2026-08-01T00:00:00Z","kind":"",
                           "reason":"threshold","pr_url":"https://github.com/acme/widgets/pull/434"}]'
examined='[{"repo":"acme/widgets","item":"PR434","verdict":"unblocked","reason":"cleared",
            "complete_handoff":true}]'
calls="$(run_case "complete_handoff: no stage recorded at all" "$pr_eligible_blank_stage" "$examined")"
assert_eq "blank stage: still refused, not treated as reviewer" "0" \
  "$(grep -cE '^event pr-ready ' <<<"$calls")"
warn_evt="$(events_named "$calls" warning | head -n1)"
assert_contains "blank stage: the warning names it as none" \
  "stage: none" "$(jq -r '.detail' <<<"$warn_evt")"

# ============================================================================
# complete_handoff: the item's failure did reach the Reviewer, but
# handoff_complete_review's own gate refuses the flip — the same gate the
# Reviewer's own handoff runs, genuinely shared rather than skipped on this
# recovery path.
# ============================================================================
pr_eligible_reviewer='[{"repo":"acme/widgets","item":"PR435","blocked_ts":"2026-08-01T00:00:00Z","kind":"",
                        "reason":"threshold","stage":"reviewer","pr_url":"https://github.com/acme/widgets/pull/435"}]'
examined='[{"repo":"acme/widgets","item":"PR435","verdict":"unblocked","reason":"the Reviewer stall is cleared",
            "complete_handoff":true}]'

# shellcheck disable=SC2317  # invoked only by the eval'd maybe_run_enabler
handoff_complete_review() {
  jq -nc '{safe: false,
           gate: {word: "dirty", reason: "required check(s) not green: CI", checks_unreadable: false},
           closing_keyword: {word: "", reason: ""}, handoff: "",
           rereview: {state: "", who: ""}, human_reviewer: {state: "", who: ""}}'
}
calls="$(run_case "complete_handoff: gate refuses the flip" "$pr_eligible_reviewer" "$examined")"

assert_eq "gate-refused: the unblock itself still stands" "1" \
  "$(grep -cE '^event unblocked ' <<<"$calls")"
assert_eq "gate-refused: no pr-ready — the gate found a real fault" "0" \
  "$(grep -cE '^event pr-ready ' <<<"$calls")"
assert_eq "gate-refused: exactly one review-gate-checks-read bookkeeping event" "1" \
  "$(grep -cE '^event review-gate-checks-read ' <<<"$calls")"
assert_eq "  ... recording a successful required-checks read" \
  "true" "$(jq -r '.ok' <<<"$(events_named "$calls" review-gate-checks-read | head -n1)")"
warn_evt="$(grep -E '^event warning ' <<<"$calls" | tail -n1 | sed -E 's/^event warning //')"
assert_contains "gate-refused: the warning names the gate's own finding" \
  "required check(s) not green: CI" "$(jq -r '.detail' <<<"$warn_evt")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "gate-refused: enabler-examined records the flip as failed" \
  "failed" "$(jq -r '.complete_handoff' <<<"$xmn_evt")"

# --- The clean path: a Reviewer verdict is on record, and the gate is clean ---
# shellcheck disable=SC2317  # invoked only by the eval'd maybe_run_enabler
handoff_complete_review() {
  jq -nc '{safe: true,
           gate: {word: "clean", reason: "", checks_unreadable: false},
           closing_keyword: {word: "clean", reason: ""}, handoff: "flipped",
           rereview: {state: "none", who: ""}, human_reviewer: {state: "skip", who: ""}}'
}
calls="$(run_case "complete_handoff: gate clean, flip completes" "$pr_eligible_reviewer" "$examined")"

assert_eq "gate-clean: exactly one pr-ready" "1" \
  "$(grep -cE '^event pr-ready ' <<<"$calls")"
pr_evt="$(events_named "$calls" pr-ready | head -n1)"
assert_eq "  ... naming the pull request" "https://github.com/acme/widgets/pull/435" "$(jq -r '.pr_url' <<<"$pr_evt")"
assert_eq "  ... crediting the handoff to the enabler" "enabler" "$(jq -r '.handoff' <<<"$pr_evt")"
assert_eq "  ... carrying the flip's own state" "flipped" "$(jq -r '.state' <<<"$pr_evt")"
xmn_evt="$(events_named "$calls" enabler-examined | head -n1)"
assert_eq "gate-clean: enabler-examined records the flip word" \
  "flipped" "$(jq -r '.complete_handoff' <<<"$xmn_evt")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
