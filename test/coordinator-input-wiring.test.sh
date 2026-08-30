#!/usr/bin/env bash
#
# test/coordinator-input-wiring.test.sh — regression test for requirement 4i's
# block in agent-cycle.sh (agent-ops#641): not whether the ladder is right
# (`test/coordinator-input.test.sh` covers that) but whether the Script hands
# it the right allowance and does the right things with what comes back.
#
# The seam is the whole point here. The bound is only worth what its arithmetic
# is worth: subtract too little and the assembled prompt still overflows, which
# is the outage; subtract too much and the fit trims prose nobody needed to
# lose. And the block has two side effects the union log depends on — an
# informational `coordinator-input-fitted` when it trimmed, and a `warning`
# when even the last rung could not fit — either of which could be dropped by
# an edit without a single assertion elsewhere noticing.
#
# So the assertions here are about what the block computes and emits:
#
#   - **The allowance is the configured maximum less everything the fit cannot
#     shed.** Measured, end to end, by reassembling the real prompt around the
#     block's own output and checking it against `coordinator_prompt_max_bytes`.
#   - **The overhead is taken against an empty `repos`.** An overhead measured
#     against the unfitted array would shrink the allowance as the fit worked,
#     because the two differ by the indentation of the lines the fit removes.
#   - **`0` means the bound is off, and the input passes through untouched.**
#   - **Trimming is recorded; failing to fit is recorded louder.**
#
# The block is lifted verbatim out of agent-cycle.sh, the way
# test/backpressure-wiring.test.sh lifts its own, so the assertions are about
# the shipped code rather than a copy of its logic.
#
# No network and no `claude`: the block reads config variables and JSON this
# test sets, and `log_event`/`guard_warn` are stubs that record their arguments.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
# ./test/coordinator-input-wiring.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/agent-cycle.sh"

# shellcheck source=lib/coordinator-input.sh
. "$SCRIPT_DIR/lib/coordinator-input.sh"
# shellcheck source=lib/coordinator-brief.sh
. "$SCRIPT_DIR/lib/coordinator-brief.sh"

failures=0
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}
assert_true() { assert_eq "$1" "true" "$2"; }
# For `$(( ... ))` conditions, which answer 1/0 rather than true/false.
assert_ok() { assert_eq "$1" "1" "$2"; }

# --- Extraction ---------------------------------------------------------------

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

fit_block="$(extract_block '^coordinator_fit_allowance=0$' "^# --- end of requirement 4i's fit ---\$" "$AGENT_CYCLE")"
if [[ -z "$fit_block" || "$fit_block" != *'coordinator_fit_bands'* ]]; then
  echo "FAIL - could not extract requirement 4i's fit block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# The prompt the block renders is built one line above the block itself; lift
