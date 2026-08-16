#!/usr/bin/env bash
#
# test/merge-budget.test.sh — regression test for lib/merge-budget.sh (D18
# WI-6, docs/reviews/2026-08-14-autonomy-investigation.md §5.4): the
# `merge_budget_per_day` spend governor.
#
# Covers, against a stubbed `gh`:
#   - merge_budget_effective_cap's precedence (repo override, top-level,
#     default 8 — the same shape merge_autonomy_configured_level uses).
#   - merge_budget_window_status's counting: labelled/App-merged pull
#     requests inside the rolling 24h window count, a merge 25h old is
#     excluded, a human's own merge is excluded, an unlabelled pull request
#     is excluded, and a listing that comes back at the page cap reads
#     truncated rather than trusted as a floor.
#   - merge_budget_decide's four outcomes: cap 0 arms with no count
#     attempted at all; an unreadable or truncated window refuses; under cap
#     arms; at or over cap holds, with the oldest waiting pull request
#     attached; over cap also flags the anomaly.
#   - merge_budget_apply_decision's write side: a hold logs merge-budget-hold
#     with the backlog; a refuse logs a warning; an anomaly freezes the repo
#     and files (and dedups) an escalation issue against the repo itself,
#     never a fleet-wide escalation repo.
#   - The freeze functions' own state machine (state/set/clear) — the
#     integration with merge_autonomy_effective_level is
#     test/merge-autonomy.test.sh's own coverage, not repeated here.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/merge-budget.test.sh
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

# --- merge_budget_effective_cap ---

assert_eq "no key anywhere defaults to 8" "8" \
  "$(merge_budget_effective_cap '{}' "acme/widgets")"
assert_eq "the top-level key governs a repo with no override" "3" \
  "$(merge_budget_effective_cap '{"merge_budget_per_day": 3}' "acme/widgets")"
budget_override_cfg='{"merge_budget_per_day": 3, "repos": [
  {"slug": "acme/widgets", "merge_budget_per_day": 0},
  {"slug": "acme/gizmos"}
]}'
assert_eq "a repo's own override wins, including 0 for unlimited" "0" \
  "$(merge_budget_effective_cap "$budget_override_cfg" "acme/widgets")"
assert_eq "a repo with no override of its own falls through to the top-level key" "3" \
  "$(merge_budget_effective_cap "$budget_override_cfg" "acme/gizmos")"
assert_eq "a repo absent from repos[] entirely still falls through to the top-level key" "3" \
  "$(merge_budget_effective_cap "$budget_override_cfg" "acme/unlisted")"

# --- Stub gh: pr list (merged/open), issue list/create, and the contents
#     API fleet_flag_* needs for the freeze. One dispatcher, the same
#     technique test/merge-autonomy.test.sh's own contents-API stub uses,
#     extended with the pr-list/issue argv shapes lib/merge-budget.sh needs. ---

stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
fixtures="$tmp_dir/fixtures"
mkdir -p "$fixtures/merged" "$fixtures/open" "$fixtures/issues"
gh_backing="$tmp_dir/fleet-remote"
mkdir -p "$gh_backing"
issue_calls="$tmp_dir/issue-create-calls"
: > "$issue_calls"
pr_list_calls="$tmp_dir/pr-list-calls"
: > "$pr_list_calls"

cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args=("$@")

