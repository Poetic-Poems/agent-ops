#!/usr/bin/env bash
#
# test/sweep-orphan-branches.test.sh — an orphaned claim branch is put back in
# front of the pipeline (requirement 17b, acceptance check 7b).
#
# What this guards: an Implementor that pushes commits and dies before its
# draft PR exists leaves a moved ref no machinery can see — the gc keeps it
# (pushed work is never deleted), the abandoned-drafts gatherer lists PRs, not
# branches, and every later claim 422s against it. The item is wedged forever
# and nothing says so. The sweep's whole value is in its guards, each of which
# fails in a different direction if lost:
#
#   open PR          the ordinary machinery owns it — touch nothing
#   registry entry   a live claim — touch nothing
#   registry error   an unanswered question (only a clean 404 proves absence,
#                    TD-PPagop-26080201's lesson) — touch nothing, say so
#   young tip        someone may still be working — wait
#   ahead > 0        the work becomes a draft PR the abandoned-drafts source
#                    recovers; the label it keys on must be on it
#   ahead == 0       the ref was only ever the claim, and the claim is dead
#   the cap          a backlog surfaces a few per cycle, and the overflow is
#                    reported, never silent
#
# `gh` is a stub on PATH via SWEEP_GH; no network.
#
# Run directly: ./test/sweep-orphan-branches.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$SCRIPT_DIR/scripts/sweep-orphan-branches.sh"

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

# --- The config the sweep reads --------------------------------------------------
config="$tmp_dir/config.json"
jq -n '{branch_prefix: "agent/", pr_label: "autonomous-agent",
        abandoned_draft_after_hours: 3,
        state_repo: "Poetic-Poems/agent-ops-state"}' > "$config"

# --- The stub gh -----------------------------------------------------------------
# Dispatches on the argument shape the sweep actually uses, serving fixtures
# from $SWEEP_STUB_DIR and recording every call in calls.log. File names take
# the branch with `/` flattened to `_`.
stub="$tmp_dir/gh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
S="$SWEEP_STUB_DIR"
printf '%s\n' "$*" >> "$S/calls.log"
args="$*"
flat() { local b="$1"; printf '%s' "${b//\//_}"; }
case "$args" in
  "api repos/x/y --jq .default_branch")
    echo main; exit 0 ;;
  "api repos/x/y/git/matching-refs/heads/"*)
    p="${args##*matching-refs/heads/}"; p="${p%% *}"
    f="$S/refs-$(flat "$p")tsv"
    [[ -f "$f" ]] && cat "$f"
    exit 0 ;;
  "pr list -R x/y --head "*)
    b="${args##*--head }"; b="${b%% *}"
    if [[ "$args" == *"--state open"* ]]; then st=open
    elif [[ "$args" == *"--state merged"* ]]; then st=merged
    else echo "stub gh: pr list without a recognised --state: $args" >&2; exit 1
    fi
    if [[ -f "$S/fail-$st-pr-list-$(flat "$b")" ]]; then exit 1; fi
    if [[ -f "$S/prs-$st-$(flat "$b")" ]]; then cat "$S/prs-$st-$(flat "$b")"; else echo 0; fi
    exit 0 ;;
  "api repos/Poetic-Poems/agent-ops-state/contents/claims/x__y/"*)
    b="${args##*claims/x__y/}"; b="${b%%.json*}"
    if [[ -f "$S/registry-500-$b" ]]; then
      echo "gh: HTTP 500 something broke" >&2; exit 1
    elif [[ -f "$S/registry-$b" ]]; then
      echo '{"content":"e30="}'; exit 0
    else
      echo "gh: Not Found (HTTP 404)" >&2; exit 1
    fi ;;
  "api repos/x/y/commits/"*)
    sha="${args##*commits/}"; sha="${sha%% *}"
    if [[ -f "$S/date-$sha" ]]; then cat "$S/date-$sha"; exit 0; fi
    exit 1 ;;
  "api repos/x/y/compare/main..."*)
    b="${args##*compare/main...}"; b="${b%% *}"
    if [[ -f "$S/ahead-$(flat "$b")" ]]; then cat "$S/ahead-$(flat "$b")"; exit 0; fi
    exit 1 ;;
  "api -X DELETE repos/x/y/git/refs/heads/"*)
    exit 0 ;;
  "pr create -R x/y --draft --head "*)
    b="${args##*--head }"; b="${b%% *}"
    if [[ -f "$S/fail-labelled-create" && "$args" == *"--label"* ]]; then
      exit 1
    fi
    echo "https://github.com/x/y/pull/9$(flat "$b" | cksum | cut -c1-2)"
    exit 0 ;;
  *)
    echo "stub gh: unexpected call: $args" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub"

stale=2020-01-01T00:00:00Z
fresh="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# run_sweep CASE_DIR — invoke the sweep against that fixture dir.
run_sweep() {
  SWEEP_STUB_DIR="$1" SWEEP_GH="$stub" AGENT_OPS_CONFIG="$config" \
    bash "$SWEEP" x/y
}

# --- Case 1: every guard, one branch each ---------------------------------------
c="$tmp_dir/guards"; mkdir -p "$c"
printf 'td/open-pr\tsha1\ntd/claimed\tsha2\ntd/reg-err\tsha3\ntd/fresh\tsha4\n' > "$c/refs-td_tsv"
printf 'agent/moved\tsha5\nagent/empty\tsha6\n' > "$c/refs-agent_tsv"
echo 1 > "$c/prs-open-td_open-pr"
touch "$c/registry-td__claimed"
touch "$c/registry-500-td__reg-err"
for s in sha1 sha2 sha3 sha5 sha6; do echo "$stale" > "$c/date-$s"; done
echo "$fresh" > "$c/date-sha4"
echo 2 > "$c/ahead-agent_moved"
echo 0 > "$c/ahead-agent_empty"

