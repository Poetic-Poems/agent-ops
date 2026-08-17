#!/usr/bin/env bash
#
# test/landing.test.sh — regression test for lib/landing.sh (D18 WI-7,
# docs/reviews/2026-08-14-autonomy-investigation.md §5.1, §6, §7;
# agent-ops#410): the deterministic eligibility classifier and the arming
# primitives.
#
# Covers, against a stubbed `gh`:
#   - landing_protected_paths_hit: a protected path is reported and exits 0,
#     all nine prefixes are recognised (the three the first draft deferred
#     to human review — `config.json`, `agent-cycle.sh`, `review-cycle.sh` —
#     each pinned singly as well), a nested or suffixed near-miss is not
#     protected, an all-clear set exits 1 with nothing printed, an unreadable
#     or truncated changed-file listing exits 2 (never a pass), and bad
#     arguments are rejected before any gh call.
#   - landing_eligible: LEVEL below agent-merges-routine, COMPLEXITY above
#     medium, and a SOURCE outside the routine list are each `ineligible`
#     with no gh call at all; a repo-level merge_autonomy_routine_sources
#     override widens what that one repository accepts; a protected path
#     is `ineligible`; an unreadable changed-file list is `unknown`, never
#     a pass; the plain-string SOURCE comparison this file's own header
#     documents is pinned directly — an `issues:low` entry in the routine
#     list never matches the plain word `issues` a real issues work order
#     always carries.
#   - landing_arm: a base branch with an active merge queue enqueues via
#     the enqueuePullRequest mutation; one without falls back to
#     `gh pr merge --auto --squash`; both write under GH_TOKEN for that one
#     invocation only; an unreadable pull request, an unreadable queue
#     probe, a refused mutation or a refused merge each return non-zero
#     printing nothing; bad arguments are rejected before any gh call.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/landing.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/landing.sh
. "$SCRIPT_DIR/lib/landing.sh"

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

# --- The stub gh -------------------------------------------------------------
# Dispatches on the sub-command / path shape, the same per-call-type fixture
# technique test/merge-budget.test.sh and test/merge-queue.test.sh both use.
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
fixtures="$tmp_dir/fixtures"
mkdir -p "$fixtures"
enqueue_calls="$tmp_dir/enqueue-calls"
merge_calls="$tmp_dir/merge-calls"
: > "$enqueue_calls"
: > "$merge_calls"

cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args=("$@")
f="$GH_FIXTURES"

# --- gh api repos/SLUG/pulls/NUMBER/files --paginate -F per_page=100 --jq ... ---
if [[ "${args[0]:-}" == "api" && "${args[1]:-}" == repos/*/pulls/*/files ]]; then
  [[ -f "$f/files-fail" ]] && exit 1
  cat "$f/files.txt" 2>/dev/null
  exit 0
fi

# --- gh api repos/SLUG/pulls/NUMBER/reviews --paginate --jq ... ---
if [[ "${args[0]:-}" == "api" && "${args[1]:-}" == repos/*/pulls/*/reviews ]]; then
  [[ -f "$f/reviews-fail" ]] && exit 1
  jqfilter="" prev=""
  for a in "${args[@]}"; do
    [[ "$prev" == "--jq" ]] && jqfilter="$a"
    prev="$a"
  done
  jq -c "$jqfilter" "$f/reviews.json" 2>/dev/null
  exit 0
fi

# --- gh api repos/SLUG/pulls/NUMBER --jq '{id,base}' ---
if [[ "${args[0]:-}" == "api" && "${args[1]:-}" == repos/*/pulls/* \
      && "${args[1]:-}" != */files && "${args[1]:-}" != */reviews ]]; then
  [[ -f "$f/pr-fail" ]] && exit 1
  cat "$f/pr.json" 2>/dev/null
  exit 0
fi