# that too rather than restating it, so a change to the substitution is caught
# here instead of silently making this test measure something else.
prompt_block="$(extract_block '^coordinator_base_prompt="\$\(stage_prompt_text' '^coordinator_base_prompt="\$\{coordinator_base_prompt' "$AGENT_CYCLE")"
if [[ -z "$prompt_block" ]]; then
  echo "FAIL - could not extract the base-prompt render from agent-cycle.sh" >&2
  exit 1
fi

# And so is the assembly the block's allowance has to predict. If the fenced
# scaffolding ever changes shape, the block's own `coordinator_fit_scaffold_
# bytes` must change with it, and this is what notices.
# shellcheck disable=SC2016  # The anchors are awk regexes matching agent-cycle.sh's own text, not expansions for this shell.
assembly_block="$(extract_block '^coordinator_prompt="\$coordinator_base_prompt$' '^"$' "$AGENT_CYCLE")"
if [[ -z "$assembly_block" || "$assembly_block" != *'Runtime input for this cycle'* ]]; then
  echo "FAIL - could not extract the prompt assembly from agent-cycle.sh" >&2
  exit 1
fi

# The fit's own exemption-set gate (requirement 34e's fourth refusal and
# requirement 3x's matching exemption, agent-ops#683) — lifted separately from
# `fit_block` above because it is its own block in agent-cycle.sh, downstream
# of "end of requirement 4i's fit". Regression coverage for agent-ops#933: this
# gate used to read `coordinator_fit_report_json` through a bash default that
# silently corrupted every non-empty report, so it always read as "fit did not
# run" and this block's `if` never took its true branch on a real cycle.
trim_block="$(extract_block '^coordinator_fit_trimmed_json="\[\]"$' "^# --- 3b\\. No-op short-circuit" "$AGENT_CYCLE")"
if [[ -z "$trim_block" || "$trim_block" != *'coordinator_fit_trimmed_items'* ]]; then
  echo "FAIL - could not extract the fit-trim exemption block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# `coordinator_eligible_items`/`coordinator_unassessable_items` (requirement
# 3x) live in lib/candidate-select.sh, lifted the way test/fit-trim-block-
# refusal.test.sh already lifts functions from that file, so this test
# exercises the same 3x accounting a real cycle would.
eligible_items_fn="$(extract_block '^coordinator_eligible_items\(\) \{' '^\}$' "$SCRIPT_DIR/lib/candidate-select.sh")"
unassessable_items_fn="$(extract_block '^coordinator_unassessable_items\(\) \{' '^\}$' "$SCRIPT_DIR/lib/candidate-select.sh")"
if [[ -z "$eligible_items_fn" || -z "$unassessable_items_fn" ]]; then
  echo "FAIL - could not extract coordinator_eligible_items/coordinator_unassessable_items from lib/candidate-select.sh" >&2
  exit 1
fi
eval "$eligible_items_fn"
eval "$unassessable_items_fn"

# --- Fixtures -----------------------------------------------------------------

PROMPTS_DIR="$tmp_dir/prompts"
mkdir -p "$PROMPTS_DIR"
state_dir="$tmp_dir/state"
mkdir -p "$state_dir"
# A base prompt big enough to matter to the arithmetic — the real one is over
# 100 KB, and a bound that ignored it is exactly the mistake requirement 4i
# exists to avoid.
{ printf '# Co-Ordinator\n\n@@WORK_SOURCES_TABLE@@\n\n'
  for _ in $(seq 1 900); do
    printf 'Some instruction text that stands in for the real prompt body.\n'
  done
} > "$PROMPTS_DIR/coordinator.md"

# shellcheck disable=SC2034  # Read by the lifted base-prompt render, through stage_prompt_text's real signature.
prompt_overrides_json='{}'
all_repos_json='[{"slug": "o/r", "sources": ["issues"]}]'
implementer_model_default="claude-sonnet-5"
implementer_model_trivial="claude-haiku-4-5-20251001"
pr_label="autonomous-agent"
candidates_max=3
refinement_policy_json='{}'
# shellcheck disable=SC2034  # Read by the lifted fit block, which assigns coordinator_refinements_json from it.
refinements_json='{}'
claimed_json='[]'
blocked_json='[]'

# The two functions the block calls that live elsewhere in agent-cycle.sh.
# `coordinator_blocked_view` is lifted rather than stubbed: it decides how many
# bytes `blocked` contributes to the overhead, which is part of what is being
# measured.
eval "$(extract_block '^coordinator_blocked_view\(\) \{' '^\}$' "$SCRIPT_DIR/lib/candidate-select.sh")"
# And requirement 4j's view of `refinements`, lifted for the same reason: it
# decides how many bytes that band contributes to the overhead, which on the
# outage it was written for was more than every other unsheddable term put
# together.
eval "$(extract_block '^coordinator_refinements_view\(\) \{' '^\}$' "$SCRIPT_DIR/lib/candidate-select.sh")"
# shellcheck disable=SC2317  # Called from the lifted base-prompt render below.
stage_prompt_text() { cat "$PROMPTS_DIR/coordinator.md"; }

events="$tmp_dir/events"
: > "$events"
# shellcheck disable=SC2317  # Called from the lifted block, on each of its three logging paths.
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$events"; }
# shellcheck disable=SC2317  # Called from the lifted block, on its own jq-failure guard path.
guard_warn() { printf 'guard\t%s\t%s\n' "$1" "$2" >> "$events"; }

mk_repos() {  # <num> <body-bytes> <ncomments> <comment-bytes>
  python3 -c '
import json, sys
n, b, c, cb = (int(x) for x in sys.argv[1:5])
issues = [{
  "source": "issues", "ref": str(i), "number": i,
  "url": "https://github.com/o/r/issues/%d" % i, "title": "issue %d" % i,
  "priority": ["Low", "Medium", "High", "Urgent"][i % 4],
  "updated_at": "2026-08-%02dT00:00:00Z" % (i % 28 + 1),
  "body": "B" * b,
  "comments": [{"author": "a", "created_at": "2026-08-01T00:00:00Z",
                "body": "C" * cb} for _ in range(c)],
} for i in range(1, n + 1)]
print(json.dumps([{"slug": "o/r", "sources": ["issues"], "issues": issues, "tech_debt": []}]))
' "$@"
}

# Run the extracted block over one input, then reassemble the real prompt the
# way "4. Co-Ordinator stage" does and report its size. Everything the block
# reads is a variable in this scope, exactly as it is in agent-cycle.sh.
run_fit() {  # <max-bytes> <repos-json>  -> assembled prompt size on stdout
  coordinator_prompt_max_bytes="$1"
  ordered_repos_json="$2"
  : > "$events"
  coordinator_sources_table="$(coordinator_work_sources_table "$all_repos_json")"
  eval "$prompt_block"
  eval "$fit_block"
  # `coordinator_refinements_json` is assigned by the lifted fit block above,
  # not here: requirement 4j has the measurement and the assembly spend the
  # same value, and a test that recomputed it would not be able to tell.
  # shellcheck disable=SC2154  # Assigned by the lifted fit block eval'd above — spending its value is the point.
  coordinator_stdin="$(printf '%s\n' \
    "$ordered_repos_json" "$(coordinator_blocked_view "$blocked_json")" \
    "$coordinator_refinements_json" "$claimed_json")"
  # shellcheck disable=SC2034  # Assembled here only to be interpolated by the lifted assembly block below.
  coordinator_input="$(jq -nc \
    --arg model_default "$implementer_model_default" \
    --arg model_trivial "$implementer_model_trivial" \
    --arg label "$pr_label" \
    --argjson cmax "$candidates_max" \
    --argjson policies "$refinement_policy_json" \
    'input as $repos | input as $blocked | input as $refinements | input as $claimed
     | {repos: $repos, blocked: $blocked, refinements: $refinements, claimed: $claimed,
        models: {default: $model_default, trivial: $model_trivial}, pr_label: $label,
        candidates_max: $cmax, refinement_policy: $policies}' <<<"$coordinator_stdin")"
  eval "$assembly_block"
  # shellcheck disable=SC2154  # Assigned by the assembly block just eval'd — it is what the block is for.
  printf '%s' "$coordinator_prompt" | wc -c
}

# --- The bound holds, and holds with room to spare ----------------------------
# Three inputs, each hugely over its allowance in a different way — long
# bodies, long threads, many entries — against three maxima. In every case the
# prompt the Script would actually send must be inside the configured maximum.
for spec in "40 6000 6 6000" "8 200 40 8000" "300 900 1 900"; do
  # shellcheck disable=SC2086   # the spec is four numbers, deliberately split
  repos="$(mk_repos $spec)"
  for max in 200000 350000 600000; do
    n="$(run_fit "$max" "$repos")"
    assert_ok "[$spec] a $max-byte maximum yields an assembled prompt inside it (got $n)" \
      "$(( n <= max ))"
  done
done

# --- The overhead is taken against an empty `repos`, so the allowance does not
#     move as the fit works. If it were measured against the unfitted array,
#     the allowance would be smaller by the indentation of every line the fit
#     removes — and the deeper the trim, the wronger it would get. ---
repos="$(mk_repos 40 6000 6 6000)"
n_small="$(run_fit 200000 "$repos")"
n_large="$(run_fit 600000 "$repos")"
assert_ok "a larger maximum yields a larger prompt, never a smaller one" \
  "$(( n_large >= n_small ))"
assert_ok "the deepest trim still uses most of its allowance rather than undershooting wildly" \
  "$(( n_small * 100 / 200000 > 60 ))"

# --- The bound off means untouched -------------------------------------------
repos="$(mk_repos 10 5000 3 5000)"
# shellcheck disable=SC2034  # Both are read by the lifted fit block, which is eval'd two lines down.
coordinator_prompt_max_bytes=0
# shellcheck disable=SC2034
ordered_repos_json="$repos"
: > "$events"
# shellcheck disable=SC2034  # Substituted into the base prompt by the lifted render below.
coordinator_sources_table="$(coordinator_work_sources_table "$all_repos_json")"
eval "$prompt_block"
eval "$fit_block"
assert_eq "a maximum of 0 leaves the repo array exactly as it was" \
  "$(jq -S . <<<"$repos")" "$(jq -S . <<<"$ordered_repos_json")"
assert_eq "a maximum of 0 logs nothing at all" "" "$(cat "$events")"

# --- Trimming is recorded, once, as an informational event -------------------
repos="$(mk_repos 40 6000 6 6000)"
run_fit 200000 "$repos" >/dev/null
assert_eq "a trimmed cycle logs exactly one coordinator-input-fitted event" \
  "1" "$(grep -c '^coordinator-input-fitted' "$events")"
assert_eq "…and no warning, because trimming is the working case" \
  "0" "$(grep -c '^warning' "$events")"
fitted="$(grep '^coordinator-input-fitted' "$events" | cut -f2-)"
assert_true "the event carries the rung it reached" \
  "$(jq -e 'has("rung") and has("bytes_before") and has("bytes_after") and has("budget")' <<<"$fitted" >/dev/null && echo true || echo false)"
assert_true "the event carries the human sentence a reader gets off the log" \
  "$(jq -r '.detail' <<<"$fitted" | grep -qF -- "-byte allowance" && echo true || echo false)"
# Requirement 4i's per-band terms (issue #645): the breakdown that lets a
# refusal's cause be read off the log instead of a live shell into the
# container.
assert_true "the event carries the per-band terms breakdown" \
  "$(jq -e '.terms | has("prompt") and has("blocked") and has("refinements") and has("claimed") and has("scaffold")' <<<"$fitted" >/dev/null && echo true || echo false)"

# --- agent-ops#933: the fit's own exemption-set gate reads the real fit
#     report ---------------------------------------------------------------
# Same fitted cycle as immediately above (`run_fit` left `ordered_repos_json`
# and `coordinator_fit_report_json` — both globals, no `local` in `run_fit` —
# set to a genuinely-trimmed array and a non-empty `{"applied":true,…}`
# report). Before agent-ops#933's fix, the gate's own
# `${coordinator_fit_report_json:-{}}` default silently corrupted that report
# into invalid JSON and its `if` never took the true branch, so
# `coordinator_fit_trimmed_json` stayed `"[]"` and `coordinator_fit_rung`
# stayed `0` on every cycle that actually trimmed — exactly the shape this
# section asserts against.
eval "$trim_block"
# shellcheck disable=SC2154  # Assigned by the lifted trim block just eval'd above.
trimmed_count="$(jq 'length' <<<"$coordinator_fit_trimmed_json" 2>/dev/null || echo 0)"
assert_ok "a fitted cycle's exemption set is non-empty (got $trimmed_count trimmed)" \
  "$(( trimmed_count > 0 ))"
# shellcheck disable=SC2154  # Assigned by the lifted trim block just eval'd above.
assert_ok "…and the rung it reached is recorded, not left at 0 (got $coordinator_fit_rung)" \
  "$(( coordinator_fit_rung > 0 ))"

# Requirement 3x: every trimmed-but-eligible candidate is counted as
# unassessable rather than demanding a needs_refinement/voided account — and
# the block says so on the log. Both come off the block just eval'd above:
# `trim_block` reaches to "3b. No-op short-circuit", so it carries requirement
# 3x's own accounting and its own `log_event` call, and the assertions here
# read those rather than recomputing them. A test that recomputed the count
# and logged the event itself could not tell a working block from a broken one
# — it would pass against the very pre-fix gate this section exists to catch.
# shellcheck disable=SC2154  # Assigned by the lifted trim block eval'd above.
assert_ok "requirement 3x counts the trimmed candidates as unassessable (got $coordinator_unassessable_total)" \
  "$(( coordinator_unassessable_total > 0 ))"
assert_eq "…and the block logs coordinator-input-fit-unassessable for this fitted cycle" \
  "1" "$(grep -c '^coordinator-input-fit-unassessable' "$events")"
unassessable_event="$(grep '^coordinator-input-fit-unassessable' "$events" | cut -f2-)"
assert_true "…carrying the count, the rung, and the sentence a reader gets off the log" \
  "$(jq -e --argjson n "$coordinator_unassessable_total" --argjson rung "$coordinator_fit_rung" \
      '.unassessable_total == $n and .rung == $rung and (.detail | test("rung \($rung)"))' \
      <<<"$unassessable_event" >/dev/null && echo true || echo false)"

# Requirement 34e's fourth refusal: a needs_refinement report naming one of
# this cycle's actually-trimmed items is refused, on the real rung and trimmed
# set the gate above computed — not a hand-written fixture.
trimmed_repo="$(jq -r '.[0].repo' <<<"$coordinator_fit_trimmed_json")"
trimmed_item="$(jq -r '.[0].item' <<<"$coordinator_fit_trimmed_json")"
entry_933="$(jq -nc --arg r "$trimmed_repo" --arg i "$trimmed_item" \
  '{repo: $r, item: $i, source: "issues", reason: "cannot tell what done means",
    missing: "the trimmed body gives no acceptance criteria", evidence: "the elided extract"}')"
