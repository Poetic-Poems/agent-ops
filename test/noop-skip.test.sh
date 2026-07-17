#!/usr/bin/env bash
#
# test/noop-skip.test.sh — regression test for lib/noop-skip.sh.
#
# The no-op short-circuit trades a Co-Ordinator run for a claim: "nothing it
# reads has changed, so its answer cannot have". If the claim is ever wrong in
# the permissive direction, the pipeline stops picking up work and says nothing
# — no error, no failed stage, just tidy `stand-down` events and no PRs. That
# is this system's signature failure (see the Gotchas table), and this rule is
# a fresh opportunity to build one.
#
# So the assertions that matter here are not "it skips when nothing changed"
# (one test) but "it *stops* skipping when each individual source moves" — one
# per source, because a source omitted from the fingerprint fails exactly this
# way and nothing else in the system would tell you. Any new work source added
# to config.json needs a signal in gather-source-state.sh and a case below; a
# source that reaches the Co-Ordinator but not the fingerprint is a stall
# waiting for a quiet week.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/noop-skip.test.sh
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

# A fingerprint input standing in for one quiet cycle: two repos, every source
# sampled cleanly, nothing to do.
base_input() {
  cat <<'EOF'
{
  "repos": [
    {
      "slug": "o/one",
      "default_branch": "main",
      "sources": ["security", "review-feedback", "tech-debt", "issues"],
      "findings": [{"ref": "dependabot-alert-1", "severity": "high"}],
      "review_feedback": [],
      "state": {
        "slug": "o/one", "ok": true, "head_sha": "aaa111",
        "issues": [{"n": 7, "u": "2026-07-16T09:00:00Z", "l": ["bug"], "a": ""}],
        "workflows": [{"w": 1, "c": "success"}],
        "open_prs": [{"n": 3, "u": "2026-07-16T09:00:00Z", "h": "agent/x", "d": true}]
      }
    },
    {
      "slug": "o/two",
      "default_branch": "main",
      "sources": ["issues"],
      "findings": [],
      "review_feedback": [],
      "state": {
        "slug": "o/two", "ok": true, "head_sha": "bbb222",
        "issues": [], "workflows": [], "open_prs": []
      }
    }
  ],
  "blocked": [{"ts": "2026-07-16T08:00:00Z", "repo": "o/one", "item": "TD26071601", "detail": "waiting on a decision"}],
  "void": [{"ts": "2026-07-15T08:00:00Z", "repo": "o/one", "item": "review-2026-07-11-R-01", "detail": "already done"}],
  "selection_config": {"coordinator_model": "claude-haiku-4-5-20251001", "models": {"default": "claude-sonnet-5", "trivial": "claude-haiku-4-5-20251001"}},
  "coordinator_prompt_sha": "deadbeef"
}
EOF
}

# fp_with JQ_MUTATION — the fingerprint of base_input with one edit applied.
fp_with() { base_input | jq -c "$1" | noop_fingerprint; }

base_fp="$(base_input | noop_fingerprint)"
assert_eq "a clean cycle is fingerprintable" "64" "${#base_fp}"

# --- Stability: the fingerprint must track meaning, not incidental form ---

assert_eq "the same inputs give the same fingerprint" "$base_fp" "$(base_input | noop_fingerprint)"
assert_eq "key order does not change the fingerprint" "$base_fp" \
  "$(base_input | jq -c '{coordinator_prompt_sha, selection_config, void, blocked, repos}' | noop_fingerprint)"
assert_eq "repo order does not change the fingerprint" "$base_fp" \
  "$(fp_with '.repos |= reverse')"
# A blocked item re-recorded with a fresh timestamp and reworded detail is the
# same skip-list. Fingerprinting the raw event would buy a Co-Ordinator run for
# a log line that changed nothing about what it may select.
assert_eq "a blocked entry's ts and detail are not part of the fingerprint" "$base_fp" \
  "$(fp_with '.blocked[0].ts = "2026-07-17T23:00:00Z" | .blocked[0].detail = "reworded"')"
assert_eq "default_branch is not double-counted (head_sha already covers it)" "$base_fp" \
  "$(fp_with '.repos[0].default_branch = "trunk"')"

# A green workflow running again on a schedule reaches the same conclusion
# under a new run id, and changes no candidate. `poetic` schedules
# sync-framework.yml hourly — on the same cadence as this pipeline — so a
# digest that tracked run ids would bust the fingerprint on every cycle and
# reduce the entire short-circuit to an expensive no-op, silently and while
# looking perfectly installed. gather-source-state.sh digests conclusions only;
# this asserts the shape it produces cannot carry a run id back in.
assert_eq "an hourly scheduled workflow rerunning green does not change the fingerprint" "$base_fp" \
  "$(base_input | noop_fingerprint)"
