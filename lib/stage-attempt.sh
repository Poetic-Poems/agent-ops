#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/stage-attempt.sh — one Co-Ordinator stage attempt end to end: launch,
# parse the final message (with the prose/fence/bare-object salvage models
# occasionally need), and the shared failure handling — a refused API
# request, a wedged or timed-out run, an unparseable message — that every
# stage this pipeline runs eventually hits.
#
# Split out of agent-cycle.sh (#771) as the "stage orchestration and prompt
# assembly" seam docs/IMPLEMENTATION-PIPELINE-SPEC.md's requirements name:
# `run_coordinator_stage_attempt` is the one launch/parse/salvage sequence the
# Co-Ordinator's first attempt and its corroboration retry both run through,
# `fallback_select_candidate` and `coordinator_corroborate_retry_or_fallback`
# are the requirement-3v ladder built on top of it once a `none-selected`
# verdict fails corroboration, and `extract_json_result`/`stage_salvage_result`/
# `dump_stage_output`/`stage_api_refusal`/`stage_api_refusal_message`/
# `handle_stage_failure` are what every stage — Co-Ordinator, Approver,
# Enabler, Refiner, Implementer, Reviewer — shares to turn a stage's raw
# output into a parsed verdict or a recorded, claim-releasing failure.
#
# Sourced by agent-cycle.sh only; reads and writes the cycle's own globals
# (`cycle_dir`, `ONCE`, `ordered_repos_json`, `selected_repo`/`selected_item`,
# `claim_active`, …) exactly as it did inline, and calls lib/stage-run.sh's
# `run_claude_stage` and lib/stage-budget.sh's `stage_budget_apply`.

