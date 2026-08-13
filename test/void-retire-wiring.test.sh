#!/usr/bin/env bash
#
# test/void-retire-wiring.test.sh — regression test for the two pieces of
# agent-cycle.sh that turn requirement 34n's liveness rule into a decision:
# `gather_register_hygiene`'s per-pass diagnostic files, and the block that
# reads them back into the per-repo, per-shape `{ok, ids}` map
# `void_liveness_actioned` consumes.
#
# `test/cycle-state.test.sh` covers the pure functions either side of this
# wiring and passes with it broken. That is not hypothetical. Requirement 34n
# shipped (PR #340) with `gather_register_hygiene` deriving its filenames from
# the slug alone, while the cycle calls it *twice* for one repo — once during
# the repo walk, once for requirement 34l's void re-derivation. Since
# `scripts/gather-register-hygiene.sh` prints `[]` on stdout for every failure
# path (a rate limit, a network blip, a branch moved between the two — the
# cases 34l's own comment names), a failed second read replaced the first
# read's array with an empty one underneath the `.ok` marker the first read had
# already written, and the liveness pass then read marker-present-plus-no-ids
# as "gathered, found nothing" and retired every still-live
# `register-hygiene-<hash>` void in the repo. A retirement caused by a failed
# read is the one outcome the marker exists to prevent, so the separation is
# what this file asserts:
#
#   - **Each pass writes its own files.** `purpose` lands in the filename, the
#     same way it already does for `gather_review_status`/`gather_plan_status`.
#   - **A failed `void` pass cannot touch the `prefetch` pass's evidence** —
#     the array survives intact and the marker still means what it said.
#   - **A failed read writes no marker of its own**, however valid the `[]` it
#     printed on stdout.
#   - **The liveness pass reads the `prefetch` pass's files, never the `void`
#     pass's**, whose array answers a different question (it folds the void
#     evidence in) and whose absence must not read as a failure.
#   - **A repo with no `prefetch` files at all decides nothing** — `ok: false`,
#     which is what hands the case to requirement 34n's config signal rather
#     than retiring on a gather that never ran.
#   - **The config signal reads the unnarrowed repo array.** `repos_json`
#     carries `--repo`'s filter and `ordered_repos_json`'s `sources` are
#     rewritten by back-pressure; either would make `void_config_actioned`
#     retire on a narrowing that means nothing of the sort.
#
# Both blocks are lifted verbatim out of agent-cycle.sh, the way
# test/human-visibility-wiring.test.sh lifts its own, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/void-retire-wiring.test.sh
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

# --- Extraction ---------------------------------------------------------------

# The patterns travel in the environment rather than through `-v`, which
# processes escape sequences and would eat the backslashes these regexes need.
extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

hygiene_fn="$(extract_block '^gather_register_hygiene\(\) \{' '^\}$' "$SCRIPT_DIR/agent-cycle.sh")"
if [[ -z "$hygiene_fn" ]]; then
  echo "FAIL - could not extract gather_register_hygiene from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

liveness_block="$(extract_block '^  void_failed_run_repos_json="\$\(jq' '^  done < <' "$SCRIPT_DIR/agent-cycle.sh")"
if [[ -z "$liveness_block" ]]; then
  echo "FAIL - could not extract the void-liveness gather block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# --- Half one: gather_register_hygiene's per-pass files -----------------------
#
# A fake SCRIPT_DIR whose gatherer replays a scripted answer per call, so the
# two passes can be given the succeed-then-fail ordering the defect needed.

fake_root="$tmp_dir/root"
mkdir -p "$fake_root/scripts" "$tmp_dir/stub"
cat > "$fake_root/scripts/gather-register-hygiene.sh" <<'STUB'
#!/usr/bin/env bash
n="$(cat "$STUB_STATE/n" 2>/dev/null || echo 0)"
n=$(( n + 1 ))
printf '%s' "$n" > "$STUB_STATE/n"
case "$(cat "$STUB_STATE/mode.$n" 2>/dev/null || echo ok-empty)" in
  ok-found) printf '%s' '[{"source":"register-hygiene","ref":"register-hygiene-aaaaaaaaaaaa"}]' ;;
  ok-empty) printf '%s' '[]' ;;
  # Every failure path in the real script: `[]` on stdout, exit 0, diagnosis
  # on stderr only. That combination is the whole defect.
  fail)     echo "gather-register-hygiene: could not fetch the register" >&2; printf '%s' '[]' ;;