# --- gh api ... (lib/toggle.sh's fleet_flag_* contents API) ---
if [[ "${args[0]:-}" == "api" ]]; then
  method=GET path="" jq_expr=""
  declare -A f=()
  i=1
  while (( i < ${#args[@]} )); do
    a="${args[$i]}"
    case "$a" in
      -X)      i=$((i+1)); method="${args[$i]}" ;;
      --jq)    i=$((i+1)); jq_expr="${args[$i]}" ;;
      -f)      i=$((i+1)); kv="${args[$i]}"; f["${kv%%=*}"]="${kv#*=}" ;;
      repos/*) path="$a" ;;
    esac
    i=$((i+1))
  done
  if [[ "$path" == repos/*/* && "$path" != */contents/* ]]; then
    echo '{}'; exit 0
  fi
  rel="${path#repos/*/*/contents/}"; rel="${rel%%\?*}"
  file="$GH_BACKING/$rel"
  sha_of() { sha1sum "$1" | awk '{print $1}'; }
  case "$method" in
    GET)
      [[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      if [[ "$jq_expr" == ".sha" ]]; then sha_of "$file"; exit 0; fi
      jq -n --arg c "$(base64 -w0 < "$file")" --arg s "$(sha_of "$file")" '{content: $c, sha: $s}'
      ;;
    PUT)
      if [[ -f "$file" ]]; then
        [[ "${f[sha]:-}" == "$(sha_of "$file")" ]] || { echo "gh: sha mismatch (HTTP 409)" >&2; exit 1; }
      elif [[ -n "${f[sha]:-}" ]]; then
        echo "gh: sha given for a missing file (HTTP 422)" >&2; exit 1
      fi
      mkdir -p "$(dirname "$file")"
      printf '%s' "${f[content]:?}" | base64 -d > "$file"
      ;;
    DELETE)
      [[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      [[ "${f[sha]:-}" == "$(sha_of "$file")" ]] || { echo "gh: sha mismatch (HTTP 409)" >&2; exit 1; }
      rm -f "$file"
      ;;
  esac
  exit 0
fi

# --- gh pr list -R <slug> --state merged|open ... ---
# The `--search` qualifier is recorded rather than honoured: the fixture is
# already the answer, and what the assertions below need to see is that the
# merged listing was scoped to the window at all (without it the listing
# enumerates the label's whole lifetime history and truncates permanently —
# see lib/merge-budget.sh's own note on merge_budget_window_status).
#
# acme/paginated is the one exception: its fixture is larger than
# GITHUB_PR_LIST_LIMIT, and the stub actually pages it — `.[0:limit]`, sorted
# by createdAt first when `--search` asks for `sort:created-asc` — so the
# merge_budget_oldest_waiting assertions below can tell "named the true
# oldest" from "named the oldest of whatever page came back" (PR #499 review
# follow-up). Every other slug keeps the old "the fixture already is the
# answer, --limit is a no-op" behaviour untouched.
if [[ "${args[0]:-}" == "pr" && "${args[1]:-}" == "list" ]]; then
  slug="" state="" search="" limit=""
  i=2
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      -R)       i=$((i+1)); slug="${args[$i]}" ;;
      --state)  i=$((i+1)); state="${args[$i]}" ;;
      --search) i=$((i+1)); search="${args[$i]}" ;;
      --limit)  i=$((i+1)); limit="${args[$i]}" ;;
    esac
    i=$((i+1))
  done
  printf '%s\t%s\t%s\n' "$state" "$slug" "$search" >> "$PR_LIST_CALLS"
  f="$GH_FIXTURES/$state/${slug//\//__}.json"
  [[ -f "$f" ]] || exit 1
  if [[ "$state" == "open" && "$slug" == "acme/paginated" ]]; then
    if [[ "$search" == *"sort:created-asc"* ]]; then
      jq -c --argjson n "${limit:-60}" 'sort_by(.createdAt) | .[0:$n]' "$f"
    else
      jq -c --argjson n "${limit:-60}" '.[0:$n]' "$f"
    fi
  else
    cat "$f"
  fi
  exit 0
fi

# --- gh issue list -R <slug> ... ---
if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "list" ]]; then
  slug=""
  i=2
  while (( i < ${#args[@]} )); do
    [[ "${args[$i]}" == "-R" ]] && { i=$((i+1)); slug="${args[$i]}"; }
    i=$((i+1))
  done
  f="$GH_FIXTURES/issues/${slug//\//__}.json"
  if [[ -f "$f" ]]; then cat "$f"; else echo '[]'; fi
  exit 0
fi

# --- gh issue create -R <slug> --title <t> --body-file <f> --assignee <a> --label <l> ---
# Also records the created issue into GH_FIXTURES/issues/<slug>.json, body
# included, so a subsequent `gh issue list` (the dedup check) actually finds
# it — the same "the fake backend remembers what it was told" idea the
# contents-API branch above already applies to fleet flags.
if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "create" ]]; then
  slug="" title="" body_file=""
  i=2
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      -R)         i=$((i+1)); slug="${args[$i]}" ;;
      --title)    i=$((i+1)); title="${args[$i]}" ;;
      --body-file) i=$((i+1)); body_file="${args[$i]}" ;;
    esac
    i=$((i+1))
  done
  printf '%s\t%s\n' "$slug" "$title" >> "$ISSUE_CALLS"
  n=$(( $(wc -l < "$ISSUE_CALLS") + 100 ))
  issues_file="$GH_FIXTURES/issues/${slug//\//__}.json"
  [[ -f "$issues_file" ]] || echo '[]' > "$issues_file"
  jq -c --argjson n "$n" --arg u "https://github.com/$slug/issues/$n" \
    --rawfile body "$body_file" \
    '. + [{number: $n, url: $u, body: $body}]' "$issues_file" > "$issues_file.tmp" \
    && mv "$issues_file.tmp" "$issues_file"
  printf 'https://github.com/%s/issues/%s\n' "$slug" "$n"
  exit 0