out="$(run_sweep "$c")"
calls="$(cat "$c/calls.log")"

assert_eq "a stale moved orphan is recovered as a draft PR" \
  '{"action":"recovered","branch":"agent/moved","pr_url":"https://github.com/x/y/pull/9'"$(printf 'agent_moved' | cksum | cut -c1-2)"'","ahead_by":2}' \
  "$(jq -c 'select(.action == "recovered")' <<<"$out")"
assert_contains "and the draft carries the abandoned-drafts label" \
  "pr create -R x/y --draft --head agent/moved --base main --title chore(recover): resume orphaned branch agent/moved" \
  "$calls"
assert_contains "with the label the gatherer keys on" \
  "--label autonomous-agent" "$calls"
assert_eq "a stale empty orphan's ref is released" \
  '{"action":"released","branch":"agent/empty"}' \
  "$(jq -c 'select(.action == "released")' <<<"$out")"
assert_contains "by deleting the ref" \
  "api -X DELETE repos/x/y/git/refs/heads/agent/empty" "$calls"

assert_not_contains "a branch with an open PR is left alone" "td/open-pr" \
  "$(jq -c 'select(.action != "warning")' <<<"$out")"
assert_not_contains "a branch with a live registry entry is left alone" "td/claimed" "$out"
assert_not_contains "and its tip is never even dated" \
  "api repos/x/y/commits/sha2" "$calls"
assert_not_contains "a branch younger than the threshold is left alone" "td/fresh" "$out"
assert_eq "a registry error that is not 404 warns and touches nothing" \
  '{"action":"warning","branch":"td/reg-err","detail":"registry read failed with something other than 404 — leaving it alone"}' \
  "$(jq -c 'select(.action == "warning")' <<<"$out")"
assert_not_contains "so no compare, delete or create ever mentions it" \
  "td/reg-err" "$(grep -vE '^(api repos/Poetic-Poems|pr list)' "$c/calls.log")"

# --- Case 2: the per-run cap ----------------------------------------------------
c="$tmp_dir/cap"; mkdir -p "$c"
: > "$c/refs-td_tsv"
for i in 1 2 3 4 5; do
  printf 'agent/orphan-%s\tsha-%s\n' "$i" "$i" >> "$c/refs-agent_tsv"
  echo "$stale" > "$c/date-sha-$i"
  echo 1 > "$c/ahead-agent_orphan-$i"
done

out="$(run_sweep "$c")"
assert_eq "a backlog past the cap acts on the cap's worth" \
  "3" "$(jq -c 'select(.action == "recovered")' <<<"$out" | wc -l | tr -d ' ')"
assert_eq "and reports the remainder rather than staying silent" \
  '{"action":"deferred","remaining":2}' \
  "$(jq -c 'select(.action == "deferred")' <<<"$out")"

# --- Case 3: the label fallback -------------------------------------------------
c="$tmp_dir/label"; mkdir -p "$c"
: > "$c/refs-td_tsv"
printf 'agent/unlabelled\tsha-u\n' > "$c/refs-agent_tsv"
echo "$stale" > "$c/date-sha-u"
echo 1 > "$c/ahead-agent_unlabelled"
touch "$c/fail-labelled-create"

out="$(run_sweep "$c")"
assert_eq "a repo without the label still gets its work back" \
  "agent/unlabelled" "$(jq -r 'select(.action == "recovered") | .branch' <<<"$out")"
assert_contains "and the fallback is loud about the gatherer's blindness" \
  "recovered without the autonomous-agent label" \
  "$(jq -r 'select(.action == "warning") | .detail' <<<"$out")"

# --- Case 4: a squash-merged branch never left `ahead_by` -----------------------
# Every repo here squash-merges, so a branch's own commits never enter the
# default branch's history: `ahead_by` stays positive forever even though the
# work already landed. A merged PR against the head is what tells the sweep
# this is a leftover ref, not unrecovered work (issue #302).
c="$tmp_dir/merged-leftover"; mkdir -p "$c"
: > "$c/refs-td_tsv"
printf 'agent/landed\tsha-landed\n' > "$c/refs-agent_tsv"
echo "$stale" > "$c/date-sha-landed"
echo 4 > "$c/ahead-agent_landed"
echo 1 > "$c/prs-merged-agent_landed"

out="$(run_sweep "$c")"
calls="$(cat "$c/calls.log")"
assert_eq "a squash-merged leftover is released, not recovered" \
  '{"action":"released","branch":"agent/landed"}' \
  "$(jq -c 'select(.branch == "agent/landed")' <<<"$out")"
assert_contains "by deleting the ref" \
  "api -X DELETE repos/x/y/git/refs/heads/agent/landed" "$calls"
assert_not_contains "and no recovery draft is ever opened for it" \
  "pr create" "$(grep 'agent/landed' "$c/calls.log" || true)"

# --- Case 5: the merged-PR check itself is fail-closed ---------------------------
c="$tmp_dir/merged-check-fails"; mkdir -p "$c"
: > "$c/refs-td_tsv"
printf 'agent/unknown\tsha-unknown\n' > "$c/refs-agent_tsv"
echo "$stale" > "$c/date-sha-unknown"
echo 3 > "$c/ahead-agent_unknown"
touch "$c/fail-merged-pr-list-agent_unknown"

out="$(run_sweep "$c")"
assert_eq "a merged-PR check that errors warns rather than guessing" \
  '{"action":"warning","branch":"agent/unknown","detail":"could not check for a merged PR — leaving it alone"}' \
  "$(jq -c 'select(.branch == "agent/unknown")' <<<"$out")"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
