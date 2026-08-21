#!/usr/bin/env bash
#
# test/autonomy-stage-report.test.sh — regression test for
# scripts/autonomy-stage-report.sh (issue #571, D18 WI of umbrella #402).
#
# Four repositories, one per scenario the acceptance criteria name:
#
#   o/human-repo      Stage 0 (`human`, the config default). Both its
#                     criteria are mechanically checkable today (a baseline
#                     file exists; `merge_autonomy` is configured somewhere) —
#                     this is the "repo meeting bars" case, verdict `met`.
#   o/approves-repo   Stage 1 (`agent-approves`). Two agent-approved pull
#                     requests, short of the ≥15 bar — the "failing one" case,
#                     verdict `not-met (criterion: agent_approved_prs)`, even
#                     though the stage's other criterion (divergence) is
#                     *also* `unavailable` here (both its pull requests are
#                     unreadable from GitHub in this fixture): a genuine
#                     failure must still win over a merely-missing
#                     measurement. Also proves the `pr_url` match is
#                     exact-prefix, not substring: a decoy
#                     `o/approves-repo-extra` approval must not be counted.
#   o/routine-repo    Stage 2/3 (`agent-merges-routine`). 15 autonomous
#                     landings (met) and a clean current revert rate against
#                     the recorded Stage 0 baseline (met) — but
#                     `classifier_escapes` has no detector yet (agent-ops#572)
#                     and is always `unavailable`. This is the "missing data
#                     source" case: every measurable criterion passes and the
#                     verdict is still `insufficient-evidence`, never `met`
#                     (acceptance 3).
#   o/divergence-repo Stage 1 (`agent-approves`), exercising the real
#                     divergence join (agent-ops#573) rather than the
#                     unavailable fallback: five agent-approved pull requests,
#                     all landed and none carrying a standing human
#                     `CHANGES_REQUESTED` — `divergence` reads `met` (a real
#                     zero, backed by a sample), and since
#                     `agent_approved_prs` also clears its own ≥15-or-elapsed
#                     bar isn't needed here (only `divergence` is asserted;
#                     `agent_approved_prs` is left `not-met` on 5 pull
#                     requests, which is fine — this repo's fixture exists to
#                     prove the divergence join, not to double as Stage 1's
#                     full exit).
#
# `gh` is stubbed via `PATH`, the same technique test/mine-merge-history.test.sh
# uses — reused here as-is because scripts/autonomy-stage-report.sh shells out
# to the real scripts/mine-merge-history.sh for the current revert rate, and
# both scripts read the same GitHub REST endpoints.
#
# Run directly:
#
#   ./test/autonomy-stage-report.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$SCRIPT_DIR/scripts/autonomy-stage-report.sh"

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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n' "$desc" "$needle"
    failures=$(( failures + 1 ))
  fi
}

# --- Fixture: config, state log, baseline files, merged-PR listing ---------

mkdir -p "$tmp_dir/bin" "$tmp_dir/state" "$tmp_dir/peers" "$tmp_dir/reviews" "$tmp_dir/fixtures"
STUB_DIR="$tmp_dir/fixtures"

cat > "$tmp_dir/config.json" <<'EOF'
{
  "repos": [
    {"slug": "o/human-repo", "sources": ["abandoned-drafts"]},
    {"slug": "o/approves-repo", "sources": ["abandoned-drafts"], "merge_autonomy": "agent-approves"},
    {"slug": "o/routine-repo", "sources": ["abandoned-drafts"], "merge_autonomy": "agent-merges-routine"},
    {"slug": "o/divergence-repo", "sources": ["abandoned-drafts"], "merge_autonomy": "agent-approves"}
  ],
  "state_dir": "/unused",
  "workspace_root": "/unused",
  "coordinator_model": "claude-haiku-4-5-20251001",
  "implementer_model_default": "claude-sonnet-5",
  "implementer_model_trivial": "claude-haiku-4-5-20251001",
  "reviewer_model_default": "claude-sonnet-5",
  "pr_label": "agent-test-label",
  "branch_prefix": "agent/",
  "max_open_agent_prs": 8,
  "limit_cooldown_default": 3
}
EOF

