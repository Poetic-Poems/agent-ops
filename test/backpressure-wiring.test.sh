#!/usr/bin/env bash
#
# test/backpressure-wiring.test.sh — regression test for requirement 2.2's
# counting block in agent-cycle.sh: not whether the parts are right (they have
# their own tests) but whether the block hands them to each other correctly.
#
# That seam is where this gate keeps going wrong, twice in a week. Issue #427
# was the dashboard's copy of the sum omitting live claims entirely; PR #434
# added them and counted every row in the registry, tombstones and
# already-raised PRs alike, so the gauge pinned red against a gate that was
# open. Both defects lived in the wiring, and both shipped past a test suite
# that covers `lib/claim.sh count` thoroughly and the block calling it not at
# all.
#
# So the assertions here are about what the block *passes*, and what it makes
# of the answers:
#
#   - **Each repo's claim count is asked for against that repo's own PRs.**
#     `claim.sh count` drops a claim that merely names a pull request already
#     inside the sum, and it can only do that if it is told which those are —
#     per repo, since PR numbers are unique only within one.
#   - **"Already inside the sum" means drafts and changes-requested PRs, and
#     nothing else.** A ready PR waiting on a human is deliberately excluded
#     from the trip (agent-ops#246), so its claim must keep counting: it is
#     then the only record that the work is in flight.
#   - **An unreadable listing names no PRs at all.** Every claim then counts,
#     which is the fail-closed reading and matches the zeroed PR counts beside
#     it: of the two ways to be wrong here, only "stood down when it could have
#     run" is recoverable next cycle.
#   - **The composition line states the split the operator reads.** It is the
#     one record of which part filled the gate, and the dashboard card is
#     written to match it word for word.
#
# The block is lifted verbatim out of agent-cycle.sh, the way
# test/void-retire-wiring.test.sh lifts its own, so the assertions are about
# the shipped code rather than a copy of its logic.
#
# No network: `gh` and `lib/claim.sh` are both stubs, the first replaying a
# per-repo listing and the second recording the argv it was handed.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
# ./test/backpressure-wiring.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

counting_block="$(extract_block '^ready_count=0$' '^open_composition=' "$AGENT_CYCLE")"
if [[ -z "$counting_block" ]]; then
  echo "FAIL - could not extract the back-pressure counting block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if [[ "$counting_block" != *'claim.sh" count'* ]]; then
  echo "FAIL - the extracted block does not call claim.sh count — the anchors have drifted" >&2
  exit 1
fi

# --- Stubs --------------------------------------------------------------------

stub_bin="$tmp_dir/bin"
fake_root="$tmp_dir/root/lib"
listings="$tmp_dir/listings"
counts_dir="$tmp_dir/counts"
mkdir -p "$stub_bin" "$fake_root" "$listings" "$counts_dir"

# `gh pr list -R <slug>` replays a checked-in listing per repo, and exits 1 for
# a repo with no file — the unreachable-GitHub path the block guards with
# `|| prs_json=''`.
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
slug=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-R" ]] && slug="$a"
  prev="$a"
done
f="$GH_STUB_LISTINGS/${slug//\//__}.json"
[[ -f "$f" ]] || exit 1
cat "$f"
STUB
chmod +x "$stub_bin/gh"

# The claim counter records the argv it was handed — the whole point of the
# test — and answers a scripted figure. Its own exclusion rule is
# test/claim.test.sh's business, not this file's.
cat > "$fake_root/claim.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "${3-<unpassed>}" >> "$CLAIM_CALLS"
cat "$CLAIM_COUNTS/${2//\//__}" 2>/dev/null || echo 0
STUB
chmod +x "$fake_root/claim.sh"

# agent-ops: one draft, one approved-and-so-human-queued, one changes-requested.
cat > "$listings/Poetic-Poems__agent-ops.json" <<'JSON'
[{"number":700,"isDraft":true,"reviewDecision":""},
 {"number":701,"isDraft":false,"reviewDecision":"APPROVED"},
 {"number":702,"isDraft":false,"reviewDecision":"CHANGES_REQUESTED"}]
