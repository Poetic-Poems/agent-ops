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
#     or truncated changed-file listing exits 2 (never a pass), a
#     protected-paths list holding a non-string entry also exits 2 rather
#     than reading as "no match" (TD-PPagop-26082320), bad arguments are
#     rejected before any gh call, and the read reaches GitHub as an
#     explicit GET (agent-ops#718 — the stubbed `gh` models `gh api`'s own
#     method selection, so a field-carrying request that forgets
#     `--method GET` 404s here exactly as it did in production).
#   - landing_eligible: LEVEL below agent-merges-routine, COMPLEXITY above
#     medium, and a SOURCE outside the routine list are each `ineligible`
#     with no gh call at all; a repo-level merge_autonomy_routine_sources
#     override widens what that one repository accepts; a protected path
#     is `ineligible`; an unreadable changed-file list, or a protected-paths
#     list that cannot be evaluated at all (TD-PPagop-26082320), is
#     `unknown`, never a pass; the plain-string SOURCE comparison this
#     file's own header documents is pinned directly — a plain `issues`
#     entry in the routine list matches the word a real issues work order
#     always carries, and an `issues:low` entry (a schema error since
#     agent-ops#558) still does not, because the comparison folds no bands.
#   - landing_arm: a base branch with an active merge queue enqueues via
#     the enqueuePullRequest mutation; one without falls back to
#     `gh pr merge --auto --squash`; both write under GH_TOKEN for that one
#     invocation only; an unreadable pull request, an unreadable queue
#     probe, a refused mutation or a refused merge each return non-zero
#     printing nothing, each with its own distinguishable exit status
#     (agent-ops#532); bad arguments are rejected before any gh call.
#     `_landing_arm_failure_reason` is pinned directly for every code it maps.
#   - landing_retry_source (TD-PPagop-26081701): the most recent matching
#     `selection` event's source wins when a branch was claimed more than
#     once, a malformed log line is skipped rather than aborting the read,
#     an unmatched repo/branch or an unreadable log both print nothing, and
#     stdin works the same as a named LOG_FILE.
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

# --- Which method would the real `gh api` use, and against which path? -------
# Modelled rather than assumed, because the one time these differed cost five
# days of held-shut arming (agent-ops#718): `gh api` sends a request carrying
# `-f`/`-F` fields as a **POST** unless `--method`/`-X` says otherwise, and a
# POST to a read-only REST path is a 404, not a listing. A stub that dispatches
# on the path shape alone models the endpoint but not that rule, so it answers
# happily to a call the real `gh` refuses. `api_path` is the first operand that
# is not a flag or a flag's value — the same thing the real one treats as the
# endpoint.
api_method="" api_fields=0 api_path=""
if [[ "${args[0]:-}" == "api" ]]; then
  _i=1
  while (( _i < ${#args[@]} )); do
    case "${args[$_i]}" in
      --method|-X)         _i=$((_i+1)); api_method="${args[$_i]:-}" ;;
      -f|-F|--field|--raw-field) _i=$((_i+1)); api_fields=1 ;;
      --jq|-q|--template|-t|--hostname|-H|--header) _i=$((_i+1)) ;;
      -*)                  : ;;
      *)                   [[ -n "$api_path" ]] || api_path="${args[$_i]}" ;;
    esac
    _i=$((_i+1))
  done
  if [[ -z "$api_method" ]]; then
    if (( api_fields )); then api_method="POST"; else api_method="GET"; fi
  fi
fi

# --- gh api --method GET repos/SLUG/pulls/NUMBER/files --paginate -F per_page=100 --jq ... ---
if [[ "${args[0]:-}" == "api" && "$api_path" == repos/*/pulls/*/files ]]; then
  if [[ "$api_method" != "GET" ]]; then
    # Verbatim shape of what the real `gh` prints for this mistake.
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
  [[ -f "$f/files-fail" ]] && exit 1
  cat "$f/files.txt" 2>/dev/null
  exit 0
