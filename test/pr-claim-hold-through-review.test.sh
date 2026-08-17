#!/usr/bin/env bash
#
# test/pr-claim-hold-through-review.test.sh — regression test for issue #360:
# the PR-keyed exclusion claim (issue #238) must survive past `pr-raised` and
# stay held until the claiming cycle's own true end, not be dropped the moment
# the item-keyed claim is (which is what let PR #353 be pushed by two
# engagements at once on 2026-08-13).
#
# release_claim and release_pr_claim are lifted whole out of agent-cycle.sh —
# same extraction technique test/pr-claim-exclusion.test.sh uses — so a
# regression in the real functions is what this suite catches, not a
# reimplementation of them. lib/claim.sh itself runs for real, through the
# same filesystem-CAS create-only `gh` stub test/claim.test.sh uses, so "a
# peer's claim on pr-<n> still loses" is proven by an actual contended
# create-only write, not by inspecting a variable.
#
# No network and no GitHub. Run directly:
#
#   ./test/pr-claim-hold-through-review.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- Lift release_claim and release_pr_claim whole out of agent-cycle.sh -------
extract_function() {  # extract_function <name>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$SCRIPT_DIR/agent-cycle.sh"
}

release_claim_src="$(extract_function release_claim)"
release_pr_claim_src="$(extract_function release_pr_claim)"

if [[ "$release_claim_src" != *"release_claim()"* ]]; then
  printf 'FAIL - could not extract release_claim from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$release_pr_claim_src" != *"release_pr_claim()"* ]]; then
  printf 'FAIL - could not extract release_pr_claim from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi

eval "$release_claim_src"
eval "$release_pr_claim_src"

# --- The stub gh: real create-only semantics, same as test/claim.test.sh -------
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

emit() { if [[ -n "$jqf" ]]; then jq -r "$jqf" <<<"$1"; else printf '%s\n' "$1"; fi; }

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

export GH_STUB_DIR="$tmp_dir/gh-state"
mkdir -p "$GH_STUB_DIR"
reg_dir="$GH_STUB_DIR/contents/claims"

seed_claim() {  # seed_claim <node> <key> <item> <source> <pr_number-or-empty>
  env CLAIM_GH="$stub_bin/gh" CLAIM_NODE="$1" CLAIM_CYCLE="cycle-$1" \
      CLAIM_ITEM="$3" CLAIM_SOURCE="$4" CLAIM_PR_NUMBER="${5:-}" \
      "$SCRIPT_DIR/lib/claim.sh" claim file "Poetic-Poems/poetic" "$2" >/dev/null 2>&1
}

release_directly() {  # release_directly <key>
  env CLAIM_GH="$stub_bin/gh" "$SCRIPT_DIR/lib/claim.sh" release file "Poetic-Poems/poetic" "$1" >/dev/null 2>&1
}

# --- Set up the globals release_claim/release_pr_claim depend on, exactly as ---
# --- agent-cycle.sh's own claim loop would have by the time an item is won -----
cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"
export CLAIM_GH="$stub_bin/gh"
# claim_release_timeout and selected_repo are consumed only by the eval'd
# release_claim/release_pr_claim, invisible to shellcheck.
# shellcheck disable=SC2034
claim_release_timeout=0
# shellcheck disable=SC2034
selected_repo="Poetic-Poems/poetic"

# poetic-2's own cycle wins the review-feedback item on PR #353, and — per the
# claim loop (requirement 17a) — the second, PR-keyed claim alongside it.
seed_claim poetic-2 "pr-353-review-501" "pr-353-review-501" review-feedback 353
seed_claim poetic-2 "pr-353" "pr-353-review-501" review-feedback 353

claim_active=1
claim_kind="file"
claim_key="pr-353-review-501"
claim_pr_key="pr-353"

# --- pr-raised: the item-keyed claim is released, the PR-keyed one is not ------
release_claim have-pr-pending

assert_eq "have-pr-pending drops the item-keyed registry entry" "0" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/pr-353-review-501.json" && echo 1 || echo 0)"
assert_eq "…but leaves the PR-keyed one standing" "1" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/pr-353.json" && echo 1 || echo 0)"
assert_eq "release_claim clears claim_active" "0" "$claim_active"
assert_eq "…but not claim_pr_key — the PR-keyed claim is still held" "pr-353" "$claim_pr_key"

# --- While the Reviewer stage is still running, a peer's fresh item on the -----
# --- same PR loses the PR-keyed claim: this is the exclusion issue #360 -------
# --- exists to keep alive past pr-raised. --------------------------------------
seed_claim ockham-2 "pr-353-review-777" "pr-353-review-777" review-feedback 353
rc=0
env CLAIM_GH="$stub_bin/gh" CLAIM_NODE=ockham-2 CLAIM_CYCLE=cycle-ockham-2 \
    CLAIM_ITEM="pr-353-review-777" CLAIM_SOURCE=review-feedback CLAIM_PR_NUMBER=353 \
    "$SCRIPT_DIR/lib/claim.sh" claim file "Poetic-Poems/poetic" "pr-353" >/dev/null 2>&1 || rc=$?
assert_eq "a peer's PR-keyed claim on the same PR loses while the Reviewer still runs (issue #360)" "3" "$rc"

