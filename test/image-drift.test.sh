#!/usr/bin/env bash
#
# test/image-drift.test.sh — the registry-backed image-staleness check (#155).
#
# The properties that matter:
#   - a checkout (source != "image", or no commit) reads null — "behind the
#     registry" is not a question that applies to it;
#   - a commit matching the registry's :latest reads current;
#   - a commit that does not reads behind, carrying the registry's commit and
#     the image's creation label — the raw material the dashboard's mid-roll
#     tolerance threshold needs, kept out of this file (design decision in
#     lib/image-drift.sh's header);
#   - a token, manifest, or config-blob fetch that fails reads unverified with
#     a reason, never a crash and never a guessed verdict;
#   - a registry image carrying no revision label reads unverified too — an
#     old publish, from before this file existed, is not "current" by
#     omission;
#   - the multi-platform index this repository actually publishes (one
#     manifest per architecture) is walked one level to reach the config that
#     carries the labels;
#   - and the cache means a second call inside IMAGE_DRIFT_TTL costs no
#     network call at all, while an empty cache-file path (what the fleet
#     scripts never pass, but this suite does to isolate scenarios) always
#     re-fetches.
#
# No real network is reached: IMAGE_DRIFT_CURL_CMD points at a fixture
# standing in for `curl`, keyed on the URL (its last argument) — the same
# seam DASHBOARD_GH_CMD gives the Publisher's tests for `gh`.
#
# Run directly: ./test/image-drift.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/image-drift.sh
. "$SCRIPT_DIR/lib/image-drift.sh"

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

version_json() {  # <source> <commit> <repo>
  jq -nc --arg s "$1" --arg c "$2" --arg r "$3" \
    '{source:$s, commit:$c, repo:$r, short:($c[0:7])}'
}

# --- The fixture curl -----------------------------------------------------------
# Every scenario drives it through environment variables rather than separate
# scripts: TOKEN_FAIL / MANIFEST_FAIL / CONFIG_FAIL make the matching call
# fail exactly the way `curl -f` fails an HTTP error (exit 22, no stdout);
# INDEX_JSON switches the top-level manifest between a single manifest and a
# multi-platform index; REVISION / CREATED fill the config blob's labels.
stub="$tmp_dir/curl-stub.sh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_CALL_LOG"
url="${*: -1}"
case "$url" in
  *"/token?"*)
    [[ "${TOKEN_FAIL:-0}" == "1" ]] && exit 22
    printf '{"token":"faketoken"}'
    ;;
  *"/manifests/latest")
    [[ "${MANIFEST_FAIL:-0}" == "1" ]] && exit 22
    if [[ "${AS_INDEX:-0}" == "1" ]]; then
      printf '{"manifests":[{"digest":"sha256:childdigest","platform":{"architecture":"amd64"}}]}'
    else
      printf '{"config":{"digest":"sha256:configdigest"}}'
    fi
    ;;
  *"/manifests/sha256:childdigest")
    [[ "${MANIFEST_FAIL:-0}" == "1" ]] && exit 22
    printf '{"config":{"digest":"sha256:configdigest"}}'
    ;;
  *"/blobs/sha256:configdigest")
    [[ "${CONFIG_FAIL:-0}" == "1" ]] && exit 22
    jq -nc --arg rev "${REVISION:-}" --arg created "${CREATED:-}" \
      '{config:{Labels: ({} + (if $rev == "" then {} else {"org.opencontainers.image.revision":$rev} end)
                            + (if $created == "" then {} else {"org.opencontainers.image.created":$created} end))}}'
    ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$stub"

export IMAGE_DRIFT_CURL_CMD="$stub"
call_log="$tmp_dir/curl.calls"
export CURL_CALL_LOG="$call_log"

token_calls() { grep -c '/token?' "$call_log" 2>/dev/null || true; }

# --- Not a CI-stamped image -----------------------------------------------------

assert_eq "a checkout (source=checkout) is null" \
  "null" "$(image_drift_status "$(version_json checkout deadbeef1234 Poetic-Poems/agent-ops)" "")"
assert_eq "an image stamp with no commit is null" \
  "null" "$(image_drift_status "$(version_json image "" Poetic-Poems/agent-ops)" "")"
assert_eq "no version at all is null" \
  "null" "$(image_drift_status "null" "")"

# --- Current ----------------------------------------------------------------

: > "$call_log"
verdict="$(REVISION=deadbeef1234567890 CREATED=2026-08-01T00:00:00Z \
  image_drift_status "$(version_json image deadbeef1234567890 Poetic-Poems/agent-ops)" "")"
assert_eq "a matching commit reads current" \
  "current" "$(jq -r '.status' <<<"$verdict")"
assert_eq "current carries a checked_at" \
  "1" "$(jq -r 'has("checked_at")' <<<"$verdict" | grep -qx true && echo 1 || echo 0)"

# --- Behind, via the multi-platform index ------------------------------------