fi

# --- gh api repos/SLUG/pulls/NUMBER/reviews --paginate --jq ... ---
if [[ "${args[0]:-}" == "api" && "$api_path" == repos/*/pulls/*/reviews ]]; then
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
if [[ "${args[0]:-}" == "api" && "$api_path" == repos/*/pulls/* \
      && "$api_path" != */files && "$api_path" != */reviews ]]; then
  [[ -f "$f/pr-fail" ]] && exit 1
  cat "$f/pr.json" 2>/dev/null
  exit 0
fi

# --- gh api graphql ... (merge_queue_for_branch's read, or landing_arm's
#     enqueuePullRequest write) — distinguished by the query text, since
#     both reach this same sub-command. ---
if [[ "${args[0]:-}" == "api" && "$api_path" == "graphql" ]]; then
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

# --- gh pr view NUMBER -R SLUG --json headRefOid --jq '.headRefOid' ---
# (landing_protected_path_controls_ok's own fresh read of the pull request's
# current head, checked against the standing review's commit_id)
if [[ "${args[0]:-}" == "pr" && "${args[1]:-}" == "view" ]]; then
  [[ -f "$f/pr-head-fail" ]] && exit 1
  cat "$f/pr-head-sha.txt" 2>/dev/null
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
head_sha() { printf '%s' "$1" > "$fixtures/pr-head-sha.txt"; }  # the PR's current headRefOid
queue() {  # queue null|OBJECT — the raw mergeQueue value, wrapped as the
           # GraphQL envelope merge_queue_for_branch's own --jq filter
           # (.data.repository.mergeQueue) expects.
  jq -nc --argjson mq "$1" '{data:{repository:{mergeQueue: $mq}}}' > "$fixtures/queue-response.json"
}
review() {  # review LOGIN STATE AT [COMMIT]
  jq -nc --arg l "$1" --arg s "$2" --arg at "$3" --arg c "${4:-}" \
    '{user: {login: $l}, submitted_at: $at, state: $s, commit_id: (if $c == "" then null else $c end)}'
}
set_reviews() { jq -sc '.' > "$fixtures/reviews.json"; }  # one `review …` per stdin line

prd "PR_kwDOfake" "main"
head_sha "sha-head-1"
queue null
echo '{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"id":"MQE_fake"}}}}' > "$fixtures/enqueue-response.json"

# --- landing_protected_paths_hit ---------------------------------------------

files "src/app.py" "lib/merge-budget.sh" "README.md"
out="$(landing_protected_paths_hit '{}' acme/widgets 12)"; rc=$?
assert_eq "a protected path is reported" "lib/merge-budget.sh" "$out"
assert_eq "  ... exit 0" "0" "$rc"

files "src/app.py" "README.md" "docs/notes.md"
out="$(landing_protected_paths_hit '{}' acme/widgets 12)"; rc=$?
assert_eq "no protected path: nothing printed" "" "$out"
assert_eq "  ... exit 1" "1" "$rc"

files "config.schema.json" "CODEOWNERS" "lib/x.sh" ".github/workflows/y.yml" "deploy/z" "prompts/p.md" \
      "config.json" "agent-cycle.sh" "review-cycle.sh"
out="$(landing_protected_paths_hit '{}' acme/widgets 12)"; rc=$?
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
  out="$(landing_protected_paths_hit '{}' acme/widgets 12)"; rc=$?
  assert_eq "$protected is protected" "$protected" "$out"
  assert_eq "  ... exit 0" "0" "$rc"
done

# Anchored, not a prefix match: the classifier must not catch a same-named
# file nested under a directory, nor a longer name that merely starts the
# same way.
files "src/app.py" "docs/config.json" "tools/agent-cycle.sh" "config.json.bak" "review-cycle.sh.orig"
out="$(landing_protected_paths_hit '{}' acme/widgets 12)"; rc=$?
assert_eq "a nested or suffixed near-miss is not protected" "" "$out"
assert_eq "  ... exit 1" "1" "$rc"

