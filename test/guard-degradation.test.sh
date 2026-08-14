#!/usr/bin/env bash
#
# test/guard-degradation.test.sh — regression tests for TD-PPagop-26081407:
# a guarded call site (`cmd 2>&1)" || { guard_warn ...; var=fallback; }`)
# reports on the union log when its guarded command fails, instead of
# silently substituting the same literal it always did. The fallback itself
# is never touched by this item — only the silence around it — so every
# assertion below checks both halves: the `guard-degraded` event fired, and
# the caller-visible value is exactly what it was before this item.
#
# `guard_warn`, `stage_budget_overrides`, `gather_claimed`,
# `unaccounted_items` and `coordinator_eligible_items` are lifted whole out
# of agent-cycle.sh with awk, the same technique test/verdict-corroboration.
# test.sh and test/pr-claim-exclusion.test.sh use for the same reason: this
# cannot pass against a paraphrase of the real function.
#
# Coverage here is representative, not the full 67-site sweep TD-PPagop-
# 26081407 converted: the guard shape is mechanically identical everywhere
# (capture stdout+stderr, guard_warn on failure, restore the untouched
# fallback), so this file exercises `guard_warn` itself once, then the
# handful of standalone functions and the one inline block (the fleet
# stand-down date parse) whose failure carries the most consequence — a
# false zero there silently lets the fleet run through an active usage-limit
# cooldown. The full test suite staying green after this item's mechanical
# sweep (no fallback value changed) is what backstops the rest.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/guard-degradation.test.sh
#
# Exit status is 0 iff every assertion passed.

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

# --- Lift the functions under test whole out of agent-cycle.sh -------------
extract_function() {  # extract_function <name>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$SCRIPT_DIR/agent-cycle.sh"
}

log_event_src="$(extract_function log_event)"
guard_warn_src="$(extract_function guard_warn)"
stage_budget_overrides_src="$(extract_function stage_budget_overrides)"
gather_claimed_src="$(extract_function gather_claimed)"
unaccounted_items_src="$(extract_function unaccounted_items)"
coordinator_eligible_items_src="$(extract_function coordinator_eligible_items)"

for pair in \
  "log_event_src:log_event()" \
  "guard_warn_src:guard_warn()" \
  "stage_budget_overrides_src:stage_budget_overrides()" \
  "gather_claimed_src:gather_claimed()" \
  "unaccounted_items_src:unaccounted_items()" \
  "coordinator_eligible_items_src:coordinator_eligible_items()"; do
  name="${pair%%:*}"
  needle="${pair#*:}"
  if [[ "${!name}" != *"$needle"* ]]; then
    printf 'FAIL - could not extract %s from agent-cycle.sh (renamed or moved?)\n' "$needle"
    exit 1
  fi
done

eval "$log_event_src"
eval "$guard_warn_src"
eval "$stage_budget_overrides_src"
eval "$gather_claimed_src"
eval "$unaccounted_items_src"
eval "$coordinator_eligible_items_src"

# log_event's own dependencies, the same fixtures test/verdict-corroboration.
# test.sh and its siblings use.
cycle_id="test-cycle"
node_name="test-node"
log_file="$tmp_dir/log.jsonl"
: > "$log_file"

last_guard_events() {  # every guard-degraded event this run wrote
  jq -c 'select(.event == "guard-degraded")' "$log_file"
}

# =================================================================================
# guard_warn / log_event
# =================================================================================

: > "$log_file"
guard_warn "some:site" "jq: error (at <stdin>:0): whatever broke"
n_events="$(jq -s 'length' "$log_file")"
assert_eq "guard_warn writes exactly one event" "1" "$n_events"
assert_eq "…tagged guard-degraded" "guard-degraded" "$(jq -r '.event' "$log_file")"
assert_eq "…naming the site" "some:site" "$(jq -r '.site' "$log_file")"
assert_eq "…carrying the captured failure text as detail" "jq: error (at <stdin>:0): whatever broke" \
  "$(jq -r '.detail' "$log_file")"
assert_eq "…stamped with this cycle's id" "test-cycle" "$(jq -r '.cycle' "$log_file")"

# =================================================================================
# stage_budget_overrides — CONFIG_FILE read off disk (test 1: external;
# test 2: {} is what a healthy unconfigured file also answers)
# =================================================================================

: > "$log_file"
CONFIG_FILE="$tmp_dir/does-not-exist.json"
out="$(stage_budget_overrides implementor "org/repo")"
assert_eq "a missing CONFIG_FILE still yields the documented {} fallback" "{}" "$out"
assert_eq "…and the read failure is reported" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "stage_budget_overrides" "$(last_guard_events | jq -r '.site')"

: > "$log_file"
CONFIG_FILE="$tmp_dir/config.json"
printf '{"repos": [{"slug": "org/repo", "stage_timeouts": {"implementor": 42}}]}' > "$CONFIG_FILE"
out="$(stage_budget_overrides implementor "org/repo")"
assert_eq "a healthy CONFIG_FILE is read normally" "42" "$(jq -r '.backstop' <<<"$out")"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"

# =================================================================================
# gather_claimed — the fleet's active claims for one repo, still delivered to
# jq as --argjson (test 1: MAX_ARG_STRLEN, the kernel's 131072-byte per-argv-
# entry cap, the same mechanism the 2026-08-12 outage hit); test 2: [] reads
# exactly like "this repo has no claims", which the caller uses to decide
# whether a candidate is already claimed.
# =================================================================================

