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
#   - **The five warning classes are told apart (issue #284's decision 1).** A
#     `could not request review from …` violation clears only once a human
#     review is live or already given (`reviewRequests` non-empty, or a
#     non-bot review with state `APPROVED`/`CHANGES_REQUESTED` in the reviews
#     list — never `reviewDecision`, agent-ops#391, TD-PPagop-26081505); a
#     `could not read the pull request's reviews …` violation
#     (`_handoff_pr_approved`'s own read failing inside the idle-nudge check)
#     has no follow-up outcome of its own to check — reaching the live
#     re-check at all already proves the read works again, since the `gh pr
#     view` call it opens with requests `reviews` among its fields, so it
#     drops unconditionally while the pull request stays open and not a
#     draft; a
#     `could not post the idle nudge comment` violation — logged only against
#     an already-`APPROVED` pull request — clears only once a comment carrying
#     both the exact `<!-- agent-ops:human-nudge -->` HTML-comment form and
#     the pipeline-marker stamp appears on the same comment, never merely
#     because the pull request is approved, and never from a comment carrying
#     only one of the two (agent-ops#390, #428). Using the request-class check
#     for both would silently drop every nudge-class warning on sight; this
#     confirms it does not. A `no legal review-request candidate` violation
#     (tech-debt/TD-PPagop-26081001.md) clears only once a non-author,
#     non-bot, submitted review appears, a review request is already pending
#     (CODEOWNERS' own auto-request, before anyone has reviewed), or the
#     assignee named in its own detail text no longer names the pull
#     request's author. A `could not post the merge-queue-dequeued notice`
#     violation (TD-PPagop-26081504) clears only once the
#     `agent-ops:merge-queue-dequeued:` marker comment actually appears, the
#     same marker-read shape as the nudge class, never the request class's
#     "has this been reviewed" check.
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
# steer a named pull request's live open/draft state; `$STUB_REVIEW_REQUESTS`
# (nonzero means a pending request exists) and `$STUB_REVIEWS` (a JSON array
# of `{author:{login},state}`, default `[]`) together steer the
# request-class check — a non-bot `APPROVED`/`CHANGES_REQUESTED` entry in
# `$STUB_REVIEWS` clears it the same as a pending request does, read from the
# reviews list rather than `reviewDecision` (agent-ops#391,
# TD-PPagop-26081505); `$STUB_REVIEW_DECISION` is still emitted by the stub
# (mirroring `gh pr view`'s real payload) but the request-class check no
# longer reads it — tests below set it to confirm that. `$STUB_REVIEW_REQUESTS_JSON`,
# when set, overrides `$STUB_REVIEW_REQUESTS` with a literal `reviewRequests`
# array, for fixturing a Bot-typed/`[bot]`-suffixed or team-shaped entry
# (tech-debt/TD-PPagop-26081403.md); `$STUB_NUDGE_COMMENT` steers which
# nudge-related comment (if any) is present — `none` (default), `real` (the
# genuine shape, both the exact `<!-- agent-ops:human-nudge -->` form and the
# `PIPELINE_COMMENT_MARKER_PREFIX` stamp on the same comment), `prose` (the
# stamp, but only prose mentioning the marker, no exact HTML form —
# a Reviewer summarising a change to this check), `fenced` (the exact HTML
# form quoted in a fenced code block, with no stamp — a bystander write), or
# `prefixed-only` (the stamp on an ordinary pipeline comment carrying no
# nudge marker at all); `$STUB_DEQUEUE_MARKER` (`yes`/`no`) steers whether the
# merge-queue-dequeued marker comment is present instead; `$STUB_AUTHOR`
# (default `author`) and `$STUB_REVIEWS` also steer the no-candidate-class
# check; `$STUB_VIEW_RC` set nonzero makes the re-check itself unreadable,
# the fail-safe case.
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
    [[ -z "${STUB_REVIEW_REQUESTS_JSON:-}" ]] || reqs="$STUB_REVIEW_REQUESTS_JSON"
    comments="[]"
    case "${STUB_NUDGE_COMMENT:-none}" in
      real)
        comments='[{"body":"reminder\n\n<!-- agent-ops:pipeline-comment cycle=c1 actor=script -->\n<!-- agent-ops:human-nudge -->"}]'
        ;;
      prose)
        comments='[{"body":"Reviewed. This touches the agent-ops:human-nudge gate.\n\n<!-- agent-ops:pipeline-comment cycle=c1 actor=reviewer -->"}]'
        ;;
      fenced)
        comments='[{"body":"a bystander quoting the marker\n\n<!-- agent-ops:human-nudge -->"}]'
        ;;
      prefixed-only)
        comments='[{"body":"unrelated pipeline comment\n\n<!-- agent-ops:pipeline-comment cycle=c1 actor=reviewer -->"}]'
        ;;
    esac
    [[ "${STUB_DEQUEUE_MARKER:-no}" != "yes" ]] || comments='[{"body":"<!-- agent-ops:merge-queue-dequeued:2026-08-08T02:00:00Z -->"}]'
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
reviews_read_level='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"could not read the pull request'"'"'s reviews — skipping the idle-nudge check","ts":"2026-08-08T02:00:00Z"}]'
unknown_level='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"could not read the pull request'"'"'s state — skipping the idle check","ts":"2026-08-08T02:00:00Z"}]'
no_candidate_level='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"no legal review-request candidate — known reviewers are empty or only the author; enabler_assignee=author","ts":"2026-08-08T02:00:00Z"}]'
dequeue_level='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"could not post the merge-queue-dequeued notice","ts":"2026-08-08T02:00:00Z"}]'