: > "$fixtures/files-fail"
out="$(landing_protected_paths_hit '{}' acme/widgets 12)"; rc=$?
assert_eq "an unreadable changed-file list: exit 2, nothing printed" "2" "$rc"
assert_eq "  ... nothing printed" "" "$out"
rm -f "$fixtures/files-fail"

files a b c
out="$(LANDING_PR_FILES_LIMIT=3 landing_protected_paths_hit '{}' acme/widgets 12)"; rc=$?
assert_eq "a listing at the page cap reads unreadable (exit 2), never trusted as complete" "2" "$rc"
files "src/app.py"

out="$(landing_protected_paths_hit '{}' "" 12)"; rc=$?
assert_eq "an empty slug is rejected before calling gh" "2" "$rc"
out="$(landing_protected_paths_hit '{}' acme/widgets abc)"; rc=$?
assert_eq "a non-numeric number is rejected before calling gh" "2" "$rc"

# The read must be an explicit GET (agent-ops#718). Two assertions, because
# either alone rots: the first pins that the stub really does refuse a
# field-carrying request that is not one — otherwise the guard could be
# deleted and nothing would notice — and the second pins that the caller
# sends one, which is the regression itself. Before the fix the second
# assertion failed with exactly the `unknown` refusal the fleet logged 72
# times.
files "src/app.py"
out="$("$stub_bin/gh" api "repos/acme/widgets/pulls/12/files" --paginate -F per_page=100 \
  --jq '.[].filename' 2>&1)"; rc=$?
assert_eq "the stub refuses a field-carrying request that is not an explicit GET" "1" "$rc"
assert_contains "  ... reporting it the way the real gh does" "HTTP 404" "$out"

out="$(landing_protected_paths_hit '{}' acme/widgets 12)"; rc=$?
assert_eq "the changed-file read is sent as a GET, so an ordinary listing is readable" "1" "$rc"

# D18 Stage 3 (agent-ops#724): merge_autonomy_protected_paths is per
# repository, on the same repo-override-else-top-level-else-default
# precedence merge_autonomy_routine_sources already uses. Nothing above
# changes without an override, since every call above resolved the default
# from an empty config.
override_cfg='{"repos":[{"slug":"acme/widgets","merge_autonomy_protected_paths":["scripts/*"]}],"merge_autonomy_protected_paths":["lib/*"]}'
files "src/app.py" "lib/x.sh" "scripts/y.sh"
out="$(landing_protected_paths_hit "$override_cfg" acme/widgets 12)"; rc=$?
assert_eq "a repo-level protected-paths override wins over the top-level list" "scripts/y.sh" "$out"
assert_eq "  ... exit 0" "0" "$rc"
out="$(landing_protected_paths_hit "$override_cfg" acme/gizmos 12)"; rc=$?
assert_eq "a repo with no override of its own falls through to the top-level list" "lib/x.sh" "$out"
assert_eq "  ... exit 0" "0" "$rc"
files "src/app.py"

# TD-PPagop-26082320: a protected-paths list holding a non-string entry makes
# _landing_is_protected's own jq program raise (jq -e exit 5) rather than
# simply return false, for every changed path checked against it. Before the
# fix that read as "no protected path touched" (exit 1) — a fail-open on the
# gate the header calls "the deadliest landing class"; now it must read as
# "could not be established" (exit 2), the same refusal an unreadable
# changed-file list already gets, never a silent pass. Not reachable through
# a schema-validated config.json (config.schema.json's own `items` are
# constrained to non-empty strings) — this pins the helper's own contract
# directly, independent of that guard.
malformed_cfg='{"merge_autonomy_protected_paths":[123,"lib/*"]}'
files "lib/x.sh"
out="$(landing_protected_paths_hit "$malformed_cfg" acme/widgets 12)"; rc=$?
assert_eq "a non-string entry in the protected-paths list: exit 2, never a silent 'no match'" "2" "$rc"
assert_eq "  ... and nothing printed" "" "$out"