# Stage prompts require the final message to be pure JSON, but a model will
# sometimes prepend analysis prose anyway and put the real object in a
# trailing fenced ```json block — or leave it bare after the prose. Try a
# straight parse first; then the last fenced block; then the earliest line
# opening a brace whose text from there to the end of the message parses as
# exactly one JSON value.
#
# The third salvage earns its place by what its absence cost. On 2026-08-03
# an Enabler engagement examined three refinement items, reached a correct
# `escalate` verdict on each and drafted every escalation issue — then ended
# with a summary paragraph, a blank line, and the verdict object, bare. The
# fence fallback could not touch it (the prompts *forbid* the fence, so the
# one deviation this function could rescue was the one the prompts rule
# out), the engagement was discarded whole under requirement 37, and the
# items sat behind its never-released claims for the rest of claim_ttl_hours
# — six further hours — waiting for a retry that could only re-derive what
# the discarded message already said. Prose-then-bare-object is the shape
# models actually produce when they slip; it must not be the one fatal case.
#
# It is deliberately a *suffix* parse: only an object that runs to the end
# of the message is taken, and an object with trailing prose still fails,
# because "which of these is the verdict" is not a question this function
# should answer. `jq -es 'length == 1'` is the single-value check — `jq
# empty` accepts a stream of several values, and a salvage should never be
# looser than the straight parse it backs up.
#
# The fenced-block fallback matches a closing ``` regardless of what info
# string the *opening* fence carried, or whether it carried one at all
# (issue #237): the state machine toggles solely on "is this a fence line",
# not on the literal text `json` following it. A verdict a model fences
# bare — ``` … ``` with no language tag — is not an ambiguous case; only a
# straight parse or a suffix match, not the fence's tag, was ever what told
# a verdict apart from prose. Before this, poetic-2's completed conflict
# resolution of PR #205 (2026-08-07T04:40Z) was discarded for exactly this
# reason — a bare fence the parser could not see — erasing pipeline memory
# that the conflict was fixed and triggering a three-node duplicate-work
# cascade on the same PR.
#
# scripts/publish-dashboard.sh's `extract_status` is a jq port of this
# algorithm and review-cycle.sh carries a bash copy; the three move together
# (docs/DASHBOARD-SPEC.md), and test/extract-json-result.test.sh holds them
# to it.
#
# An empty-or-whitespace-only $text is checked explicitly and fails outright
# (TD26072802, for symmetry with publish-dashboard.sh's extract_status,
# which shares this algorithm per DASHBOARD-SPEC.md): `jq empty` on
# whitespace input succeeds trivially with no output, so without this check
# the function would return 0 — success — while printing nothing. Every call
# site already treats empty output as failure regardless of the exit code, so
# this changes no observable behaviour; it just stops the exit code lying
# about what happened.
extract_json_result() {
  local text="$1" block line_no suffix
  [[ "$text" =~ ^[[:space:]]*$ ]] && return 1
  if jq empty <<<"$text" >/dev/null 2>&1; then
    jq -c '.' <<<"$text"
    return 0
  fi
  block="$(awk '
    /^```[A-Za-z0-9_-]*[[:space:]]*$/ {
      if (in_block) { last=capture; in_block=0 } else { capture=""; in_block=1 }
      next
    }
    in_block { capture = capture $0 "\n" }
    END { printf "%s", last }
  ' <<<"$text")"
  if [[ -n "$block" ]] && jq empty <<<"$block" >/dev/null 2>&1; then
    jq -c '.' <<<"$block"
    return 0
  fi
  while IFS=: read -r line_no _; do
    suffix="$(tail -n "+$line_no" <<<"$text")"
    if jq -es 'length == 1' <<<"$suffix" >/dev/null 2>&1; then
      jq -c '.' <<<"$suffix"
      return 0
    fi
  done < <(grep -n '^[[:space:]]*{' <<<"$text" || true)
  return 1
}

# A salvage resume is a single short turn — "state the verdict you already
# reached, nothing else" — so it earns none of the adaptive budgeting a real
# stage's own caps get from lib/stage-budget.sh (requirement 4e): a fixed,
# conservative bound is safer than one that could grow to a whole stage's own
# backstop over time. Five minutes is generous for a turn with no tool calls;
# the ninety-second watchdog catches a resume that never starts producing at
# all.
stage_salvage_backstop_sec=300
stage_salvage_inactivity_sec=90

# stage_salvage_result STAGE OUT_FILE MODEL CWD
# The bounded rescue of requirement 37's discard rule (issue #237): before an
# engagement whose final message failed extract_json_result is discarded
# whole, resume the exact session that produced it — not a fresh one, which
# would pay to re-derive work already done — with nothing but "return the
# verdict object". Prints the recovered JSON on stdout and returns 0 when
# that resume's own final message parses; returns 1 and prints nothing
# otherwise, including when the original run left no `session_id` to resume
# (a killed run's stream can end before the CLI's init event ever landed).
#
# Deliberately silent about *why* the first attempt failed — a timeout, a
# crash, an unparseable message are all the same fact from here: the session
# is worth one more ask before its work is written off. The caller decides
# what "worth trying" means for its own stage (an Enabler with a `rc != 0`
# has no living session to resume in the first place, since the process that
# would hold one is the one that never exited).
stage_salvage_result() {
  local stage="$1" out_file="$2" model="$3" cwd="$4"
  local session_id salvage_out salvage_rc salvage_result parsed
  # run_claude_stage sets its caller-visible globals for whichever run is
  # most recent; the original run's metering is already logged by the time
  # this is called, but detect_and_log_limit_hit is not — it reads
  # $stage_rate_limit_json at the call sites' own discretion, later, against
  # $out_file. Left alone, a salvage attempt would overwrite it with the
  # resume's own (almost always empty) limit info before that read happens.
  # Saving and restoring here keeps this function's globals side effect
  # entirely local, which is what every caller of it is entitled to assume.
  local saved_gaps="$stage_gaps_json" saved_kill="$stage_kill_reason" \
        saved_limit="$stage_rate_limit_json"
  session_id="$(jq -r '.session_id // empty' "$out_file" 2>/dev/null || true)"
  if [[ -z "$session_id" ]]; then
    stage_gaps_json="$saved_gaps"; stage_kill_reason="$saved_kill"; stage_rate_limit_json="$saved_limit"
    return 1
  fi
  salvage_out="${out_file%.out}.salvage.out"
  log_event "salvage" "$(jq -nc --arg s "$stage" '{stage: $s, outcome: "attempted"}')"
  if run_claude_stage "$stage-salvage" "$stage_salvage_backstop_sec" "$model" \
       "Return only the verdict JSON object, nothing else." \
       "$salvage_out" "$cwd" "$stage_salvage_inactivity_sec" "$session_id"; then
    salvage_rc=0
  else
    salvage_rc=$?
  fi
  stage_gaps_json="$saved_gaps"; stage_kill_reason="$saved_kill"; stage_rate_limit_json="$saved_limit"
  if (( salvage_rc != 0 )); then
    log_event "salvage" "$(jq -nc --arg s "$stage" --argjson rc "$salvage_rc" \
      '{stage: $s, outcome: "failed", exit_code: $rc}')"
    return 1
  fi
  salvage_result="$(jq -r '.result // empty' "$salvage_out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$salvage_result" 2>/dev/null || true)"
  if [[ -z "$parsed" ]]; then
    log_event "salvage" "$(jq -nc --arg s "$stage" '{stage: $s, outcome: "failed"}')"
    return 1
  fi
  log_event "salvage" "$(jq -nc --arg s "$stage" '{stage: $s, outcome: "recovered"}')"
  printf '%s' "$parsed"
  return 0
}

dump_stage_output() {
  local out_file="$1"
  cat "$out_file"
  [[ -s "$out_file.stderr" ]] && cat "$out_file.stderr" >&2
  # An empty stderr file must not become this function's return value: the
  # call sites are `(( ONCE )) && dump_stage_output …`, and the command after
  # a final `&&` is exactly where `set -e` applies — a stage whose stderr was
  # empty killed a --once cycle here, after the stage ended and before its
  # failure handling (limit detection, attempt-failed, claim release) ran.
  return 0
}

# Requirement 4i (agent-ops#641): the terminal reason a headless `claude` run
# records for itself when the API refused the request outright, and the message
# it came with. Empty for every ordinary failure, so the caller's own ladder is
# untouched by stages that failed some other way.
#
# The two halves are deliberately separate. `stage_api_refusal` is the *stable*
# token (`prompt_too_long`, `invalid_request_error`, …) and is what goes in the
# `detail` a crash-loop verdict groups on — requirement 2.7 counts consecutive
# failures carrying the *same* detail, and on 2026-08-21 the accompanying
# message named a token count that moved every cycle, so a detail built from it
# would have been four distinct failures and the ladder would never have fired
# on the very outage it was needed for. The message travels beside it, on the
# event, where a reader gets the numbers and nothing groups on them.
# The test is `api_error_status` being a number, not merely `is_error` being
# true: `is_error` covers every way a stage can end badly, including ones that
# ran and then failed, and calling those "refused by the API before it could
# run" would put a confident falsehood where an honest exit code used to be.
# An HTTP status on the record is the API itself saying it declined the
# request. `terminal_reason` names which refusal when the runner recorded one
# (`prompt_too_long`); the status stands in when it did not.
stage_api_refusal() {  # <out-file> -> terminal reason, or empty
  local out_file="$1"
  [[ -s "$out_file" ]] || return 0
  jq -r 'select((.is_error // false) == true)
         | select((.api_error_status // null) | type == "number")
         | ((.terminal_reason // "") as $r
            | if $r == "" or $r == "completed" then "api_error_\(.api_error_status)" else $r end)' \
    "$out_file" 2>/dev/null | head -1
}

stage_api_refusal_message() {  # <out-file> -> the API's own words, truncated
  local out_file="$1"
  [[ -s "$out_file" ]] || return 0
  jq -r 'select((.is_error // false) == true)
         | select((.api_error_status // null) | type == "number")
         | (.result // "") | .[0:600]' \
    "$out_file" 2>/dev/null | head -1
}

handle_stage_failure() {
  local stage="$1" rc="$2" out_file="$3" pr_url="${4:-}" detail refusal refusal_msg
  # 124 is now both caps, and they are not the same news to whoever reads this
  # next — the Enabler, or a human asking why an item is blocked. "Ran to its
  # wall-clock cap while still working" argues for a longer cap; "produced
  # nothing at all for ten minutes" argues for looking at what it was waiting
  # on. So the reason is stated rather than left to be inferred from an exit
  # code that cannot carry it.
  refusal="$(stage_api_refusal "$out_file")"
  if [[ -n "$refusal" ]]; then
    # An API refusal is not a crash, and "coordinator exited 1" is a true but
    # useless account of one: on 2026-08-21 that was every record the fleet
    # kept of four cycles it lost to a prompt past the context window, and the
    # escalation it raised sent its reader to `coordinator.out.stderr`, which
    # an API refusal leaves empty because the refusal is in `coordinator.out`.
    detail="$stage was refused by the API before it could run: $refusal"
  elif [[ "$rc" == "124" && "$stage_kill_reason" == "inactivity" ]]; then
    detail="$stage produced no output at all for its inactivity threshold and was stopped as wedged"
  elif [[ "$rc" == "124" && "$stage_kill_reason" == "rate-limit" ]]; then
    detail="$stage was stopped the moment the account reported a usage limit — nothing it did after that could have succeeded"
  elif [[ "$rc" == "124" ]]; then
    detail="$stage timed out"
  else
    detail="$stage exited $rc"
  fi
  detect_and_log_limit_hit "$out_file" || true
  # The PR travels on the event (requirement 32a) so the Enabler can open it
  # without re-deriving it from the item id — for a finishing source the item
  # may not name the PR at all. So does the API's own refusal message, which
  # carries the numbers `detail` deliberately leaves out.
  refusal_msg=""
  [[ -n "$refusal" ]] && refusal_msg="$(stage_api_refusal_message "$out_file")"
  log_attempt_failed "$stage" "$detail" \
    "$(jq -nc --arg u "$pr_url" --arg r "$refusal" --arg m "$refusal_msg" \
       '(if $u == "" then {} else {pr_url: $u} end)
        + (if $r == "" then {} else {api_refusal: $r} end)
        + (if $m == "" then {} else {api_message: $m} end)')"
  if [[ -n "$pr_url" ]]; then
    gh pr comment "$pr_url" --body "$(pipeline_comment_header script "$node_name")

The $(pipeline_actor_label "$stage") stopped on this PR: $detail. Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed.

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
}

# Requirement 3v (issue #321): one Co-Ordinator engagement, launched, parsed,
# and its own failure paths handled — factored out of the "4. Co-Ordinator
# stage" flow below so the corroboration retry can call it a second time
# without duplicating the launch/parse/salvage machinery. Sets
# `coord_attempt_result_json` to the parsed work order on success (empty on
# any failure — a launch failure, an unparseable final message even after
# salvage) and `coord_attempt_metering_json` to this attempt's own cost/time
# fields (lib/metering.sh) every time, success or failure, so a caller can
# report what the attempt cost regardless of its outcome. Returns 1 on any
# failure, after this attempt's own `attempt-failed`/`stage-end` logging and
# (for a launch failure) `handle_stage_failure`'s claim release — the same
# handling the single inline attempt used to do for itself, run here for
# either attempt.
#
# `extra` (default `{}`) is spliced into both `stage_budget_apply`'s own
# `stage-start` event and this attempt's `stage-end`/`attempt-failed` events,
# so the first (and by far the common) attempt is untouched — no argument,
# `{}` merges to nothing — while the retry tags every event it produces
# `{"retry": true}`, letting a reader (or requirement 3v's own corroboration
# events, below) tell which attempt paid for what without cross-referencing
# `stage-start` timestamps by hand.
run_coordinator_stage_attempt() {  # <attempt-out-file> <prompt> [extra-budget-json]
  local out_file="$1" prompt="$2" extra="${3:-{\}}" rc=0 watchdog_warning result
  jq -e 'type == "object"' <<<"$extra" >/dev/null 2>&1 || extra='{}'

  stage_budget_apply coordinator "*" "$coordinator_model" "$extra"
  if run_claude_stage coordinator "$(( stage_backstop_min * 60 ))" "$coordinator_model" "$prompt" "$out_file" "$cycle_dir" "$(( stage_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  coord_attempt_metering_json="$(metering_fields "$coordinator_model" "$out_file" "$stage_gaps_json")"
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" \
    --argjson m "$coord_attempt_metering_json" --argjson e "$extra" \
    '{stage: "coordinator", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m + $e')"
  # No repo/item: the Co-Ordinator runs ahead of selection, over every
  # configured repository at once (docs/FLOW-SCHEMA.md's "where applicable").
  rework_stage_rerun_maybe "coordinator" "$stage_kill_reason"
  # `if`, not `&&` — see the identical comment at the original call site below.
  watchdog_warning="$(stage_watchdog_warning coordinator || true)"
  if [[ -n "$watchdog_warning" ]]; then
    log_event "warning" "$watchdog_warning"
  fi
  (( ONCE )) && dump_stage_output "$out_file"

  if (( rc != 0 )); then
    handle_stage_failure "coordinator" "$rc" "$out_file" ""
    coord_attempt_result_json=""
    return 1
  fi

  result="$(jq -r '.result // empty' "$out_file" 2>/dev/null || true)"
  coord_attempt_result_json="$(extract_json_result "$result" 2>/dev/null || true)"
  if [[ -z "$coord_attempt_result_json" ]]; then
    coord_attempt_result_json="$(stage_salvage_result coordinator "$out_file" "$coordinator_model" "$cycle_dir" || true)"
  fi
  if [[ -z "$coord_attempt_result_json" ]]; then
    detect_and_log_limit_hit "$out_file" || true
    log_event "attempt-failed" "$(jq -nc --argjson e "$extra" \
      '{stage: "coordinator", detail: "unparseable final message"} + $e')"
    return 1
  fi
  return 0
}

# Requirement 3v (issue #321): the mechanical last resort once a `none-selected`
# verdict has failed corroboration twice in the same cycle (the original
# engagement and its one retry — see "5. Nothing selected" below). At that
# point liveness must stop depending on the model getting it right at all, so
# the Script itself picks: the highest-priority non-empty source band, its
# first item in repo order, with no per-item judgement applied.
#
# The band order approximates `prompts/coordinator.md`'s own "Selection
# algorithm" — the five cross-repo overrides (security, urgent issues,
# review-feedback, merge-conflicts, abandoned-drafts) ahead of the residual
# bands (human-visibility, high issues, tech-debt, medium issues, low issues,
# code-quality, register-hygiene) — restricted to the bands the Script has a
# pre-fetched array for. Approximates, not mirrors, in two respects a
# mechanical pick can afford: the walk is band-major across the whole fleet
# rather than the Co-Ordinator's repo-then-source walk. `failed-runs`,
# `implementation-plan` and
# `project-review` have no pre-fetched array — enumerating their candidates means a live `gh`
# read or a tree fetch the Co-Ordinator does for itself, which this mechanical
# fallback does not perform — so those three ranks are skipped rather than
# approximated. This is a known, deliberate narrowing: this path exists to
# keep the fleet selecting *something* once the model has twice failed to
# corroborate a `none-selected` against the bands requirement 3x's gate does
# check, so those three sitting
# unreached by fallback costs nothing on the failure mode this exists for —
# `eligible_items_json` is non-empty exactly when the gate can reject a
# verdict at all, and every band it counts has a rank below, so there is
# always something to fall to.
#
# It reads each repo's configured `sources` list as well as its pre-fetched
# arrays, and that is load-bearing rather than tidiness (requirement 3x): the
# arrays alone stopped being the authority on what a cycle may select once
# requirement 2.2a's back-pressure began narrowing the *list* while leaving
# `findings`, `register_hygiene` and `human_visibility` populated. Before 3x
# the point could not arise — back-pressure emptied `tech_debt`, so the
# tech-debt-only gate could never reject during a restricted cycle and this
# function was never reached — but a gate that now counts the finishing
# sources can, and a fallback blind to `sources` would answer it by starting
# fresh work through a full landing gate. The one place the list is coarser
# than the array is `findings`, whose two kinds are separate source tokens
# (`security`, `code-quality`) and are matched as such here.
#
# The one band the gate counts that this walk can still decline is a
# superseded Dependabot merge-conflict entry: the prompt requires it in
# `voided` (so it is eligible, and owed an account) but it is not selectable
# work, so `mc_cands` skips it exactly as the prompt does. A cycle whose only
# unaccounted item is one of those reaches the empty-pick branch below, which
# stands down rather than assuming the guarantee.
#
# Each candidate is built straight from its own pre-fetched entry — the same
# fields the Co-Ordinator's own contract in `prompts/coordinator.md`'s
# "Output" section requires (`item`, `branch`/`pr_url`/`pr_number` for the
# four finishing sources, the Dependabot `takeover` shape for
# merge-conflicts) — with `context` a verbatim paste of the entry's own body
# text and `acceptance` a generic instruction naming the source's standard
# procedure, since there is no model here to compose a bespoke one.
# `model`/`model_reason` are supplied by the caller (ordinarily
# `implementer_model_default`) since a mechanical pick makes no model
# judgement to report — cheap to spot on the eventual Implementer work order,
# rather than silently reusing whatever the last attempt happened to prefer.
# `pr_label` is supplied by the caller for the same reason the Co-Ordinator is
# handed it on its runtime input and copies it into every candidate
# (requirement 20): the Implementer labels its draft pull request with the
# work order's own field, and a candidate built here without one would raise
# the unlabelled pull request that no gatherer — nor the back-pressure count —
# can find again.
#
# `refinement_policy` (requirement 39a) binds this path exactly as it binds
# the Co-Ordinator, and for the same reason: a `"required"` source's unrefined
# item is not a lower-ranked candidate, it is one nobody has written a
# specification for yet, and handing it to an Implementer under a generic
# `acceptance` string is precisely the outcome that policy exists to prevent.
# A mechanical picker that ignored it could select what no Co-Ordinator
# engagement was allowed to. So an unrefined item from a `"required"` source
# is dropped here (`mk` yields nothing for it), and a `"preferred"` source's
# refined items are ranked ahead of its unrefined ones within their band —
# the same thumb on the scale `prompts/coordinator.md`'s "Per-source
# refinement policy" section describes, applied by a stable sort so the band's
# own order still decides everything else. `"exempt"` sources, which is every
# source an installation has not opted in, are unaffected.
#
# This costs the guarantee above nothing, band by band: `unaccounted_items`
# drops an eligible entry whose own source is `"required"` before it can ever
# make the gate reject, so a band that could send the cycle here is by
# construction a band this exclusion does not empty.
#
# Prints the single winning candidate object, or `null` if every reachable
# band was empty (never observed in practice, per the guarantee above, but
# handled rather than assumed).
fallback_select_candidate() {  # <ordered-repos-json> <default-model> <refinements-json> <refinement-policy-json> <pr-label>
  local repos="$1" model="$2" refinements="${3:-{\}}" policy="${4:-{\}}" label="${5:-}"
  jq -e 'type == "object"' <<<"$refinements" >/dev/null 2>&1 || refinements='{}'
  jq -e 'type == "object"' <<<"$policy" >/dev/null 2>&1 || policy='{}'
  jq -c --arg model "$model" --arg label "$label" --argjson refinements "$refinements" --argjson policy "$policy" \
    --arg model_reason "script-fallback: deterministic band-priority pick after two rejected corroboration verdicts; no model judgement applied" '
    def policy_of($src): (($policy // {})[$src] // "exempt");
    def is_refined($r; $item): ((($refinements // {})[$r] // {})[($item | tostring)] // null) != null;
    # Requirement 3x: the repo entry keeps its own `sources` list, and a band
    # this cycle narrowed away (back-pressure, or a repo that never listed the
    # source) is not a band a mechanical pick may reach into. Applied to the
    # repo, before its array is walked, so it costs one test per repo per band
    # rather than one per candidate.
    def lists($src): (((.sources // []) | index($src)) != null);
    # An issue is banded per entry (requirement 15e), so its rank token is
    # too: `issues` alone means every band, `issues:high` means only that one.
    def lists_issue_band($p): (lists("issues") or lists("issues:" + ($p | ascii_downcase)));

    # `_rank` is stripped from the winner below; it exists only to order the
    # band of a "preferred" source, and is 0 under every other policy so those
    # bands keep the order they are built in.
    def mk($r; $db; $src; $item; $title; $ctx; $acc; $extra):
      if policy_of($src) == "required" and (is_refined($r; $item) | not) then empty
      else
        {repo: $r, default_branch: $db, pr_label: $label, source: $src, item: $item, title: $title,
         model: $model, model_reason: $model_reason, context: $ctx, acceptance: $acc,
         _rank: (if policy_of($src) == "preferred" and (is_refined($r; $item) | not)
                 then 1 else 0 end)} + $extra
      end;

    def issue_ctx: "Issue #" + (.number | tostring) + ": " + (.title // "") + "\n\n"
      + (.body // "") + "\n\nComments:\n"
      + ([(.comments // [])[] | (.author // "") + " (" + (.created_at // "") + "):\n" + (.body // "")] | join("\n\n"));

    def sec_cands: [.[] | select(lists("security")) | .slug as $r | .default_branch as $db | (.findings // [])[] | select(.source == "security")
      | mk($r; $db; "security"; .ref; .title;
          ("Security finding (script-fallback selection).\nkind: " + (.kind // "") + "\nseverity: " + (.severity // "")
           + "\npackage: " + (.package // "") + "\nrule: " + (.rule // "") + "\nlocation: " + (.location // "")
           + "\nurl: " + (.url // "") + "\ntitle: " + (.title // ""));
          "Resolve the finding per its own record above, following this repo'"'"'s standard security-finding handling.";
          {})];

    def issue_band($p): [.[] | select(lists_issue_band($p)) | .slug as $r | .default_branch as $db | (.issues // [])[]
      | select((.priority // "Medium") == $p)
      | mk($r; $db; "issues"; ((.ref // (.number | tostring))); .title; issue_ctx;
          "Resolve per the current state of the issue thread above (body and every comment), not just the opening post.";
          {})];

    def rf_cands: [.[] | select(lists("review-feedback")) | .slug as $r | .default_branch as $db | (.review_feedback // [])[]
      | mk($r; $db; "review-feedback"; .ref; .title; (.body // "");
          "Address the review feedback above and push to the existing pull request.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number})];

    def mc_cands: [.[] | select(lists("merge-conflicts")) | .slug as $r | .default_branch as $db | (.merge_conflicts // [])[]
      | select((.superseded_by // null) == null)
      | select(((.bot // false) | not) or (.rebase_requested // false))
      | (((.bot // false) and (.rebase_requested // false)) as $takeover
         | mk($r; $db; "merge-conflicts"; .ref; .title; (.body // "");
             "Rebase the existing pull request onto its base and resolve the conflict.";
             ({pr_url: .pr_url, pr_number: .pr_number} + (if $takeover then {takeover: true} else {branch: .branch} end))))];

    def dq_cands: [.[] | select(lists("dequeued")) | .slug as $r | .default_branch as $db | (.dequeued // [])[]
      | mk($r; $db; "dequeued"; .ref; .title; (.body // "");
          "Diagnose and fix the merge-group checks failure that got this pull request dequeued, then push to the existing branch.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number, base: .base})];

    def ad_cands: [.[] | select(lists("abandoned-drafts")) | .slug as $r | .default_branch as $db | (.abandoned_drafts // [])[]
      | mk($r; $db; "abandoned-drafts"; .ref; .title; (.body // "");
          "Finish the existing draft pull request to the item'"'"'s own acceptance.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number})];

    def hv_cands: [.[] | select(lists("human-visibility")) | .slug as $r | .default_branch as $db | (.human_visibility // [])[]
      | mk($r; $db; "human-visibility"; .ref; ("human-visibility: " + .ref);
          ((.body // "") + "\n\nurl: " + (.url // ""));
          "Diagnose and fix the named human-visibility failure per its own record above; report blocked if the cause is outside this repository.";
          {})];

    def td_cands: [.[] | select(lists("tech-debt")) | .slug as $r | .default_branch as $db | (.tech_debt // [])[]
      | mk($r; $db; "tech-debt"; .ref; .title; (.body // "");
          "Resolve per the tech-debt record verbatim above; standard tech-debt closing procedure applies.";
          {})];

    def cq_cands: [.[] | select(lists("code-quality")) | .slug as $r | .default_branch as $db | (.findings // [])[] | select(.source == "code-quality")
      | mk($r; $db; "code-quality"; .ref; .title;
          ("Code-quality finding (script-fallback selection).\nkind: " + (.kind // "") + "\nrule: " + (.rule // "")
           + "\nlocation: " + (.location // "") + "\nurl: " + (.url // "") + "\ntitle: " + (.title // ""));
          "Resolve the finding per its own record above, following this repo'"'"'s standard code-quality handling.";
          {})];

    def rh_cands: [.[] | select(lists("register-hygiene")) | .slug as $r | .default_branch as $db | (.register_hygiene // [])[]
      | mk($r; $db; "register-hygiene"; .ref; ("register-hygiene: " + .ref);
          ((.body // "") + "\n\nurl: " + (.url // "") + "\nblob_sha: " + (.blob_sha // "")
           + "\nproblems: " + ((.problems // []) | join("; ")));
          "Repair only the flagged register inconsistencies per TECH-DEBT.md'"'"'s claiming/filing discipline; touch nothing else.";
          {})];

    [ sec_cands, issue_band("Urgent"), rf_cands, mc_cands, dq_cands, ad_cands, hv_cands,
      issue_band("High"), td_cands, issue_band("Medium"), issue_band("Low"), cq_cands, rh_cands ]
    | map(select(length > 0))
    | if length > 0 then (.[0] | sort_by(._rank) | .[0] | del(._rank)) else null end
  ' <<<"$repos"
}

# Requirement 3v (issue #321): the Co-Ordinator's own `selected: false`
# verdict, corroborated, retried, and — as a last resort — mechanically
# resolved, all in one call. Called only when the first attempt's own
# `work_order_json` reports `selected != true` (the caller's "5. Nothing
# selected" guard); reads and writes that same global, along with `selected`,
# `reason`, `candidates_json` and `selected_by_fallback`, exactly the way the
# top-level flow that used to hold this logic inline did — factored out
# purely so it can `return` instead of `exit`, which is what makes it
# testable (`extract_fn`-and-`eval`, the technique `maybe_run_enabler` already
# established) and what lets its caller decide whether standing down means
# ending the process or falling through to "5b. Candidates, and the claim"
# with a work order now ready to claim.
#
# Returns 0 when `work_order_json`/`candidates_json` are ready for 5b (a
# retry that selected, or a fallback pick); returns 1 when the caller should
# `exit 0` immediately — every event this needs logged (`none-selected`,
# `warning`, `corroboration`, and any failed-attempt handling
# `run_coordinator_stage_attempt` already did for a launch failure) has
# already been written by the time it returns 1.
coordinator_corroborate_retry_or_fallback() {
  reason="$(jq -r '.reason // "no reason given"' <<<"$work_order_json")"

  # --- 5a. Verdict corroboration (requirements 3t/3x, issues #310, #322) ---
  # See unaccounted_items' own comment above for the rule, and
  # coordinator_eligible_items' for what "eligible" means per band; only worth
  # computing at all when the Script found something eligible to check the
  # verdict against. Fed the recording loops' own collections (steps above),
  # never $work_order_json's arrays verbatim: the account is what the Script
  # put on the record, not what the message claimed to.
  unaccounted_json="[]"
  if (( eligible_items_total > 0 )); then
    # $nr/$v are the recording loops' own collections and grow with the
    # cycle's whole needs_refinement/voided bands — unbounded past this call,
    # never argv (requirement 4g, TD-PPagop-26081406): both arrive on stdin,
    # bound positionally with `input as $name` in the order printed.
    unaccounted_json="$(unaccounted_items \
      "$(jq -nc 'input as $nr | input as $v | {needs_refinement: $nr, voided: $v}' \
          <<<"${coord_recorded_refinement_json:-[]}"$'\n'"${coord_recorded_voided_json:-[]}")" \
      "$eligible_items_json" "$refinement_policy_json" "${coordinator_fit_trimmed_json:-[]}")"
  fi
  unaccounted_n="$(jq 'length' <<<"$unaccounted_json" 2>&1)" \
    || { guard_warn "unaccounted_n" "$unaccounted_n"; unaccounted_n=0; }
  # Requirement 3x's band tag: the same rejection, split by the band it was
  # rejected over, so a fleet reading requirement 3w's rate can tell "the
  # model keeps confabulating the issues band away" from "it keeps forgetting
  # to void superseded Dependabot conflicts" without re-deriving either from
  # the `unaccounted` refs. One `corroboration` per verdict still, never one
  # per band: the rate's unit is the verdict (requirement 3w), and a
  # per-band event would inflate its denominator by however many bands a
  # cycle happened to have work in.
  unaccounted_bands_json="$(jq -c 'group_by(.source)
    | map({key: (.[0].source // ""), value: length}) | from_entries' \
    <<<"$unaccounted_json" 2>&1)" \
    || { guard_warn "unaccounted_bands_json" "$unaccounted_bands_json"; unaccounted_bands_json='{}'; }

  # Requirement 3w (issue #319): what every verdict this cycle records owes
  # the rate. Requirement 3v's `corroboration` events already carry the
  # Script's own `eligible_total`, which is the denominator; what neither they
  # nor `none-selected` carried is *which model produced the verdict*, and
  # without that the fleet cannot tell a rate that would justify changing
  # `coordinator_model` from one that would not. The only other record of this
  # cycle's Co-Ordinator model is its `stage-end` metering — a per-verdict
  # join for any reader — or its transcript, which is retained on an entirely
  # different schedule from the log.
  #
  # `coordinator_model` is the id the stage was *invoked* with, not a key of
  # the envelope's `modelUsage` map, for the reason lib/metering.sh gives for
  # making the same choice: the invocation id is the thing an operator sets
  # and the thing `stage-end` already records, while `modelUsage` names
  # whatever the session actually reached for — including a subagent's model —
  # so keying on it would split one setting's rate across several labels and
  # disagree with every other record of the same run. Both attempts run under
  # the same id (`run_coordinator_stage_attempt` above), so the retry's own
  # verdict is attributed to the same model that produced the first.
  coord_model_json="$(jq -nc --arg m "$coordinator_model" '{coordinator_model: $m}')"

  # The fingerprint recorded here is the one taken *before* the Co-Ordinator
  # ran, which is the only correct choice. Anything that changed while it was
  # working is, by definition, something it may not have seen — so it must be
  # allowed to change the fingerprint and buy the next cycle a fresh look. A
  # fingerprint taken now would absorb that change and skip on it.
  #
  # An empty fingerprint is omitted, not stored: the next cycle must find no
  # fingerprint here rather than an empty one it might match against an equally
  # empty sample of its own (see gather-source-state.sh). A verdict this cycle
  # found to contradict the Script's own eligible count, in any band, is
  # omitted the same way and for the same reason a failed sample is unfingerprintable
  # (requirement 3b's "a sample that failed is not a sample"): a wrong
  # `none-selected` cemented into the fingerprint would freeze the fleet on
  # that wrong answer until `none_selected_recheck_hours` forced a recheck —
  # which is exactly what held the whole fleet down for a full day on
  # 2026-08-11. Rejecting the fingerprint here instead means the very next
  # cycle asks again, unconditionally.
  if (( unaccounted_n == 0 )); then
    if (( eligible_items_total > 0 )); then
      log_event "corroboration" "$(jq -nc --argjson a 1 --arg v "accepted" --argjson total "$eligible_items_total" \
        --argjson m "$coord_model_json" '{attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: 0} + $m')"
    fi
    # `eligible_total` rides the `none-selected` too, and on every branch
    # below (requirement 3w): a cycle whose bands were genuinely empty logs no
    # `corroboration` at all, so without the figure here a reader cannot tell
    # "nothing was eligible" — which is a clean verdict with no rate to be
    # part of — from an event written before any of this existed.
    log_event "none-selected" "$(jq -nc --arg r "$reason" --arg f "$noop_fingerprint_value" \
      --argjson total "$eligible_items_total" --argjson m "$coord_model_json" \
      '{reason: $r} + (if $f == "" then {} else {fingerprint: $f} end) + {eligible_total: $total} + $m')"
    return 1
  fi

  # requirement 4g (TD-PPagop-26081401): $unaccounted_json is the unaccounted
  # eligible items carried whole out of the pre-fetched bands, unbounded past
  # this jq call, so it arrives on stdin — the only unbounded value at each
  # call site, everything else (n, total, bands, reason, model fields) stays
  # bounded by configuration and travels as --arg/--argjson as before.
  log_event "warning" "$(jq -nc --argjson n "$unaccounted_n" --argjson total "$eligible_items_total" \
    --argjson bands "$unaccounted_bands_json" --arg r "$reason" \
    'input as $items | {detail: ("verdict contradiction: the Script found " + ($total | tostring)
               + " eligible item(s) across the pre-fetched bands (unclaimed, unblocked, not void), but "
               + ($n | tostring)
               + " of them — " + (($bands | to_entries | map(.key + " " + (.value | tostring)) | join(", ")))
               + " — were neither selected, covered by a needs_refinement report the Script"
               + " recorded under that item'"'"'s own source, nor by a voided entry it disposed of this cycle"
               + " — the Co-Ordinator'"'"'s stated reason (\"" + $r + "\") does not account for them"),
      eligible_total: $total, bands: $bands, unaccounted: $items}' <<<"$unaccounted_json")"
  log_event "corroboration" "$(jq -nc --argjson a 1 --arg v "rejected" --argjson total "$eligible_items_total" \
    --argjson n "$unaccounted_n" --arg r "$reason" \
    --argjson bands "$unaccounted_bands_json" --argjson m "$coord_model_json" \
    'input as $items | {attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: $n, bands: $bands, unaccounted: $items, reason: $r} + $m' <<<"$unaccounted_json")"

  # --- 5a-retry. One re-prompt, quoting the contradiction (requirement 3v, issue #321) ---
  # A confabulated `none-selected` costs the Script nothing to detect (above),
  # but until now it still cost the whole cycle: the fingerprint stays
  # unarmed (so the *next* cycle asks again unconditionally — #314's fix for
  # #310's day-long freeze), but this cycle itself still stood down. If the
  # model's confabulation is persistent rather than a one-off — #310 showed
  # the same wrong verdict recurring across cycles and nodes — the fleet
  # degrades into a warning-per-cycle loop with zero selections: visible on
  # the log, but liveness still depends entirely on the model eventually
  # getting it right. This retry, and the fallback selection below when it
  # too fails corroboration, are what stop that dependency: a rejected
  # verdict now costs at most one extra Co-Ordinator engagement, never the
  # cycle.
  #
  # Same model, same base prompt, plus an addendum stating the Script's own
  # arithmetic and naming exactly which eligible items the first verdict left
  # unaccounted — the contradiction itself, not a generic "try again", on the
  # theory that the failure mode is pattern-matching against a band
  # description rather than reading it, and a pointed, specific contradiction
  # is what breaks that pattern. One retry only: the retry's own verdict,
  # corroborated or not, is never itself retried.
  coord_recorded_refinement_json_1="${coord_recorded_refinement_json:-[]}"
  coord_recorded_voided_json_1="${coord_recorded_voided_json:-[]}"
  # Grouped by band, and each ref given with its repo and its source token,
  # because the addendum's whole theory is specificity: the retry has to know
  # which array a given ref belongs to before it can issue a per-item verdict
  # for it, and `needs_refinement` is only an account when its `source`
  # matches the band the item was eligible in (unaccounted_items above).
  unaccounted_refs="$(jq -r 'group_by(.source)
    | map("- `" + (.[0].source // "") + "`: "
          + ([.[] | ((.repo // "") + " " + (.item // ""))] | join(", ")))
    | join("\n")' <<<"$unaccounted_json" 2>/dev/null || printf '(unavailable)')" # TD-PPagop-26081407: passes test 2 -- "(unavailable)" is not English text a real band summary could ever produce, so a reader can never mistake it for content
  coordinator_retry_prompt="$coordinator_prompt

## Corroboration retry — your previous verdict this cycle was rejected

Your final message a moment ago in this same cycle reported \`\"selected\": false\`
with reason: \"$reason\"

The Script independently counts $eligible_items_total eligible item(s) across
the bands it pre-fetched for you this cycle (unclaimed, unblocked, not void,
and listed in that repo's own \`sources\`). Your verdict accounted for only
$(( eligible_items_total - unaccounted_n )) of them, via \`needs_refinement\`
(under the item's own \`source\`) or \`voided\`. The remaining $unaccounted_n
item(s) were neither selected, reported, nor voided, and are still unaccounted
for, by band:

$unaccounted_refs

This is your one retry for this cycle. Issue a per-item verdict for every item
named above — add it to \`needs_refinement\` (with all five required fields, and
\`source\` set to the band it is listed under above) or to \`voided\` (with
\`evidence\`) — or select one of them, or any other eligible candidate, in
\`candidates\`. Send your entire final message exactly as before: one JSON
object, nothing else.
"
  coordinator_retry_out="$cycle_dir/coordinator-retry.out"
  if ! run_coordinator_stage_attempt "$coordinator_retry_out" "$coordinator_retry_prompt" '{"retry": true}'; then
    # The retry engagement itself failed to launch or never produced a
    # parseable message — run_coordinator_stage_attempt already logged
    # attempt-failed/handle_stage_failure for it. That is a different failure
    # mode from a rendered-but-uncorroborated verdict (network, rate limit, a
    # wedged session), so it does not reach fallback selection below — the
    # ordinary attempt-failed handling already in place is this cycle's
    # answer, same as it would be for the first attempt.
    return 1
  fi
  retry_work_order_json="$coord_attempt_result_json"
  retry_metering_json="$coord_attempt_metering_json"

  log_unblocked_items "$retry_work_order_json"
  log_recheck_clean_items "$retry_work_order_json"
  # Restricted to exactly the items the retry addendum named unaccounted: the
  # retry received the full runtime input again, so a `needs_refinement`/
  # `voided` entry it repeats for something the first attempt already
  # accounted for is not new information, and processing it again would
  # double the void-guard check, the refinement label, and any GitHub comment
  # either one posts. An item outside `unaccounted_json` was never asked
  # about, so an entry naming one is dropped the same way. Matched on the ref
  # alone, not on repo+item+source as the corroboration itself is: this filter
  # decides what gets *processed*, and a report the retry mis-attributes to
  # the wrong source is still a report about an item the addendum asked about
  # — recording it is right even though it will not account for anything.
  # requirement 4g (TD-PPagop-26081401): $unaccounted_json is the same
  # unbounded aggregate site 3's log_event calls above deliver on stdin — a
  # fifth consumer in this same function, previously still riding in as an
  # --argjson. Unguarded, so past MAX_ARG_STRLEN this used to die the whole
  # cycle under set -e rather than degrade. On a jq failure here, falling
  # back to the unfiltered retry_work_order_json costs at most some
  # redundant void-guard/refinement-label processing for an item attempt 1
  # already accounted for — never the silent loss a fallback to "nothing
  # filtered" would risk.
  retry_filter_docs="$(printf '%s\n' "$retry_work_order_json" "$unaccounted_json")"
  retry_work_order_filtered_json="$(jq -nc '
    input as $wo | input as $unaccounted
    | ($unaccounted | map(.item | tostring)) as $u
    | $wo + {
        needs_refinement: (($wo.needs_refinement // []) | map(select((.item | tostring) as $i | $u | index($i) != null))),
        voided: (($wo.voided // []) | map(select((.item | tostring) as $i | $u | index($i) != null)))
      }
    ' <<<"$retry_filter_docs" 2>/dev/null || printf '%s' "$retry_work_order_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unfiltered work order, a value the caller already accepted, not a fabricated empty
  log_voided_items "$retry_work_order_filtered_json" "$ordered_repos_json"
  log_needs_refinement_items "$retry_work_order_filtered_json"

  retry_selected="$(jq -r '.selected' <<<"$retry_work_order_json")"
  retry_reason="$(jq -r '.reason // "no reason given"' <<<"$retry_work_order_json")"
  # Both grow with the cycle's whole recorded band across both attempts —
  # unbounded past this call, never argv (requirement 4g, TD-PPagop-26081406):
  # each pair arrives on stdin, bound positionally with `input as $name` in
  # the order printed.
  recorded_refinement_all_json="$(jq -nc 'input as $a | input as $b | $a + $b' \
    <<<"$coord_recorded_refinement_json_1"$'\n'"${coord_recorded_refinement_json:-[]}")"
  recorded_voided_all_json="$(jq -nc 'input as $a | input as $b | $a + $b' \
    <<<"$coord_recorded_voided_json_1"$'\n'"${coord_recorded_voided_json:-[]}")"

  if [[ "$retry_selected" == "true" ]]; then
    # `eligible_total` here too (requirement 3w): this verdict is one the
    # retry got right, and a denominator that counted only the verdicts still
    # phrased as `none-selected` would credit the recovery to nobody and
    # overstate every model that ever recovers this way.
    log_event "corroboration" "$(jq -nc --argjson a 2 --arg v "accepted-by-selection" --argjson m "$retry_metering_json" \
      --argjson total "$eligible_items_total" --argjson cm "$coord_model_json" \
      '{attempt: $a, verdict: $v, eligible_total: $total} + $m + $cm')"
    # The retry's own work order — an ordinary model selection, no different
    # from one the first attempt could have made — is what the caller feeds
    # "5b. Candidates, and the claim" once this returns 0.
    work_order_json="$retry_work_order_json"
    selected="true"
    return 0
  fi

  # $nr/$v are the same unbounded recorded-band aggregates as the first
  # attempt's build above — stdin, never argv (requirement 4g,
  # TD-PPagop-26081406).
  unaccounted_retry_json="$(unaccounted_items \
    "$(jq -nc 'input as $nr | input as $v | {needs_refinement: $nr, voided: $v}' \
        <<<"$recorded_refinement_all_json"$'\n'"$recorded_voided_all_json")" \
    "$eligible_items_json" "$refinement_policy_json" "${coordinator_fit_trimmed_json:-[]}")"
  unaccounted_retry_n="$(jq 'length' <<<"$unaccounted_retry_json" 2>&1)" \
    || { guard_warn "unaccounted_retry_n" "$unaccounted_retry_n"; unaccounted_retry_n=0; }
  unaccounted_retry_bands_json="$(jq -c 'group_by(.source)
    | map({key: (.[0].source // ""), value: length}) | from_entries' \
    <<<"$unaccounted_retry_json" 2>&1)" \
    || { guard_warn "unaccounted_retry_bands_json" "$unaccounted_retry_bands_json"; unaccounted_retry_bands_json='{}'; }

  if (( unaccounted_retry_n == 0 )); then
    log_event "corroboration" "$(jq -nc --argjson a 2 --arg v "accepted" --argjson total "$eligible_items_total" \
      --argjson m "$retry_metering_json" --argjson cm "$coord_model_json" \
      '{attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: 0} + $m + $cm')"
    log_event "none-selected" "$(jq -nc --arg r "$retry_reason" --arg f "$noop_fingerprint_value" \
      --argjson total "$eligible_items_total" --argjson m "$coord_model_json" \
      '{reason: $r} + (if $f == "" then {} else {fingerprint: $f} end) + {eligible_total: $total} + $m')"
    return 1
  fi

  # requirement 4g (TD-PPagop-26081401): $unaccounted_retry_json is the same
  # shape as $unaccounted_json above, and just as unbounded, so it too
  # arrives on stdin rather than as an --argjson.
  log_event "warning" "$(jq -nc --argjson n "$unaccounted_retry_n" --argjson total "$eligible_items_total" \
    --argjson bands "$unaccounted_retry_bands_json" --arg r "$retry_reason" \
    'input as $items | {detail: ("verdict contradiction (retry): the Script found " + ($total | tostring)
               + " eligible item(s) across the pre-fetched bands, but " + ($n | tostring)
               + " — " + (($bands | to_entries | map(.key + " " + (.value | tostring)) | join(", ")))
               + " — remain unaccounted for after the one retry this cycle allows"
               + " — the Co-Ordinator'"'"'s retried reason (\"" + $r + "\") does not account for them"),
      eligible_total: $total, bands: $bands, unaccounted: $items}' <<<"$unaccounted_retry_json")"
  log_event "corroboration" "$(jq -nc --argjson a 2 --arg v "rejected" --argjson total "$eligible_items_total" \
    --argjson n "$unaccounted_retry_n" --arg r "$retry_reason" \
    --argjson bands "$unaccounted_retry_bands_json" \
    --argjson m "$retry_metering_json" --argjson cm "$coord_model_json" \
    'input as $items | {attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: $n, bands: $bands, unaccounted: $items, reason: $r} + $m + $cm' <<<"$unaccounted_retry_json")"

  # --- 5a-fallback. Deterministic selection (requirement 3v, issue #321) ---
  # Both engagements this cycle failed to corroborate a `none-selected`
  # against bands the Script itself can already see are
  # non-empty (`eligible_items_total > 0` is what let the gate reject a
  # verdict at all). Liveness now stops depending on the model: the Script
  # picks mechanically, through the same create-only claim race any
  # model-ranked candidate goes through (requirement 17a, in the caller) — a
  # possibly-suboptimal pick is strictly better than a frozen fleet.
  #
  # The twice-rejected verdict is fully on the record by this point — two
  # `warning`s and two `corroboration` events, the second carrying the
  # retry's own `reason` — so it is deliberately *not* also written as a
  # `none-selected` before the pick is attempted. `none-selected` names a
  # cycle's outcome, not a verdict: every other reader treats it that way,
  # from requirement 3b's fingerprint to the dashboard's own outcome ladder
  # (`scripts/publish-dashboard.sh`, where it outranks both `selection` and
  # `stand-down`), so a cycle that logged one *and* went on to select would
  # render as "Nothing selected" — reporting the recovery as the failure it
  # recovered from, and undercounting fallback picks for issue #319's
  # metrics. It is logged below instead, on the one branch where the cycle
  # really does select nothing.
  fallback_candidate_json="$(fallback_select_candidate "$ordered_repos_json" \
    "$implementer_model_default" "$refinements_json" "$refinement_policy_json" "$pr_label")"
  if [[ -z "$fallback_candidate_json" || "$fallback_candidate_json" == "null" ]]; then
    # Not observed in practice (see fallback_select_candidate's own comment
    # for the guarantee this would defy), but fail closed rather than assume
    # it away: nothing to claim, so stand down exactly as an ordinary
    # corroboration rejection would — including requirement 3t's un-armed
    # fingerprint, which a rejected verdict is denied however the cycle ends.
    # `td_verdict_rejected` keeps its name though the gate is no longer
    # tech-debt-only (requirement 3x): it is what every reader of this event
    # already keys on — `scripts/publish-dashboard.sh`'s verdict-quality
    # aggregate, and every such event already in the retained log — and a
    # rename would silently zero the rejection count for the history it can
    # still see. `bands` carries what the name no longer says.
    log_event "none-selected" "$(jq -nc --arg r "$retry_reason" \
      --argjson total "$eligible_items_total" --argjson bands "$unaccounted_retry_bands_json" \
      --argjson m "$coord_model_json" \
      '{reason: $r, td_verdict_rejected: true, retried: true, eligible_total: $total, bands: $bands} + $m')"
    return 1
  fi
  candidates_json="$(jq -c '[.]' <<<"$fallback_candidate_json")"
  selected_by_fallback=1
  selected="true"
  work_order_json="$fallback_candidate_json"
  return 0
}