fi

echo "gh-stub: unhandled invocation: ${args[*]}" >&2
exit 1
STUB
chmod +x "$stub_bin/gh"

export GH_BACKING="$gh_backing" GH_FIXTURES="$fixtures" ISSUE_CALLS="$issue_calls" \
       PR_LIST_CALLS="$pr_list_calls" PATH="$stub_bin:$PATH"

now="2026-08-16T12:00:00Z"
label="autonomous-agent"

pr() {
  # pr NUMBER MERGED_AT LOGIN LABEL_OR_EMPTY
  jq -nc --argjson n "$1" --arg m "$2" --arg login "$3" --arg lbl "${4-$label}" \
    '{number: $n, mergedAt: $m, mergedBy: {login: $login},
      labels: (if $lbl == "" then [] else [{name: $lbl}] end)}'
}

# --- merge_budget_window_status ---

# Two App-merged, labelled PRs inside the window; one 25h old (excluded);
# one merged by a human (excluded); one unlabelled (excluded).
jq -sc '.' <(pr 1 "2026-08-16T10:00:00Z" "pullwright-approver[bot]") \
           <(pr 2 "2026-08-16T02:00:00Z" "pullwright-approver[bot]") \
           <(pr 3 "2026-08-15T10:00:00Z" "pullwright-approver[bot]") \
           <(pr 4 "2026-08-16T09:00:00Z" "a-human") \
           <(pr 5 "2026-08-16T09:00:00Z" "pullwright-approver[bot]" "") \
  > "$fixtures/merged/acme__widgets.json"

: > "$pr_list_calls"
status="$(merge_budget_window_status "acme/widgets" "$label" "pullwright-approver[bot]" "$now")"
assert_eq "two in-window, labelled, App-merged PRs count; the 25h-old, human-merged and unlabelled ones do not" \
  "ok	2" "$status"

# The merged listing must be scoped to the window by GitHub's own qualifier,
# not merely filtered to it afterwards. Unscoped, `gh pr list --state merged`
# enumerates the label's whole lifetime history, which passes
# GITHUB_PR_LIST_LIMIT on every repository this fleet governs and never comes
# back under it — so the listing would read `truncated` on every call forever
# and `arm`/`hold`/the anomaly freeze would all be unreachable in production
# while every fixture here, being small, still passed.
assert_eq "the merged listing is scoped to the window by merged:>=<cutoff>, not filtered afterwards" \
  "merged	acme/widgets	merged:>=2026-08-15T12:00:00Z" \
  "$(head -1 "$pr_list_calls")"

# An unreadable listing (no fixture file at all).
status="$(merge_budget_window_status "acme/unreadable" "$label" "pullwright-approver[bot]" "$now")"
assert_eq "an unreadable listing reports unreadable" "unreadable	" "$status"

# A listing at the page cap.
: > "$fixtures/merged/acme__truncated.json"
jq -nc --argjson n "$GITHUB_PR_LIST_LIMIT" \
  '[range($n) | {number: ., mergedAt: "2026-08-16T09:00:00Z", mergedBy: {login: "pullwright-approver[bot]"}, labels: [{name: "autonomous-agent"}]}]' \
  > "$fixtures/merged/acme__truncated.json"
status="$(merge_budget_window_status "acme/truncated" "$label" "pullwright-approver[bot]" "$now")"
assert_eq "a listing that comes back at the page cap reads truncated, not trusted as a floor" \
  "truncated	" "$status"

# --- merge_budget_oldest_waiting ---

jq -nc '[
  {number: 20, url: "https://github.com/acme/widgets/pull/20", createdAt: "2026-08-15T00:00:00Z", isDraft: false},
  {number: 21, url: "https://github.com/acme/widgets/pull/21", createdAt: "2026-08-14T00:00:00Z", isDraft: false},
  {number: 22, url: "https://github.com/acme/widgets/pull/22", createdAt: "2026-08-10T00:00:00Z", isDraft: true}
]' > "$fixtures/open/acme__widgets.json"
assert_eq "the oldest waiting PR is the earliest-created non-draft, not the draft" \
  '{"number":21,"url":"https://github.com/acme/widgets/pull/21","created_at":"2026-08-14T00:00:00Z"}' \
  "$(merge_budget_oldest_waiting "acme/widgets" "$label")"