refusal_reason="$(coordinator_fit_trim_refusal_reason "$entry_933" "$coordinator_fit_trimmed_json" "$coordinator_fit_rung")"
refusal_rc=$?
assert_eq "a needs_refinement report naming a trimmed item is refused" "1" "$refusal_rc"
assert_true "…and the refusal names the rung it was trimmed at" \
  "$([[ "$refusal_reason" == *"rung $coordinator_fit_rung"* ]] && echo true || echo false)"

# --- An untrimmed cycle is silent --------------------------------------------
run_fit 5000000 "$(mk_repos 3 100 1 100)" >/dev/null
assert_eq "a cycle that needed no trimming logs nothing" "" "$(cat "$events")"

# --- A prompt that cannot be fitted warns *before* the API refuses it. This is
#     the gap agent-ops#641 was filed into: the fleet's only record of four
#     lost cycles was an exit code. ---
# Two distinct shapes of "cannot fit", and they warn for different reasons.
# A maximum smaller than the prompt text itself leaves no allowance at all, so
# there is nothing for the ladder to shed and the warning has to say so rather
# than reading as the bound being switched off.
repos_hopeless="$(mk_repos 40 6000 6 6000)"
run_fit 1 "$repos_hopeless" >/dev/null
assert_ok "a maximum the prompt text alone exceeds logs a warning" \
  "$(( $(grep -c '^warning' "$events") >= 1 ))"
