#!/usr/bin/env bash
#
# test/pr-claim-exclusion.test.sh — regression tests for issue #238's two
# deterministic-code pieces of PR-level claim exclusion, both lifted whole out
# of agent-cycle.sh rather than reimplemented, so a change to the real
# function is what this suite exercises:
#
#   - gather_claimed: the PR-keyed claim's pr_number rides the dedup along
#     with the item-keyed claim's, so a peer's claim on the same PR under a
#     different item ref is visible without an extra lookup.
#   - exclude_claimed_prs: the finishing sources' own candidate arrays are
#     filtered by that pr_number before they ever reach the Co-Ordinator —
#     deterministic code, not a comparison the model has to remember to make
#     per candidate (the failure mode that let PR #205 be worked by three
#     nodes at once: a Co-Ordinator "saw" a peer's claim and reasoned past it
#     because the item ref didn't match).
#
# Requirement 3q extends the same decision from PR numbers to item refs, and
# requirement 17a applies it again on the claim side, so this suite also
# covers:
#
#   - exclude_claimed_items: every pre-fetched source's array is filtered by
#     claimed item ref before the Co-Ordinator sees it (the failure mode of
#     2026-08-09: a Co-Ordinator read four issues as claimed and ranked
#     three of them as alternates anyway).
#   - candidate_preclaimed: the claim loop's own pre-claim check — a
#     candidate the cycle's gather already saw claimed is skipped without
#     spending a claim attempt on a foregone conclusion.
#
# test/claim.test.sh covers the underlying claim primitive (two item refs on
# one PR, only one PR-level claim survives); test/enabler-eligibility.test.sh
# covers enabler_eligible_items itself. This is the third leg: the Script's
# own filtering code around both.
#
# No network and no GitHub beyond the same filesystem-CAS gh stub
# test/claim.test.sh uses. Run directly:
#
#   ./test/pr-claim-exclusion.test.sh
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

# --- Lift gather_claimed and exclude_claimed_prs whole out of agent-cycle.sh ----
# Each is a self-contained function (no other agent-cycle.sh state besides the
# globals set up below), delimited by its own `name() {` line and a `}` back at
# column 0 — the same extraction shape test/signal-exit.test.sh uses.
extract_function() {  # extract_function <name>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$SCRIPT_DIR/lib/candidate-select.sh"
}

gather_claimed_src="$(extract_function gather_claimed)"
exclude_claimed_prs_src="$(extract_function exclude_claimed_prs)"
exclude_claimed_items_src="$(extract_function exclude_claimed_items)"
candidate_preclaimed_src="$(extract_function candidate_preclaimed)"
pr_number_for_candidate_src="$(extract_function pr_number_for_candidate)"
# Requirement 3t/3u's own filter, lifted for the same reason as the rest: the
# band-eligibility block below calls it, and the whole point of running that
# block (issue #1119) is that the real subtraction is what the staleness test
# then has to survive.
exclude_blocked_or_void_items_src="$(extract_function exclude_blocked_or_void_items)"

if [[ "$gather_claimed_src" != *"gather_claimed()"* ]]; then
  printf 'FAIL - could not extract gather_claimed from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$exclude_claimed_prs_src" != *"exclude_claimed_prs()"* ]]; then
  printf 'FAIL - could not extract exclude_claimed_prs from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$exclude_claimed_items_src" != *"exclude_claimed_items()"* ]]; then
  printf 'FAIL - could not extract exclude_claimed_items from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$candidate_preclaimed_src" != *"candidate_preclaimed()"* ]]; then
  printf 'FAIL - could not extract candidate_preclaimed from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$pr_number_for_candidate_src" != *"pr_number_for_candidate()"* ]]; then
  printf 'FAIL - could not extract pr_number_for_candidate from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$exclude_blocked_or_void_items_src" != *"exclude_blocked_or_void_items()"* ]]; then
  printf 'FAIL - could not extract exclude_blocked_or_void_items from lib/candidate-select.sh (renamed or moved?)\n'
  exit 1
fi

eval "$gather_claimed_src"
eval "$exclude_claimed_prs_src"
eval "$exclude_claimed_items_src"
eval "$candidate_preclaimed_src"
eval "$pr_number_for_candidate_src"
eval "$exclude_blocked_or_void_items_src"

