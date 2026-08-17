#!/usr/bin/env bash
#
# test/refiner-priority-triage.test.sh — regression test for the Refiner's
# Priority triage duty and its one-way ratchet (D18 WI-11; agent-ops#414;
# requirement 39g).
#
# Three things have to hold, each covered in its own section below:
#
#   (A) the candidate rule (`refiner_candidate_items`, lib/refinement.sh) lets
#       an already-refined `issues` item back in when its `Priority` is
#       unset, marked `triage_only`, without loosening any of the existing
#       exclusions or letting an entry from before this field existed
#       (no `priority_set` key at all) slip through;
#   (B) the ratchet itself (`lib/issue-priority.sh`) resolves the field live,
#       re-reads the issue's current band immediately before writing, applies
#       only when unset or strictly outranked, skips rather than overwrites a
#       band outside the four names it can rank (agent-ops#509), and never
#       mistakes "cannot read the field" for "nothing to band";
#   (C) `maybe_run_refiner` (agent-cycle.sh) wires a verdict's `priority`
#       field to that ratchet independently of the refined/needs-refinement
#       outcome, honours `triage_only` (no corroboration required, no
#       item-refined, no label, and no block a decline could put on an
#       already-refined item), and never mutates anything under DRY_RUN;
#   (D) `scripts/doctor.sh`'s warning is gated on a test that a valid
#       configuration actually satisfies, rather than one that can never fire.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/refiner-priority-triage.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Section (C) below rebinds SCRIPT_DIR to its fake root — the lifted
# `maybe_run_refiner` reads it — so anything that still needs the real
# repository after that point reads this instead.
repo_root="$SCRIPT_DIR"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"
# ISSUE_PRIORITY_CACHE_DIR is set before sourcing lib/issue-priority.sh below
# (issue #510) — a subdirectory of tmp_dir, so the trap above reclaims it and
# the library's own source-time `mktemp -d` never runs at all.
ISSUE_PRIORITY_CACHE_DIR="$(mktemp -d "$tmp_dir/cache-init.XXXXXX")"
# shellcheck source=lib/issue-priority.sh
. "$SCRIPT_DIR/lib/issue-priority.sh"

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
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# ============================================================================
# (A) The candidate rule — refiner_candidate_items, requirement 39g
# ============================================================================

repos='[
  {"slug": "o/r",
   "issues": [
     {"source": "issues", "ref": "1", "title": "unbanded, already refined",
      "priority": "Medium", "priority_set": false},
     {"source": "issues", "ref": "2", "title": "banded, already refined",
      "priority": "High", "priority_set": true},
     {"source": "issues", "ref": "3", "title": "unbanded, not yet refined",
      "priority": "Medium", "priority_set": false},
     {"source": "issues", "ref": "4", "title": "pre-39g shape: no priority_set key at all",
      "priority": "Medium"},
     {"source": "issues", "ref": "5", "title": "unbanded, already refined, but blocked",
      "priority": "Medium", "priority_set": false},
     {"source": "issues", "ref": "6", "title": "unbanded, already refined, but claimed",
      "priority": "Medium", "priority_set": false}
   ],
   "merge_conflicts": [
     {"source": "merge-conflicts", "ref": "pr-1-conflict-abc", "title": "not issues, exempt anyway"}
   ]}
]'
policy='{"issues": "preferred"}'
refinements='{"o/r": {"1": {"ts": "2026-08-01T00:00:00Z", "comment_url": "https://x/1"},
                       "2": {"ts": "2026-08-01T00:00:00Z", "comment_url": "https://x/2"},
                       "4": {"ts": "2026-08-01T00:00:00Z", "comment_url": "https://x/4"},
                       "5": {"ts": "2026-08-01T00:00:00Z", "comment_url": "https://x/5"},
                       "6": {"ts": "2026-08-01T00:00:00Z", "comment_url": "https://x/6"}}}'
blocked='[{"repo": "o/r", "item": "5"}]'
claimed='[{"repo": "o/r", "item": "6"}]'

candidates="$(refiner_candidate_items "$repos" "$policy" "$refinements" "$blocked" '[]' "$claimed")"

assert_eq "an unbanded, already-refined issue is a candidate" "yes" \
  "$(jq -r 'any(.[]; .item == "1") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "  ... marked triage_only" "true" \
  "$(jq -r '.[] | select(.item == "1") | .triage_only' <<<"$candidates")"
