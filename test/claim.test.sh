#!/usr/bin/env bash
#
# test/claim.test.sh — regression tests for lib/claim.sh (requirement 17a).
#
# The one property everything else rests on is atomicity: two nodes claiming
# the same item must produce exactly one winner, every time. The stub `gh`
# below is therefore not a canned-response stub — it implements real
# create-only semantics on the filesystem (noclobber for files, which the
# kernel arbitrates), so the concurrent tests race for real.
#
# Also covered: the release rules (a claim branch is deleted only when it is
# untouched AND no open PR uses it — pushed work is never deleted), the
# registry count that feeds back-pressure, the gc sweep's TTL, and `expire`
# (issue #237) — the backdate that lets a discarded engagement's tombstone
# retire on the next gc sweep without releasing it outright.
#
# No network and no GitHub. Run directly:
#
#   ./test/claim.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAIM="$SCRIPT_DIR/lib/claim.sh"

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

# --- The stub gh ---------------------------------------------------------------
# State lives under GH_STUB_DIR: refs/<slug>/<branch> hold a SHA each;
# contents/<path> hold base64 payloads. Creates use `set -C` (noclobber), so a
# create of something that exists fails exactly as GitHub's 422 does — and two
# concurrent creates are settled by the filesystem, not by luck. GH_STUB_FAIL=1
# makes every call fail (GitHub unreachable); GH_STUB_PRS fakes `pr list`.
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
d="${GH_STUB_DIR:?}"
[[ "${GH_STUB_FAIL:-0}" == "1" ]] && exit 1

if [[ "${1:-}" == "pr" ]]; then printf '%s\n' "${GH_STUB_PRS:-0}"; exit 0; fi

method=GET; path=""; jqf=""; declare -A f=()
args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
  case "${args[i]}" in
    -X)   method="${args[i+1]}"; (( i++ )) ;;
    -f)   kv="${args[i+1]}"; f["${kv%%=*}"]="${kv#*=}"; (( i++ )) ;;
    --jq) jqf="${args[i+1]}"; (( i++ )) ;;
    repos/*) path="${args[i]}" ;;
  esac
done

emit() {  # apply --jq the way gh would
  if [[ -n "$jqf" ]]; then jq -r "$jqf" <<<"$1"; else printf '%s\n' "$1"; fi
}

case "$method $path" in
  "POST "*/git/refs)
    slug="${path#repos/}"; slug="${slug%/git/refs}"
    ref="${f[ref]#refs/heads/}"
    file="$d/refs/$slug/$ref"
    mkdir -p "$(dirname "$file")"
    ( set -C; printf '%s' "${f[sha]}" > "$file" ) 2>/dev/null || exit 1
    exit 0 ;;
  "GET "*/git/ref/heads/*)
    slug="${path#repos/}"; slug="${slug%%/git/*}"
    ref="${path#*/git/ref/heads/}"
    if [[ "$ref" == "main" && ! -f "$d/refs/$slug/$ref" ]]; then
      emit '{"object":{"sha":"basesha000"}}'; exit 0
    fi
    [[ -f "$d/refs/$slug/$ref" ]] || exit 1
    emit "{\"object\":{\"sha\":\"$(cat "$d/refs/$slug/$ref")\"}}"; exit 0 ;;
  "DELETE "*/git/refs/heads/*)
    slug="${path#repos/}"; slug="${slug%%/git/*}"
    ref="${path#*/git/refs/heads/}"
    rm -f "$d/refs/$slug/$ref"; exit 0 ;;
  "PUT "*/contents/*)
    p="$d/contents/${path#*/contents/}"
    mkdir -p "$(dirname "$p")"
    if [[ -v 'f[sha]' ]]; then
      # A `sha` means "update" in the real contents API — real GitHub also
      # requires it to match the current content, which this stub does not
      # bother enforcing (callers here only ever expire what they just read).
      printf '%s' "${f[content]}" > "$p"
    else
      ( set -C; printf '%s' "${f[content]}" > "$p" ) 2>/dev/null || exit 1
    fi
    exit 0 ;;
  "GET "*/contents/*)
    p="$d/contents/${path#*/contents/}"
    if [[ -d "$p" ]]; then
      out="$(cd "$p" && for e in *; do
               [[ -e "$e" ]] || continue
               [[ -d "$e" ]] && t=dir || t=file
               printf '{"type":"%s","name":"%s"}\n' "$t" "$e"
             done | jq -sc '.')"
      emit "$out"; exit 0
    fi
    [[ -f "$p" ]] || exit 1
    emit "{\"sha\":\"stubsha\",\"content\":\"$(cat "$p")\"}"; exit 0 ;;
  "DELETE "*/contents/*)
    p="$d/contents/${path#*/contents/}"
    rm -f "$p"; exit 0 ;;
  "GET "*/git/matching-refs/heads/*)
    slug="${path#repos/}"; slug="${slug%%/git/*}"
    prefix="${path#*/git/matching-refs/heads/}"
    out="$(cd "$d/refs/$slug" 2>/dev/null \
      && find . -type f 2>/dev/null | sed 's|^\./||' | grep "^${prefix}" \
      | jq -R '{ref: ("refs/heads/" + .)}' | jq -sc '.')"
    [[ -n "$out" ]] || out='[]'
    emit "$out"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$stub_bin/gh"

