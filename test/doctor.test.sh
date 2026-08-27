#!/usr/bin/env bash
#
# test/doctor.test.sh — the four network- and render-facing checks
# scripts/doctor.sh added on top of test/config-schema.test.sh's coverage of
# its configuration half (docs/IMPLEMENTATION-PIPELINE-SPEC.md component 14):
# write access to every target repository, Claude credentials, the rendered
# crontab, and the `nice` reordering report.
#
# scripts/doctor.sh has no override variable for `gh` or `claude` (unlike
# lib/labels.sh's LABELS_GH) — it calls both by their bare name — so both are
# stubbed by prepending a directory to PATH. These assertions therefore run
# *without* --offline: --offline is what test/config-schema.test.sh already
# covers, and skipping every network-gated check here would leave the checks
# themselves untested. No real network call is possible through `gh` or
# `claude`, because neither ever resolves to anything but the stubs below.
#
# lib/approver-token.sh's live installation-permissions read (D18 Stage 3,
# agent-ops#575) is the one exception: it calls `curl` directly, stubbed the
# same way test/approver-token.test.sh stubs it, through APPROVER_TOKEN_CURL
# — never left to resolve to a real `curl`. Every invocation below also
# explicitly clears PULLWRIGHT_APPROVER_APP_ID/_INSTALLATION_ID/
# _PRIVATE_KEY_PATH (`env -u`) before setting any of its own: a node this
# suite runs on may carry the fleet's own real Approver credentials in its
# environment, and without the clear this check would sign a real JWT and
# call the real GitHub API using them.
#
# The renderer-failure and missing-template cases use the real
# deploy/docker/render-crontab.sh rather than a stub: a config whose
# schedule.excluded_minutes rules out every minute is a genuine failure the
# real renderer already produces, and a missing template is reproduced by
# running a trimmed copy of the repository that omits it — so what is under
# test is doctor.sh's own reaction, not a fabricated substitute for the
# renderer's behaviour.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/doctor.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$SCRIPT_DIR/scripts/doctor.sh"
# shellcheck source=lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"
# The same slug doctor.sh's own ruleset check resolves for itself — derived
# rather than hardcoded, so this suite is not the thing that breaks when this
# checkout's remote (or a built image's stamp) differs from the usual one.
self_repo="$(jq -r '.repo // empty' <<<"$(agent_ops_version "$SCRIPT_DIR")" 2>/dev/null)"
CONFIG="$SCRIPT_DIR/config.json"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- The stubbed gh -------------------------------------------------------
# Four endpoints doctor.sh's new checks reach: `repos/<slug>` (write access +
# archived, this suite's STUB_REPO_JSON piped through the *real* jq — the
# same filter doctor.sh passes to --jq — so what is under test is doctor.sh's
# reaction to gh's shape, not a hand-rolled restatement of it), `repos/<slug>/
# labels`, answered empty so the pre-existing label check neither fails nor
# adds noise this suite has to filter around, and `repos/<slug>/rulesets` +
# `repos/<slug>/rulesets/<id>` (STUB_RULESETS_JSON, STUB_RULESET_DETAIL_JSON —
# the closing-keyword ruleset-drift check, TD-PPagop-26080802). `auth
# status`, `api user` and `--version` are what the rest of doctor.sh's
# GitHub/Toolchain sections call regardless of what this suite is testing.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
case "$1" in
  --version) printf 'gh version 0.0.0 (stub)\n'; exit 0 ;;
  auth)
    [[ "$2" == "status" ]] && exit 0
    exit 1 ;;
  api)
    endpoint="$2"; shift 2
    jq_filter="."
    while (( $# > 0 )); do
      case "$1" in
        --jq) jq_filter="$2"; shift 2 ;;
        --paginate) shift ;;
        *) shift ;;
      esac
    done
    case "$endpoint" in
      rate_limit)
        # The fine-grained-PAT-expiry read (agent-ops#694,
        # token_expiry_header, lib/token-expiry.sh): `--include` dumps raw
        # HTTP headers ahead of the JSON body, exactly as the real `gh`
        # does. STUB_TOKEN_EXPIRY_HEADER unset reproduces a classic PAT (no
        # such header at all); STUB_RATE_LIMIT_FAIL=1 reproduces a call that
        # cannot be read.
        [[ "${STUB_RATE_LIMIT_FAIL:-0}" != "1" ]] || exit 1
        printf 'HTTP/2.0 200 OK\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        if [[ -n "${STUB_TOKEN_EXPIRY_HEADER:-}" ]]; then
          printf 'Github-Authentication-Token-Expiration: %s\r\n' "$STUB_TOKEN_EXPIRY_HEADER"
        fi
        printf '\r\n'
        printf '{"resources":{"core":{"remaining":4999},"graphql":{"remaining":999}}}' \
          | jq -c "$jq_filter" ;;
      graphql)
        # lib/merge-queue.sh's `merge_queue_for_branch` (the allow_auto_merge
        # pairing check, agent-ops#532) is the only GraphQL read this suite
        # ever triggers, so the query text itself is never inspected —
        # STUB_MERGE_QUEUE_JSON is the raw `mergeQueue` value (`null`, or an
        # object literal), served through the same jq_filter the real
        # `--jq '.data.repository.mergeQueue'` applies. STUB_MERGE_QUEUE_FAIL=1
        # is a transport-level failure.
        [[ "${STUB_MERGE_QUEUE_FAIL:-0}" != "1" ]] || exit 1
        printf '{"data":{"repository":{"mergeQueue":%s}}}' "${STUB_MERGE_QUEUE_JSON:-null}" \
          | jq -c "$jq_filter" ;;
      user) printf '"stub-user"\n' ;;
      repos/*/labels) printf '' ;;
      repos/*/contents/*)
        # The fleet-flag read (merge_autonomy_kill_state's kill-switch fetch,
        # requirement 2.3b). STUB_FLEET_FLAG_JSON is the record the flag file
        # holds, served the way the contents API does (base64 under .content);
        # unset, the flag file does not exist (a 404 whose repo probe then
        # lands on `repos/*` below); STUB_FLEET_FLAG_FAIL=1 is a
        # transport-level failure — exit 1 with no HTTP status at all.
        [[ "${STUB_FLEET_FLAG_FAIL:-0}" != "1" ]] || exit 1
        flag_json="${STUB_FLEET_FLAG_JSON:-}"
        if [[ -z "$flag_json" ]]; then
          echo "gh: Not Found (HTTP 404)" >&2
          exit 1
        fi
        printf '{"content":"%s"}' "$(printf '%s' "$flag_json" | base64 -w0)" | jq -c "$jq_filter" ;;
      repos/*/rulesets/*)
        [[ "${STUB_RULESET_DETAIL_FAIL:-0}" != "1" ]] || exit 1
        # Per-id detail first (`STUB_RULESET_DETAIL_JSON_<id>`), so a case can
        # give two rulesets *different* rules — what the strictest-wins check
        # needs and one shared fixture cannot express — falling back to the
        # single shared fixture every other case still uses.
        detail_var="STUB_RULESET_DETAIL_JSON_${endpoint##*/}"
        detail_json="${!detail_var:-${STUB_RULESET_DETAIL_JSON:-}}"
        [[ -n "$detail_json" ]] || detail_json='{}'
        printf '%s' "$detail_json" | jq -c "$jq_filter" ;;
      repos/*/rulesets)
        [[ "${STUB_RULESETS_FAIL:-0}" != "1" ]] || exit 1
        rulesets_json="${STUB_RULESETS_JSON:-}"
        [[ -n "$rulesets_json" ]] || rulesets_json='[]'
        printf '%s' "$rulesets_json" | jq -c "$jq_filter" ;;
      repos/*)
        [[ "${STUB_REPO_FAIL:-0}" != "1" ]] || exit 1
        # Not `${STUB_REPO_JSON:-{}}` — bash's brace-matching for a `${VAR:-…}`
        # default gets confused when the default text itself contains braces,
        # and silently appends a stray one to the *set* value too.
        repo_json="${STUB_REPO_JSON:-}"
        [[ -n "$repo_json" ]] || repo_json='{}'
        printf '%s' "$repo_json" | jq -c "$jq_filter" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub_bin/gh"

# --- The stubbed claude ----------------------------------------------------
cat > "$stub_bin/claude" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "$1" == "--version" ]]; then
  printf 'stub-claude 0.0.0 (Claude Code)\n'
  exit 0
fi
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  if [[ "${STUB_CLAUDE_NO_AUTH_SUBCOMMAND:-0}" == "1" ]]; then
    printf 'error: unknown command "auth" for "claude"\n' >&2
    exit 1
  fi
  # Not `${STUB_CLAUDE_AUTH_JSON:-{…}}` — see the gh stub's comment on why a
  # brace-shaped default breaks the substitution even when the var is set.
  auth_json="${STUB_CLAUDE_AUTH_JSON:-}"
  [[ -n "$auth_json" ]] || auth_json='{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'
  printf '%s\n' "$auth_json"
  exit 0
fi
exit 1
STUB
chmod +x "$stub_bin/claude"

# --- A single-target-repo fixture, so the stub above only ever has to
#     answer one `repos/<slug>` call per run. Review repos, state_repo and the
#     Enabler are all switched off for the same reason — none of them is
#     what this suite tests, and every one left on is another call the stub
#     would need to arbitrate.
#
#     The D18 autonomy keys are deleted for a different reason: the merge
#     autonomy assertions below are *cross-key* rules, and each one wants a
#     specific combination of set and unset. They were written when the
#     shipped config carried none of these keys, so "unset" came for free and
#     each test only ever set what it needed. Stage 1 entry then set
#     merge_autonomy, approver_app_id and the model tiers for real, and six
#     assertions inverted — every one that depended on a key being absent
#     (#546). Deleting them here restores the known-empty baseline those
#     assertions are written against, so each test states its own combination
#     explicitly and none of them depends on what the fleet's current stage
#     happens to be. ---
slug="acme-org/target-repo"
base_config="$tmp/base-config.json"
jq --arg slug "$slug" '
  .repos = [{slug: $slug, sources: ["security", "abandoned-drafts"]}]
  | .project_review.repos = []
  | .state_repo = ""
  | .enabler_model = ""
  | .enabler_assignee = ""
  | del(.merge_autonomy, .approver_app_id, .approver_model_default,
        .approver_model_complex, .approver_model_critical, .escalation_autonomy)
' "$CONFIG" > "$base_config"

# run_doctor [VAR=value…] [-- extra doctor.sh args]
# Never passes --offline: that path is test/config-schema.test.sh's, and
# skipping the network-gated checks here would leave them untested. PATH is
# replaced, not prepended, for the two stubs' own invocations (gh, claude) —
# everything else doctor.sh calls (jq, bash) still resolves normally because
# the stub scripts run through /usr/bin/env bash on the real PATH.
rc=0
out=""
run_doctor() {
  local env_pairs=() extra_args=()
  while (( $# > 0 )); do
    if [[ "$1" == "--" ]]; then shift; extra_args=( "$@" ); break; fi
    env_pairs+=( "$1" ); shift
  done
  out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" "${env_pairs[@]}" \
    bash "$DOCTOR" --config "$base_config" "${extra_args[@]}" 2>&1)"
  rc=$?
}

# --- Write access: permissions.push true / false / absent, and archived ---

run_doctor STUB_REPO_JSON='{"permissions":{"push":true},"archived":false}'
assert_contains "permissions.push true is reported writable" \
  "[ ok ] $slug is writable — the token can push claim branches" "$out"

run_doctor STUB_REPO_JSON='{"permissions":{"push":false},"archived":false}'
assert_contains "permissions.push false is a failure — a cycle would lose work at push" \
  "[fail] $slug is readable but not writable with this token" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

run_doctor STUB_REPO_JSON='{"archived":false}'
assert_contains "an absent .permissions is a skip, never a fail — it is unauthenticated, not unwritable" \
  "[skip] $slug's write permission is not visible to this token" "$out"

run_doctor STUB_REPO_JSON='{"permissions":{"push":true},"archived":true}'
assert_contains "an archived repo fails even though the token could otherwise push" \
  "[fail] $slug is archived" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

# project_review.repos gets the same write-access check as repos[] — the
# Reviewer stage pushes a branch and opens a PR against them exactly as an
# Implementer does against a target repo, so a review repo the token can read
# but not push to loses the review the same way a target repo loses an item.
review_config="$tmp/review-config.json"
jq --arg slug "$slug" '.repos = [] | .project_review.repos = [{slug: $slug}]' "$base_config" > "$review_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" STUB_REPO_JSON='{"permissions":{"push":false},"archived":false}' \
  bash "$DOCTOR" --config "$review_config" 2>&1)"
rc=$?
assert_contains "project_review.repos names a repo the token cannot push to" \
  "[fail] $slug is readable but not writable with this token" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

# state_repo shares check_repo_access with repos[] and project_review.repos — this is
# what catches the two verdicts drifting apart, the way a hand-rolled
# state_repo check once folded an absent `.permissions` into `fail` rather
# than `skip` (it cannot be asked, which is not evidence it cannot push).
state_repo_config="$tmp/state-repo-config.json"
jq --arg slug "$slug" '.repos = [] | .project_review.repos = [] | .state_repo = $slug' "$base_config" > "$state_repo_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" STUB_REPO_JSON='{"archived":false}' \
  bash "$DOCTOR" --config "$state_repo_config" 2>&1)"
assert_contains "state_repo with no visible .permissions is a skip, not a fail" \
  "[skip] $slug's write permission is not visible to this token" "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" STUB_REPO_JSON='{"permissions":{"push":true},"archived":false}' \
  bash "$DOCTOR" --config "$state_repo_config" 2>&1)"
assert_contains "state_repo writable is reported with its own wording" \
  "[ ok ] $slug is readable and writable — the fleet's shared state can replicate" "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" STUB_REPO_JSON='{"permissions":{"push":false},"archived":false}' \
  bash "$DOCTOR" --config "$state_repo_config" 2>&1)"
assert_contains "state_repo unwritable is reported with its own wording" \
  "[fail] $slug is readable but not writable with this token" "$out"

# --- closing-keyword ruleset drift (requirement 25a, TD-PPagop-26080802) ---
# doctor.sh resolves its own repository's slug via lib/version.sh, not from
# config.repos, so every case below fires regardless of what $base_config
# names — hence no per-case config file, just run_doctor with the ruleset
# stubs set. A non-branch or non-active ruleset in the list is included in
# every fixture to confirm it is filtered out rather than merely absent.
noise_ruleset='{"id":1,"target":"tag","enforcement":"active"},{"id":2,"target":"branch","enforcement":"disabled"}'

if [[ -z "$self_repo" ]]; then
  printf 'skip - closing-keyword ruleset drift cases (could not resolve this checkout'\''s own repo slug)\n'
else
  run_doctor \
    STUB_RULESETS_JSON="[$noise_ruleset,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
    STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"closing-keyword","integration_id":15368}]}}]}'
  assert_contains "closing-keyword required and pinned to 15368 is ok" \
    "[ ok ] $self_repo's \"default\" branch ruleset requires \"closing-keyword\", pinned to integration_id 15368" "$out"

  run_doctor \
    STUB_RULESETS_JSON="[$noise_ruleset,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
    STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"shellcheck","integration_id":15368}]}}]}'
  assert_contains "closing-keyword absent from required_status_checks is a warn, naming requirement 25a's gap" \
    "[warn] $self_repo's \"default\" branch ruleset does not require \"closing-keyword\" — the check reports without blocking the merge" "$out"

  run_doctor \
    STUB_RULESETS_JSON="[$noise_ruleset,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
    STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"closing-keyword","integration_id":99999}]}}]}'
  assert_contains "closing-keyword required but unpinned is a warn — any app of that name could satisfy it" \
    "[warn] $self_repo's \"default\" branch ruleset requires \"closing-keyword\" without pinning integration_id 15368" "$out"

  run_doctor STUB_RULESETS_JSON="[$noise_ruleset]"
  assert_contains "no active branch ruleset targets the default branch — a warn, not a fail" \
    "[warn] $self_repo has no active branch ruleset targeting the default branch" "$out"

  run_doctor STUB_RULESETS_FAIL=1
  assert_contains "the rulesets endpoint being unreachable is a skip, not a fail" \
    "[skip] closing-keyword ruleset enforcement — repos/$self_repo/rulesets is not reachable with this token" "$out"

  run_doctor \
    STUB_RULESETS_JSON="[$noise_ruleset,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
    STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"closing-keyword","integration_id":15368}]}}]}'
  assert_eq "and a fully-enforced ruleset does not fail doctor.sh" "0" "$rc"
fi

# --- Requirement 38's ruleset dependency (agent-ops#391) --------------------
# `reviewDecision` never becomes `APPROVED` on a repository whose branch
# ruleset requires zero approving reviews, however many humans approve — the
# gap that cost agent-ops#391 a cross-repo investigation to find. The nudge
# itself no longer depends on the field (`_handoff_pr_approved`, lib/
# handoff.sh), but doctor.sh still reports each target repository's own
# `required_approving_review_count` so the quirk is visible up front instead
# of rediscovered. Runs over `base_config`'s own `$slug`, unlike the
# closing-keyword block above, which resolves `self_repo` regardless of
# config.
noise_ruleset_38='{"id":1,"target":"tag","enforcement":"active"},{"id":2,"target":"branch","enforcement":"disabled"}'

run_doctor \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]}'
assert_contains "a ruleset requiring 1 approving review reports it, ok" \
  "[ ok ] $slug's default-branch ruleset requires 1 approving review(s) — reviewDecision reaches APPROVED normally" "$out"

run_doctor \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":0}}]}'
assert_contains "a ruleset requiring 0 approving reviews is a warn naming agent-ops#391" \
  "[warn] $slug's default-branch ruleset requires 0 approving reviews — reviewDecision never becomes APPROVED here" "$out"
assert_contains "  ... explicitly not treated as a requirement 38 fault" \
  "so this is informational, not a requirement 38 fault" "$out"

run_doctor \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"closing-keyword"}]}}]}'
assert_contains "an active default-branch ruleset with no pull_request rule is a skip" \
  "[skip] $slug's default branch has no active ruleset requiring approving reviews" "$out"

run_doctor STUB_RULESETS_JSON="[$noise_ruleset_38]"
assert_contains "no active ruleset targets the default branch at all is the same skip" \
  "[skip] $slug's default branch has no active ruleset requiring approving reviews" "$out"

run_doctor STUB_RULESETS_FAIL=1
assert_contains "the rulesets endpoint being unreachable is its own skip" \
  "[skip] $slug's default-branch ruleset — repos/$slug/rulesets is not reachable with this token" "$out"

# Two active rulesets both targeting the default branch: GitHub enforces the
# strictest applicable rule, so the reported count must be the maximum across
# matches and not whichever the API happened to return last. Asserted in both
# list orders, since a last-wins implementation passes one of them by luck.
strict_1='{"name":"strict","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]}'
lax_0='{"name":"lax","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":0}}]}'

run_doctor \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"},{\"id\":4,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON_3="$strict_1" \
  STUB_RULESET_DETAIL_JSON_4="$lax_0"
assert_contains "two default-branch rulesets report the strictest, not the last (1 then 0)" \
  "[ ok ] $slug's default-branch ruleset requires 1 approving review(s) — reviewDecision reaches APPROVED normally" "$out"

run_doctor \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"},{\"id\":4,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON_3="$lax_0" \
  STUB_RULESET_DETAIL_JSON_4="$strict_1"
assert_contains "  ... and in the other list order (0 then 1)" \
  "[ ok ] $slug's default-branch ruleset requires 1 approving review(s) — reviewDecision reaches APPROVED normally" "$out"

# A ruleset whose count is not a number is no count at all — passed over like
# an absent rule, never compared as the `0` that flips the verdict to warn.
run_doctor \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"},{\"id\":4,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON_3='{"name":"odd","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":"all"}}]}' \
  STUB_RULESET_DETAIL_JSON_4="$strict_1"
assert_contains "a non-numeric required count is passed over, not read as 0" \
  "[ ok ] $slug's default-branch ruleset requires 1 approving review(s) — reviewDecision reaches APPROVED normally" "$out"

run_doctor \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":0}}]}'
assert_eq "and requiring 0 approving reviews is a warn, not a failure" "0" "$rc"

# --- D18 §5.3 (requirement 2.3b): merge_autonomy at agent-merges-routine+
#     while the ruleset still requires code-owner review ---------------------
# Reuses the same ruleset pass as requirement 38's check above (one API read,
# two facts), so the fixture shape is identical; only merge_autonomy and
# require_code_owner_review vary. A per-repo config is needed here, unlike
# the requirement-38 block above, since the level under test lives on
# $base_config itself.
ma_config="$tmp/ma-config.json"

jq '.merge_autonomy = "agent-merges-routine" | .approver_app_id = "123456" | .approver_model_default = "claude-sonnet-5"' "$base_config" > "$ma_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":true}}]}' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "agent-merges-routine with code-owner review still required fails, naming the repo and level" \
  "[fail] $slug's merge_autonomy is \"agent-merges-routine\" but its default-branch ruleset still requires code-owner review" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":false}}]}' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
assert_not_contains "agent-merges-routine with code-owner review off does not fail" \
  "still requires code-owner review" "$out"
assert_contains "and positively confirms the pairing, naming the repo and level" \
  "[ ok ] $slug's merge_autonomy is \"agent-merges-routine\" and its default-branch ruleset requires no code-owner review" "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":true}}]}' \
  bash "$DOCTOR" --config "$base_config" 2>&1)"
assert_not_contains "merge_autonomy at the default (human) is unaffected by code-owner review either way" \
  "still requires code-owner review" "$out"
assert_not_contains "and stays silent below the routine tier rather than narrate an inapplicable pairing" \
  "requires no code-owner review" "$out"

ma_approves_config="$tmp/ma-approves-config.json"
jq '.merge_autonomy = "agent-approves" | .approver_app_id = "123456" | .approver_model_default = "claude-sonnet-5"' "$base_config" > "$ma_approves_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":true}}]}' \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_not_contains "agent-approves (below the routine tier) is unaffected by code-owner review" \
  "still requires code-owner review" "$out"
assert_not_contains "and earns no code-owner ok line either" \
  "requires no code-owner review" "$out"

# --- D18 Stage 3 (agent-ops#575): stale-review dismissal and bypass-actor
#     checks, added alongside the code-owner one above — same ruleset pass,
#     same fixture shape, only dismiss_stale_reviews_on_push/bypass_actors
#     vary. ----------------------------------------------------------------
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":false,"dismiss_stale_reviews_on_push":false}}]}' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "agent-merges-routine with stale reviews not dismissed on push fails" \
  "[fail] $slug's merge_autonomy is \"agent-merges-routine\" but its default-branch ruleset does not dismiss stale reviews on push" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":false,"dismiss_stale_reviews_on_push":true}}]}' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
assert_not_contains "agent-merges-routine with stale reviews dismissed on push does not fail" \
  "does not dismiss stale reviews" "$out"
assert_contains "and positively confirms it, naming the repo and level" \
  "[ ok ] $slug's merge_autonomy is \"agent-merges-routine\" and its default-branch ruleset dismisses stale reviews on push" "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":false,"dismiss_stale_reviews_on_push":true}}],"bypass_actors":[{"actor_id":1,"actor_type":"Team","bypass_mode":"always"}]}' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "agent-merges-routine with a bypass actor named fails, naming the count" \
  "[fail] $slug's merge_autonomy is \"agent-merges-routine\" but its default-branch ruleset names 1 bypass actor(s)" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":false,"dismiss_stale_reviews_on_push":true}}],"bypass_actors":[]}' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
assert_not_contains "no bypass actor at all does not fail" \
  "bypass actor(s)" "$out"
assert_contains "and positively confirms none, naming the repo and level" \
  "[ ok ] $slug's merge_autonomy is \"agent-merges-routine\" and its default-branch ruleset names no bypass actor" "$out"

# --- D18 Stage 3 (agent-ops#575): the Approver App installation's live
#     granted permissions (lib/approver-token.sh's
#     approver_token_installation_permissions), stubbed through
#     APPROVER_TOKEN_CURL exactly as test/approver-token.test.sh stubs the
#     same wrapper — a real throwaway RSA key so JWT signing is exercised for
#     real rather than faked, and a stub curl answering the one GET this
#     check makes. ----------------------------------------------------------
perm_key="$tmp/approver-perm-key.pem"
openssl genrsa -out "$perm_key" 2048 >/dev/null 2>&1
perm_curl="$tmp/perm-curl"
perm_cache="$tmp/approver-token-cache"
mkdir -p "$perm_cache"
# Dispatches on the URL, because two different reads reach it now: the JWT-
# signed permissions read (`/app/installations/<id>`) and, behind an
# installation token it must first mint (`…/access_tokens`), the repository
# selection (`/installation/repositories`, agent-ops#721). A stub answering
# one canned body to all three would fail the mint and report the selection
# unreadable in every existing case.
cat > "$perm_curl" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
cat >/dev/null 2>&1
url=""
for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
case "$url" in
  */access_tokens)
    printf '{"token":"ghs_doctor_stub","expires_at":"2099-01-01T00:00:00Z"}\n201'
    exit 0 ;;
  */installation/repositories*)
    [[ -f "$d/repos_curl_fail" ]] && exit 1
    status="$(cat "$d/repos_curl_status" 2>/dev/null || echo 200)"
    body="$(cat "$d/repos_curl_body" 2>/dev/null || echo '{}')"
    printf '%s\n%s' "$body" "$status"
    exit 0 ;;