files "src/app.py"
out="$(landing_protected_paths_hit "$malformed_cfg" acme/widgets 12)"; rc=$?
assert_eq "  ... exit 2 even when no changed path would otherwise have matched" "2" "$rc"
files "src/app.py"

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

# D18 WI-12 (agent-ops#415): at agent-merges-all, and only there, a protected
# path is deferred to `eligible` rather than refused outright — the
# compensating controls (critical tier, cool-off) are
# `landing_protected_path_controls_ok`'s job, which needs facts (the
# standing review's own tier and timestamp) this function is never handed.
out="$(landing_eligible "$base_cfg" acme/widgets 12 medium tech-debt agent-merges-all)"
assert_eq "a protected path at agent-merges-all is eligible, deferred to the compensating-control gate" \
  "eligible" "$out"
files "src/app.py"

: > "$fixtures/files-fail"
out="$(landing_eligible "$base_cfg" acme/widgets 12 medium tech-debt agent-merges-routine)"
assert_eq "an unreadable changed-file list is unknown, never a pass" \
  "unknown:could not establish acme/widgets#12's changed-file list" "$out"
rm -f "$fixtures/files-fail"

# TD-PPagop-26082320: landing_protected_paths_hit's own exit 2 for a
# protected-paths list it cannot evaluate at all must read as `unknown` here
# too — the same refusal an unreadable changed-file list gets, never
# `eligible` by the classifier's own vocabulary silently going quiet on a
# malformed merge_autonomy_protected_paths.
malformed_cfg='{"merge_autonomy_protected_paths":[123,"lib/*"]}'
out="$(landing_eligible "$malformed_cfg" acme/widgets 12 medium tech-debt agent-merges-routine)"
assert_eq "a non-string entry in the protected-paths list is unknown, never eligible" \
  "unknown:could not establish acme/widgets#12's changed-file list" "$out"

override_cfg='{"repos":[{"slug":"acme/widgets","merge_autonomy_routine_sources":["register-hygiene"]}],"merge_autonomy_routine_sources":["tech-debt","register-hygiene"]}'
out="$(landing_eligible "$override_cfg" acme/widgets 12 medium tech-debt agent-merges-routine)"
assert_eq "a repo-level override wins over the top-level list" \
  'ineligible:source tech-debt is not in acme/widgets'\''s configured routine list ["register-hygiene"]' "$out"
out="$(landing_eligible "$override_cfg" acme/gizmos 12 medium tech-debt agent-merges-routine)"
assert_eq "a repo with no override of its own falls through to the top-level list" "eligible" "$out"

# The subtlety this file's own header documents: SOURCE is compared as a
# plain string, never expanded against the four issues:<band> ranks. A real
# issues work order's own .source is always the plain word "issues"
# (scripts/gather-issues.sh), so `issues` is the spelling that arms one —
# which is why the schema's landingSourceToken offers that and not the bands
# (agent-ops#558).
plain_cfg='{"merge_autonomy_routine_sources":["issues","tech-debt"]}'
out="$(landing_eligible "$plain_cfg" acme/widgets 12 medium issues agent-merges-routine)"
assert_eq "a plain 'issues' routine entry matches the source a real issues work order carries" \
  "eligible" "$out"

# The comparison is still exact-string, not band-folding — pinned because the
# #558 fix deliberately changed the config vocabulary and left this alone. A
# banded entry is a schema error at load; were one to reach here anyway it
# must still not match, rather than being quietly widened by this file.
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