export GH_STUB_DIR="$tmp_dir/gh-state"
mkdir -p "$GH_STUB_DIR"

run_claim() {  # run_claim <node-name> <args…>; prints nothing, returns claim.sh's rc
  env CLAIM_GH="$stub_bin/gh" CLAIM_NODE="$1" CLAIM_CYCLE="cycle-$1" \
      CLAIM_ITEM="${CLAIM_ITEM_OVERRIDE:-TD99}" CLAIM_SOURCE="${CLAIM_SOURCE_OVERRIDE:-tech-debt}" \
      "$CLAIM" "${@:2}" >/dev/null 2>&1
}

reg_dir="$GH_STUB_DIR/contents/claims"

# --- Two nodes race for the same branch claim ------------------------------------
run_claim node-a claim branch Poetic-Poems/poetic td/TD99 main &
pid_a=$!
run_claim node-b claim branch Poetic-Poems/poetic td/TD99 main &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
assert_eq "a raced branch claim has exactly one winner" "0 3" \
  "$(printf '%s\n' "$rc_a" "$rc_b" | sort -n | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the winning claim created the ref" "1" \
  "$(test -f "$GH_STUB_DIR/refs/Poetic-Poems/poetic/td/TD99" && echo 1 || echo 0)"
assert_eq "the winner recorded a registry entry" "1" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/td__TD99.json" && echo 1 || echo 0)"

# --- Two nodes race for the same file claim --------------------------------------
CLAIM_ITEM_OVERRIDE="pr-57-review-1" CLAIM_SOURCE_OVERRIDE="review-feedback" \
  run_claim node-a claim file Poetic-Poems/poetic pr-57-review-1 &
pid_a=$!
CLAIM_ITEM_OVERRIDE="pr-57-review-1" CLAIM_SOURCE_OVERRIDE="review-feedback" \
  run_claim node-b claim file Poetic-Poems/poetic pr-57-review-1 &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
assert_eq "a raced file claim has exactly one winner" "0 3" \
  "$(printf '%s\n' "$rc_a" "$rc_b" | sort -n | tr '\n' ' ' | sed 's/ $//')"

# --- GitHub unreachable fails closed ----------------------------------------------
GH_STUB_FAIL=1 run_claim node-a claim branch Poetic-Poems/poetic td/TD98 main
assert_eq "an unreachable GitHub is an error (1), not a win" "1" "$?"

# --- Release: untouched and PR-less → the ref goes --------------------------------
run_claim node-a release branch Poetic-Poems/poetic td/TD99
assert_eq "release deletes an untouched, PR-less claim branch" "0" \
  "$(test -f "$GH_STUB_DIR/refs/Poetic-Poems/poetic/td/TD99" && echo 1 || echo 0)"
