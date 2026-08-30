#!/usr/bin/env bash
#
# test/gh-shim.test.sh — regression test for lib/gh-shim.sh and
# scripts/gh-shim.sh: the `gh` transport shim of requirement 2.0e
# (agent-ops#1084).
#
# Two layers:
#
#   - pure functions, sourced directly (classification, header/body
#     parsing, cache-key derivation, the last-known-good decision, the
#     invalidation heuristic);
#   - the shim end to end, run as a subprocess against a stub "real gh"
#     binary that answers from a small per-call JSON plan
#     (STUB_PLAN_DIR/<n>.json — {status, body, etag, ratelimit, rc}), so a
#     whole HTTP exchange (headers, body, status, ratelimit figures) is
#     under the test's control with no network involved. The stub prints
#     `-i`-shaped output (status line, headers, blank line, body) whenever
#     `-i`/`--include` is in its own argv — which the shim always adds for a
#     cacheable read, and never adds for anything else — and every call is
#     recorded to STUB_PLAN_DIR/calls.log for asserting exactly what the
#     shim sent (an `If-None-Match` header, or nothing extra at all).
#
# Run directly:
#
#   ./test/gh-shim.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/gh-shim.sh
. "$SCRIPT_DIR/lib/gh-shim.sh"

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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# === Pure functions ===========================================================

# --- gh_shim_classify / gh_shim_parse ---

gh_shim_classify api repos/o/r
assert_eq "a plain GET is 'read'" "read" "$GH_SHIM_CLASS"
assert_eq "…and the endpoint is captured" "repos/o/r" "$GH_SHIM_ENDPOINT"
assert_eq "…and the method defaults to GET" "GET" "$GH_SHIM_METHOD"

gh_shim_classify api repos/o/r -X POST
assert_eq "-X POST is 'write'" "write" "$GH_SHIM_CLASS"
assert_eq "…and the method is POST" "POST" "$GH_SHIM_METHOD"

gh_shim_classify api repos/o/r --method=DELETE
assert_eq "--method=DELETE is 'write'" "write" "$GH_SHIM_CLASS"

gh_shim_classify api repos/o/r -f a=b
assert_eq "-f with no explicit method is 'write' (gh's own POST default)" "write" "$GH_SHIM_CLASS"

gh_shim_classify api repos/o/r --input -
assert_eq "--input is 'write'" "write" "$GH_SHIM_CLASS"

gh_shim_classify api repos/o/r -f a=b --method GET
assert_eq "an explicit -X/--method GET overrides the body-flag default" "read" "$GH_SHIM_CLASS"

gh_shim_classify api graphql -f query=x
assert_eq "the literal graphql endpoint is its own class, never 'read'" "graphql" "$GH_SHIM_CLASS"

gh_shim_classify api repos/o/r -i
assert_eq "a caller already asking for -i is its own class, never 'read'" "include" "$GH_SHIM_CLASS"

gh_shim_classify api repos/o/r --include
assert_eq "…same for --include" "include" "$GH_SHIM_CLASS"

gh_shim_classify pr view 5
assert_eq "a non-'api' subcommand is 'other'" "other" "$GH_SHIM_CLASS"

gh_shim_classify api
assert_eq "'api' with no endpoint is 'other'" "other" "$GH_SHIM_CLASS"

gh_shim_classify api "repos/o/r/issues?state=open" --paginate
assert_eq "--paginate is still 'read'" "read" "$GH_SHIM_CLASS"
assert_eq "…and is flagged" "1" "$GH_SHIM_HAS_PAGINATE"

# --- gh_shim_strip_query / gh_shim_parent_path ---

assert_eq "strip_query drops a query string" \
  "repos/o/r/issues" "$(gh_shim_strip_query 'repos/o/r/issues?state=open&per_page=100')"
assert_eq "strip_query is a no-op with no query string" \
  "repos/o/r" "$(gh_shim_strip_query 'repos/o/r')"
assert_eq "parent_path drops the last segment" \
  "repos/o/r/pulls/5" "$(gh_shim_parent_path 'repos/o/r/pulls/5/reviews')"
assert_eq "parent_path of a path with no '/' is empty" \
  "" "$(gh_shim_parent_path 'meta')"

# --- gh_shim_cache_key ---