# state log: 2 approver-verdicts for o/approves-repo (short of the 15 bar),
# one decoy approval for a same-prefix-but-different repo (must not count),
# and 15 landing-armed events for o/routine-repo (clears the 15 bar outright,
# so this fixture does not need to exercise the elapsed-time alternative).
{
  printf '{"ts":"2026-08-01T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/approves-repo/pull/1","tier":"medium","verdict":"approve","refuse_streak":0,"adjudication":false}\n'
  printf '{"ts":"2026-08-02T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/approves-repo/pull/2","tier":"medium","verdict":"land","refuse_streak":1,"adjudication":true}\n'
  printf '{"ts":"2026-08-03T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/approves-repo-extra/pull/9","tier":"medium","verdict":"approve","refuse_streak":0,"adjudication":false}\n'
  for i in $(seq 101 115); do
    printf '{"ts":"2026-08-%02dT00:00:00Z","node":"n","event":"landing-armed","repo":"o/routine-repo","pr_url":"https://github.com/o/routine-repo/pull/%d","source":"tech-debt","complexity":"medium","method":"auto-merge"}\n' "$(( (i - 100) % 28 + 1 ))" "$i"
  done
  # o/divergence-repo (agent-ops#573): 5 approved-and-landed pull requests,
  # none carrying a standing human CHANGES_REQUESTED — a real, sample-backed
  # zero, not the criterion's `unavailable` fallback.
  for i in $(seq 1 5); do
    printf '{"ts":"2026-08-%02dT00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/divergence-repo/pull/%d","repo":"o/divergence-repo","tier":"medium","model":"claude-sonnet-5","verdict":"approve","refuse_streak":0,"adjudication":false,"posted":true}\n' "$i" "$i"
  done
} > "$tmp_dir/state/log.jsonl"

# Two baseline files; the earlier one (2026-08-01) must be the one read as
# "the" Stage 0 baseline, not the later (2026-08-10, deliberately worse) one.
mkdir -p "$tmp_dir/reviews"
cat > "$tmp_dir/reviews/2026-08-01-merge-autonomy-baseline.md" <<'EOF'
# Merge-Autonomy Baseline — 2026-08-01

## Raw data

```json
{"generated":"2026-08-01","label":"agent-test-label","repos":{"o/routine-repo":{"count":10,"post_merge":{"reverts":1,"follow_up_fixes":1,"clean":8}}}}
```
EOF
cat > "$tmp_dir/reviews/2026-08-10-merge-autonomy-baseline.md" <<'EOF'
# Merge-Autonomy Baseline — 2026-08-10

## Raw data

```json
{"generated":"2026-08-10","label":"agent-test-label","repos":{"o/routine-repo":{"count":10,"post_merge":{"reverts":9,"follow_up_fixes":0,"clean":1}}}}
```
EOF

# The merged-PR listing for o/routine-repo: 15 merged, label-carrying pull
# requests, #101-#115, matching the landing-armed events above by URL. Read
# both directly (the report's own autonomous-landings join) and by the
# scripts/mine-merge-history.sh subprocess the revert-rate criterion shells
# out to for the current rate.
{
  printf '['
  for i in $(seq 101 115); do
    [[ "$i" == "101" ]] || printf ','
    printf '{"number":%d,"title":"fix: routine change %d","created_at":"2026-08-%02dT00:00:00Z","pull_request":{"merged_at":"2026-08-%02dT01:00:00Z","html_url":"https://github.com/o/routine-repo/pull/%d"}}' \
      "$i" "$i" "$(( (i - 100) % 28 + 1 ))" "$(( (i - 100) % 28 + 1 ))" "$i"
  done
  printf ']'
} > "$STUB_DIR/routine-hits.json"

cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected command: $*" >&2; exit 1; }
shift
path=""
filter='.'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) filter="$2"; shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) path="$1"; shift ;;
  esac
done
case "$path" in
  repos/o/routine-repo/issues\?labels=*) body="$(cat "$STUB_DIR/routine-hits.json")" ;;
  repos/*/pulls/*/reviews\?*) body='[]' ;;
  repos/*/pulls/*/files\?*) body='[]' ;;
  repos/*/issues/*/timeline\?*) body='[]' ;;
  # agent-ops#573's divergence join: each divergence-repo pull request is
  # merged, with no standing review at all — a real, sample-backed
  # agreement, not the criterion's `unavailable` fallback.
  repos/o/divergence-repo/pulls/[0-9]*/reviews) body='[]' ;;
  repos/o/divergence-repo/pulls/[0-9]*) body='{"state":"closed","merged":true}' ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1 ;;
esac
jq -r "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export STUB_DIR
export PATH="$tmp_dir/bin:$PATH"

out="$("$REPORT" --config "$tmp_dir/config.json" \
  --repo o/human-repo --repo o/approves-repo --repo o/routine-repo --repo o/divergence-repo \
  --label agent-test-label \
  --reviews-dir "$tmp_dir/reviews" \
  --state-dir "$tmp_dir/state" --peers-dir "$tmp_dir/peers" \
  --now "2026-08-20T00:00:00Z" 2>"$tmp_dir/run.err")"
rc=$?
assert_eq "a clean run exits 0" "0" "$rc"
assert_eq "  ... and stderr is silent" "" "$(cat "$tmp_dir/run.err")"

raw_json="$(awk '/```json/{flag=1;next}/```/{flag=0}flag' <<<"$out")"
assert_eq "raw JSON parses" "4" "$(jq -r '.repos | length' <<<"$raw_json")"

