#!/usr/bin/env bash
#
# test/sweep-decision-vetoes.test.sh — the decision-veto sweep
# (scripts/sweep-decision-vetoes.sh, agent-ops#937) finds a reopened
# `pw::decision` log issue and acts on it: re-blocks a non-terminal item
# (needs-refinement action, a comment on its thread, its open pull request
# flipped to draft) or files a revisit issue for a terminal one.
#
# `gh` is a stub on PATH via SWEEP_GH; no network.
#
# Run directly: ./test/sweep-decision-vetoes.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$SCRIPT_DIR/scripts/sweep-decision-vetoes.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

stub="$tmp_dir/gh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
S="$SWEEP_STUB_DIR"
printf '%s\n' "$*" >> "$S/calls.log"
args="$*"
case "$args" in
  "issue list -R acme/widgets --label pw::decision --state open --json number,url,title,body")
    cat "$S/decision-issues.json" ;;
  "api repos/acme/widgets/issues/"*"/events --paginate")
    n="${args#api repos/acme/widgets/issues/}"; n="${n%%/events*}"
    [[ -f "$S/events-$n.json" ]] && cat "$S/events-$n.json" || echo '[]' ;;
  "issue view "*" -R acme/widgets --json state --jq .state")
    n="${args#issue view }"; n="${n%% -R*}"
    [[ -f "$S/item-state-$n" ]] && cat "$S/item-state-$n" || echo "OPEN" ;;
  "issue view "*" -R acme/widgets --json comments --jq"*)
    n="${args#issue view }"; n="${n%% -R*}"
    [[ -f "$S/log-comments-$n.json" ]] && jq -r '.comments[-1].body // ""' "$S/log-comments-$n.json" ;;
  "pr list -R acme/widgets --state open --json number,url,body,headRefName")
    [[ -f "$S/open-prs.json" ]] && cat "$S/open-prs.json" || echo '[]' ;;
  "pr list -R acme/widgets --state merged --json number,url,body,headRefName --limit 30")
    [[ -f "$S/merged-prs.json" ]] && cat "$S/merged-prs.json" || echo '[]' ;;
  "issue comment "*" -R acme/widgets --body "*)
    [[ -f "$S/fail-issue-comment" ]] && exit 1
    echo "https://github.com/acme/widgets/issues/999#issuecomment-1" ;;
  "pr comment "*" --body "*)
    [[ -f "$S/fail-pr-comment" ]] && exit 1
    exit 0 ;;
  "pr ready "*" --undo")
    exit 0 ;;
  "pr view "*" --json isDraft --jq .isDraft")
    [[ -f "$S/pr-draft-flag" ]] && cat "$S/pr-draft-flag" || echo "true" ;;
  "issue create -R acme/widgets --title "*"--label bug")
    [[ -f "$S/fail-revisit-create" ]] && exit 1
    echo "https://github.com/acme/widgets/issues/700" ;;
  *)
    echo "stub gh: unexpected call: $args" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub"

run_sweep() {  # run_sweep STUB_DIR PROCESSED_JSON
  SWEEP_STUB_DIR="$1" SWEEP_GH="$stub" bash "$SWEEP" acme/widgets node-1 cycle-1 <<<"${2:-[]}"
}

marker() { printf '<!-- agent-ops:decision-log item=%s repo=acme/widgets -->' "$1"; }  # marker ITEM

# --- Case 1: non-terminal issue item, no open pull request ------------------
c="$tmp_dir/case1"; mkdir -p "$c"
jq -n --arg body "$(marker 42)" \
  '[{number: 501, url: "https://github.com/acme/widgets/issues/501",
     title: "widgets: decision", body: $body}]' > "$c/decision-issues.json"
jq -n '[{"actor": {"login": "warwickallen"}, "event": "reopened"}]' > "$c/events-501.json"
printf 'OPEN' > "$c/item-state-42"
echo '[]' > "$c/open-prs.json"