# --- gh api graphql ... (merge_queue_for_branch's read, or landing_arm's
#     enqueuePullRequest write) — distinguished by the query text, since
#     both reach this same sub-command. ---
if [[ "${args[0]:-}" == "api" && "${args[1]:-}" == "graphql" ]]; then
  query="" jqfilter=""
  i=2
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      --jq) i=$((i+1)); jqfilter="${args[$i]}" ;;
      -f)   i=$((i+1)); kv="${args[$i]}"; [[ "$kv" == query=* ]] && query="${kv#query=}" ;;
    esac
    i=$((i+1))
  done
  if [[ "$query" == *enqueuePullRequest* ]]; then
    [[ -f "$f/enqueue-fail" ]] && exit 1
    printf '%s\n' "${GH_TOKEN:-<none>}" >> "$ENQUEUE_CALLS"
    jq -c "$jqfilter" "$f/enqueue-response.json" 2>/dev/null
    exit 0
  fi
  if [[ "$query" == *mergeQueue* ]]; then
    [[ -f "$f/queue-fail" ]] && exit 1
    jq -c "$jqfilter" "$f/queue-response.json" 2>/dev/null
    exit 0
  fi
  exit 1
fi

# --- gh pr merge NUMBER -R SLUG --auto --squash ---
if [[ "${args[0]:-}" == "pr" && "${args[1]:-}" == "merge" ]]; then
  [[ -f "$f/merge-fail" ]] && exit 1
  printf '%s\n' "${GH_TOKEN:-<none>}" >> "$MERGE_CALLS"
  exit 0
fi

echo "gh-stub: unhandled invocation: ${args[*]}" >&2
exit 1
STUB
chmod +x "$stub_bin/gh"

export GH_FIXTURES="$fixtures" ENQUEUE_CALLS="$enqueue_calls" MERGE_CALLS="$merge_calls"
LANDING_GH="$stub_bin/gh"; MERGE_QUEUE_GH="$stub_bin/gh"
export LANDING_GH MERGE_QUEUE_GH

files() { printf '%s\n' "$@" > "$fixtures/files.txt"; }
prd() {  # prd NODE_ID BASE
  jq -nc --arg id "$1" --arg base "$2" '{id: $id, base: $base}' > "$fixtures/pr.json"
}
queue() {  # queue null|OBJECT — the raw mergeQueue value, wrapped as the
           # GraphQL envelope merge_queue_for_branch's own --jq filter
           # (.data.repository.mergeQueue) expects.
  jq -nc --argjson mq "$1" '{data:{repository:{mergeQueue: $mq}}}' > "$fixtures/queue-response.json"
}
review() {  # review LOGIN STATE AT
  jq -nc --arg l "$1" --arg s "$2" --arg at "$3" \
    '{user: {login: $l}, submitted_at: $at, state: $s}'
}
set_reviews() { jq -sc '.' > "$fixtures/reviews.json"; }  # one `review …` per stdin line

prd "PR_kwDOfake" "main"
queue null
echo '{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"id":"MQE_fake"}}}}' > "$fixtures/enqueue-response.json"

# --- landing_protected_paths_hit ---------------------------------------------

files "src/app.py" "lib/merge-budget.sh" "README.md"
out="$(landing_protected_paths_hit acme/widgets 12)"; rc=$?
assert_eq "a protected path is reported" "lib/merge-budget.sh" "$out"
assert_eq "  ... exit 0" "0" "$rc"

files "src/app.py" "README.md" "docs/notes.md"
out="$(landing_protected_paths_hit acme/widgets 12)"; rc=$?
assert_eq "no protected path: nothing printed" "" "$out"
assert_eq "  ... exit 1" "1" "$rc"

files "config.schema.json" "CODEOWNERS" "lib/x.sh" ".github/workflows/y.yml" "deploy/z" "prompts/p.md" \
      "config.json" "agent-cycle.sh" "review-cycle.sh"
out="$(landing_protected_paths_hit acme/widgets 12)"; rc=$?
assert_eq "every protected prefix is recognised, one per line" \
  "config.schema.json
CODEOWNERS
lib/x.sh
.github/workflows/y.yml
deploy/z
prompts/p.md
config.json
agent-cycle.sh
review-cycle.sh" "$out"
assert_eq "  ... exit 0" "0" "$rc"

