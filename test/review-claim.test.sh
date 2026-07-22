#!/usr/bin/env bash
#
# test/review-claim.test.sh — the review-branch claim wiring (R5.0/R5c).
#
# lib/claim.sh's own semantics are covered by test/claim.test.sh; what this
# suite pins is the *wiring*: that review-cycle.sh claims `review/<date>`
# before anything expensive, skips the repo on a lost claim AND on a claim
# error (fail closed), and releases on the failure path — the leak the
# implementation pipeline fixed in its own workspace path (#55) must not be
# reintroduced here.
#
# Offline throughout: `gh` and `claude` on PATH fail fast (the skip-guards
# degrade to "proceed", the clone fails, no model ever runs), the claim goes
# through CLAIM_GH to the same filesystem-CAS stub test/claim.test.sh uses,
# TOGGLE_GH fails like an unreachable state repo (fleet flags fall back to
# enabled), and the cleanup push lands in a local bare repository. Run
# directly:
#
#   ./test/review-claim.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW="$SCRIPT_DIR/review-cycle.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- The stub gh for CLAIM_GH (same filesystem CAS as test/claim.test.sh) -----
stub_bin="$tmp_dir/claim-bin"
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

emit() {
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
    ( set -C; printf '%s' "${f[content]}" > "$p" ) 2>/dev/null || exit 1
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
esac
exit 1
STUB
chmod +x "$stub_bin/gh"

# --- Fail-fast PATH shims: the skip-guards degrade to "proceed", the clone
# --- fails, and no model can ever launch.
fail_bin="$tmp_dir/fail-bin"
mkdir -p "$fail_bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_bin/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_bin/claude"
chmod +x "$fail_bin/gh" "$fail_bin/claude"

state_remote="$tmp_dir/state-remote.git"
git init --quiet --bare --initial-branch=main "$state_remote"

review_date="$(date -u +%Y-%m-%d)"

run_review() {  # run_review <home> <claim-gh> [env…] — real review-cycle.sh, offline
  local home="$1" claim_gh="$2"; shift 2
  mkdir -p "$home/.local/state/poetic-agents" "$home/.cache/poetic-agents/workspaces"
  env HOME="$home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$home")" \
    PATH="$fail_bin:$PATH" TOGGLE_GH=/bin/false \
    CLAIM_GH="$claim_gh" GH_STUB_DIR="$GH_STUB_DIR" \
    STATE_SYNC_REMOTE="$state_remote" "$@" \
    "$REVIEW" --repo poetic >/dev/null 2>&1
}

export GH_STUB_DIR="$tmp_dir/gh-state"
mkdir -p "$GH_STUB_DIR"

# --- A lost claim skips the repo before anything is cloned --------------------

mkdir -p "$GH_STUB_DIR/refs/Poetic-Poems/poetic/review"
printf 'othersha00' > "$GH_STUB_DIR/refs/Poetic-Poems/poetic/review/$review_date"

lost_home="$tmp_dir/node-lost"
run_review "$lost_home" "$stub_bin/gh"
assert_eq "a lost claim exits cleanly" "0" "$?"
lost_log="$(cat "$lost_home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null)"
assert_contains "a lost claim logs review-skipped" '"event":"review-skipped"' "$lost_log"
assert_contains "naming the branch and the other node" \
  "review branch review/$review_date is already claimed by another node" "$lost_log"
assert_eq "nothing was cloned" "0" \
  "$(find "$lost_home/.cache/poetic-agents/workspaces" -mindepth 1 -maxdepth 1 -name '[!.]*' 2>/dev/null | wc -l)"
assert_eq "no clone was even attempted" "0" \
  "$(find "$lost_home/.local/state/poetic-agents/reviews" -name 'clone-*.err' 2>/dev/null | wc -l)"
assert_eq "the other node's claim ref is untouched" "othersha00" \
  "$(cat "$GH_STUB_DIR/refs/Poetic-Poems/poetic/review/$review_date")"

# --- A claim error also skips, fail closed ------------------------------------

err_home="$tmp_dir/node-err"
run_review "$err_home" /bin/false
assert_eq "a claim error exits cleanly" "0" "$?"
err_log="$(cat "$err_home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null)"
assert_contains "a claim error logs review-skipped" '"event":"review-skipped"' "$err_log"
assert_contains "and says it failed closed" "standing this repo down, fail closed" "$err_log"
assert_eq "nothing was cloned there either" "0" \
  "$(find "$err_home/.cache/poetic-agents/workspaces" -mindepth 1 -maxdepth 1 -name '[!.]*' 2>/dev/null | wc -l)"

# --- A won claim proceeds, and a failed clone releases it ----------------------

rm -f "$GH_STUB_DIR/refs/Poetic-Poems/poetic/review/$review_date"

won_home="$tmp_dir/node-won"
run_review "$won_home" "$stub_bin/gh"
assert_eq "a won claim's run exits cleanly" "0" "$?"
won_log="$(cat "$won_home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null)"
assert_contains "the clone failure is the recorded outcome, not the claim" \
  '"stage":"workspace"' "$won_log"
assert_eq "the failed clone released the claim ref (unmoved, PR-less)" "0" \
  "$(test -f "$GH_STUB_DIR/refs/Poetic-Poems/poetic/review/$review_date" && echo 1 || echo 0)"
assert_eq "and dropped the registry entry" "0" \
  "$(find "$GH_STUB_DIR/contents/claims" -type f 2>/dev/null | wc -l)"
claim_log="$(cat "$won_home"/.local/state/poetic-agents/reviews/*/claim-Poetic-Poems_poetic.log 2>/dev/null)"
assert_contains "the claim log shows the win" "claim" "$claim_log"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