assert_true "the warning names the maximum it could not work inside" \
  "$(grep '^warning' "$events" | cut -f2- | jq -r '.detail' | grep -qF "coordinator_prompt_max_bytes" && echo true || echo false)"
warned="$(grep '^warning' "$events" | head -1 | cut -f2-)"
assert_true "the warning carries the per-band terms breakdown" \
  "$(jq -e '.terms | has("prompt") and has("blocked") and has("refinements") and has("claimed") and has("scaffold")' <<<"$warned" >/dev/null && echo true || echo false)"
# shellcheck disable=SC2154  # Assigned by the lifted fit block, eval'd inside run_fit above.
assert_eq "…and the five terms sum to the overhead total the block itself computed" \
  "$coordinator_fit_overhead_bytes" \
  "$(jq '[.terms[]] | add' <<<"$warned")"

# Requirement 4j: a hopeless allowance still walks the ladder. Before it, this
# branch warned and fell past the fit entirely, sending the array whole — which
# is how a 350052-byte `issues` extract went into a prompt that was over the
# window without it. Shedding nothing is the worst answer available in the one
# case where nothing can be enough.
assert_eq "…and still sheds, rather than sending the array whole" \
  "1" "$(grep -c '^coordinator-input-fitted' "$events")"
assert_true "…down to the ladder's last rung, which reports it does not fit" \
  "$(grep '^coordinator-input-fitted' "$events" | cut -f2- | jq -e '.fits == false' >/dev/null && echo true || echo false)"