# --- The stub gh (same filesystem CAS as test/claim.test.sh) -------------------
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
d="${GH_STUB_DIR:?}"
method=GET; path=""; jqf=""; slurp=0; declare -A f=()
args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
  case "${args[i]}" in
    -X)   method="${args[i+1]}"; (( i++ )) ;;
    -f)   kv="${args[i+1]}"; f["${kv%%=*}"]="${kv#*=}"; (( i++ )) ;;
    --jq) jqf="${args[i+1]}"; (( i++ )) ;;
    --paginate) ;;
    --slurp) slurp=1 ;;
    repos/*) path="${args[i]}" ;;
  esac
done
emit() { if [[ -n "$jqf" ]]; then jq -r "$jqf" <<<"$1"; else printf '%s\n' "$1"; fi; }
case "$method $path" in
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
  "GET "*/git/matching-refs/heads/*)
    # --slurp wraps each page's array in an outer array, exactly as gh does.
    if (( slurp )); then emit '[[]]'; else emit '[]'; fi; exit 0 ;;
esac
exit 1
STUB
chmod +x "$stub_bin/gh"

export GH_STUB_DIR="$tmp_dir/gh-state"
mkdir -p "$GH_STUB_DIR"
export CLAIM_GH="$stub_bin/gh"

# gather_claimed shells out to "$SCRIPT_DIR/lib/claim.sh" directly (never a
# configurable override), so it needs the globals the real agent-cycle.sh
# would have set by the time it runs. branch_prefix is consumed by the eval'd
# gather_claimed, which shellcheck cannot see into.
cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"
# shellcheck disable=SC2034
branch_prefix="agent/"

seed_claim() {  # seed_claim <slug> <key> <item> <pr_number-or-empty>
  env CLAIM_NODE=node-a CLAIM_CYCLE=cycle-a CLAIM_ITEM="$3" CLAIM_SOURCE=review-feedback \
      CLAIM_PR_NUMBER="${4:-}" "$SCRIPT_DIR/lib/claim.sh" claim file "$1" "$2" >/dev/null 2>&1
}

# --- gather_claimed: pr_number survives the item-ref/PR-ref dedup --------------
seed_claim Poetic-Poems/poetic pr-77-review-501 pr-77-review-501 77
seed_claim Poetic-Poems/poetic pr-77 pr-77-review-501 77
seed_claim Poetic-Poems/poetic td/TD1 TD1

claimed_out="$(gather_claimed Poetic-Poems/poetic)"
assert_eq "gather_claimed reports pr_number for the PR-claimed item" "77" \
  "$(jq -r '.[] | select(.item == "pr-77-review-501") | .pr_number' <<<"$claimed_out")"
assert_eq "an ordinary tech-debt claim carries no pr_number at all" "absent" \
  "$(jq -r 'map(select(.item == "TD1")) | if length == 0 then "missing-row" else (.[0].pr_number // "absent") end' <<<"$claimed_out")"
assert_eq "…and the field is genuinely absent, not null" "1" \
  "$(jq '[.[] | select(.item == "TD1")] | map(has("pr_number") | not) | all | if . then 1 else 0 end' <<<"$claimed_out")"
assert_eq "gather_claimed dedups the item-keyed and PR-keyed entries into one row" "1" \
  "$(jq '[.[] | select(.item == "pr-77-review-501")] | length' <<<"$claimed_out")"

# --- exclude_claimed_prs: the repo loop's own filter ----------------------------
candidates='[
  {"ref": "pr-57-review-1", "pr_number": 57},
  {"ref": "pr-58-review-2", "pr_number": 58},
  {"ref": "pr-59-abandoned-abc123", "pr_number": null}
]'
filtered="$(exclude_claimed_prs "$candidates" '[57]')"
assert_eq "exclude_claimed_prs drops the candidate on an already-claimed PR" "2" \
  "$(jq 'length' <<<"$filtered")"
assert_eq "…keeping the unclaimed PR's candidate" "58" \
  "$(jq -r '.[] | select(.ref == "pr-58-review-2") | .pr_number' <<<"$filtered")"
assert_eq "…and a candidate with no pr_number at all (never filtered on)" "1" \
  "$(jq '[.[] | select(.ref == "pr-59-abandoned-abc123")] | length' <<<"$filtered")"
assert_eq "an empty claimed-PR set filters nothing" "3" \
  "$(jq 'length' <<<"$(exclude_claimed_prs "$candidates" '[]')")"

# --- exclude_claimed_prs feeding straight off gather_claimed's own output ------
claimed_prs="$(jq -c '[.[] | select(has("pr_number")) | .pr_number]' <<<"$claimed_out")"
end_to_end="$(exclude_claimed_prs '[{"ref": "pr-77-conflict-deadbeefcafe", "pr_number": 77}]' "$claimed_prs")"
assert_eq "gather_claimed's pr_number is exactly what excludes a fresh candidate on the same PR" "0" \
  "$(jq 'length' <<<"$end_to_end")"

# --- exclude_claimed_items: the item-ref filter over every pre-fetched array (3q) --
item_candidates='[
  {"ref": "238", "number": 238},
  {"ref": "247", "number": 247},
  {"ref": "register-hygiene-422a6ef41c6f"},
  {"title": "no ref at all"}
]'
item_filtered="$(exclude_claimed_items "$item_candidates" '["247", "register-hygiene-422a6ef41c6f"]')"
assert_eq "exclude_claimed_items drops every candidate whose ref a peer holds" "2" \
  "$(jq 'length' <<<"$item_filtered")"
assert_eq "…keeping the unclaimed issue" "1" \
  "$(jq '[.[] | select(.ref == "238")] | length' <<<"$item_filtered")"
assert_eq "…and a candidate with no ref at all (never filtered on)" "1" \
  "$(jq '[.[] | select(.title == "no ref at all")] | length' <<<"$item_filtered")"
assert_eq "an empty claimed-item set filters nothing" "4" \
  "$(jq 'length' <<<"$(exclude_claimed_items "$item_candidates" '[]')")"
assert_eq "a malformed claimed-item set degrades to passing the array through" "4" \
  "$(jq 'length' <<<"$(exclude_claimed_items "$item_candidates" 'not json')")"

# --- exclude_claimed_items feeding straight off gather_claimed's own output ----
# The 2026-08-09 shape end-to-end: the peer's claim branch alone (registry or
# not) is what keeps the issue out of the Co-Ordinator's input.
claimed_items="$(jq -c '[.[].item]' <<<"$claimed_out")"
issues_after="$(exclude_claimed_items '[{"ref": "TD1", "number": 1}, {"ref": "TD2", "number": 2}]' "$claimed_items")"
assert_eq "gather_claimed's item ref is exactly what excludes a candidate on the same item" "1" \
  "$(jq 'length' <<<"$issues_after")"
assert_eq "…and the survivor is the unclaimed one" "TD2" \
  "$(jq -r '.[0].ref' <<<"$issues_after")"

# --- The argv cap (requirement 4g) ---------------------------------------------
# Both claims arrays grow with the fleet's live claim count, and both functions
# degrade fail-*open*: on a jq failure the candidate array passes through
# unfiltered. Delivered via `--argjson`, that made the cap's arrival past
# MAX_ARG_STRLEN (131072 bytes, the kernel's per-entry argv cap) reopen exactly
# the claimed-work proposals #305 closed — silently, because passing a
# candidate through is what this function does on purpose in every other
# failure. Requirement 4g puts both arrays on stdin; these pin it, with
# fixtures the size assertions prove are genuinely past the cap. The filler PR
# numbers start well above the fixture's own so the padding cannot do the
# filtering the assertion is attributing to the claim.
big_claimed_prs="$(jq -nc '[range(200000; 230000)] + [57]')"
assert_eq "the oversized claimed-PR fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_claimed_prs" | wc -c) > 131072 ))"
assert_eq "a claims array past the argv cap still drops the claimed PR" "2" \
  "$(jq 'length' <<<"$(exclude_claimed_prs "$candidates" "$big_claimed_prs")")"

big_claimed_items="$(jq -nc '[range(12000) | "fill-" + tostring] + ["247", "register-hygiene-422a6ef41c6f"]')"
assert_eq "the oversized claimed-item fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_claimed_items" | wc -c) > 131072 ))"
assert_eq "a claimed-item array past the argv cap still drops both claimed refs" "2" \
  "$(jq 'length' <<<"$(exclude_claimed_items "$item_candidates" "$big_claimed_items")")"

# --- The per-repo claims fold itself (requirement 4g, TD-PPagop-26081401) ------
# `claimed_json` is one of the five aggregates requirement 4g names as growing
# with the fleet's own history: the per-repo gather loop folds each repo's
# `gather_claimed` output into it once per repo, every cycle, forever. Lifted
# verbatim (inline loop body, not a function — same extraction shape
# test/finish-then-continue.test.sh already uses for the stand-down block),
# and eval'd with a `claimed_json` already past MAX_ARG_STRLEN to prove the
# fold survives an accumulator this large without dropping the new repo's
# claims or the ones already folded in.
extract_claims_fold() {
  awk '
    /^  claimed_fold_docs="\$\(printf/ { on = 1 }
    on                                 { print }
    on && /<<<"\$claimed_fold_docs"\)"$/ { exit }
  ' "$SCRIPT_DIR/lib/candidate-gather.sh"
}
claims_fold_block="$(extract_claims_fold)"
if [[ "$claims_fold_block" != *"claimed_fold_docs"* ]]; then
  echo "FAIL - could not extract the claims fold from lib/candidate-gather.sh — has it moved?" >&2
  exit 1
fi

run_claims_fold() {  # <claimed_json> <slug> <repo_claimed_json>
  (
    # slug and repo_claimed_json are consumed only by the eval'd
    # claims_fold_block, invisible to shellcheck.
    # shellcheck disable=SC2034
    claimed_json="$1" slug="$2" repo_claimed_json="$3"
    eval "$claims_fold_block"
    printf '%s' "$claimed_json"
  )
}

big_claimed_json="$(jq -nc '[range(6000) | {repo: "o/other", item: ("fill-" + (. | tostring)), pr_number: (1000 + .)}]')"
assert_eq "the oversized claimed_json fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_claimed_json" | wc -c) > 131072 ))"
new_repo_claims='[{"item": "247", "pr_number": 305}]'
folded="$(run_claims_fold "$big_claimed_json" "o/r" "$new_repo_claims")"
assert_eq "the fold past the argv cap still carries every already-accumulated claim" \
  "6001" "$(jq 'length' <<<"$folded")"
assert_eq "  ... plus the new repo's own claim, tagged with its repo" \
  "1" "$(jq '[.[] | select(.repo == "o/r" and .item == "247" and .pr_number == 305)] | length' <<<"$folded")"

# --- candidate_preclaimed: the claim loop's own pre-claim check (17a) -----------
claims_fixture='[
  {"repo": "o/r", "item": "247", "age_hours": 2},
  {"repo": "o/r", "item": "finding-tls-verify", "age_hours": null}
]'
rc=0; candidate_preclaimed "o/r" "247" "$claims_fixture" || rc=$?
assert_eq "a candidate whose repo+item the gather saw claimed is pre-claimed" "0" "$rc"
rc=0; candidate_preclaimed "other/repo" "247" "$claims_fixture" || rc=$?
assert_eq "the same item ref on a different repo is not" "1" "$rc"
rc=0; candidate_preclaimed "o/r" "250" "$claims_fixture" || rc=$?
assert_eq "an unclaimed item is not pre-claimed" "1" "$rc"
# The sanitised-form match: a claim derived from a branch name has already
# been through claim_branch_for's character flattening, so the raw item ref
# the Co-Ordinator returns must still hit it.
rc=0; candidate_preclaimed "o/r" "finding tls/verify" "$claims_fixture" || rc=$?
assert_eq "a claim recorded in branch-sanitised form still matches the raw ref" "0" "$rc"
rc=0; candidate_preclaimed "o/r" "247" 'not json' || rc=$?
assert_eq "malformed claims JSON fails open — the atomic claim stays the gate" "1" "$rc"

# --- pr_number_for_candidate: the PR-keyed claim's key never depends on the model --
# The claim in the selection loop is the hard gate (requirement 17a), so it must
# key on a number the Script can always work out for itself. A Co-Ordinator that
# forgot prompts/coordinator.md's "carry the entry's pr_url and pr_number" must
# not be able to switch the gate off by omission.
assert_eq "the candidate's own pr_number is used when it has one" "57" \
  "$(pr_number_for_candidate '{"pr_number": 57}' 'pr-57-review-1')"
assert_eq "a review-feedback ref alone yields the PR number" "57" \
  "$(pr_number_for_candidate '{}' 'pr-57-review-4718691960')"
assert_eq "a merge-conflicts ref alone yields the PR number" "205" \
  "$(pr_number_for_candidate '{}' 'pr-205-conflict-305ca060016d')"
assert_eq "an abandoned-drafts ref alone yields the PR number" "80" \
  "$(pr_number_for_candidate '{"pr_number": null}' 'pr-80-abandoned-6319fee06dfc')"
assert_eq "a non-numeric pr_number falls back to the ref rather than poisoning the key" "57" \
  "$(pr_number_for_candidate '{"pr_number": "#57"}' 'pr-57-review-1')"
assert_eq "a pr_number given as a numeric string is accepted" "57" \
  "$(pr_number_for_candidate '{"pr_number": "57"}' 'pr-99-review-1')"
assert_eq "an item ref of no PR shape yields nothing, and no PR claim is taken" "" \
  "$(pr_number_for_candidate '{}' 'TD26071805')"
assert_eq "malformed candidate JSON degrades to the ref" "57" \
  "$(pr_number_for_candidate 'not json' 'pr-57-review-1')"

# --- The Enabler stale-conflict/abandoned-draft ref filter ---------------------
# Neither half is a standalone function (both run inline — the live-set
# snapshot and requirement 3t/3u's subtraction inside
# `compute_band_eligibility`, the staleness test inside
# `compute_enabler_eligible_set`, since #771), so each is lifted by its own
# start/end markers instead of a function signature — same technique, same
# reason: the real code is what runs here, not a reimplementation of it.
#
# Both halves, not just the second, and in the order agent-cycle.sh calls them
# (issue #1119). Requirement 35e's live set is sampled before requirement
# 3t/3u subtracts the blocked and void entries from every band, and a blocked
# entry is the only kind the Enabler is ever eligible for — so a test that
# hands the staleness filter a hand-built `ordered_repos_json` still
# containing a blocked ref is asserting against a state no real cycle can
# reach. That is exactly what this suite used to do, and it is why the
# regression that skipped every blocked SHA-scoped PR ref as stale, on every
# cycle of every node, went unnoticed from 2026-08-13 to 2026-08-30.
extract_band_eligibility_block() {
  awk '
    /^gathered_pr_refs_json="\$\(jq -c \\$/ { on = 1 }
    on                                        { print }
    on && /^done$/                            { exit }
  ' "$SCRIPT_DIR/lib/eligibility.sh"
}
extract_stale_ref_block() {
  awk '
    /^live_pr_refs_json="\$\{gathered_pr_refs_json-\}"$/ { on = 1 }
    on                                                     { print }
    on && /^fi$/                                           { exit }
  ' "$SCRIPT_DIR/lib/eligibility.sh"
}
band_eligibility_block_src="$(extract_band_eligibility_block)"
stale_ref_block_src="$(extract_stale_ref_block)"
if [[ "$band_eligibility_block_src" != *"exclude_blocked_or_void_items"* \
   || "$band_eligibility_block_src" != *"gathered_pr_refs_json"* ]]; then
  printf 'FAIL - could not extract the band-eligibility block from lib/eligibility.sh (moved or reworded?)\n'
  exit 1
fi
if [[ "$stale_ref_block_src" != *"stale_enabler_refs_json"* ]]; then
  printf 'FAIL - could not extract the stale-ref block from lib/eligibility.sh (moved or reworded?)\n'
  exit 1
fi

# The pair, run back to back over one `ordered_repos_json`, exactly as
# agent-cycle.sh:1623-1624 runs them. `blocked_json`/`void_json` default empty
# so the existing head-SHA assertions below read unchanged.
run_stale_ref_block() {  # run_stale_ref_block <ordered-repos-json> <enabler-eligible-json> [blocked-json] [void-json]
  # Every one of these is consumed by the eval'd blocks below, which the
  # linter cannot see into.
  # shellcheck disable=SC2034
  ordered_repos_json="$1" enabler_eligible_json="$2" blocked_json="${3:-[]}" void_json="${4:-[]}"
  # shellcheck disable=SC2034
  logged="" logged_fields="" gathered_pr_refs_json=""
  # shellcheck disable=SC2317
  log_event() { logged="$logged$1 $2\n"; logged_fields="$2"; }
  # shellcheck disable=SC2317
  guard_warn() { :; }
  eval "$band_eligibility_block_src"
  eval "$stale_ref_block_src"
  # `.ordered` reports back what requirement 3t/3u left in the bands, so an
  # assertion can check both halves of the fix at once. It reports `null` for
  # an `ordered_repos_json` that was never JSON — the degradation case below
  # feeds this harness deliberate garbage, and that case is about the eligible
  # set, not the bands.
  local ordered_out="$ordered_repos_json"
  jq -e 'type == "array"' <<<"$ordered_out" >/dev/null 2>&1 || ordered_out='null'
  jq -c -n --argjson e "$enabler_eligible_json" --arg l "$logged" --arg f "$logged_fields" \
    --argjson o "$ordered_out" \
    '{eligible: $e, logged: $l, fields: $f, ordered: $o}'
}

ordered='[{"slug": "o/r",
           "merge_conflicts": [{"ref": "pr-205-conflict-6319fee06dfc"}],
           "abandoned_drafts": []}]'
eligible='[
  {"repo": "o/r", "item": "pr-205-conflict-305ca060016d", "reason": "threshold"},
  {"repo": "o/r", "item": "pr-205-conflict-6319fee06dfc", "reason": "threshold"},
  {"repo": "o/r", "item": "TD123", "reason": "threshold"}
]'
result="$(run_stale_ref_block "$ordered" "$eligible")"
assert_eq "the stale ref (superseded head SHA) is dropped from enabler_eligible" "0" \
  "$(jq '[.eligible[] | select(.item == "pr-205-conflict-305ca060016d")] | length' <<<"$result")"
assert_eq "the live conflict ref (matches this cycle's own gather) survives" "1" \
  "$(jq '[.eligible[] | select(.item == "pr-205-conflict-6319fee06dfc")] | length' <<<"$result")"
assert_eq "an unrelated blocked item kind (tech-debt) is untouched" "1" \
  "$(jq '[.eligible[] | select(.item == "TD123")] | length' <<<"$result")"
assert_eq "the drop is logged, not silent" "true" \
  "$(jq -r '.logged | test("enabler-stale-refs-skipped")' <<<"$result")"
# The payload's *type* is load-bearing: log_event's envelope merge is jq `+`,
# which cannot add an object and an array, and the bare-array form of this
# payload is what crash-looped the whole fleet pre-selection on 2026-08-13
# (issue #361) — the first time the guard above ever fired in production.
assert_eq "  ... and the logged payload is a JSON object, never a bare array (issue #361)" "object" \
  "$(jq -r '.fields | fromjson | type' <<<"$result")"
assert_eq "  ... carrying the dropped refs under .skipped" "pr-205-conflict-305ca060016d" \
  "$(jq -r '.fields | fromjson | .skipped[0].item' <<<"$result")"

# The merge-conflicts gather's *other* shape, `pr-<n>-superseded-<sha>`
# (requirement 3g, TD-PPagop-26081304), is scoped to the same head SHA and comes
# from the same array, so requirement 35e's filter must reach it identically. It
# is not hypothetical: a supersession void requirement 34d refuses — the newer
# bump merged between the gather and the void, or `gh pr list` failed — is
# recorded blocked under exactly this ref (requirement 32a), and a shape this
# filter cannot see would sit `enabler_eligible` forever, which is the
# `pr-205-conflict-305ca060016d` engagement-per-recheck failure issue #238 closed.
sup_ordered='[{"slug": "o/r",
               "merge_conflicts": [{"ref": "pr-129-superseded-c96c8ef9d31a"}],
               "abandoned_drafts": []}]'
sup_eligible='[
  {"repo": "o/r", "item": "pr-129-superseded-aaaaaaaaaaaa", "reason": "threshold"},
  {"repo": "o/r", "item": "pr-129-superseded-c96c8ef9d31a", "reason": "threshold"}
]'
sup_result="$(run_stale_ref_block "$sup_ordered" "$sup_eligible")"
assert_eq "a stale superseded-shape ref is dropped too" "0" \
  "$(jq '[.eligible[] | select(.item == "pr-129-superseded-aaaaaaaaaaaa")] | length' <<<"$sup_result")"
assert_eq "  ... while the one this cycle's gather still reports survives" "1" \
  "$(jq '[.eligible[] | select(.item == "pr-129-superseded-c96c8ef9d31a")] | length' <<<"$sup_result")"

# A PR fully resolved (no longer conflicted or abandoned at all) supersedes its
# blocked ref exactly as a moved head does — absent from the live set either way.
resolved_ordered='[{"slug": "o/r", "merge_conflicts": [], "abandoned_drafts": []}]'
resolved_result="$(run_stale_ref_block "$resolved_ordered" "$eligible")"
assert_eq "a resolved PR's now-stale ref is dropped too" "0" \
  "$(jq '[.eligible[] | select(.item == "pr-205-conflict-305ca060016d" or .item == "pr-205-conflict-6319fee06dfc")] | length' <<<"$resolved_result")"

# Issue #1119, the reason both halves now run: a blocked ref that this cycle's
# gather still reports must survive to `enabler_eligible`. Requirement 3t/3u
# strips it out of `merge_conflicts` on the way past — that is its job, and the
# Co-Ordinator must not see it — but requirement 35e's live set was sampled
# before that, so the staleness test still finds it. This is PR #1059's own
# state on 2026-08-30: open, non-draft, conflicting at a head that never moved,
# recorded blocked by `implementer exited 137`, re-reported by
# scripts/gather-merge-conflicts.sh every cycle, and skipped as stale 96 times.
blocked_ordered='[{"slug": "o/r",
                   "merge_conflicts": [{"ref": "pr-1059-conflict-f108aca762e5"}],
                   "dequeued": [], "abandoned_drafts": []}]'
blocked_blocked='[{"repo": "o/r", "item": "pr-1059-conflict-f108aca762e5",
                   "ts": "2026-08-30T12:27:28Z", "detail": "implementer exited 137"}]'
blocked_eligible='[{"repo": "o/r", "item": "pr-1059-conflict-f108aca762e5", "reason": "threshold"}]'
blocked_result="$(run_stale_ref_block "$blocked_ordered" "$blocked_eligible" "$blocked_blocked")"
assert_eq "a blocked ref the gather still reports reaches the Enabler (issue #1119)" "1" \
  "$(jq '[.eligible[] | select(.item == "pr-1059-conflict-f108aca762e5")] | length' <<<"$blocked_result")"
assert_eq "  ... and nothing is logged as stale, because nothing is" "false" \
  "$(jq -r '.logged | test("enabler-stale-refs-skipped")' <<<"$blocked_result")"
assert_eq "  ... while requirement 3t/3u still keeps it from the Co-Ordinator's band" "0" \
  "$(jq '.ordered[0].merge_conflicts | length' <<<"$blocked_result")"

# The converse, over the same pair: a blocked ref the gather has stopped
# reporting (the head moved, or the PR resolved) is still dropped. Requirement
# 35e's whole purpose survives the fix — this is the `pr-205-conflict-…`
# engagement-per-recheck case issue #238 closed.
moved_ordered='[{"slug": "o/r",
                 "merge_conflicts": [{"ref": "pr-1059-conflict-9f5401ba7ad4"}],
                 "dequeued": [], "abandoned_drafts": []}]'
moved_result="$(run_stale_ref_block "$moved_ordered" "$blocked_eligible" "$blocked_blocked")"
assert_eq "a blocked ref at a head the gather no longer reports is still dropped" "0" \
  "$(jq '[.eligible[] | select(.item == "pr-1059-conflict-f108aca762e5")] | length' <<<"$moved_result")"
assert_eq "  ... and that drop is logged" "true" \
  "$(jq -r '.logged | test("enabler-stale-refs-skipped")' <<<"$moved_result")"

# The degradation requirement 35e promises: a jq failure deriving the live set
# leaves the eligible set *unfiltered*. The distinction that makes this work is
# that an empty live set means "nothing is in either state" (assert above: it
# filters) while a failed one means nothing at all — so it must not filter, or
# one bad `ordered_repos_json` would drop every conflict/abandoned ref the
# Enabler was eligible to examine and log them as superseded, which they are not.
broken_result="$(run_stale_ref_block 'not json at all' "$eligible")"
assert_eq "a failed live-set derivation leaves the eligible set unfiltered" "3" \
  "$(jq '.eligible | length' <<<"$broken_result")"
assert_eq "…including the ref an empty live set would have dropped" "1" \
  "$(jq '[.eligible[] | select(.item == "pr-205-conflict-305ca060016d")] | length' <<<"$broken_result")"
assert_eq "…and nothing is logged as stale on that path" "false" \
  "$(jq -r '.logged | test("enabler-stale-refs-skipped")' <<<"$broken_result")"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