assert_eq "the workflows digest holds no run id to churn on" "" \
  "$(base_input | jq -r '[.repos[].state.workflows[]? | keys[]] | unique - ["w","c"] | join(",")')"

# --- Coverage: every input to the Co-Ordinator's verdict must move it ---
#
# One case per source. A source that can gain work without moving the
# fingerprint is a silent stall, and this block is the only thing standing
# between that bug and production.

assert_ne() {
  local desc="$1" fp="$2"
  if [[ "$fp" != "$base_fp" && -n "$fp" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     fingerprint did not change: %s\n' "$desc" "$fp"
    failures=$(( failures + 1 ))
  fi
}

# tech-debt, implementation-plan, project-review and the code itself: all
# file-backed, none can change without the head SHA changing.
assert_ne "a commit on the default branch changes the fingerprint" \
  "$(fp_with '.repos[0].head_sha = "ccc333" | .repos[0].state.head_sha = "ccc333"')"
assert_ne "a new security finding changes the fingerprint" \
  "$(fp_with '.repos[0].findings += [{"ref": "dependabot-alert-2", "severity": "critical"}]')"
assert_ne "a re-rated finding changes the fingerprint" \
  "$(fp_with '.repos[0].findings[0].severity = "critical"')"
assert_ne "a new issue changes the fingerprint" \
  "$(fp_with '.repos[1].state.issues += [{"n": 9, "u": "2026-07-17T10:00:00Z", "l": [], "a": ""}]')"
# Requirement 16.4: a label or an assignment is what decides whether an issue
# is a candidate at all, so triage that changes nothing else must still count.
assert_ne "relabelling an issue changes the fingerprint" \
  "$(fp_with '.repos[0].state.issues[0].l = ["bug", "blocked"]')"
assert_ne "assigning an issue changes the fingerprint" \
  "$(fp_with '.repos[0].state.issues[0].a = "someone"')"
# The one source that can change with no commit at all: a scheduled run or a
# re-run turns main red while every SHA stays put. Dropping the run id from the
# digest must not cost us this — the conclusion is what requirement 15 reads.
assert_ne "a workflow run turning main red changes the fingerprint" \
  "$(fp_with '.repos[0].state.workflows[0] = {"w": 1, "c": "failure"}')"
assert_ne "a newly added workflow changes the fingerprint" \
  "$(fp_with '.repos[0].state.workflows += [{"w": 2, "c": "failure"}]')"
# Requirement 16.3: an open PR is a claim. Closing it releases the claim and
# creates a candidate, touching no commit, issue or alert.
assert_ne "closing a claiming PR changes the fingerprint" \
  "$(fp_with '.repos[0].state.open_prs = []')"
assert_ne "a PR leaving draft changes the fingerprint" \
  "$(fp_with '.repos[0].state.open_prs[0].d = false')"
# A human appending `unblocked`/`unvoided` by hand (requirements 34, 34c) is
# how a stuck item is freed. If the skip-lists weren't fingerprinted, that
# intervention would sit unnoticed until something else happened to change.
assert_ne "an item becoming unblocked changes the fingerprint" \
  "$(fp_with '.blocked = []')"
assert_ne "an item becoming unvoided changes the fingerprint" \
  "$(fp_with '.void = []')"
assert_ne "a newly blocked item changes the fingerprint" \
  "$(fp_with '.blocked += [{"repo": "o/two", "item": "TD26071701", "detail": "x"}]')"
# The same id in a different repo is a different item (requirement 34).
assert_ne "the same item id blocked in a different repo changes the fingerprint" \
  "$(fp_with '.blocked[0].repo = "o/two"')"
# review-feedback. The candidate only exists while it is the agent's turn (see
# gather-review-feedback.sh), so its arrival and its disappearance are both
# fingerprint events. Digesting the PR's reviewDecision instead would be stably
# CHANGES_REQUESTED before and after the fix, because the agent cannot dismiss a
# review on its own PR — the fingerprint would never notice the work was done.
assert_ne "a human requesting changes changes the fingerprint" \
  "$(fp_with '.repos[0].review_feedback += [{"ref": "pr-57-review-99", "number": 57, "reviewed_at": "2026-07-17T01:22:54Z", "body": "please fix the gitignore gap"}]')"

# Config and prompt: the two inputs that aren't repo state, and the two most
# likely to be left out. Without them, editing the selection rules does nothing
# until an unrelated commit lands and you spend the afternoon debugging an edit
# that was correct all along.
assert_ne "adding a work source to a repo changes the fingerprint" \
  "$(fp_with '.repos[1].sources += ["tech-debt"]')"
assert_ne "adding a repo changes the fingerprint" \
  "$(fp_with '.repos += [{"slug": "o/three", "sources": [], "findings": [], "state": {"slug": "o/three", "ok": true, "head_sha": "d", "issues": [], "workflows": [], "open_prs": []}}]')"
assert_ne "changing the Co-Ordinator's model changes the fingerprint" \
  "$(fp_with '.selection_config.coordinator_model = "claude-sonnet-5"')"
assert_ne "editing prompts/coordinator.md changes the fingerprint" \
  "$(fp_with '.coordinator_prompt_sha = "feedface"')"

# --- A cycle that could not be sampled is not fingerprintable ---
#
# The alternative — hashing a digest built from failed API calls — is stable
# and wrong: two consecutive outages would agree with each other and skip, and
# go on skipping for as long as the outage lasted.

assert_eq "one repo failing to sample makes the whole cycle unfingerprintable" "" \
  "$(fp_with '.repos[0].state.ok = false')"
assert_eq "a repo with no state at all is unfingerprintable" "" \
  "$(fp_with '.repos[0].state = {"ok": false}')"

# The call-site shape under `set -e`: an unfingerprintable cycle is a normal
# outcome (it just runs the Co-Ordinator), so it must not abort the caller.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/noop-skip.sh"
  fp="$(base_input | jq -c '.repos[0].state.ok = false' | noop_fingerprint)"
  r="$(noop_skip_reason "$fp" "/nonexistent/log.jsonl" 24)"
  printf '%s%s' "$fp" "$r" >/dev/null
  exit 0
) >/dev/null 2>&1
assert_eq "an unfingerprintable cycle does not abort its caller under set -e" "0" "$?"

# --- noop_skip_reason ---

log="$tmp_dir/log.jsonl"
now="$(date -u -d '2026-07-17T12:00:00Z' +%s)"

skips() {
  local reason
  reason="$(noop_skip_reason "$1" "$log" "$2" "$now")"
  [[ -n "$reason" ]] && echo yes || echo no
}

: > "$log"
assert_eq "an empty log skips nothing" "no" "$(skips "$base_fp" 24)"

cat > "$log" <<EOF
{"ts":"2026-07-17T11:00:00Z","event":"none-selected","reason":"nothing to do","fingerprint":"$base_fp"}
EOF
assert_eq "a matching fingerprint from an hour ago skips" "yes" "$(skips "$base_fp" 24)"
assert_eq "a different fingerprint does not skip" "no" "$(skips "$(fp_with '.repos[0].state.head_sha = "ccc333"')" 24)"
assert_eq "an unfingerprintable cycle never skips" "no" "$(skips "" 24)"

# Requirement 3b's safety valve. Without it, a source missing from the
# fingerprint is an unbounded outage rather than a bounded one.
cat > "$log" <<EOF
{"ts":"2026-07-16T11:00:00Z","event":"none-selected","reason":"nothing to do","fingerprint":"$base_fp"}
EOF
assert_eq "a match older than the recheck window is re-checked, not skipped" "no" "$(skips "$base_fp" 24)"
assert_eq "the same match inside a longer window still skips" "yes" "$(skips "$base_fp" 48)"
assert_eq "a recheck window of 0 disables the valve" "yes" "$(skips "$base_fp" 0)"

# A `none-selected` written before this feature existed, or on a cycle that
# could not be sampled, says nothing about the current state.
cat > "$log" <<'EOF'
{"ts":"2026-07-17T11:00:00Z","event":"none-selected","reason":"nothing to do"}
EOF
assert_eq "a none-selected carrying no fingerprint skips nothing" "no" "$(skips "$base_fp" 24)"

# The most recent fingerprinted none-selected wins: the world has moved on and
# come back, or it has moved on and stayed.
cat > "$log" <<EOF
{"ts":"2026-07-17T09:00:00Z","event":"none-selected","reason":"nothing to do","fingerprint":"$base_fp"}
{"ts":"2026-07-17T10:00:00Z","event":"selection","repo":"o/one","item":"TD1"}
{"ts":"2026-07-17T11:00:00Z","event":"none-selected","reason":"nothing to do","fingerprint":"other"}
EOF
assert_eq "an older matching fingerprint is superseded by a newer one" "no" "$(skips "$base_fp" 24)"

# A malformed line must not strand the rule: one truncated append would
# otherwise buy a Co-Ordinator run every hour forever.
cat > "$log" <<EOF
{"ts":"2026-07-17T11:00:00Z","event":"none-selected","reason":"nothing to do","fingerprint":"$base_fp"}
{"ts":"2026-07-17T11:05:00Z","event":"cycle-e
EOF
assert_eq "a malformed trailing line does not lose the fingerprint" "yes" "$(skips "$base_fp" 24)"

# An unreadable timestamp cannot be aged, and an unaged skip is an unbounded
# one — the recheck valve would never fire.
cat > "$log" <<EOF
{"ts":"whenever","event":"none-selected","reason":"nothing to do","fingerprint":"$base_fp"}
EOF
assert_eq "a none-selected with an unparseable ts does not skip" "no" "$(skips "$base_fp" 24)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
