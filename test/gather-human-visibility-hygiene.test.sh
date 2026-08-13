#!/usr/bin/env bash
#
# test/gather-human-visibility-hygiene.test.sh — regression test for
# scripts/gather-human-visibility-hygiene.sh (requirement 38e): turning a
# still-live human-visibility violation into an ordinary `human-visibility`
# candidate, or dropping one a live re-check shows has already resolved.
#
# The behaviours asserted, each failing silently if broken:
#
#   - **No violations handed in is `[]`.** The ordinary answer almost every
#     cycle gets — a repo with nothing recently logged against it.
#   - **A violation that still reproduces live becomes exactly one candidate**,
#     `source: "human-visibility"` (its own source, issue #284's decision 2 —
#     never `register-hygiene`), with its own `human-visibility-<hash>` ref.
#   - **The three warning classes are told apart (issue #284's decision 1).** A
#     `could not request review from …` violation clears only once a human
#     review is live or already given (`reviewRequests` non-empty, or
#     `reviewDecision` of `APPROVED`/`CHANGES_REQUESTED`); a
#     `could not post the idle nudge comment` violation — logged only against
#     an already-`APPROVED` pull request — clears only once the
#     `agent-ops:human-nudge` marker comment actually appears, never merely
#     because the pull request is approved. Using the request-class check for
#     both would silently drop every nudge-class warning on sight; this
#     confirms it does not. A `no legal review-request candidate` violation
#     (tech-debt/TD-PPagop-26081001.md) clears only once a non-author,
#     non-bot, submitted review appears, a review request is already pending
#     (CODEOWNERS' own auto-request, before anyone has reviewed), or the
#     assignee named in its own detail text no longer names the pull
#     request's author.
#   - **A pull-request violation of any class is dropped once merged, closed
#     or back in draft**, and a repo-level listing failure is dropped only
#     once the listing itself succeeds live.
#   - **An unreadable live re-check, or an unrecognised warning shape, keeps
#     the violation** — the same "never guess a read it could not make was
#     clean" reasoning `sweep-human-visibility.sh` itself uses.
#
# The script is run for real against a stubbed `gh`, so what is asserted is
# the shipped script rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gather-human-visibility-hygiene.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-human-visibility-hygiene.sh"

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

# --- A stub `gh`, answering only `pr list` and `pr view` -------------------
#
# `$STUB_LIST_RC` steers whether the repo-level listing re-check still fails
# (nonzero) or now succeeds (0, the default). `$STUB_PR_STATE`/`$STUB_PR_DRAFT`
# steer a named pull request's live open/draft state; `$STUB_REVIEW_DECISION`
# and `$STUB_REVIEW_REQUESTS` (nonzero means a pending request exists) steer
# the request-class check; `$STUB_NUDGE_MARKER` (`yes`/`no`) steers whether
# the nudge marker comment is present; `$STUB_AUTHOR` (default `author`) and
# `$STUB_REVIEWS` (a JSON array of `{author:{login},state}`, default `[]`)
# steer the no-candidate-class check; `$STUB_VIEW_RC` set nonzero makes the
# re-check itself unreadable, the fail-safe case.
mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-} ${2:-}" in
  "pr list")
    exit "${STUB_LIST_RC:-0}"
    ;;
  "pr view")
    (( "${STUB_VIEW_RC:-0}" == 0 )) || exit "$STUB_VIEW_RC"
    reqs="[]"
    [[ "${STUB_REVIEW_REQUESTS:-0}" == "0" ]] || reqs='[{"login":"reviewer"}]'
    comments="[]"
    [[ "${STUB_NUDGE_MARKER:-no}" != "yes" ]] || comments='[{"body":"<!-- agent-ops:human-nudge -->"}]'
    printf '{"state":"%s","isDraft":%s,"reviewDecision":"%s","reviewRequests":%s,"comments":%s,"author":{"login":"%s"},"reviews":%s}\n' \
      "${STUB_PR_STATE:-OPEN}" "${STUB_PR_DRAFT:-false}" "${STUB_REVIEW_DECISION:-}" "$reqs" "$comments" \
      "${STUB_AUTHOR:-author}" "${STUB_REVIEWS:-[]}"
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