assert_eq "a banded, already-refined issue is not a candidate" "no" \
  "$(jq -r 'any(.[]; .item == "2") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "an unbanded, unrefined issue is an ordinary candidate" "yes" \
  "$(jq -r 'any(.[]; .item == "3") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "  ... not marked triage_only (it needs a real specification too)" "null" \
  "$(jq -r '.[] | select(.item == "3") | .triage_only // "null"' <<<"$candidates")"
assert_eq "an entry with no priority_set key at all is not swept in by the triage rule" "no" \
  "$(jq -r 'any(.[]; .item == "4") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "an otherwise-triage-eligible issue stays excluded while blocked" "no" \
  "$(jq -r 'any(.[]; .item == "5") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "an otherwise-triage-eligible issue stays excluded while claimed" "no" \
  "$(jq -r 'any(.[]; .item == "6") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "a non-issues source is unaffected by the triage rule" "no" \
  "$(jq -r 'any(.[]; .source == "merge-conflicts") | if . then "yes" else "no" end' <<<"$candidates")"

# Policy exclusions still bind: an installation that turns `issues` fully
# exempt gets no triage candidates either, exactly as the item's own scope
# states ("the existing … policy exclusions still apply unchanged").
exempt_candidates="$(refiner_candidate_items "$repos" '{"issues":"exempt"}' "$refinements" '[]' '[]' '[]')"
assert_eq "exempt issues never triage-candidate, even unbanded and refined" "no" \
  "$(jq -r 'any(.[]; .item == "1") | if . then "yes" else "no" end' <<<"$exempt_candidates")"

# ============================================================================
# (A2) The pure filter — refiner_drop_unbandable_triage, issue #511
# ============================================================================
# A repository this token cannot resolve `Priority` for must never keep
# contributing `triage_only` candidates the Refiner can never band; every
# other candidate — from that repository or any other — is untouched.

triage_candidates_511='[
  {"repo":"o/r1","source":"issues","item":"1","triage_only":true},
  {"repo":"o/r1","source":"issues","item":"2","triage_only":true},
  {"repo":"o/r1","source":"issues","item":"3"},
  {"repo":"o/r2","source":"issues","item":"10","triage_only":true},
  {"repo":"o/r3","source":"issues","item":"20"}
]'

dropped="$(refiner_drop_unbandable_triage "$triage_candidates_511" '["o/r1"]')"
assert_eq "drops only the unresolvable slug's triage_only entries" "3" \
  "$(jq 'length' <<<"$dropped")"
assert_eq "  ... item 1 (o/r1, triage_only) is gone" "no" \
  "$(jq -r 'any(.[]; .item == "1") | if . then "yes" else "no" end' <<<"$dropped")"
assert_eq "  ... item 2 (o/r1, triage_only) is gone" "no" \
  "$(jq -r 'any(.[]; .item == "2") | if . then "yes" else "no" end' <<<"$dropped")"
assert_eq "  ... item 3 (o/r1, not triage_only) survives" "yes" \
  "$(jq -r 'any(.[]; .item == "3") | if . then "yes" else "no" end' <<<"$dropped")"
assert_eq "  ... item 10 (o/r2, triage_only, a different slug) survives" "yes" \
  "$(jq -r 'any(.[]; .item == "10") | if . then "yes" else "no" end' <<<"$dropped")"
assert_eq "  ... item 20 (o/r3, untouched) survives" "yes" \
  "$(jq -r 'any(.[]; .item == "20") | if . then "yes" else "no" end' <<<"$dropped")"

identity="$(refiner_drop_unbandable_triage "$triage_candidates_511" '[]')"
assert_eq "an empty unresolvable-slug list is the identity" \
  "$(jq -Sc . <<<"$triage_candidates_511")" "$(jq -Sc . <<<"$identity")"

malformed="$(refiner_drop_unbandable_triage 'not json at all' '["o/r1"]')"
assert_eq "malformed candidates JSON falls back to the input unchanged" \
  "not json at all" "$malformed"

# ============================================================================
# (B) The ratchet — lib/issue-priority.sh, requirement 39g
# ============================================================================

mkdir -p "$tmp_dir/gh-b"
cat > "$tmp_dir/gh-b/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  shift 2
  query="" jqfilter="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f) case "$2" in query=*) query="${2#query=}" ;; esac; shift 2 ;;
      --jq) jqfilter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ "$query" == *setIssueFieldValue* ]]; then
    printf '1\n' >> "$d/mutation-calls"
    [[ -f "$d/fail-mutation" ]] && exit 1
    exit 0
  fi
  [[ -f "$d/fail-fields" ]] && exit 1
  jq -c "$jqfilter" "$d/fields-response.json" 2>/dev/null || exit 1
  exit 0
