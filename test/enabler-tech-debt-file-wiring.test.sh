#!/usr/bin/env bash
#
# test/enabler-tech-debt-file-wiring.test.sh — regression test for the
# file_debt/file_issue handling `maybe_run_enabler` adds in agent-cycle.sh
# (agent-ops#631): an Enabler verdict may carry either field, alongside any
# of the four verdicts, asking the Script to file a tech-debt record or a
# plain GitHub issue on its behalf — the Enabler itself must never write to
# GitHub or a branch (prompts/enabler.md).
#
# This file complements test/enabler-verdicts.test.sh (the four-verdict
# switch itself, untouched by this feature) and test/tech-debt-file.test.sh
# (lib/tech-debt-file.sh's own filing logic, exercised for real against a
# fixture git remote). What this file proves is narrower: that
# `maybe_run_enabler` actually calls `techdebt_file_debt`/`techdebt_file_issue`
# with the right arguments, logs the right event on success, warns instead of
# silently dropping a malformed or failed request, and that neither field is
# gated by which verdict carried it — the same lift-with-awk technique
# test/enabler-verdicts.test.sh uses, with `techdebt_file_debt`/
# `techdebt_file_issue` stubbed as simple recorders (the same role
# `create_escalation_issue` plays there) rather than wired for real.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/enabler-tech-debt-file-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"

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

extract_fn() {
  local start_pat="$1" file="$2"
  awk -v start="$start_pat" '
    $0 == start { on = 1 }
    on          { print }
    on && /^}$/ { exit }
  ' "$file"
}

maybe_run_enabler_fn="$(extract_fn 'maybe_run_enabler() {' "$SCRIPT_DIR/lib/enabler.sh")"
enabler_claim_key_fn="$(extract_fn 'enabler_claim_key() {' "$SCRIPT_DIR/lib/enabler.sh")"
extract_json_result_fn="$(extract_fn 'extract_json_result() {' "$SCRIPT_DIR/lib/stage-attempt.sh")"
review_gate_escalate_unreadable_streak_fn="$(extract_fn 'review_gate_escalate_unreadable_streak() {' "$SCRIPT_DIR/lib/review-gate.sh")"
escalation_autonomy_pass_available_fn="$(extract_fn 'escalation_autonomy_pass_available() {' "$SCRIPT_DIR/lib/enabler.sh")"

for pair in \
  'maybe_run_enabler_fn:enabler-examined' \
  'enabler_claim_key_fn:__verify' \
  'extract_json_result_fn:awk' \
  'review_gate_escalate_unreadable_streak_fn:streak_json' \
  'escalation_autonomy_pass_available_fn:escalation_autonomy_adjudicated_before'; do
  name="${pair%%:*}" needle="${pair##*:}"
  val="${!name}"
  if [[ "$val" != *"$needle"* ]]; then
    printf 'FAIL - %s could not be found in agent-cycle.sh (renamed or moved?)\n' "$name"
    exit 1
  fi
done
if [[ "$maybe_run_enabler_fn" != *"file_debt"* || "$maybe_run_enabler_fn" != *"file_issue"* ]]; then
  printf 'FAIL - maybe_run_enabler no longer mentions file_debt/file_issue (agent-ops#631 wiring removed?)\n'
  exit 1
fi

eval "$extract_json_result_fn"
eval "$enabler_claim_key_fn"
eval "$review_gate_escalate_unreadable_streak_fn"
eval "$escalation_autonomy_pass_available_fn"
eval "$maybe_run_enabler_fn"

fake_root="$tmp_dir/fake-root"
mkdir -p "$fake_root/lib" "$fake_root/prompts"
cat > "$fake_root/lib/claim.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$fake_root/lib/claim.sh"
: > "$fake_root/prompts/enabler.md"

# Every function below this point is invoked only from inside the eval'd
# maybe_run_enabler (or its own eval'd callees) — invisible to shellcheck's
# reachability analysis, hence SC2317 on each.
calls_log=""
# shellcheck disable=SC2317
record() { printf '%s\n' "$*" >> "$calls_log"; }

