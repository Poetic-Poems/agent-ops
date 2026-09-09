#!/usr/bin/env bash
#
# test/notify.test.sh — regression test for requirement 2m (issue #1279):
# the installation's one push-notification channel, lib/notify.sh.
#
# Sources lib/notify.sh directly (it is self-contained by design — see its
# own header — so no extraction dance and no cycle-scoped globals to stub,
# unlike the escalation_webhook_notify/create_escalation_issue pair this file
# replaces, test/escalation-webhook.test.sh). `curl` is stubbed; `date` is
# real, so rate-limit scenarios place fixture timestamps relative to the
# actual wall clock.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/notify.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/notify.sh
source "$SCRIPT_DIR/lib/notify.sh"

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

# curl stub: records argv, captures --data-binary, succeeds/fails per
# $CURL_MODE ("succeed" or "fail" — "fail" stands in for a fence 403).
# shellcheck disable=SC2317  # called from inside lib/notify.sh, invisible to a static reader
curl() {
  printf '%s\n' "$*" >> "$tmp_dir/curl_calls"
  local args=("$@") i
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--data-binary" ]]; then
      printf '%s' "${args[$((i+1))]}" > "$tmp_dir/curl_payload"
    fi
  done
  [[ "${CURL_MODE:-succeed}" == succeed ]]
}

reset_fixtures() {
  : > "$tmp_dir/curl_calls"
  : > "$tmp_dir/curl_payload"
  : > "$tmp_dir/read.jsonl"
  : > "$tmp_dir/write.jsonl"
}

# --- notify_event_class ------------------------------------------------------

assert_eq "escalation-filed classifies as escalation" "escalation" "$(notify_event_class escalation-filed)"
assert_eq "escalation-closed classifies as escalation" "escalation" "$(notify_event_class escalation-closed)"
assert_eq "escalation-unfiled classifies as escalation" "escalation" "$(notify_event_class escalation-unfiled)"
assert_eq "pager-fired classifies as pager" "pager" "$(notify_event_class pager-fired)"
assert_eq "pager-cleared classifies as pager" "pager" "$(notify_event_class pager-cleared)"
assert_eq "fleet-standdown-begin classifies as fleet-standdown" "fleet-standdown" "$(notify_event_class fleet-standdown-begin)"
assert_eq "fleet-standdown-end classifies as fleet-standdown" "fleet-standdown" "$(notify_event_class fleet-standdown-end)"
assert_eq "an unrecognised event classifies as nothing (fail closed)" "" "$(notify_event_class some-other-event)"

# --- notify_resolve_webhook_url (the alias) ----------------------------------

assert_eq "notify_webhook_url wins when both are set" \
  "https://notify.example.test/hook" \
  "$(notify_resolve_webhook_url "https://notify.example.test/hook" "https://escalation.example.test/hook")"
assert_eq "escalation_webhook_url is used when notify_webhook_url is empty (the alias)" \
  "https://escalation.example.test/hook" \
  "$(notify_resolve_webhook_url "" "https://escalation.example.test/hook")"
assert_eq "both empty resolves to empty" "" "$(notify_resolve_webhook_url "" "")"

# --- notify_post: no webhook configured — always a no-op --------------------

reset_fixtures
CURL_MODE=succeed notify_post "escalation-filed" "acme/repo#42" "title" "url" "acme/repo" "detail" \
  "" '["escalation","pager","fleet-standdown"]' 600 "$tmp_dir/read.jsonl" "$tmp_dir/write.jsonl" "n1" "c1"
assert_eq "no webhook_url: curl is never called" "0" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
assert_eq "no webhook_url: nothing is logged" "" "$(cat "$tmp_dir/write.jsonl")"

# --- notify_post: event class filtering by notify_events --------------------

reset_fixtures
CURL_MODE=succeed notify_post "pager-fired" "pager:x" "title" "" "" "detail" \
  "https://notify.example.test/hook" '["escalation","fleet-standdown"]' 600 \
  "$tmp_dir/read.jsonl" "$tmp_dir/write.jsonl" "n1" "c1"
assert_eq "pager class absent from notify_events: curl is never called" "0" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
assert_eq "pager class absent from notify_events: nothing is logged" "" "$(cat "$tmp_dir/write.jsonl")"

for class_event in escalation-filed:escalation pager-fired:pager fleet-standdown-begin:fleet-standdown; do
  event="${class_event%%:*}"
  reset_fixtures
  CURL_MODE=succeed notify_post "$event" "key:$event" "title" "url" "repo" "detail" \
    "https://notify.example.test/hook" '["escalation","pager","fleet-standdown"]' 600 \
    "$tmp_dir/read.jsonl" "$tmp_dir/write.jsonl" "n1" "c1"
  assert_eq "$event: every class enabled — curl is called once" "1" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
  assert_eq "$event: notify-sent is logged" "notify-sent" "$(jq -r '.event' "$tmp_dir/write.jsonl")"
done

# --- notify_post: payload shape --------------------------------------------

reset_fixtures
CURL_MODE=succeed notify_post "escalation-filed" "acme/repo#42" "GitHub credentials rejected" \
  "https://github.com/acme/repo/issues/99" "acme/repo" "GitHub said: Bad credentials" \
  "https://notify.example.test/hook" '["escalation"]' 600 \
  "$tmp_dir/read.jsonl" "$tmp_dir/write.jsonl" "test-node" "cycle-1"