esac
[[ -f "$d/perm_curl_fail" ]] && exit 1
status="$(cat "$d/perm_curl_status" 2>/dev/null || echo 200)"
body="$(cat "$d/perm_curl_body" 2>/dev/null || echo '{}')"
printf '%s\n%s' "$body" "$status"
STUB
chmod +x "$perm_curl"
stub_perm() {
  local status="${1:-200}" body="$2"
  printf '%s' "$status" > "$tmp/perm_curl_status"
  printf '%s' "$body" > "$tmp/perm_curl_body"
  rm -f "$tmp/perm_curl_fail"
}
# The installation's repository selection: covering $slug by default, so every
# case written before agent-ops#721 keeps the verdict it was written for.
stub_repos() {
  local status="${1:-200}" body="$2"
  printf '%s' "$status" > "$tmp/repos_curl_status"
  printf '%s' "$body" > "$tmp/repos_curl_body"
  rm -f "$tmp/repos_curl_fail" "$perm_cache"/* 2>/dev/null || true
}
stub_repos 200 "$(printf '{"total_count":1,"repository_selection":"selected","repositories":[{"full_name":"%s"}]}' "$slug")"

stub_perm 200 '{"permissions":{"contents":"write","metadata":"read","pull_requests":"write"}}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
rc=$?
assert_contains "the exact three permissions live is ok" \
  "[ ok ] the Approver App installation carries exactly contents:write, metadata:read and pull_requests:write" "$out"
assert_eq "and doctor.sh does not fail for it" "0" "$rc"

stub_perm 200 '{"permissions":{"contents":"read","metadata":"read","pull_requests":"write"}}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
rc=$?
assert_contains "a narrower live contents permission fails, naming the gap" \
  "[fail] the Approver App installation's live permissions do not match what this fleet needs: contents is read, needs write" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

stub_perm 200 '{"permissions":{"contents":"write","metadata":"read","pull_requests":"write","issues":"write"}}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_contains "a permission granted beyond the three required fails too, naming it" \
  "issues granted but not required" "$out"

touch "$tmp/perm_curl_fail"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
rc=$?
assert_contains "an unreachable installation endpoint is a skip, never a fail — it degrades gracefully" \
  "[skip] the Approver App installation's live permissions" "$out"
assert_eq "and doctor.sh does not exit non-zero for it" "0" "$rc"
rm -f "$tmp/perm_curl_fail"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_not_contains "with no credential present in this environment, the fleet-wide permissions check stays silent (already warned about separately)" \
  "the Approver App installation carries exactly" "$out"
assert_not_contains "  ... and never prints its own skip line either" \
  "[skip] the Approver App installation's live permissions" "$out"
assert_contains "  ... but the consolidated verdict at agent-approves still names it unconfirmed — the App's own live permissions are exactly what agent-approves needs, credential or no" \
  "$slug's autonomy readiness at \"agent-approves\" could not be fully confirmed — unconfirmed: the Approver App installation's live permissions could not be confirmed" "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$base_config" 2>&1)"
assert_not_contains "at human (nothing above human configured), the permissions check stays silent too" \
  "the Approver App installation" "$out"

# --- D18 WI-5 (requirement 8b): merge_autonomy above human needs
#     approver_model_default too, the same pairing approver_app_id already
#     gets — the Approver stage reads it empty as "disabled", so a level
#     above human configured with it empty would silently gain no App review
#     at all, and doctor is where an operator can still see that. -----------
ma_no_model_config="$tmp/ma-no-model-config.json"
jq '.merge_autonomy = "agent-approves" | .approver_app_id = "123456"' "$base_config" > "$ma_no_model_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$ma_no_model_config" 2>&1)"
rc=$?
assert_contains "agent-approves with no approver_model_default fails, naming the level" \
  '[fail] merge_autonomy is "agent-approves" with no approver_model_default configured' "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_not_contains "agent-approves with approver_model_default set does not fail on this pairing" \
  "no approver_model_default configured" "$out"
assert_contains "  ... and positively confirms the level, same as it did before this pairing existed" \
  '[ ok ] merge_autonomy is "agent-approves"' "$out"

run_doctor
assert_not_contains "merge_autonomy at the default (human) needs no approver_model_default" \
  "no approver_model_default configured" "$out"

# --- agent-ops#627: escalation_autonomy's adjudicate-first needs the
#     Enabler enabled to run its adjudication pass against ------------------
ea_no_enabler_config="$tmp/ea-no-enabler-config.json"
jq '.escalation_autonomy = "adjudicate-first"' "$base_config" > "$ea_no_enabler_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$ea_no_enabler_config" 2>&1)"
assert_contains "adjudicate-first with the Enabler disabled warns, naming the key" \
  '[warn] escalation_autonomy is "adjudicate-first" but enabler_model is empty' "$out"

ea_enabled_config="$tmp/ea-enabled-config.json"
jq '.escalation_autonomy = "adjudicate-first" | .enabler_model = "claude-opus-5"
    | .enabler_assignee = "octocat"' "$base_config" > "$ea_enabled_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$ea_enabled_config" 2>&1)"
assert_not_contains "adjudicate-first with the Enabler enabled does not warn on this pairing" \
  "enabler_model is empty" "$out"
assert_contains "  ... and positively confirms the level" \
  '[ ok ] escalation_autonomy is "adjudicate-first"' "$out"

run_doctor
assert_contains "always-escalate (the default) needs no enabler_model either" \
  '[ ok ] escalation_autonomy is "always-escalate"' "$out"

# --- agent-ops#532 (D18 WI-7 follow-up): merge_autonomy at
#     agent-merges-routine+ with no merge queue must pair with *both*
#     allow_auto_merge and allow_squash_merge, since landing_arm's no-queue
#     fallback is `gh pr merge --auto --squash`, a call GitHub refuses
#     outright when either of the two is off ---------------------------------
# Reuses $ma_config (merge_autonomy already at agent-merges-routine, with
# approver_app_id/approver_model_default set so those pairings don't also
# fire and add noise to these assertions).
aam_queue_json='{"id":"MQ_kwDOTWpCsc4AA8Qo","mergeMethod":"SQUASH","mergingStrategy":"ALLGREEN"}'
aam_ok_json='{"permissions":{"push":true},"archived":false,"allow_auto_merge":true,"allow_squash_merge":true,"default_branch":"main"}'
aam_auto_off_json='{"permissions":{"push":true},"archived":false,"allow_auto_merge":false,"allow_squash_merge":true,"default_branch":"main"}'
aam_squash_off_json='{"permissions":{"push":true},"archived":false,"allow_auto_merge":true,"allow_squash_merge":false,"default_branch":"main"}'
aam_both_off_json='{"permissions":{"push":true},"archived":false,"allow_auto_merge":false,"allow_squash_merge":false,"default_branch":"main"}'

# D18 Stage 3 (agent-ops#575): the consolidated autonomy-readiness verdict
# runs against this same $ma_config (agent-merges-routine) too, so any case
# below asserting doctor.sh exits 0 also needs a ruleset that satisfies that
# verdict's *other* preconditions — otherwise a repository this suite never
# gives any ruleset at all would report its own "no active default-branch
# ruleset requires approving reviews" as a missing precondition, which is not
# what these cases test.
aam_ready_rulesets_json='[{"id":9,"target":"branch","enforcement":"active"}]'
aam_ready_ruleset_detail_json='{"name":"ready","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":false,"dismiss_stale_reviews_on_push":true}}]}'

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_ok_json" STUB_MERGE_QUEUE_JSON='null' \
  STUB_RULESETS_JSON="$aam_ready_rulesets_json" STUB_RULESET_DETAIL_JSON="$aam_ready_ruleset_detail_json" \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "no merge queue but both merge settings enabled is ok" \
  "[ ok ] $slug's merge_autonomy is \"agent-merges-routine\" with no merge queue on main, but allow_auto_merge and allow_squash_merge are both enabled — no repository setting refuses landing_arm's no-queue fallback" \
  "$out"
assert_eq "and doctor.sh exits 0" "0" "$rc"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_auto_off_json" STUB_MERGE_QUEUE_JSON='null' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "no merge queue and allow_auto_merge disabled fails, naming it and both fixes" \
  "[fail] $slug's merge_autonomy is \"agent-merges-routine\" with no merge queue on main and allow_auto_merge disabled — landing_arm's no-queue fallback, gh pr merge --auto --squash, would be refused outright; enable allow_auto_merge on $slug or adopt a merge queue on main" \
  "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

# The gap this pairing would otherwise leave open: `--auto --squash` needs
# `allow_squash_merge` just as much as `allow_auto_merge`, so a repository
# that merges by rebase or merge commit must not collect a green all-clear.
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_squash_off_json" STUB_MERGE_QUEUE_JSON='null' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "allow_squash_merge disabled fails too, naming that one" \
  "[fail] $slug's merge_autonomy is \"agent-merges-routine\" with no merge queue on main and allow_squash_merge disabled — landing_arm's no-queue fallback, gh pr merge --auto --squash, would be refused outright; enable allow_squash_merge on $slug or adopt a merge queue on main" \
  "$out"
assert_eq "  ... and doctor.sh exits 1" "1" "$rc"
assert_not_contains "  ... and never collects the pass line as well" \
  "no repository setting refuses" "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_both_off_json" STUB_MERGE_QUEUE_JSON='null' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
assert_contains "both disabled names both in the one failure" \
  "[fail] $slug's merge_autonomy is \"agent-merges-routine\" with no merge queue on main and allow_auto_merge and allow_squash_merge disabled — landing_arm's no-queue fallback, gh pr merge --auto --squash, would be refused outright; enable allow_auto_merge and allow_squash_merge on $slug or adopt a merge queue on main" \
  "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_both_off_json" STUB_MERGE_QUEUE_JSON="$aam_queue_json" \
  STUB_RULESETS_JSON="$aam_ready_rulesets_json" STUB_RULESET_DETAIL_JSON="$aam_ready_ruleset_detail_json" \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "an active merge queue is ok regardless of either setting" \
  "[ ok ] $slug's merge_autonomy is \"agent-merges-routine\" and main carries an active merge queue — landing_arm enqueues regardless of allow_auto_merge and allow_squash_merge" \
  "$out"
assert_eq "  ... even with both off" "0" "$rc"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_both_off_json" STUB_MERGE_QUEUE_JSON='null' \
  bash "$DOCTOR" --config "$base_config" 2>&1)"
assert_not_contains "below the routine tier the pairing stays silent" \
  "merge-settings/merge-queue pairing" "$out"
assert_not_contains "  ... no positive line either" \
  "landing_arm enqueues" "$out"
assert_not_contains "  ... nor a failure" \
  "would be refused outright" "$out"
assert_contains "  ... and unrelated checks keep running for this repo" \
  "[ ok ] $slug is writable — the token can push claim branches" "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_FAIL=1 \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
assert_contains "an unreachable repos/\$slug is a skip, never an ok or a fail" \
  "[skip] $slug's merge-settings/merge-queue pairing — repos/$slug is not reachable with this token" \
  "$out"
assert_not_contains "  ... never read as a pass" \
  "landing_arm enqueues" "$out"
assert_not_contains "  ... never read as a failure either" \
  "would be refused outright" "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_ok_json" STUB_MERGE_QUEUE_FAIL=1 \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
assert_contains "an unreadable merge-queue state is also a skip" \
  "[skip] $slug's merge-settings/merge-queue pairing — could not read main's merge-queue state" \
  "$out"

# GitHub omits both keys from `repos/$slug` altogether unless the reading
# token has admin visibility of the repository's merge settings — verified
# live 2026-08-18: `gh api repos/cli/cli` from a token with no admin there
# returns neither key, while the same token reading `Poetic-Poems/agent-ops`
# (where it is an admin) returns `true` for both. An absent key is *unknown*,
# not `false`, and reading it as `false` would fail an installation for a
# setting it never got to see.
aam_absent_json='{"permissions":{"push":true},"archived":false,"default_branch":"main"}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_absent_json" STUB_MERGE_QUEUE_JSON='null' \
  STUB_RULESETS_JSON="$aam_ready_rulesets_json" STUB_RULESET_DETAIL_JSON="$aam_ready_ruleset_detail_json" \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "both absent is a skip naming both, never read as disabled" \
  "[skip] $slug's merge-settings/merge-queue pairing — main carries no merge queue and repos/$slug did not report allow_auto_merge and allow_squash_merge" \
  "$out"
assert_not_contains "  ... never read as a failure" \
  "would be refused outright" "$out"
assert_not_contains "  ... nor as a pass" \
  "no repository setting refuses" "$out"
assert_eq "  ... and doctor.sh does not exit non-zero for it" "0" "$rc"

# One absent sibling alone is still just a skip, and names only the key that
# was actually missing.
aam_squash_absent_json='{"permissions":{"push":true},"archived":false,"allow_auto_merge":true,"default_branch":"main"}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_squash_absent_json" STUB_MERGE_QUEUE_JSON='null' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
assert_contains "a readable allow_auto_merge with an unreadable sibling is a skip" \
  "[skip] $slug's merge-settings/merge-queue pairing — main carries no merge queue and repos/$slug did not report allow_squash_merge" \
  "$out"
assert_not_contains "  ... and does not claim the fallback is accepted" \
  "no repository setting refuses" "$out"

# Ordering: a setting read as a definite `false` decides the verdict before
# the absent case is considered, so an unreadable sibling can never mask a
# setting doctor did read as off.
aam_off_and_absent_json='{"permissions":{"push":true},"archived":false,"allow_auto_merge":false,"default_branch":"main"}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_off_and_absent_json" STUB_MERGE_QUEUE_JSON='null' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "a known-false setting outranks an unreadable sibling" \
  "[fail] $slug's merge_autonomy is \"agent-merges-routine\" with no merge queue on main and allow_auto_merge disabled — landing_arm's no-queue fallback, gh pr merge --auto --squash, would be refused outright; enable allow_auto_merge on $slug or adopt a merge queue on main" \
  "$out"
assert_eq "  ... and still exits 1 rather than skipping" "1" "$rc"
assert_not_contains "  ... never downgraded to the unreadable skip" \
  "did not report allow_squash_merge" "$out"

# An active queue makes both settings irrelevant, so absent ones are still a
# plain `ok` there rather than the skip above.
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_absent_json" STUB_MERGE_QUEUE_JSON="$aam_queue_json" \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
assert_contains "absent merge settings with an active queue are still ok" \
  "[ ok ] $slug's merge_autonomy is \"agent-merges-routine\" and main carries an active merge queue — landing_arm enqueues regardless of allow_auto_merge and allow_squash_merge" \
  "$out"

# --- D18 Stage 3 (agent-ops#575): the one consolidated autonomy-readiness
#     verdict per repository, gathering every precondition above (merge path,
#     ruleset approval/code-owner/stale-dismissal/bypass-actor, App
#     installation permissions, approver_app_id/approver_model_default) into
#     the one question an operator actually has: is $slug's *configured*
#     merge_autonomy something its forge configuration can support right now.
# Every precondition satisfied — forge ruleset ready, merge settings both
# enabled, and the live App installation carrying exactly the three
# permissions this fleet needs — earns the one positive verdict line, never a
# `fail`, acceptance check 2's own contrapositive.
stub_perm 200 '{"permissions":{"contents":"write","metadata":"read","pull_requests":"write"}}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  STUB_REPO_JSON="$aam_ok_json" STUB_MERGE_QUEUE_JSON='null' \
  STUB_RULESETS_JSON="$aam_ready_rulesets_json" STUB_RULESET_DETAIL_JSON="$aam_ready_ruleset_detail_json" \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "every precondition satisfied earns one ok verdict" \
  "[ ok ] $slug's autonomy readiness: \"agent-merges-routine\" is fully supported by its forge configuration" "$out"
assert_eq "and doctor.sh does not exit non-zero for it" "0" "$rc"

# Nothing satisfied — no ruleset, no merge path, no App permissions readable
# — is a `fail`, never a `warn` (acceptance check 2), naming every missing
# precondition and its owner-act/configuration-error tag in the one line.
touch "$tmp/perm_curl_fail"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  STUB_REPO_JSON="$aam_both_off_json" STUB_MERGE_QUEUE_JSON='null' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "nothing satisfied is a fail, never a warn, naming the repo and level" \
  "[fail] $slug is configured at \"agent-merges-routine\" but its forge configuration does not support it — missing:" "$out"
assert_contains "  ... naming the merge-path gap as an owner act" \
  "no merge queue and allow_auto_merge/allow_squash_merge are not both enabled (owner act)" "$out"
assert_contains "  ... naming the missing ruleset as an owner act" \
  "no active default-branch ruleset requires approving reviews (owner act)" "$out"
assert_not_contains "  ... and never reported as a warn instead" \
  "[warn] $slug is configured at \"agent-merges-routine\" but its forge configuration" "$out"
assert_eq "  ... and doctor.sh exits 1" "1" "$rc"
rm -f "$tmp/perm_curl_fail"

# A missing configuration key (approver_model_default) is named too, tagged
# distinctly from the forge-side owner acts above.
ma_config_no_model="$tmp/ma-config-no-model.json"
jq 'del(.approver_model_default)' "$ma_config" > "$ma_config_no_model"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_ok_json" STUB_MERGE_QUEUE_JSON='null' \
  STUB_RULESETS_JSON="$aam_ready_rulesets_json" STUB_RULESET_DETAIL_JSON="$aam_ready_ruleset_detail_json" \
  bash "$DOCTOR" --config "$ma_config_no_model" 2>&1)"
assert_contains "a missing config key is named as a configuration error, not an owner act" \
  "approver_model_default is not set (configuration error)" "$out"

# A precondition this run could not check at all (the ruleset endpoint
# unreachable) is named as unconfirmed and never turns the verdict into a
# `fail` by itself — acceptance check 7's "degrade gracefully" applied to the
# one consolidated verdict, not just the individual checks that feed it.
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_ok_json" STUB_MERGE_QUEUE_JSON='null' STUB_RULESETS_FAIL=1 \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "an unreachable ruleset endpoint is reported unconfirmed, not failed" \
  "$slug's autonomy readiness at \"agent-merges-routine\" could not be fully confirmed" "$out"
assert_not_contains "  ... never as a fail for something this run could not check" \
  "[fail] $slug is configured at \"agent-merges-routine\" but its forge configuration" "$out"
assert_eq "  ... and doctor.sh does not exit non-zero for it" "0" "$rc"

# The merge-path pass has three skip-and-continue paths of its own that leave
# no verdict behind at all (repos/<slug> unreachable, no default_branch
# reported, the merge-queue state unreadable — the live case on
# Poetic-Poems/agent-ops as of 2026-08-22). The consolidated verdict must name
# those as could-not-be-read rather than as never-looked-at: at this rank the
# pass always runs, so an unset entry can only mean a failed read.
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON="$aam_ok_json" STUB_MERGE_QUEUE_FAIL=1 \
  STUB_RULESETS_JSON="$aam_ready_rulesets_json" STUB_RULESET_DETAIL_JSON="$aam_ready_ruleset_detail_json" \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "an unreadable merge-queue state leaves the verdict unconfirmed, naming it as unread" \
  "$slug's autonomy readiness at \"agent-merges-routine\" could not be fully confirmed — unconfirmed: its merge-settings/merge-queue pairing could not be read" "$out"
assert_not_contains "  ... never as a fail for something this run could not check" \
  "[fail] $slug is configured at \"agent-merges-routine\" but its forge configuration" "$out"
assert_eq "  ... and doctor.sh does not exit non-zero for it" "0" "$rc"

# Below agent-approves (human), the verdict is silent — there is nothing to
# verify at the level every repository starts at.
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  bash "$DOCTOR" --config "$base_config" 2>&1)"
assert_not_contains "at human, the consolidated verdict prints nothing at all" \
  "autonomy readiness" "$out"

# At agent-approves (below the routine tier, over $ma_approves_config), the
# ruleset and merge-path facts play no part — landing_arm is unreachable at
# this level regardless of either — but the App installation's live
# permissions still do, since pull_requests:write is the whole of what
# agent-approves consists of: the App cannot post any review without it. A
# live installation narrowed off pull_requests:write must not earn the "is
# fully supported by its forge configuration" line.
stub_perm 200 '{"permissions":{"contents":"write","metadata":"read"}}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
rc=$?
assert_contains "agent-approves with a narrowed App installation fails, naming the gap as an owner act" \
  "[fail] $slug is configured at \"agent-approves\" but its forge configuration does not support it — missing: the Approver App installation's live permissions do not match exactly what this fleet needs (owner act)" "$out"
assert_not_contains "  ... and never the false all-clear that it is fully supported" \
  "[ ok ] $slug's autonomy readiness: \"agent-approves\" is fully supported by its forge configuration" "$out"
assert_eq "  ... and doctor.sh exits 1" "1" "$rc"

# The exact three permissions live earns the positive verdict at agent-approves
# too, exactly as it does at agent-merges-routine above.
stub_perm 200 '{"permissions":{"contents":"write","metadata":"read","pull_requests":"write"}}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
rc=$?
assert_contains "agent-approves with the exact three permissions live earns the ok verdict" \
  "[ ok ] $slug's autonomy readiness: \"agent-approves\" is fully supported by its forge configuration" "$out"
assert_eq "  ... and doctor.sh does not exit non-zero for it" "0" "$rc"

# --- D18 Stage 3 (agent-ops#721): the installation's repository *selection*,
#     not just its permissions. Permissions say what the App may do; the
#     selection says where — and a repository left out of a `selected`
#     installation is one the App can neither review nor land in, however
#     right its permissions look.
stub_perm 200 '{"permissions":{"contents":"write","metadata":"read","pull_requests":"write"}}'
stub_repos 200 '{"total_count":1,"repository_selection":"selected","repositories":[{"full_name":"acme-org/some-other-repo"}]}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
rc=$?
assert_contains "a repository outside the installation's selection fails, naming it an owner act" \
  "the Approver App installation does not cover $slug — add it to the installation's repository selection (owner act)" "$out"
assert_not_contains "  ... and never the false all-clear that it is fully supported" \
  "[ ok ] $slug's autonomy readiness: \"agent-approves\" is fully supported by its forge configuration" "$out"
assert_eq "  ... and doctor.sh exits 1" "1" "$rc"

# An installation granted every repository in the account covers this one by
# construction — no listing to search.
stub_repos 200 '{"total_count":0,"repository_selection":"all","repositories":[]}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_contains "a whole-account installation covers every configured repository" \
  "[ ok ] $slug's autonomy readiness: \"agent-approves\" is fully supported by its forge configuration" "$out"

# A listing that could not be read whole — here a page shorter than its own
# total_count — is unconfirmed, never the "does not cover" that would be a
# fail and an owner act. A dropped page must not be able to mint one of those.
stub_repos 200 '{"total_count":9,"repository_selection":"selected","repositories":[{"full_name":"acme-org/other"}]}'
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$perm_key" APPROVER_TOKEN_CURL="$perm_curl" \
  APPROVER_TOKEN_CACHE_DIR="$perm_cache" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
rc=$?
assert_contains "a truncated listing reports unconfirmed, never a missing repository" \
  "which repositories the Approver App installation covers could not be read" "$out"
assert_not_contains "  ... and never claims the App cannot see it" \
  "the Approver App installation does not cover" "$out"
assert_eq "  ... and doctor.sh does not fail for something it could not check" "0" "$rc"

# Restore the covering selection for every case below.
stub_repos 200 "$(printf '{"total_count":1,"repository_selection":"selected","repositories":[{"full_name":"%s"}]}' "$slug")"

# --- D18 WI-7 (requirement 8d): merge_autonomy_routine_sources naming a
#     source this repository's own sources list never gathers ---------------
# $base_config's own repo lists only ["security", "abandoned-drafts"], and
# neither is in the shipped default ["register-hygiene", "tech-debt"], so the
# default itself already exercises the warning with no override needed.
run_doctor
assert_contains "the shipped default merge_autonomy_routine_sources warns when this repo gathers neither" \
  "[warn] $slug's merge_autonomy_routine_sources names [register-hygiene,tech-debt], which its own sources list never gathers" \
  "$out"

rs_ok_config="$tmp/rs-ok-config.json"
jq --arg slug "$slug" \
  '.repos = [{slug: $slug, sources: ["security", "abandoned-drafts", "tech-debt", "register-hygiene"]}]' \
  "$base_config" > "$rs_ok_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$rs_ok_config" 2>&1)"
assert_not_contains "a repo whose sources cover the default routine list gets no warning" \
  "merge_autonomy_routine_sources names" "$out"
assert_contains "  ... and a positive ok instead" \
  "[ ok ] $slug's merge_autonomy_routine_sources are all sources it actually gathers" "$out"

rs_override_config="$tmp/rs-override-config.json"
jq --arg slug "$slug" \
  '.repos = [{slug: $slug, sources: ["security", "abandoned-drafts", "code-quality"],
              merge_autonomy_routine_sources: ["code-quality", "tech-debt"]}]' \
  "$base_config" > "$rs_override_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$rs_override_config" 2>&1)"
assert_contains "a repo-level override is checked against that repo's own sources, naming only the missing entry" \
  "[warn] $slug's merge_autonomy_routine_sources names [tech-debt], which its own sources list never gathers" \
  "$out"
assert_not_contains "  ... code-quality is not named — the repo does gather it" \
  "names [tech-debt,code-quality]" "$out"

# --- agent-ops#519: a banded issues:<band> token validates clean against the
#     "does the repo gather this" check above — it is typically present in
#     the repo's own sources list too — but can never match a work order:
#     every issues:<band> candidate's own source collapses to the plain word
#     "issues" before landing_eligible's comparison ever runs (lib/landing.sh's
#     own header). --------------------------------------------------------
rs_banded_config="$tmp/rs-banded-config.json"
jq --arg slug "$slug" \
  '.repos = [{slug: $slug, sources: ["security", "abandoned-drafts", "issues:low", "tech-debt"],
              merge_autonomy_routine_sources: ["issues:low", "tech-debt"]}]' \
  "$base_config" > "$rs_banded_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$rs_banded_config" 2>&1)"
assert_contains "a banded issues:<band> token warns even though the repo's own sources list gathers it" \
  "[warn] $slug's merge_autonomy_routine_sources names [issues:low], a banded issues:<band> token — every issues:<band> work order's own source collapses to the plain word \"issues\" before landing_eligible's comparison ever runs (lib/landing.sh's own header), so this entry can never match a work order; list \"issues\" itself if this repository should land issues work routinely (D18 WI-7)" \
  "$out"
assert_not_contains "  ... the 'never gathers' warning does not also fire — the repo does gather issues:low" \
  "which its own sources list never gathers" "$out"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$rs_ok_config" 2>&1)"
assert_not_contains "an unbanded routine list never triggers the banded-token warning" \
  "banded issues:<band> token" "$out"

# --- agent-ops#558: the remedy #519's warning names — a bare `issues` in the
#     routine list — is now a writable token (the key takes landingSourceToken,
#     not sourceToken), and must not then be reported as ungathered by the
#     set-difference check above: `sources` spells the same source banded, so
#     the routine side is normalised before the difference is taken. Without
#     that, following doctor's own advice would trade one warning for another
#     and there would still be no clean way to land issues work. ------------
rs_plain_config="$tmp/rs-plain-config.json"
jq --arg slug "$slug" \
  '.repos = [{slug: $slug, sources: ["security", "abandoned-drafts", "issues:low", "tech-debt"],
              merge_autonomy_routine_sources: ["issues", "tech-debt"]}]' \
  "$base_config" > "$rs_plain_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$rs_plain_config" 2>&1)"
assert_contains "a bare 'issues' routine entry is gathered, because the repo's sources carry issues:low" \
  "[ ok ] $slug's merge_autonomy_routine_sources are all sources it actually gathers" "$out"
assert_not_contains "  ... so the 'never gathers' warning does not fire on the normalised token" \
  "which its own sources list never gathers" "$out"
assert_not_contains "  ... and the banded-token warning does not fire either — nothing here is banded" \
  "banded issues:<band> token" "$out"

# A bare `issues` in a repository that gathers no issues at all is still a
# real fault, and the normalisation must not swallow it.
rs_noissues_config="$tmp/rs-noissues-config.json"
jq --arg slug "$slug" \
  '.repos = [{slug: $slug, sources: ["security", "tech-debt"],
              merge_autonomy_routine_sources: ["issues", "tech-debt"]}]' \
  "$base_config" > "$rs_noissues_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$rs_noissues_config" 2>&1)"
assert_contains "a bare 'issues' entry still warns where the repository gathers no issues source at all" \
  "[warn] $slug's merge_autonomy_routine_sources names [issues], which its own sources list never gathers" \
  "$out"

# --- D18 WI-12 (Stage 4, agent-ops#415): landing_cool_off_hours reported
#     per configured source, and a warn when a repository trusted at
#     agent-merges-all resolves it to 0 — the cool-off control disabled
#     entirely, which §7 risk 1 accepts the residual risk of only with both
#     compensating controls in force. ---------------------------------------
lc_config="$tmp/lc-config.json"
jq --arg slug "$slug" \
  '.merge_autonomy = "agent-merges-all" | .approver_app_id = "123456" | .approver_model_default = "claude-sonnet-5"
   | .repos = [{slug: $slug, sources: ["security", "abandoned-drafts"]}]' \
  "$base_config" > "$lc_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$lc_config" 2>&1)"
assert_contains "the shipped default landing_cool_off_hours is reported ok" \
  "[ ok ] landing_cool_off_hours is 24h" "$out"
assert_not_contains "  ... and agent-merges-all with the default cool-off in force draws no warning" \
  "landing_cool_off_hours 0" "$out"

lc_zero_config="$tmp/lc-zero-config.json"
jq '.landing_cool_off_hours = 0' "$lc_config" > "$lc_zero_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$lc_zero_config" 2>&1)"
assert_contains "landing_cool_off_hours 0 is reported ok, as a value (the sanity check is separate)" \
  "[ ok ] landing_cool_off_hours is 0h (no wait)" "$out"
assert_contains "  ... but agent-merges-all with it at 0 draws a warning naming both facts" \
  "[warn] $slug's merge_autonomy is \"agent-merges-all\" with landing_cool_off_hours 0 — a protected-path pull request lands the moment its critical-tier Approver review stands, with no fleet-day observation window (D18 WI-12)" \
  "$out"

lc_repo_override_config="$tmp/lc-repo-override-config.json"
jq --arg slug "$slug" \
  '.repos = [{slug: $slug, sources: ["security", "abandoned-drafts"], landing_cool_off_hours: 0}]' \
  "$lc_config" > "$lc_repo_override_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$lc_repo_override_config" 2>&1)"
assert_contains "a repo-level override is reported under its own label" \
  "[ ok ] $slug's landing_cool_off_hours override is 0h (no wait)" "$out"
assert_contains "  ... and still warns, resolved through the repo's own override" \
  "[warn] $slug's merge_autonomy is \"agent-merges-all\" with landing_cool_off_hours 0" "$out"

lc_routine_config="$tmp/lc-routine-config.json"
jq '.merge_autonomy = "agent-merges-routine" | .landing_cool_off_hours = 0' "$lc_config" > "$lc_routine_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$lc_routine_config" 2>&1)"
assert_not_contains "below agent-merges-all, landing_cool_off_hours 0 draws no warning — the control does not bind there" \
  "landing_cool_off_hours 0 —" "$out"

# --- The kill switch's own live state (requirement 2.3b), reported once per
#     run alongside state_repo's own access check ---------------------------
run_doctor
assert_contains "with no state_repo configured, the kill switch is reported not-set" \
  "[ ok ] the merge-autonomy kill switch is not set" "$out"

# With a state_repo configured the report has three ways to go
# (TD-PPagop-26081602), and doctor.sh's own branching — not
# merge_autonomy_kill_state's, which test/merge-autonomy.test.sh covers — is
# what decides among them: a probed clear reads not-set; a record served
# live reads SET whether or not it carries a `kind` (a flag file an operator
# set by hand carries none and is a real kill, not the synthesis); an
# unreadable flag with no cached copy reads "could not be confirmed clear",
# keyed on the fail-closed synthesis naming itself `kind: "fail-closed"`.
kill_config="$tmp/kill-config.json"
mkdir -p "$tmp/kill-state-dir"
jq --arg slug "$slug" --arg sd "$tmp/kill-state-dir" \
  '.repos = [] | .review.repos = [] | .state_repo = $slug | .state_dir = $sd' \
  "$base_config" > "$kill_config"
run_kill_doctor() {
  # Each case owns its cache: a live fetch in one would otherwise hand the
  # next a cached copy and change which branch it exercises.
  rm -rf "$tmp/kill-state-dir/fleet-cache"
  out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
    STUB_REPO_JSON='{"permissions":{"push":true},"archived":false}' \
    "$@" bash "$DOCTOR" --config "$kill_config" 2>&1)"
  rc=$?
}

run_kill_doctor
assert_contains "a flag-file 404 whose repo probe succeeds is reported not-set" \
  "[ ok ] the merge-autonomy kill switch is not set" "$out"

run_kill_doctor STUB_FLEET_FLAG_JSON='{"disabled_at":"2026-08-16T00:00:00Z","expires_at":null,"by":"an operator","reason":"drill","kind":"manual"}'
assert_contains "a real kill is reported SET, naming the command that clears it" \
  "[warn] the merge-autonomy kill switch is SET" "$out"

run_kill_doctor STUB_FLEET_FLAG_JSON='{"reason":"stop everything now","by":"an operator in a hurry","expires_at":null}'
assert_contains "a hand-set record with no kind at all is still reported SET" \
  "[warn] the merge-autonomy kill switch is SET" "$out"
assert_not_contains "and never as the fail-closed synthesis" \
  "could not be confirmed clear" "$out"

run_kill_doctor STUB_FLEET_FLAG_FAIL=1
assert_contains "an unreadable flag with no cache is reported unconfirmed, with the synthesis's own reason" \
  "[warn] the merge-autonomy kill switch could not be confirmed clear — state repo unreachable and no cached copy" "$out"
assert_not_contains "and not as a kill somebody set" \
  "the merge-autonomy kill switch is SET" "$out"

# --- The Approver identity's two sources of truth are reconciled ------------
# The token wrapper (requirement 14b) reads PULLWRIGHT_APPROVER_APP_ID from
# the environment; approver_app_id is the config declaration doctor already
# validates. Nothing else compares them, so doctor must: a set pair that
# differs means the node would mint as an App the configuration never named,
# with every consumer of the mismatch silent.
run_doctor PULLWRIGHT_APPROVER_APP_ID=999999
assert_contains "an env App id with no configured approver_app_id is a warn — wired but undeclared" \
  "[warn] PULLWRIGHT_APPROVER_APP_ID is set but approver_app_id is empty" "$out"
assert_eq "and doctor.sh still exits 0" "0" "$rc"

approver_env_config="$tmp/approver-env-config.json"
jq '.approver_app_id = "123456"' "$base_config" > "$approver_env_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" PULLWRIGHT_APPROVER_APP_ID=999999 \
  bash "$DOCTOR" --config "$approver_env_config" 2>&1)"
rc=$?
assert_contains "an env App id differing from the configured one fails, naming both ids" \
  '[fail] PULLWRIGHT_APPROVER_APP_ID is "999999" but approver_app_id is "123456"' "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" PULLWRIGHT_APPROVER_APP_ID=123456 \
  bash "$DOCTOR" --config "$approver_env_config" 2>&1)"
assert_contains "matching env and config App ids earn a positive ok" \
  "[ ok ] PULLWRIGHT_APPROVER_APP_ID matches approver_app_id" "$out"

run_doctor
assert_not_contains "with no env App id and none configured, doctor says nothing about the pair" \
  "PULLWRIGHT_APPROVER_APP_ID" "$out"

# A level above human whose environment carries no runtime credential is a
# warn, not a fail: the wrapper fails closed (exit 2, gate unreadable) and
# the Approver stage simply skips this pull request's App review rather than
# blocking it — but the operator who raised the level is waiting on
# approvals that never come.
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_contains "a level above human with no runtime credential in this environment warns" \
  "[warn] merge_autonomy is above human but the Approver's runtime credential is not present in this environment" "$out"

approver_key="$tmp/approver-key.pem"
printf 'not-really-a-key\n' > "$approver_key"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  PULLWRIGHT_APPROVER_APP_ID=123456 \
  PULLWRIGHT_APPROVER_INSTALLATION_ID=42 \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$approver_key" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_contains "a level above human with the full credential present earns the ok" \
  "[ ok ] the Approver's runtime credential is present and its key is readable" "$out"

run_doctor
assert_not_contains "at human, doctor stays silent about the runtime credential" \
  "Approver's runtime credential" "$out"

# --- Claude credentials ----------------------------------------------------

run_doctor STUB_CLAUDE_AUTH_JSON='{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'
assert_contains "loggedIn true is ok" "[ ok ] claude is authenticated" "$out"

run_doctor STUB_CLAUDE_AUTH_JSON='{"loggedIn":false}'
assert_contains "loggedIn false is a failure, distinguished from a parse failure" \
  "[fail] claude is not authenticated" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

run_doctor STUB_CLAUDE_NO_AUTH_SUBCOMMAND=1
assert_contains "a claude with no auth subcommand is a skip, not a failure" \
  "[skip] claude auth status did not succeed" "$out"
assert_not_contains "and is not reported as a failure" "[fail] claude" "$out"

# --- The rendered crontab ---------------------------------------------------

# CYCLE_MINUTE=1 makes the cycle (and therefore review) minute deterministic —
# 1, repeating every base_config's schedule.cycle_interval_minutes (15) —
# 1,16,31,46 — plus base_config's schedule.review_offset_minutes (29), past
# schedule.review_hour (3) — so the report's minute math is checked exactly,
# not just for the presence of expected substrings.
run_doctor CYCLE_MINUTE=1
assert_contains "a successful render reports the node name" "node " "$out"
assert_contains "and the cycle minute(s) CYCLE_MINUTE asks for, every cycle_interval_minutes" \
  "cycle at minute(s) 1,16,31,46 past" "$out"
assert_contains "and the review minute derived from cycle + review_offset_minutes" \
  "review at 30 past 3:00" "$out"
assert_contains "and the heartbeat cadence" "heartbeat every 5 min" "$out"
assert_contains "and the background timer minutes the config asks for" \
  "state sync push every 5 min, fetch every 7 min, log rotation at :19" "$out"
assert_contains "and an allowed, explicit CYCLE_MINUTE is named as the source" \
  "cycle minute set explicitly by CYCLE_MINUTE=1" "$out"
assert_eq "a clean render does not fail the run by itself" "0" "$rc"

# With CYCLE_MINUTE unset, the same report names the hash instead — the
# derivation the review flagged as a trap: doctor.sh's node name is
# $(hostname) unless NODE_NAME overrides it, so --config PATH against a config
# not yet deployed can hash onto a minute that means nothing on the real node.
run_doctor CYCLE_MINUTE=
assert_contains "an unset CYCLE_MINUTE is reported as hashed from the node name" \
  "cycle minute hashed from node name" "$out"
assert_not_contains "and not as explicit" "set explicitly by CYCLE_MINUTE" "$out"

# An out-of-range CYCLE_MINUTE falls back to the hash exactly like unset —
# the renderer's own WARNING path — and is reported as hashed, not explicit.
run_doctor CYCLE_MINUTE=999
assert_contains "an out-of-range CYCLE_MINUTE also falls back to the hash" \
  "cycle minute hashed from node name" "$out"
assert_not_contains "and is not reported as explicit either" \
  "set explicitly by CYCLE_MINUTE" "$out"

# A config with schedule values other than the fallback defaults proves the
# background-timer line reports what the config asks for, not the renderer's
# own defaults.
custom_schedule_config="$tmp/custom-schedule-config.json"
jq '.schedule.heartbeat_minutes = 11
    | .schedule.state_sync_push_minutes = 13
    | .schedule.state_sync_fetch_minutes = 17
    | .schedule.log_rotation_minute = 42' "$base_config" > "$custom_schedule_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" CYCLE_MINUTE=1 bash "$DOCTOR" --config "$custom_schedule_config" 2>&1)"
rc=$?
assert_contains "a custom heartbeat interval is reported, not the fallback default" \
  "heartbeat every 11 min" "$out"
assert_contains "and custom background timer minutes are reported, not the fallback defaults" \
  "state sync push every 13 min, fetch every 17 min, log rotation at :42" "$out"
assert_eq "a clean render against a custom schedule does not fail the run" "0" "$rc"

# The real renderer's own failure mode: schedule.excluded_minutes ruling out
# every minute of the hour leaves it nothing to hash the node's name onto.
all_excluded_config="$tmp/all-excluded-config.json"
jq '.schedule.excluded_minutes = [range(0;60)]' "$base_config" > "$all_excluded_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$all_excluded_config" 2>&1)"
rc=$?
assert_contains "a renderer that exits non-zero is a doctor.sh failure" \
  "[fail] deploy/docker/render-crontab.sh failed" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

# A missing template is reproduced with a trimmed copy of the repository —
# doctor.sh resolves the template relative to its own location, so there is
# no override to poke instead.
no_tmpl_app="$tmp/no-tmpl-app"
mkdir -p "$no_tmpl_app/scripts" "$no_tmpl_app/lib" "$no_tmpl_app/deploy/docker"
cp "$SCRIPT_DIR/scripts/doctor.sh" "$no_tmpl_app/scripts/"
cp "$SCRIPT_DIR/lib/config-schema.sh" "$SCRIPT_DIR/lib/model-id.sh" "$SCRIPT_DIR/lib/labels.sh" \
  "$no_tmpl_app/lib/"
cp "$SCRIPT_DIR/config.schema.json" "$no_tmpl_app/"
cp "$SCRIPT_DIR/deploy/docker/render-crontab.sh" "$no_tmpl_app/deploy/docker/"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$no_tmpl_app/scripts/doctor.sh" --config "$base_config" 2>&1)"
rc=$?
assert_contains "a missing crontab.tmpl is a skip, not a failure" \
  "[skip] deploy/docker/crontab.tmpl is missing" "$out"

# --- Repository priority: the nice reordering report ------------------------

run_doctor
assert_not_contains "no repo carries a non-zero nice, so the section prints no line" \
  "Repository priority" "$out"

niced_config="$tmp/niced-config.json"
jq '.repos[0].nice = -5' "$base_config" > "$niced_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$niced_config" 2>&1)"
assert_contains "a non-zero nice gets its own line, naming the repo and the weighting" \
  "[ ok ] $slug: nice -5 — effective age ×3.05, earlier attention" "$out"

# --- --offline still runs the crontab and nice checks, and skips the rest --

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$niced_config" --offline 2>&1)"
assert_contains "--offline still renders the crontab" "cycle at minute" "$out"
assert_contains "--offline still reports the background timer minutes" \
  "state sync push every 5 min, fetch every 7 min, log rotation at :19" "$out"
assert_contains "--offline still reports nice reordering" \
  "$slug: nice -5" "$out"
assert_contains "--offline skips write access" "[skip] every GitHub check (--offline)" "$out"
assert_contains "--offline skips Claude credentials" \
  "[skip] Claude credentials (--offline)" "$out"
# The stream-flushing probe is the one check in doctor.sh that spends, so
# --offline must skip it — and this suite must never be the thing that runs
# it. Its being reported skipped, by name, is what says it did not.
assert_contains "--offline skips the stream-flushing probe, the one check that spends" \
  "[skip] stream flushing (--offline" "$out"

# --- --unattended runs the full GitHub section but skips the two spending
#     checks, with wording distinct from --offline's, and writes
#     state_dir/.doctor-status.json for scripts/publish-dashboard.sh
#     (agent-ops#543) --------------------------------------------------------

unattended_state_dir="$tmp/unattended-state-dir"
mkdir -p "$unattended_state_dir"
unattended_config="$tmp/unattended-config.json"
jq --arg sd "$unattended_state_dir" '.state_dir = $sd' "$niced_config" > "$unattended_config"

out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON='{"permissions":{"push":true},"archived":false}' \
  bash "$DOCTOR" --config "$unattended_config" --unattended 2>&1)"
assert_contains "--unattended still renders the crontab" "cycle at minute" "$out"
assert_contains "--unattended still runs the GitHub section (write access is checked)" \
  "is writable — the token can push claim branches" "$out"
assert_contains "--unattended skips Claude credentials, for its own reason" \
  "[skip] Claude credentials (--unattended" "$out"
assert_not_contains "not with --offline's wording" "[skip] Claude credentials (--offline)" "$out"
assert_contains "--unattended skips the stream-flushing probe, the one check that spends" \
  "[skip] stream flushing (--unattended" "$out"
assert_not_contains "not with --offline's wording either" "[skip] stream flushing (--offline" "$out"

status_file="$unattended_state_dir/.doctor-status.json"
assert_eq "--unattended writes state_dir/.doctor-status.json" "1" \
  "$( [[ -f "$status_file" ]] && echo 1 || echo 0 )"
assert_eq "its verdict is warn (the stub labels endpoint always answers empty)" \
  "warn" "$(jq -r '.verdict' "$status_file" 2>/dev/null)"
assert_eq "its fails array is empty in this fixture" "[]" \
  "$(jq -c '.fails' "$status_file" 2>/dev/null)"
assert_eq "its warns array is non-empty in this fixture" "true" \
  "$(jq '(.warns | length) > 0' "$status_file" 2>/dev/null)"
assert_eq "its timestamp is a real UTC instant" "1" \
  "$(jq -r '.timestamp' "$status_file" 2>/dev/null | grep -Ecq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; echo $((1 - $?)))"
assert_eq "no GitHub-Authentication-Token-Expiration header (this fixture's stub sends none) leaves token_expiry null" \
  "null" "$(jq -c '.token_expiry' "$status_file" 2>/dev/null)"

# --- Fine-grained PAT expiry (agent-ops#694) --------------------------------

rm -f "$status_file"
# "+12 hours" of slack past the 3-day mark absorbs the few seconds between
# minting this header and doctor.sh reading its own clock — without it, a
# header timed exactly 3 days out could floor to 2 by the time doctor.sh
# computes days_remaining a moment later.
future_header="$(date -u -d '+3 days +12 hours' '+%Y-%m-%d %H:%M:%S UTC')"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON='{"permissions":{"push":true},"archived":false}' \
  STUB_TOKEN_EXPIRY_HEADER="$future_header" \
  bash "$DOCTOR" --config "$unattended_config" --unattended 2>&1)"
assert_contains "a token under the 7-day threshold is reported as a warning" \
  "this node's fine-grained PAT expires in 3 day(s)" "$out"
assert_contains "  ... naming the warning threshold" \
  "under the 7-day warning threshold" "$out"
assert_eq "  ... and the artefact carries the same day count" \
  "3" "$(jq -r '.token_expiry.days_remaining' "$status_file" 2>/dev/null)"
assert_eq "  ... and its own verdict is (at least) warn" \
  "true" "$(jq -r '.verdict == "warn" or .verdict == "fail"' "$status_file" 2>/dev/null)"
assert_eq "  ... and the same message rides in the artefact's warns[], same as any other warn()" \
  "true" "$(jq '.warns | any(test("fine-grained PAT expires in 3 day"))' "$status_file" 2>/dev/null)"

rm -f "$status_file"
far_future_header="$(date -u -d '+90 days +12 hours' '+%Y-%m-%d %H:%M:%S UTC')"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON='{"permissions":{"push":true},"archived":false}' \
  STUB_TOKEN_EXPIRY_HEADER="$far_future_header" \
  bash "$DOCTOR" --config "$unattended_config" --unattended 2>&1)"
assert_contains "a token well above the threshold is reported ok, not as a warning" \
  "[ ok ] this node's fine-grained PAT expires in 90 day(s)" "$out"
assert_not_contains "  ... and never mentions the warning threshold" \
  "under the 7-day warning threshold" "$out"
assert_eq "  ... and the artefact still records the day count" \
  "90" "$(jq -r '.token_expiry.days_remaining' "$status_file" 2>/dev/null)"

rm -f "$status_file"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON='{"permissions":{"push":true},"archived":false}' \
  STUB_RATE_LIMIT_FAIL=1 \
  bash "$DOCTOR" --config "$unattended_config" --unattended 2>&1)"; rc=$?
assert_not_contains "an unreadable /rate_limit call is not reported as a failure or warning" \
  "fine-grained PAT expires" "$out"
assert_eq "  ... and doctor.sh still exits 0 (this fixture's only other finding is a warning)" \
  "0" "$rc"
assert_eq "  ... and the artefact's token_expiry stays null" \
  "null" "$(jq -c '.token_expiry' "$status_file" 2>/dev/null)"

rm -f "$status_file"
out_plain="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" \
  STUB_REPO_JSON='{"permissions":{"push":true},"archived":false}' \
  bash "$DOCTOR" --config "$unattended_config" 2>&1)"
assert_eq "an ordinary run (no --unattended) does not write the status file" "0" \
  "$( [[ -f "$status_file" ]] && echo 1 || echo 0 )"
assert_contains "and its Claude section actually runs (neither --unattended nor --offline)" \
  "[ ok ] claude is authenticated" "$out_plain"

# --- Cache directory cleanup (issue #510) ------------------------------------
#
# doctor.sh sources lib/issue-priority.sh, whose ISSUE_PRIORITY_CACHE_DIR used
# to be created at source time and never removed — a leaked directory on
# every run, including one that exits before any check runs at all. TMPDIR is
# pointed at an isolated, empty directory here so "did doctor.sh leave
# anything behind" is a question this suite can actually answer, rather than
# one lost among whatever else already lives under the real /tmp.
doctor_tmpdir="$tmp/doctor-tmpdir"
mkdir -p "$doctor_tmpdir"

run_doctor_tmp() {  # run_doctor_tmp [doctor.sh args...]
  out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" TMPDIR="$doctor_tmpdir" bash "$DOCTOR" "$@" 2>&1)"
  rc=$?
}
assert_empty_tmpdir() {
  local desc="$1" leftover
  leftover="$(find "$doctor_tmpdir" -mindepth 1 2>/dev/null)"
  assert_eq "$desc" "" "$leftover"
}

run_doctor_tmp --config "$base_config"
assert_empty_tmpdir "a clean pass leaves no cache directory under TMPDIR"

run_doctor_tmp --help
assert_empty_tmpdir "--help, which exits before any check runs, still cleans up"

run_doctor_tmp --config /nonexistent/config.json
assert_empty_tmpdir "an unreadable config, which exits at argument time, still cleans up"

rm -rf "$doctor_tmpdir"

# --- Directories: the free-space floor is configurable (agent-ops#756) -----
#
# min_free_workspace_bytes set absurdly high forces the warning
# deterministically, with no need to fake `df`: this host's real free space,
# whatever it actually is, is certainly below an exbibyte. Exercises the same
# lib/disk-space.sh requirement 2.0c's own stand-down reads
# (test/disk-space.test.sh, test/disk-space-wiring.test.sh), from doctor.sh's
# side of the shared floor.
huge_floor_config="$tmp/huge-floor-config.json"
jq '.min_free_workspace_bytes = 1152921504606846976' "$base_config" > "$huge_floor_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$huge_floor_config" 2>&1)"
rc=$?
assert_contains "a floor above real free space warns on state_dir, naming the key's own figure" \
  "state_dir: " "$out"
assert_contains "…and on workspace_root too" \
  "workspace_root: " "$out"
assert_contains "…stating the configured floor in MiB (1 EiB = 1099511627776 MiB)" \
  "1099511627776 MiB this cycle needs" "$out"
assert_eq "a warning alone (not a failure) still exits 0" "0" "$rc"

zero_floor_config="$tmp/zero-floor-config.json"
jq '.min_free_workspace_bytes = 0' "$base_config" > "$zero_floor_config"
out="$(env -u PULLWRIGHT_APPROVER_APP_ID -u PULLWRIGHT_APPROVER_INSTALLATION_ID -u PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$zero_floor_config" 2>&1)"
assert_contains "0 turns the warning off entirely, regardless of real free space" \
  "[ ok ] state_dir" "$out"
assert_contains "…for workspace_root too" \
  "[ ok ] workspace_root" "$out"

# --- shellcheck ---

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$DOCTOR" >/dev/null; then
    pass "scripts/doctor.sh is shellcheck-clean"
  else
    printf 'FAIL - scripts/doctor.sh is shellcheck-clean\n'
    shellcheck -x "$DOCTOR"
    failures=$(( failures + 1 ))
  fi
else
  printf 'skip - shellcheck not on PATH\n'
fi

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
