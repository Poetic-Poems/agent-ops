#!/usr/bin/env bash
#
# test/stage-salvage.test.sh — the bounded salvage resume of issue #237:
# before an engagement whose final message failed extract_json_result is
# discarded, the runner asks the *same* session, once, for nothing but the
# verdict object.
#
# What this guards: a stage that ends with a background task still pending
# ("I'll check back shortly") or any other shape extract_json_result cannot
# parse used to be discarded whole — the work it already did, gone, and its
# claims frozen behind it. stage_salvage_result (agent-cycle.sh) is the
# recovery: resume the same `claude` session named by the original run's
# `session_id` with a minimal continuation prompt, and re-parse. These cases
# pin that it recovers a verdict the resume produces, refuses to fabricate
# one the resume still doesn't, and never spends a resume on a run that left
# no session behind at all.
#
# `claude` is a stub on PATH — no network, no model, no cost. The function
# under test is lifted from agent-cycle.sh itself (as
# test/extract-json-result.test.sh already does), so this cannot pass against
# a copy the script has since moved on from.
#
# Run directly: ./test/stage-salvage.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- Stub `claude`: always answers a --resume with $RESUME_RESPONSE's lines,
#     and would answer a fresh (non-resume) invocation with $FRESH_RESPONSE's
#     — the function under test never issues one, so no case here needs it. ---
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
saw_resume=0
for a in "$@"; do [[ "$a" == "--resume" ]] && saw_resume=1; done
if (( saw_resume )); then
  cat "$RESUME_RESPONSE"
else
  cat "${FRESH_RESPONSE:-/dev/null}"
fi
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

# --- Lift the function under test and its two constants from agent-cycle.sh ---
lift_bash_fn() {
  awk -v name="$2" '
    $0 == name "() {" { on = 1 }
    on               { print }
    on && /^\}$/      { exit }
  ' "$1"
}
extract_fn="$(lift_bash_fn "$SCRIPT_DIR/lib/stage-attempt.sh" extract_json_result)"
salvage_fn="$(lift_bash_fn "$SCRIPT_DIR/lib/stage-attempt.sh" stage_salvage_result)"
salvage_consts="$(grep -E '^stage_salvage_(backstop|inactivity)_sec=' "$SCRIPT_DIR/lib/stage-attempt.sh")"
if [[ -z "$extract_fn" || -z "$salvage_fn" || -z "$salvage_consts" ]]; then
  echo "FAIL - could not lift extract_json_result/stage_salvage_result from lib/stage-attempt.sh"
  exit 1
fi

events_log="$tmp_dir/events.jsonl"

# The harness every case shares: lib/stage-run.sh for the real run_claude_stage,
# the two lifted functions, and a log_event stub that records outcomes instead
# of writing the pipeline's real log.
harness="
. '$SCRIPT_DIR/lib/stage-run.sh'
$salvage_consts
$extract_fn
$salvage_fn
log_event() { local event=\"\$1\" fields=\"\${2:-{\}}\"; printf '%s\t%s\n' \"\$event\" \"\$fields\" >> '$events_log'; }
"

run_case() {  # run_case RESUME_RESPONSE_LINES ORIGINAL_SESSION_ID  -> stdout is stage_salvage_result's
  local resume_lines="$1" session_id="$2"
  local out_file="$tmp_dir/case.out" resume_response="$tmp_dir/resume-response.jsonl"
  : > "$events_log"
  printf '%s' "$resume_lines" > "$resume_response"
  jq -nc --arg sid "$session_id" 'if $sid == "" then {result: "unparseable prose"} else {result: "unparseable prose", session_id: $sid} end' \
    > "$out_file"
  bash -c "
    $harness
    export RESUME_RESPONSE='$resume_response'
    stage_salvage_result test-stage '$out_file' test-model '$tmp_dir'
  "
}

# --- A resume that produces a parseable verdict is recovered -----------------------
result_line='{"type":"result","subtype":"success","is_error":false,"result":"{\"status\":\"complete\"}","session_id":"s1"}'
out="$(run_case "$result_line"$'\n' "s1")"
rc=$?
assert_eq "a parseable resume is recovered — exit status" "0" "$rc"
assert_eq "a parseable resume is recovered — the verdict itself" '{"status":"complete"}' "$out"
assert_eq "a recovered salvage logs its outcome" "1" \
  "$(grep -c $'^salvage\t.*"outcome":"recovered"' "$events_log")"

# --- A resume that still produces nothing parseable is not fabricated --------------
still_prose_line='{"type":"result","subtype":"success","is_error":false,"result":"I will check back shortly.","session_id":"s1"}'
out="$(run_case "$still_prose_line"$'\n' "s1")"
rc=$?
assert_eq "a resume that stays unparseable fails closed — exit status" "1" "$rc"
assert_eq "…and prints nothing" "" "$out"
assert_eq "a failed salvage logs its outcome" "1" \
  "$(grep -c $'^salvage\t.*"outcome":"failed"' "$events_log")"

# --- A run that left no session_id is never resumed ---------------------------------
: > "$events_log"
out_file="$tmp_dir/no-session.out"
printf '%s' '{"result": "unparseable prose"}' > "$out_file"
out="$(bash -c "
  $harness
  export RESUME_RESPONSE=/dev/null
  stage_salvage_result test-stage '$out_file' test-model '$tmp_dir'
")"
rc=$?
assert_eq "no session_id — no salvage is attempted — exit status" "1" "$rc"
assert_eq "…and nothing is logged (the caller never had a session to spend)" "0" "$(wc -l < "$events_log")"

# --- A bare-fenced verdict (issue #237's other shape) is recovered without salvage --
# stage_salvage_result is a fallback, not the primary fix: extract_json_result
# alone must already recover a fence with no `json` info string.
out="$(bash -c "$extract_fn"$'\nextract_json_result "$1"' bash \
  $'Here is my verdict.\n```\n{"verdict": "unblocked"}\n```')"
assert_eq "a bare fence is recovered by extract_json_result directly, no salvage needed" \
  '{"verdict":"unblocked"}' "$out"

# --------------------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
