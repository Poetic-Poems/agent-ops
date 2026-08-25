#!/usr/bin/env bash
#
# test/escalation-webhook.test.sh — regression test for requirement 2m
# (TD-PPagop-26082304): the credential-independent webhook fallback inside
# `create_escalation_issue`.
#
# Every escalation route in this repository — requirement 2.0b's auth-failure
# check, 1c's usage-limit freeze, requirement 2.7's crash loop — files through
# `create_escalation_issue`, which reaches GitHub with the same `GH_TOKEN` an
# escalation's own trigger can have just shown GitHub rejects. For 2.0b that
# is the *expected* path, not an edge case: every cycle, for as long as the
# token stays dead, the escalation issue cannot be filed and nobody outside
# the node is told. `escalation_webhook_notify`, called from inside
# `create_escalation_issue` on every one of its failure returns, is the fix —
# and living inside the shared function is what makes it apply to all three
# routes (and any future one) without each call site having to know it needs
# it.
#
# `create_escalation_issue` and `escalation_webhook_notify` are lifted
# verbatim out of lib/enabler.sh, the way test/cycle-state.test.sh lifts its
# own functions, so these assertions are about the shipped code rather than a
# reimplementation that could drift from it.
#
# No network: `gh` and `curl` are both stubs recording the argv (and, for
# `curl`, the POSTed body) they were handed.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/escalation-webhook.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENABLER_LIB="$SCRIPT_DIR/lib/enabler.sh"

failures=0
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual: %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

extract_function() {  # extract_function <name>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$ENABLER_LIB"
}

notify_src="$(extract_function escalation_webhook_notify)"
create_src="$(extract_function create_escalation_issue)"
if [[ "$notify_src" != *"escalation_webhook_notify()"* ]]; then
  echo "FAIL - could not extract escalation_webhook_notify from lib/enabler.sh (renamed or moved?)" >&2
  exit 1
fi
if [[ "$create_src" != *"create_escalation_issue()"* ]]; then
  echo "FAIL - could not extract create_escalation_issue from lib/enabler.sh (renamed or moved?)" >&2
  exit 1
fi
if [[ "$create_src" != *"escalation_webhook_notify"* ]]; then
  echo "FAIL - create_escalation_issue no longer calls escalation_webhook_notify on a failure path" >&2
  exit 1
fi

# run_case WEBHOOK_URL GH_LIST_JSON GH_CREATE_MODE CURL_MODE REPO ITEM LABEL TITLE BODY
# GH_CREATE_MODE is "succeed" (both attempts print a URL) or "fail" (both
# attempts print nothing, as a real 401'd `gh issue create` would). Writes the
# body to a fresh file, evals the two extracted functions with `gh`/`curl`/
# `labels_ensure_role`/`log_event` stubbed, calls create_escalation_issue, and
# prints "<rc>\t<stdout>".
run_case() {
  local webhook_url="$1" gh_list_json="$2" gh_create_mode="$3" curl_mode="$4" \
        repo="$5" item="$6" label="$7" title="$8" body="$9"
  local body_file="$tmp_dir/body-$$-$RANDOM.md"
  printf '%s' "$body" > "$body_file"
  : > "$tmp_dir/gh_calls"
  : > "$tmp_dir/curl_calls"
  : > "$tmp_dir/curl_payload"
  : > "$tmp_dir/events"
  (
    set -uo pipefail
    # shellcheck disable=SC2034  # consumed by $notify_src/$create_src below, invisible to a static reader
    escalation_webhook_url="$webhook_url"
    # shellcheck disable=SC2034  # consumed by $notify_src/$create_src below, invisible to a static reader
    cycle_dir="$tmp_dir"
    # shellcheck disable=SC2034  # consumed by $notify_src below, invisible to a static reader
    node_name="test-node"
    # shellcheck disable=SC2034  # consumed by $notify_src below, invisible to a static reader
    cycle_id="20260101T000000Z-test-node-1"
    # shellcheck disable=SC2034  # consumed by $create_src below, invisible to a static reader
    enabler_assignee="ops-bot"
    # shellcheck disable=SC2034  # consumed by $create_src below, invisible to a static reader
    CONFIG_FILE=""
    # shellcheck disable=SC2034  # consumed by $create_src below, invisible to a static reader
    SCHEMA_FILE=""

    # shellcheck disable=SC2317  # called via eval below
    labels_ensure_role() { return 0; }

    # shellcheck disable=SC2317  # called via eval below
    log_event() { printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$tmp_dir/events"; }

    # shellcheck disable=SC2317  # called via eval below
    gh() {
      printf '%s\n' "$*" >> "$tmp_dir/gh_calls"
      case "$1 $2" in
        "issue list")
          printf '%s' "$GH_LIST_JSON"
          ;;
        "issue create")
          [[ "$GH_CREATE_MODE" == succeed ]] || return 1
          printf 'https://github.com/acme/agent-ops/issues/99\n'
          ;;
        *)
          return 1
          ;;
      esac
    }
    export GH_LIST_JSON="$gh_list_json" GH_CREATE_MODE="$gh_create_mode"

    # shellcheck disable=SC2317  # called via eval below
    curl() {
      printf '%s\n' "$*" >> "$tmp_dir/curl_calls"
      local args=("$@") i
      for i in "${!args[@]}"; do
        if [[ "${args[$i]}" == "--data-binary" ]]; then
          printf '%s' "${args[$((i+1))]}" > "$tmp_dir/curl_payload"
        fi
      done
      [[ "$CURL_MODE" == succeed ]]
    }
    export CURL_MODE="$curl_mode"

    eval "$notify_src"
    eval "$create_src"

    out="$(create_escalation_issue "$repo" "$item" "$label" "$title" "$body_file")"
    rc="$?"
    printf '%s\t%s' "$rc" "$out"
  )
}

