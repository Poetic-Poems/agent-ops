#!/usr/bin/env bash
#
# test/issue-priority.test.sh — regression test for issue priority banding
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 15e).
#
# An open issue's rank in the Co-Ordinator's walk is its `Priority` issue field:
# `Urgent` outranks everything but security, `High` beats tech-debt, `Medium` is
# where issues have always sat, `Low` sits just above the automated findings. Two
# halves of that have to hold outside the model, and both fail silently if broken:
#
#   - **The default.** An issue with no `Priority` is `Medium`. Get this wrong in
#     the "lowest" direction and every untriaged issue in both repos is demoted
#     the moment the change lands — a fleet-wide re-prioritisation nobody asked
#     for, visible only as issues that stop being picked. Get it wrong in the
#     "highest" direction and an untriaged backlog outranks the finishing
#     sources. The band must also survive an organisation adding a fifth option
#     to the field, which is a thing an admin can do at any time without telling
#     anyone.
#   - **The fingerprint.** Re-prioritising an issue changes what the Co-Ordinator
#     would select while touching no commit, no alert and no PR. If the band is
#     not in the source-state digest, two cycles either side of a re-triage
#     fingerprint identically and the cycle skips — and goes on skipping. That is
#     this system's signature failure (see the Gotchas table): green, logged, and
#     idle.
#
# `scripts/gather-source-state.sh` is run for real here against a stubbed `gh`,
# so the assertions are about the shipped filter rather than a copy of it.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/issue-priority.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/noop-skip.sh
. "$SCRIPT_DIR/lib/noop-skip.sh"

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

# --- A stub `gh`, so the real gatherer runs offline ---
#
# It answers the four endpoints gather-source-state.sh calls and mimics the one
# behaviour of `gh api --jq` that the script depends on: string results print
# raw, not as JSON (which is why the script pipes scalars through `@json`).
# `jq -rc` reproduces that exactly.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected command: $*" >&2; exit 1; }
path="$2"; shift 2
filter='.'
while [[ $# -gt 0 ]]; do
  case "$1" in --jq) filter="$2"; shift 2;; *) shift;; esac
done
case "$path" in
  */commits/*)     body='{"sha":"aaa111"}';;
  */issues\?*)     body="$(cat "$STUB_ISSUES")";;
  */actions/runs*) body='{"workflow_runs":[]}';;
  */pulls\?*)      body='[]';;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1;;
esac
jq -rc "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# --- The fixture: one issue per way the field can present itself ---
#
# #1–#4 are the four names; #5 has an empty `issue_field_values` (the shape
# GitHub returns for an issue nobody has triaged); #6 carries other fields but
# no `Priority`; #7 carries a `Priority` whose option the organisation added
# after this code was written; #8 is a pull request, which the issues endpoint
# returns alongside issues and which must not reach the digest at all.
export STUB_ISSUES="$tmp_dir/issues.json"
cat >"$STUB_ISSUES" <<'EOF'
[
  {"number": 1, "updated_at": "2026-07-20T09:00:00Z", "labels": [{"name": "bug"}], "assignee": null,
   "issue_field_values": [{"issue_field_name": "Priority", "single_select_option": {"name": "Urgent"}}]},
  {"number": 2, "updated_at": "2026-07-20T09:00:00Z", "labels": [], "assignee": null,
   "issue_field_values": [{"issue_field_name": "Priority", "single_select_option": {"name": "High"}}]},
  {"number": 3, "updated_at": "2026-07-20T09:00:00Z", "labels": [], "assignee": null,
   "issue_field_values": [{"issue_field_name": "Priority", "single_select_option": {"name": "Medium"}}]},
  {"number": 4, "updated_at": "2026-07-20T09:00:00Z", "labels": [], "assignee": null,
   "issue_field_values": [{"issue_field_name": "Priority", "single_select_option": {"name": "Low"}}]},
  {"number": 5, "updated_at": "2026-07-20T09:00:00Z", "labels": [], "assignee": null,
   "issue_field_values": []},
  {"number": 6, "updated_at": "2026-07-20T09:00:00Z", "labels": [], "assignee": null,
   "issue_field_values": [{"issue_field_name": "Effort", "single_select_option": {"name": "Low"}}]},
  {"number": 7, "updated_at": "2026-07-20T09:00:00Z", "labels": [], "assignee": null,
   "issue_field_values": [{"issue_field_name": "Priority", "single_select_option": {"name": "Blocker"}}]},
  {"number": 8, "updated_at": "2026-07-20T09:00:00Z", "labels": [], "assignee": null,
   "pull_request": {"url": "https://api.github.com/repos/o/r/pulls/8"},
   "issue_field_values": [{"issue_field_name": "Priority", "single_select_option": {"name": "Urgent"}}]}
]
EOF