out="$(run_sweep "$c")"
calls="$(cat "$c/calls.log")"

vetoed="$(jq -c 'select(.action == "vetoed")' <<<"$out")"
assert_eq "vetoed action names the repo, item, log issue and reopener" \
  '{"action":"vetoed","repo":"acme/widgets","item":"42","issue_number":501,"issue_url":"https://github.com/acme/widgets/issues/501","by":"warwickallen","terminal":false}' \
  "$vetoed"
nr="$(jq -c 'select(.action == "needs-refinement")' <<<"$out")"
assert_eq "needs-refinement action names the item" "42" "$(jq -r '.item' <<<"$nr")"
assert_contains "needs-refinement evidence cites the log issue" "501" "$(jq -r '.evidence' <<<"$nr")"
assert_eq "a comment is posted on the item's own thread" "1" \
  "$(jq -c 'select(.action == "comment-posted")' <<<"$out" | wc -l | tr -d ' ')"
assert_contains "the comment call names the item" "issue comment 42 -R acme/widgets" "$calls"
assert_eq "no pull request is flipped (none is open)" "0" \
  "$(jq -c 'select(.action == "pr-flipped-to-draft")' <<<"$out" | wc -l | tr -d ' ')"
assert_eq "no revisit issue is filed for a non-terminal item" "0" \
  "$(jq -c 'select(.action == "revisit-filed")' <<<"$out" | wc -l | tr -d ' ')"

# --- Case 2: non-terminal issue item WITH an open pull request --------------
c="$tmp_dir/case2"; mkdir -p "$c"
jq -n --arg body "$(marker 43)" \
  '[{number: 502, url: "https://github.com/acme/widgets/issues/502",
     title: "widgets: decision", body: $body}]' > "$c/decision-issues.json"
jq -n '[{"actor": {"login": "warwickallen"}, "event": "reopened"}]' > "$c/events-502.json"
printf 'OPEN' > "$c/item-state-43"
jq -n '[{number: 7, url: "https://github.com/acme/widgets/pull/7",
         body: "<!-- agent-ops:closes-issue item=43 -->", headRefName: "agent/43"}]' > "$c/open-prs.json"
printf 'true' > "$c/pr-draft-flag"

out="$(run_sweep "$c")"
calls="$(cat "$c/calls.log")"

assert_contains "the pull request is commented on" "pr comment https://github.com/acme/widgets/pull/7" "$calls"
assert_contains "the pull request is flipped back to draft" "pr ready https://github.com/acme/widgets/pull/7 --undo" "$calls"
flip="$(jq -c 'select(.action == "pr-flipped-to-draft")' <<<"$out")"
assert_eq "the flip action names the pull request" "https://github.com/acme/widgets/pull/7" "$(jq -r '.pr_url' <<<"$flip")"

# --- Case 3: terminal item (issue already closed) — a revisit issue is filed,
# quoting the veto's own comment, and the log issue itself is told -----------
c="$tmp_dir/case3"; mkdir -p "$c"
jq -n --arg body "$(marker 44)" \
  '[{number: 503, url: "https://github.com/acme/widgets/issues/503",
     title: "widgets: use option B", body: $body}]' > "$c/decision-issues.json"
jq -n '[{"actor": {"login": "warwickallen"}, "event": "reopened"}]' > "$c/events-503.json"
printf 'CLOSED' > "$c/item-state-44"
echo '[]' > "$c/open-prs.json"
jq -n '{comments: [{body: "I disagree with this decision after all."}]}' > "$c/log-comments-503.json"

out="$(run_sweep "$c")"
calls="$(cat "$c/calls.log")"

vetoed="$(jq -c 'select(.action == "vetoed")' <<<"$out")"
assert_eq "the vetoed action reports the item as terminal" "true" "$(jq -r '.terminal' <<<"$vetoed")"
assert_eq "no needs-refinement action for a terminal item" "0" \
  "$(jq -c 'select(.action == "needs-refinement")' <<<"$out" | wc -l | tr -d ' ')"