# The three the first draft left off the list, each on its own so a
# regression names which one came off rather than failing the nine-way
# assertion above with a diff to read.
for protected in config.json agent-cycle.sh review-cycle.sh; do
  files "src/app.py" "$protected" "README.md"
  out="$(landing_protected_paths_hit acme/widgets 12)"; rc=$?
  assert_eq "$protected is protected" "$protected" "$out"
  assert_eq "  ... exit 0" "0" "$rc"
done

# Anchored, not a prefix match: the classifier must not catch a same-named
# file nested under a directory, nor a longer name that merely starts the
# same way.
files "src/app.py" "docs/config.json" "tools/agent-cycle.sh" "config.json.bak" "review-cycle.sh.orig"
out="$(landing_protected_paths_hit acme/widgets 12)"; rc=$?
assert_eq "a nested or suffixed near-miss is not protected" "" "$out"
assert_eq "  ... exit 1" "1" "$rc"

: > "$fixtures/files-fail"
out="$(landing_protected_paths_hit acme/widgets 12)"; rc=$?
assert_eq "an unreadable changed-file list: exit 2, nothing printed" "2" "$rc"
assert_eq "  ... nothing printed" "" "$out"
rm -f "$fixtures/files-fail"

files a b c
out="$(LANDING_PR_FILES_LIMIT=3 landing_protected_paths_hit acme/widgets 12)"; rc=$?
assert_eq "a listing at the page cap reads unreadable (exit 2), never trusted as complete" "2" "$rc"
files "src/app.py"

out="$(landing_protected_paths_hit "" 12)"; rc=$?
assert_eq "an empty slug is rejected before calling gh" "2" "$rc"
out="$(landing_protected_paths_hit acme/widgets abc)"; rc=$?
assert_eq "a non-numeric number is rejected before calling gh" "2" "$rc"

# --- landing_eligible ---------------------------------------------------------

files "src/app.py"
base_cfg='{}'

out="$(landing_eligible "$base_cfg" acme/widgets 12 medium tech-debt human)"
assert_eq "level human: ineligible, no gh call needed" \
  "ineligible:merge_autonomy effective level is human, not agent-merges-routine or agent-merges-all" "$out"

out="$(landing_eligible "$base_cfg" acme/widgets 12 medium tech-debt agent-approves)"
assert_eq "level agent-approves: still ineligible" \
  "ineligible:merge_autonomy effective level is agent-approves, not agent-merges-routine or agent-merges-all" "$out"

out="$(landing_eligible "$base_cfg" acme/widgets 12 high tech-debt agent-merges-routine)"
assert_eq "complexity:high is always ineligible, regardless of source or path" \
  "ineligible:complexity is high, not low or medium" "$out"

out="$(landing_eligible "$base_cfg" acme/widgets 12 medium issues agent-merges-routine)"
assert_eq "a source outside the default routine list (register-hygiene, tech-debt) is ineligible" \
  'ineligible:source issues is not in acme/widgets'\''s configured routine list ["register-hygiene","tech-debt"]' "$out"

out="$(landing_eligible "$base_cfg" acme/widgets 12 medium "" agent-merges-routine)"
assert_eq "an empty source is ineligible, never eligible by omission" \
  'ineligible:source empty is not in acme/widgets'\''s configured routine list ["register-hygiene","tech-debt"]' "$out"

out="$(landing_eligible "$base_cfg" acme/widgets 12 low tech-debt agent-merges-routine)"
assert_eq "complexity:low, a routine source, no protected path: eligible" "eligible" "$out"

out="$(landing_eligible "$base_cfg" acme/widgets 12 medium register-hygiene agent-merges-all)"
assert_eq "agent-merges-all is eligible too, on the same terms" "eligible" "$out"

files "lib/x.sh"
out="$(landing_eligible "$base_cfg" acme/widgets 12 medium tech-debt agent-merges-routine)"
assert_eq "a protected path is ineligible, naming the path" \
  "ineligible:touches protected path(s): lib/x.sh" "$out"
files "src/app.py"

: > "$fixtures/files-fail"
out="$(landing_eligible "$base_cfg" acme/widgets 12 medium tech-debt agent-merges-routine)"
assert_eq "an unreadable changed-file list is unknown, never a pass" \
  "unknown:could not establish acme/widgets#12's changed-file list" "$out"