# --- No input is [] ----------------------------------------------------------
out="$(STUB_LIST_RC=0 "$GATHER" "o/a" </dev/null)"
assert_eq "no stdin is []" "[]" "$out"
out="$(STUB_LIST_RC=0 "$GATHER" "o/a" <<<'[]')"
assert_eq "an empty array is []" "[]" "$out"

# --- Violations for a different repo are ignored ----------------------------
out="$(STUB_LIST_RC=0 "$GATHER" "o/other" <<<"$request_level")"
assert_eq "violations naming a different repo are ignored" "[]" "$out"

# --- A repo-level violation whose listing still fails survives -------------
out="$(STUB_LIST_RC=1 "$GATHER" "o/a" <<<"$repo_level")"
assert_eq "a still-failing listing survives" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... source is human-visibility" "human-visibility" "$(jq -r '.[0].source' <<<"$out")"
assert_eq "  ... ref is human-visibility-prefixed" \
  "human-visibility-" "$(jq -r '.[0].ref' <<<"$out" | grep -o '^human-visibility-')"
assert_eq "  ... names the repo in its problem line" \
  "1" "$(jq -r '.[0].problems | map(select(startswith("HUMAN VISIBILITY  o/a:"))) | length' <<<"$out")"

# --- A repo-level violation whose listing now succeeds is dropped ----------
out="$(STUB_LIST_RC=0 "$GATHER" "o/a" <<<"$repo_level")"
assert_eq "a resolved listing is dropped" "[]" "$out"

# --- could_not_request: no live request and no review is still live --------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=0 \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a request-class violation with no live request survives" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... source is human-visibility" "human-visibility" "$(jq -r '.[0].source' <<<"$out")"

# --- could_not_request: a pending review request clears it -----------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=1 \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a request-class violation with a pending request is dropped" "[]" "$out"

# --- could_not_request: an approval clears it, even with no pending request
# and an empty `reviewDecision` — this repository's own shape
# (`required_approving_review_count: 0`, agent-ops#391): `reviewDecision`
# can never read `APPROVED` here, so the drop must come from the reviews
# list alone, never that field (TD-PPagop-26081505).
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=0 \
        STUB_REVIEWS='[{"author":{"login":"reviewer"},"state":"APPROVED"}]' \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a request-class violation with an approving review is dropped despite empty reviewDecision" \
  "[]" "$out"

# --- could_not_request: changes-requested also proves the request worked ---
# Read the same way — from the reviews list, not `reviewDecision`.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=0 \
        STUB_REVIEWS='[{"author":{"login":"reviewer"},"state":"CHANGES_REQUESTED"}]' \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a request-class violation with a changes-requested review is dropped despite empty reviewDecision" \
  "[]" "$out"