# --- landing_approver_standing_review_at (D18 WI-12, agent-ops#415) ---------
# The same answer, plus the standing review's own submitted_at and
# commit_id — the timestamp the protected-path cool-off is measured from,
# and the commit landing_protected_path_controls_ok checks against the pull
# request's current head to detect a push after approval, both at no extra
# gh call (the same reviews-list read either function makes).

set_reviews <<REVIEWS
$(review "pullwright-approver[bot]" APPROVED "2026-08-17T10:00:00Z" "sha-head-1")
REVIEWS
out="$(landing_approver_standing_review_at acme/widgets 12 "pullwright-approver[bot]")"; rc=$?
assert_eq "a standing APPROVED review carries its own submitted_at and commit_id" \
  "APPROVED	2026-08-17T10:00:00Z	sha-head-1" "$out"
assert_eq "  ... exit 0" "0" "$rc"

set_reviews <<REVIEWS
$(review "a-human" APPROVED "2026-08-17T10:00:00Z" "sha-head-1")
REVIEWS
out="$(landing_approver_standing_review_at acme/widgets 12 "pullwright-approver[bot]")"
assert_eq "no standing review for this login: empty state, empty at, empty commit" "		" "$out"

set_reviews <<REVIEWS
$(review "pullwright-approver[bot]" APPROVED "2026-08-17T10:00:00Z" "sha-head-1")
REVIEWS
: > "$fixtures/reviews-fail"
out="$(landing_approver_standing_review_at acme/widgets 12 "pullwright-approver[bot]")"; rc=$?
assert_eq "an unreadable reviews list: non-zero, nothing printed" "1" "$rc"
assert_eq "  ... nothing printed" "" "$out"
rm -f "$fixtures/reviews-fail"

# --- landing_cool_off_effective_hours (D18 WI-12) ----------------------------

out="$(landing_cool_off_effective_hours '{}' acme/widgets)"
assert_eq "no config at all: the shipped default, 24" "24" "$out"

out="$(landing_cool_off_effective_hours '{"landing_cool_off_hours": 6}' acme/widgets)"
assert_eq "a top-level override wins over the shipped default" "6" "$out"

out="$(landing_cool_off_effective_hours \
  '{"landing_cool_off_hours": 6, "repos":[{"slug":"acme/widgets","landing_cool_off_hours": 0}]}' \
  acme/widgets)"
assert_eq "a repo-level override wins over the top-level key, and 0 means no wait, not unset" \
  "0" "$out"

out="$(landing_cool_off_effective_hours \
  '{"landing_cool_off_hours": 6, "repos":[{"slug":"acme/widgets","landing_cool_off_hours": 0}]}' \
  acme/gizmos)"
assert_eq "a repo with no override of its own falls through to the top-level key" "6" "$out"

out="$(landing_cool_off_effective_hours '{"landing_cool_off_hours": "not-a-number"}' acme/widgets)"
assert_eq "a malformed value falls through to the shipped default" "24" "$out"

# --- landing_cool_off_remaining_hours (D18 WI-12) ----------------------------

out="$(landing_cool_off_remaining_hours "2026-08-17T10:00:00Z" 24 "2026-08-17T12:48:00Z")"
assert_eq "2h48m into a 24h cool-off: 21.2h remaining" "21.2" "$out"

out="$(landing_cool_off_remaining_hours "2026-08-17T10:00:00Z" 24 "2026-08-18T10:00:00Z")"
assert_eq "24h elapsed exactly: 0, not negative" "0" "$out"

out="$(landing_cool_off_remaining_hours "2026-08-17T10:00:00Z" 24 "2026-08-19T10:00:00Z")"
assert_eq "well past the window: clamped to 0, never negative" "0" "$out"

out="$(landing_cool_off_remaining_hours "2026-08-17T10:00:00Z" 0 "2026-08-17T10:00:01Z")"
assert_eq "landing_cool_off_hours: 0 disables the wait" "0" "$out"