k1="$(gh_shim_cache_key idA api repos/o/r)"
k2="$(gh_shim_cache_key idA api repos/o/r)"
k3="$(gh_shim_cache_key idB api repos/o/r)"
k4="$(gh_shim_cache_key idA api repos/o/r2)"
assert_eq "the same identity and argv give the same key" "$k1" "$k2"
assert_eq "a different identity gives a different key" "no" "$([[ "$k1" == "$k3" ]] && echo yes || echo no)"
assert_eq "different argv gives a different key" "no" "$([[ "$k1" == "$k4" ]] && echo yes || echo no)"

# --- gh_shim_identity ---

assert_eq "no credential at all is the fixed 'no-token' identity" \
  "no-token" "$(GH_TOKEN='' GITHUB_TOKEN='' gh_shim_identity)"
assert_eq "a token hashes to something other than itself or 'no-token'" \
  "no" "$(v="$(GH_TOKEN=ghp_supersecret gh_shim_identity)"; [[ "$v" == "no-token" || "$v" == "ghp_supersecret" ]] && echo yes || echo no)"
assert_eq "the same token always hashes the same way" \
  "$(GH_TOKEN=ghp_a gh_shim_identity)" "$(GH_TOKEN=ghp_a gh_shim_identity)"
assert_eq "two different tokens hash differently" \
  "no" "$([[ "$(GH_TOKEN=ghp_a gh_shim_identity)" == "$(GH_TOKEN=ghp_b gh_shim_identity)" ]] && echo yes || echo no)"

# --- gh_shim_header_value ---

hdr_file="$tmp_dir/sample.hdr"
printf 'ETag: W/"abc123"\r\nX-RateLimit-Used: 12\r\nContent-Type: application/json\r\n' > "$hdr_file"
assert_eq "header_value is case-insensitive and CR-stripped" \
  'W/"abc123"' "$(gh_shim_header_value "$hdr_file" etag)"
assert_eq "…for a differently-cased header name too" \
  "12" "$(gh_shim_header_value "$hdr_file" X-RateLimit-Used)"
assert_eq "an absent header is empty" \
  "" "$(gh_shim_header_value "$hdr_file" Link)"

# --- gh_shim_split_blocks ---

split_dir="$tmp_dir/split1"; mkdir -p "$split_dir"
raw_file="$tmp_dir/raw1"
printf 'HTTP/2.0 200 OK\r\nEtag: "one"\r\n\r\n{"n":1}\n' > "$raw_file"
count="$(gh_shim_split_blocks "$raw_file" "$split_dir")"
assert_eq "a single response is one block" "1" "$count"
assert_eq "…with the right status" "200" "$(cat "$split_dir/1.status")"
assert_eq "…and the right body" '{"n":1}' "$(cat "$split_dir/1.body")"

split_dir2="$tmp_dir/split2"; mkdir -p "$split_dir2"
raw_file2="$tmp_dir/raw2"
printf 'HTTP/2.0 200 OK\r\nLink: <p2>\r\n\r\n[1,2]\nHTTP/2.0 200 OK\r\n\r\n[3,4]\n' > "$raw_file2"
count2="$(gh_shim_split_blocks "$raw_file2" "$split_dir2")"
assert_eq "a --paginate-shaped capture splits into its pages" "2" "$count2"
assert_eq "…first page body" "[1,2]" "$(cat "$split_dir2/1.body")"
assert_eq "…second page body" "[3,4]" "$(cat "$split_dir2/2.body")"

split_dir3="$tmp_dir/split3"; mkdir -p "$split_dir3"
raw_file3="$tmp_dir/raw3"
printf 'gh: Could not resolve host: api.github.com\n' > "$raw_file3"
count3="$(gh_shim_split_blocks "$raw_file3" "$split_dir3")"
assert_eq "output with no HTTP status line at all is zero blocks" "0" "$count3"

# --- gh_shim_should_use_lkg ---

assert_eq "a primary rate-limit refusal uses last-known-good" \
  "yes" "$(gh_shim_should_use_lkg 403 'HTTP 403: API rate limit exceeded for user ID 9' >/dev/null && echo yes || echo no)"
assert_eq "a secondary rate limit does not (it is short; the retry wrapper handles it)" \
  "no" "$(gh_shim_should_use_lkg 403 'You have exceeded a secondary rate limit. Please wait.' >/dev/null && echo yes || echo no)"