# --- could_not_request: a non-empty reviewDecision changes nothing ---------
# Another repository's ruleset can compute `reviewDecision` fine, but this
# re-check no longer reads it either way — confirming the reviews-list path
# alone drives the verdict on both kinds of repository.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=CHANGES_REQUESTED STUB_REVIEW_REQUESTS=0 \
        STUB_REVIEWS='[]' \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a request-class violation survives a non-empty reviewDecision with no matching review" \
  "1" "$(jq 'length' <<<"$out")"

# --- could_not_request: a COMMENTED-only review does not clear it ----------
# Neither `APPROVED` nor `CHANGES_REQUESTED` — a comment-only review proves
# nobody has actually approved or requested changes yet.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=0 \
        STUB_REVIEWS='[{"author":{"login":"reviewer"},"state":"COMMENTED"}]' \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a request-class violation with only a commented review survives" \
  "1" "$(jq 'length' <<<"$out")"

# --- could_not_request: a bot's approval does not clear it -----------------
# The same bot filter the `reviewRequests` half already applies — a Copilot
# (or any `[bot]`-suffixed) review is never proof a human approved.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=0 \
        STUB_REVIEWS='[{"author":{"login":"copilot-pull-request-reviewer[bot]"},"state":"APPROVED"}]' \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a request-class violation with only a bot's approval survives" \
  "1" "$(jq 'length' <<<"$out")"

# --- could_not_request: a Bot-typed-only reviewRequests entry does not clear
# it (tech-debt/TD-PPagop-26081403.md). Defensive: today's `gh pr view` never
# delivers this shape — its exporter (cli/cli `api/export_pr.go`) drops Bot
# reviewers from `reviewRequests` entirely, so a Copilot-only request arrives
# as `[]` and is the "no live request survives" case above. This fixtures the
# `__typename`-keyed entry the exporter *would* emit if it ever stopped
# dropping them, so the filter keeps the two readers agreed even then.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" \
        STUB_REVIEW_REQUESTS_JSON='[{"__typename":"Bot","login":"copilot-pull-request-reviewer"}]' \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a Bot-typed-only pending request does not clear a request-class violation" \
  "1" "$(jq 'length' <<<"$out")"

# --- could_not_request: a [bot]-suffixed-only reviewRequests entry survives -
# Defensive for the same reason: a `[bot]`-suffixed login is REST's rendering
# of a Bot account, which this reader's GraphQL-backed exporter types as
# `Bot` and drops — a `User`-typed `[bot]` login cannot occur today. The
# `type` fallback retained in the filter covers a REST-shaped payload too.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" \
        STUB_REVIEW_REQUESTS_JSON='[{"__typename":"User","login":"some-app[bot]"}]' \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a [bot]-suffixed-only pending request does not clear a request-class violation" \
  "1" "$(jq 'length' <<<"$out")"

# --- could_not_request: a requested-team-only reviewRequests entry clears it,
# the same as a pending user request — a team can never itself be a bot, and
# it is extended the same review-request mechanism CODEOWNERS gives a named
# human (agreeing with `ensure_human_reviewer`'s own pending read,
# requirement 38a).
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" \
        STUB_REVIEW_REQUESTS_JSON='[{"__typename":"Team","name":"Reviewers","slug":"reviewers-team"}]' \
        "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a requested-team-only pending request clears a request-class violation" "[]" "$out"

# --- no_candidate: still nobody to ask — survives ---------------------------
# The fixture's own detail names `enabler_assignee=author`, and the stub's
# default author is also `author` with no reviews at all: exactly the state
# `ensure_human_reviewer` read when it returned `skip\tno-candidate`.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author STUB_REVIEWS='[]' \
        "$GATHER" "o/a" <<<"$no_candidate_level")"
assert_eq "a no-candidate violation with still nobody to ask survives" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... source is human-visibility" "human-visibility" "$(jq -r '.[0].source' <<<"$out")"