# --- Scenario 1: o/human-repo (Stage 0) — meets both its bars --------------
human="$(jq -c '.repos[] | select(.slug == "o/human-repo")' <<<"$raw_json")"
assert_eq "human-repo: level" "human" "$(jq -r '.level' <<<"$human")"
assert_eq "human-repo: stage" "0" "$(jq -r '.stage' <<<"$human")"
assert_eq "human-repo: baseline_recorded met" "met" "$(jq -r '.criteria[] | select(.id == "baseline_recorded") | .status' <<<"$human")"
assert_eq "human-repo: d18_on_main met" "met" "$(jq -r '.criteria[] | select(.id == "d18_on_main") | .status' <<<"$human")"
assert_eq "human-repo: verdict met" "met" "$(jq -r '.verdict' <<<"$human")"

# --- Scenario 2: o/approves-repo (Stage 1) — fails its measurable bar ------
approves="$(jq -c '.repos[] | select(.slug == "o/approves-repo")' <<<"$raw_json")"
assert_eq "approves-repo: level" "agent-approves" "$(jq -r '.level' <<<"$approves")"
assert_eq "approves-repo: stage" "1" "$(jq -r '.stage' <<<"$approves")"
assert_eq "approves-repo: counts exactly its own 2 approvals (decoy excluded)" \
  "2 agent-approved pull request(s) (need ≥15)" \
  "$(jq -r '.criteria[] | select(.id == "agent_approved_prs") | .measured' <<<"$approves")"
assert_eq "approves-repo: agent_approved_prs not-met" "not-met" "$(jq -r '.criteria[] | select(.id == "agent_approved_prs") | .status' <<<"$approves")"
assert_eq "approves-repo: divergence unavailable" "unavailable" "$(jq -r '.criteria[] | select(.id == "divergence") | .status' <<<"$approves")"
assert_eq "approves-repo: a real failure outranks a merely-missing measurement" \
  "not-met (criterion: agent_approved_prs)" "$(jq -r '.verdict' <<<"$approves")"

# --- Scenario 3: o/routine-repo (Stage 2/3) — every measurable bar passes,
#     classifier_escapes is still unavailable, and the verdict must show it
#     rather than reading "met" ----------------------------------------------
routine="$(jq -c '.repos[] | select(.slug == "o/routine-repo")' <<<"$raw_json")"
assert_eq "routine-repo: level" "agent-merges-routine" "$(jq -r '.level' <<<"$routine")"
assert_eq "routine-repo: stage" "2/3" "$(jq -r '.stage' <<<"$routine")"
assert_eq "routine-repo: 15 autonomous landings clears the bar" "met" "$(jq -r '.criteria[] | select(.id == "autonomous_landings") | .status' <<<"$routine")"
assert_contains "  ... and says how many" "$(jq -r '.criteria[] | select(.id == "autonomous_landings") | .measured' <<<"$routine")" "15 autonomous landing(s)"
assert_eq "routine-repo: current revert rate (0) against the *earliest* baseline (0.2, not the later 0.9) — met" \
  "met" "$(jq -r '.criteria[] | select(.id == "revert_rate") | .status' <<<"$routine")"
assert_contains "  ... measured against the earlier baseline's rate" \
  "$(jq -r '.criteria[] | select(.id == "revert_rate") | .measured' <<<"$routine")" "0.2"
assert_eq "routine-repo: classifier_escapes always unavailable (agent-ops#572)" \
  "unavailable" "$(jq -r '.criteria[] | select(.id == "classifier_escapes") | .status' <<<"$routine")"
assert_eq "routine-repo: every measurable bar met, but the verdict is still insufficient-evidence, never met" \
  "insufficient-evidence" "$(jq -r '.verdict' <<<"$routine")"

# --- Scenario 4: o/divergence-repo (Stage 1) — the real divergence join
#     (agent-ops#573), not the unavailable fallback ---------------------------
divergence="$(jq -c '.repos[] | select(.slug == "o/divergence-repo")' <<<"$raw_json")"
assert_eq "divergence-repo: level" "agent-approves" "$(jq -r '.level' <<<"$divergence")"
assert_eq "divergence-repo: stage" "1" "$(jq -r '.stage' <<<"$divergence")"
assert_eq "divergence-repo: divergence criterion reads met, backed by a real sample" \
  "met" "$(jq -r '.criteria[] | select(.id == "divergence") | .status' <<<"$divergence")"
assert_contains "  ... and states the sample it is backed by" \
  "$(jq -r '.criteria[] | select(.id == "divergence") | .measured' <<<"$divergence")" "5 agreement, 0 divergence"

assert_contains "the Markdown body cites the stage-table source" "$out" "agent-ops#402"
assert_contains "  ... and includes the divergence-repo's own section" "$out" "o/divergence-repo"

echo "---"
if [[ "$failures" -eq 0 ]]; then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