state="$("$SCRIPT_DIR/scripts/gather-source-state.sh" o/r main)"

assert_eq "a clean sample is ok" "true" "$(jq -r '.ok' <<<"$state")"
assert_eq "every issue is banded" \
  "1:Urgent 2:High 3:Medium 4:Low 5:Medium 6:Medium 7:Medium" \
  "$(jq -r '[.issues[] | "\(.n):\(.p)"] | join(" ")' <<<"$state")"

# Each default, named, so an edit that breaks one fails loudly rather than
# quietly re-ranking a backlog:
assert_eq "an untriaged issue (no field values) is Medium, not lowest" \
  "Medium" "$(jq -r '.issues[] | select(.n == 5) | .p' <<<"$state")"
assert_eq "an issue with other fields but no Priority is Medium" \
  "Medium" "$(jq -r '.issues[] | select(.n == 6) | .p' <<<"$state")"
assert_eq "an option the organisation added later is Medium, not its own band" \
  "Medium" "$(jq -r '.issues[] | select(.n == 7) | .p' <<<"$state")"

# The endpoint returns PRs too. #8 is deliberately Urgent so that a regression
# which lets pull requests through would show up here as the loudest band.
assert_eq "pull requests are still dropped from the issues digest" \
  "false" "$(jq -r 'any(.issues[]; .n == 8)' <<<"$state")"

# The rest of the digest is unchanged by banding — labels and assignee are
# requirement 16.4's exclusion criteria and must still be sampled.
assert_eq "labels and assignee are still digested alongside the band" \
  '{"n":1,"u":"2026-07-20T09:00:00Z","l":["bug"],"a":"","p":"Urgent"}' \
  "$(jq -c '.issues[] | select(.n == 1)' <<<"$state")"

# --- The fingerprint moves when a band moves ---
#
# Two samples identical but for one issue's Priority. If these fingerprint the
# same, a re-triage never wakes the Co-Ordinator and the item waits for an
# unrelated commit to land.
fp_input() {
  jq -nc --argjson state "$1" '
    {repos: [{slug: "o/r", default_branch: "main", sources: ["issues:medium"],
              findings: [], review_feedback: [], state: $state}],
     blocked: [], void: [], enabler_eligible: [],
     selection_config: {}, coordinator_prompt_sha: "deadbeef",
     enabler_config: {}, enabler_prompt_sha: "cafebabe"}'
}

fp_before="$(fp_input "$state" | noop_fingerprint)"
assert_eq "the sample is fingerprintable" "64" "${#fp_before}"

jq -c '(.[] | select(.number == 4) | .issue_field_values[0].single_select_option.name) = "Urgent"' \
  "$STUB_ISSUES" >"$tmp_dir/issues-retriaged.json"
mv "$tmp_dir/issues-retriaged.json" "$STUB_ISSUES"

state_after="$("$SCRIPT_DIR/scripts/gather-source-state.sh" o/r main)"
assert_eq "the re-triaged issue is the only difference in the digest" \
  "Urgent" "$(jq -r '.issues[] | select(.n == 4) | .p' <<<"$state_after")"
assert_eq "issue #4's updated_at deliberately did not move" \
  "$(jq -c '[.issues[] | {n, u, l, a}]' <<<"$state")" \
  "$(jq -c '[.issues[] | {n, u, l, a}]' <<<"$state_after")"

fp_after="$(fp_input "$state_after" | noop_fingerprint)"
if [[ "$fp_before" != "$fp_after" ]]; then
  printf 'ok   - %s\n' "re-prioritising an issue busts the no-op fingerprint"
else
  printf 'FAIL - %s\n     both cycles fingerprinted: %s\n' \
    "re-prioritising an issue busts the no-op fingerprint" "$fp_before"
  failures=$(( failures + 1 ))
fi

# --- Failure is still failure ---
#
# The whole safety argument of gather-source-state.sh is that a failed call is
# never an empty result. Banding must not have introduced a path where a broken
# issues endpoint reads as "no issues, all Medium".
rm -f "$STUB_ISSUES"
state_broken="$("$SCRIPT_DIR/scripts/gather-source-state.sh" o/r main)"
assert_eq "an unreadable issues endpoint marks the sample not-ok" \
  "false" "$(jq -r '.ok' <<<"$state_broken")"
assert_eq "and still prints a valid object rather than aborting the cycle" \
  "0" "$(jq -e . >/dev/null 2>&1 <<<"$state_broken"; echo $?)"

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