# --- no_candidate: a non-author, non-bot reviewer now exists — dropped -----
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author \
        STUB_REVIEWS='[{"author":{"login":"Warwick-Allen"},"state":"APPROVED"}]' \
        "$GATHER" "o/a" <<<"$no_candidate_level")"
assert_eq "a no-candidate violation is dropped once a real reviewer appears" "[]" "$out"

# --- no_candidate: the author's own review is never a candidate ------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author \
        STUB_REVIEWS='[{"author":{"login":"author"},"state":"COMMENTED"}]' \
        "$GATHER" "o/a" <<<"$no_candidate_level")"
assert_eq "the author's own review never counts as a candidate" "1" "$(jq 'length' <<<"$out")"

# --- no_candidate: a bot reviewer is never a candidate ---------------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author \
        STUB_REVIEWS='[{"author":{"login":"dependabot[bot]"},"state":"COMMENTED"}]' \
        "$GATHER" "o/a" <<<"$no_candidate_level")"
assert_eq "a bot reviewer is never a candidate" "1" "$(jq 'length' <<<"$out")"

# --- no_candidate: a still-pending review is not yet a candidate -----------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author \
        STUB_REVIEWS='[{"author":{"login":"Warwick-Allen"},"state":"PENDING"}]' \
        "$GATHER" "o/a" <<<"$no_candidate_level")"
assert_eq "an unsubmitted (pending) review is not yet a candidate" "1" "$(jq 'length' <<<"$out")"

# --- no_candidate: a pending review request now exists — dropped -----------
# agent-ops #350, #353, #355: CODEOWNERS already auto-requested a live
# reviewer the moment the pull request opened, before anyone had reviewed it
# — exactly `STUB_REVIEWS='[]'` with `STUB_REVIEW_REQUESTS=1` — which the
# `known`-reviewer check alone cannot see.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author STUB_REVIEWS='[]' \
        STUB_REVIEW_REQUESTS=1 "$GATHER" "o/a" <<<"$no_candidate_level")"
assert_eq "a no-candidate violation is dropped once a review request is already pending" \
  "[]" "$out"

# --- no_candidate: a Bot-typed-only pending request does not clear it ------
# (tech-debt/TD-PPagop-26081403.md), the same filter `ensure_human_reviewer`'s
# own pending read applies. Defensive, `__typename`-keyed, for the same
# reason as the request-class twin above: today's `gh` drops this entry
# before it ever reaches the filter.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author STUB_REVIEWS='[]' \
        STUB_REVIEW_REQUESTS_JSON='[{"__typename":"Bot","login":"copilot-pull-request-reviewer"}]' \
        "$GATHER" "o/a" <<<"$no_candidate_level")"
assert_eq "a Bot-typed-only pending request does not clear a no-candidate violation" \
  "1" "$(jq 'length' <<<"$out")"

# --- no_candidate: a requested-team-only pending request clears it ---------
# — a team can never itself be a bot, and it is extended the same
# review-request mechanism CODEOWNERS gives a named human, agreeing with
# `ensure_human_reviewer`'s own pending read (requirement 38a).
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author STUB_REVIEWS='[]' \
        STUB_REVIEW_REQUESTS_JSON='[{"__typename":"Team","name":"Reviewers","slug":"reviewers-team"}]' \
        "$GATHER" "o/a" <<<"$no_candidate_level")"
assert_eq "a requested-team-only pending request clears a no-candidate violation" "[]" "$out"

# --- no_candidate: enabler_assignee no longer names the author — dropped ---
no_candidate_reassigned='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"no legal review-request candidate — known reviewers are empty or only the author; enabler_assignee=someone-else","ts":"2026-08-08T02:00:00Z"}]'
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_AUTHOR=author STUB_REVIEWS='[]' \
        "$GATHER" "o/a" <<<"$no_candidate_reassigned")"
assert_eq "a no-candidate violation is dropped once the assignee no longer names the author" \
  "[]" "$out"

# --- could_not_post_nudge: absent marker survives, even though APPROVED ----
# The pull request a nudge warning is logged against is always APPROVED (the
# nudge's own gate) — asserting this survives is what proves the request-class
# check is not being reused here; a shared check would drop it immediately.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=APPROVED STUB_REVIEW_REQUESTS=0 \
        STUB_NUDGE_COMMENT=none "$GATHER" "o/a" <<<"$nudge_level")"