assert_eq "a bare 5xx uses last-known-good even with no rate-limit wording" \
  "yes" "$(gh_shim_should_use_lkg 502 'Bad Gateway' >/dev/null && echo yes || echo no)"
assert_eq "an ordinary 404 does not" \
  "no" "$(gh_shim_should_use_lkg 404 'Not Found' >/dev/null && echo yes || echo no)"
assert_eq "a 200 does not" \
  "no" "$(gh_shim_should_use_lkg 200 '' >/dev/null && echo yes || echo no)"

# --- gh_shim_cache_write / gh_shim_cache_read round-trip ---

cache_state="$tmp_dir/cache-state"; mkdir -p "$cache_state/http-cache"
body_file="$tmp_dir/body-with-newlines"
printf 'line one\nline two\n{"nested":"json\\nvalue"}' > "$body_file"
gh_shim_cache_write "$cache_state" thekey theident repos/o/r etag-1 "$body_file" 1000
roundtrip="$(gh_shim_cache_read "$cache_state" thekey)"
assert_eq "the round-tripped identity matches" "theident" "$(jq -r '.identity' <<<"$roundtrip")"
assert_eq "the round-tripped path matches" "repos/o/r" "$(jq -r '.path' <<<"$roundtrip")"
assert_eq "the round-tripped etag matches" "etag-1" "$(jq -r '.etag' <<<"$roundtrip")"
assert_eq "the round-tripped body preserves embedded newlines and quoting exactly" \
  "$(cat "$body_file")" "$(jq -j '.body' <<<"$roundtrip")"
assert_eq "a missing key reads as nothing" "" "$(gh_shim_cache_read "$cache_state" no-such-key)"

# --- gh_shim_cache_invalidate ---

inv_state="$tmp_dir/inv-state"; mkdir -p "$inv_state/http-cache"
echo x > "$tmp_dir/inv-body"
gh_shim_cache_write "$inv_state" keyA idX "repos/o/r/pulls/5/reviews" e "$tmp_dir/inv-body" 1
gh_shim_cache_write "$inv_state" keyB idX "repos/o/r/pulls/5" e "$tmp_dir/inv-body" 1
gh_shim_cache_write "$inv_state" keyC idX "repos/o/r/issues/9" e "$tmp_dir/inv-body" 1
gh_shim_cache_write "$inv_state" keyD idY "repos/o/r/pulls/5/reviews" e "$tmp_dir/inv-body" 1
gh_shim_cache_invalidate "$inv_state" idX "repos/o/r/pulls/5/reviews"
assert_eq "invalidation drops the write's own path" \
  "no" "$([[ -f "$inv_state/http-cache/keyA.json" ]] && echo yes || echo no)"
assert_eq "…and drops the parent resource" \
  "no" "$([[ -f "$inv_state/http-cache/keyB.json" ]] && echo yes || echo no)"
assert_eq "…but leaves an unrelated path alone" \
  "yes" "$([[ -f "$inv_state/http-cache/keyC.json" ]] && echo yes || echo no)"
assert_eq "…and leaves a different identity's cache of the very same path alone" \
  "yes" "$([[ -f "$inv_state/http-cache/keyD.json" ]] && echo yes || echo no)"

# --- gh_shim_ledger_line ---

ledger_state="$tmp_dir/ledger-state"; mkdir -p "$ledger_state"
gh_shim_ledger_line "$ledger_state" GET repos/o/r 200 miss core 5
gh_shim_ledger_line "$ledger_state" GET repos/o/r "" stale "" ""
last_line="$(tail -1 "$ledger_state/ledger.ndjson")"
first_line="$(head -1 "$ledger_state/ledger.ndjson")"
assert_eq "a numeric status is logged as a number" "200" "$(jq -r '.status' <<<"$first_line")"
assert_eq "…with its cache outcome" "miss" "$(jq -r '.cache' <<<"$first_line")"
assert_eq "…and its resource/used" "core 5" "$(jq -r '.resource + " " + (.used|tostring)' <<<"$first_line")"
assert_eq "an empty status is logged as null, not a string" "null" "$(jq -c '.status' <<<"$last_line")"
assert_eq "an empty resource is logged as null" "null" "$(jq -c '.resource' <<<"$last_line")"

# --- gh_shim_budget_update ---