# --- The Reviewer stage finishes (pr-ready): the PR-keyed claim releases now ---
release_pr_claim

assert_eq "release_pr_claim drops the PR-keyed registry entry" "0" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/pr-353.json" && echo 1 || echo 0)"
assert_eq "…and clears claim_pr_key" "" "$claim_pr_key"
assert_eq "release_pr_claim is idempotent — a second call is a harmless no-op" "0" \
  "$(release_pr_claim; echo $?)"

# --- Only once released does a peer's claim on the same PR succeed -------------
rc=0
env CLAIM_GH="$stub_bin/gh" CLAIM_NODE=ockham-2 CLAIM_CYCLE=cycle-ockham-2 \
    CLAIM_ITEM="pr-353-review-777" CLAIM_SOURCE=review-feedback CLAIM_PR_NUMBER=353 \
    "$SCRIPT_DIR/lib/claim.sh" claim file "Poetic-Poems/poetic" "pr-353" >/dev/null 2>&1 || rc=$?
assert_eq "…after which a peer's claim on the same PR wins" "0" "$rc"
release_directly "pr-353"
release_directly "pr-353-review-777"

# --- The one ending no handler reaches: an unhandled errexit abort after -------
# --- pr-raised. cleanup (the EXIT trap) is the backstop — the real cleanup -----
# --- runs here, under set -e in a subshell, with its cycle-record side ---------
# --- effects (Enabler, Refiner, events, state-sync, dashboard) stubbed and -----
# --- the real lib/ symlinked in, so release_pr_claim still drives the real -----
# --- lib/claim.sh against the same contended create-only store. ----------------
cleanup_src="$(extract_function cleanup)"
if [[ "$cleanup_src" != *"cleanup()"* ]]; then
  printf 'FAIL - could not extract cleanup from agent-cycle.sh (renamed or moved?)\n'
  failures=$(( failures + 1 ))
else
  seed_claim poetic-2 "pr-353" "pr-353-review-501" review-feedback 353

  stub_root="$tmp_dir/script-root"
  mkdir -p "$stub_root/scripts"
  # lib/, and the config claim.sh resolves against its own root — without
  # config.json, state_repo reads empty and every release is a vacuous no-op,
  # which would pass the wrong way. state-sync.sh alone is stubbed out.
  ln -s "$SCRIPT_DIR/lib" "$stub_root/lib"
  ln -s "$SCRIPT_DIR/config.json" "$stub_root/config.json"
  ln -s "$SCRIPT_DIR/config.schema.json" "$stub_root/config.schema.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_root/scripts/state-sync.sh"
  chmod +x "$stub_root/scripts/state-sync.sh"

  rc=0
  (
    set -e
    # The post-pr-raised state: release_claim have-pr-pending has run, so the
    # item-keyed claim is gone and only the PR-keyed one is still held. All
    # variables below are consumed by the eval'd cleanup/release_pr_claim,
    # invisible to shellcheck.
    # shellcheck disable=SC2034
    SCRIPT_DIR="$stub_root"
    # shellcheck disable=SC2034
    claim_active=0
    # shellcheck disable=SC2034
    claim_pr_key="pr-353"
    # shellcheck disable=SC2034
    clone_dir=""
    # shellcheck disable=SC2034
    lock_acquired=0
    # shellcheck disable=SC2034
    chain_eligible=0
    # Called only from the eval'd cleanup, which shellcheck cannot see into,
    # so each stub reads as unreachable to it.
    # shellcheck disable=SC2317
    maybe_run_enabler() { :; }
    # shellcheck disable=SC2317
    maybe_run_refiner() { :; }
    # shellcheck disable=SC2317
    issue_priority_cache_cleanup() { :; }
    # shellcheck disable=SC2317
    log_event() { :; }
    eval "$cleanup_src"
    trap cleanup EXIT
    false  # the unhandled abort: errexit ends the cycle between statements
  ) || rc=$?

  assert_eq "an unhandled errexit abort still exits non-zero through cleanup" "1" "$rc"
  assert_eq "…and cleanup's backstop releases the PR-keyed registry entry (issue #360)" "0" \
    "$(test -f "$reg_dir/Poetic-Poems__poetic/pr-353.json" && echo 1 || echo 0)"
fi

# --- A path with no PR at all ("have-pr"/"no-pr") still drops both together ----
# --- in the same call — the ordinary end-of-cycle shape, unchanged by #360. ----
seed_claim poetic-3 "pr-500-review-1" "pr-500-review-1" review-feedback 500
seed_claim poetic-3 "pr-500" "pr-500-review-1" review-feedback 500
claim_active=1
# shellcheck disable=SC2034
claim_kind="file"
# shellcheck disable=SC2034
claim_key="pr-500-review-1"
claim_pr_key="pr-500"

release_claim no-pr

assert_eq "release_claim no-pr drops the item-keyed entry" "0" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/pr-500-review-1.json" && echo 1 || echo 0)"
assert_eq "…and the PR-keyed one too, in the same call" "0" \
  "$(test -f "$reg_dir/Poetic-Poems__poetic/pr-500.json" && echo 1 || echo 0)"
assert_eq "…clearing claim_pr_key" "" "$claim_pr_key"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