repo_level='[{"repo":"o/a","pr_url":"","detail":"could not list o/a'"'"'s open pull requests — sweeping nothing","ts":"2026-08-08T01:00:00Z"}]'
request_level='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"could not request review from foo","ts":"2026-08-08T02:00:00Z"}]'
nudge_level='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"could not post the idle nudge comment","ts":"2026-08-08T02:00:00Z"}]'
unknown_level='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"could not read the pull request'"'"'s state — skipping the idle check","ts":"2026-08-08T02:00:00Z"}]'
no_candidate_level='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"no legal review-request candidate — known reviewers are empty or only the author; enabler_assignee=author","ts":"2026-08-08T02:00:00Z"}]'

# --- No input is [] ----------------------------------------------------------
out="$(STUB_LIST_RC=0 "$GATHER" "o/a")"
assert_eq "no violations-json argument is []" "[]" "$out"
out="$(STUB_LIST_RC=0 "$GATHER" "o/a" '[]')"
assert_eq "an empty array is []" "[]" "$out"

# --- Violations for a different repo are ignored ----------------------------
out="$(STUB_LIST_RC=0 "$GATHER" "o/other" "$request_level")"
assert_eq "violations naming a different repo are ignored" "[]" "$out"

# --- A repo-level violation whose listing still fails survives -------------
out="$(STUB_LIST_RC=1 "$GATHER" "o/a" "$repo_level")"
assert_eq "a still-failing listing survives" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... source is human-visibility" "human-visibility" "$(jq -r '.[0].source' <<<"$out")"
assert_eq "  ... ref is human-visibility-prefixed" \
  "human-visibility-" "$(jq -r '.[0].ref' <<<"$out" | grep -o '^human-visibility-')"
assert_eq "  ... names the repo in its problem line" \
  "1" "$(jq -r '.[0].problems | map(select(startswith("HUMAN VISIBILITY  o/a:"))) | length' <<<"$out")"

# --- A repo-level violation whose listing now succeeds is dropped ----------
out="$(STUB_LIST_RC=0 "$GATHER" "o/a" "$repo_level")"
assert_eq "a resolved listing is dropped" "[]" "$out"

# --- could_not_request: no live request and no review is still live --------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=0 \
        "$GATHER" "o/a" "$request_level")"
assert_eq "a request-class violation with no live request survives" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... source is human-visibility" "human-visibility" "$(jq -r '.[0].source' <<<"$out")"

# --- could_not_request: a pending review request clears it -----------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=1 \
        "$GATHER" "o/a" "$request_level")"
assert_eq "a request-class violation with a pending request is dropped" "[]" "$out"

# --- could_not_request: an approval clears it, even with no pending request
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=APPROVED STUB_REVIEW_REQUESTS=0 \
        "$GATHER" "o/a" "$request_level")"
assert_eq "a request-class violation on an approved pull request is dropped" "[]" "$out"

# --- could_not_request: changes-requested also proves the request worked ---
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=CHANGES_REQUESTED STUB_REVIEW_REQUESTS=0 \
        "$GATHER" "o/a" "$request_level")"
assert_eq "a request-class violation on a changes-requested pull request is dropped" "[]" "$out"

# --- no_candidate: still nobody to ask — survives ---------------------------
# The fixture's own detail names `enabler_assignee=author`, and the stub's
# default author is also `author` with no reviews at all: exactly the state
# `ensure_human_reviewer` read when it returned `skip\tno-candidate`.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author STUB_REVIEWS='[]' \
        "$GATHER" "o/a" "$no_candidate_level")"
assert_eq "a no-candidate violation with still nobody to ask survives" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... source is human-visibility" "human-visibility" "$(jq -r '.[0].source' <<<"$out")"

# --- no_candidate: a non-author, non-bot reviewer now exists — dropped -----
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author \
        STUB_REVIEWS='[{"author":{"login":"Warwick-Allen"},"state":"APPROVED"}]' \
        "$GATHER" "o/a" "$no_candidate_level")"
assert_eq "a no-candidate violation is dropped once a real reviewer appears" "[]" "$out"

# --- no_candidate: the author's own review is never a candidate ------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author \
        STUB_REVIEWS='[{"author":{"login":"author"},"state":"COMMENTED"}]' \
        "$GATHER" "o/a" "$no_candidate_level")"
assert_eq "the author's own review never counts as a candidate" "1" "$(jq 'length' <<<"$out")"

# --- no_candidate: a bot reviewer is never a candidate ---------------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author \
        STUB_REVIEWS='[{"author":{"login":"dependabot[bot]"},"state":"COMMENTED"}]' \
        "$GATHER" "o/a" "$no_candidate_level")"
