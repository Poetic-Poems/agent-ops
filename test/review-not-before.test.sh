#!/usr/bin/env bash
#
# test/review-not-before.test.sh — `project_review.defaults.not_before` holds the weekly review
# off until a date, and nothing else off at all.
#
# The requirement it serves (R3.3) is one the switch cannot express. `--disable`
# is deliberately shared between both pipelines, so using it to hold a review
# back would stop the implementation cycles for the same window — and the case
# this exists for is precisely "no reviews until Thursday, but keep working".
#
# Six behaviours, and the middle four are the ones that would fail quietly:
#
#   in force      a timestamp in the future stands the review down, and says so
#                 in the log with the date attached, so an operator reading
#                 `review-stand-down` can tell this apart from a switch
#   expired       a timestamp in the past is inert — the whole point of a
#                 timestamp over a raised `min_days_between_reviews` is that it
#                 needs no undoing, and a stand-down that outlived its date
#                 would be the throttle-left-on failure wearing a new hat
#   absent        no key, or an empty one, is not a stand-down. The key is
#                 optional and most nodes will never set it
#   unparseable   stands down rather than running. The operator plainly meant
#                 to hold reviews off; running through a value we could not
#                 read would spend exactly the quota they were protecting
#   tier two      `project_review.defaults.not_before` is only the
#                 installation-wide half (requirement 342); when it is itself
#                 unset but every configured repository's own override still
#                 holds it off, the whole cycle stands down before the lock
#                 too, rather than taking it for a run R4's skip-guard would
#                 skip every repository of anyway
#   mixed         and the converse: one repository held on its own override
#                 while another is free stands *neither* tier down — the cycle
#                 runs, and R4's per-repository skip-guard turns the held one
#                 away by name. A `not_before` that only ever ran cycle-wide
#                 passes every case above and fails this one alone
#
# Each case runs the real `review-cycle.sh` against a shim node: a directory of
# symlinks back into the tree with its own `config.json`, which works because
# the script takes SCRIPT_DIR from its own path and reads config from there.
# `project_review.repos` is emptied so a run that is *not* stood down still finishes
# without reaching for the network — except the last two cases, which need real
# entries to exercise the per-repository resolution: the tier-two case relies on
# the stand-down itself firing before any repository is touched, and the mixed
# case, which by design gets past it, on the fail-fast shims described below.
#
# No network. Run directly: ./test/review-not-before.test.sh — exit 0 iff all
# passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# A shim node: symlinks back into the tree, plus a config of its own. `$1` is a
# jq filter applied to the real config, so each case states only its difference
# and every other required key stays in step with the shipped file.
make_node() {  # make_node <name> <jq-filter> -> prints its directory
  # Separate statements on purpose: `local a=… b="$a"` expands every argument
  # before assigning any, so the second would read an unset `a` under `set -u`.
  local name="$1" filter="$2"
  local dir="$tmp_dir/$name"
  mkdir -p "$dir" "$dir/home"
  local item
  for item in lib prompts scripts .claude review-cycle.sh agent-cycle.sh config.schema.json; do
    [[ -e "$SCRIPT_DIR/$item" ]] && ln -s "$SCRIPT_DIR/$item" "$dir/$item"
  done
  jq "$filter" "$SCRIPT_DIR/config.json" > "$dir/config.json"
  printf '%s' "$dir"
}

# Prints stdout+stderr and leaves the exit status in RC. A stand-down must end
# 0: supercronic reports a non-zero tick as a failed job, so a pipeline that
# held itself back correctly would page as though it had broken — the same
# shape of bug as the dashboard launcher's exit status (publish-dashboard).
RC=0
run_review() {  # run_review <dir> -> prints stdout+stderr, sets RC
  local dir="$1" out
  out="$(env HOME="$dir/home" AGENT_OPS_ROLE=active \
    timeout 60 "$dir/review-cycle.sh" --once 2>&1)"
  RC=$?
  printf '%s' "$out"
}

# The mixed case below is the one that must survive the stand-down checks and
# run on into the per-repository skip-guard, so it cannot rely on an empty
# `project_review.repos` to keep it offline the way every other case here does.
# Fail-fast shims stand in the way of every reach for the network instead, on
# the same reasoning test/review-claim.test.sh gives at its own copy: a test
# that needs a step not to happen must be the thing that stops it, rather than
# passing on a machine without egress and failing on a CI runner with one. The
# skip-guard's own `gh` reads degrade to "proceed" when they fail, which is
# what makes the not_before skip the only reason either repository can be
# skipped for here.
fail_bin="$tmp_dir/fail-bin"
mkdir -p "$fail_bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_bin/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_bin/claude"
chmod +x "$fail_bin/gh" "$fail_bin/claude"

run_review_offline() {  # run_review_offline <dir> -> prints stdout+stderr, sets RC
  local dir="$1" out
  out="$(env HOME="$dir/home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$dir")" \
    PATH="$fail_bin:$PATH" TOGGLE_GH=/bin/false CLAIM_GH=/bin/false \
    CLONE_GIT=/bin/false \
    GIT_USER_NAME="Test Node" GIT_USER_EMAIL="test-node@example.invalid" \
    timeout 180 "$dir/review-cycle.sh" --once 2>&1)"
  RC=$?
  printf '%s' "$out"
}

events_of() {  # events_of <dir> -> the review log, one JSON object per line
  cat "$1/home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null || true
}

stand_down_reason() {  # stand_down_reason <dir>
  events_of "$1" | jq -r 'select(.event == "review-stand-down") | .reason' 2>/dev/null || true
}

# `repos: []` keeps a non-stood-down run offline; `state_repo: ""` keeps the
# fleet switch from reaching for one.
BASE='.project_review.repos = [] | .state_repo = ""'

