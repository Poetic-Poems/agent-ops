#!/usr/bin/env bash
#
# test/verdict-fate-report.test.sh — regression test for
# scripts/verdict-fate-report.sh, the I/O wrapper around lib/verdict-fate.sh
# (agent-ops#573, D18 WI of umbrella #402).
#
# One repository exercising every fate the issue's own vocabulary names:
#
#   pull/1  APPROVE, closed unmerged                 -> divergence
#   pull/2  APPROVE, landed (a landing-armed event exists) -> agreement
#   pull/3  APPROVE, a human CHANGES_REQUESTED, then a *second* APPROVE
#           once `review-feedback` brought it back round — still open
#                                                      -> divergence,
#           its own fate (`changes-requested-after-approval`), never
#           collapsed into `closed-unmerged`. The human's review falls
#           between the two approvals, so this entry stays a divergence only
#           while the window is tested against the pull request's *first*
#           approval; against the latest verdict's own `ts` the human's
#           review reads as "before" the approval and the divergence
#           vanishes, which is exactly what agent-ops#661 fixed. This is the
#           end-to-end guard on that fix: `verdict_fate_latest_per_pr`
#           carrying `first_approve_ts` is worth nothing if a caller does not
#           thread it through to `verdict_fate_classify`.
#   pull/4  REQUEST_CHANGES, closed unmerged (the human agreed) -> agreement
#   pull/5  APPROVE, still open, no standing request    -> pending, excluded
#           from the sample
#   pull/6  a superseded verdict: `refuse` then `approve` on the same pull
#           request — only the later `approve` (and pull/6's own eventual
#           GitHub state, still open) is read; the superseded refusal never
#           contributes a second entry
#   pull/9  under `o/repo-extra`, a same-prefix decoy that must never be
#           counted toward `o/repo`
#
# `gh` is stubbed via `PATH`, the same technique
# test/autonomy-stage-report.test.sh already uses.
#
# Run directly:
#
#   ./test/verdict-fate-report.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$SCRIPT_DIR/scripts/verdict-fate-report.sh"

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

mkdir -p "$tmp_dir/bin" "$tmp_dir/state" "$tmp_dir/peers"

cat > "$tmp_dir/config.json" <<'EOF'
{
  "repos": [
    {"slug": "o/repo", "sources": ["abandoned-drafts"], "merge_autonomy": "agent-approves"}
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

{
  printf '{"ts":"2026-08-01T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/1","repo":"o/repo","tier":"medium","model":"m1","verdict":"approve","refuse_streak":0,"adjudication":false,"posted":true}\n'
  printf '{"ts":"2026-08-02T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/2","repo":"o/repo","tier":"medium","model":"m1","verdict":"approve","refuse_streak":0,"adjudication":false,"posted":true}\n'
  printf '{"ts":"2026-08-02T00:00:00Z","node":"n","event":"landing-armed","repo":"o/repo","pr_url":"https://github.com/o/repo/pull/2","source":"tech-debt","complexity":"medium","method":"auto-merge"}\n'
  printf '{"ts":"2026-08-03T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/3","repo":"o/repo","tier":"medium","model":"m1","verdict":"approve","refuse_streak":0,"adjudication":false,"posted":true}\n'
  # pull/3's re-approval (agent-ops#661): the human's CHANGES_REQUESTED in the
  # stub below is stamped 06:00, between this pull request's first approval and
  # this one. Both approvals are stamped the same day as the first, so the
  # --since window the last assertion uses still excludes pull/3 entirely and
  # its own count is unchanged by this event.
  printf '{"ts":"2026-08-03T12:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/3","repo":"o/repo","tier":"medium","model":"m1","verdict":"approve","refuse_streak":0,"adjudication":false,"posted":true}\n'
  printf '{"ts":"2026-08-04T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/4","repo":"o/repo","tier":"medium","model":"m1","verdict":"refuse","refuse_streak":0,"adjudication":false,"posted":true}\n'
  printf '{"ts":"2026-08-05T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/5","repo":"o/repo","tier":"medium","model":"m1","verdict":"approve","refuse_streak":0,"adjudication":false,"posted":true}\n'
  printf '{"ts":"2026-08-06T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/6","repo":"o/repo","tier":"medium","model":"m1","verdict":"refuse","refuse_streak":1,"adjudication":false,"posted":true}\n'
  printf '{"ts":"2026-08-07T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/repo/pull/6","repo":"o/repo","tier":"medium","model":"m1","verdict":"approve","refuse_streak":0,"adjudication":false,"posted":true}\n'
  printf '{"ts":"2026-08-01T00:00:00Z","node":"n","event":"approver-verdict","pr_url":"https://github.com/o/repo-extra/pull/9","repo":"o/repo-extra","tier":"medium","model":"m1","verdict":"approve","refuse_streak":0,"adjudication":false,"posted":true}\n'
} > "$tmp_dir/state/log.jsonl"

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
  repos/o/repo/pulls/1) body='{"state":"closed","merged":false}' ;;
  repos/o/repo/pulls/1/reviews) body='[]' ;;
  repos/o/repo/pulls/2) body='{"state":"closed","merged":true}' ;;
  repos/o/repo/pulls/2/reviews) body='[]' ;;
  repos/o/repo/pulls/3) body='{"state":"open","merged":false}' ;;
  repos/o/repo/pulls/3/reviews) body='[{"user":{"login":"human1","type":"User"},"state":"CHANGES_REQUESTED","submitted_at":"2026-08-03T06:00:00Z"}]' ;;
  repos/o/repo/pulls/4) body='{"state":"closed","merged":false}' ;;
  repos/o/repo/pulls/4/reviews) body='[]' ;;
  repos/o/repo/pulls/5) body='{"state":"open","merged":false}' ;;
  repos/o/repo/pulls/5/reviews) body='[]' ;;
  repos/o/repo/pulls/6) body='{"state":"open","merged":false}' ;;
  repos/o/repo/pulls/6/reviews) body='[]' ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1 ;;