budget_state="$tmp_dir/budget-state"; mkdir -p "$budget_state"
gh_shim_budget_update "$budget_state" idX '{"limit":5000,"used":10,"remaining":4990,"reset":1893456000}'
assert_eq "the budget file records the identity's core reading" \
  "4990" "$(jq -r '.idX.core.remaining' "$budget_state/budget.json")"
gh_shim_budget_update "$budget_state" idY '{"limit":5000,"used":1,"remaining":4999,"reset":1893456000}'
assert_eq "a second identity does not clobber the first" \
  "4990" "$(jq -r '.idX.core.remaining' "$budget_state/budget.json")"
gh_shim_budget_update "$budget_state" idX '{"limit":5000,"used":20,"remaining":4980,"reset":1893456000}'
assert_eq "the same identity's later reading overwrites its own, only" \
  "4980" "$(jq -r '.idX.core.remaining' "$budget_state/budget.json")"

# === End to end, against a stub "real gh" ====================================

stub_bin="$tmp_dir/stub"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
# A stub "real gh": answers from STUB_PLAN_DIR/<call-number>.json
# ({status, body, etag, ratelimit, rc}), in `-i`-shaped output whenever -i or
# --include is in its own argv (the only time it needs to be, since that is
# the only time the shim itself is reading the response) and plain otherwise
# (a bypassed call, or a caller asking for its own headers without asking
# this stub to add any more).
set -uo pipefail
plan_dir="${STUB_PLAN_DIR:?}"
count_file="$plan_dir/.count"
n=0
[[ -f "$count_file" ]] && n="$(cat "$count_file")"
n=$(( n + 1 ))
printf '%s' "$n" > "$count_file"
{ printf '%s\x1f' "$@"; printf '\n'; } >> "$plan_dir/calls.log"
plan="$plan_dir/$n.json"
if [[ ! -f "$plan" ]]; then
  printf 'stub: no plan for call %s\n' "$n" >&2
  exit 99
fi
status="$(jq -r '.status' "$plan")"
body="$(jq -r '.body' "$plan")"
etag="$(jq -r '.etag // empty' "$plan")"
rc="$(jq -r '.rc' "$plan")"
has_include=0
for a in "$@"; do [[ "$a" == "-i" || "$a" == "--include" ]] && has_include=1; done
if [[ "$has_include" == 1 ]]; then
  printf 'HTTP/2.0 %s X\r\n' "$status"
  [[ -n "$etag" ]] && printf 'etag: %s\r\n' "$etag"
  if jq -e '.ratelimit != null' "$plan" >/dev/null 2>&1; then
    printf 'x-ratelimit-limit: %s\r\nx-ratelimit-used: %s\r\nx-ratelimit-remaining: %s\r\nx-ratelimit-reset: %s\r\nx-ratelimit-resource: core\r\n' \
      "$(jq -r '.ratelimit.limit' "$plan")" "$(jq -r '.ratelimit.used' "$plan")" \
      "$(jq -r '.ratelimit.remaining' "$plan")" "$(jq -r '.ratelimit.reset' "$plan")"
  fi
  printf '\r\n%s' "$body"
else
  printf '%s' "$body"
fi
exit "$rc"
STUB
chmod +x "$stub_bin/gh"

plan() {  # PLAN_DIR N STATUS BODY ETAG RATELIMIT_JSON RC
  jq -n --argjson status "$3" --arg body "$4" --arg etag "$5" --argjson rl "$6" --argjson rc "$7" \
    '{status: $status, body: $body, etag: (if $etag == "" then null else $etag end), ratelimit: $rl, rc: $rc}' \
    > "$1/$2.json"
}

run_shim() {  # STATE_DIR PLAN_DIR TOKEN ARGS...
  local state="$1" plan_dir="$2" token="$3"
  shift 3
  PW_GH_REAL_BIN="$stub_bin/gh" PW_GH_STATE_DIR="$state" STUB_PLAN_DIR="$plan_dir" \
    GH_TOKEN="$token" "$SCRIPT_DIR/scripts/gh-shim.sh" "$@"
}

# --- "repeated GET sends If-None-Match, 304 yields stored body and exit 0" ---

stA="$tmp_dir/stateA"; pdA="$tmp_dir/planA"; mkdir -p "$stA" "$pdA"
plan "$pdA" 1 200 '{"n":1}' 'W/"one"' '{"limit":5000,"used":10,"remaining":4990,"reset":1893456000}' 0
plan "$pdA" 2 304 '' 'W/"one"' null 1