verdict="$(AS_INDEX=1 REVISION=newcommit0000000 CREATED=2026-08-01T09:00:00Z \
  image_drift_status "$(version_json image oldcommit0000000 Poetic-Poems/agent-ops)" "")"
assert_eq "a differing commit reads behind" \
  "behind" "$(jq -r '.status' <<<"$verdict")"
assert_eq "carrying the registry's commit" \
  "newcommit0000000" "$(jq -r '.registry_commit' <<<"$verdict")"
assert_eq "and the image's creation label" \
  "2026-08-01T09:00:00Z" "$(jq -r '.registry_created_at' <<<"$verdict")"

# --- Behind, with no creation label (an old publish) -------------------------

verdict="$(REVISION=newcommit0000000 image_drift_status \
  "$(version_json image oldcommit0000000 Poetic-Poems/agent-ops)" "")"
assert_eq "a missing creation label reads null, not a false age" \
  "null" "$(jq -r '.registry_created_at' <<<"$verdict")"

# --- Unverified: each leg of the fetch can fail on its own -------------------

verdict="$(TOKEN_FAIL=1 image_drift_status \
  "$(version_json image oldcommit0000000 Poetic-Poems/agent-ops)" "")"
assert_eq "a failed token fetch reads unverified" \
  "unverified" "$(jq -r '.status' <<<"$verdict")"

verdict="$(MANIFEST_FAIL=1 image_drift_status \
  "$(version_json image oldcommit0000000 Poetic-Poems/agent-ops)" "")"
assert_eq "a failed manifest fetch reads unverified" \
  "unverified" "$(jq -r '.status' <<<"$verdict")"

verdict="$(CONFIG_FAIL=1 image_drift_status \
  "$(version_json image oldcommit0000000 Poetic-Poems/agent-ops)" "")"
assert_eq "a failed config-blob fetch reads unverified" \
  "unverified" "$(jq -r '.status' <<<"$verdict")"

verdict="$(image_drift_status \
  "$(version_json image oldcommit0000000 Poetic-Poems/agent-ops)" "")"
assert_eq "an image with no revision label reads unverified, never current" \
  "unverified" "$(jq -r '.status' <<<"$verdict")"

# --- Caching ------------------------------------------------------------------

cache_file="$tmp_dir/image-cache.json"
: > "$call_log"
REVISION=samecommit0000000 \
  image_drift_status "$(version_json image samecommit0000000 Poetic-Poems/agent-ops)" "$cache_file" >/dev/null
first_calls="$(token_calls)"
REVISION=samecommit0000000 \
  image_drift_status "$(version_json image samecommit0000000 Poetic-Poems/agent-ops)" "$cache_file" >/dev/null
assert_eq "a second call within the TTL costs no extra network call" \
  "$first_calls" "$(token_calls)"

: > "$call_log"
REVISION=samecommit0000000 \
  image_drift_status "$(version_json image samecommit0000000 Poetic-Poems/agent-ops)" "" >/dev/null
REVISION=samecommit0000000 \
  image_drift_status "$(version_json image samecommit0000000 Poetic-Poems/agent-ops)" "" >/dev/null
assert_eq "an empty cache-file path never caches" \
  "2" "$(token_calls)"

: > "$call_log"
REVISION=samecommit0000000 IMAGE_DRIFT_TTL=0 \
  image_drift_status "$(version_json image samecommit0000000 Poetic-Poems/agent-ops)" "$cache_file" >/dev/null
REVISION=samecommit0000000 IMAGE_DRIFT_TTL=0 \
  image_drift_status "$(version_json image samecommit0000000 Poetic-Poems/agent-ops)" "$cache_file" >/dev/null
assert_eq "IMAGE_DRIFT_TTL=0 always refetches" \
  "2" "$(token_calls)"

# --- The label that makes the comparison possible at all ----------------------
# build-image.yml's publish step must carry the creation label this file
# reads, alongside the revision label it already set for lib/version.sh's own
# purposes (#155's whole premise is that the registry can answer without a
# GitHub API scope this pipeline does not hold).

workflow="$SCRIPT_DIR/.github/workflows/build-image.yml"
assert_eq "the publish step stamps org.opencontainers.image.created" \
  "1" "$(grep -qE 'org\.opencontainers\.image\.created=' "$workflow" && echo 1 || echo 0)"
assert_eq "and org.opencontainers.image.revision, for the commit comparison" \
  "1" "$(grep -qE 'org\.opencontainers\.image\.revision=' "$workflow" && echo 1 || echo 0)"

# The verdict must never abort a heartbeat: the function is called under
# `set -e` from state-sync.sh, so every path above must also return 0.
( set -e
  TOKEN_FAIL=1 image_drift_status "$(version_json image oldcommit0000000 Poetic-Poems/agent-ops)" "" >/dev/null )
assert_eq "no path returns non-zero, even when every fetch fails" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