n_hopeless="$(run_fit 1 "$repos_hopeless")"
n_unbounded="$(run_fit 0 "$repos_hopeless")"
assert_ok "…so a hopeless bound sends strictly less than no bound at all" \
  "$(( n_hopeless < n_unbounded ))"

# An allowance that exists but that even one entry per band cannot meet is the
# other shape: the ladder ran, bottomed out, and the API will refuse the
# prompt. The union log has to carry that cause rather than an exit code —
# the exact gap agent-ops#641 was filed into.
base_bytes="$(wc -c < "$PROMPTS_DIR/coordinator.md")"
run_fit "$(( base_bytes + 400 ))" "$(mk_repos 40 6000 6 6000)" >/dev/null
assert_eq "an allowance the ladder bottoms out inside logs a warning too" \
  "1" "$(grep -c '^warning' "$events")"
warned_bottomed="$(grep '^warning' "$events" | cut -f2-)"
assert_true "…and that warning says the API will refuse this cycle's prompt" \
  "$(jq -r '.detail' <<<"$warned_bottomed" | grep -qF "still does not fit" && echo true || echo false)"
assert_true "…and the warning itself carries the per-band terms breakdown" \
  "$(jq -e '.terms | has("prompt") and has("blocked") and has("refinements") and has("claimed") and has("scaffold")' <<<"$warned_bottomed" >/dev/null && echo true || echo false)"