esac
exit 0
STUB
chmod +x "$fake_root/scripts/gather-register-hygiene.sh"

# run_passes MODE1 MODE2 — run the prefetch pass then the void pass, under the
# same `set -euo pipefail` agent-cycle.sh runs under, in a fresh cycle dir.
run_passes() {
  local harness="$tmp_dir/hygiene-harness.sh"
  rm -rf "$tmp_dir/cycle" "$tmp_dir/stub"
  mkdir -p "$tmp_dir/cycle" "$tmp_dir/stub"
  printf '%s' "$1" > "$tmp_dir/stub/mode.1"
  printf '%s' "$2" > "$tmp_dir/stub/mode.2"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'SCRIPT_DIR=%q\n' "$fake_root"
    printf 'cycle_dir=%q\n' "$tmp_dir/cycle"
    printf '%s\n' "$hygiene_fn"
    printf '%s\n' 'gather_register_hygiene o/r main prefetch >/dev/null'
    printf '%s\n' 'gather_register_hygiene o/r main void "[]" >/dev/null'
  } > "$harness"
  STUB_STATE="$tmp_dir/stub" bash "$harness" 2>/dev/null
}

file_or() { [[ -f "$1" ]] && tr -d '\n' < "$1" || printf 'ABSENT'; }
marker_of() { [[ -f "$1" ]] && printf 'present' || printf 'absent'; }

# The defect's exact ordering: the repo walk's read succeeds and finds a live
# register-hygiene candidate, then 34l's re-derivation hits a rate limit.
run_passes ok-found fail

assert_eq "the prefetch pass's array survives a failed void pass" \
  '[{"source":"register-hygiene","ref":"register-hygiene-aaaaaaaaaaaa"}]' \
  "$(file_or "$tmp_dir/cycle/register-hygiene-prefetch-o_r.json")"
assert_eq "  ... and its marker still stands" \
  "present" "$(marker_of "$tmp_dir/cycle/register-hygiene-prefetch-o_r.ok")"
assert_eq "the void pass writes its own array, not the prefetch pass's" \
  "[]" "$(file_or "$tmp_dir/cycle/register-hygiene-void-o_r.json")"
assert_eq "a read that failed on stderr writes no marker, whatever it printed" \
  "absent" "$(marker_of "$tmp_dir/cycle/register-hygiene-void-o_r.ok")"
assert_eq "the shared, purpose-less filename is written by neither pass" \
  "ABSENT" "$(file_or "$tmp_dir/cycle/register-hygiene-o_r.json")"

# Both passes clean: each still keeps its own pair, so the void pass's
# void-folded array can never be mistaken for the plain gather.
run_passes ok-found ok-empty
assert_eq "two clean passes keep two separate arrays" \
  '[{"source":"register-hygiene","ref":"register-hygiene-aaaaaaaaaaaa"}]|[]' \
  "$(file_or "$tmp_dir/cycle/register-hygiene-prefetch-o_r.json")|$(file_or "$tmp_dir/cycle/register-hygiene-void-o_r.json")"
assert_eq "  ... and two separate markers" \
  "present|present" \
  "$(marker_of "$tmp_dir/cycle/register-hygiene-prefetch-o_r.ok")|$(marker_of "$tmp_dir/cycle/register-hygiene-void-o_r.ok")"

# --- Half two: which files the liveness pass reads back -----------------------
#
# The block under test builds `void_liveness_gather_json` from the cycle dir.
# `gather_workflow_basenames` is stubbed (it has its own test) and the
# failed-run half is left out of these fixtures entirely — this is about which
# register-hygiene files the block trusts.