# shellcheck disable=SC2317
log_event() { record "event $1 $2"; }
# shellcheck disable=SC2317
stage_prompt_text() { printf 'stub prompt'; }
# shellcheck disable=SC2317
stage_budget_apply() { :; }
# shellcheck disable=SC2317
metering_fields() { printf '{}'; }
# shellcheck disable=SC2317
stage_watchdog_warning() { printf ''; }
# shellcheck disable=SC2317
fleet_limit_resume_at() { printf ''; }
# shellcheck disable=SC2317
release_refinement_label() { record "release-refinement-label $1 $2"; }
# shellcheck disable=SC2317
void_obsolete_ctx_json() { printf '{}'; }
# shellcheck disable=SC2317
handoff_complete_review() { echo "FAIL - unexpected handoff_complete_review call" >&2; exit 98; }
# shellcheck disable=SC2317
run_enabler_adjudication() { echo "FAIL - unexpected run_enabler_adjudication call" >&2; exit 97; }
# shellcheck disable=SC2317
create_escalation_issue() { echo "FAIL - unexpected create_escalation_issue call" >&2; return 1; }

# techdebt_file_debt/techdebt_file_issue: recorders, overridden per scenario
# below when a scenario needs a specific return value; the defaults record
# the call and succeed with a canned id/url, which is what most scenarios
# want.
# shellcheck disable=SC2317
techdebt_file_debt() {
  record "techdebt_file_debt $*"
  [[ "${STUB_FILE_DEBT_RC:-0}" -eq 0 ]] || return 1
  printf 'TD-PPtest-99999901\thttps://github.com/acme/widgets/pull/501'
}
# shellcheck disable=SC2317
techdebt_file_issue() {
  record "techdebt_file_issue $*"
  [[ "${STUB_FILE_ISSUE_RC:-0}" -eq 0 ]] || return 1
  printf '55\thttps://github.com/acme/widgets/issues/55'
}

mkdir -p "$fake_root/prompts"
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
DEFAULTED_CONFIG='{}'
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
cycle_started_at="2026-08-17T00:00:00Z"
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
# shellcheck disable=SC2034
log_file="$state_dir/log.jsonl"
: > "$log_file"
# shellcheck disable=SC2034
review_gate_unknown_streak_after=3
# shellcheck disable=SC2317
review_gate_unknown_streak_verdict() { cat >/dev/null; printf ''; }
# shellcheck disable=SC2317
review_gate_degraded_since() { cat >/dev/null; return 1; }

# shellcheck disable=SC2317  # invoked only by the eval'd maybe_run_enabler
run_claude_stage() {
  local out_file="$5"
  jq -nc --argjson env "$STUB_EXAMINED_JSON" '{result: ($env | tostring), session_id: "stub-session"}' \
    > "$out_file"
  # shellcheck disable=SC2034
  stage_gaps_json="null"
  # shellcheck disable=SC2034
  stage_kill_reason=""
  return "${STUB_RUN_RC:-0}"
}

# run_case DESC EXAMINED_JSON [FILE_DEBT_RC] [FILE_ISSUE_RC]
run_case() {
  local desc="$1" examined_json="$2"
  STUB_FILE_DEBT_RC="${3:-0}"
  STUB_FILE_ISSUE_RC="${4:-0}"
  cycle_dir="$(mktemp -d)"
  calls_log="$cycle_dir/calls.log"
  : > "$calls_log"
  # shellcheck disable=SC2034
  enabler_eligible_json='[{"repo":"acme/widgets","item":"TD26082201","reason":"threshold","blocked_ts":"2026-08-16T00:00:00Z","stage":"implementer","detail":"d","unblock_condition":"u"}]'
  STUB_EXAMINED_JSON="$(jq -nc --argjson e "$examined_json" '{examined: $e}')"
  maybe_run_enabler 0 >/dev/null 2>&1
  cat "$calls_log"
}

events_named() { grep -E "^event $2 " <<<"$1" | sed -E "s/^event $2 //"; }

still_blocked_verdict() {  # still_blocked_verdict FILE_DEBT_JSON|null FILE_ISSUE_JSON|null
  jq -nc --argjson fd "$1" --argjson iss "$2" \
    '[{repo:"acme/widgets", item:"TD26082201", verdict:"still-blocked",
       reason:"still stuck", unblock_condition:"needs X"}
      + (if $fd == null then {} else {file_debt: $fd} end)
      + (if $iss == null then {} else {file_issue: $iss} end)]'
}

# --- file_debt: success ------------------------------------------------------
fd='{"title":"A gap worth filing","body":"The body text."}'
out="$(run_case "file_debt success" "$(still_blocked_verdict "$fd" null)")"
assert_eq "file_debt success: techdebt_file_debt called once" "1" \
  "$(grep -c '^techdebt_file_debt ' <<<"$out")"
assert_eq "  ... with the repo, title, body and provenance" "1" \
  "$(grep -c 'techdebt_file_debt acme/widgets A gap worth filing The body text' <<<"$out")"