out1="$(run_shim "$stA" "$pdA" tokA api repos/o/r)"; rc1=$?
assert_eq "first call: body reaches the caller" '{"n":1}' "$out1"
assert_eq "first call: exit 0" "0" "$rc1"

out2="$(run_shim "$stA" "$pdA" tokA api repos/o/r)"; rc2=$?
assert_eq "second call (304): the cached body is served" '{"n":1}' "$out2"
assert_eq "second call (304): exit 0" "0" "$rc2"
assert_eq "second call: If-None-Match carried the first call's etag" \
  "yes" "$(grep -F 'If-None-Match: W/"one"' "$pdA/calls.log" >/dev/null && echo yes || echo no)"
assert_eq "the ledger records a miss, then a hit" \
  "miss hit" "$(jq -r '.cache' "$stA/gh-shim/ledger.ndjson" | paste -sd' ' -)"
assert_eq "the budget file recorded the identity's core reading" \
  "4990" "$(jq -r ". | to_entries[0].value.core.remaining" "$stA/gh-shim/budget.json")"

# --- "403 primary with stored body yields body+stale+ceiling" ---

stB="$tmp_dir/stateB"; pdB="$tmp_dir/planB"; mkdir -p "$stB" "$pdB"
plan "$pdB" 1 200 '{"n":2}' 'W/"b1"' null 0
plan "$pdB" 2 403 '{"message":"API rate limit exceeded for user ID 9"}' '' null 1

run_shim "$stB" "$pdB" tokB api repos/o/r2 >/dev/null
outB2="$(run_shim "$stB" "$pdB" tokB api repos/o/r2 2>"$tmp_dir/stalestderr")"; rcB2=$?
assert_eq "a primary-limit refusal serves the stored body" '{"n":2}' "$outB2"
assert_eq "…with exit 0 by default" "0" "$rcB2"
assert_eq "…and a stale marker on stderr" \
  "yes" "$(grep -qE '^PW_GH_CACHE=stale age=[0-9]+s$' "$tmp_dir/stalestderr" && echo yes || echo no)"
assert_eq "the ledger records the refusal as 'stale'" \
  "stale" "$(tail -1 "$stB/gh-shim/ledger.ndjson" | jq -r '.cache')"

# The ceiling: backdate the cache entry past it, and the same refusal must
# fall through to the real (failing) answer instead.
cache_key_b="$(gh_shim_cache_key "$(GH_TOKEN=tokB gh_shim_identity)" api repos/o/r2)"
jq '.fetched_at = 1' "$stB/gh-shim/http-cache/$cache_key_b.json" > "$tmp_dir/backdated.json"
mv "$tmp_dir/backdated.json" "$stB/gh-shim/http-cache/$cache_key_b.json"
plan "$pdB" 3 403 '{"message":"API rate limit exceeded for user ID 9"}' '' null 1
outB3="$(PW_GH_STALE_CEILING_SECONDS=10 run_shim "$stB" "$pdB" tokB api repos/o/r2)"; rcB3=$?
assert_eq "a cache entry older than the ceiling is not served" \
  '{"message":"API rate limit exceeded for user ID 9"}' "$outB3"
assert_eq "…and the real (failing) exit status is preserved" "1" "$rcB3"

# --- "write invalidates affected reads" ---

stC="$tmp_dir/stateC"; pdC="$tmp_dir/planC"; mkdir -p "$stC" "$pdC"
plan "$pdC" 1 200 '{"pr":5}' 'e1' null 0
plan "$pdC" 2 200 '[{"id":1}]' 'e2' null 0
plan "$pdC" 3 200 '{"posted":true}' '' null 0
run_shim "$stC" "$pdC" tokC api repos/o/r/pulls/5 >/dev/null
run_shim "$stC" "$pdC" tokC api repos/o/r/pulls/5/reviews >/dev/null
assert_eq "two GETs are cached before the write" \
  "2" "$(find "$stC/gh-shim/http-cache" -name '*.json' | wc -l | tr -d ' ')"
run_shim "$stC" "$pdC" tokC api repos/o/r/pulls/5/reviews -X POST -f body=hi >/dev/null
assert_eq "a successful write to .../reviews invalidates both the listing and its parent PR" \
  "0" "$(find "$stC/gh-shim/http-cache" -name '*.json' | wc -l | tr -d ' ')"