# shellcheck disable=SC2154  # Assigned by the lifted fit block, eval'd inside run_fit above.
assert_eq "…and its five terms sum to the overhead total the block itself computed" \
  "$coordinator_fit_overhead_bytes" \
  "$(jq '[.terms[]] | add' <<<"$warned_bottomed")"
assert_true "…and the coordinator-input-fitted event beside it also carries the terms breakdown" \
  "$(grep '^coordinator-input-fitted' "$events" | cut -f2- | jq -e '.terms | has("prompt") and has("blocked") and has("refinements") and has("claimed") and has("scaffold")' >/dev/null && echo true || echo false)"

# --- The other half of agent-ops#641: a stage the API refused says which
#     refusal it was, and a stage that merely died does not get mislabelled as
#     one. `handle_stage_failure`'s two readers are lifted the same way the fit
#     block is. ---
eval "$(extract_block '^stage_api_refusal\(\) \{' '^\}$' "$SCRIPT_DIR/lib/stage-attempt.sh")"
eval "$(extract_block '^stage_api_refusal_message\(\) \{' '^\}$' "$SCRIPT_DIR/lib/stage-attempt.sh")"
eval "$(extract_block '^stage_api_refusal_class\(\) \{' '^\}$' "$SCRIPT_DIR/lib/stage-attempt.sh")"

# The record the fleet actually produced on 2026-08-21, verbatim but for the
# fields nothing here reads.
cat > "$tmp_dir/refused.out" <<'REC'
{"is_error":true,"terminal_reason":"prompt_too_long","api_error_status":400,"stop_reason":"stop_sequence","subtype":"success","type":"result","result":"Prompt is too long · the request is ~226580 tokens (limit 200000) but this conversation is only ~177028 tokens — the rest is system prompt, tool definitions, and attachment content. A single-exchange conversation cannot be compacted; reduce attached files/tools or start with less context."}
REC
assert_eq "the refusal that took the fleet down is named by its terminal reason" \
  "prompt_too_long" "$(stage_api_refusal "$tmp_dir/refused.out")"
assert_true "the API's own message is kept, beside the name and not inside it" \
  "$(stage_api_refusal_message "$tmp_dir/refused.out" | grep -qF "~226580 tokens (limit 200000)" && echo true || echo false)"
assert_true "the name carries none of the numbers the crash-loop ladder must not group on" \
  "$(stage_api_refusal "$tmp_dir/refused.out" | grep -qE '[0-9]' && echo false || echo true)"

# An API refusal with no `terminal_reason` still gets a stable name from the
# status alone, rather than reading as "not a refusal".
echo '{"is_error":true,"api_error_status":529,"result":"Overloaded"}' > "$tmp_dir/overloaded.out"
assert_eq "a refusal the runner did not name falls back to its HTTP status" \
  "api_error_529" "$(stage_api_refusal "$tmp_dir/overloaded.out")"