assert_eq "release drops the registry entry" "0" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/td__TD99.json" && echo 1 || echo 0)"

# --- Release: a moved ref is kept --------------------------------------------------
run_claim node-a claim branch Poetic-Poems/poetic td/TD97 main
printf 'someothersha' > "$GH_STUB_DIR/refs/Poetic-Poems/poetic/td/TD97"
run_claim node-a release branch Poetic-Poems/poetic td/TD97
assert_eq "release keeps a claim branch that has moved" "1" \
  "$(test -f "$GH_STUB_DIR/refs/Poetic-Poems/poetic/td/TD97" && echo 1 || echo 0)"
assert_eq "…but still drops its registry entry" "0" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/td__TD97.json" && echo 1 || echo 0)"

# --- Release: an open PR protects the ref even when untouched ----------------------
run_claim node-a claim branch Poetic-Poems/poetic td/TD96 main
GH_STUB_PRS=1 run_claim node-a release branch Poetic-Poems/poetic td/TD96
assert_eq "release keeps an untouched branch that an open PR uses" "1" \
  "$(test -f "$GH_STUB_DIR/refs/Poetic-Poems/poetic/td/TD96" && echo 1 || echo 0)"

# --- Count feeds back-pressure ------------------------------------------------------
# Only the file claim is still live: every branch claim above was released,
# and a release always drops the registry entry (entries exist only until a
# PR — or a release — supersedes them).
count="$(env CLAIM_GH="$stub_bin/gh" "$CLAIM" count Poetic-Poems/poetic 2>/dev/null)"
assert_eq "count reports the live registry entries" "1" "$count"

# --- gc sweeps only what is old, and never pushed work ------------------------------
old_ts="$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
# An aged file claim: gc must remove it.
printf '%s' "$(jq -nc --arg ts "$old_ts" \
  '{node:"dead",cycle:"c",repo:"Poetic-Poems/poetic",key:"pr-1-review-9",kind:"file",branch:"",sha:"",item:"x",source:"review-feedback",ts:$ts}' \
  | base64 -w0)" > "$reg_dir/Poetic-Poems__poetic/pr-1-review-9.json"
# An aged branch claim whose ref has moved: gc keeps the ref, drops the entry.
printf 'pushedwork' > "$GH_STUB_DIR/refs/Poetic-Poems/poetic/td/TD96"
printf '%s' "$(jq -nc --arg ts "$old_ts" \
  '{node:"dead",cycle:"c",repo:"Poetic-Poems/poetic",key:"td/TD96",kind:"branch",branch:"td/TD96",sha:"basesha000",item:"TD96",source:"tech-debt",ts:$ts}' \
  | base64 -w0)" > "$reg_dir/Poetic-Poems__poetic/td__TD96.json"
env CLAIM_GH="$stub_bin/gh" "$CLAIM" gc >/dev/null 2>&1
assert_eq "gc removes an aged file claim" "0" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/pr-1-review-9.json" && echo 1 || echo 0)"
assert_eq "gc drops an aged branch claim's registry entry" "0" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/td__TD96.json" && echo 1 || echo 0)"
assert_eq "gc keeps a branch whose ref has moved (pushed work survives)" "1" \
  "$(test -f "$GH_STUB_DIR/refs/Poetic-Poems/poetic/td/TD96" && echo 1 || echo 0)"
# A fresh registry entry survives gc untouched.
run_claim node-a claim branch Poetic-Poems/poetic td/TD95 main
env CLAIM_GH="$stub_bin/gh" "$CLAIM" gc >/dev/null 2>&1
assert_eq "gc leaves a fresh claim alone" "1" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/td__TD95.json" && echo 1 || echo 0)"