rm -f "$fixtures/files-fail"

override_cfg='{"repos":[{"slug":"acme/widgets","merge_autonomy_routine_sources":["register-hygiene"]}],"merge_autonomy_routine_sources":["tech-debt","register-hygiene"]}'
out="$(landing_eligible "$override_cfg" acme/widgets 12 medium tech-debt agent-merges-routine)"
assert_eq "a repo-level override wins over the top-level list" \
  'ineligible:source tech-debt is not in acme/widgets'\''s configured routine list ["register-hygiene"]' "$out"
out="$(landing_eligible "$override_cfg" acme/gizmos 12 medium tech-debt agent-merges-routine)"
assert_eq "a repo with no override of its own falls through to the top-level list" "eligible" "$out"

# The subtlety this file's own header documents: SOURCE is compared as a
# plain string, never expanded against the four issues:<band> ranks. A real
# issues work order's own .source is always the plain word "issues"
# (scripts/gather-issues.sh) — an issues:low entry in the routine list can
# never match it.
banded_cfg='{"merge_autonomy_routine_sources":["issues:low","tech-debt"]}'
out="$(landing_eligible "$banded_cfg" acme/widgets 12 medium issues agent-merges-routine)"
assert_eq "an issues:low routine entry never matches the plain word 'issues' a real work order carries" \
  'ineligible:source issues is not in acme/widgets'\''s configured routine list ["issues:low","tech-debt"]' "$out"
out="$(landing_eligible "$banded_cfg" acme/widgets 12 medium "issues:low" agent-merges-routine)"
assert_eq "...but the literal banded string does match, confirming the comparison is exact-string, not banded" \
  "eligible" "$out"

# --- landing_approver_standing_review ----------------------------------------
# The fresh GitHub read that catches a review agent-cycle.sh's own in-process
# verdict believes was posted but GitHub itself never actually recorded
# (approver_post_or_warn always returns 0, even on a failed write).

set_reviews <<REVIEWS
$(review "pullwright-approver[bot]" APPROVED "2026-08-17T10:00:00Z")
REVIEWS
out="$(landing_approver_standing_review acme/widgets 12 "pullwright-approver[bot]")"; rc=$?
assert_eq "a standing APPROVED review reads APPROVED" "APPROVED" "$out"
assert_eq "  ... exit 0" "0" "$rc"

set_reviews <<REVIEWS
$(review "pullwright-approver[bot]" APPROVED "2026-08-17T10:00:00Z")
$(review "pullwright-approver[bot]" CHANGES_REQUESTED "2026-08-17T11:00:00Z")
REVIEWS
out="$(landing_approver_standing_review acme/widgets 12 "pullwright-approver[bot]")"
assert_eq "the most recent standing review wins over an earlier approval" "CHANGES_REQUESTED" "$out"

set_reviews <<REVIEWS
$(review "pullwright-approver[bot]" CHANGES_REQUESTED "2026-08-17T09:00:00Z")
$(review "pullwright-approver[bot]" COMMENTED "2026-08-17T12:00:00Z")
REVIEWS
out="$(landing_approver_standing_review acme/widgets 12 "pullwright-approver[bot]")"
assert_eq "a later COMMENTED review does not change the standing position" "CHANGES_REQUESTED" "$out"

set_reviews <<REVIEWS
$(review "a-human" APPROVED "2026-08-17T10:00:00Z")
REVIEWS
out="$(landing_approver_standing_review acme/widgets 12 "pullwright-approver[bot]")"
assert_eq "a different login's approval is not this login's standing review" "" "$out"

set_reviews <<REVIEWS
$(review "pullwright-approver[bot]" APPROVED "2026-08-17T10:00:00Z")
REVIEWS
: > "$fixtures/reviews-fail"
out="$(landing_approver_standing_review acme/widgets 12 "pullwright-approver[bot]")"; rc=$?
assert_eq "an unreadable reviews list: non-zero, nothing printed — never read as \"not approved\"" "1" "$rc"
assert_eq "  ... nothing printed" "" "$out"
rm -f "$fixtures/reviews-fail"