: > "$fixtures/open/acme__none.json"
echo '[]' > "$fixtures/open/acme__none.json"
assert_eq "no open PRs at all: waiting is null" "null" \
  "$(merge_budget_oldest_waiting "acme/none" "$label")"

# 61 open pull requests — one past GITHUB_PR_LIST_LIMIT (60) — file-ordered
# newest first, so the true oldest (#160, 60 days back) sits past the page
# cap and only survives a listing actually sorted oldest-first before it is
# paged (PR #499 review follow-up).
{
  i=0
  while (( i <= 60 )); do
    d="$(date -u -d "2026-08-16 - $i days" +%Y-%m-%dT%H:%M:%SZ)"
    n=$(( 100 + i ))
    jq -nc --argjson n "$n" --arg d "$d" --arg u "https://github.com/acme/paginated/pull/$n" \
      '{number: $n, url: $u, createdAt: $d, isDraft: false}'
    i=$(( i + 1 ))
  done
} | jq -sc '.' > "$fixtures/open/acme__paginated.json"

: > "$pr_list_calls"
assert_eq "the true oldest survives past GITHUB_PR_LIST_LIMIT, not just the oldest of the newest page" \
  '{"number":160,"url":"https://github.com/acme/paginated/pull/160","created_at":"2026-06-17T00:00:00Z"}' \
  "$(merge_budget_oldest_waiting "acme/paginated" "$label")"
assert_eq "…because the listing actually asked GitHub to sort oldest-first" \
  "open	acme/paginated	sort:created-asc" \
  "$(cat "$pr_list_calls")"

# --- merge_budget_decide ---

decide_cfg='{"merge_budget_per_day": 2}'
zero_cfg='{"merge_budget_per_day": 0}'

decision="$(merge_budget_decide "$zero_cfg" "acme/never-called" "$label" "pullwright-approver[bot]" "$now")"
assert_eq "cap 0 arms with no count attempted at all — no gh call, so an unfixtured repo does not fail" \
  '{"decision":"arm","cap":0,"count":null,"anomaly":false,"waiting_backlog":null}' "$decision"

decision="$(merge_budget_decide "$decide_cfg" "acme/unreadable" "$label" "pullwright-approver[bot]" "$now")"
assert_eq "an unreadable window refuses rather than clearing landing" \
  '{"decision":"refuse","cap":2,"count":null,"anomaly":false,"waiting_backlog":null}' "$decision"

decision="$(merge_budget_decide "$decide_cfg" "acme/truncated" "$label" "pullwright-approver[bot]" "$now")"
assert_eq "a truncated window refuses too — an undercount is the dangerous direction" \
  '{"decision":"refuse","cap":2,"count":null,"anomaly":false,"waiting_backlog":null}' "$decision"

# acme/widgets has 2 counted merges (above) — at cap 2, this is a hold.
decision="$(merge_budget_decide "$decide_cfg" "acme/widgets" "$label" "pullwright-approver[bot]" "$now")"
assert_eq "count == cap holds, and does not arm" \
  '{"decision":"hold","cap":2,"count":2,"anomaly":false,"waiting_backlog":{"number":21,"url":"https://github.com/acme/widgets/pull/21","created_at":"2026-08-14T00:00:00Z"}}' \
  "$decision"

under_cfg='{"merge_budget_per_day": 5}'
decision="$(merge_budget_decide "$under_cfg" "acme/widgets" "$label" "pullwright-approver[bot]" "$now")"
assert_eq "count under cap arms" \
  '{"decision":"arm","cap":5,"count":2,"anomaly":false,"waiting_backlog":null}' "$decision"

over_cfg='{"merge_budget_per_day": 1}'
decision="$(merge_budget_decide "$over_cfg" "acme/widgets" "$label" "pullwright-approver[bot]" "$now")"
assert_eq "count over cap holds and flags the anomaly" \
  '{"decision":"hold","cap":1,"count":2,"anomaly":true,"waiting_backlog":{"number":21,"url":"https://github.com/acme/widgets/pull/21","created_at":"2026-08-14T00:00:00Z"}}' \
  "$decision"

# --- merge_budget_freeze_state / _set / _clear ---

fs="$tmp_dir/fleet-state"
mkdir -p "$fs"
assert_eq "the freeze starts clear" "enabled" \
  "$(merge_budget_freeze_state "acme/state-repo" "$fs" "acme/widgets" | jq -r '.state')"