# --- In force --------------------------------------------------------------------
d="$(make_node in-force "$BASE | .project_review.defaults.not_before = \"2099-01-01T00:00:00Z\"")"
out="$(run_review "$d")"
assert_contains "a future not_before stands the review down" \
  "standing down until 2099-01-01T00:00:00Z" "$out"
assert_contains "and the log says which rule did it" \
  "project_review.defaults.not_before: no review before 2099-01-01T00:00:00Z" "$(stand_down_reason "$d")"
assert_eq "with the date on the event, for the dashboard to read" "2099-01-01T00:00:00Z" \
  "$(events_of "$d" | jq -r 'select(.event == "review-stand-down") | .not_before' 2>/dev/null)"
assert_eq "and the tick still ends 0, so cron does not call it a failure" "0" "$RC"

# --- Expired ---------------------------------------------------------------------
# The property that distinguishes this from raising min_days_between_reviews:
# nothing has to be put back by hand once the date passes.
d="$(make_node expired "$BASE | .project_review.defaults.not_before = \"2000-01-01T00:00:00Z\"")"
out="$(run_review "$d")"
assert_lacks "a past not_before does not stand the review down" "standing down until" "$out"
assert_lacks "and leaves no stand-down of its own in the log" \
  "project_review.defaults.not_before" "$(stand_down_reason "$d")"
assert_lacks "nor does tier two fire — an empty project_review.repos has nothing to hold back" \
  "every configured repository's own not_before" "$out"

# --- Absent ----------------------------------------------------------------------
d="$(make_node absent "$BASE | del(.project_review.defaults.not_before)")"
out="$(run_review "$d")"
assert_lacks "an absent key is not a stand-down" "standing down until" "$out"
assert_lacks "nor is it reported as one" "project_review.defaults.not_before" "$(stand_down_reason "$d")"
assert_lacks "and tier two is vacuously false, not true, on an empty project_review.repos" \
  "every configured repository's own not_before" "$out"

d="$(make_node empty "$BASE | .project_review.defaults.not_before = \"\"")"
out="$(run_review "$d")"
assert_lacks "and neither is an empty one" "standing down until" "$out"

# --- Tier two: every configured repo held on its own override, with
#     project_review.defaults.not_before itself left unset --------------------------
# Tier one alone reads only the installation-wide key, so it would let this
# straight through to the lock even though every configured repository is
# individually held. `repos` carries two real entries here (rather than the
# empty array every other case above uses) precisely to exercise that: tier
# two must resolve each entry's own `not_before` override from
# project_review_repos_json and stand the whole cycle down before ever
# reaching a repository's own skip-guard or the network.
d="$(make_node tier-two-all-held ".project_review.defaults.not_before = \"\" \
  | .project_review.repos = [ {slug: \"Poetic-Poems/poetic\", not_before: \"2099-01-01T00:00:00Z\"}, \
                               {slug: \"Poetic-Poems/poetic-fiddle\", not_before: \"2099-06-01T00:00:00Z\"} ] \
  | .state_repo = \"\"")"
out="$(run_review "$d")"
assert_contains "every repository held on its own override stands the whole cycle down" \
  "every configured repository's own not_before" "$out"
assert_contains "naming requirement 342, the resolution rule tier one alone would miss" \
  "every configured repository's own not_before holds it off (requirement 342)" \
  "$(stand_down_reason "$d")"
assert_eq "and the tick still ends 0" "0" "$RC"

# --- Mixed: one repository held on its own override, one not ---------------------
# The other half of requirement 342's two-tier rule, and the half with nothing
# above it to catch a regression: neither tier may stand the *cycle* down here,
# because one repository is free to be reviewed — the held one has to be turned
# away by R4's per-repository skip-guard instead, once the cycle is under way.
# A `not_before` check that only ever ran cycle-wide would pass every assertion
# in this file except these.
d="$(make_node mixed-one-held ".project_review.defaults.not_before = \"\" \
  | .project_review.repos = [ {slug: \"Poetic-Poems/poetic\", not_before: \"2099-01-01T00:00:00Z\"}, \
                               {slug: \"Poetic-Poems/poetic-fiddle\"} ] \
  | .state_repo = \"\"")"
out="$(run_review_offline "$d")"
assert_lacks "one free repository is enough to keep tier two from firing" \
  "every configured repository's own not_before" "$out"
assert_lacks "and tier one has nothing to say either" "standing down until" "$out"
assert_contains "the held repository is skipped by name, with its own date" \
  "skip Poetic-Poems/poetic — not_before: no review before 2099-01-01T00:00:00Z" "$out"
assert_eq "and the skip is recorded against that repository alone" \
  "Poetic-Poems/poetic" \
  "$(events_of "$d" | jq -r 'select(.event == "review-skipped" and (.detail | startswith("not_before"))) | .repo' 2>/dev/null)"
assert_lacks "the repository inheriting the empty default is not held back by it" \
  "skip Poetic-Poems/poetic-fiddle — not_before" "$out"
assert_eq "and the tick still ends 0" "0" "$RC"

# --- Unparseable -----------------------------------------------------------------
# Fails towards the operator's evident intent, not through it.
d="$(make_node unparseable "$BASE | .project_review.defaults.not_before = \"next Thursday-ish\"")"
out="$(run_review "$d")"
assert_contains "an unparseable not_before stands down rather than running" \
  "not a date this system can parse" "$out"
assert_contains "and the log names the value, so it can be corrected" \
  "next Thursday-ish" "$(stand_down_reason "$d")"
assert_eq "and this one ends 0 too — a bad value is not a crash" "0" "$RC"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
