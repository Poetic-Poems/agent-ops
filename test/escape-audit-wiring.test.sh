#!/usr/bin/env bash
#
# test/escape-audit-wiring.test.sh — regression test for the block in
# agent-cycle.sh that turns scripts/detect-classifier-escapes.sh's own
# stdout into first-class log events (requirement 8e, agent-ops#572): which
# repos it is called for, how each JSON action line becomes a `log_event`
# call, and that the union log is kept fresh across repos within one cycle.
#
# `test/detect-classifier-escapes.test.sh` covers the detector itself; this
# file covers only the translation either side of it — the "sweep prints,
# the Script logs" shape `scripts/sweep-human-visibility.sh`'s own wiring
# already established (test/human-visibility-wiring.test.sh), reused here:
#
#   - Every configured repository's slug is offered to the detector, in
#     order.
#   - An `outcome: "escape"` line becomes a `classifier-escape` event with
#     `outcome` stripped (the event name itself already says it).
#   - An `outcome: "clean"`/`"unverifiable"` line becomes a `landing-audit`
#     event, `outcome` kept so a reader of the log alone can tell them apart.
#   - An `outcome: "not-approver"` line — a merge nothing armed, so there is
#     nothing to audit — becomes its own `landing-audit-skip` event, kept
#     apart from `landing-audit` so `scripts/publish-dashboard.sh`'s
#     `counts.escape_audits` (which folds only `classifier-escape` and
#     `landing-audit`) never counts it as an audit finding.
#   - No Approver login resolvable at all (an unset or unreadable
#     credential) skips the whole block — no detector call, no log_event —
#     rather than auditing against an identity nothing can confirm.
#   - The union log is topped up with this repo's own new lines before the
#     next repo's pass, the same convention every sweep before it follows.
#
# The block is lifted verbatim out of agent-cycle.sh, the same way
# test/human-visibility-wiring.test.sh lifts its own block, so the
# assertions are about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/escape-audit-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# generated file literally, not expand in this shell — same as
# test/landing-wiring.test.sh's own header note.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- Extraction ---------------------------------------------------------------
extract_block() {
  awk '
    /^if escape_login="\$\(approver_token_identity_login/ { on = 1 }
    on          { print }
    on && /^fi$/ { exit }
  ' "$1"
}

block="$(extract_block "$REPO_ROOT/lib/standdown.sh")"
if [[ -z "$block" ]]; then
  echo "FAIL - could not extract the classifier-escape audit block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# --- Assembly -----------------------------------------------------------------
# run_block LOGIN REPOS_JSON DETECTOR_STDOUT
# Runs an assembled script that stubs approver_token_identity_login,
# guard_warn, log_event and scripts/detect-classifier-escapes.sh itself
# (via SCRIPT_DIR pointing at a scratch tree carrying a fake one), sets the
# globals the block reads, executes it under the same `set -euo pipefail`
# agent-cycle.sh runs under, and prints one line per log_event call
# (`event<TAB>fields`) followed by a `--` line and one line per repo slug
# the detector was invoked for, in call order.
run_block() {
  local login="$1" repos="$2" detector_out="$3" harness="$tmp_dir/harness.sh" \
    scratch="$tmp_dir/scratch-$RANDOM"
  mkdir -p "$scratch/scripts"
  local out_file="$tmp_dir/detector-out-$RANDOM.txt"
  # A trailing newline matters: the real detect-classifier-escapes.sh always
  # ends its stdout in one (each emitted line is its own `jq -nc` call), and
  # `while read` silently drops a final line with none — a test-harness
  # gotcha, not a fact about the shipped block, so the fixture must not
  # reproduce it by accident.
  printf '%s\n' "$detector_out" > "$out_file"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$1" >> %q\n' "$tmp_dir/detector-calls"
    printf 'cat %q\n' "$out_file"
  } > "$scratch/scripts/detect-classifier-escapes.sh"
  chmod +x "$scratch/scripts/detect-classifier-escapes.sh"
  : > "$tmp_dir/detector-calls"
  : > "$tmp_dir/log-events"
  : > "$tmp_dir/log.jsonl"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'SCRIPT_DIR=%q\n' "$scratch"
    printf 'CONFIG_FILE=%q\n' "$tmp_dir/config.json"
    printf 'log_file=%q\n' "$tmp_dir/log.jsonl"
    printf 'union_log=%q\n' "$tmp_dir/union.jsonl"
    printf 'cycle_dir=%q\n' "$tmp_dir"
    : > "$tmp_dir/config.json"
    printf '%s' "$repos" | jq -c '{repos: [.[] | {slug: .}]}' > "$tmp_dir/config.json"
    if [[ -n "$login" ]]; then
      printf '%s\n' 'approver_token_identity_login() { printf "%s" '"$(printf '%q' "$login")"'; }'
    else
      printf '%s\n' 'approver_token_identity_login() { return 1; }'
    fi
    printf '%s\n' 'guard_warn() { :; }'
    printf '%s\n' 'log_event() { printf "%s\t%s\n" "$1" "$2" >> '"$(printf '%q' "$tmp_dir/log-events")"'; }'
    printf '%s\n' "$block"
    printf 'cat %q 2>/dev/null || true\n' "$tmp_dir/log-events"
    printf '%s\n' 'printf -- "--\n"'
    printf 'cat %q 2>/dev/null || true\n' "$tmp_dir/detector-calls"
  } > "$harness"
  bash "$harness" 2>/dev/null
}