esac
jq -r "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

out="$("$REPORT" --config "$tmp_dir/config.json" --repo o/repo \
  --state-dir "$tmp_dir/state" --peers-dir "$tmp_dir/peers" 2>"$tmp_dir/run.err")"
rc=$?
assert_eq "a clean run exits 0" "0" "$rc"
assert_eq "  ... and stderr is silent" "" "$(cat "$tmp_dir/run.err")"

raw_json="$(awk '/```json/{flag=1;next}/```/{flag=0}flag' <<<"$out")"
repo="$(jq -c '.repos[] | select(.slug == "o/repo")' <<<"$raw_json")"

assert_eq "exactly 6 entries: pull/1..6, decoy excluded" \
  "6" "$(jq '.entries | length' <<<"$repo")"
assert_eq "pull/6's superseded refusal never contributes a second entry" \
  "1" "$(jq '[.entries[] | select(.pr_url | endswith("/6"))] | length' <<<"$repo")"
assert_eq "  ... and reads its later approve, not the superseded refuse" \
  "approve" "$(jq -r '.entries[] | select(.pr_url | endswith("/6")) | .verdict' <<<"$repo")"

assert_eq "pull/1: closed unmerged after an approval -> divergence" \
  "divergence" "$(jq -r '.entries[] | select(.pr_url | endswith("/1")) | .comparison' <<<"$repo")"
assert_eq "pull/2: landed (landing-armed) -> agreement, landed-by-script" \
  "landed-by-script" "$(jq -r '.entries[] | select(.pr_url | endswith("/2")) | .fate' <<<"$repo")"
assert_eq "pull/3: a standing CHANGES_REQUESTED after approval -> its own fate" \
  "changes-requested-after-approval" "$(jq -r '.entries[] | select(.pr_url | endswith("/3")) | .fate' <<<"$repo")"
assert_eq "  ... and counts as divergence even while the pull request is still open" \
  "divergence" "$(jq -r '.entries[] | select(.pr_url | endswith("/3")) | .comparison' <<<"$repo")"
assert_eq "  ... and survives the later re-approval that supersedes the verdict (agent-ops#661)" \
  "2026-08-03T12:00:00Z" "$(jq -r '.entries[] | select(.pr_url | endswith("/3")) | .ts' <<<"$repo")"
assert_eq "  ... which is the whole point: the window is the first approval, not that later ts" \
  "2026-08-03T00:00:00Z" "$(jq -r '.entries[] | select(.pr_url | endswith("/3")) | .first_approve_ts' <<<"$repo")"
assert_eq "pull/4: REQUEST_CHANGES, closed unmerged -> agreement" \
  "agreement" "$(jq -r '.entries[] | select(.pr_url | endswith("/4")) | .comparison' <<<"$repo")"
assert_eq "pull/5: still open, no standing request -> pending" \
  "pending" "$(jq -r '.entries[] | select(.pr_url | endswith("/5")) | .comparison' <<<"$repo")"
assert_eq "pull/6: still open, approved, no standing request -> pending" \
  "pending" "$(jq -r '.entries[] | select(.pr_url | endswith("/6")) | .comparison' <<<"$repo")"

# Sample excludes the two `pending` (pull/5, pull/6): agreement (2, 4) +
# divergence (1, 3) = 4, short of the default min-sample of 5.
assert_eq "summary: agreement 2, divergence 2, pending 2, sample 4" \
  '{"agreement":2,"divergence":2,"pending":2,"sample":4}' \
  "$(jq -c '.summary | {agreement, divergence, pending, sample}' <<<"$repo")"
assert_eq "summary status: below the default min-sample of 5 -> insufficient-sample" \
  "insufficient-sample" "$(jq -r '.summary.status' <<<"$repo")"

# --- --min-sample and --since are both honoured -----------------------------

out2="$("$REPORT" --config "$tmp_dir/config.json" --repo o/repo --min-sample 4 \
  --state-dir "$tmp_dir/state" --peers-dir "$tmp_dir/peers" 2>/dev/null)"
raw2="$(awk '/```json/{flag=1;next}/```/{flag=0}flag' <<<"$out2")"
assert_eq "--min-sample 4 clears the bar at exactly 4, and reports the real divergence" \
  "divergence" "$(jq -r '.repos[0].summary.status' <<<"$raw2")"

out3="$("$REPORT" --config "$tmp_dir/config.json" --repo o/repo --since "2026-08-04T00:00:00Z" \
  --state-dir "$tmp_dir/state" --peers-dir "$tmp_dir/peers" 2>/dev/null)"
raw3="$(awk '/```json/{flag=1;next}/```/{flag=0}flag' <<<"$out3")"
assert_eq "--since restricts to verdicts on or after the given timestamp" \
  "3" "$(jq '.repos[0].entries | length' <<<"$raw3")"

echo "---"
if [[ "$failures" -eq 0 ]]; then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