out="$(landing_approver_standing_review "" 12 "pullwright-approver[bot]")"; rc=$?
assert_eq "an empty slug is rejected before calling gh" "1" "$rc"
out="$(landing_approver_standing_review acme/widgets 12 "")"; rc=$?
assert_eq "an empty login is rejected before calling gh" "1" "$rc"

# --- landing_arm ---------------------------------------------------------------

: > "$enqueue_calls"; : > "$merge_calls"
queue '{"id":"MQ_fake","mergeMethod":"SQUASH","mergingStrategy":"ALLGREEN"}'
out="$(landing_arm acme/widgets 12 a-minted-token)"; rc=$?
assert_eq "a base branch with a merge queue: enqueues" "enqueued" "$out"
assert_eq "  ... exit 0" "0" "$rc"
assert_eq "  ... GH_TOKEN carried the minted token for that one call" "a-minted-token" "$(cat "$enqueue_calls")"
assert_eq "  ... and gh pr merge was never called" "" "$(cat "$merge_calls")"

: > "$enqueue_calls"; : > "$merge_calls"
queue 'null'
out="$(landing_arm acme/widgets 12 a-minted-token)"; rc=$?
assert_eq "no merge queue: falls back to gh pr merge --auto --squash" "auto-merge" "$out"
assert_eq "  ... exit 0" "0" "$rc"
assert_eq "  ... GH_TOKEN carried the minted token for that call" "a-minted-token" "$(cat "$merge_calls")"
assert_eq "  ... and enqueuePullRequest was never called" "" "$(cat "$enqueue_calls")"

: > "$fixtures/pr-fail"
out="$(landing_arm acme/widgets 12 a-token)"; rc=$?
assert_eq "an unreadable pull request (node id / base): non-zero, nothing printed" "1" "$rc"
assert_eq "  ... nothing printed" "" "$out"
rm -f "$fixtures/pr-fail"

: > "$fixtures/queue-fail"
out="$(landing_arm acme/widgets 12 a-token)"; rc=$?
assert_eq "an unreadable merge-queue probe: non-zero, nothing printed" "1" "$rc"
rm -f "$fixtures/queue-fail"

queue '{"id":"MQ_fake"}'
: > "$fixtures/enqueue-fail"
out="$(landing_arm acme/widgets 12 a-token)"; rc=$?
assert_eq "a refused enqueue mutation: non-zero, nothing printed" "1" "$rc"
rm -f "$fixtures/enqueue-fail"

# A mutation that succeeds at the transport level but carries no merge-queue
# entry: `--jq` prints the word `null`, which must never be read as a queue
# entry the way a non-empty string otherwise would.
queue '{"id":"MQ_fake"}'
echo '{"data":{"enqueuePullRequest":{"mergeQueueEntry":null}}}' > "$fixtures/enqueue-response.json"
out="$(landing_arm acme/widgets 12 a-token)"; rc=$?
assert_eq "an enqueue that returned no merge-queue entry: non-zero" "1" "$rc"
assert_eq "  ... nothing printed — never a landing-armed naming a queue entry that does not exist" "" "$out"
echo '{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"id":"MQE_fake"}}}}' > "$fixtures/enqueue-response.json"

queue 'null'
: > "$fixtures/merge-fail"
out="$(landing_arm acme/widgets 12 a-token)"; rc=$?
assert_eq "a refused gh pr merge: non-zero, nothing printed" "1" "$rc"
rm -f "$fixtures/merge-fail"

out="$(landing_arm "" 12 a-token)"; rc=$?
assert_eq "an empty slug is rejected before calling gh" "1" "$rc"
out="$(landing_arm acme/widgets abc a-token)"; rc=$?
assert_eq "a non-numeric number is rejected before calling gh" "1" "$rc"
out="$(landing_arm acme/widgets 12 "")"; rc=$?
assert_eq "an empty token is rejected before calling gh" "1" "$rc"

echo
if (( failures == 0 )); then
  echo "All landing assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