# --- no webhook configured: a total filing failure stays a plain failure,
# and nothing is ever attempted over HTTP -----------------------------------

result="$(run_case "" "[]" fail succeed \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "GitHub said: Bad credentials (HTTP 401)")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "no escalation_webhook_url: create_escalation_issue still returns 1 on a filing failure" "1" "$rc"
assert_eq "…and prints nothing" "" "$out"
assert_eq "…and never calls curl" "0" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
assert_eq "…and logs no webhook-related event" "" "$(cat "$tmp_dir/events")"

# --- webhook configured, filing fails on both attempts: the fallback fires
# exactly once, to the configured URL, carrying reason/detail/item ----------

result="$(run_case "https://hooks.example.test/escalate" "[]" fail succeed \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "GitHub said: Bad credentials (HTTP 401)")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "with escalation_webhook_url set: create_escalation_issue still returns 1" "1" "$rc"
assert_eq "…and still prints nothing (the fallback is not a success)" "" "$out"
assert_eq "…curl is called exactly once" "1" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
assert_contains "…POSTed to the configured URL" \
  "https://hooks.example.test/escalate" "$(cat "$tmp_dir/curl_calls")"
payload="$(cat "$tmp_dir/curl_payload")"
assert_eq "…payload's reason is the failed issue's own title" \
  "GitHub credentials rejected" "$(jq -r '.reason' <<<"$payload")"
assert_eq "…payload's detail is the failed issue's own body" \
  "GitHub said: Bad credentials (HTTP 401)" "$(jq -r '.detail' <<<"$payload")"
assert_eq "…payload names the item" \
  "auth-failure:test-node" "$(jq -r '.item' <<<"$payload")"
assert_eq "…payload names the repo" \
  "acme/agent-ops" "$(jq -r '.repo' <<<"$payload")"
assert_eq "…payload names the node" \
  "test-node" "$(jq -r '.node' <<<"$payload")"
assert_eq "…payload names the cycle" \
  "20260101T000000Z-test-node-1" "$(jq -r '.cycle' <<<"$payload")"

# --- webhook configured, but filing actually succeeds: no fallback needed,
# so nothing is POSTed ------------------------------------------------------

result="$(run_case "https://hooks.example.test/escalate" "[]" succeed succeed \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "detail")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "a successful filing returns 0" "0" "$rc"
assert_eq "…with the issue number and URL" \
  $'99\thttps://github.com/acme/agent-ops/issues/99' "$out"
assert_eq "…and curl is never called" "0" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"

# --- webhook configured, but the dedup guard finds an existing issue: no
# creation is attempted and nothing is POSTed --------------------------------

existing_list='[{"number":77,"url":"https://github.com/acme/agent-ops/issues/77","body":"ref: auth-failure:test-node"}]'
result="$(run_case "https://hooks.example.test/escalate" "$existing_list" fail succeed \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "detail")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "a duplicate escalation returns 0" "0" "$rc"
assert_eq "…with the existing issue number and URL" \
  $'77\thttps://github.com/acme/agent-ops/issues/77' "$out"
assert_eq "…never attempting gh issue create" \
  "no" "$(if grep -q '^issue create' "$tmp_dir/gh_calls"; then echo yes; else echo no; fi)"
assert_eq "…and curl is never called" "0" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"

# --- the webhook itself is unreachable: the caller's own return value is
# unaffected, and the failure is recorded locally for a human to find -------

result="$(run_case "https://hooks.example.test/escalate" "[]" fail fail \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "detail")"
rc="${result%%$'\t'*}"
assert_eq "a webhook POST failure does not change create_escalation_issue's own verdict" "1" "$rc"
assert_contains "…and logs a local warning naming the item" \
  "auth-failure:test-node" "$(grep '^warning' "$tmp_dir/events" || true)"

echo
if (( failures == 0 )); then
  echo "All escalation-webhook assertions passed."
  exit 0
else
  echo "$failures escalation-webhook assertion(s) FAILED."
  exit 1
fi