out="$(landing_cool_off_remaining_hours "not-a-timestamp" 24 "2026-08-17T12:00:00Z")"
assert_eq "an unparseable submitted_at: empty, never a pass" "" "$out"

out="$(landing_cool_off_remaining_hours "2026-08-17T10:00:00Z" "not-a-number" "2026-08-17T12:00:00Z")"
assert_eq "a non-numeric cool-off duration: empty, never a pass" "" "$out"

# --- landing_protected_path_controls_ok (D18 WI-12) --------------------------
# Fixture head_sha "sha-head-1" (set above) is the pull request's current
# headRefOid throughout; REVIEW_COMMIT matching it is what lets the cool-off
# checks below run at all.

files "src/app.py"
out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 critical "2026-08-17T10:00:00Z" "sha-head-1")"
assert_eq "no protected path at all: ok immediately, neither control consulted" "ok" "$out"

files "lib/x.sh"
out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 standard "2026-08-17T10:00:00Z" "sha-head-1" \
  "2026-08-17T11:00:00Z")"
assert_contains "a non-critical tier is refused, naming the tier it actually found" \
  "did not run at the critical tier (tier: standard)" "$out"

out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 "" "2026-08-17T10:00:00Z" "sha-head-1" \
  "2026-08-17T11:00:00Z")"
assert_contains "an empty tier is refused the same way, naming it empty" \
  "tier: empty" "$out"

out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 critical "" "sha-head-1" "2026-08-17T11:00:00Z")"
assert_contains "a critical tier but no submitted_at: refused, naming the missing timestamp" \
  "no approval timestamp could be established" "$out"

out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 critical "2026-08-17T10:00:00Z" "sha-head-1" \
  "2026-08-17T11:00:00Z")"
assert_contains "critical tier, commit matches head, cool-off still open: refused, naming the remaining time" \
  "cool-off has 23h remaining" "$out"

out="$(landing_protected_path_controls_ok '{"landing_cool_off_hours": 0}' acme/widgets 12 critical \
  "2026-08-17T10:00:00Z" "sha-head-1" "2026-08-17T11:00:00Z")"
assert_eq "critical tier, commit matches head, landing_cool_off_hours: 0: ok immediately" "ok" "$out"

out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 critical "2026-08-17T10:00:00Z" "sha-head-1" \
  "2026-08-18T10:00:00Z")"
assert_eq "critical tier, commit matches head, a full day elapsed: ok" "ok" "$out"

# A push after approval (agent-ops#658 review): the standing review's own
# commit_id no longer matches the pull request's current head, so the
# cool-off is never even consulted — refused outright, naming both commits,
# regardless of how much time has elapsed since the stale submitted_at.
out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 critical "2026-08-17T10:00:00Z" "sha-stale" \
  "2026-08-18T10:00:00Z")"
assert_contains "a push after approval refuses even past a full day elapsed, naming the mismatch" \
  "the standing review approved commit sha-stale, but acme/widgets#12's current head is sha-head-1" "$out"
assert_contains "  ... names it a restart of the cool-off" \
  "restarts the protected-path cool-off" "$out"

out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 critical "2026-08-17T10:00:00Z" "" \
  "2026-08-17T11:00:00Z")"
assert_contains "an empty review commit is refused the same way, naming it empty" \
  "approved commit empty" "$out"

: > "$fixtures/pr-head-fail"
out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 critical "2026-08-17T10:00:00Z" "sha-head-1")"
assert_contains "an unreadable current-head read: unknown, never a pass" \
  "unknown:could not re-establish acme/widgets#12's current head commit" "$out"
rm -f "$fixtures/pr-head-fail"

: > "$fixtures/files-fail"
out="$(landing_protected_path_controls_ok '{}' acme/widgets 12 critical "2026-08-17T10:00:00Z" "sha-head-1")"
assert_contains "an unreadable changed-file list on re-check: unknown, never a pass" \
  "unknown:could not re-establish" "$out"
