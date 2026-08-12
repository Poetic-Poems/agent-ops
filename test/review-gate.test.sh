#!/usr/bin/env bash
#
# test/review-gate.test.sh — regression test for lib/review-gate.sh
# (requirement 31c, agent-ops#249).
#
# poetic-fiddle #216 reached `reviewDecision: APPROVED` with a CodeQL
# high-severity alert open, hidden inside an otherwise 15/16-green check
# list. The assertions below are the two facts that must hold before a pull
# request is handed to a human as ready, checked against a stubbed `gh`
# rather than trusted from a model's report:
#
#   - every required check green, with an empty or unreadable required-check
#     list treated as a failure rather than a vacuous pass (poetic-fiddle
#     #190: a CONFLICTING pull request reports none at all);
#   - no code-scanning alert with a security severity introduced by the pull
#     request — one already open on the base branch is inherited debt, not
#     this pull request's fault, and must not block it;
#   - an alerts API that cannot be asked at all reads as `unknown`, never as
#     `clean` — a fact about the node or the repository, not the pull
#     request, that a caller must still be told about;
#   - an empty alert list is only believed once an analysis is confirmed to
#     exist for the merge ref (agent-ops#270) — the alerts endpoint answers a
#     never-analysed ref with `[]` and a 200, the same shape as a genuinely
#     clean pull request.
#
# `gh` is stubbed through REVIEW_GATE_GH, the same convention
# test/handoff.test.sh's stub uses.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/review-gate.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/review-gate.sh
. "$SCRIPT_DIR/lib/review-gate.sh"

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
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

URL="https://github.com/Poetic-Poems/poetic-fiddle/pull/216"

# --- The stub gh --------------------------------------------------------------
# State lives in files:
#   $tmp_dir/required.json   the `pr checks --required --json name,bucket`
#                             payload; "ERROR" makes the call fail as #190's
#                             does (empty stdout, non-zero exit).
#   $tmp_dir/pr-alerts.tsv   lines for the `ref=refs/pull/<n>/merge` alerts
#                             call; "ERROR" makes the call fail.
#   $tmp_dir/base-alerts.tsv the same, for `ref=refs/heads/<default-branch>`.
#   $tmp_dir/analyses.count  what the code-scanning *analyses* listing answers
#                             (the lib asks it with `--jq length`, so this is
#                             the bare count); "ERROR" makes the call fail.
#                             This is the existence check that tells an empty
#                             alert list apart from a ref that was never
#                             analysed (agent-ops#270).
#   $tmp_dir/refs-asked      every ref the stub was asked for, one per line, so
#                             an assertion can pin *which* ref the alerts read
#                             uses rather than only what it does with the
#                             answer. A pull request's alerts exist only under
#                             `refs/pull/<n>/merge`; asking `.../head` returns
#                             an empty list and a 200, which reads as "clean"
#                             and would silently disarm the whole gate, so the
#                             stub answers only the merge ref and any other
#                             pull-request ref fails the call outright.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"

if [[ "$1 $2" == "pr checks" ]]; then
  content="$(cat "$d/required.json" 2>/dev/null || echo '[]')"
  [[ "$content" == "ERROR" ]] && { echo "no required checks reported on the branch" >&2; exit 1; }
  printf '%s' "$content"
  exit 0
fi

