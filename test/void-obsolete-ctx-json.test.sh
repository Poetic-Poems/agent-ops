#!/usr/bin/env bash
#
# test/void-obsolete-ctx-json.test.sh — regression test for
# `void_obsolete_ctx_json` (agent-cycle.sh), the function every
# `void_guard_reason` call site (Co-Ordinator, Enabler, Implementor) hands it
# as CTX_JSON for the machine `obsolete` alternative (design doc §5.5, issue
# #413, WI-10).
#
# Issue #507 (follow-up to PR #501's automated review, concern 1): every
# existing test that reaches a `void_guard_reason` call site stubs this
# function out (`test/enabler-verdicts.test.sh`, `test/coordinator-retry-
# fallback.test.sh`, `test/verdict-corroboration.test.sh`), and
# `test/void-guard.test.sh` builds its ctx objects by hand — the right split
# for those files, since none of them is testing this function's own wiring.
# The net effect was that the one link in the WI-10 chain that touches
# config, the kill switch and the log was the one link nothing exercised.
# Its failure mode is silent and looks safe: a `set -u` unbound global, a
# wrong argument order into `merge_autonomy_effective_level`, or malformed
# JSON all degrade to an empty ctx, which `void_draft_obsolete_flag_reason`
# reads as "not agent-merges-all" and refuses — indistinguishable from the
# whole machine `obsolete` alternative being dead in production while the
# suite stays green.
#
# This file lifts the real function (the `extract_fn` pattern
# test/enabler-verdicts.test.sh already uses) and wires in its two real
# dependencies rather than stubbing them: `merge_autonomy_effective_level`
# (lib/merge-autonomy.sh) behind a `gh` stub backed by an empty directory —
# every fleet flag reads as absent, so the configured level passes straight
# through — and `draft_obsolete_flags` (lib/cycle-state.sh) over a temp log
# carrying one `draft-obsolete-flagged` event.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/void-obsolete-ctx-json.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/merge-budget.sh
. "$SCRIPT_DIR/lib/merge-budget.sh"
# shellcheck source=lib/merge-autonomy.sh
. "$SCRIPT_DIR/lib/merge-autonomy.sh"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"

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

# --- Lift void_obsolete_ctx_json verbatim ---
#
# Lifted, not restated: this cannot pass against a copy the script has since
# moved on from, the same guarantee test/enabler-verdicts.test.sh's own lift
# of maybe_run_enabler gives it.
extract_fn() {
  local start_pat="$1" file="$2"
  awk -v start="$start_pat" '
    $0 == start { on = 1 }
    on          { print }
    on && /^}$/ { exit }
  ' "$file"
}

void_obsolete_ctx_json_fn="$(extract_fn 'void_obsolete_ctx_json() {' "$SCRIPT_DIR/agent-cycle.sh")"
if [[ "$void_obsolete_ctx_json_fn" != *"merge_autonomy_effective_level"* ]]; then
  printf 'FAIL - void_obsolete_ctx_json could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
eval "$void_obsolete_ctx_json_fn"

# --- A gh stub backed by an empty directory: every fleet flag reads absent ---
#
# The same stub-gh-backed-by-a-directory pattern test/merge-autonomy.test.sh
# uses. With the backing directory empty, every flag-file fetch 404s and
# every repo-existence probe (the kill switch's own `probe-404` disambiguator)
# succeeds, so both the kill switch and the merge-budget freeze flag read as
# their default "enabled" (i.e. not tripped, not frozen) state and
# merge_autonomy_effective_level falls straight through to the configured
# level — exactly what lets this test assert that value came out the far end
# of the real function, not a hand-typed one.
gh_backing="$tmp_dir/fleet-remote"
mkdir -p "$gh_backing"
gh_stub="$tmp_dir/gh-stub"
cat > "$gh_stub" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
backing="${GH_STUB_BACKING:?}"
path=""
for a in "$@"; do
  case "$a" in
    repos/*) path="$a" ;;
  esac
done
if [[ "$path" == repos/*/* && "$path" != */contents/* ]]; then
  echo '{}'
  exit 0
fi
rel="${path#repos/*/*/contents/}"; rel="${rel%%\?*}"
file="$backing/$rel"
[[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -n --arg c "$(base64 -w0 < "$file")" '{content: $c}'
STUB
chmod +x "$gh_stub"
export TOGGLE_GH="$gh_stub" GH_STUB_BACKING="$gh_backing"

# --- Globals void_obsolete_ctx_json reads ---
# shellcheck disable=SC2034
DEFAULTED_CONFIG='{"merge_autonomy": "agent-merges-all"}'
# shellcheck disable=SC2034
state_repo="example/agent-ops-state"
state_dir="$tmp_dir/state"
# shellcheck disable=SC2034
cycle_id="20260817T090000Z-test-1"

slug="acme/widgets"

# --- One draft-obsolete-flagged event, read via the real draft_obsolete_flags ---
log_with_flag="$tmp_dir/log.jsonl"
cat > "$log_with_flag" <<JSONL
{"ts":"2026-08-16T10:00:00Z","cycle":"20260816T100000Z-node-1","node":"node-1","event":"draft-obsolete-flagged","repo":"acme/widgets","item":"TD26081601","pr":250,"evidence":"landed under PR #260"}
JSONL

expected_flags='[{"repo":"acme/widgets","item":"TD26081601","pr":250,"evidence":"landed under PR #260","cycle":"20260816T100000Z-node-1","node":"node-1","ts":"2026-08-16T10:00:00Z"}]'

# --- union_log set: the ordinary case ---
# shellcheck disable=SC2034
union_log="$log_with_flag"
# shellcheck disable=SC2034
log_file="$tmp_dir/log.jsonl.should-not-be-read"

before_epoch="$(date -u +%s)"
ctx="$(void_obsolete_ctx_json "$slug")"
after_epoch="$(date -u +%s)"

assert_eq "merge_autonomy_level is the real function's answer" "agent-merges-all" \
  "$(jq -r '.merge_autonomy_level' <<<"$ctx")"
assert_eq "cycle carries the current cycle id" "$cycle_id" \
  "$(jq -r '.cycle' <<<"$ctx")"
now_epoch="$(jq -r '.now_epoch' <<<"$ctx")"
now_epoch_is_numeric=0
[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch_is_numeric=1
assert_eq "now_epoch is numeric" "0" "$now_epoch_is_numeric"
assert_eq "now_epoch falls within the call's own window" "1" \
  "$(( now_epoch >= before_epoch && now_epoch <= after_epoch ))"
assert_eq "flags carries the union log's draft-obsolete-flagged event" "$expected_flags" \
  "$(jq -c '.flags' <<<"$ctx")"

# --- union_log unset: must fall back to log_file, not crash under set -u ---
unset union_log
# shellcheck disable=SC2034
log_file="$log_with_flag"

ctx_fallback="$(void_obsolete_ctx_json "$slug")"
rc=$?
assert_eq "the fallback call does not crash under set -u" "0" "$rc"
assert_eq "flags come off log_file when union_log is unset" "$expected_flags" \
  "$(jq -c '.flags' <<<"$ctx_fallback")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
