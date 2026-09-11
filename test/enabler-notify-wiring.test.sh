#!/usr/bin/env bash
#
# test/enabler-notify-wiring.test.sh — regression test for requirement 2m's
# `escalation` class as wired into `lib/enabler.sh` (issue #1279).
#
# test/notify.test.sh covers `notify_post` itself — the classes, the alias,
# the per-(event, key) rate limit, the failure paths. This file covers the
# other half: that `create_escalation_issue` actually calls it, on the right
# paths, with the right event, and — the part that matters most — that adding
# a notification to a function every escalation route files through changed
# nothing about what that function returns to its callers.
#
# It is the successor to test/escalation-webhook.test.sh (TD-PPagop-26082304),
# which covered the same wiring back when the webhook was a filing-failure
# fallback and nothing else. The contract it guarded still holds and is
# re-asserted here against the new event names: a failed filing still returns
# 1 and still prints nothing, a successful one still prints `<number>\t<url>`,
# and the duplicate-guard path still short-circuits before either.
#
# Three routes reach GitHub through `create_escalation_issue` with the same
# `GH_TOKEN` an escalation's own trigger may have just shown GitHub rejects —
# requirement 2.0b's auth-failure check, 1c's usage-limit freeze, requirement
# 2.7's crash loop — which is why the notification lives inside the shared
# function rather than at each call site.
#
# `create_escalation_issue` and `escalation_webhook_notify` are lifted
# verbatim out of lib/enabler.sh, the way test/escalation-webhook.test.sh did
# before it and test/cycle-state.test.sh still does, so these assertions are
# about the shipped code rather than a reimplementation that could drift from
# it. lib/notify.sh is sourced whole: it is standalone by design.
#
# No network: `gh` and `curl` are both stubs recording the argv (and, for
# `curl`, the POSTed body) they were handed.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/enabler-notify-wiring.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENABLER_LIB="$SCRIPT_DIR/lib/enabler.sh"
NOTIFY_LIB="$SCRIPT_DIR/lib/notify.sh"

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
if [[ "$create_src" != *"notify_post_cycle \"escalation-filed\""* ]]; then
  echo "FAIL - create_escalation_issue no longer posts escalation-filed on its create path" >&2
  exit 1
fi