# And the shapes that must NOT be called a refusal: a stage that ran and then
# failed, a clean result, an empty file, and a file that is not JSON at all.
# Mislabelling any of these would replace an honest exit code with a confident
# falsehood.
echo '{"is_error":true,"terminal_reason":"error_during_execution","result":"the tool crashed"}' > "$tmp_dir/crashed.out"
assert_eq "a stage that ran and then failed is not a refusal" \
  "" "$(stage_api_refusal "$tmp_dir/crashed.out")"
assert_eq "…and yields no message either" \
  "" "$(stage_api_refusal_message "$tmp_dir/crashed.out")"
echo '{"is_error":false,"terminal_reason":"completed","result":"{}"}' > "$tmp_dir/ok.out"
assert_eq "a clean result is not a refusal" "" "$(stage_api_refusal "$tmp_dir/ok.out")"
: > "$tmp_dir/empty.out"
assert_eq "an empty transcript is not a refusal" "" "$(stage_api_refusal "$tmp_dir/empty.out")"
echo 'this is not json' > "$tmp_dir/garbage.out"
assert_eq "an unparseable transcript is not a refusal" "" "$(stage_api_refusal "$tmp_dir/garbage.out")"

# --- issue #1073: not every refusal is deterministic, and the record now
#     says which. `stage_api_refusal_class` reads the same file as
#     `stage_api_refusal`/`stage_api_refusal_message` above and answers
#     "transient" or "refused" beside the stable token, never inside it. ---

# The Ockham record, verbatim but for the fields nothing here reads
# (2026-08-29/30, agent-ops#1073's own evidence): a 503 the runner named
# "api_error" — the API was unreachable, not refusing a considered request.
cat > "$tmp_dir/ockham.out" <<'REC'
{"is_error":true,"api_error_status":503,"terminal_reason":"api_error","result":"API Error: ERROR: The requested URL could not be retrieved. This is a server-side issue, usually temporary — try again in a moment. If it persists, check https://status.claude.com."}
REC
assert_eq "a 503 is classified transient" \
  "transient" "$(stage_api_refusal_class "$tmp_dir/ockham.out")"

assert_eq "the 2026-08-21 prompt_too_long refusal is classified refused" \
  "refused" "$(stage_api_refusal_class "$tmp_dir/refused.out")"

# A named connection-level fault, whatever status happens to ride with it
# (here none at all is impossible — stage_api_refusal_class shares
# stage_api_refusal's own gate, an HTTP status must be present — so this is
# the shape a CLI naming the fault explicitly would take).
echo '{"is_error":true,"api_error_status":502,"terminal_reason":"api_connection_error","result":"connection reset by peer"}' \
  > "$tmp_dir/connection.out"
assert_eq "a named connection-level fault is classified transient" \
  "transient" "$(stage_api_refusal_class "$tmp_dir/connection.out")"

assert_eq "the 529 overload falls back to its status, above 500, so transient" \
  "transient" "$(stage_api_refusal_class "$tmp_dir/overloaded.out")"

# An ordinary 4xx with no named reason: the API considered and declined the
# request, so this defaults to refused rather than transient.
echo '{"is_error":true,"api_error_status":404,"result":"not found"}' > "$tmp_dir/notfound.out"
assert_eq "an unnamed 4xx defaults to refused" \
  "refused" "$(stage_api_refusal_class "$tmp_dir/notfound.out")"

# The shapes that are not a refusal at all yield no class, same as
# stage_api_refusal itself.
assert_eq "a stage that ran and then failed has no refusal class" \
  "" "$(stage_api_refusal_class "$tmp_dir/crashed.out")"
assert_eq "a clean result has no refusal class" \
  "" "$(stage_api_refusal_class "$tmp_dir/ok.out")"
assert_eq "an empty transcript has no refusal class" \
  "" "$(stage_api_refusal_class "$tmp_dir/empty.out")"
assert_eq "an unparseable transcript has no refusal class" \
  "" "$(stage_api_refusal_class "$tmp_dir/garbage.out")"

echo
if (( failures == 0 )); then
  echo "All coordinator-input-wiring assertions passed."
  exit 0
else
  echo "$failures coordinator-input-wiring assertion(s) FAILED."
  exit 1
fi
