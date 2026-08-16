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
# themselves untested. No real network call is possible regardless, because
# gh and claude never resolve to anything but the stubs below.
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
#     would need to arbitrate. ---
slug="acme-org/target-repo"
base_config="$tmp/base-config.json"
jq --arg slug "$slug" '
  .repos = [{slug: $slug, sources: ["security"]}]
  | .project_review.repos = []
  | .state_repo = ""
  | .enabler_model = ""
  | .enabler_assignee = ""
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
  out="$(env PATH="$stub_bin:$PATH" "${env_pairs[@]}" \
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
# Implementor does against a target repo, so a review repo the token can read
# but not push to loses the review the same way a target repo loses an item.
review_config="$tmp/review-config.json"
jq --arg slug "$slug" '.repos = [] | .project_review.repos = [{slug: $slug}]' "$base_config" > "$review_config"
out="$(env PATH="$stub_bin:$PATH" STUB_REPO_JSON='{"permissions":{"push":false},"archived":false}' \
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
out="$(env PATH="$stub_bin:$PATH" STUB_REPO_JSON='{"archived":false}' \
  bash "$DOCTOR" --config "$state_repo_config" 2>&1)"
assert_contains "state_repo with no visible .permissions is a skip, not a fail" \
  "[skip] $slug's write permission is not visible to this token" "$out"

out="$(env PATH="$stub_bin:$PATH" STUB_REPO_JSON='{"permissions":{"push":true},"archived":false}' \
  bash "$DOCTOR" --config "$state_repo_config" 2>&1)"
assert_contains "state_repo writable is reported with its own wording" \
  "[ ok ] $slug is readable and writable — the fleet's shared state can replicate" "$out"

out="$(env PATH="$stub_bin:$PATH" STUB_REPO_JSON='{"permissions":{"push":false},"archived":false}' \
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
out="$(env PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":true}}]}' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
rc=$?
assert_contains "agent-merges-routine with code-owner review still required fails, naming the repo and level" \
  "[fail] $slug's merge_autonomy is \"agent-merges-routine\" but its default-branch ruleset still requires code-owner review" "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

out="$(env PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":false}}]}' \
  bash "$DOCTOR" --config "$ma_config" 2>&1)"
assert_not_contains "agent-merges-routine with code-owner review off does not fail" \
  "still requires code-owner review" "$out"
assert_contains "and positively confirms the pairing, naming the repo and level" \
  "[ ok ] $slug's merge_autonomy is \"agent-merges-routine\" and its default-branch ruleset requires no code-owner review" "$out"

out="$(env PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":true}}]}' \
  bash "$DOCTOR" --config "$base_config" 2>&1)"
assert_not_contains "merge_autonomy at the default (human) is unaffected by code-owner review either way" \
  "still requires code-owner review" "$out"
assert_not_contains "and stays silent below the routine tier rather than narrate an inapplicable pairing" \
  "requires no code-owner review" "$out"

ma_approves_config="$tmp/ma-approves-config.json"
jq '.merge_autonomy = "agent-approves" | .approver_app_id = "123456" | .approver_model_default = "claude-sonnet-5"' "$base_config" > "$ma_approves_config"
out="$(env PATH="$stub_bin:$PATH" \
  STUB_RULESETS_JSON="[$noise_ruleset_38,{\"id\":3,\"target\":\"branch\",\"enforcement\":\"active\"}]" \
  STUB_RULESET_DETAIL_JSON='{"name":"default","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":true}}]}' \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_not_contains "agent-approves (below the routine tier) is unaffected by code-owner review" \
  "still requires code-owner review" "$out"
assert_not_contains "and earns no code-owner ok line either" \
  "requires no code-owner review" "$out"

# --- D18 WI-5 (requirement 8b): merge_autonomy above human needs
#     approver_model_default too, the same pairing approver_app_id already
#     gets — the Approver stage reads it empty as "disabled", so a level
#     above human configured with it empty would silently gain no App review
#     at all, and doctor is where an operator can still see that. -----------
ma_no_model_config="$tmp/ma-no-model-config.json"
jq '.merge_autonomy = "agent-approves" | .approver_app_id = "123456"' "$base_config" > "$ma_no_model_config"
out="$(env PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$ma_no_model_config" 2>&1)"
rc=$?
assert_contains "agent-approves with no approver_model_default fails, naming the level" \
  '[fail] merge_autonomy is "agent-approves" with no approver_model_default configured' "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

out="$(env PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_not_contains "agent-approves with approver_model_default set does not fail on this pairing" \
  "no approver_model_default configured" "$out"
assert_contains "  ... and positively confirms the level, same as it did before this pairing existed" \
  '[ ok ] merge_autonomy is "agent-approves"' "$out"

run_doctor
assert_not_contains "merge_autonomy at the default (human) needs no approver_model_default" \
  "no approver_model_default configured" "$out"

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
  out="$(env PATH="$stub_bin:$PATH" \
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
out="$(env PATH="$stub_bin:$PATH" PULLWRIGHT_APPROVER_APP_ID=999999 \
  bash "$DOCTOR" --config "$approver_env_config" 2>&1)"
rc=$?
assert_contains "an env App id differing from the configured one fails, naming both ids" \
  '[fail] PULLWRIGHT_APPROVER_APP_ID is "999999" but approver_app_id is "123456"' "$out"
assert_eq "and doctor.sh exits 1" "1" "$rc"

out="$(env PATH="$stub_bin:$PATH" PULLWRIGHT_APPROVER_APP_ID=123456 \
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
out="$(env PATH="$stub_bin:$PATH" \
  bash "$DOCTOR" --config "$ma_approves_config" 2>&1)"
assert_contains "a level above human with no runtime credential in this environment warns" \
  "[warn] merge_autonomy is above human but the Approver's runtime credential is not present in this environment" "$out"

approver_key="$tmp/approver-key.pem"
printf 'not-really-a-key\n' > "$approver_key"
out="$(env PATH="$stub_bin:$PATH" \
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
out="$(env PATH="$stub_bin:$PATH" CYCLE_MINUTE=1 bash "$DOCTOR" --config "$custom_schedule_config" 2>&1)"
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
out="$(env PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$all_excluded_config" 2>&1)"
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
out="$(env PATH="$stub_bin:$PATH" bash "$no_tmpl_app/scripts/doctor.sh" --config "$base_config" 2>&1)"
rc=$?
assert_contains "a missing crontab.tmpl is a skip, not a failure" \
  "[skip] deploy/docker/crontab.tmpl is missing" "$out"

# --- Repository priority: the nice reordering report ------------------------

run_doctor
assert_not_contains "no repo carries a non-zero nice, so the section prints no line" \
  "Repository priority" "$out"

niced_config="$tmp/niced-config.json"
jq '.repos[0].nice = -5' "$base_config" > "$niced_config"
out="$(env PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$niced_config" 2>&1)"
assert_contains "a non-zero nice gets its own line, naming the repo and the weighting" \
  "[ ok ] $slug: nice -5 — effective age ×3.05, earlier attention" "$out"

# --- --offline still runs the crontab and nice checks, and skips the rest --

out="$(env PATH="$stub_bin:$PATH" bash "$DOCTOR" --config "$niced_config" --offline 2>&1)"
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
