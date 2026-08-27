#!/usr/bin/env bash
#
# test/release-pending-reservations.test.sh — regression tests for
# scripts/release-pending-reservations.sh (TD-PPagop-26082427): the retry
# pass for a tech-debt reservation release lib/tech-debt-file.sh's
# `_techdebt_unfile` could not make land the first time.
#
# Behaviours asserted:
#
#   - **A marker whose branch delete now succeeds is reported "released"**,
#     and its own marker file is cleared from the state repository.
#   - **A marker whose branch is already gone (a peer's concurrent retry, or
#     the ordinary release-td-branch.yml path) reports "absent"**, not an
#     error, and is cleared the same way.
#   - **A marker whose delete fails again reports "warning"**, and is left in
#     place — checked by asserting no DELETE of the marker file itself is
#     attempted.
#   - **A malformed marker (missing repo or branch) reports "warning"** and is
#     left in place rather than acted on.
#   - **No `state_repo` configured is a silent no-op** — no `gh` call at all.
#   - **An empty `reservation-releases/` tree is a silent no-op.**
#   - **One invocation covers markers naming different target repositories**,
#     each independently.
#
# `gh` is stubbed through RELEASE_PENDING_GH, the technique
# test/sweep-orphan-branches.test.sh's own SWEEP_GH already uses to bypass
# lib/github-limit.sh's rate-limit wrapper in tests.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/release-pending-reservations.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="$SCRIPT_DIR/scripts/release-pending-reservations.sh"

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

config_no_state="$tmp_dir/config-no-state.json"
jq -n '{}' > "$config_no_state"

config="$tmp_dir/config.json"
jq -n '{state_repo: "o/state"}' > "$config"

# --- The stub gh ---------------------------------------------------------------
# $tmp_dir/dirs.json            newline-separated dir names under reservation-releases/,
#                                one per line -- matching what `gh --jq '[...] | .[]'`
#                                actually prints for real, not a JSON array literal
# $tmp_dir/files-<dir>.json     newline-separated file names under reservation-releases/<dir>/
# $tmp_dir/marker-<dir>-<file>  the marker's own body (repo, branch) and a "sha"
#                                field this stub reports as the file's own blob sha
# $tmp_dir/delete-fails         branch names (one per line, "repo branch") whose
#                                git/refs/heads/<branch> DELETE fails
# $tmp_dir/absent-branches      branch names (one per line, "repo branch") whose
#                                git/ref/heads/<branch> GET 404s
# $tmp_dir/marker-delete-fails  "dir/file" entries whose marker DELETE fails
# $tmp_dir/calls                every invocation's argv, one per line
stub="$tmp_dir/gh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
d="$RELEASE_STUB_DIR"
printf '%s\n' "$*" >> "$d/calls"

# repos/<state_repo>/contents/reservation-releases  (top-level dir listing)
if [[ "$1" == "api" && "$2" == "repos/o/state/contents/reservation-releases" && "$3" == "--jq" ]]; then
  cat "$d/dirs.json" 2>/dev/null
  exit 0
fi