assert_eq "a nudge-class violation with no marker comment survives despite APPROVED" \
  "1" "$(jq 'length' <<<"$out")"

# --- could_not_post_nudge: an unanchored substring test would wrongly clear ---
# --- this — the discriminating cases from agent-ops#390/#428, applied here ----
# --- the same way sweep-human-visibility.sh's own re-check is tested ----------
#
# A pipeline comment merely discussing the marker in prose (no exact HTML
# form) never clears the violation.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=APPROVED STUB_REVIEW_REQUESTS=0 \
        STUB_NUDGE_COMMENT=prose "$GATHER" "o/a" <<<"$nudge_level")"
assert_eq "a comment merely mentioning the marker in prose survives" \
  "1" "$(jq 'length' <<<"$out")"

# A bystander (non-pipeline) comment quoting the exact HTML form, with no
# pipeline-marker stamp, never clears the violation.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=APPROVED STUB_REVIEW_REQUESTS=0 \
        STUB_NUDGE_COMMENT=fenced "$GATHER" "o/a" <<<"$nudge_level")"
assert_eq "a bystander comment quoting the exact marker with no stamp survives" \
  "1" "$(jq 'length' <<<"$out")"

# An ordinary pipeline comment carrying the marker prefix but no nudge
# marker at all never clears the violation.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=APPROVED STUB_REVIEW_REQUESTS=0 \
        STUB_NUDGE_COMMENT=prefixed-only "$GATHER" "o/a" <<<"$nudge_level")"
assert_eq "an ordinary pipeline comment with no nudge marker survives" \
  "1" "$(jq 'length' <<<"$out")"

# --- could_not_post_nudge: the real nudge comment appearing clears it ------
# Both the exact HTML form and the pipeline-marker stamp on the same comment
# — the genuine shape sweep-human-visibility.sh itself posts.
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION=APPROVED STUB_REVIEW_REQUESTS=0 \
        STUB_NUDGE_COMMENT=real "$GATHER" "o/a" <<<"$nudge_level")"
assert_eq "a nudge-class violation is dropped once the real marker comment appears" "[]" "$out"

# --- could_not_read_reviews: reaching the live re-check at all already
# --- proves the read works again — dropped unconditionally while open and
# --- not a draft, with no further signal to check (unlike every other class)
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false "$GATHER" "o/a" <<<"$reviews_read_level")"
assert_eq "a reviews-read violation is dropped once the pull request is readable again" \
  "[]" "$out"

# --- could_not_read_reviews: a merged/closed/draft pull request still drops
# --- it too, the same as every other class -----------------------------------
out="$(STUB_PR_STATE=MERGED STUB_PR_DRAFT=false "$GATHER" "o/a" <<<"$reviews_read_level")"
assert_eq "a reviews-read violation is dropped on a merged pull request" "[]" "$out"

# --- could_not_read_reviews: an unreadable re-check keeps it, fail-safe ----
out="$(STUB_VIEW_RC=1 "$GATHER" "o/a" <<<"$reviews_read_level")"
assert_eq "a reviews-read violation survives an unreadable re-check" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... source is human-visibility" "human-visibility" "$(jq -r '.[0].source' <<<"$out")"

# --- dequeue_notice: absent marker survives, even while open ---------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_DEQUEUE_MARKER=no \
        "$GATHER" "o/a" <<<"$dequeue_level")"
assert_eq "a dequeue-notice violation with no marker comment survives" \
  "1" "$(jq 'length' <<<"$out")"

# --- dequeue_notice: the marker comment appearing clears it ----------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_DEQUEUE_MARKER=yes \
        "$GATHER" "o/a" <<<"$dequeue_level")"
assert_eq "a dequeue-notice violation is dropped once the marker comment appears" "[]" "$out"

# --- An unrecognised warning shape survives while open and not draft -------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false "$GATHER" "o/a" <<<"$unknown_level")"
assert_eq "an unrecognised warning shape survives while open and not draft" \
  "1" "$(jq 'length' <<<"$out")"