assert_eq "a bot reviewer is never a candidate" "1" "$(jq 'length' <<<"$out")"

# --- no_candidate: a still-pending review is not yet a candidate -----------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author \
        STUB_REVIEWS='[{"author":{"login":"Warwick-Allen"},"state":"PENDING"}]' \
        "$GATHER" "o/a" "$no_candidate_level")"
assert_eq "an unsubmitted (pending) review is not yet a candidate" "1" "$(jq 'length' <<<"$out")"

# --- no_candidate: a pending review request now exists — dropped -----------
# agent-ops #350, #353, #355: CODEOWNERS already auto-requested a live
# reviewer the moment the pull request opened, before anyone had reviewed it
# — exactly `STUB_REVIEWS='[]'` with `STUB_REVIEW_REQUESTS=1` — which the
# `known`-reviewer check alone cannot see.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author STUB_REVIEWS='[]' \
        STUB_REVIEW_REQUESTS=1 "$GATHER" "o/a" "$no_candidate_level")"
assert_eq "a no-candidate violation is dropped once a review request is already pending" \
  "[]" "$out"

# --- no_candidate: enabler_assignee no longer names the author — dropped ---
no_candidate_reassigned='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"no legal review-request candidate — known reviewers are empty or only the author; enabler_assignee=someone-else","ts":"2026-08-08T02:00:00Z"}]'
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author STUB_REVIEWS='[]' \
        "$GATHER" "o/a" "$no_candidate_reassigned")"
assert_eq "a no-candidate violation is dropped once the assignee no longer names the author" \
  "[]" "$out"

# --- could_not_post_nudge: absent marker survives, even though APPROVED ----
# The pull request a nudge warning is logged against is always APPROVED (the
# nudge's own gate) — asserting this survives is what proves the request-class
# check is not being reused here; a shared check would drop it immediately.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=APPROVED STUB_REVIEW_REQUESTS=0 \
        STUB_NUDGE_MARKER=no "$GATHER" "o/a" "$nudge_level")"
assert_eq "a nudge-class violation with no marker comment survives despite APPROVED" \
  "1" "$(jq 'length' <<<"$out")"

# --- could_not_post_nudge: the marker comment appearing clears it ----------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=APPROVED STUB_REVIEW_REQUESTS=0 \
        STUB_NUDGE_MARKER=yes "$GATHER" "o/a" "$nudge_level")"
assert_eq "a nudge-class violation is dropped once the marker comment appears" "[]" "$out"

# --- An unrecognised warning shape survives while open and not draft -------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false "$GATHER" "o/a" "$unknown_level")"
assert_eq "an unrecognised warning shape survives while open and not draft" \
  "1" "$(jq 'length' <<<"$out")"

# --- A merged pull request is dropped regardless of class ------------------
out="$(STUB_PR_STATE=MERGED STUB_PR_DRAFT=false "$GATHER" "o/a" "$request_level")"
assert_eq "a merged pull request is dropped" "[]" "$out"
out="$(STUB_PR_STATE=MERGED STUB_PR_DRAFT=false "$GATHER" "o/a" "$nudge_level")"
assert_eq "a merged pull request is dropped (nudge class)" "[]" "$out"

# --- A closed pull request is dropped ---------------------------------------
out="$(STUB_PR_STATE=CLOSED STUB_PR_DRAFT=false "$GATHER" "o/a" "$request_level")"
assert_eq "a closed pull request is dropped" "[]" "$out"

# --- A pull request now back in draft is dropped ----------------------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=true "$GATHER" "o/a" "$request_level")"
assert_eq "a draft pull request is dropped" "[]" "$out"

# --- An unreadable re-check keeps the violation, fail-safe -----------------
out="$(STUB_VIEW_RC=1 "$GATHER" "o/a" "$request_level")"
assert_eq "an unreadable re-check keeps the violation" "1" "$(jq 'length' <<<"$out")"

# --- A repo-level and a pull-request violation for the same repo combine ---
both="$(jq -c -n --argjson a "$repo_level" --argjson b "$request_level" '$a + $b')"
out="$(STUB_LIST_RC=1 STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=0 \
        "$GATHER" "o/a" "$both")"
assert_eq "a repo-level and a pull-request violation combine into one candidate" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... with two problem lines" "2" "$(jq -r '.[0].problems | length' <<<"$out")"

echo
if (( failures == 0 )); then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