# repos/<state_repo>/contents/reservation-releases/<dir>  (file listing)
if [[ "$1" == "api" && "$2" == repos/o/state/contents/reservation-releases/* && "$3" == "--jq" ]]; then
  dir="${2##*/reservation-releases/}"
  cat "$d/files-$dir.json" 2>/dev/null
  exit 0
fi

# repos/<state_repo>/contents/reservation-releases/<dir>/<file>  (one marker's content)
if [[ "$1" == "api" && "$2" == repos/o/state/contents/reservation-releases/*/* ]]; then
  path="${2#repos/o/state/contents/reservation-releases/}"
  cat "$d/marker-${path//\//__}" 2>/dev/null && exit 0
  exit 1
fi

if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" && "$4" == repos/o/state/contents/reservation-releases/* ]]; then
  path="${4#repos/o/state/contents/reservation-releases/}"
  grep -qxF "$path" "$d/marker-delete-fails" 2>/dev/null && exit 1
  exit 0
fi

if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" && "$4" == *"/git/refs/heads/"* ]]; then
  repo="$(sed -E 's#repos/([^/]+/[^/]+)/git/refs/heads/.*#\1#' <<<"$4")"
  branch="${4##*/git/refs/heads/}"
  grep -qxF "$repo $branch" "$d/delete-fails" 2>/dev/null && exit 1
  exit 0
fi

if [[ "$1" == "api" && "$2" == *"/git/ref/heads/"* ]]; then
  repo="$(sed -E 's#repos/([^/]+/[^/]+)/git/ref/heads/.*#\1#' <<<"$2")"
  branch="${2##*/git/ref/heads/}"
  if grep -qxF "$repo $branch" "$d/absent-branches" 2>/dev/null; then
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
  echo '{"object":{"sha":"deadbeef"}}'
  exit 0
fi

exit 1
STUB
chmod +x "$stub"

reset_stub() {
  : > "$tmp_dir/calls"
  rm -f "$tmp_dir"/marker-*.json "$tmp_dir"/files-*.json
  : > "$tmp_dir/delete-fails"
  : > "$tmp_dir/absent-branches"
  : > "$tmp_dir/marker-delete-fails"
  : > "$tmp_dir/dirs.json"
}

# marker DIR FILE REPO BRANCH SHA -- writes the fixture files a listing of
# DIR would report FILE under, and the base64-content response for that
# path exactly as GitHub's contents API shapes it.
marker() {
  local dir="$1" file="$2" repo="$3" branch="$4" sha="${5:-abc123}"
  jq -nc --arg repo "$repo" --arg branch "$branch" --arg sha "$sha" \
    '{sha: $sha, content: (({repo: $repo, branch: $branch, ts: "2026-08-23T16:23:03Z"} | tojson) | @base64)}' \
    > "$tmp_dir/marker-${dir}__${file}"
}

run() { RELEASE_PENDING_GH="$stub" RELEASE_STUB_DIR="$tmp_dir" AGENT_OPS_CONFIG="$1" "$RELEASE"; }

# --- No state_repo configured -> silent no-op, gh never called -------------
reset_stub
out="$(run "$config_no_state")"; rc=$?
assert_eq "no state_repo: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"
assert_eq "  ... gh never called" "" "$(cat "$tmp_dir/calls")"

# --- Empty reservation-releases/ tree -> silent no-op -----------------------
reset_stub
out="$(run "$config")"; rc=$?
assert_eq "empty tree: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"

# --- A marker whose delete now succeeds -> released, and marker cleared ----
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082407.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082407.json" "o/r" "td/TD-PPagop-26082407"
out="$(run "$config")"; rc=$?
assert_eq "delete succeeds: exit 0" "0" "$rc"
assert_eq "  ... action released" "released" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... repo/branch reported" "o/r td/TD-PPagop-26082407" \
  "$(jq -r '"\(.repo) \(.branch)"' <<<"$out")"
assert_eq "  ... the branch delete was attempted" "1" \
  "$(grep -c 'api -X DELETE repos/o/r/git/refs/heads/td/TD-PPagop-26082407' "$tmp_dir/calls")"
assert_eq "  ... the marker itself was cleared" "1" \
  "$(grep -c 'api -X DELETE repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082407.json' "$tmp_dir/calls")"

# --- A marker whose branch is already gone -> absent, marker still cleared -
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082408.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082408.json" "o/r" "td/TD-PPagop-26082408"
echo "o/r td/TD-PPagop-26082408" > "$tmp_dir/delete-fails"
echo "o/r td/TD-PPagop-26082408" > "$tmp_dir/absent-branches"
out="$(run "$config")"; rc=$?
assert_eq "already absent: exit 0" "0" "$rc"
assert_eq "  ... action absent" "absent" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... the marker itself was still cleared" "1" \
  "$(grep -c 'api -X DELETE repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082408.json' "$tmp_dir/calls")"

# --- A marker whose delete fails again -> warning, marker left in place ----
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082409.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082409.json" "o/r" "td/TD-PPagop-26082409"
echo "o/r td/TD-PPagop-26082409" > "$tmp_dir/delete-fails"
out="$(run "$config")"; rc=$?
assert_eq "delete fails again: exit 0" "0" "$rc"
assert_eq "  ... action warning" "warning" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... the marker itself was NOT cleared" "0" \
  "$(grep -c 'api -X DELETE repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082409.json' "$tmp_dir/calls")"

# --- A malformed marker (no repo/branch) -> warning, left in place ---------
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "broken.json" > "$tmp_dir/files-o__r.json"
jq -nc '{sha: "abc123", content: ("{}" | @base64)}' > "$tmp_dir/marker-o__r__broken.json"
out="$(run "$config")"; rc=$?
assert_eq "malformed marker: exit 0" "0" "$rc"
assert_eq "  ... action warning" "warning" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... no DELETE of anything attempted" "0" \
  "$(grep -c 'api -X DELETE' "$tmp_dir/calls")"

# --- Two markers under different repo dirs are each handled independently --
reset_stub
printf 'o__r\nacme__widgets\n' > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082410.json" > "$tmp_dir/files-o__r.json"
echo "td__TD-PPagop-26082411.json" > "$tmp_dir/files-acme__widgets.json"
marker "o__r" "td__TD-PPagop-26082410.json" "o/r" "td/TD-PPagop-26082410"
marker "acme__widgets" "td__TD-PPagop-26082411.json" "acme/widgets" "td/TD-PPagop-26082411"
out="$(run "$config")"; rc=$?
n="$(jq -s 'length' <<<"$out")"
assert_eq "two repos: exit 0" "0" "$rc"
assert_eq "  ... two lines emitted" "2" "$n"
assert_eq "  ... both reported released" "released
released" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... both repos named" "acme/widgets
o/r" "$(jq -r '.repo' <<<"$out" | sort)"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$failures test(s) failed."
  exit 1
fi