assert_eq "no comment is posted on the (terminal) item's own thread" "0" \
  "$(jq -c 'select(.action == "comment-posted")' <<<"$out" | wc -l | tr -d ' ')"
revisit="$(jq -c 'select(.action == "revisit-filed")' <<<"$out")"
assert_eq "a revisit issue is filed" "https://github.com/acme/widgets/issues/700" "$(jq -r '.url' <<<"$revisit")"
assert_contains "the revisit issue names the decision title" "revisit: widgets: use option B" "$calls"
assert_contains "the revisit issue quotes the veto's own comment" "I disagree with this decision after all." "$calls"
assert_contains "the revisit issue is labelled bug" "--label bug" "$calls"
assert_contains "the log issue itself is told a revisit issue was filed" "issue comment 503 -R acme/widgets" "$calls"

# --- Case 4: dedup — a log issue already in the processed set is skipped ----
c="$tmp_dir/case4"; mkdir -p "$c"
jq -n --arg body "$(marker 45)" \
  '[{number: 504, url: "https://github.com/acme/widgets/issues/504",
     title: "widgets: decision", body: $body}]' > "$c/decision-issues.json"

out="$(run_sweep "$c" '[{"repo":"acme/widgets","item":"504"}]')"
calls="$(cat "$c/calls.log" 2>/dev/null || true)"
assert_eq "an already-processed veto is never re-reported" "" \
  "$(jq -c 'select(.action == "vetoed")' <<<"$out" 2>/dev/null || true)"
assert_not_contains "and its events are never even fetched" "issues/504/events" "$calls"

# --- Case 5: a `pw::decision` issue carrying no marker at all is left alone,
# reported rather than silently skipped ---------------------------------------
c="$tmp_dir/case5"; mkdir -p "$c"
jq -n '[{number: 505, url: "https://github.com/acme/widgets/issues/505",
         title: "widgets: decision", body: "no marker here"}]' > "$c/decision-issues.json"

out="$(run_sweep "$c")"
assert_eq "no vetoed action for an unmarked issue" "" \
  "$(jq -c 'select(.action == "vetoed")' <<<"$out" 2>/dev/null || true)"
assert_contains "a warning names the unmarked issue" "no agent-ops:decision-log marker" \
  "$(jq -r 'select(.action == "warning") | .detail' <<<"$out")"

# --- Case 6: the action cap defers the rest ---------------------------------
c="$tmp_dir/case6"; mkdir -p "$c"
jq -n --arg b1 "$(marker 61)" --arg b2 "$(marker 62)" --arg b3 "$(marker 63)" --arg b4 "$(marker 64)" '
  [{number: 601, url: "https://github.com/acme/widgets/issues/601", title: "d1", body: $b1},
   {number: 602, url: "https://github.com/acme/widgets/issues/602", title: "d2", body: $b2},
   {number: 603, url: "https://github.com/acme/widgets/issues/603", title: "d3", body: $b3},
   {number: 604, url: "https://github.com/acme/widgets/issues/604", title: "d4", body: $b4}]' \
  > "$c/decision-issues.json"
for n in 601 602 603 604; do echo '[]' > "$c/events-$n.json"; done
for n in 61 62 63 64; do printf 'OPEN' > "$c/item-state-$n"; done
echo '[]' > "$c/open-prs.json"

out="$(run_sweep "$c")"
assert_eq "vetoes exactly the per-run cap" "3" \
  "$(jq -c 'select(.action == "vetoed")' <<<"$out" | wc -l | tr -d ' ')"
assert_eq "and reports the rest as deferred" \
  '{"action":"deferred","remaining":1}' \
  "$(jq -c 'select(.action == "deferred")' <<<"$out")"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