if [[ "$1" == "api" ]]; then
  ref=""
  path=""
  for arg in "$@"; do
    [[ "$arg" == ref=* ]] && ref="${arg#ref=}"
    [[ "$arg" == repos/* ]] && path="$arg"
  done
  printf '%s\n' "$ref" >>"$d/refs-asked"
  printf '%s\n' "$path" >>"$d/paths-asked"
  if [[ "$path" == */code-scanning/analyses ]]; then
    content="$(cat "$d/analyses.count" 2>/dev/null || printf '')"
    [[ "$content" == "ERROR" ]] && exit 1
    printf '%s' "$content"
    exit 0
  fi
  case "$ref" in
    refs/pull/*/merge) file="$d/pr-alerts.tsv" ;;
    refs/heads/*)      file="$d/base-alerts.tsv" ;;
    *) exit 1 ;;
  esac
  content="$(cat "$file" 2>/dev/null || printf '')"
  [[ "$content" == "ERROR" ]] && exit 1
  printf '%s' "$content"
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/gh"
export REVIEW_GATE_GH="$tmp_dir/gh"

set_required() { printf '%s' "$1" >"$tmp_dir/required.json"; }
set_pr_alerts() { printf '%s' "$1" >"$tmp_dir/pr-alerts.tsv"; }
set_base_alerts() { printf '%s' "$1" >"$tmp_dir/base-alerts.tsv"; }
set_analyses() { printf '%s' "$1" >"$tmp_dir/analyses.count"; }

set_required '[{"name":"CI","bucket":"pass"},{"name":"commit-format","bucket":"pass"}]'
set_pr_alerts ''
set_base_alerts ''
set_analyses '1'

# --- review_gate_required_checks ----------------------------------------------

out="$(review_gate_required_checks "$URL")"; rc=$?
assert_eq "all required checks passing is clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

set_required '[{"name":"CI","bucket":"fail"},{"name":"commit-format","bucket":"pass"}]'
out="$(review_gate_required_checks "$URL")"; rc=$?
assert_eq "a failing required check is dirty" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the failing check" "CI" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

set_required '[]'
out="$(review_gate_required_checks "$URL")"; rc=$?
assert_eq "an empty required-check list is dirty, not vacuously clean" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the conflicting-PR-runs-no-CI trap" "no required checks at all" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

set_required 'ERROR'
out="$(review_gate_required_checks "$URL")"; rc=$?
assert_eq "an unreadable required-check list is dirty, never assumed clean" "dirty" "${out%%$'\t'*}"
assert_eq "  ... and exits 1" "1" "$rc"

out="$(review_gate_required_checks "")"; rc=$?
assert_eq "no PR url at all is dirty" "dirty" "${out%%$'\t'*}"
assert_eq "  ... and exits 1" "1" "$rc"

set_required '[{"name":"CI","bucket":"pass"}]'

# --- review_gate_security_alerts ----------------------------------------------

set_pr_alerts ''
set_analyses '1'
out="$(review_gate_security_alerts "$URL" "main")"; rc=$?
assert_eq "no open alerts, with an analysis to vouch for it, is clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# The empty list alone is not evidence (agent-ops#270): the alerts endpoint
# answers a never-analysed ref with `[]` and a 200 — CodeQL skipped by path
# filters, a first-push race, or a repository scanning on push only, whose
# alerts live under `refs/heads/<branch>` where this gate's merge-ref query
# can never see them. Without the analysis-existence check every one of those
# certifies `clean`; with it they surface as `unknown`, which a handoff
# reports rather than trusts.
set_pr_alerts ''
set_analyses '0'
out="$(review_gate_security_alerts "$URL" "main")"; rc=$?
assert_eq "no alerts with no analysis at all is unknown, never clean" "unknown" "${out%%$'\t'*}"
assert_contains "  ... saying no analysis exists for the merge ref" \
  "no code-scanning analysis exists for refs/pull/216/merge" "$out"
assert_eq "  ... and exits 0 (does not itself block)" "0" "$rc"

set_pr_alerts ''
set_analyses 'ERROR'
out="$(review_gate_security_alerts "$URL" "main")"; rc=$?
assert_eq "no alerts with an unaskable analyses API is unknown too" "unknown" "${out%%$'\t'*}"
assert_contains "  ... saying the existence check itself failed" \
  "could not confirm a code-scanning analysis exists" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# A non-empty alert list is its own proof an analysis ran: the existence
# check must not spend a second API call on it.
rm -f "$tmp_dir/paths-asked"
set_pr_alerts "$(printf '42\thigh')"
set_base_alerts ''
set_analyses 'ERROR'
review_gate_security_alerts "$URL" "main" >/dev/null
assert_eq "alerts in hand skip the analysis-existence check" \
  "" "$(grep -c 'code-scanning/analyses' "$tmp_dir/paths-asked" | grep -v '^0$')"
set_analyses '1'

# The ref itself, pinned. GitHub files a pull request's code-scanning alerts
# only under `refs/pull/<n>/merge` — the ref its `pull_request`-triggered
# analysis runs against. `refs/pull/<n>/head` carries no analysis, so the
# alerts API answers it with an empty list and a 200, which every branch below
# reads as "clean". That disarms the security half of this gate completely
# while leaving every other assertion in this file passing, so the ref gets an
# assertion of its own rather than being left implicit in the stub.
rm -f "$tmp_dir/refs-asked"
set_pr_alerts "$(printf '42\thigh')"
set_base_alerts ''
out="$(review_gate_security_alerts "$URL" "main")"
assert_contains "the pull request's alerts are read on its merge ref" \
  "refs/pull/216/merge" "$(cat "$tmp_dir/refs-asked")"
assert_eq "  ... and not on its head ref, which carries no analysis" \
  "" "$(grep -c 'refs/pull/216/head' "$tmp_dir/refs-asked" | grep -v '^0$')"
assert_contains "  ... and the base branch on its heads ref" \
  "refs/heads/main" "$(cat "$tmp_dir/refs-asked")"

set_pr_alerts "$(printf '42\thigh')"
set_base_alerts ''
out="$(review_gate_security_alerts "$URL" "main")"; rc=$?
assert_eq "a new security-severity alert is dirty" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the alert" "#42 (high)" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

set_pr_alerts "$(printf '42\thigh')"
set_base_alerts "$(printf '42\thigh')"
out="$(review_gate_security_alerts "$URL" "main")"; rc=$?
assert_eq "an alert already open on the base branch is inherited, not dirty" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

set_pr_alerts "$(printf '7\t')"
set_base_alerts ''
out="$(review_gate_security_alerts "$URL" "main")"; rc=$?
assert_eq "an open alert with no security severity does not gate" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

set_pr_alerts 'ERROR'
out="$(review_gate_security_alerts "$URL" "main")"; rc=$?
assert_eq "an unreadable alerts API is unknown, never clean" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0 (does not itself block)" "0" "$rc"

set_pr_alerts "$(printf '42\thigh')"
set_base_alerts 'ERROR'
out="$(review_gate_security_alerts "$URL" "main")"; rc=$?
assert_eq "an unreadable base-branch read is unknown too, not a false dirty" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0" "0" "$rc"

# --- review_gate_verdict: the combined entry point ----------------------------

set_required '[{"name":"CI","bucket":"pass"}]'
set_pr_alerts ''
set_base_alerts ''
out="$(review_gate_verdict "$URL" "main")"; rc=$?
assert_eq "clean checks and no alerts is clean overall" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

set_required '[{"name":"CI","bucket":"fail"}]'
out="$(review_gate_verdict "$URL" "main")"; rc=$?
assert_eq "a dirty required check blocks regardless of alerts" "dirty" "${out%%$'\t'*}"
assert_eq "  ... and exits 1" "1" "$rc"

set_required '[{"name":"CI","bucket":"pass"}]'
set_pr_alerts "$(printf '42\tcritical')"
set_base_alerts ''
out="$(review_gate_verdict "$URL" "main")"; rc=$?
assert_eq "clean checks with a new security alert is dirty overall" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the alert" "#42 (critical)" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

set_pr_alerts 'ERROR'
out="$(review_gate_verdict "$URL" "main")"; rc=$?
assert_eq "clean checks with an unreadable alerts API is unknown overall" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0" "0" "$rc"

# --- Survives the caller's shell options ---------------------------------------
# agent-cycle.sh runs under `set -euo pipefail`, and reads this the same way it
# reads confirm_pr_ready: `x="$(review_gate_verdict …)" || true`.
set_required '[{"name":"CI","bucket":"fail"}]'
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/review-gate.sh"
  # shellcheck disable=SC2030
  REVIEW_GATE_GH="$tmp_dir/gh"
  x="$(review_gate_verdict "$URL" "main")" || true
  [[ "${x%%$'\t'*}" == "dirty" ]] || exit 9
  exit 0
) >/dev/null 2>&1
assert_eq "the real call-site shape survives set -e" "0" "$?"

echo
if (( failures == 0 )); then
  echo "review-gate.test.sh: all assertions passed"
  exit 0
else
  echo "review-gate.test.sh: $failures assertion(s) failed"
  exit 1
fi
