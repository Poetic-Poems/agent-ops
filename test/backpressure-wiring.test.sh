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
# Captured now, alongside AGENT_CYCLE above: run_block (below) reassigns the
# global $SCRIPT_DIR to a fake root for the lifted counting_block's own use,
# and that reassignment outlives the function call (no `local`), so a path
# derived from $SCRIPT_DIR at the point of use — rather than captured here,
# before anything clobbers it — would resolve against the fake root instead.
AGENT_APPROVER_LIB="$SCRIPT_DIR/lib/approver.sh"
# Same reasoning: the back-pressure counting block itself moved to
# lib/standdown.sh (#771).
AGENT_STANDDOWN_LIB="$SCRIPT_DIR/lib/standdown.sh"
# Captured here, alongside the two above, because the harness below reassigns
# `SCRIPT_DIR` to a fixture root — deliberately, so the lifted block resolves
# its own helpers against the stubs — and never restores it. The SC2154 scan at
# the end of this file must still reach the real modules.
AGENT_LIB_DIR="$SCRIPT_DIR/lib"

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

counting_block="$(extract_block '^ready_count=0$' '^open_composition=' "$AGENT_STANDDOWN_LIB")"
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
#
# `gh api repos/<repo>/contents/fleet/<name>.json?ref=main` is
# fleet_flag_fetch_status's own read (the kill switch, and a per-repo merge-
# budget freeze) — every flag reads as absent (a 404), which is the ordinary
# "nothing stands this repo down" case the back-pressure loop runs under on
# every cycle, and each such call is logged to GH_API_CALLS (one line per
# call, when the variable is set) so a test can count how many the block
# actually made. `repos/<repo>` with no `/contents/` is the repo-visibility
# probe `probe-404` mode spends resolving the kill flag's own 404 — answered
# successfully so that 404 resolves to a genuine "clear" rather than
# "unreachable".
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
  path="${2:-}"
  case "$path" in
    repos/*/contents/*)
      [[ -z "${GH_API_CALLS:-}" ]] || printf '%s\n' "$path" >> "$GH_API_CALLS"
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
      ;;
    repos/*)
      echo '{}'
      exit 0
      ;;
  esac
  exit 1
fi
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
  # shellcheck source=lib/toggle.sh
  . "$SCRIPT_DIR/lib/toggle.sh"
  # shellcheck source=lib/merge-budget.sh
  . "$SCRIPT_DIR/lib/merge-budget.sh"
  # shellcheck source=lib/merge-autonomy.sh
  . "$SCRIPT_DIR/lib/merge-autonomy.sh"
  # shellcheck disable=SC2317  # Called from the lifted block, on its truncation and guard paths.
  log_event() { :; }
  # shellcheck disable=SC2317  # Likewise — the lifted block's guard_warn on a claim-count failure.
  guard_warn() { :; }
  SCRIPT_DIR="$tmp_dir/root"
  # shellcheck disable=SC2034  # Read by the lifted block: the label it lists PRs by...
  pr_label="autonomous-agent"
  # shellcheck disable=SC2034  # ...and the repo list it walks.
  all_repos_json="$REPOS_JSON"
  # shellcheck disable=SC2034  # Read by merge_autonomy_effective_level, once per repo, inside the block.
  DEFAULTED_CONFIG="$CFG_JSON"
  # shellcheck disable=SC2034  # Empty (the default) means "no fleet flags", so the level resolves from
  # DEFAULTED_CONFIG alone with no gh call at all (fleet_flag_fetch_status's own no-repo short circuit).
  # STATE_REPO overrides this for the memoisation assertions below, which need
  # a real fleet flag fetch to count calls against.
  state_repo="${STATE_REPO:-}"
  # shellcheck disable=SC2034
  state_dir="${STATE_DIR:-$tmp_dir/state}"
  eval "$counting_block"
  # shellcheck disable=SC2154  # All three are assigned by the lifted block — they are what it is for.
  printf '%s\n%s\n%s\n' "$open_composition" "$adjusted_open_count" "$raw_open_count"
}

calls_file="$tmp_dir/claim-calls"
: > "$calls_file"
out="$(PATH="$stub_bin:$PATH" \
       GH_STUB_LISTINGS="$listings" CLAIM_CALLS="$calls_file" CLAIM_COUNTS="$counts_dir" \
       REPOS_JSON='[{"slug":"Poetic-Poems/agent-ops"},{"slug":"Poetic-Poems/poetic"}]' \
       CFG_JSON='{}' \
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

# --- D18 WI-6: the exclusion is level-aware. A second, standalone repo,
#     configured at agent-merges-routine, with one approved (not
#     CHANGES_REQUESTED) ready PR that the plain rule above would exclude —
#     above this level there is no human queue for it to be parked in, so it
#     must count, and its claim must not double-count on top of it. ---

cat > "$listings/Poetic-Poems__poetic-fiddle.json" <<'JSON'
[{"number":900,"isDraft":false,"reviewDecision":"APPROVED"}]
JSON
printf '0' > "$counts_dir/Poetic-Poems__poetic-fiddle"

calls_file2="$tmp_dir/claim-calls-2"
: > "$calls_file2"
out2="$(PATH="$stub_bin:$PATH" \
        GH_STUB_LISTINGS="$listings" CLAIM_CALLS="$calls_file2" CLAIM_COUNTS="$counts_dir" \
        REPOS_JSON='[{"slug":"Poetic-Poems/poetic-fiddle"}]' \
        CFG_JSON='{"repos":[{"slug":"Poetic-Poems/poetic-fiddle","merge_autonomy":"agent-merges-routine"}]}' \
        run_block 2>/dev/null)"
composition2="$(sed -n '1p' <<<"$out2")"
adjusted2="$(sed -n '2p' <<<"$out2")"

assert_eq "at agent-merges-routine, an approved ready PR counts toward the cap — no human queue to exclude it from" \
  "1 changes-requested + 0 draft + 0 unraised claim(s) — plus 0 waiting on human (1 raw)" \
  "$composition2"
assert_eq "…so the trip figure includes it" "1" "$adjusted2"
assert_eq "…and its claim does not double-count on top of it — the PR itself is already in counted_prs" \
  "count|Poetic-Poems/poetic-fiddle|900" "$(sed -n '1p' "$calls_file2")"

# The same repo at the default level (human) excludes the identical PR, so
# the difference above is the level, not a change to the underlying rule.
calls_file3="$tmp_dir/claim-calls-3"
: > "$calls_file3"
out3="$(PATH="$stub_bin:$PATH" \
        GH_STUB_LISTINGS="$listings" CLAIM_CALLS="$calls_file3" CLAIM_COUNTS="$counts_dir" \
        REPOS_JSON='[{"slug":"Poetic-Poems/poetic-fiddle"}]' \
        CFG_JSON='{}' \
        run_block 2>/dev/null)"
adjusted3="$(sed -n '2p' <<<"$out3")"
assert_eq "at human (the default), the identical approved PR is excluded, and the trip figure is 0" \
  "0" "$adjusted3"
assert_eq "…and its claim is what keeps counting instead" \
  "count|Poetic-Poems/poetic-fiddle|" "$(sed -n '1p' "$calls_file3")"

# --- Issue #502 (PR #499 review follow-up): fleet_flag_fetch_status
#     memoises a live/clear answer per (flag, state_dir) for the life of this
#     process, so the block's own per-repo loop — which reads the kill switch
#     once per repository, all inside this one run_block invocation — must
#     hit the network for it at most once regardless of repository count. And
#     the reordered merge_autonomy_effective_level (same PR) must never even
#     ask for a repo's freeze flag when its configured level already ranks at
#     or below agent-approves, where the freeze's own answer would go
#     unread. GH_API_CALLS records every `gh api repos/*/contents/*` call the
#     stub above serves — one line per call — so both are countable. ---

fleet_calls="$tmp_dir/fleet-calls"
for repo_file in acme__repo-a acme__repo-b acme__repo-c; do
  printf '[]\n' > "$listings/$repo_file.json"
  printf '0' > "$counts_dir/$repo_file"
done

: > "$fleet_calls"
PATH="$stub_bin:$PATH" \
  GH_STUB_LISTINGS="$listings" CLAIM_CALLS="$tmp_dir/claim-calls-4" CLAIM_COUNTS="$counts_dir" \
  GH_API_CALLS="$fleet_calls" \
  STATE_REPO="acme/fleet-state" STATE_DIR="$tmp_dir/state-memo" \
  REPOS_JSON='[{"slug":"acme/repo-a"},{"slug":"acme/repo-b"},{"slug":"acme/repo-c"}]' \
  CFG_JSON='{}' \
  run_block >/dev/null 2>/dev/null

assert_eq "one kill-switch fetch per cycle regardless of repository count" "1" \
  "$(grep -c 'merge-autonomy-kill\.json' "$fleet_calls")"
assert_eq "no freeze-flag fetch for a repository whose configured level ranks at or below agent-approves" "0" \
  "$(grep -c 'merge-budget-freeze-' "$fleet_calls")"

# A single repo configured *above* agent-approves does need the freeze's own
# answer — confirming the zero above is about the level, not the freeze fetch
# having been removed altogether.
: > "$fleet_calls"
PATH="$stub_bin:$PATH" \
  GH_STUB_LISTINGS="$listings" CLAIM_CALLS="$tmp_dir/claim-calls-5" CLAIM_COUNTS="$counts_dir" \
  GH_API_CALLS="$fleet_calls" \
  STATE_REPO="acme/fleet-state" STATE_DIR="$tmp_dir/state-memo-2" \
  REPOS_JSON='[{"slug":"acme/repo-a"}]' \
  CFG_JSON='{"repos":[{"slug":"acme/repo-a","merge_autonomy":"agent-merges-routine"}]}' \
  run_block >/dev/null 2>/dev/null

assert_eq "…while a repo ranked above agent-approves does fetch its freeze flag" "1" \
  "$(grep -c 'merge-budget-freeze-acme-repo-a\.json' "$fleet_calls")"

# --- approver_escalate's warning path (PR #499 review follow-up) ---
#
# The pre-existing SC2154 #499's PR body flagged: `--arg d "…could not settle
# $u…"` interpolated a bash variable `u` that is never assigned in this
# file — `$u` is jq's own `--arg u`, not a shell variable — so under `set -u`
# (which agent-cycle.sh runs under) the expansion aborted that command
# substitution and `log_event "warning" ""` logged an event with no fields at
# all: no detail, and — on the one line where a human most needs it — no
# pr_url either. Lifted verbatim out of agent-cycle.sh, the same way the
# counting block above is, so this is testing the shipped function, not a
# copy of it.
approver_escalate_fn="$(awk -v fn='^approver_escalate\\(\\) \\{' \
  '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$AGENT_APPROVER_LIB")"
if [[ -z "$approver_escalate_fn" ]]; then
  echo "FAIL - could not extract approver_escalate from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

run_approver_escalate() {
  eval "$approver_escalate_fn"
  # shellcheck disable=SC2317  # Stubbed: this covers only the "adjudication could not settle,
  # and the escalation issue could not be filed either" warning path — the
  # dedup/success path is create_escalation_issue's own test, not this one's.
  create_escalation_issue() { return 1; }
  # shellcheck disable=SC2034  # Read by the eval'd approver_escalate body below, standing in for
  # the state a real cycle already has in scope by the time it calls this function — invisible to
  # the linter, the same way every other lifted-block variable in this file already is.
  cycle_dir="$tmp_dir/approver-escalate-cycle"
  mkdir -p "$cycle_dir"
  # shellcheck disable=SC2034
  cycle_id="test-cycle"
  # shellcheck disable=SC2034
  node_name="test-node"
  # shellcheck disable=SC2034
  enabler_escalation_label="enabler-escalation"
  # shellcheck disable=SC2034
  selected_repo="acme/widgets"
  log_calls="$tmp_dir/approver-escalate-log-calls"
  : > "$log_calls"
  # shellcheck disable=SC2317
  log_event() { printf '%s\t%s\n' "$1" "$2" >> "$log_calls"; }
  approver_escalate "https://github.com/acme/widgets/pull/42" '["reason one","reason two"]'
  cat "$log_calls"
}
escalate_out="$(run_approver_escalate 2>/dev/null)"
escalate_event="$(cut -f1 <<<"$escalate_out")"
escalate_json="$(cut -f2- <<<"$escalate_out")"

assert_eq "exactly one event is logged" "1" "$(wc -l < <(printf '%s\n' "$escalate_out") | tr -d ' ')"
assert_eq "…as a warning" "warning" "$escalate_event"
assert_eq "…carrying pr_url, not silently dropped by the \$u bug" \
  "https://github.com/acme/widgets/pull/42" "$(jq -r '.pr_url' <<<"$escalate_json")"
assert_eq "…and carrying a non-empty detail naming the same pull request" "true" \
  "$(jq --arg u "https://github.com/acme/widgets/pull/42" \
     '(.detail // "") != "" and ((.detail // "") | contains($u))' <<<"$escalate_json")"

# The same scan #499 added, adjusted for #771 rather than dropped. What it is
# for is unchanged: a `$name` interpolated in agent-cycle.sh that no shell
# variable anywhere provides — `--arg d "…$u…"`, where `u` is jq's own
# argument and not a shell variable at all, which under `set -u` aborts the
# command substitution and logs an event with no fields.
#
# What changed is that agent-cycle.sh is now the cycle's spine and reads
# globals the lib/*.sh modules assign, and shellcheck without `-x` sees none
# of them — while `-x` here would parse the whole 26,000-line union and need
# more than 4.5 GiB, which is the very thing #770/#771 are about. So each
# SC2154 is resolved against the modules by hand: a name some module assigns
# *as a global* is an artefact of the unfollowed sources, and a name nothing
# assigns is the bug this scan exists to catch. "As a global" means assigned
# in a module that never declares it `local` — without which a jq `--arg u`
# would be excused by any `local u` in any module, which is exactly the
# finding #499 was about.
sc2154_names="$(shellcheck --severity=warning -f gcc "$AGENT_CYCLE" 2>/dev/null \
  | sed -n 's/.*: \([A-Za-z_][A-Za-z0-9_]*\) is referenced but not assigned.*/\1/p' \
  | sort -u)"
sc2154_unresolved=""
while IFS= read -r sc_name; do
  [[ -n "$sc_name" ]] || continue
  sc_global=0
  for sc_lib in "$AGENT_LIB_DIR"/*.sh; do
    grep -qE "(^|[^A-Za-z0-9_])${sc_name}=" "$sc_lib" || continue
    grep -qE "^[[:space:]]*(local|declare|typeset)([[:space:]]+-[A-Za-z]+)*[[:space:]].*(^|[^A-Za-z0-9_])${sc_name}([=[:space:]]|\$)" \
      "$sc_lib" && continue
    sc_global=1
    break
  done
  (( sc_global )) || sc2154_unresolved+="$sc_name "
done <<<"$sc2154_names"
assert_eq "every SC2154 in agent-cycle.sh names a global some lib/*.sh module assigns" \
  "" "${sc2154_unresolved% }"

# --- Report -------------------------------------------------------------------

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