# --- A merged pull request is dropped regardless of class ------------------
out="$(STUB_PR_STATE=MERGED STUB_PR_DRAFT=false "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a merged pull request is dropped" "[]" "$out"
out="$(STUB_PR_STATE=MERGED STUB_PR_DRAFT=false "$GATHER" "o/a" <<<"$nudge_level")"
assert_eq "a merged pull request is dropped (nudge class)" "[]" "$out"

# --- A closed pull request is dropped ---------------------------------------
out="$(STUB_PR_STATE=CLOSED STUB_PR_DRAFT=false "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a closed pull request is dropped" "[]" "$out"

# --- A pull request now back in draft is dropped ----------------------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=true "$GATHER" "o/a" <<<"$request_level")"
assert_eq "a draft pull request is dropped" "[]" "$out"

# --- An unreadable re-check keeps the violation, fail-safe -----------------
out="$(STUB_VIEW_RC=1 "$GATHER" "o/a" <<<"$request_level")"
assert_eq "an unreadable re-check keeps the violation" "1" "$(jq 'length' <<<"$out")"

# --- A repo-level and a pull-request violation for the same repo combine ---
both="$(jq -c -n --argjson a "$repo_level" --argjson b "$request_level" '$a + $b')"
out="$(STUB_LIST_RC=1 STUB_PR_STATE=OPEN STUB_PR_DRAFT=false STUB_REVIEW_DECISION="" STUB_REVIEW_REQUESTS=0 \
        "$GATHER" "o/a" <<<"$both")"
assert_eq "a repo-level and a pull-request violation combine into one candidate" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... with two problem lines" "2" "$(jq -r '.[0].problems | length' <<<"$out")"

# --- The CLI's own argv cap (requirement 4g, TD-PPagop-26081502) -----------
#
# `agent-cycle.sh` used to hand this script the whole fleet-wide violations
# log as the script's own second positional argument — a single argv element
# subject to the identical MAX_ARG_STRLEN cap the internal jq calls below
# were hitting, and nothing inside the script could work around it: the
# process never started. TD-PPagop-26081502 moves the violations array onto
# stdin instead, mirroring test/nudge-dependabot-rebase.test.sh's own
# stdin-fed candidates array. This drives the real script directly (no
# extraction) over a violations log genuinely past MAX_ARG_STRLEN, proving
# the CLI invocation itself no longer dies at execve.
big_violations="$(jq -nc \
  '[range(150) | {repo: "o/a", pr_url: "", detail: ("pad " + ("x" * 900)), ts: "2026-08-15T00:00:00Z"}]')"
assert_eq "the oversized violations-log fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_violations" | wc -c) > 131072 ))"
out="$(STUB_LIST_RC=1 "$GATHER" "o/a" <<<"$big_violations" 2>"$tmp_dir/cli-cap.err")"
rc=$?
assert_eq "the real script over an oversized violations log on stdin exits 0" "0" "$rc"
assert_eq "  ... without an Argument list too long error" "" \
  "$(grep -o 'Argument list too long' "$tmp_dir/cli-cap.err" || true)"
assert_eq "  ... and still produces one candidate" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... carrying every one of the 150 problem lines" \
  "150" "$(jq '.[0].problems | length' <<<"$out")"

# --- The internal jq argv cap (requirement 4g, TD-PPagop-26081406) ---
#
# The two survivor-accumulator appends and the final `problems` build all
# used to ride into jq as --argjson: $problems alone grows with the survivor
# set, unbounded past this call. Past MAX_ARG_STRLEN (131072 bytes) the build
# died at execve and this repo's whole human-visibility candidate was lost.
# Requirement 4g moves all three onto stdin. The append and the `problems`
# build are each lifted by their own literal lines and driven directly with
# an oversized accumulator, the same technique
# test/pr-claim-exclusion.test.sh's `extract_claims_fold` uses — the CLI-argv
# case above already proves the real script end-to-end; this isolates the
# internal accumulation logic itself.
extract_block() {  # extract_block <start-literal> <end-literal>
  awk -v s="$1" -v e="$2" \
    'index($0, s) == 1 { on = 1 } on { print } on && index($0, e) > 0 { exit }' \
    "$SCRIPT_DIR/scripts/gather-human-visibility-hygiene.sh"
}