# run_case WEBHOOK_URL EVENTS_JSON GH_LIST_JSON GH_CREATE_MODE CURL_MODE \
#          REPO ITEM LABEL TITLE BODY
# GH_CREATE_MODE is "succeed" (both attempts print a URL) or "fail" (both
# attempts print nothing, as a real 401'd `gh issue create` would). Writes the
# body to a fresh file, sources lib/notify.sh and evals the two extracted
# functions with `gh`/`curl`/`labels_ensure_role`/`log_event` stubbed, calls
# create_escalation_issue, and prints "<rc>\t<stdout>".
#
# Every case gets a fresh `log_file`: notify_post's own rate limit is
# event-sourced over that log, so a shared one would let an earlier case's
# `notify-sent` suppress a later case's POST.
run_case() {
  local webhook_url="$1" events_json="$2" gh_list_json="$3" gh_create_mode="$4" \
        curl_mode="$5" repo="$6" item="$7" label="$8" title="$9" body="${10}"
  local body_file="$tmp_dir/body-$$-$RANDOM.md"
  printf '%s' "$body" > "$body_file"
  : > "$tmp_dir/gh_calls"
  : > "$tmp_dir/curl_calls"
  : > "$tmp_dir/curl_payload"
  : > "$tmp_dir/events"
  : > "$tmp_dir/log.jsonl"
  (
    set -uo pipefail
    # shellcheck disable=SC2034  # consumed by notify_post_cycle, invisible to a static reader
    notify_webhook_url="$webhook_url"
    # shellcheck disable=SC2034  # consumed by notify_post_cycle, invisible to a static reader
    notify_events_json="$events_json"
    # shellcheck disable=SC2034  # consumed by notify_post_cycle, invisible to a static reader
    notify_min_interval_seconds=600
    # shellcheck disable=SC2034  # consumed by notify_post_cycle, invisible to a static reader
    log_file="$tmp_dir/log.jsonl"
    # shellcheck disable=SC2034  # consumed by $create_src below, invisible to a static reader
    cycle_dir="$tmp_dir"
    # shellcheck disable=SC2034  # consumed by notify_post_cycle, invisible to a static reader
    node_name="test-node"
    # shellcheck disable=SC2034  # consumed by notify_post_cycle, invisible to a static reader
    cycle_id="20260101T000000Z-test-node-1"
    # shellcheck disable=SC2034  # consumed by $create_src below, invisible to a static reader
    enabler_assignee="ops-bot"
    # shellcheck disable=SC2034  # consumed by $create_src below, invisible to a static reader
    CONFIG_FILE=""
    # shellcheck disable=SC2034  # consumed by $create_src below, invisible to a static reader
    SCHEMA_FILE=""

    # shellcheck disable=SC2317  # called from the extracted sources below
    labels_ensure_role() { return 0; }

    # shellcheck disable=SC2317  # called from the extracted sources below
    log_event() { printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$tmp_dir/events"; }

    # shellcheck disable=SC2317  # called from the extracted sources below
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

    # shellcheck disable=SC2317  # called from lib/notify.sh below
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

    # shellcheck source=lib/notify.sh
    . "$NOTIFY_LIB"
    eval "$notify_src"
    eval "$create_src"

    out="$(create_escalation_issue "$repo" "$item" "$label" "$title" "$body_file")"
    rc="$?"
    printf '%s\t%s' "$rc" "$out"
  )
}

all_events='["escalation","pager","fleet-standdown"]'

# --- no webhook configured: a total filing failure stays a plain failure,
# and nothing is ever attempted over HTTP -----------------------------------

result="$(run_case "" "$all_events" "[]" fail succeed \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "GitHub said: Bad credentials (HTTP 401)")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "no notify_webhook_url: create_escalation_issue still returns 1 on a filing failure" "1" "$rc"
assert_eq "…and prints nothing" "" "$out"
assert_eq "…and never calls curl" "0" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
assert_eq "…and logs nothing on the notify channel" "" "$(cat "$tmp_dir/log.jsonl")"

# --- webhook configured, filing fails on both attempts: escalation-unfiled
# fires exactly once, to the configured URL, in the new body shape ----------

result="$(run_case "https://hooks.example.test/escalate" "$all_events" "[]" fail succeed \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "GitHub said: Bad credentials (HTTP 401)")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "with notify_webhook_url set: create_escalation_issue still returns 1" "1" "$rc"
assert_eq "…and still prints nothing (a notification is not a filing)" "" "$out"
assert_eq "…curl is called exactly once" "1" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
assert_contains "…POSTed to the configured URL" \
  "https://hooks.example.test/escalate" "$(cat "$tmp_dir/curl_calls")"
payload="$(cat "$tmp_dir/curl_payload")"
assert_eq "…the event is escalation-unfiled" \
  "escalation-unfiled" "$(jq -r '.event' <<<"$payload")"
assert_eq "…the key is <repo>#<item>" \
  "acme/agent-ops#auth-failure:test-node" "$(jq -r '.key' <<<"$payload")"
assert_eq "…the title is the failed issue's own title" \
  "GitHub credentials rejected" "$(jq -r '.title' <<<"$payload")"
assert_eq "…the detail is the failed issue's own body" \
  "GitHub said: Bad credentials (HTTP 401)" "$(jq -r '.detail' <<<"$payload")"
assert_eq "…the payload names the repo" \
  "acme/agent-ops" "$(jq -r '.repo' <<<"$payload")"
assert_eq "…the payload names the node" \
  "test-node" "$(jq -r '.node' <<<"$payload")"
assert_eq "…and notify-sent is logged" \
  "notify-sent" "$(jq -r 'select(.event | startswith("notify-")) | .event' "$tmp_dir/log.jsonl")"

# --- the escalation class is switched off in notify_events: nothing is
# POSTed, and the caller's own verdict is still the filing's ----------------

result="$(run_case "https://hooks.example.test/escalate" '["pager"]' "[]" fail succeed \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "detail")"
rc="${result%%$'\t'*}"
assert_eq "escalation absent from notify_events: create_escalation_issue still returns 1" "1" "$rc"
assert_eq "…and curl is never called" "0" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
assert_eq "…and nothing is logged, not even a suppression" "" "$(cat "$tmp_dir/log.jsonl")"

# --- filing succeeds: escalation-filed is POSTed, and the function's own
# stdout — which every caller parses back — is untouched by it --------------

result="$(run_case "https://hooks.example.test/escalate" "$all_events" "[]" succeed succeed \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "detail")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "a successful filing returns 0" "0" "$rc"
assert_eq "…printing the issue number and URL, and nothing the notification added" \
  $'99\thttps://github.com/acme/agent-ops/issues/99' "$out"
assert_eq "…curl is called exactly once" "1" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
payload="$(cat "$tmp_dir/curl_payload")"
assert_eq "…the event is escalation-filed" \
  "escalation-filed" "$(jq -r '.event' <<<"$payload")"
assert_eq "…carrying the new issue's own URL" \
  "https://github.com/acme/agent-ops/issues/99" "$(jq -r '.url' <<<"$payload")"

# --- the dedup guard finds an existing issue: no creation is attempted, and
# nothing is POSTed — a fault already escalated is not a fresh page ---------

existing_list='[{"number":77,"url":"https://github.com/acme/agent-ops/issues/77","body":"ref: auth-failure:test-node"}]'
result="$(run_case "https://hooks.example.test/escalate" "$all_events" "$existing_list" fail succeed \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "detail")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "a duplicate escalation returns 0" "0" "$rc"
assert_eq "…with the existing issue number and URL" \
  $'77\thttps://github.com/acme/agent-ops/issues/77' "$out"
assert_eq "…never attempting gh issue create" \
  "no" "$(if grep -q '^issue create' "$tmp_dir/gh_calls"; then echo yes; else echo no; fi)"
assert_eq "…and curl is never called (the duplicate-guard path posts nothing)" \
  "0" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"

# --- the webhook itself is unreachable: the caller's own return value is
# unaffected, and the failure is recorded locally for a human to find -------

result="$(run_case "https://hooks.example.test/escalate" "$all_events" "[]" fail fail \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "detail")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "a webhook POST failure does not change create_escalation_issue's own verdict" "1" "$rc"
assert_eq "…and still prints nothing" "" "$out"
assert_eq "…logging notify-failed locally" \
  "notify-failed" "$(jq -r 'select(.event | startswith("notify-")) | .event' "$tmp_dir/log.jsonl")"
assert_contains "…naming the key it could not deliver" \
  "acme/agent-ops#auth-failure:test-node" "$(cat "$tmp_dir/log.jsonl")"

# --- a POST failure on the *success* path cannot swallow the issue the
# filing actually created --------------------------------------------------

result="$(run_case "https://hooks.example.test/escalate" "$all_events" "[]" succeed fail \
  "acme/agent-ops" "auth-failure:test-node" "escalation" \
  "GitHub credentials rejected" "detail")"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "a failed escalation-filed POST still returns 0" "0" "$rc"
assert_eq "…and still prints the issue number and URL" \
  $'99\thttps://github.com/acme/agent-ops/issues/99' "$out"

echo
if (( failures == 0 )); then
  echo "All enabler notify-wiring assertions passed."
  exit 0
else
  echo "$failures enabler notify-wiring assertion(s) FAILED."
  exit 1
fi