set_outcome="$(merge_budget_freeze_set "acme/state-repo" "acme/widgets" 1 2)"
assert_eq "setting the freeze reports ok" "ok" "$set_outcome"
assert_eq "the freeze now reads disabled (frozen)" "disabled" \
  "$(merge_budget_freeze_state "acme/state-repo" "$fs" "acme/widgets" | jq -r '.state')"
assert_eq "and carries kind anomaly, never manual" "anomaly" \
  "$(merge_budget_freeze_state "acme/state-repo" "$fs" "acme/widgets" | jq -r '.record.kind')"
assert_eq "a different repo's freeze is untouched — the flag is per-repo" "enabled" \
  "$(merge_budget_freeze_state "acme/state-repo" "$fs" "acme/gizmos" | jq -r '.state')"
assert_eq "with no state repo, the freeze reads enabled — a single-node install has no fleet flags" \
  "enabled" \
  "$(merge_budget_freeze_state "" "$tmp_dir/no-fleet" "acme/widgets" | jq -r '.state')"
clear_outcome="$(merge_budget_freeze_clear "acme/state-repo" "$fs" "acme/widgets")"
assert_eq "clearing the freeze reports ok" "ok" "$clear_outcome"
assert_eq "the freeze reads clear again" "enabled" \
  "$(merge_budget_freeze_state "acme/state-repo" "$fs" "acme/widgets" | jq -r '.state')"

# --- merge_budget_apply_decision ---

log_calls="$tmp_dir/log-calls"
: > "$log_calls"
# shellcheck disable=SC2317  # invoked indirectly by merge_budget_apply_decision, which assumes its caller (agent-cycle.sh) has already defined it
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$log_calls"; }

refuse_json='{"decision":"refuse","cap":2,"count":null,"anomaly":false,"waiting_backlog":null}'
merge_budget_apply_decision "$refuse_json" "acme/widgets" "acme/state-repo" "escalation" "octocat"
assert_eq "a refuse logs exactly one warning event and nothing else" "1" \
  "$(wc -l < "$log_calls" | tr -d ' ')"
assert_eq "…naming it a warning" "warning" "$(cut -f1 "$log_calls")"
: > "$log_calls"

hold_json='{"decision":"hold","cap":2,"count":2,"anomaly":false,"waiting_backlog":{"number":21,"url":"https://github.com/acme/widgets/pull/21","created_at":"2026-08-14T00:00:00Z"}}'
merge_budget_apply_decision "$hold_json" "acme/widgets" "acme/state-repo" "escalation" "octocat"
assert_eq "a plain hold (no anomaly) logs merge-budget-hold and nothing more — no freeze, no escalation" \
  "1" "$(wc -l < "$log_calls" | tr -d ' ')"
assert_eq "…carrying the backlog" "true" \
  "$(cut -f2- "$log_calls" | jq 'has("waiting_backlog") and (.waiting_backlog.number == 21)')"
assert_eq "and the repo is not frozen" "enabled" \
  "$(merge_budget_freeze_state "acme/state-repo" "$fs" "acme/widgets" | jq -r '.state')"
: > "$log_calls"

anomaly_json='{"decision":"hold","cap":1,"count":3,"anomaly":true,"waiting_backlog":null}'
merge_budget_apply_decision "$anomaly_json" "acme/widgets" "acme/state-repo" "escalation" "octocat"
assert_eq "an anomaly logs hold, frozen and escalated — three events" \
  "3" "$(wc -l < "$log_calls" | tr -d ' ')"
assert_eq "in that order" "merge-budget-hold	merge-budget-frozen	merge-budget-freeze-escalated" \
  "$(cut -f1 "$log_calls" | paste -sd$'\t')"
assert_eq "and the repo is now genuinely frozen" "disabled" \
  "$(merge_budget_freeze_state "acme/state-repo" "$fs" "acme/widgets" | jq -r '.state')"
assert_eq "the escalation issue is filed against the repo itself, never a fleet-wide escalation repo" \
  "acme/widgets" "$(cut -f1 "$issue_calls" | tail -1)"

before="$(wc -l < "$issue_calls" | tr -d ' ')"
merge_budget_apply_decision "$anomaly_json" "acme/widgets" "acme/state-repo" "escalation" "octocat"
after="$(wc -l < "$issue_calls" | tr -d ' ')"
assert_eq "a second anomaly on an already-frozen repo does not re-freeze or re-file — dedup holds" \
  "$before" "$after"
merge_budget_freeze_clear "acme/state-repo" "$fs" "acme/widgets" >/dev/null

echo
if (( failures == 0 )); then
  echo "All merge-budget assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