# --- claims: registry entries younger than claim_ttl_hours (issue #175) -------------
CLAIM_ITEM_OVERRIDE="TD-CLAIMS-1" run_claim node-a claim branch Poetic-Poems/poetic td/TD-CLAIMS-1 main
claims_out="$(env CLAIM_GH="$stub_bin/gh" "$CLAIM" claims Poetic-Poems/poetic 2>/dev/null)"
assert_eq "claims lists a fresh branch claim's item" "1" \
  "$(jq '[.[] | select(.item == "TD-CLAIMS-1")] | length' <<<"$claims_out")"
assert_eq "claims tags it as a branch claim" "branch" \
  "$(jq -r '.[] | select(.item == "TD-CLAIMS-1") | .kind' <<<"$claims_out")"

old_ts="$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '%s' "$(jq -nc --arg ts "$old_ts" \
  '{node:"dead",cycle:"c",repo:"Poetic-Poems/poetic",key:"td/TD-OLD",kind:"branch",branch:"td/TD-OLD",sha:"basesha000",item:"TD-OLD",source:"tech-debt",ts:$ts}' \
  | base64 -w0)" > "$reg_dir/Poetic-Poems__poetic/td__TD-OLD.json"
printf 'oldsha' > "$GH_STUB_DIR/refs/Poetic-Poems/poetic/td/TD-OLD"
claims_out="$(env CLAIM_GH="$stub_bin/gh" "$CLAIM" claims Poetic-Poems/poetic 2>/dev/null)"
assert_eq "claims excludes an entry older than claim_ttl_hours (the staleness escape)" "0" \
  "$(jq '[.[] | select(.item == "TD-OLD")] | length' <<<"$claims_out")"

# --- branches: live td/*, <branch_prefix>* refs on the target repo (issue #175) ------
branches_out="$(env CLAIM_GH="$stub_bin/gh" "$CLAIM" branches Poetic-Poems/poetic 2>/dev/null)"
assert_eq "branches lists the live td/ claim branch, registry entry or not" "1" \
  "$(jq '[.[] | select(. == "td/TD-CLAIMS-1")] | length' <<<"$branches_out")"
assert_eq "branches is not TTL-filtered — the ref alone is the signal" "1" \
  "$(jq '[.[] | select(. == "td/TD-OLD")] | length' <<<"$branches_out")"

# --- expire: a discarded engagement's tombstone is backdated, not released ---------
# (issue #237) — an Enabler-style file claim under the pseudo-slug `enabler`.
CLAIM_ITEM_OVERRIDE="TD-EXPIRE-1" CLAIM_SOURCE_OVERRIDE="tech-debt" \
  run_claim node-a claim file enabler "Poetic-Poems__poetic__TD-EXPIRE-1__100"
assert_eq "expire leaves the registry entry in place, not released" "1" \
  "$(env CLAIM_GH="$stub_bin/gh" "$CLAIM" expire enabler "Poetic-Poems__poetic__TD-EXPIRE-1__100" >/dev/null 2>&1; \
     test -f "$reg_dir/enabler/Poetic-Poems__poetic__TD-EXPIRE-1__100.json" && echo 1 || echo 0)"
expired_entry="$(base64 -d < "$reg_dir/enabler/Poetic-Poems__poetic__TD-EXPIRE-1__100.json")"
assert_eq "expire backdates ts far past claim_ttl_hours" "1970-01-01T00:00:01Z" \
  "$(jq -r '.ts' <<<"$expired_entry")"
assert_eq "expire preserves the item the entry named" "TD-EXPIRE-1" \
  "$(jq -r '.item' <<<"$expired_entry")"
env CLAIM_GH="$stub_bin/gh" "$CLAIM" gc >/dev/null 2>&1
assert_eq "gc retires an expired claim on its very next sweep" "0" \
  "$(test -f "$reg_dir/enabler/Poetic-Poems__poetic__TD-EXPIRE-1__100.json" && echo 1 || echo 0)"

# expire on an unknown key is a silent no-op, not an error — the caller may
# race a gc sweep that already retired the same entry.
env CLAIM_GH="$stub_bin/gh" "$CLAIM" expire enabler "no-such-key"
assert_eq "expire on a missing entry is a silent no-op" "0" "$?"

# ------------------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