assert_contains "POSTed to the configured webhook URL" \
  "https://notify.example.test/hook" "$(cat "$tmp_dir/curl_calls")"
payload="$(cat "$tmp_dir/curl_payload")"
assert_eq "payload event" "escalation-filed" "$(jq -r '.event' <<<"$payload")"
assert_eq "payload key" "acme/repo#42" "$(jq -r '.key' <<<"$payload")"
assert_eq "payload title" "GitHub credentials rejected" "$(jq -r '.title' <<<"$payload")"
assert_eq "payload url" "https://github.com/acme/repo/issues/99" "$(jq -r '.url' <<<"$payload")"
assert_eq "payload repo" "acme/repo" "$(jq -r '.repo' <<<"$payload")"
assert_eq "payload node" "test-node" "$(jq -r '.node' <<<"$payload")"
assert_eq "payload detail" "GitHub said: Bad credentials" "$(jq -r '.detail' <<<"$payload")"
assert_eq "payload has no count on a first send" "null" "$(jq -r '.count' <<<"$payload")"

# --- notify_post: the rate limit (notify_min_interval_seconds), per key -----

reset_fixtures
now_epoch="$(date -u +%s)"
recent_ts="$(date -u -d "@$(( now_epoch - 30 ))" +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"notify-sent","key":"pager:x"}\n' "$recent_ts" > "$tmp_dir/read.jsonl"
CURL_MODE=succeed notify_post "pager-fired" "pager:x" "title" "" "" "detail" \
  "https://notify.example.test/hook" '["pager"]' 600 \
  "$tmp_dir/read.jsonl" "$tmp_dir/write.jsonl" "n1" "c1"
assert_eq "inside the interval: curl is not called" "0" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
assert_eq "inside the interval: notify-suppressed is logged instead" \
  "notify-suppressed" "$(jq -r '.event' "$tmp_dir/write.jsonl")"

reset_fixtures
old_ts="$(date -u -d "@$(( now_epoch - 900 ))" +%Y-%m-%dT%H:%M:%SZ)"
suppressed_ts_1="$(date -u -d "@$(( now_epoch - 500 ))" +%Y-%m-%dT%H:%M:%SZ)"
suppressed_ts_2="$(date -u -d "@$(( now_epoch - 400 ))" +%Y-%m-%dT%H:%M:%SZ)"
{
  printf '{"ts":"%s","event":"notify-sent","key":"pager:x"}\n' "$old_ts"
  printf '{"ts":"%s","event":"notify-suppressed","key":"pager:x"}\n' "$suppressed_ts_1"
  printf '{"ts":"%s","event":"notify-suppressed","key":"pager:x"}\n' "$suppressed_ts_2"
} > "$tmp_dir/read.jsonl"
CURL_MODE=succeed notify_post "pager-fired" "pager:x" "title" "" "" "detail" \
  "https://notify.example.test/hook" '["pager"]' 600 \
  "$tmp_dir/read.jsonl" "$tmp_dir/write.jsonl" "n1" "c1"
assert_eq "past the interval: curl is called once" "1" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"
assert_eq "past the interval: the coalesced count folds in every suppressed send since" \
  "3" "$(jq -r '.count' "$tmp_dir/curl_payload")"
assert_eq "past the interval: notify-sent is logged" "notify-sent" "$(jq -r '.event' "$tmp_dir/write.jsonl")"

reset_fixtures
printf '{"ts":"%s","event":"notify-sent","key":"pager:other-key"}\n' \
  "$(date -u -d "@$(( now_epoch - 30 ))" +%Y-%m-%dT%H:%M:%SZ)" > "$tmp_dir/read.jsonl"
CURL_MODE=succeed notify_post "pager-fired" "pager:unrelated-key" "title" "" "" "detail" \
  "https://notify.example.test/hook" '["pager"]' 600 \
  "$tmp_dir/read.jsonl" "$tmp_dir/write.jsonl" "n1" "c1"
assert_eq "the rate limit is per key, not global: an unrelated key still sends" \
  "1" "$(wc -l < "$tmp_dir/curl_calls" | tr -d ' ')"

# --- notify_post: a fence failure (403) is best-effort ----------------------

reset_fixtures
CURL_MODE=fail notify_post "escalation-unfiled" "acme/repo#42" "title" "" "acme/repo" "detail" \
  "https://notify.example.test/hook" '["escalation"]' 600 \
  "$tmp_dir/read.jsonl" "$tmp_dir/write.jsonl" "n1" "c1"
rc=$?
assert_eq "a POST failure never propagates: notify_post still returns 0" "0" "$rc"
assert_eq "a POST failure logs notify-failed" "notify-failed" "$(jq -r '.event' "$tmp_dir/write.jsonl")"
assert_contains "…naming the key" "acme/repo#42" "$(jq -r '.key' "$tmp_dir/write.jsonl")"

echo
if (( failures == 0 )); then
  echo "All notify assertions passed."
  exit 0
else
  echo "$failures notify assertion(s) FAILED."
  exit 1
fi