rm -f "$fixtures/files-fail"
files "src/app.py"

# --- landing_retry_tier (D18 WI-12, agent-ops#415) ---------------------------
# The fleet's own union log stands in for `run_approver_stage`'s in-process
# `approver_stage_tier` on a re-arm, exactly as `landing_retry_source` already
# does for a work order's `source` — pinned against a hand-built log.

tier_log="$tmp_dir/tier-union-log.jsonl"
cat > "$tier_log" <<'LOG'
{"ts":"2026-08-17T09:00:00Z","event":"approver-verdict","pr_url":"https://github.com/acme/widgets/pull/12","tier":"standard","verdict":"refuse","refuse_streak":0,"adjudication":false}
this line is not json at all
{"ts":"2026-08-17T10:00:00Z","event":"approver-verdict","pr_url":"https://github.com/acme/widgets/pull/12","tier":"critical","verdict":"approve","refuse_streak":0,"adjudication":false,"critical_reason":"protected-path"}
{"ts":"2026-08-17T09:30:00Z","event":"landing-refused","pr_url":"https://github.com/acme/widgets/pull/12","repo":"acme/widgets","reason":"a human CHANGES_REQUESTED stands (someone)"}
LOG

out="$(landing_retry_tier "https://github.com/acme/widgets/pull/12" "$tier_log")"
assert_eq "the most recent matching approver-verdict's tier wins" "critical" "$out"

out="$(landing_retry_tier "https://github.com/acme/widgets/pull/999" "$tier_log")"
assert_eq "an unmatched pull request prints nothing" "" "$out"

out="$(landing_retry_tier "https://github.com/acme/widgets/pull/12" "$tmp_dir/does-not-exist.jsonl")"
assert_eq "an unreadable log prints nothing rather than guessing" "" "$out"

out="$(landing_retry_tier "https://github.com/acme/widgets/pull/12" < "$tier_log")"
assert_eq "stdin works the same as a named file (LOG_FILE omitted/-)" "critical" "$out"

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
assert_eq "an unreadable pull request (node id / base): non-zero, nothing printed" "2" "$rc"
assert_eq "  ... nothing printed" "" "$out"
rm -f "$fixtures/pr-fail"

: > "$fixtures/queue-fail"
out="$(landing_arm acme/widgets 12 a-token)"; rc=$?
assert_eq "an unreadable merge-queue probe: non-zero, nothing printed" "4" "$rc"
rm -f "$fixtures/queue-fail"

queue '{"id":"MQ_fake"}'
: > "$fixtures/enqueue-fail"
out="$(landing_arm acme/widgets 12 a-token)"; rc=$?
assert_eq "a refused enqueue mutation: non-zero, nothing printed" "5" "$rc"
rm -f "$fixtures/enqueue-fail"

# A mutation that succeeds at the transport level but carries no merge-queue
# entry: `--jq` prints the word `null`, which must never be read as a queue
# entry the way a non-empty string otherwise would.
queue '{"id":"MQ_fake"}'
echo '{"data":{"enqueuePullRequest":{"mergeQueueEntry":null}}}' > "$fixtures/enqueue-response.json"
out="$(landing_arm acme/widgets 12 a-token)"; rc=$?
assert_eq "an enqueue that returned no merge-queue entry: non-zero" "6" "$rc"
assert_eq "  ... nothing printed — never a landing-armed naming a queue entry that does not exist" "" "$out"
echo '{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"id":"MQE_fake"}}}}' > "$fixtures/enqueue-response.json"

queue 'null'
: > "$fixtures/merge-fail"
out="$(landing_arm acme/widgets 12 a-token)"; rc=$?
assert_eq "a refused gh pr merge: non-zero, nothing printed" "7" "$rc"
rm -f "$fixtures/merge-fail"