assert_eq "  ... tech-debt-filed event logged" "1" "$(events_named "$out" tech-debt-filed | grep -c .)"
fields="$(events_named "$out" tech-debt-filed)"
assert_eq "  ... event names by:enabler" "enabler" "$(jq -r '.by' <<<"$fields")"
assert_eq "  ... event carries the returned id" "TD-PPtest-99999901" "$(jq -r '.id' <<<"$fields")"
assert_eq "  ... no warning" "0" "$(events_named "$out" warning | grep -c .)"

# --- file_debt: missing title/body -> warning, no call ----------------------
fd_bad='{"title":"","body":""}'
out="$(run_case "file_debt missing fields" "$(still_blocked_verdict "$fd_bad" null)")"
assert_eq "file_debt missing fields: no call made" "0" "$(grep -c '^techdebt_file_debt ' <<<"$out")"
assert_eq "  ... a warning was logged" "1" "$(events_named "$out" warning | grep -c .)"

# --- file_debt: the call itself fails -> warning -----------------------------
out="$(run_case "file_debt call fails" "$(still_blocked_verdict "$fd" null)" 1)"
assert_eq "file_debt call fails: still attempted" "1" "$(grep -c '^techdebt_file_debt ' <<<"$out")"
assert_eq "  ... no tech-debt-filed event" "0" "$(events_named "$out" tech-debt-filed | grep -c .)"
assert_eq "  ... a warning was logged instead" "1" "$(events_named "$out" warning | grep -c .)"

# --- file_issue: success ------------------------------------------------------
fi='{"title":"A question worth asking","body":"Body of the issue."}'
out="$(run_case "file_issue success" "$(still_blocked_verdict null "$fi")")"
assert_eq "file_issue success: techdebt_file_issue called once" "1" \
  "$(grep -c '^techdebt_file_issue ' <<<"$out")"
assert_eq "  ... with the repo, item ref and title" "1" \
  "$(grep -c 'techdebt_file_issue acme/widgets TD26082201 A question worth asking' <<<"$out")"
assert_eq "  ... issue-filed event logged" "1" "$(events_named "$out" issue-filed | grep -c .)"
fields="$(events_named "$out" issue-filed)"
assert_eq "  ... event names by:enabler" "enabler" "$(jq -r '.by' <<<"$fields")"
assert_eq "  ... event carries the returned issue number" "55" "$(jq -r '.issue_number' <<<"$fields")"

# --- file_issue: missing body -> warning, no call ----------------------------
fi_bad='{"title":"A question","body":""}'
out="$(run_case "file_issue missing body" "$(still_blocked_verdict null "$fi_bad")")"
assert_eq "file_issue missing body: no call made" "0" "$(grep -c '^techdebt_file_issue ' <<<"$out")"
assert_eq "  ... a warning was logged" "1" "$(events_named "$out" warning | grep -c .)"

# --- file_issue: the call itself fails -> warning ----------------------------
out="$(run_case "file_issue call fails" "$(still_blocked_verdict null "$fi")" 0 1)"
assert_eq "file_issue call fails: still attempted" "1" "$(grep -c '^techdebt_file_issue ' <<<"$out")"
assert_eq "  ... no issue-filed event" "0" "$(events_named "$out" issue-filed | grep -c .)"
assert_eq "  ... a warning was logged instead" "1" "$(events_named "$out" warning | grep -c .)"

# --- Neither field set -> no filing calls, no extra warnings ----------------
out="$(run_case "neither field" "$(still_blocked_verdict null null)")"
assert_eq "neither field: no techdebt_file_debt call" "0" "$(grep -c '^techdebt_file_debt ' <<<"$out")"
assert_eq "  ... no techdebt_file_issue call" "0" "$(grep -c '^techdebt_file_issue ' <<<"$out")"
assert_eq "  ... no warning" "0" "$(events_named "$out" warning | grep -c .)"

# --- Orthogonal to verdict: an `unblocked` item still files ------------------
unblocked_with_debt="$(jq -nc --argjson fd "$fd" \
  '[{repo:"acme/widgets", item:"TD26082201", verdict:"unblocked",
     reason:"the block lifted", file_debt:$fd}]')"
out="$(run_case "unblocked + file_debt" "$unblocked_with_debt")"
assert_eq "unblocked verdict: the unblocked event still fires" "1" \
  "$(events_named "$out" unblocked | grep -c .)"
assert_eq "  ... and file_debt still files, independent of the verdict" "1" \
  "$(grep -c '^techdebt_file_debt ' <<<"$out")"
assert_eq "  ... tech-debt-filed event logged alongside it" "1" \
  "$(events_named "$out" tech-debt-filed | grep -c .)"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$failures test(s) failed."
  exit 1
fi