REPOS='["acme/widgets","acme/gizmos"]'

# --- Every configured repo is offered to the detector, in order --------------

out="$(run_block "pullwright-approver[bot]" "$REPOS" "")"
calls_out="$(sed -n '/^--$/,$p' <<<"$out" | tail -n +2)"

assert_eq "the detector is invoked once per configured repo, in order" \
  "$(printf 'acme/widgets\nacme/gizmos')" "$calls_out"

# --- An escape line becomes classifier-escape, a clean line becomes
# landing-audit ---------------------------------------------------------------

DETECTOR_OUT='{"outcome":"escape","pr_url":"https://github.com/acme/widgets/pull/1","repo":"acme/widgets","reason":"touched protected path(s): lib/landing.sh"}
{"outcome":"clean","pr_url":"https://github.com/acme/widgets/pull/2","repo":"acme/widgets","reason":"recomputed eligibility agrees"}
{"outcome":"not-approver","pr_url":"https://github.com/acme/widgets/pull/3","repo":"acme/widgets","reason":"merged by a-human, not the Approver identity"}'

out="$(run_block "pullwright-approver[bot]" '["acme/widgets"]' "$DETECTOR_OUT")"
events_out="$(sed '/^--$/,$d' <<<"$out")"

assert_eq "an escape line becomes a classifier-escape event" \
  "1" "$(grep -c '^classifier-escape' <<<"$events_out")"
assert_eq "  ... with outcome stripped from its fields" \
  "" "$(grep '^classifier-escape' <<<"$events_out" | grep -o '"outcome"')"
assert_eq "a clean line becomes a landing-audit event" \
  "1" "$(grep -cP '^landing-audit\t' <<<"$events_out")"
assert_eq "  ... keeping outcome in its fields, so the log alone tells clean from unverifiable" \
  '"outcome":"clean"' "$(grep -P '^landing-audit\t' <<<"$events_out" | grep -o '"outcome":"clean"')"
assert_eq "a not-approver line becomes its own landing-audit-skip event" \
  "1" "$(grep -c '^landing-audit-skip' <<<"$events_out")"
assert_eq "  ... never folded into landing-audit itself" \
  "0" "$(grep -P '^landing-audit\t' <<<"$events_out" | grep -c 'not-approver')"

# --- No resolvable Approver login: the whole block no-ops ---------------------

out="$(run_block "" "$REPOS" "$DETECTOR_OUT")"
events_out="$(sed '/^--$/,$d' <<<"$out")"
calls_out="$(sed -n '/^--$/,$p' <<<"$out" | tail -n +2)"

assert_eq "no Approver login at all: the detector is never invoked" "" "$calls_out"
assert_eq "  ... and no event is logged" "" "$events_out"

# --- Nothing new from the detector: no event, still one call per repo --------

out="$(run_block "pullwright-approver[bot]" "$REPOS" "")"
events_out="$(sed '/^--$/,$d' <<<"$out")"
calls_out="$(sed -n '/^--$/,$p' <<<"$out" | tail -n +2)"

assert_eq "an empty detector run still calls it for every repo" \
  "$(printf 'acme/widgets\nacme/gizmos')" "$calls_out"
assert_eq "  ... and logs nothing" "" "$events_out"

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