# shellcheck disable=SC2016  # The harness's own `$void_liveness_gather_json`, written out literally for the assembled script to expand, not this shell.
run_liveness_block() {
  local cycle="$1" void_json="$2" harness="$tmp_dir/liveness-harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf '. %q\n' "$SCRIPT_DIR/lib/void-liveness.sh"
    printf 'cycle_dir=%q\n' "$cycle"
    printf 'void_json=%q\n' "$void_json"
    printf '%s\n' 'ordered_repos_json='"$(printf '%q' '[{"slug":"o/r"}]')"
    printf '%s\n' 'source_states_json="[]"'
    printf '%s\n' 'gather_workflow_basenames() { printf "%s" "{\"ok\":false,\"basenames\":{}}"; }'
    printf '%s\n' "$liveness_block"
    printf '%s\n' 'printf "%s" "$void_liveness_gather_json"'
  } > "$harness"
  bash "$harness" 2>/dev/null
}

lv_cycle="$tmp_dir/lv"
rm -rf "$lv_cycle"; mkdir -p "$lv_cycle"
printf '%s\n' '[{"ref":"register-hygiene-aaaaaaaaaaaa"}]' > "$lv_cycle/register-hygiene-prefetch-o_r.json"
: > "$lv_cycle/register-hygiene-prefetch-o_r.ok"
# The void pass's own files, deliberately disagreeing: an empty array and no
# marker. A block reading these would report "gathered, found nothing".
printf '%s\n' '[]' > "$lv_cycle/register-hygiene-void-o_r.json"

out="$(run_liveness_block "$lv_cycle" '[{"repo":"o/r","item":"register-hygiene-aaaaaaaaaaaa"}]')"

assert_eq "the liveness pass reads the prefetch pass's marker" \
  "true" "$(jq -r '."o/r"."register-hygiene".ok' <<<"$out")"
assert_eq "  ... and the prefetch pass's ids, not the void pass's empty array" \
  '["register-hygiene-aaaaaaaaaaaa"]' \
  "$(jq -c '."o/r"."register-hygiene".ids' <<<"$out")"

# A repo that dropped `register-hygiene` from its sources: the walk never
# called the gatherer, so no prefetch files exist. 34l's void pass may still
# have run and left its own — which must decide nothing.
rm -f "$lv_cycle/register-hygiene-prefetch-o_r.json" "$lv_cycle/register-hygiene-prefetch-o_r.ok"
: > "$lv_cycle/register-hygiene-void-o_r.ok"
out="$(run_liveness_block "$lv_cycle" '[{"repo":"o/r","item":"register-hygiene-aaaaaaaaaaaa"}]')"

assert_eq "a repo with no prefetch files decides nothing, whatever the void pass left" \
  "false" "$(jq -r '."o/r"."register-hygiene".ok' <<<"$out")"
assert_eq "  ... and offers no ids to decide it with" \
  "[]" "$(jq -c '."o/r"."register-hygiene".ids' <<<"$out")"

# --- Half three: which arguments the two rules are wired to -------------------
#
# Source-text assertions, because both failures are invisible at runtime until
# the cycle that exhibits them: a `--repo` run or a back-pressured cycle
# retiring a repo's whole void residue on a narrowing that means nothing of the
# sort, and the two hygiene passes sharing one tee again.
#
# Tab-separated: expected count, description, pattern. The quoted heredoc
# delimiter is what keeps `$void_json` and its siblings the variable *names*
# they are in agent-cycle.sh rather than expansions this shell should make,
# and `grep -F` matches them as the literals they are.
while IFS=$'\t' read -r want desc pattern; do
  [[ -n "$pattern" ]] || continue
  assert_eq "$desc" "$want" "$(grep -cF -- "$pattern" "$SCRIPT_DIR/agent-cycle.sh")"
done <<'PATTERNS'
1	void_config_actioned is handed the unnarrowed all_repos_json	void_config_actioned "$void_json" "$all_repos_json"
0	  ... and never the --repo-filtered repos_json	void_config_actioned "$void_json" "$repos_json"
0	  ... nor the back-pressure-narrowed ordered_repos_json	void_config_actioned "$void_json" "$ordered_repos_json"
1	the repo walk calls gather_register_hygiene with purpose prefetch	gather_register_hygiene "$slug" "$default_branch" prefetch
1	requirement 34l's pass calls it with purpose void	gather_register_hygiene "$vr_slug" "$vr_branch" void
0	neither pass is left calling it without a purpose	gather_register_hygiene "$slug" "$default_branch")
PATTERNS

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