JSON
# poetic: no file, so the stub exits 1 — GitHub unreachable for this repo.
printf '3' > "$counts_dir/Poetic-Poems__agent-ops"
printf '1' > "$counts_dir/Poetic-Poems__poetic"

# --- Run the lifted block -----------------------------------------------------

# Everything below the `eval` is invisible to shellcheck, which is the point of
# lifting the block rather than copying it: the callees, the inputs and the
# outputs are all named by code the linter never sees. Hence the disables, each
# on the one line it covers rather than over the function.
run_block() {
  # shellcheck source=lib/github-limit.sh
  . "$SCRIPT_DIR/lib/github-limit.sh"
  # shellcheck disable=SC2317  # Called from the lifted block, on its truncation and guard paths.
  log_event() { :; }
  # shellcheck disable=SC2317  # Likewise — the lifted block's guard_warn on a claim-count failure.
  guard_warn() { :; }
  SCRIPT_DIR="$tmp_dir/root"
  # shellcheck disable=SC2034  # Read by the lifted block: the label it lists PRs by...
  pr_label="autonomous-agent"
  # shellcheck disable=SC2034  # ...and the repo list it walks.
  all_repos_json='[{"slug":"Poetic-Poems/agent-ops"},{"slug":"Poetic-Poems/poetic"}]'
  eval "$counting_block"
  # shellcheck disable=SC2154  # All three are assigned by the lifted block — they are what it is for.
  printf '%s\n%s\n%s\n' "$open_composition" "$adjusted_open_count" "$raw_open_count"
}

calls_file="$tmp_dir/claim-calls"
: > "$calls_file"
out="$(PATH="$stub_bin:$PATH" \
       GH_STUB_LISTINGS="$listings" CLAIM_CALLS="$calls_file" CLAIM_COUNTS="$counts_dir" \
       run_block 2>/dev/null)"
composition="$(sed -n '1p' <<<"$out")"
adjusted="$(sed -n '2p' <<<"$out")"
raw="$(sed -n '3p' <<<"$out")"

# --- What the block passed ----------------------------------------------------

assert_eq "the claim count is asked for once per configured repo" \
  "2" "$(wc -l < "$calls_file" | tr -d ' ')"
assert_eq "a repo's claims are counted against that repo's own drafts and changes-requested PRs" \
  "count|Poetic-Poems/agent-ops|700,702" "$(sed -n '1p' "$calls_file")"
assert_eq "…so the approved PR waiting on a human is not among them, and its claim keeps counting" \
  "no" "$(if [[ "$(sed -n '1p' "$calls_file")" == *701* ]]; then echo yes; else echo no; fi)"
assert_eq "an unreadable listing names no PRs at all — every claim counts (fail-closed)" \
  "count|Poetic-Poems/poetic|" "$(sed -n '2p' "$calls_file")"
assert_eq "…and the argument is still passed, rather than the call falling back to the old arity" \
  "no" "$(if grep -q '<unpassed>' "$calls_file"; then echo yes; else echo no; fi)"

# --- What the block made of the answers ---------------------------------------
#
# agent-ops contributes 2 ready (1 of them the human's), 1 draft; poetic
# contributes nothing but its unreachable listing's zeros. The stubs answer 3
# and 1 claims. So the trip figure is 1 changes-requested + 1 draft + 4 claims
# = 6, and the raw total counts the human-queue PR the trip figure does not.
assert_eq "the composition states the split the operator and the dashboard both read" \
  "1 changes-requested + 1 draft + 4 unraised claim(s) — plus 1 waiting on human (7 raw)" \
  "$composition"
assert_eq "the trip figure excludes the human-queue PR" "6" "$adjusted"
assert_eq "…while the raw total includes it" "7" "$raw"

# --- Report -------------------------------------------------------------------

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