out="$(landing_arm "" 12 a-token)"; rc=$?
assert_eq "an empty slug is rejected before calling gh" "1" "$rc"
out="$(landing_arm acme/widgets abc a-token)"; rc=$?
assert_eq "a non-numeric number is rejected before calling gh" "1" "$rc"
out="$(landing_arm acme/widgets 12 "")"; rc=$?
assert_eq "an empty token is rejected before calling gh" "1" "$rc"

# --- _landing_arm_failure_reason (agent-ops#532) -----------------------------
# Pinned directly so the mapping cannot drift from landing_arm's own return
# statements without a test noticing — one assertion per documented code,
# plus the unrecognised-code fallback.
assert_eq "code 1 names bad arguments" \
  "bad arguments (missing slug, pull request number or token)" "$(_landing_arm_failure_reason 1)"
assert_eq "code 2 names the unreadable pull request read" \
  "could not read the pull request's own node id and base branch" "$(_landing_arm_failure_reason 2)"
assert_eq "code 3 names the missing node id / base branch" \
  "the pull request read reported no node id or no base branch" "$(_landing_arm_failure_reason 3)"
assert_eq "code 4 names the unreadable merge-queue state" \
  "could not read the base branch's merge-queue state" "$(_landing_arm_failure_reason 4)"
assert_eq "code 5 names the failed enqueue mutation" \
  "the enqueue mutation itself failed" "$(_landing_arm_failure_reason 5)"
assert_eq "code 6 names the partial enqueue write" \
  "the enqueue mutation reported no merge-queue entry (a partial write)" "$(_landing_arm_failure_reason 6)"
assert_eq "code 7 names the failed gh pr merge" \
  "gh pr merge --auto --squash failed" "$(_landing_arm_failure_reason 7)"
assert_eq "an unrecognised code still names itself rather than nothing" \
  "exited 99" "$(_landing_arm_failure_reason 99)"

# --- landing_retry_source (TD-PPagop-26081701) -------------------------------
# The one gate the 2.1e landing-retry sweep answers from the fleet's own
# union log rather than fresh from GitHub — pinned directly against a
# hand-built log file (LOG_FILE argument, and stdin).

log_file="$tmp_dir/union-log.jsonl"
cat > "$log_file" <<'LOG'
{"ts":"2026-08-10T00:00:00Z","event":"selection","repo":"acme/widgets","item":"TD-1","source":"tech-debt","model":"m","title":"t","branch":"td/TD-1"}
this line is not json at all
{"ts":"2026-08-12T00:00:00Z","event":"landing-refused","repo":"acme/widgets","pr_url":"https://github.com/acme/widgets/pull/1","reason":"a human CHANGES_REQUESTED stands (someone)"}
{"ts":"2026-08-11T00:00:00Z","event":"selection","repo":"acme/widgets","item":"TD-1","source":"tech-debt","model":"m","title":"t","branch":"td/TD-1"}
{"ts":"2026-08-09T23:00:00Z","event":"selection","repo":"acme/widgets","item":"9","source":"issues","model":"m","title":"t2","branch":"agent/9"}
LOG

out="$(landing_retry_source acme/widgets td/TD-1 "$log_file")"
assert_eq "the most recent matching selection's source wins" "tech-debt" "$out"

out="$(landing_retry_source acme/widgets agent/9 "$log_file")"
assert_eq "a different branch resolves independently" "issues" "$out"

out="$(landing_retry_source acme/widgets no/such-branch "$log_file")"
assert_eq "an unmatched repo/branch prints nothing" "" "$out"

out="$(landing_retry_source acme/widgets td/TD-1 "$tmp_dir/does-not-exist.jsonl")"
assert_eq "an unreadable log prints nothing rather than guessing" "" "$out"

out="$(landing_retry_source acme/widgets td/TD-1 < "$log_file")"
assert_eq "stdin works the same as a named file (LOG_FILE omitted/-)" "tech-debt" "$out"

echo
if (( failures == 0 )); then
  echo "All landing assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