assert_eq "the write itself was never conditioned (no injected -i/-H reached the stub)" \
  "no" "$(tail -1 "$pdC/calls.log" | grep -q -- '-i' && echo yes || echo no)"

# --- "POST/graphql/--input bypass unchanged" ---

stD="$tmp_dir/stateD"; pdD="$tmp_dir/planD"; mkdir -p "$stD" "$pdD"
plan "$pdD" 1 201 '{"created":true}' '' null 0
outD1="$(run_shim "$stD" "$pdD" tokD api repos/o/r/issues -X POST -f title=x)"
assert_eq "a POST reaches the caller exactly as the real binary answered" '{"created":true}' "$outD1"
assert_eq "…and was never asked to include headers" \
  "no" "$(tail -1 "$pdD/calls.log" | grep -qF -- '-i' && echo yes || echo no)"

plan "$pdD" 2 200 '{"data":{}}' '' null 0
outD2="$(run_shim "$stD" "$pdD" tokD api graphql -f query=x)"
assert_eq "graphql reaches the caller exactly as the real binary answered" '{"data":{}}' "$outD2"
assert_eq "…and is never cached" \
  "0" "$(find "$stD/gh-shim/http-cache" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

plan "$pdD" 3 200 '{"ok":true}' '' null 0
outD3="$(run_shim "$stD" "$pdD" tokD api repos/o/r/import --input -)"
assert_eq "--input reaches the caller exactly as the real binary answered" '{"ok":true}' "$outD3"

plan "$pdD" 4 200 '{"already":"headers"}' 'e' null 0
outD4="$(run_shim "$stD" "$pdD" tokD api repos/o/r -i)"
assert_eq "a caller already asking for -i gets the real binary's raw output back verbatim" \
  "yes" "$(grep -q '^HTTP/2.0 200' <<<"$outD4" && grep -qF '{"already":"headers"}' <<<"$outD4" && echo yes || echo no)"
assert_eq "…and that call is never cached either" \
  "0" "$(find "$stD/gh-shim/http-cache" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

# --- "real binary reached with original args/status in other cases" ---

stE="$tmp_dir/stateE"; pdE="$tmp_dir/planE"; mkdir -p "$stE" "$pdE"
plan "$pdE" 1 0 'pr view output' '' null 0
outE1="$(run_shim "$stE" "$pdE" tokE pr view 5)"; rcE1=$?
assert_eq "a non-'api' subcommand's output is unmodified" "pr view output" "$outE1"
assert_eq "…and its exit status is unmodified" "0" "$rcE1"

plan "$pdE" 2 0 '' '' null 7
run_shim "$stE" "$pdE" tokE pr merge 9 >/dev/null; rcE2=$?
assert_eq "a non-'api' subcommand's failure exit status reaches the caller too" "7" "$rcE2"

# --- PW_GH_NO_CACHE=1 opt-out ---

stF="$tmp_dir/stateF"; pdF="$tmp_dir/planF"; mkdir -p "$stF" "$pdF"
plan "$pdF" 1 200 '{"n":9}' 'eF' null 0
outF="$(PW_GH_NO_CACHE=1 PW_GH_REAL_BIN="$stub_bin/gh" PW_GH_STATE_DIR="$stF" STUB_PLAN_DIR="$pdF" \
  GH_TOKEN=tokF "$SCRIPT_DIR/scripts/gh-shim.sh" api repos/o/r)"
assert_eq "PW_GH_NO_CACHE=1 still reaches the caller with the real body" '{"n":9}' "$outF"
assert_eq "…without asking the stub for headers" \
  "no" "$(tail -1 "$pdF/calls.log" | grep -qF -- '-i' && echo yes || echo no)"
assert_eq "…and writes nothing to the cache" \
  "no" "$([[ -d "$stF/gh-shim/http-cache" ]] && find "$stF/gh-shim/http-cache" -name '*.json' | grep -q . && echo yes || echo no)"
assert_eq "…but is still ledgered, as bypass" \
  "bypass" "$(tail -1 "$stF/gh-shim/ledger.ndjson" | jq -r '.cache')"

echo
if (( failures == 0 )); then
  echo "All gh-shim assertions passed."
  exit 0
else
  echo "$failures gh-shim assertion(s) FAILED."
  exit 1
fi