# shellcheck disable=SC2016  # both single-quoted args are literal source text to match, not meant to expand
append_line="$(extract_block '    survivors="$(jq -nc '"'"'input as $arr | input as $v' '    continue')"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$append_line" != *'$arr + [$v]'* ]]; then
  printf 'FAIL - could not extract the survivors-append from scripts/gather-human-visibility-hygiene.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
append_stmt="$(head -n1 <<<"$append_line")"
run_append() {  # run_append <survivors-json> <v-json>
  # v is consumed only by the eval'd append_stmt, invisible to shellcheck.
  # shellcheck disable=SC2034
  ( survivors="$1" v="$2"; eval "$append_stmt"; printf '%s' "$survivors" )
}
big_survivors="$(jq -nc '[range(1300) | {repo: "o/a", pr_url: "", detail: ("pad " + ("x" * 100))}]')"
assert_eq "the oversized survivors-accumulator fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_survivors" | wc -c) > 131072 ))"
new_v='{"repo":"o/a","pr_url":"","detail":"the newest one"}'
appended="$(run_append "$big_survivors" "$new_v")"
assert_eq "an append onto an oversized survivors accumulator keeps every prior entry" \
  "1301" "$(jq 'length' <<<"$appended")"
assert_eq "  ... plus the new one just appended" "1" \
  "$(jq '[.[] | select(.detail == "the newest one")] | length' <<<"$appended")"

# shellcheck disable=SC2016  # both single-quoted args are literal source text to match, not meant to expand
problems_block="$(extract_block 'jq -nc' '"$problems"')"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$problems_block" != *'source: "human-visibility"'* ]]; then
  printf 'FAIL - could not extract the final problems build from scripts/gather-human-visibility-hygiene.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
run_problems_block() {  # run_problems_block <problems-json> [body-json]
  # ref/url/body_json are consumed only by the eval'd problems_block, unseen
  # by static analysis.
  # shellcheck disable=SC2034
  ( problems="$1" ref="human-visibility-abc123" url="https://github.com/o/a/pulls"
    body_json="${2-\"the digest\"}"
    eval "$problems_block" )
}
big_problems="$(jq -nc '[range(1300) | ("HUMAN VISIBILITY  o/a: pad " + ("x" * 100))]')"
assert_eq "the oversized problems fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_problems" | wc -c) > 131072 ))"
built_candidate="$(run_problems_block "$big_problems")"
assert_eq "a problems array past the argv cap still produces the candidate" "1" \
  "$(jq 'length' <<<"$built_candidate")"
assert_eq "  ... carrying every one of the 1300 problem lines" \
  "1300" "$(jq '.[0].problems | length' <<<"$built_candidate")"
assert_eq "  ... with the source and ref intact" "human-visibility human-visibility-abc123" \
  "$(jq -r '.[0] | "\(.source) \(.ref)"' <<<"$built_candidate")"

# $body is rendered from the same $survivors set as $problems and is the
# larger of the two, so it has to travel on stdin as well: an `--arg body`
# here would have left the cap exactly where it was, one flag over.
oversized_hv_body="$(head -c 140000 < /dev/zero | tr '\0' 'x')"
assert_eq "the oversized hygiene-body fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( ${#oversized_hv_body} > 131072 ))"
built_candidate="$(run_problems_block '[]' "$(printf '"%s"' "$oversized_hv_body")")"
assert_eq "a rendered body past the argv cap still produces the candidate" "1" \
  "$(jq 'length' <<<"$built_candidate")"
# Compared in bash, not with `jq --arg`: an --arg carrying the oversized
# string would hit the very cap this section exists to prove is gone.
assert_eq "  ... carrying the whole oversized body, not a truncation" "1" \
  "$([[ "$(jq -r '.[0].body' <<<"$built_candidate")" == "$oversized_hv_body" ]] && echo 1 || echo 0)"

echo
if (( failures == 0 )); then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