fake_claim_sh() {  # writes a lib/claim.sh stand-in that answers a big fixture
  cat > "$tmp_dir/claim.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  claims) cat "$CLAIM_SH_FIXTURE" ;;
  branches) echo '[]' ;;
esac
STUB
  chmod +x "$tmp_dir/claim.sh"
}
fake_claim_sh
mkdir -p "$tmp_dir/lib"
cp "$tmp_dir/claim.sh" "$tmp_dir/lib/claim.sh"

real_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="$tmp_dir"
cycle_dir="$tmp_dir"
branch_prefix="agent/"

big_registry="$(jq -nc '[range(1300) | {item: ("TD-fill-" + (. | tostring)),
  age_hours: 1, pr_number: null, detail: ("pad " + ("x" * 100))}]')"
assert_eq "the oversized claims fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_registry" | wc -c) > 131072 ))"

CLAIM_SH_FIXTURE="$tmp_dir/big-registry.json"
printf '%s' "$big_registry" > "$CLAIM_SH_FIXTURE"
export CLAIM_SH_FIXTURE

: > "$log_file"
out="$(gather_claimed "org/repo")"
assert_eq "a claims registry past the argv cap still falls back to []" "[]" "$out"
assert_eq "…and the argv failure is reported, not swallowed" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "gather_claimed:org/repo" "$(last_guard_events | jq -r '.site')"

CLAIM_SH_FIXTURE="$tmp_dir/small-registry.json"
printf '[{"item": "TD1", "age_hours": 1, "pr_number": null}]' > "$CLAIM_SH_FIXTURE"
: > "$log_file"
out="$(gather_claimed "org/repo")"
assert_eq "a normal-sized claims registry is read whole" "TD1" "$(jq -r '.[0].item' <<<"$out")"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"
SCRIPT_DIR="$real_script_dir"

# =================================================================================
# unaccounted_items — this is the guard the 2026-08-14 outage went through:
# an execve failure here read as "everything is accounted for" and the
# Script corroborated a none-selected verdict silently.
# =================================================================================

: > "$log_file"
out="$(unaccounted_items 'not json' '[{"repo":"o/r","item":"TD1","source":"tech-debt"}]' '{}')"
assert_eq "malformed recorded-json still falls back to []" "[]" "$out"
assert_eq "…and the failure is reported" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "unaccounted_items" "$(last_guard_events | jq -r '.site')"

: > "$log_file"
out="$(unaccounted_items '{"needs_refinement":[],"voided":[]}' \
  '[{"repo":"o/r","item":"TD1","source":"tech-debt"}]' '{}')"
assert_eq "a well-formed input still names the unaccounted item" "TD1" "$(jq -r '.[0].item' <<<"$out")"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"

# =================================================================================
# coordinator_eligible_items — the Co-Ordinator's own eligible-set
# denominator; a jq failure reading as [] would silently tell the fleet
# nothing was ever selectable.
# =================================================================================

: > "$log_file"
# A bare-scalar element passes the function's own `type == "array"` sanity
# check (it *is* an array) but breaks inside the pipeline itself (`.slug` on
# a number), which is the failure mode the pre-check at the top of the
# function cannot catch — the one this item's guard is for.
out="$(coordinator_eligible_items '[1,2,3]' '[]')"
assert_eq "an array of non-objects still falls back to []" "[]" "$out"
assert_eq "…and the failure is reported" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "coordinator_eligible_items" "$(last_guard_events | jq -r '.site')"

: > "$log_file"
ordered='[{"slug":"o/r","sources":["tech-debt"],"tech_debt":[{"ref":"TD1"}]}]'
out="$(coordinator_eligible_items "$ordered" '[]')"
assert_eq "a well-formed input still names the eligible item" "TD1" "$(jq -r '.[0].item' <<<"$out")"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"

# =================================================================================
# The fleet stand-down date parse (main cycle path, not --status) — lifted by
# its own start/end markers rather than a function signature, the same
# technique test/pr-claim-exclusion.test.sh uses for the stale-ref block: the
# gate this feeds decides whether the whole fleet stands down for an active
# limit, so a false "already expired" here is the highest-stakes single site
# this item touches.
# =================================================================================

resume_block_src="$(awk '
    /^resume_epoch=0$/ { on = 1 }
    on                 { print }
    on && /^fi$/        { exit }
  ' "$SCRIPT_DIR/agent-cycle.sh")"
if [[ "$resume_block_src" != *"resume_epoch"* ]]; then
  printf 'FAIL - could not extract the resume_epoch block from agent-cycle.sh (moved or reworded?)\n'
  exit 1
fi

run_resume_block() {  # run_resume_block <resume_at>
  resume_at="$1"
  eval "$resume_block_src"
  printf '%s' "$resume_epoch"
}

: > "$log_file"
out="$(run_resume_block 'not a date')"
assert_eq "an unparseable resume_at still falls back to epoch 0" "0" "$out"
assert_eq "…and the date-parse failure is reported, not swallowed" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "cycle:resume_epoch" "$(last_guard_events | jq -r '.site')"

: > "$log_file"
out="$(run_resume_block '2026-08-14T00:00:00Z')"
assert_eq "a well-formed resume_at is parsed normally" "1786665600" "$out"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"

echo "----------------------------------------"
if (( failures == 0 )); then
  echo "All assertions passed."
  exit 0
else
  echo "$failures assertion(s) failed."
  exit 1
fi