fi
if [[ "$1" == "api" ]]; then
  path="$2"; shift 2
  jqfilter="."
  while [[ $# -gt 0 ]]; do
    case "$1" in --jq) jqfilter="$2"; shift 2 ;; *) shift ;; esac
  done
  case "$path" in
    */issues/*)
      [[ -f "$d/fail-current" ]] && exit 1
      jq -c "$jqfilter" "$d/current-response.json" 2>/dev/null || exit 1
      exit 0 ;;
    *) exit 1 ;;
  esac
fi
exit 1
STUB
chmod +x "$tmp_dir/gh-b/gh"
export ISSUE_PRIORITY_GH="$tmp_dir/gh-b/gh"

cat > "$tmp_dir/gh-b/fields-response.json" <<'EOF'
{"data":{"repository":{"issueFields":{"nodes":[
  {"id":"IFSS_priority","name":"Priority","options":[
    {"id":"OPT_URGENT","name":"Urgent"},{"id":"OPT_HIGH","name":"High"},
    {"id":"OPT_MEDIUM","name":"Medium"},{"id":"OPT_LOW","name":"Low"}]},
  {"id":"IFSS_effort","name":"Effort","options":[{"id":"OPT_E_LOW","name":"Low"}]}
]}}}}
EOF

current_response() {  # current_response NODE_ID [BAND]
  local node="$1" band="${2:-}"
  if [[ -z "$band" ]]; then
    jq -nc --arg n "$node" '{node_id: $n, issue_field_values: []}' > "$tmp_dir/gh-b/current-response.json"
  else
    jq -nc --arg n "$node" --arg b "$band" \
      '{node_id: $n, issue_field_values: [{issue_field_name: "Priority", single_select_option: {name: $b}}]}' \
      > "$tmp_dir/gh-b/current-response.json"
  fi
}

reset_b() {
  rm -f "$tmp_dir/gh-b/mutation-calls" "$tmp_dir/gh-b/fail-mutation" "$tmp_dir/gh-b/fail-fields" \
        "$tmp_dir/gh-b/fail-current"
  ISSUE_PRIORITY_CACHE_DIR="$(mktemp -d "$tmp_dir/cache.XXXXXX")"
}

# --- issue_priority_rank ---
assert_eq "Urgent outranks everything" "4" "$(issue_priority_rank Urgent)"
assert_eq "Low is the bottom rank, never zero" "1" "$(issue_priority_rank Low)"
assert_eq "anything else ranks 0" "0" "$(issue_priority_rank NotABand)"

# --- issue_priority_field_ids / issue_priority_options_complete ---
reset_b
field_json="$(issue_priority_field_ids "o/case-fields-ok")"
assert_eq "the Priority field's id resolves" "IFSS_priority" "$(jq -r '.field_id' <<<"$field_json")"
assert_eq "every band's option id resolves" "OPT_URGENT OPT_HIGH OPT_MEDIUM OPT_LOW" \
  "$(jq -r '[.options.Urgent, .options.High, .options.Medium, .options.Low] | join(" ")' <<<"$field_json")"
assert_eq "issue_priority_options_complete is true for all four" "0" \
  "$(issue_priority_options_complete "$field_json"; echo $?)"

reset_b
cat > "$tmp_dir/gh-b/fields-response.json" <<'EOF'
{"data":{"repository":{"issueFields":{"nodes":[
  {"id":"IFSS_priority","name":"Priority","options":[{"id":"OPT_HIGH","name":"High"}]}
]}}}}
EOF
incomplete_json="$(issue_priority_field_ids "o/case-fields-incomplete")"
assert_eq "issue_priority_options_complete is false when a band is missing" "1" \
  "$(issue_priority_options_complete "$incomplete_json"; echo $?)"
cat > "$tmp_dir/gh-b/fields-response.json" <<'EOF'
{"data":{"repository":{"issueFields":{"nodes":[
  {"id":"IFSS_priority","name":"Priority","options":[
    {"id":"OPT_URGENT","name":"Urgent"},{"id":"OPT_HIGH","name":"High"},
    {"id":"OPT_MEDIUM","name":"Medium"},{"id":"OPT_LOW","name":"Low"}]},
  {"id":"IFSS_effort","name":"Effort","options":[{"id":"OPT_E_LOW","name":"Low"}]}
]}}}}
EOF

reset_b
touch "$tmp_dir/gh-b/fail-fields"
assert_eq "an unresolvable field is a plain failure, not empty options" "1" \
  "$(issue_priority_field_ids 'o/case-fields-unreadable' >/dev/null 2>&1; echo $?)"
rm -f "$tmp_dir/gh-b/fail-fields"

# --- issue_priority_apply: bad arguments ---
reset_b
assert_eq "a malformed slug is bad-slug, no gh call at all" "bad-slug" \
  "$(jq -r '.reason' <<<"$(issue_priority_apply 'not-a-slug' 5 High)")"
assert_eq "a non-numeric issue number is bad-number" "bad-number" \
  "$(jq -r '.reason' <<<"$(issue_priority_apply 'o/r' 'five' High)")"
assert_eq "a band outside the four names is bad-band" "bad-band" \
  "$(jq -r '.reason' <<<"$(issue_priority_apply 'o/r' 5 Critical)")"

# --- issue_priority_apply: the ratchet itself ---
reset_b
current_response "I_node_10"
result="$(issue_priority_apply "o/case-apply-1" 10 High)"
assert_eq "no current band: the verdict is applied" "true" "$(jq -r '.applied' <<<"$result")"
assert_eq "  ... previous is null, not empty string" "null" "$(jq -c '.previous' <<<"$result")"
assert_eq "  ... the mutation actually reached gh" "1" "$(wc -l < "$tmp_dir/gh-b/mutation-calls")"

reset_b
current_response "I_node_11" "Low"
result="$(issue_priority_apply "o/case-apply-2" 11 High)"
assert_eq "a strictly higher band is applied" "true" "$(jq -r '.applied' <<<"$result")"
assert_eq "  ... previous names the old band" "Low" "$(jq -r '.previous' <<<"$result")"

reset_b
current_response "I_node_12" "High"
result="$(issue_priority_apply "o/case-apply-3" 12 High)"
assert_eq "an equal band is skipped, not applied" "false" "$(jq -r '.applied' <<<"$result")"
assert_eq "  ... reason is skipped-lower-or-equal" "skipped-lower-or-equal" "$(jq -r '.reason' <<<"$result")"
assert_eq "  ... and no mutation reaches gh" "0" \
  "$([[ -f "$tmp_dir/gh-b/mutation-calls" ]] && wc -l < "$tmp_dir/gh-b/mutation-calls" || echo 0)"

reset_b
current_response "I_node_13" "Urgent"
result="$(issue_priority_apply "o/case-apply-4" 13 Low)"
assert_eq "a strictly lower band is skipped, not applied" "false" "$(jq -r '.applied' <<<"$result")"
assert_eq "  ... reason is skipped-lower-or-equal" "skipped-lower-or-equal" "$(jq -r '.reason' <<<"$result")"
assert_eq "  ... and no mutation reaches gh" "0" \
  "$([[ -f "$tmp_dir/gh-b/mutation-calls" ]] && wc -l < "$tmp_dir/gh-b/mutation-calls" || echo 0)"

# A band outside the four recognised names — an org admin can add one at any
# time (agent-ops#509, requirement 39g's own promise) — must never be
# overwritten, however clearly the offered verdict would otherwise outrank
# it. `issue_priority_current` reads the raw option name unfiltered
# (asserted first, directly), and the ratchet must treat rank-0 as "cannot
# rank", not as "unset and safe to write".
reset_b
current_response "I_node_13b" "Critical"
current_json="$(issue_priority_current "o/case-apply-4b" 13)"
assert_eq "issue_priority_current reads the raw name, not just the four it can rank" \
  "Critical" "$(jq -r '.priority' <<<"$current_json")"

reset_b
current_response "I_node_13c" "Critical"
result="$(issue_priority_apply "o/case-apply-4c" 13 Urgent)"
assert_eq "a band outside the four names is never overwritten, even by Urgent" "false" \
  "$(jq -r '.applied' <<<"$result")"
assert_eq "  ... reason is skipped-unrankable" "skipped-unrankable" "$(jq -r '.reason' <<<"$result")"
assert_eq "  ... previous names the raw, unranked band" "Critical" "$(jq -r '.previous' <<<"$result")"
assert_eq "  ... and no mutation reaches gh" "0" \
  "$([[ -f "$tmp_dir/gh-b/mutation-calls" ]] && wc -l < "$tmp_dir/gh-b/mutation-calls" || echo 0)"

# The pre-write re-read: a band that changed since this cycle's pre-fetch is
# what issue_priority_current reads, not a value the caller might have cached
# — asserted here by giving the ratchet a *current* value the pre-fetch could
# never have known about, and confirming it is exactly what decides the
# ratchet's outcome.
reset_b
current_response "I_node_14" "Urgent"
result="$(issue_priority_apply "o/case-apply-5" 14 Medium)"
assert_eq "a band set between pre-fetch and write is honoured, not clobbered" "false" \
  "$(jq -r '.applied' <<<"$result")"
assert_eq "  ... skipped against the freshly-read Urgent, not a stale Medium" "Urgent" \
  "$(jq -r '.previous' <<<"$result")"

reset_b
touch "$tmp_dir/gh-b/fail-fields"
result="$(issue_priority_apply "o/case-apply-6" 15 High)"
assert_eq "an unresolvable field fails the whole apply" "false" "$(jq -r '.applied' <<<"$result")"
assert_eq "  ... reason is field-unresolvable" "field-unresolvable" "$(jq -r '.reason' <<<"$result")"
rm -f "$tmp_dir/gh-b/fail-fields"

reset_b
touch "$tmp_dir/gh-b/fail-current"
result="$(issue_priority_apply "o/case-apply-7" 16 High)"
assert_eq "an unreadable issue is issue-unreadable" "issue-unreadable" "$(jq -r '.reason' <<<"$result")"
rm -f "$tmp_dir/gh-b/fail-current"

reset_b
current_response "I_node_17"
touch "$tmp_dir/gh-b/fail-mutation"
result="$(issue_priority_apply "o/case-apply-8" 17 High)"
assert_eq "a failed mutation is mutation-failed, not silently applied" "false" "$(jq -r '.applied' <<<"$result")"
assert_eq "  ... reason is mutation-failed" "mutation-failed" "$(jq -r '.reason' <<<"$result")"
rm -f "$tmp_dir/gh-b/fail-mutation"

# Caching: two applies against the same repo resolve the field once.
reset_b
current_response "I_node_18" "Low"
issue_priority_apply "o/case-cache" 18 High >/dev/null
current_response "I_node_19" "Low"
issue_priority_apply "o/case-cache" 19 High >/dev/null
rm -f "$tmp_dir/gh-b/fields-response.json"  # the second apply must not need to re-read it
result="$(issue_priority_apply "o/case-cache" 20 High)"
assert_eq "a cached field resolution serves a third apply with the fixture gone" "true" \
  "$(jq -r '.applied' <<<"$result")"

# --- Cache cleanup (issue #510) ---
#
# lib/issue-priority.sh leaked ISSUE_PRIORITY_CACHE_DIR once per sourcing
# process: nothing removed it. issue_priority_cache_cleanup fixes that; these
# assertions cover both halves of the ownership rule it has to get right —
# remove a directory this file created for itself, never one a caller
# supplied — plus the idempotency every EXIT trap that calls it depends on.
saved_dir="$ISSUE_PRIORITY_CACHE_DIR" saved_owned="$ISSUE_PRIORITY_CACHE_DIR_OWNED"

# A process that leaves ISSUE_PRIORITY_CACHE_DIR unset gets one created and
# owned on its behalf, and cleanup removes it — fixture files included, not
# just an empty directory, since an empty `rm -rf` proves nothing about the
# real per-SLUG cache this stands in for.
unset ISSUE_PRIORITY_CACHE_DIR ISSUE_PRIORITY_CACHE_DIR_OWNED
. "$SCRIPT_DIR/lib/issue-priority.sh"
assert_eq "an unset ISSUE_PRIORITY_CACHE_DIR is created and marked owned" "1" "$ISSUE_PRIORITY_CACHE_DIR_OWNED"
default_dir="$ISSUE_PRIORITY_CACHE_DIR"
assert_eq "the default cache directory exists before cleanup" "true" \
  "$([[ -d "$default_dir" ]] && echo true || echo false)"
for n in $(seq 1 25); do
  head -c 65536 /dev/zero | tr '\0' 'x' > "$default_dir/o__r$n.json"
done
issue_priority_cache_cleanup
assert_eq "cleanup removes the default cache directory, oversized fixtures included" "false" \
  "$([[ -d "$default_dir" ]] && echo true || echo false)"

# A caller that supplies its own path keeps it after the same call — it is
# that caller's directory to manage, not this library's.
caller_dir="$(mktemp -d "$tmp_dir/cache-caller.XXXXXX")"
touch "$caller_dir/not-mine.json"
ISSUE_PRIORITY_CACHE_DIR="$caller_dir"
. "$SCRIPT_DIR/lib/issue-priority.sh"
assert_eq "a caller-supplied ISSUE_PRIORITY_CACHE_DIR is not marked owned" "0" "$ISSUE_PRIORITY_CACHE_DIR_OWNED"
issue_priority_cache_cleanup
assert_eq "cleanup leaves a caller-supplied directory in place" "true" \
  "$([[ -d "$caller_dir" ]] && echo true || echo false)"
rm -rf "$caller_dir"

# Idempotent: called again with nothing left to remove, or with no directory
# ever created at all, it is silent and still returns 0.
out="$(issue_priority_cache_cleanup)"
rc=$?
assert_eq "calling cleanup again after it already ran returns 0" "0" "$rc"
assert_eq "  ... and prints nothing" "" "$out"

ISSUE_PRIORITY_CACHE_DIR_OWNED=1
ISSUE_PRIORITY_CACHE_DIR=""
out2="$(issue_priority_cache_cleanup)"
rc2=$?
assert_eq "cleanup with no directory ever created returns 0" "0" "$rc2"
assert_eq "  ... and prints nothing" "" "$out2"

ISSUE_PRIORITY_CACHE_DIR="$saved_dir"
ISSUE_PRIORITY_CACHE_DIR_OWNED="$saved_owned"

unset ISSUE_PRIORITY_GH

# ============================================================================
# (C) The wiring — maybe_run_refiner (agent-cycle.sh), requirement 39g
# ============================================================================
# Follows test/refiner-verdicts.test.sh's own harness: the function under
# test is lifted verbatim out of agent-cycle.sh with awk, so this cannot pass
# against a copy the script has since moved on from.

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

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
refiner_filter_unbandable_triage_fn="$(extract_fn 'refiner_filter_unbandable_triage() {' "$SCRIPT_DIR/agent-cycle.sh")"

if [[ "$maybe_run_refiner_fn" != *"issue-prioritised"* ]]; then
  printf 'FAIL - maybe_run_refiner could not be found carrying the priority wiring (renamed or moved?)\n'
  exit 1
fi
if [[ "$refiner_filter_unbandable_triage_fn" != *"refiner_drop_unbandable_triage"* ]]; then
  printf 'FAIL - refiner_filter_unbandable_triage could not be found carrying the pre-flight wiring (renamed or moved?)\n'
  exit 1
fi

eval "$extract_json_result_fn"
eval "$refiner_claim_key_fn"
eval "$record_needs_refinement_block_fn"
eval "$refiner_filter_unbandable_triage_fn"
eval "$maybe_run_refiner_fn"

fake_root="$tmp_dir/fake-root"
mkdir -p "$fake_root/lib" "$fake_root/prompts"
cat > "$fake_root/lib/claim.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*"
exit 0
STUB
chmod +x "$fake_root/lib/claim.sh"
: > "$fake_root/prompts/refiner.md"

# One stub `gh`, reached through both REFINEMENT_GH (label/assignee/issue
# view, the same shape test/refiner-verdicts.test.sh uses) and
# ISSUE_PRIORITY_GH (the field-ids/mutation/current-band calls from section
# B above) — maybe_run_refiner exercises both libraries in the same call.
gh_c="$tmp_dir/gh-c"
mkdir -p "$gh_c"
cat > "$gh_c/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  cat "$d/issue-assignees" 2>/dev/null
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "edit" ]]; then
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
fi
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  shift 2
  query="" jqfilter="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f) case "$2" in query=*) query="${2#query=}" ;; esac; shift 2 ;;
      --jq) jqfilter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ "$query" == *setIssueFieldValue* ]]; then
    printf '1\n' >> "$d/mutation-calls"
    [[ -f "$d/fail-mutation" ]] && exit 1
    exit 0
  fi
  [[ -f "$d/fail-fields" ]] && exit 1
  jq -c "$jqfilter" "$d/fields-response.json" 2>/dev/null || exit 1
  exit 0
fi
if [[ "$1" == "api" ]]; then
  path="$2"; shift 2
  jqfilter="."
  while [[ $# -gt 0 ]]; do
    case "$1" in --jq) jqfilter="$2"; shift 2 ;; *) shift ;; esac
  done
  case "$path" in
    */issues/*)
      [[ -f "$d/fail-current" ]] && exit 1
      jq -c "$jqfilter" "$d/current-response.json" 2>/dev/null || exit 1
      exit 0 ;;
    *) exit 1 ;;
  esac
fi
exit 1
STUB
chmod +x "$gh_c/gh"
export REFINEMENT_GH="$gh_c/gh"
export ISSUE_PRIORITY_GH="$gh_c/gh"
: > "$gh_c/issue-assignees"
cat > "$gh_c/fields-response.json" <<'EOF'
{"data":{"repository":{"issueFields":{"nodes":[
  {"id":"IFSS_priority","name":"Priority","options":[
    {"id":"OPT_URGENT","name":"Urgent"},{"id":"OPT_HIGH","name":"High"},
    {"id":"OPT_MEDIUM","name":"Medium"},{"id":"OPT_LOW","name":"Low"}]}
]}}}}
EOF

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
run_claude_stage() {
  local out_file="$5"
  jq -nc --argjson env "$STUB_REFINED_JSON" '{result: ($env | tostring), session_id: "stub-session"}' \
    > "$out_file"
  # shellcheck disable=SC2034  # read by the eval'd maybe_run_refiner, not visible here
  stage_gaps_json="null"
  # shellcheck disable=SC2034
  stage_kill_reason=""
  return 0
}

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
state_dir="$tmp_dir/state-c"
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

run_case_c() {
  local desc="$1" candidates_json="$2" verdicts_json="$3" dry_run_val="${4:-0}" rc_val
  cycle_dir="$(mktemp -d "$tmp_dir/case-c.XXXXXX")"
  calls_log="$cycle_dir/calls.log"
  : > "$calls_log"
  rm -f "$gh_c/label-calls" "$gh_c/assignee-calls" "$gh_c/mutation-calls"
  ISSUE_PRIORITY_CACHE_DIR="$(mktemp -d "$tmp_dir/cache-c.XXXXXX")"
  # shellcheck disable=SC2034  # read only by the eval'd maybe_run_refiner
  refiner_candidates_json="$candidates_json"
  DRY_RUN="$dry_run_val"
  STUB_REFINED_JSON="$(jq -nc --argjson v "$verdicts_json" '{refined: $v}')"
  maybe_run_refiner 0 >/dev/null 2>&1
  rc_val=$?
  # shellcheck disable=SC2034  # read only by the eval'd maybe_run_refiner
  DRY_RUN=0
  printf 'refiner-rc %s\n' "$rc_val" >> "$calls_log"
  cat "$calls_log"
  sed 's/^/gh-label /' "$gh_c/label-calls" 2>/dev/null || true
  sed 's/^/claimlog /' "$cycle_dir/claim.log" 2>/dev/null || true
}

events_named() {  # events_named LOG NAME -> each matching event's JSON payload, one per line
  grep -E "^event $2 " <<<"$1" | sed -E "s/^event $2 //"
}

# ----------------------------------------------------------------------------
# (i) an ordinary refined issues verdict carrying priority: the field is set
# ----------------------------------------------------------------------------
issue_candidates_c='[{"repo":"o/r","source":"issues","item":"55"}]'
jq -nc '{node_id: "I_c55", issue_field_values: []}' > "$gh_c/current-response.json"
verdicts='[{"repo":"o/r","item":"55","verdict":"refined","reason":"specified in one comment",
            "comments_posted":["https://github.com/o/r/issues/55#issuecomment-1"],
            "priority":"High"}]'
calls="$(run_case_c "priority set alongside a real refinement" "$issue_candidates_c" "$verdicts")"

assert_eq "priority-and-spec: item-refined still recorded" "1" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
ip_evt="$(events_named "$calls" issue-prioritised | head -n1)"
assert_eq "priority-and-spec: issue-prioritised names the band" "High" "$(jq -r '.priority' <<<"$ip_evt")"
assert_eq "priority-and-spec: ...and by: refiner" "refiner" "$(jq -r '.by' <<<"$ip_evt")"
assert_eq "priority-and-spec: ...and no prior band" "null" "$(jq -c '.previous' <<<"$ip_evt")"
assert_eq "priority-and-spec: exactly one mutation reached gh" "1" \
  "$([[ -f "$gh_c/mutation-calls" ]] && wc -l < "$gh_c/mutation-calls" || echo 0)"

# ----------------------------------------------------------------------------
# (ii) a triage_only item: priority alone is the whole verdict — no
# corroboration required, no item-refined, no label
# ----------------------------------------------------------------------------
triage_candidates_c='[{"repo":"o/r","source":"issues","item":"56","triage_only":true}]'
jq -nc '{node_id: "I_c56", issue_field_values: []}' > "$gh_c/current-response.json"
verdicts='[{"repo":"o/r","item":"56","verdict":"refined","reason":"banded only, already specified",
            "priority":"Medium"}]'
calls="$(run_case_c "triage_only: priority alone" "$triage_candidates_c" "$verdicts")"

assert_eq "triage-only: no item-refined — nothing new was specified" "0" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
assert_eq "triage-only: no comment-missing warning" "0" \
  "$(grep -c 'carries no comment' <<<"$calls")"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "triage-only: refiner-examined outcome is triage-only" "triage-only" "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_eq "triage-only: no label write" "0" "$(grep -cE '^event own-label-action ' <<<"$calls")"
assert_not_contains "triage-only: gh never saw a label call" "gh-label" "$calls"
ip_evt="$(events_named "$calls" issue-prioritised | head -n1)"
assert_eq "triage-only: the band still gets applied" "Medium" "$(jq -r '.priority' <<<"$ip_evt")"

# ----------------------------------------------------------------------------
# (iii) a priority at or below the current band: skipped, logged, no mutation
# ----------------------------------------------------------------------------
jq -nc '{node_id: "I_c55", issue_field_values: [{issue_field_name:"Priority", single_select_option:{name:"High"}}]}' \
  > "$gh_c/current-response.json"
verdicts='[{"repo":"o/r","item":"55","verdict":"refined","reason":"already specified",
            "comments_posted":["https://github.com/o/r/issues/55#issuecomment-2"],
            "priority":"Medium"}]'
calls="$(run_case_c "priority at or below current: skipped" "$issue_candidates_c" "$verdicts")"

assert_eq "skipped: item-refined is still recorded regardless" "1" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
skip_evt="$(events_named "$calls" issue-prioritised-skipped | head -n1)"
assert_eq "skipped: issue-prioritised-skipped names the offered band" "Medium" "$(jq -r '.priority' <<<"$skip_evt")"
assert_eq "skipped: ...and the current, higher band" "High" "$(jq -r '.previous' <<<"$skip_evt")"
assert_eq "skipped: no issue-prioritised (the write kind) at all" "0" \
  "$(grep -cE '^event issue-prioritised ' <<<"$calls")"
assert_eq "skipped: no mutation reached gh" "0" \
  "$([[ -f "$gh_c/mutation-calls" ]] && wc -l < "$gh_c/mutation-calls" || echo 0)"

# ----------------------------------------------------------------------------
# (iiib) a band outside the four names: skipped as unrankable, logged, no
# mutation, and never mistaken for a warning-worthy failure (agent-ops#509)
# ----------------------------------------------------------------------------
jq -nc '{node_id: "I_c55", issue_field_values: [{issue_field_name:"Priority", single_select_option:{name:"Critical"}}]}' \
  > "$gh_c/current-response.json"
verdicts='[{"repo":"o/r","item":"55","verdict":"refined","reason":"already specified",
            "comments_posted":["https://github.com/o/r/issues/55#issuecomment-2b"],
            "priority":"Urgent"}]'
calls="$(run_case_c "priority outside the four names: skipped as unrankable" "$issue_candidates_c" "$verdicts")"

assert_eq "unrankable: item-refined is still recorded regardless" "1" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
skip_evt="$(events_named "$calls" issue-prioritised-skipped | head -n1)"
assert_eq "unrankable: issue-prioritised-skipped names the offered band" "Urgent" "$(jq -r '.priority' <<<"$skip_evt")"
assert_eq "unrankable: ...and the current, unranked band, not clobbered" "Critical" "$(jq -r '.previous' <<<"$skip_evt")"
assert_eq "unrankable: no issue-prioritised (the write kind) at all" "0" \
  "$(grep -cE '^event issue-prioritised ' <<<"$calls")"
assert_eq "unrankable: no warning either — this is the ratchet working, not failing" "0" \
  "$(grep -c 'could not set Priority' <<<"$calls")"
assert_eq "unrankable: no mutation reached gh" "0" \
  "$([[ -f "$gh_c/mutation-calls" ]] && wc -l < "$gh_c/mutation-calls" || echo 0)"

# ----------------------------------------------------------------------------
# (iv) a failed write: warning, but the refinement verdict is unaffected
# ----------------------------------------------------------------------------
jq -nc '{node_id: "I_c55", issue_field_values: []}' > "$gh_c/current-response.json"
touch "$gh_c/fail-mutation"
verdicts='[{"repo":"o/r","item":"55","verdict":"refined","reason":"specified fine, band fails",
            "comments_posted":["https://github.com/o/r/issues/55#issuecomment-3"],
            "priority":"High"}]'
calls="$(run_case_c "mutation fails: refinement still lands" "$issue_candidates_c" "$verdicts")"
rm -f "$gh_c/fail-mutation"

assert_eq "write failure: item-refined is recorded either way" "1" \
  "$(grep -cE '^event item-refined ' <<<"$calls")"
assert_contains "write failure: a warning names the failed band write" \
  "could not set Priority on o/r#55 to High" "$calls"
assert_eq "write failure: no issue-prioritised event" "0" \
  "$(grep -cE '^event issue-prioritised ' <<<"$calls")"

# ----------------------------------------------------------------------------
# (v) needs-refinement verdict carrying priority: the block is independent,
# the band still gets applied
# ----------------------------------------------------------------------------
jq -nc '{node_id: "I_c55", issue_field_values: []}' > "$gh_c/current-response.json"
verdicts='[{"repo":"o/r","item":"55","verdict":"needs-refinement","reason":"no acceptance criteria",
            "missing":"a scope bound","evidence":"issue 55, read in full","priority":"Urgent"}]'
calls="$(run_case_c "needs-refinement carrying priority" "$issue_candidates_c" "$verdicts")"

assert_eq "decline+priority: the block is still recorded" "1" \
  "$(grep -cE '^event attempt-failed ' <<<"$calls")"
ip_evt="$(events_named "$calls" issue-prioritised | head -n1)"
assert_eq "decline+priority: the band is applied despite the decline" "Urgent" "$(jq -r '.priority' <<<"$ip_evt")"

# ----------------------------------------------------------------------------
# (va) the same decline on a triage_only item: refused, never recorded
# ----------------------------------------------------------------------------
# The one way this requirement's candidate rule could cost the pipeline work
# rather than save it: an item that is already refined reaches the Refiner
# solely for its band, the Refiner declines it, and a block lands on an item
# that already carries a specification — labelled, assigned to a human, and
# out of selection until someone clears it. The Script refuses the decline
# instead, and the band still applies.
jq -nc '{node_id: "I_c56", issue_field_values: []}' > "$gh_c/current-response.json"
verdicts='[{"repo":"o/r","item":"56","verdict":"needs-refinement","reason":"I would want more detail",
            "missing":"a scope bound","evidence":"issue 56, read in full","priority":"High"}]'
calls="$(run_case_c "needs-refinement on a triage_only item" "$triage_candidates_c" "$verdicts")"

assert_eq "triage-only decline: no block is recorded" "0" \
  "$(grep -cE '^event attempt-failed ' <<<"$calls")"
xmn_evt="$(events_named "$calls" refiner-examined | head -n1)"
assert_eq "triage-only decline: outcome is triage-only-refused" "triage-only-refused" \
  "$(jq -r '.outcome' <<<"$xmn_evt")"
assert_contains "triage-only decline: a warning says why nothing was recorded" \
  "offered only for its Priority band" "$calls"
assert_eq "triage-only decline: no needs_refinement label" "0" \
  "$(grep -cE '^event own-label-action ' <<<"$calls")"
assert_not_contains "triage-only decline: gh saw no label or assignee write" "gh-label" "$calls"
ip_evt="$(events_named "$calls" issue-prioritised | head -n1)"
assert_eq "triage-only decline: the band still applies" "High" "$(jq -r '.priority' <<<"$ip_evt")"

# ----------------------------------------------------------------------------
# (vi) DRY_RUN: no mutation, no gh call, no events at all
# ----------------------------------------------------------------------------
jq -nc '{node_id: "I_c55", issue_field_values: []}' > "$gh_c/current-response.json"
verdicts='[{"repo":"o/r","item":"55","verdict":"refined","reason":"would specify",
            "comments_posted":["https://github.com/o/r/issues/55#issuecomment-4"],
            "priority":"High"}]'
calls="$(run_case_c "DRY_RUN: nothing is mutated" "$issue_candidates_c" "$verdicts" 1)"

assert_eq "DRY_RUN: maybe_run_refiner returns 0 having done nothing" "refiner-rc 0" \
  "$(grep -E '^refiner-rc' <<<"$calls")"
assert_eq "DRY_RUN: no events at all" "0" "$(grep -cE '^event ' <<<"$calls")"
assert_eq "DRY_RUN: no mutation reached gh" "0" \
  "$([[ -f "$gh_c/mutation-calls" ]] && wc -l < "$gh_c/mutation-calls" || echo 0)"

unset REFINEMENT_GH ISSUE_PRIORITY_GH

# ----------------------------------------------------------------------------
# (vii) refiner_filter_unbandable_triage — the pre-flight wiring, issue #511
# ----------------------------------------------------------------------------
# A dedicated `gh` stub, distinguishing repositories by owner/repo (the earlier
# stubs in this file need no such distinction): "o/bad"'s field query fails,
# "o/good"'s succeeds, exactly what this pre-flight has to tell apart.
gh_e="$tmp_dir/gh-e"
mkdir -p "$gh_e"
cat > "$gh_e/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  shift 2
  owner="" repo="" jqfilter="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f) case "$2" in owner=*) owner="${2#owner=}" ;; repo=*) repo="${2#repo=}" ;; esac; shift 2 ;;
      --jq) jqfilter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s/%s\n' "$owner" "$repo" >> "$d/field-queries.log"
  [[ "$repo" == "bad" ]] && exit 1
  jq -c "$jqfilter" "$d/fields-response.json" 2>/dev/null || exit 1
  exit 0
fi
exit 1
STUB
chmod +x "$gh_e/gh"
cat > "$gh_e/fields-response.json" <<'EOF'
{"data":{"repository":{"issueFields":{"nodes":[
  {"id":"IFSS_priority","name":"Priority","options":[
    {"id":"OPT_URGENT","name":"Urgent"},{"id":"OPT_HIGH","name":"High"},
    {"id":"OPT_MEDIUM","name":"Medium"},{"id":"OPT_LOW","name":"Low"}]}
]}}}}
EOF
: > "$gh_e/field-queries.log"
export ISSUE_PRIORITY_GH="$gh_e/gh"
ISSUE_PRIORITY_CACHE_DIR="$(mktemp -d "$tmp_dir/cache-pf.XXXXXX")"

pf_candidates='[
  {"repo":"o/bad","source":"issues","item":"1","triage_only":true},
  {"repo":"o/bad","source":"issues","item":"2","triage_only":true},
  {"repo":"o/bad","source":"issues","item":"3"},
  {"repo":"o/good","source":"issues","item":"10","triage_only":true},
  {"repo":"o/good","source":"issues","item":"11"}
]'
calls_log="$tmp_dir/pf-calls.log"
: > "$calls_log"
filtered="$(refiner_filter_unbandable_triage "$pf_candidates")"
pf_calls="$(cat "$calls_log")"

assert_eq "pre-flight: o/bad's triage_only candidates never reach the set (1/2)" "3" \
  "$(jq 'length' <<<"$filtered")"
assert_eq "  ... o/bad's non-triage_only candidate still reaches it" "yes" \
  "$(jq -r 'any(.[]; .item == "3") | if . then "yes" else "no" end' <<<"$filtered")"
assert_eq "  ... o/good's triage_only candidate still reaches it (field resolves)" "yes" \
  "$(jq -r 'any(.[]; .item == "10") | if . then "yes" else "no" end' <<<"$filtered")"
assert_eq "  ... o/good's ordinary candidate is untouched" "yes" \
  "$(jq -r 'any(.[]; .item == "11") | if . then "yes" else "no" end' <<<"$filtered")"

pf_warnings="$(events_named "$pf_calls" warning)"
assert_eq "pre-flight: exactly one warning, for o/bad alone" "1" "$(wc -l <<<"$pf_warnings")"
assert_eq "  ... naming the slug" "o/bad" "$(jq -r '.repo' <<<"$pf_warnings")"
assert_eq "  ... and the count of dropped candidates, not one per item" "2" \
  "$(jq -r '.dropped' <<<"$pf_warnings")"

assert_eq "pre-flight: exactly one field query reached o/bad" "1" \
  "$(grep -c '^o/bad$' "$gh_e/field-queries.log")"
assert_eq "pre-flight: exactly one field query reached o/good" "1" \
  "$(grep -c '^o/good$' "$gh_e/field-queries.log")"

# criterion 6: a second consumer in the same process (an ordinary
# issue_priority_field_ids call, standing in for issue_priority_apply's own
# later call inside maybe_run_refiner) hits the process cache for both —
# including o/bad's cached failure — issuing no further query.
issue_priority_field_ids "o/bad" >/dev/null 2>&1
issue_priority_field_ids "o/good" >/dev/null 2>&1
assert_eq "  ... a second o/bad resolution hits the cache, not a fresh query" "1" \
  "$(grep -c '^o/bad$' "$gh_e/field-queries.log")"
assert_eq "  ... a second o/good resolution hits the cache, not a fresh query" "1" \
  "$(grep -c '^o/good$' "$gh_e/field-queries.log")"

# criterion 5: no triage_only candidate at all -> no query from this path.
: > "$gh_e/field-queries.log"
no_triage_candidates='[{"repo":"o/good","source":"issues","item":"99"}]'
refiner_filter_unbandable_triage "$no_triage_candidates" >/dev/null
assert_eq "pre-flight: no triage_only candidates issues no field query" "0" \
  "$(wc -l < "$gh_e/field-queries.log")"

# criterion 7: every contributing repository resolves -> byte-identical input.
ISSUE_PRIORITY_CACHE_DIR="$(mktemp -d "$tmp_dir/cache-pf2.XXXXXX")"
all_good_candidates='[{"repo":"o/good","source":"issues","item":"1","triage_only":true},
                       {"repo":"o/good","source":"issues","item":"2"}]'
all_good_result="$(refiner_filter_unbandable_triage "$all_good_candidates")"
assert_eq "pre-flight: every field resolving returns the input byte-identical" \
  "$all_good_candidates" "$all_good_result"

unset ISSUE_PRIORITY_GH ISSUE_PRIORITY_CACHE_DIR

# ============================================================================
# (D) The doctor's own gate — scripts/doctor.sh, requirement 39g
# ============================================================================
# The warning is only worth having if it ever runs, and its gate is the one
# line in this whole duty that a plausible-looking equality test silently
# disables: `sources` never carries a bare `issues`, because the issues
# source is one source at four ranks and the schema's enum offers only
# `issues:urgent` … `issues:low` (requirement 15e). So the gate is lifted
# verbatim out of doctor.sh and run against the shape a valid configuration
# actually has, rather than re-typed here where it could agree with a copy
# doctor.sh no longer holds.
doctor_gate="$(sed -n "s/^ *'\(.*sources.*any(.*\)' *\\\\\$/\1/p" "$repo_root/scripts/doctor.sh")"
assert_contains "the doctor's Priority gate was found in doctor.sh" "any(" "$doctor_gate"

banded_config='{"repos":[{"slug":"o/r","sources":["security","issues:high","tech-debt"]}]}'
unbanded_config='{"repos":[{"slug":"o/r","sources":["security","tech-debt"]}]}'
assert_eq "the gate fires on a repo configured with a banded issues token" "0" \
  "$(jq -e --arg s "o/r" "$doctor_gate" <<<"$banded_config" >/dev/null 2>&1; printf '%s' $?)"
assert_eq "  ... and on every one of the four bands" "0000" \
  "$(for b in urgent high medium low; do
       jq -e --arg s "o/r" "$doctor_gate" \
         <<<"{\"repos\":[{\"slug\":\"o/r\",\"sources\":[\"issues:$b\"]}]}" >/dev/null 2>&1
       printf '%s' $?
     done)"
assert_eq "the gate stays silent on a repo with the issues source off" "1" \
  "$(jq -e --arg s "o/r" "$doctor_gate" <<<"$unbanded_config" >/dev/null 2>&1; printf '%s' $?)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
