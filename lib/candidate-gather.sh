#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/candidate-gather.sh — the repo-ordering/candidate-gathering loop and
# the skip-list (blocked/void) extracts built on top of it, moved out of
# agent-cycle.sh (#771) as the seam directly ahead of the requirement-4i
# fit machinery: `gather_ordered_repos` orders every configured repo by
# effective staleness (lib/repo-order.sh) and, for each, runs every
# pre-fetched source's gather script, folding claims, first-seen state and
# per-repo entries into `ordered_repos_json`/`source_states_json`/
# `claimed_json`/`unvoid_requests_json`/`hand_flagged_refinements_json`.
# `compute_skip_lists` reconciles the two label-driven human overrides
# (`unvoid` and hand-flagged `needs_refinement`) against that cycle's own
# claim, then derives `blocked_json`/`void_json`, the skip-lists everything
# downstream (eligibility, the Enabler's threshold, the Co-Ordinator's
# input) reads.
#
# Both are pure moves out of agent-cycle.sh's own top-level script body —
# never before functions, so their bodies keep the exact original
# indentation (including column-0 `if`/`while` blocks) rather than being
# reformatted as a function's own — reading and writing the cycle's own
# globals (`cycle_dir`, `union_log`, `repos_json`, …) exactly as they did
# inline. Several test/*.test.sh files lift specific lines out of this file
# by literal pattern, the same way they did out of agent-cycle.sh before
# the move; only the file path changed for them.

gather_ordered_repos() {
if [[ -n "$REPO_FILTER" ]]; then
  repos_json="$(jq -c --arg f "$REPO_FILTER" '[.[] | select(.slug == $f or (.slug | endswith("/" + $f)))]' <<<"$all_repos_json")"
  if [[ "$(jq 'length' <<<"$repos_json")" == "0" ]]; then
    echo "agent-cycle: --repo '$REPO_FILTER' matches no configured repo" >&2
    exit 64
  fi
else
  repos_json="$all_repos_json"
fi

ordered_repos_json="[]"
source_states_json="[]"
unvoid_requests_json="[]"
hand_flagged_refinements_json="[]"
claimed_json="[]"
# Requirement 48 (agent-ops#1086): of every repo `repos_json` names, the one
# whose expensive per-repository sources (findings, review-feedback,
# abandoned-drafts, merge-conflicts, dequeued, register-hygiene, issues,
# tech-debt) this cycle actually reads fresh from GitHub — every other one
# reuses the snapshot this same node captured the last time its own turn came
# around (lib/expensive-gather-cache.sh). Picked once, ahead of the per-repo
# loop below, from `repos_json` rather than `all_repos_json`: a `--repo`
# filter narrows this cycle to one repository, and that one repository must
# always be the one read fresh, exactly as before this feature existed.
expensive_gather_slug="$(expensive_gather_pick_repo "$state_dir" "$repos_json")"
# Issue #248 acceptance 4 (TD-PPagop-26081405): the fleet's already-logged
# `first-seen` set, read once off the union log snapshotted at 1a1 above —
# every emit_first_seen call below both consults and grows this — and
# whether THIS node's own log had no `first-seen` in it at all when the
# cycle began. Decided once, here, before this cycle writes its own first
# one: an event written mid-cycle must not flip a later call in the same
# cycle from bootstrap to not, which is what checking $log_file fresh at
# each call site would do.
first_seen_known_json="$(first_seen_known_items "$union_log")"
first_seen_bootstrap="$(jq -c '(length == 0)' <<<"$(first_seen_known_items "$log_file")")"
# Review decision on agent-ops#452 concern 1: the `issues-excluded` event
# below logs only on change, and this is the "previous state" each repo's
# freshly gathered set is compared against — read once, here, off the same
# union log snapshot first_seen_known_json above reads, for the same reason:
# an event this cycle logs must not make its own repo's later comparison (if
# the repo were ever visited twice in one cycle) see itself as unchanged.
# Requirement 38b's live blocked-label reconciliation (below, in the
# issues-source block) is the one reader in this cycle that draws a
# *negative* conclusion from the union — "no open block exists" — rather than
# only ever acting on positive evidence in it, so it is the one reader an
# empty or unreliable union actively misleads rather than merely leaves
# uninformed (agent-ops#816 review). Decided once, here, rather than inside
# the per-repo loop below: every repo shares this cycle's one union log and
# one peers directory, so a degraded read is degraded for all of them
# together, and a once-per-cycle warning says so once rather than once per
# repo.
union_log_healthy=1
if ! fleet_logs_healthy "$state_dir" "$peers_dir" "$union_log"; then
  union_log_healthy=0
  log_event "warning" "$(jq -nc \
    --arg d "this cycle's fleet-wide log looks degraded (an empty union, or the peers directory's own fetch marker reporting failure) — requirement 38b's live blocked-label reconciliation is skipped this cycle rather than risk reading a block's absence off an incomplete view of it" \
    '{detail: $d}')"
fi
latest_issues_excluded_json="$(latest_issues_excluded "$union_log")"
repo_order_now="$(date +%s)"
while IFS= read -r slug; do
  # TD-PPagop-26081407: gh api can fail (rate limit, auth, network -- test 1);
  # "main" is a plausible real default branch and 1970-01-01 sorts this repo
  # oldest without saying why (test 2 for both).
  #
  # The shape check after each capture is the sibling of the `claim.sh count`
  # site's `=~ ^[0-9]+$` above, and it closes what `2>&1` opens: swapping
  # `2>/dev/null` for `2>&1` is what makes `detail` useful on failure, but it
  # also merges a *successful* command's stderr into the value. These two are
  # the only converted sites where that matters — every other one feeds jq,
  # date or wc, while `$default_branch` is interpolated straight into the next
  # API path and `$commit_ts` into `.repo_ts`'s ordering sort, both
  # unvalidated. gh 2.97.0 writes nothing to stderr on a successful `api
  # --jq`, so this is a future-proofing check, not a live defect; it reports
  # like any other guard rather than silently substituting, which is the whole
  # point of this item.
  default_branch="$(gh api "repos/$slug" --jq '.default_branch' 2>&1)" \
    || { guard_warn "repo-order:default_branch:$slug" "$default_branch"; default_branch="main"; }
  [[ "$default_branch" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || { guard_warn "repo-order:default_branch-malformed:$slug" "$default_branch"; default_branch="main"; }
  commit_ts="$(gh api "repos/$slug/commits/$default_branch" --jq '.commit.committer.date' 2>&1)" \
    || { guard_warn "repo-order:commit_ts:$slug" "$commit_ts"; commit_ts="1970-01-01T00:00:00Z"; }
  [[ "$commit_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || { guard_warn "repo-order:commit_ts-malformed:$slug" "$commit_ts"; commit_ts="1970-01-01T00:00:00Z"; }
  printf '%s\t%s\t%s\n' "$commit_ts" "$slug" "$default_branch" >> "$cycle_dir/.repo_ts"
done < <(jq -r '.[].slug' <<<"$repos_json")

while IFS=$'\t' read -r _ slug default_branch; do
  sources="$(jq -c --arg s "$slug" '.[] | select(.slug == $s) | .sources' <<<"$repos_json")"
  # Requirement 3o, gathered here — ahead of the four finishing sources below,
  # not after them as before — so their own candidate arrays can be filtered by
  # it: unconditional, regardless of `sources`, because any starting source's
  # item can be claimed.
  repo_claimed_json="$(gather_claimed "$slug")"
  # requirement 4g (TD-PPagop-26081401): $claimed_json is one of the five
  # aggregates requirement 4g names as growing with the fleet's own history —
  # already delivered on stdin — but this repo's own increment,
  # $repo_claimed_json, used to ride in as a second --argjson, past
  # MAX_ARG_STRLEN once enough repos' claims had accumulated into it. Both now
  # arrive as one stdin document. Unguarded — same as before the conversion —
  # because a claims-fold failure here must not be silently swallowed.
  claimed_fold_docs="$(printf '%s\n' "$claimed_json" "$repo_claimed_json")"
  claimed_json="$(jq -nc --arg r "$slug" '
    input as $claimed | input as $items
    | $claimed + ($items | map({repo: $r} + .))
  ' <<<"$claimed_fold_docs")"
  # Requirement 3p/issue #238: the PR numbers a peer already holds a claim on,
  # for this repo. Filtered into the four finishing sources' own arrays below —
  # deterministic code, not something the Co-Ordinator is asked to notice and
  # apply itself, which is exactly the step a Co-Ordinator run "saw" a peer's
  # claim on PR #205 and reasoned past because the item ref didn't match.
  claimed_pr_numbers_json="$(jq -c '[.[] | select(has("pr_number")) | .pr_number]' <<<"$repo_claimed_json")"
  # The claimed item refs themselves, applied below to every pre-fetched
  # source's array through exclude_claimed_items: the same
  # deterministic-code-not-model-judgement decision as the pr_number filter
  # above, extended from the four finishing sources to everything the
  # Script pre-fetches. Every gather script mints a `ref` field that is the
  # exact string a claim on that item is keyed on, so the match needs no
  # re-derivation.
  claimed_item_refs_json="$(jq -c '[.[].item]' <<<"$repo_claimed_json")"
  # Claim exclusion only, in this pass: blocked/void exclusion needs
  # `blocked_json`/`void_json`, which do not exist yet this early in the cycle
  # (they depend on this same loop's `ordered_repos_json` for the work-gone
  # reconciliation passes below) — see "3c/3u. Pre-fetched-band eligibility"
  # further down, which filters every one of these arrays in place, a second
  # time, once they do.
  #
  # Requirement 48 (agent-ops#1086): the eight expensive bands below —
  # findings, review-feedback, abandoned-drafts, merge-conflicts, dequeued,
  # register-hygiene, issues (+ issues_excluded) and tech-debt — are read
  # fresh from GitHub only for `expensive_gather_slug`, the one repository
  # this cycle picked for this node's turn (lib/expensive-gather-cache.sh).
  # Every other configured repository reuses the raw gather this same node
  # captured the last time its own turn came around, with this cycle's own
  # `sources` gating and claim exclusion re-applied to it exactly as they
  # would be to a fresh read — only the GitHub call itself is skipped. A
  # repository never yet read on this node (no cache file) yields empty
  # bands, the same shape a repository whose sources are all disabled
  # already produces, until its own first turn arrives — which
  # `expensive_gather_pick_repo`'s epoch-0 default guarantees happens before
  # any repository already cached once does.
  if [[ "$slug" == "$expensive_gather_slug" ]]; then
  # Pre-fetch security/code-quality findings only when this repo lists either
  # source, so a repo that opts out of them costs no gh calls. first-seen is
  # emitted on the raw array, split by each finding's own `.source`, before
  # exclusion — findings is the one pre-fetch that mixes two first-seen
  # sources in one gather call.
  findings="[]"; findings_raw="[]"
  if jq -e 'any(.[]; . == "security" or . == "code-quality")' <<<"$sources" >/dev/null 2>&1; then
    findings_raw="$(gather_findings "$slug")"
    emit_first_seen "$slug" security "$(jq -c '[.[] | select(.source == "security")]' <<<"$findings_raw")"
    emit_first_seen "$slug" code-quality "$(jq -c '[.[] | select(.source == "code-quality")]' <<<"$findings_raw")"
    findings="$(exclude_claimed_items "$findings_raw" "$claimed_item_refs_json")"
  fi
  review_feedback="[]"; review_feedback_raw="[]"
  if jq -e 'any(.[]; . == "review-feedback")' <<<"$sources" >/dev/null 2>&1; then
    review_feedback_raw="$(gather_review_feedback "$slug")"
    emit_first_seen "$slug" review-feedback "$review_feedback_raw"
    review_feedback="$(exclude_claimed_items "$(exclude_claimed_prs "$review_feedback_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
  # Unconditional, unlike its neighbours: `abandoned-drafts` is a required
  # member of every repository's `sources` (the schema's `contains` rule;
  # requirement 3e, agent-ops#472) — the only route back to a draft this
  # system raised and then abandoned.
  abandoned_drafts_raw="$(gather_abandoned_drafts "$slug")"
  emit_first_seen "$slug" abandoned-drafts "$abandoned_drafts_raw"
  abandoned_drafts="$(exclude_claimed_items "$(exclude_claimed_prs "$abandoned_drafts_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  merge_conflicts="[]"; merge_conflicts_raw="[]"
  if jq -e 'any(.[]; . == "merge-conflicts")' <<<"$sources" >/dev/null 2>&1; then
    merge_conflicts_raw="$(gather_merge_conflicts "$slug")"
    emit_first_seen "$slug" merge-conflicts "$merge_conflicts_raw"
    merge_conflicts="$(exclude_claimed_items "$(exclude_claimed_prs "$merge_conflicts_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
  dequeued="[]"; dequeued_raw="[]"
  if jq -e 'any(.[]; . == "dequeued")' <<<"$sources" >/dev/null 2>&1; then
    dequeued_raw="$(gather_dequeued "$slug")"
    emit_first_seen "$slug" dequeued "$dequeued_raw"
    dequeued="$(exclude_claimed_items "$(exclude_claimed_prs "$dequeued_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
  register_hygiene="[]"; register_hygiene_raw="[]"
  if jq -e 'any(.[]; . == "register-hygiene")' <<<"$sources" >/dev/null 2>&1; then
    register_hygiene_raw="$(gather_register_hygiene "$slug" "$default_branch" prefetch)"
    emit_first_seen "$slug" register-hygiene "$register_hygiene_raw"
    register_hygiene="$(exclude_claimed_items "$register_hygiene_raw" "$claimed_item_refs_json")"
  fi
  # The issues source is one source at four ranks (`issues:urgent` …
  # `issues:low`, requirement 15e), so any band in `sources` warrants the one
  # fetch — the band is per issue, not per fetch.
  issues="[]"; issues_raw="[]"
  issues_excluded="[]"; issues_excluded_raw="null"
  if jq -e 'any(.[]; startswith("issues"))' <<<"$sources" >/dev/null 2>&1; then
    # Requirement 38b's *live* reconciliation (agent-ops#816,
    # TD-PPagop-26082602), run ahead of the gather below so an issue this
    # frees becomes a candidate in the same cycle rather than the next one
    # (acceptance 3): `refinement_blocked_label_stale` above can only retry a
    # removal its own history already proves is ours, which is exactly what a
    # label `scripts/sweep-legacy-refinement-assignees.sh` applied (it logs no
    # `own-label-action` of its own) or one whose block cleared before that
    # event existed to log never has. One `gh` call per repo per cycle —
    # `refinement_blocked_reason_label` is empty for no configured kind today,
    # so this never runs for nothing. Gated on `union_log_healthy` (computed
    # once, above the per-repo loop): a degraded union cannot prove a block is
    # gone, only that this node cannot see one, so nothing below runs against
    # it (agent-ops#816 review concern 1).
    if ! (( DRY_RUN )) && (( union_log_healthy )) \
        && refinement_reason_label="$(refinement_blocked_reason_label "$REFINEMENT_BLOCK_KIND")" \
        && [[ -n "$refinement_reason_label" ]]; then
      # The page cap is stated rather than inherited, and checked, per
      # lib/github-limit.sh's own header: `gh`'s undeclared default of 30
      # would truncate this listing silently, and a truncated one is
      # indistinguishable from a complete one. The direction of harm here is
      # the mild one — a stuck pair this page misses is simply not released
      # this cycle — but it does not self-heal on its own, because the
      # listing is newest-first and a stuck label is by nature an old one:
      # past the cap it can sit behind newer, legitimately-blocked issues
      # indefinitely. So it warns rather than degrading silently.
      live_reason_issues_json="$(gh issue list -R "$slug" --label "$refinement_reason_label" \
          --state open --limit "$GITHUB_PR_LIST_LIMIT" --json number,labels 2>/dev/null \
        | jq -c '[.[] | {number: .number, labels: [.labels[].name]}]' 2>/dev/null)" || true
      jq -e 'type == "array"' <<<"$live_reason_issues_json" >/dev/null 2>&1 \
        || live_reason_issues_json='[]'
      live_reason_issues_n="$(jq 'length' <<<"$live_reason_issues_json" 2>/dev/null)" \
        || live_reason_issues_n=0
      if github_pr_list_truncated "$live_reason_issues_n"; then
        log_event "warning" "$(jq -nc \
          --arg d "the $refinement_reason_label listing for $slug came back at the $GITHUB_PR_LIST_LIMIT cap — an orphaned label past it is not reconciled this cycle" \
          '{detail: $d}')"
      fi
      # _REFINEMENT_ORPHAN_RECENT memoises, per (repo, item) — never bare item
      # number, which collides across repos — whether that issue's own
      # reason-label application is too recent to trust an absent block for
      # (agent-ops#816 review concern 2): a peer node can apply this exact
      # pair within seconds of logging the block that justifies it, while
      # that log line reaches this node only through the fleet's periodic
      # state-sync — up to a full fetch interval behind. `LABEL_OWN_GRACE_SECONDS`
      # (lib/label-marker.sh) is the same tolerance requirement 39f already
      # measures a peer's label writes against `union_log_horizon` with,
      # reused rather than duplicated. Declared once for the whole process
      # (the same `declare -p ... || declare -gA` guard
      # `_REFINEMENT_LABEL_ENSURE_ATTEMPTED` below uses), not reset per repo:
      # an issue this cycle's own gather loop somehow revisits costs one
      # timeline call, not two.
      declare -p _REFINEMENT_ORPHAN_RECENT >/dev/null 2>&1 \
        || declare -gA _REFINEMENT_ORPHAN_RECENT=()
      while IFS=$'\t' read -r orph_repo orph_item orph_label; do
        [[ -n "$orph_repo" && -n "$orph_item" && -n "$orph_label" ]] || continue
        orph_key="$orph_repo|$orph_item"
        if [[ -z "${_REFINEMENT_ORPHAN_RECENT[$orph_key]+x}" ]]; then
          _REFINEMENT_ORPHAN_RECENT[$orph_key]=1
          # The aggregate is taken out here, not inside `--jq`: `gh api
          # --paginate` re-runs its filter once per page and prints each
          # page's result as its own document (TD-PPagop-26081306), and this
          # endpoint pages at thirty, so a `sort_by | last` inside the filter
          # yields one stamp per matching page on any issue with a timeline
          # longer than that — an unparseable multi-line value that reads as
          # "unknown" and defers the issue for good. So the read streams one
          # ISO-8601 stamp per line across every page and the latest is taken
          # with `sort | tail -1`: a lexical sort is a time sort for these
          # stamps, the same property `fleet_logs`' own union sort relies on.
          orph_labelled_at="$(gh api --paginate "repos/$orph_repo/issues/$orph_item/timeline" \
              --jq ".[] | select(.event == \"labeled\" and .label.name == \"$refinement_reason_label\")
                    | .created_at // empty" 2>/dev/null | sort | tail -1)" || orph_labelled_at=""
          if [[ -n "$orph_labelled_at" ]]; then
            orph_age_verdict="$(jq -nr --arg at "$orph_labelled_at" --arg horizon "$union_log_horizon" \
              --argjson grace "$LABEL_OWN_GRACE_SECONDS" '
                (try ($at | fromdateiso8601) catch null) as $a |
                (try ($horizon | fromdateiso8601) catch null) as $h |
                if $a == null or $h == null then "unknown"
                elif ($h - $a) < $grace then "recent"
                else "old" end' 2>/dev/null)" || orph_age_verdict="unknown"
            [[ "$orph_age_verdict" == "old" ]] && _REFINEMENT_ORPHAN_RECENT[$orph_key]=0
          fi
          # No resolvable `labelled_at` (a failed timeline call, an
          # unparseable horizon) leaves the memo at its default of 1 —
          # deferred, not stripped, the same fail-safe direction every other
          # reader of this grace mechanism takes on a malformed input.
        fi
        [[ "${_REFINEMENT_ORPHAN_RECENT[$orph_key]}" == "0" ]] || continue
        if refinement_label_remove "$orph_repo" "$orph_item" "$orph_label"; then
          log_event "own-label-action" \
            "$(label_own_action_fields "$orph_repo" "$orph_item" "$orph_label" "remove")"
        else
          log_event "warning" "$(jq -nc --arg d "could not remove the orphaned $orph_label label from $orph_repo#$orph_item" \
             '{detail: $d}')"
        fi
      done < <(refinement_blocked_label_orphaned "$(blocked_items "$union_log")" \
                 "$live_reason_issues_json" "$slug" "$union_log")
    fi
    issues_raw="$(gather_issues "$slug")"
    emit_first_seen "$slug" issues "$issues_raw"
    issues="$(exclude_claimed_items "$issues_raw" "$claimed_item_refs_json")"
    # Requirement 16.4's deterministic drops (assigned, `blocked`-labelled,
    # unresolved `Blocked-by:`), reported rather than lost the moment
    # scripts/gather-issues.sh applies them (agent-ops#447): a repo with
    # drops leaves an `issues-excluded` event any reader of the shared log —
    # the cycle record, the dashboard's log tail — can see without
    # re-deriving the filter by hand.
    #
    # Logged only when this repo's exclusion set differs from the one most
    # recently logged for it (review decision on agent-ops#452 concern 1):
    # an onset and a release are both changes, so "now empty" logs exactly as
    # "now non-empty" does, and a quiet cycle logs nothing because nothing
    # changed — not because $issues_excluded happens to be empty this time.
    # Fail open on the *previous*-state read: if it cannot be read, log
    # unconditionally rather than risk staying silent — silence is the #447
    # failure class this event exists to remove.
    #
    # The *current* set gets no such leniency (review decision on
    # agent-ops#452 concern 3): `gather_issues_excluded` reports `null`,
    # never `[]`, when the gather failed or degraded — the deterministic
    # filter did not run to completion, so the exclusion set is unknown, not
    # known-empty. Comparing an unknown current set against a known previous
    # one would fabricate a release event on an ordinary `gh` hiccup and, by
    # overwriting the baseline, mask a genuinely stuck exclusion behind a
    # flapping gatherer. A `null` current set therefore skips the
    # comparison, the event and the baseline update entirely — a failed
    # gather is a no-op on the event stream, not a claim about it — while
    # the Co-Ordinator's own runtime input still gets an array: `[]` for
    # "nothing to report", the same reading requirement 3j already gives an
    # empty `candidates`.
    issues_excluded_raw="$(gather_issues_excluded "$slug")"
    if [[ "$issues_excluded_raw" != "null" ]]; then
      issues_excluded="$issues_excluded_raw"
      issues_excluded_changed=1
      if prev_issues_excluded="$(jq -ce --arg r "$slug" '(.[$r] // [])' \
            <<<"$latest_issues_excluded_json" 2>/dev/null)"; then
        if issues_excluded_same="$(jq -nc --argjson prev "$prev_issues_excluded" --argjson cur "$issues_excluded" \
              '($prev | sort_by(.number, .reason)) == ($cur | sort_by(.number, .reason))' 2>/dev/null)" \
            && [[ "$issues_excluded_same" == "true" ]]; then
          issues_excluded_changed=0
        fi
      fi
      if [[ "$issues_excluded_changed" == "1" ]]; then
        log_event "issues-excluded" "$(jq -nc --arg r "$slug" --argjson ex "$issues_excluded" \
          '{repo: $r, count: ($ex | length),
            detail: (($ex | length | tostring) + " issue(s) excluded"
                     + (if ($ex | length) > 0
                        then ": " + ([$ex[] | "#\(.number) (\(.reason))"] | join(", "))
                        else "" end)),
            excluded: $ex}')"
        latest_issues_excluded_json="$(jq -c --arg r "$slug" --argjson ex "$issues_excluded" \
          '.[$r] = $ex' <<<"$latest_issues_excluded_json" 2>/dev/null || printf '%s' "$latest_issues_excluded_json")"
      fi
    fi
  fi
  tech_debt="[]"; tech_debt_raw="[]"
  if jq -e 'any(.[]; . == "tech-debt")' <<<"$sources" >/dev/null 2>&1; then
    tech_debt_raw="$(gather_tech_debt "$slug")"
    emit_first_seen "$slug" tech-debt "$tech_debt_raw"
    tech_debt="$(exclude_claimed_items "$tech_debt_raw" "$claimed_item_refs_json")"
  fi
  expensive_gather_fresh=1
  expensive_gather_as_of="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  expensive_gather_cache_save "$state_dir" "$slug" "$(jq -nc \
    --arg at "$expensive_gather_as_of" \
    --argjson f "$findings_raw" --argjson rf "$review_feedback_raw" \
    --argjson ad "$abandoned_drafts_raw" --argjson mc "$merge_conflicts_raw" \
    --argjson dq "$dequeued_raw" --argjson rh "$register_hygiene_raw" \
    --argjson is "$issues_raw" --argjson ie "$issues_excluded_raw" \
    --argjson td "$tech_debt_raw" \
    '{gathered_at: $at, findings_raw: $f, review_feedback_raw: $rf,
      abandoned_drafts_raw: $ad, merge_conflicts_raw: $mc, dequeued_raw: $dq,
      register_hygiene_raw: $rh, issues_raw: $is, issues_excluded_raw: $ie,
      tech_debt_raw: $td}')" \
    || log_event "warning" "$(jq -nc --arg d "could not persist the expensive-gather cache for $slug — its next non-selected cycle will see empty bands, not this cycle's read" '{detail: $d}')"
  else
  # Not this cycle's turn (see the requirement-48 comment above): reuse the
  # raw gather this node cached the last time $slug was picked, re-applying
  # this cycle's own `sources` gating and claim exclusion to it exactly as
  # the fresh branch does to a live read. No emit_first_seen here — nothing
  # was newly observed this cycle, only re-shown.
  expensive_gather_fresh=0
  expensive_gather_cache_json="$(expensive_gather_cache_load "$state_dir" "$slug")"
  if [[ -n "$expensive_gather_cache_json" ]]; then
    expensive_gather_as_of="$(jq -r '.gathered_at // ""' <<<"$expensive_gather_cache_json" 2>/dev/null || true)"
  else
    expensive_gather_as_of=""
    expensive_gather_cache_json='{}'
  fi
  findings_raw="$(jq -c '.findings_raw // []' <<<"$expensive_gather_cache_json" 2>/dev/null || echo '[]')"
  review_feedback_raw="$(jq -c '.review_feedback_raw // []' <<<"$expensive_gather_cache_json" 2>/dev/null || echo '[]')"
  abandoned_drafts_raw="$(jq -c '.abandoned_drafts_raw // []' <<<"$expensive_gather_cache_json" 2>/dev/null || echo '[]')"
  merge_conflicts_raw="$(jq -c '.merge_conflicts_raw // []' <<<"$expensive_gather_cache_json" 2>/dev/null || echo '[]')"
  dequeued_raw="$(jq -c '.dequeued_raw // []' <<<"$expensive_gather_cache_json" 2>/dev/null || echo '[]')"
  register_hygiene_raw="$(jq -c '.register_hygiene_raw // []' <<<"$expensive_gather_cache_json" 2>/dev/null || echo '[]')"
  issues_raw="$(jq -c '.issues_raw // []' <<<"$expensive_gather_cache_json" 2>/dev/null || echo '[]')"
  issues_excluded_raw="$(jq -c '.issues_excluded_raw // null' <<<"$expensive_gather_cache_json" 2>/dev/null || echo 'null')"
  tech_debt_raw="$(jq -c '.tech_debt_raw // []' <<<"$expensive_gather_cache_json" 2>/dev/null || echo '[]')"

  findings="[]"
  if jq -e 'any(.[]; . == "security" or . == "code-quality")' <<<"$sources" >/dev/null 2>&1; then
    findings="$(exclude_claimed_items "$findings_raw" "$claimed_item_refs_json")"
  fi
  review_feedback="[]"
  if jq -e 'any(.[]; . == "review-feedback")' <<<"$sources" >/dev/null 2>&1; then
    review_feedback="$(exclude_claimed_items "$(exclude_claimed_prs "$review_feedback_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
  abandoned_drafts="$(exclude_claimed_items "$(exclude_claimed_prs "$abandoned_drafts_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  merge_conflicts="[]"
  if jq -e 'any(.[]; . == "merge-conflicts")' <<<"$sources" >/dev/null 2>&1; then
    merge_conflicts="$(exclude_claimed_items "$(exclude_claimed_prs "$merge_conflicts_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
  dequeued="[]"
  if jq -e 'any(.[]; . == "dequeued")' <<<"$sources" >/dev/null 2>&1; then
    dequeued="$(exclude_claimed_items "$(exclude_claimed_prs "$dequeued_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
  register_hygiene="[]"
  if jq -e 'any(.[]; . == "register-hygiene")' <<<"$sources" >/dev/null 2>&1; then
    register_hygiene="$(exclude_claimed_items "$register_hygiene_raw" "$claimed_item_refs_json")"
  fi
  issues="[]"; issues_excluded="[]"
  if jq -e 'any(.[]; startswith("issues"))' <<<"$sources" >/dev/null 2>&1; then
    issues="$(exclude_claimed_items "$issues_raw" "$claimed_item_refs_json")"
    [[ "$issues_excluded_raw" != "null" ]] && issues_excluded="$issues_excluded_raw"
  fi
  tech_debt="[]"
  if jq -e 'any(.[]; . == "tech-debt")' <<<"$sources" >/dev/null 2>&1; then
    tech_debt="$(exclude_claimed_items "$tech_debt_raw" "$claimed_item_refs_json")"
  fi
  fi
  # The implementation-plan source's path is per-repo config, never a path
  # fixed in the prompt (issue #77): echo it into the runtime-input entry only
  # when the repo actually lists the source, so the Co-Ordinator reads it from
  # its own input rather than a repo it happens to know about. The startup
  # guard above already refused to run if this were missing.
  implementation_plan_path=""
  if jq -e 'any(.[]; . == "implementation-plan")' <<<"$sources" >/dev/null 2>&1; then
    implementation_plan_path="$(jq -r --arg s "$slug" \
      '.[] | select(.slug == $s) | .implementation_plan_path // ""' <<<"$repos_json")"
  fi
  # findings/review_feedback/abandoned_drafts/merge_conflicts/dequeued/
  # register_hygiene/issues/tech_debt are the pre-fetched bands themselves —
  # issue threads (requirement 3d/#118) and the open tech-debt register
  # (requirement 3t/#310) included — each unbounded past this call and each
  # tens of kilobytes alone; $sources is this repo's configured source list,
  # bounded by config, and stays in argv (requirement 4g). The eight bands arrive on
  # stdin, one document per line, bound positionally with `input as $name` in
  # the order printed (TD-PPagop-26081406) — never in argv, where past
  # MAX_ARG_STRLEN this build would silently drop the repo's whole entry.
  entry_docs="$(printf '%s\n' "$findings" "$review_feedback" "$abandoned_drafts" \
    "$merge_conflicts" "$dequeued" "$register_hygiene" "$issues" "$tech_debt")"
  # `issues_excluded` rides in as its own --argjson, not on this stdin
  # stream: unlike the eight bands above, it is bounded by the gatherer's own
  # 100-item page (scripts/gather-issues.sh) and each entry is a bare number
  # and a short reason, tens of bytes at most — nowhere near MAX_ARG_STRLEN.
  entry="$(jq -nc --arg slug "$slug" --arg db "$default_branch" --argjson sources "$sources" \
    --arg ipp "$implementation_plan_path" --argjson ie "$issues_excluded" \
    'input as $findings | input as $rf | input as $ad | input as $mc | input as $dq | input as $rh
     | input as $issues | input as $td
     | {slug: $slug, default_branch: $db, sources: $sources, findings: $findings, review_feedback: $rf, abandoned_drafts: $ad, merge_conflicts: $mc, dequeued: $dq, register_hygiene: $rh, human_visibility: [], issues: $issues, issues_excluded: $ie, tech_debt: $td}
     + (if $ipp == "" then {} else {implementation_plan_path: $ipp} end)' <<<"$entry_docs")"
  # Requirement 48 (agent-ops#1086): whether the eight bands above came from
  # this cycle's own read of $slug or from this node's cache of an earlier
  # cycle's — lib/coordinator-input.sh documents what a reader (the
  # Co-Ordinator, a human, the no-op fingerprint) may conclude from each.
  # Applied after the lifted block above, not inside it, so
  # test/repo-entry-build.test.sh's literal extraction of that block (which
  # predates this feature) stays byte-identical and keeps pinning the eight
  # bands' own shape undisturbed by this addition.
  entry="$(jq -c --arg fresh "${expensive_gather_fresh:-1}" --arg at "${expensive_gather_as_of:-}" \
    '. + {expensive_gather: {fresh: ($fresh == "1"), gathered_at: (if $at == "" then null else $at end)}}' \
    <<<"$entry")"
  # $entry — one repo's whole pre-fetched sources, including issue threads
  # (requirement 3d/#118) and its open tech-debt register (requirement
  # 3t/#310) — is the least bounded value in this loop, and the accumulator it
  # joins only grows every iteration. Both arrive on stdin, one document per
  # line, bound positionally with `input as $name` in the order printed
  # (requirement 4g) — never in argv, where past MAX_ARG_STRLEN this append
  # would silently drop the repo from the Co-Ordinator's whole input.
  ordered_repos_json="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' \
    <<<"$ordered_repos_json"$'\n'"$entry")"
  # --- Labels (requirement 6a, agent-ops#687) ---
  # Every repository this cycle gathers data for, not only the one it later
  # selects to work: the Co-Ordinator's block-label projection and the
  # Refiner's own can both reach a repository step 6a below never touches, so
  # ensuring only there left both silently unable to create anything the first
  # time either ran against a fresh repository. Rate-limited by a stamp under
  # `state_dir` (`labels_ensure_interval_hours`, default 24h) so the steady
  # state stays one listing per repository per interval and zero writes.
  gathered_labels_report="$(labels_ensure_stamped "$state_dir" "$CONFIG_FILE" "$SCHEMA_FILE" \
    "$slug" target "$labels_ensure_interval_hours" 2>/dev/null || true)"
  if [[ -n "$gathered_labels_report" ]]; then
    log_event "labels-ensured" "$(jq -nc --arg repo "$slug" --arg report "$gathered_labels_report" '
      {repo: $repo, role: "target"}
      + ($report | split("\n") | map(select(length > 0) | split("\t"))
         | {created: [.[] | select(.[0] == "created") | .[1]],
            failed:  [.[] | select(.[0] == "failed")  | .[1]]})')"
  fi
  # Kept in a separate array, never folded into the entry above: this is the
  # Script's own bookkeeping, and every byte added to `ordered_repos_json` is a
  # byte the Co-Ordinator pays to read. A cost-control feature that grows the
  # prompt it is meant to avoid buying has not saved anything.
  state="$(gather_source_state "$slug" "$default_branch")"
  source_states_json="$(jq -nc 'input as $arr | input as $s | $arr + [$s]' \
    <<<"$source_states_json"$'\n'"$state")"
  # Requirement 34f, gathered here for the repo loop's one `gh` budget but read
  # below, before the skip-lists: a human's instruction to reopen a void has to
  # land *before* the extract the Co-Ordinator is handed, not after it.
  unvoid_requests_json="$(jq -nc 'input as $arr | input as $r | $arr + $r' \
    <<<"$unvoid_requests_json"$'\n'"$(gather_unvoid_requests "$slug")")"
  # Requirement 34g, same reasoning: a human's hand-applied label has to reach
  # the skip-list before the Co-Ordinator is handed it. An empty
  # `needs_refinement_label` disables the projection entirely (README.md), so
  # there is nothing to scan for and no `gh` call to spend.
  if [[ -n "$needs_refinement_label" ]]; then
    hand_flagged_refinements_json="$(jq -nc 'input as $arr | input as $r | $arr + $r' \
      <<<"$hand_flagged_refinements_json"$'\n'"$(gather_hand_flagged_refinements "$slug")")"
  fi
done < <(repo_order_by_effective_age "$repo_order_now" "$repos_json" < "$cycle_dir/.repo_ts")
rm -f "$cycle_dir/.repo_ts"
}

compute_skip_lists() {
# --- Skip-list extracts (requirement 34: blocked iff the most recent
#     attempt-failed/unblocked event for that repo+item is attempt-failed;
#     requirement 34c: void iff the most recent item-void/unvoided event for it
#     is item-void). Two lists, not one, because the Co-Ordinator may clear the
#     first and may never clear the second. ---
#
# Read here — above the back-pressure decision below, not after it — because the
# Enabler's eligible set is derived from these two lists (requirement 35a) and
# back-pressure can end the cycle. A fleet wedged at `max_open_agent_prs` is
# exactly when getting something unblocked matters most, and the Enabler opens
# no PRs, so it must not be what back-pressure silences.
# Requirement 34f, applied first: a human labelled an issue or pull request on
# GitHub asking for a void to be reopened. The `unvoided` events go in here —
# above the extract that reads them — because a clearance landing after
# `void_json` was computed would be a cycle late, and a cycle late for this
# source means the human watches nothing happen and concludes, a second time,
# that the label does not work.
#
# The new lines are appended to the union snapshot as well as to the log. That
# snapshot was taken once at the top of the cycle (requirement 2.5) so every
# reader below sees one consistent stream; rebuilding it here would pull in
# whatever peers had written since, which is the inconsistency it exists to
# prevent, so the exact lines this cycle just wrote are what gets added and
# nothing else.
unvoid_clearances_json="$(unvoid_clearances "$unvoid_requests_json" "$(void_items "$union_log")")"
unvoid_clearances_n="$(jq 'length' <<<"$unvoid_clearances_json" 2>&1)" \
  || { guard_warn "unvoid_clearances_n" "$unvoid_clearances_n"; unvoid_clearances_n=0; }
if [[ "$unvoid_clearances_n" != "0" ]]; then
  log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
  while IFS= read -r clearance; do
    [[ -n "$clearance" ]] || continue
    # `by: "label"` distinguishes this from the Enabler's unblocks and from a
    # line a human appended by hand; the request's URL and the void's own
    # timestamp are what let a later reader see which verdict was reopened and
    # on whose authority, without going back to GitHub.
    log_event "unvoided" "$(jq -c '{item: .item, repo: .repo, by: "label",
                                    request_url: .url, labelled_at: .labelled_at,
                                    cleared_void_ts: .void_ts}' <<<"$clearance")"
  done < <(jq -c '.[]' <<<"$unvoid_clearances_json" 2>/dev/null || true)
  tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
fi

# Requirement 34g, applied next and for the same reason as 34f above: a human
# labelled an issue directly, asking the pipeline to treat it as too
# under-specified to select, and that has to land before `blocked_json` is
# read below — a cycle late here is a human watching nothing happen and
# concluding, the same way they would for an unread `unvoided`, that the label
# does not work.
#
# New blocks first, against `blocked_items` as it stands after the unvoid
# clearances above (an item a void just reopened has no other block to
# collide with); then, against the extract as it stands after those new
# blocks, which hand-flagged blocks this mechanism created have lost their
# label since — the `unblocked` half of the same requirement.
#
# Requirement 39f narrows the *new* half, and only that half: an issue still
# carrying the label because this system's own removal silently failed is not
# a human asking for anything, so `label_filter_own_applications` drops it
# before the "not already blocked" test ever sees it. The `cleared` half below
# reads the unfiltered list on purpose — it asks which issues have *lost* the
# label, and an entry filtered out for being our own would read there as a
# label that had gone, unblocking the very item this rule exists to leave
# alone.
if [[ -n "$needs_refinement_label" ]]; then
  refinement_own_actions_json="$(label_own_actions_map "$needs_refinement_label" "$union_log")"
  hand_flagged_not_ours_json="$(label_filter_own_applications "$hand_flagged_refinements_json" \
    "$refinement_own_actions_json" "$union_log_horizon")"
  hand_flag_new_json="$(refinement_hand_flag_new "$hand_flagged_not_ours_json" "$(blocked_items "$union_log")")"
  hand_flag_new_n="$(jq 'length' <<<"$hand_flag_new_json" 2>&1)" \
    || { guard_warn "hand_flag_new_n" "$hand_flag_new_n"; hand_flag_new_n=0; }
  if [[ "$hand_flag_new_n" != "0" ]]; then
    log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
    while IFS= read -r flag; do
      [[ -n "$flag" ]] || continue
      log_event "attempt-failed" "$(item_event_fields "coordinator" \
        "$(jq -r '"hand-applied the " + .label + " label" + (if (.by // "") == "" then "" else " (by " + .by + ")" end)' <<<"$flag")" \
        "$(jq -r '.repo' <<<"$flag")" "$(jq -r '.number' <<<"$flag")" \
        "$(refinement_hand_flag_fields "$(jq -r '.repo' <<<"$flag")" "$(jq -r '.number' <<<"$flag")" \
             "$(jq -r '.label' <<<"$flag")" "$(jq -r '.by // ""' <<<"$flag")" \
             "$(jq -r '.labelled_at // ""' <<<"$flag")" "$(jq -r '.url // ""' <<<"$flag")")")"
    done < <(jq -c '.[]' <<<"$hand_flag_new_json" 2>/dev/null || true)
    tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
  fi

  # Requirement 39f's retry: `label_filter_own_applications` above has already
  # proven each entry `label_own_stale_applications` returns here to be our own
  # last action, and the blocked extract it is given here proves the other half
  # — that no block stands behind the label any more. Both tests are needed,
  # and the second is the one that keeps this from undoing requirement 34e: a
  # label the Script applied to an item it blocked one cycle ago is *also* our
  # own last action, and removing that one would strip the live projection of
  # an open block off the issue while the human is still being waited on. What
  # is left after both is exactly the set `release_refinement_label`'s own
  # removal attempt failed on.
  #
  # The extract is read here rather than reused from above so it includes the
  # hand-flag blocks this cycle just wrote (appended to `union_log` in the
  # branch above) — an issue whose label earned a block moments ago is not a
  # stuck one. Best-effort, like every other label write: a second failure
  # costs nothing beyond what the first already did, and the filter above
  # already keeps the label from being misread as a fresh flag on any cycle in
  # between.
  if ! (( DRY_RUN )); then
    hand_flag_stale_json="$(label_own_stale_applications "$hand_flagged_refinements_json" \
      "$refinement_own_actions_json" "$(blocked_items "$union_log")" "$union_log_horizon")"
    while IFS=$'\t' read -r stale_repo stale_number; do
      [[ -n "$stale_repo" && -n "$stale_number" ]] || continue
      if refinement_label_remove "$stale_repo" "$stale_number" "$needs_refinement_label"; then
        log_event "own-label-action" \
          "$(label_own_action_fields "$stale_repo" "$stale_number" "$needs_refinement_label" "remove")"
      else
        log_event "warning" \
          "$(jq -nc --arg d "could not retry removing the $needs_refinement_label label from $stale_repo#$stale_number" \
             '{detail: $d}')"
      fi
    done < <(jq -r '.[] | [(.repo // ""), ((.number // "") | tostring)] | @tsv' \
               <<<"$hand_flag_stale_json" 2>/dev/null || true)
  fi

  hand_flag_cleared_json="$(refinement_hand_flag_cleared "$hand_flagged_refinements_json" "$(blocked_items "$union_log")")"
  hand_flag_cleared_n="$(jq 'length' <<<"$hand_flag_cleared_json" 2>&1)" \
    || { guard_warn "hand_flag_cleared_n" "$hand_flag_cleared_n"; hand_flag_cleared_n=0; }
  if [[ "$hand_flag_cleared_n" != "0" ]]; then
    log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
    while IFS= read -r cleared; do
      [[ -n "$cleared" ]] || continue
      # `by: "label-removed"` distinguishes this from the Co-Ordinator's own
      # `unblocked` (requirement 18) and the Enabler's — the same trail
      # `unvoided`'s `by: "label"` leaves for a void reopened the same way.
      log_event "unblocked" "$(jq -c '{item: .item, repo: .repo, by: "label-removed"}' <<<"$cleared")"
    done < <(jq -c '.[]' <<<"$hand_flag_cleared_json" 2>/dev/null || true)
    tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
  fi
fi

# Requirement 38b's own reconciliation sweep for `blocked`/`blocked:<reason>`
# (agent-ops#651), unconditional — unlike the `needs_refinement_label` block
# above, these two labels are not configurable and carry no hand-flag path, so
# this runs every cycle regardless. Unlike requirement 39f's stale-retry, no
# live GitHub read or own/human attribution heuristic is needed:
# `refinement_blocked_label_stale` already proves an `own-label-action add`
# recorded for the label is ours with nothing but the log, so a
# `release_refinement_label` removal that silently failed at the moment its
# block cleared gets retried here rather than sitting on the issue forever —
# the same permanently-stuck-hold class of failure agent-ops#639 ended for the
# assignment-based mechanism, reopened on the label list if this half were
# skipped.
if ! (( DRY_RUN )); then
  while IFS=$'\t' read -r stale_repo stale_item stale_label; do
    [[ -n "$stale_repo" && -n "$stale_item" && -n "$stale_label" ]] || continue
    if refinement_label_remove "$stale_repo" "$stale_item" "$stale_label"; then
      log_event "own-label-action" \
        "$(label_own_action_fields "$stale_repo" "$stale_item" "$stale_label" "remove")"
    else
      log_event "warning" \
        "$(jq -nc --arg d "could not retry removing the $stale_label label from $stale_repo#$stale_item" \
           '{detail: $d}')"
    fi
  done < <(refinement_blocked_label_stale "$(blocked_items "$union_log")" "$union_log")
fi

# Requirement 34i, applied last of the three reconciliations, and for the same
# reason as 34f and 34g above: it has to land before the extract the
# Co-Ordinator, the Enabler's eligible set and the dashboard are all handed.
# What it clears is the block whose *work* has gone — the issue closed, the
# pull request merged, the register entry flipped to `resolved` — none of which
# emits an event, and none of which any other reader of the log can see. The
# Co-Ordinator never revisits such an item (a finished item is offered by no
# source, so it never reaches the candidates), which leaves only the Enabler's
# recheck, a full engagement `enabler_recheck_hours` later to learn what one
# read of state already on disk says now.
#
# Against the *open* blocked set (requirement 34h): a void item needs no
# unblocking, and an `unblocked` written against a void would put a clear in the
# log for no reason at all.
open_blocked_now="$(open_blocked_items "$union_log")"
# The register read, for the repos that have blocked register items and no
# others — usually none, and then it costs nothing. `ordered_repos_json` is what
# names each repo's default branch; a repo this cycle did not walk has no entry
# there and is asked nothing, which is the same "unknown decides nothing" the
# source-state digest's `ok` gives the other two classes.
register_status_json='{}'
while IFS=$'\t' read -r reg_slug reg_ids; do
  [[ -n "$reg_slug" && -n "$reg_ids" ]] || continue
  reg_branch="$(jq -r --arg s "$reg_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
    <<<"$ordered_repos_json" 2>/dev/null || true)"
  [[ -n "$reg_branch" ]] || continue
  # shellcheck disable=SC2086  # $reg_ids is a deliberate word-split id list.
  reg_map="$(gather_register_status "$reg_slug" "$reg_branch" blocked $reg_ids)"
  register_status_json="$(jq -c --arg s "$reg_slug" --argjson m "$reg_map" '. + {($s): $m}' \
    <<<"$register_status_json" 2>/dev/null || printf '%s' "$register_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
         <<<"$(work_gone_register_ids "$open_blocked_now")" 2>/dev/null || true)

# The project-review read, for the repos that have blocked project-review
# items and no others — same cost shape as the register read above.
review_status_json='{}'
while IFS=$'\t' read -r rev_slug rev_refs; do
  [[ -n "$rev_slug" && -n "$rev_refs" ]] || continue
  rev_branch="$(jq -r --arg s "$rev_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
    <<<"$ordered_repos_json" 2>/dev/null || true)"
  [[ -n "$rev_branch" ]] || continue
  # shellcheck disable=SC2086  # $rev_refs is a deliberate word-split ref list.
  rev_map="$(gather_review_status "$rev_slug" "$rev_branch" blocked $rev_refs)"
  review_status_json="$(jq -c --arg s "$rev_slug" --argjson m "$rev_map" '. + {($s): $m}' \
    <<<"$review_status_json" 2>/dev/null || printf '%s' "$review_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
         <<<"$(work_gone_review_refs "$open_blocked_now")" 2>/dev/null || true)

# The plan read, for the repos that have blocked plan-task items *and* an
# `implementation_plan_path` configured — a repo without one has nowhere for
# this to read, so it is asked nothing (the same "unknown decides nothing" as
# every other class here).
plan_status_json='{}'
while IFS=$'\t' read -r plan_slug plan_ids; do
  [[ -n "$plan_slug" && -n "$plan_ids" ]] || continue
  plan_entry="$(jq -c --arg s "$plan_slug" 'map(select(.slug == $s)) | .[0] // {}' \
    <<<"$ordered_repos_json" 2>&1)" || { guard_warn "work-gone:plan_entry" "$plan_entry"; plan_entry='{}'; }
  plan_branch="$(jq -r '.default_branch // ""' <<<"$plan_entry" 2>/dev/null || true)"
  plan_path="$(jq -r '.implementation_plan_path // ""' <<<"$plan_entry" 2>/dev/null || true)"
  [[ -n "$plan_branch" && -n "$plan_path" ]] || continue
  # shellcheck disable=SC2086  # $plan_ids is a deliberate word-split id list.
  plan_map="$(gather_plan_status "$plan_slug" "$plan_branch" "$plan_path" blocked $plan_ids)"
  plan_status_json="$(jq -c --arg s "$plan_slug" --argjson m "$plan_map" '. + {($s): $m}' \
    <<<"$plan_status_json" 2>/dev/null || printf '%s' "$plan_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
         <<<"$(work_gone_plan_ids "$open_blocked_now")" 2>/dev/null || true)

work_gone_json="$(work_gone_clearances "$open_blocked_now" "$source_states_json" "$register_status_json" \
                   "$review_status_json" "$plan_status_json")"
work_gone_n="$(jq 'length' <<<"$work_gone_json" 2>&1)" \
  || { guard_warn "work_gone_n" "$work_gone_n"; work_gone_n=0; }
if [[ "$work_gone_n" != "0" ]]; then
  log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
  while IFS= read -r clearance; do
    [[ -n "$clearance" ]] || continue
    # `by: "work-gone"` distinguishes this from the Co-Ordinator's own
    # `unblocked` (requirement 18), the Enabler's, and the label-driven one of
    # requirement 34g; `detail` carries the fact that decided it, so a later
    # reader can audit the clearance without re-deriving it.
    log_event "unblocked" "$(jq -c '{item: .item, repo: .repo, by: "work-gone",
                                     detail: .reason}' <<<"$clearance")"
  done < <(jq -c '.[]' <<<"$work_gone_json" 2>/dev/null || true)
  tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
fi

# Requirement 34j, applied last of the four reconciliations and for the same
# reason as 34f, 34g and 34i above: it has to land before the extract the
# Co-Ordinator, the Enabler's eligible set and the dashboard are all handed.
# What it clears is a block whose own `Blocked-by:` dependency has resolved —
# read from this cycle's own `issues` candidates, already reshaped once per
# repo above, so no second `gh` read is spent deciding it: an already-blocked
# issue reappearing there this cycle is itself gather-issues.sh's live proof
# that every reference it named is now closed.
#
# Requirement 48 (agent-ops#1086) is why the reshape starts by narrowing to
# the repos this cycle actually read: that live proof is the whole mechanism
# here, and a repo whose `issues` band was replayed from this node's
# expensive-gather cache carries proof from whenever its last turn was, not
# from this cycle. `dependency_clearances`' own rule already names the right
# answer for the rest — an item this cycle's candidates do not carry, "simply
# not walked this cycle", decides nothing and stays blocked — so a non-fresh
# repo's dependency clearances wait for its own turn rather than being made
# on stale proof. An entry with no `expensive_gather` stamp at all (a caller
# that predates the field, every test that builds the array by hand) reads as
# fresh, exactly as it did before this narrowing existed.
issues_by_repo_json="$(jq -c '
  map(select((.expensive_gather // null) == null or (.expensive_gather.fresh == true)))
  | map({key: .slug,
       value: ((.issues // [])
               | map({key: (.number | tostring),
                      value: {body: (.body // ""), comments: (.comments // [])}})
               | from_entries)})
  | from_entries' <<<"$ordered_repos_json" 2>/dev/null || true)"
[[ -n "$issues_by_repo_json" ]] || issues_by_repo_json='{}'

dependency_json="$(dependency_clearances "$open_blocked_now" "$issues_by_repo_json")"
dependency_n="$(jq 'length' <<<"$dependency_json" 2>&1)" \
  || { guard_warn "dependency_n" "$dependency_n"; dependency_n=0; }
if [[ "$dependency_n" != "0" ]]; then
  log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
  while IFS= read -r clearance; do
    [[ -n "$clearance" ]] || continue
    # `by: "dependency-resolved"` distinguishes this from the Co-Ordinator's
    # own `unblocked` (requirement 18), the Enabler's, the label-driven one of
    # requirement 34g, and requirement 34i's `work-gone`; `detail` carries the
    # reference(s) that decided it, so a later reader can audit the clearance
    # without re-deriving it.
    log_event "unblocked" "$(jq -c '{item: .item, repo: .repo, by: "dependency-resolved",
                                      detail: .reason}' <<<"$clearance")"
  done < <(jq -c '.[]' <<<"$dependency_json" 2>/dev/null || true)
  tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
fi

blocked_json="$(blocked_items "$union_log")"
void_json="$(void_items "$union_log")"

# Requirement 34n's memory, applied the moment the extract exists: every pair
# an earlier cycle already retired (a `void-retired` event on the log — a
# fact, not a state, exactly as `void-object-closed` is) is subtracted here,
# before the 34k sweep, the 34l register pass and 34n's own evidence-gathering
# below ever see the set. Two bounds follow that re-deciding retirement from
# scratch each cycle would not give: the register read below runs only over
# the *unretired* residue, so an id retired once is never asked about again —
# per-cycle GitHub cost proportional to what is still live, not to every void
# ever filed — and the extract stays bounded even on a cycle whose register
# read fails, because this subtraction needs nothing but the log. The
# subtraction is ts-ordered (`subtract_retired_voids`): an item voided afresh
# after its old verdict retired re-enters on the new verdict's own terms.
#
# Neither pass between here and 34n loses anything to the narrowing: 34k's
# closed-object gate already skips every issue- or PR-shaped id a retirement
# could cover (a closed object is what actioned it), and 34l's register repair
# has nothing to do once a row reads `resolved`/`not-debt`, which retirement
# itself required first — narrowing before 34l is what stops a repo whose
# void register ids are all retired paying a register fetch forever. The 34f
# label route is computed further up, from `void_items` directly, so a human's
# `unvoided` still reaches a retired-but-void item.
#
# Gated on the same switch as retirement itself: `0` must restore the full,
# unretired extract — the recorded facts stay on the log, but stop masking —
# so an operator has a kill switch if retirement ever misbehaves, and flipping
# it back re-masks from the log with nothing re-queried.
if (( void_retire_after_days > 0 )); then
  void_json="$(subtract_retired_voids "$void_json" "$(void_retired_items "$union_log")")"
fi

# 34k: act on void. A void already stops the item being selected again
# (requirement 34c), but nothing before this touched the GitHub object it
# names, so an obsolete draft PR or a superseded issue stayed open — visible
# to every human and re-derived void by cycle after cycle (issue #240;
# poetic-fiddle #190/#214 were re-derived void on 7+ separate cycles, never
# closed). Only the two id shapes that name a GitHub object at all — a bare
# issue number, or `pr-<n>-…` — are in scope; a register id, a review ref or
# a plan task id names nothing this can close. `void_object_closed_items`
# excludes whatever a previous cycle already actioned, so this never
# re-checks (and never re-closes) the same item twice, even if a human
# reopens the object directly rather than through `unvoid_label`. The event's
# `stage` travels with each candidate because the sweep's corroboration gate
# keys on it — every writer's `item-void` passes requirement 34d before it is
# logged (issue #243), so all three are eligible, and the gate itself lives in
# close-void-github-items.sh (requirement 34a: one definition, at the point
# of action). Skipped on --dry-run: the sweep closes issues and pull
# requests.
if ! (( DRY_RUN )); then
  void_object_closed_json="$(void_object_closed_items "$union_log")"
  # Both arrays arrive on stdin, one document per line, never in argv
  # (requirement 4g): the void extract and the closed set are unbounded, and
  # on 2026-08-12 the extract crossed MAX_ARG_STRLEN — an `--argjson`
  # delivery here failed into its `|| echo '[]'`, silently disabling the one
  # sweep that retires void state.
  void_close_stdin="$void_json"$'\n'"$void_object_closed_json"
  void_close_candidates_json="$(jq -nc \
    --arg issue_re "$WORK_GONE_ISSUE_RE" --arg pr_re "$WORK_GONE_PR_RE" '
    input as $void | input as $closed
    | ($closed | map(.repo + " " + .item)) as $done
    | [ $void[]
        | select((.repo // "") != "" and (.item // "") != "")
        | select((.item | test($issue_re)) or (.item | test($pr_re)))
        | select((.repo + " " + .item) as $k | ($done | index($k)) == null) ]
  ' <<<"$void_close_stdin" 2>&1)" \
    || { guard_warn "void_close_candidates_json" "$void_close_candidates_json"; void_close_candidates_json='[]'; }
  while IFS= read -r vslug; do
    [[ -n "$vslug" ]] || continue
    repo_candidates_json="$(jq -c --arg r "$vslug" '[ .[] | select(.repo == $r)
      | {item, detail, evidence, stage} ]' <<<"$void_close_candidates_json" 2>&1)" \
      || { guard_warn "void:repo_candidates_json" "$repo_candidates_json"; repo_candidates_json='[]'; }
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        closed) log_event "void-object-closed" \
          "$(jq -c --arg r "$vslug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        deferred|warning) log_event "warning" "$(jq -c --arg r "$vslug" \
          '{detail: ("act-on-void sweep (" + $r + "): " + (del(.repo) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(printf '%s' "$repo_candidates_json" \
               | timeout 120 "$SCRIPT_DIR/scripts/close-void-github-items.sh" "$vslug" "$node_name" "$cycle_id" \
                 2>>"$cycle_dir/void-close-sweep.err" || true)
  done < <(jq -r '[.[].repo] | unique[]' <<<"$void_close_candidates_json" 2>/dev/null || true)
fi

# Register rows, requirement 34l — the other half of acting on a void: a void
# item shaped like a tech-debt register id (issue #240) names a file, not a
# GitHub object, so close-void-github-items.sh above leaves it untouched
# entirely — this instead re-derives that repo's register-hygiene candidate
# with the void evidence folded in (gather-register-hygiene.sh's VOIDED STATUS
# problem class), so the ordinary register-hygiene Implementer flow flips
# the row exactly as it repairs any other frontmatter drift. Only for repos
# that actually have a void register item — everywhere else costs nothing
# beyond the one jq read below. This necessarily re-fetches the register (a
# second read this cycle, alongside the plain one the loop at "3. Repo
# ordering" already took) because that earlier pass runs before void_json
# exists to hand it; the alternative is reordering the cycle around a state
# read this is the only consumer of.
void_register_ids_json="$(work_gone_register_ids "$void_json")"
while IFS= read -r vr_slug; do
  [[ -n "$vr_slug" ]] || continue
  vr_branch="$(jq -r --arg s "$vr_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
    <<<"$ordered_repos_json" 2>/dev/null || true)"
  [[ -n "$vr_branch" ]] || continue
  # The void extract on stdin, never in argv (requirement 4g) — same failure
  # shape as the sweep above: past MAX_ARG_STRLEN this call would fall into
  # its `|| echo '[]'` and the pass would silently find nothing. `ids` stays
  # an --argjson: it is one repo's matching register ids, bounded by the
  # register itself.
  vr_candidates_json="$(jq -c --arg r "$vr_slug" \
    --argjson ids "$(jq -c --arg s "$vr_slug" '.[$s] // []' <<<"$void_register_ids_json")" \
    -n 'input as $void
        | [ $void[] | select(.repo == $r and (.item as $i | $ids | index($i)) != null)
            | {item, detail, evidence} ]' <<<"$void_json" 2>&1)" \
    || { guard_warn "vr_candidates_json" "$vr_candidates_json"; vr_candidates_json='[]'; }
  vr_hygiene_json="$(gather_register_hygiene "$vr_slug" "$vr_branch" void "$vr_candidates_json")"
  # Only ever *adds* to what the first pass found. gather_register_hygiene
  # fails safe to `[]`, and this second read can fail where the first
  # succeeded — a rate limit, a network blip, a branch moved between the two.
  # Overwriting on that answer would delete a genuine register-hygiene
  # candidate the cycle already holds, on no evidence at all; the whole point
  # of this pass is a superset of the first, so an empty result is the one
  # answer it can never mean. `purpose void` is what keeps that reasoning
  # true of the tee files as well as of this variable: the two passes wrote
  # to one filename until requirement 34n's liveness rule started reading it,
  # at which point this pass's failure became a false retirement of the other
  # pass's still-live findings.
  vr_hygiene_n="$(jq 'length' <<<"$vr_hygiene_json" 2>&1)" \
    || { guard_warn "vr_hygiene_n" "$vr_hygiene_n"; vr_hygiene_n=0; }
  [[ "$vr_hygiene_n" != "0" ]] || continue
  ordered_repos_json="$(jq -c --arg r "$vr_slug" --argjson rh "$vr_hygiene_json" \
    'map(if .slug == $r then .register_hygiene = $rh else . end)' \
    <<<"$ordered_repos_json" 2>/dev/null || printf '%s' "$ordered_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -r 'keys[]' <<<"$void_register_ids_json" 2>/dev/null || true)

# Human-visibility hygiene, requirement 38e — the read-back half of
# tech-debt/TD-PPagop-26080801.md's fix: a violation requirement 38c's sweep
# could not self-heal (logged above as a `warning`) is read back out of
# `union_log`, re-verified live by scripts/gather-human-visibility-hygiene.sh
# (a stale or already-resolved one is dropped there, never here), and — where
# one survives — assigned into that repo's own `human_visibility` array. Its
# own source (issue #284's decision 2), never register-hygiene's: a violation
# here means finished work is invisible to the human whose merge everything
# waits on, ranked immediately after `merge-conflicts` (config.schema.json),
# the same "finishing beats starting" class as the four sources around it —
# register-hygiene's cosmetic-repair, last-place rationale does not describe
# it. Assigned, not appended: unlike `register_hygiene` above (which two
# passes can each contribute to — the plain gather and the void
# re-derivation) this array has exactly one writer, so there is nothing a
# plain assignment could clobber. Only for repos whose `sources` actually
# list `human-visibility`, and only for repos this reduction found a
# violation for at all — everywhere else costs nothing beyond the one
# reduction over `union_log` below, already read once each for `blocked_json`
# and `void_json` above.
#
# ...with one addition (agent-ops#646): a repo carrying *unretired
# `human-visibility-<hash>` void residue* is walked too, even with no live
# violation of its own. That is the only case in which the walk's own "found a
# violation for it" test and requirement 34n's liveness rule want opposite
# answers — the rule needs a definite "this repo yields no such ref this
# cycle", and a repo the walk skipped leaves no `.ok` marker to say so, which
# `void_liveness_actioned` reads as ungathered and declines to decide on
# forever. It is exactly the bound the `failed-run` shape's own extra fetch
# takes further down, and it is free: with no violations to re-verify,
# scripts/gather-human-visibility-hygiene.sh makes no `gh` call at all and
# prints `[]` on the empty input, which is the definite answer the rule was
# missing. `hv_finding_n` of `0` then skips the assignment below, so a repo
# added by this clause contributes a marker and nothing else — it can never
# manufacture a candidate.
human_visibility_json="$(human_visibility_violations "$union_log")"
# The reduction's own validity gate, and the reason it is a gate rather than a
# fallback to `[]`: a malformed reduction is not "no violations", it is "no
# answer", and handing `[]` to the gatherer for a repo whose violations we
# failed to read would mint an `.ok` marker over an emptiness we never
# established — the one way the marker could lie. So an unreadable reduction
# walks nothing at all, exactly as it did before agent-ops#646 widened the
# walk, and every human-visibility void simply stays undecided for a cycle.
human_visibility_n="$(jq 'length' <<<"$human_visibility_json" 2>&1)" \
  || { guard_warn "human_visibility_n" "$human_visibility_n"; human_visibility_n=""; }
hv_void_repos_json="$(jq -c --arg re "$VOID_LIVENESS_HUMAN_VISIBILITY_RE" '
  [ .[] | select((.repo // "") != "" and ((.item // "") | test($re))) | .repo ] | unique' \
  <<<"$void_json" 2>&1)" \
  || { guard_warn "hv_void_repos_json" "$hv_void_repos_json"; hv_void_repos_json='[]'; }
[[ -n "$human_visibility_n" ]] || hv_void_repos_json='[]'
while IFS= read -r hv_slug; do
  [[ -n "$hv_slug" ]] || continue
  jq -e --arg r "$hv_slug" \
    'any(.[]; .slug == $r and ((.sources // []) | any(.[]; . == "human-visibility")))' \
    <<<"$ordered_repos_json" >/dev/null 2>&1 || continue
  hv_candidates_json="$(jq -c --arg r "$hv_slug" '[.[] | select(.repo == $r)]' <<<"$human_visibility_json")"
  hv_finding_json="$(gather_human_visibility_hygiene "$hv_slug" "$hv_candidates_json")"
  hv_finding_n="$(jq 'length' <<<"$hv_finding_json" 2>&1)" \
    || { guard_warn "hv_finding_n" "$hv_finding_n"; hv_finding_n=0; }
  [[ "$hv_finding_n" != "0" ]] || continue
  ordered_repos_json="$(jq -c --arg r "$hv_slug" --argjson hv "$hv_finding_json" \
    'map(if .slug == $r then .human_visibility = $hv else . end)' \
    <<<"$ordered_repos_json" 2>/dev/null || printf '%s' "$ordered_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -rn --argjson v "$hv_void_repos_json" \
         'input as $hv | (($hv | map(.repo)) + $v) | unique[]' \
         <<<"$human_visibility_json" 2>/dev/null || true)

# Requirement 34n: retire every void entry that is both fully actioned and
# old enough out of `void_json` before anything else reads it — from here on
# `void_json` *is* the bounded extract, reassigned rather than shadowed under
# a new name so every consumer below (the Refiner's candidate filter, the
# no-op fingerprint, the Co-Ordinator's own input) sees it with nothing to
# remember. This is what stops the extract growing without bound: on
# 2026-08-12 it reached 122 entries and 133,615 bytes — past `MAX_ARG_STRLEN`
# — because nothing before this requirement ever retired an entry once it was
# actioned; the only way one left the set at all was a human's hand-appended
# `unvoided` (issue #309).
#
# The 34k sweep and the 34l register-hygiene pass above saw the extract with
# *recorded* retirements already subtracted (the block where `void_json` is
# first computed), but not the ones this block is about to decide — and
# neither needs those either, being already safe to run against an
# item this rule would go on to retire — 34k's own `void_object_closed_items`
# gate already skips a closed object, and 34l's register-hygiene repair has
# nothing left to do once the row already reads `resolved`/`not-debt`, which
# is exactly the state this rule requires before it will retire a register
# void at all. `unvoid_clearances_json`, computed earlier from `void_items`
# directly, is unaffected for the same reason `void_items` itself is: neither
# this reassignment nor requirement 34c's own semantics change — a void stays
# void forever, on the raw log, for every reader that recomputes it there
# (`open_blocked_items`, `enabler_eligible_items`, `refinements_map`, and the
# monitoring dashboard's own use of `void_items`). Retirement narrows only
# what this one cycle goes on to hand somebody, never what counts as void.
#
# "Actioned" is built from six signals, none of them needing a `gh` call this
# rule does not already budget for:
#
#   - an issue or pull request GitHub itself confirms closed
#     (`void_object_closed_items`, re-read here — a pure function over the
#     union log already in memory, costing nothing);
#   - a tech-debt register row whose own file says `status: resolved` or
#     `status: not-debt` — 34i's own "the work is gone" statuses, read by a
#     further `gather_register_status` call per repo with still-unretired void
#     register ids, alongside the one 34i already makes for that repo's
#     blocked ones — the recorded subtraction above is what keeps that
#     residue, and so this read, bounded;
#   - liveness, for the six shapes the cycle already gathers as structured
#     data each cycle (TD-PPagop-26081303, extended by TD-PPagop-26081409):
#     a `dependabot-alert-<n>`/
#     `code-scanning-alert-<n>`, a `register-hygiene-<hash>`, either
#     merge-conflicts shape (`pr-<n>-conflict-<head-sha>`, which requirement
#     34k deliberately excludes from its own close, and
#     `pr-<n>-superseded-<head-sha>`, which it closes — same gather, so the
#     same test decides both), a `pr-<n>-dequeued-<head-sha>` (requirement 3z,
#     excluded from 34k's close for the same reason as the conflict shape), or
#     a `failed-run-<…>` is
#     actioned once its id is absent from this cycle's own gather for that
#     source, and that gather succeeded (`void_liveness_actioned`,
#     lib/void-liveness.sh) — read off the same tee files the repo loop
#     already wrote for the first four, and one further
#     `gather_workflow_basenames` call per repo with still-unretired
#     `failed-run-` void ids for the fifth; and
#   - a merged pull request, for a project-review ref, or a checked task-list
#     box, for an implementation-plan task id — the same on-demand readers
#     34i already calls for the blocked set (`gather_review_status`,
#     `gather_plan_status`), read here for the void residue
#     (`void_review_plan_actioned`, lib/void-liveness.sh); and
#   - the configuration itself, for the residue none of the four above can
#     reach (`void_config_actioned`, lib/void-liveness.sh; PR #340 review):
#     liveness needs the source's own successful gather, and a source is
#     gathered only for a repo whose `sources` still list it, so a repo that
#     drops `merge-conflicts` — or `security`, or `register-hygiene` — freezes
#     every void of that shape it had already minted, and a repo dropped from
#     the config altogether freezes every shape but the closed-object one.
#     Both are read straight off `all_repos_json`, which costs nothing and is
#     deliberately the *unnarrowed* array: `repos_json` carries `--repo`'s
#     filter, under which every other repo would read as dropped, and
#     `ordered_repos_json`'s own `sources` are rewritten by back-pressure
#     (step 2.2a, further down) to the four finishing sources.
#
# Age-only retirement for the six liveness shapes was considered and
# rejected: a void whose id is *still being gathered* — a still-open alert, a
# register-hygiene finding the register still has, a workflow still failing, a
# PR still conflicted — is doing live suppression work every cycle, and
# retiring it on age alone would re-expose the item to be rediscovered void
# all over again, the exact rediscovery churn requirement 34k exists to stop.
# That objection does not reach the config signal: it needs the item to be
# re-offered, which needs a human to re-add the source or the repo, at which
# point one rediscovery pass is the correct behaviour of a newly-enabled
# source and is bounded by what is still live at that moment.
# A void naming no repo (the hand-appended form requirement 34c allows) never
# matches any of these six signals, so it is left, as it always was, for a
# human to retract.
#
# Each entry this block retires is recorded as a `void-retired` event —
# `{repo, item, void_ts, by}`, a fact rather than a state exactly as
# `void-object-closed` is (requirement 34k) — which is what makes the
# decision durable: the subtraction where `void_json` is first computed reads
# those events back, so a settled id is never re-evidenced or re-decided, and
# the register read here stays proportional to the unretired residue instead
# of growing by one id per void ever retired. The recording is skipped on
# --dry-run, like the 34k sweep itself — it is a durable mark on the log —
# while the in-memory narrowing still applies, so a dry run sees the extract
# a real one would.
#
# All of it is behind the `> 0` gate, because the register read is the whole
# cost of this requirement and `void_retire_after_days` of `0` disables the
# requirement: an installation that has switched retirement off must not go
# on paying for the evidence retirement would have needed.
if (( void_retire_after_days > 0 )); then
  void_register_status_json='{}'
  while IFS=$'\t' read -r vrs_slug vrs_ids; do
    [[ -n "$vrs_slug" && -n "$vrs_ids" ]] || continue
    vrs_branch="$(jq -r --arg s "$vrs_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
      <<<"$ordered_repos_json" 2>/dev/null || true)"
    [[ -n "$vrs_branch" ]] || continue
    # shellcheck disable=SC2086  # $vrs_ids is a deliberate word-split id list.
    vrs_map="$(gather_register_status "$vrs_slug" "$vrs_branch" void $vrs_ids)"
    void_register_status_json="$(jq -c --arg s "$vrs_slug" --argjson m "$vrs_map" '. + {($s): $m}' \
      <<<"$void_register_status_json" 2>/dev/null || printf '%s' "$void_register_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
  done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
           <<<"$void_register_ids_json" 2>/dev/null || true)

  # The project-review and implementation-plan residue (TD-PPagop-26081303):
  # requirement 34i's own on-demand readers, over the void set's still-
  # unretired ids of those two shapes — same cost shape as the register read
  # above, `purpose void` so the diagnostic files don't collide with 34i's own
  # blocked-set read of the same repo.
  #
  # This repo's own resolved report_directory (its override in
  # project_review.repos, or project_review.defaults' otherwise, requirement
  # 342) — or, absent from project_review entirely, the same ultimate
  # fallback review-cycle.sh itself falls back to (issue #761). Computed once,
  # outside the loop, the same way lib/eligibility.sh's own
  # `refiner_project_review_repos_json` is: every repository's resolved value
  # is a lookup against this, not a fresh derivation.
  void_review_current_repos_json="$(config_project_review_repos "$DEFAULTED_CONFIG")"
  void_review_status_json='{}'
  void_review_current_json='{}'
  while IFS=$'\t' read -r vrv_slug vrv_refs; do
    [[ -n "$vrv_slug" && -n "$vrv_refs" ]] || continue
    vrv_branch="$(jq -r --arg s "$vrv_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
      <<<"$ordered_repos_json" 2>/dev/null || true)"
    [[ -n "$vrv_branch" ]] || continue
    # shellcheck disable=SC2086  # $vrv_refs is a deliberate word-split ref list.
    vrv_map="$(gather_review_status "$vrv_slug" "$vrv_branch" void $vrv_refs)"
    void_review_status_json="$(jq -c --arg s "$vrv_slug" --argjson m "$vrv_map" '. + {($s): $m}' \
      <<<"$void_review_status_json" 2>/dev/null || printf '%s' "$void_review_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
    # The review-superseded signal (TD-PPagop-26082309): one `--current-date`
    # call per repo already walked above, so this residue pays no `gh` call
    # a repo with none of it would not have paid anyway. An `ok: false` read
    # contributes no entry — a repo absent from void_review_current_json
    # decides nothing, same "unknown is not gone" rule as every other
    # liveness shape.
    vrv_report_directory="$(jq -r --arg s "$vrv_slug" \
      'map(select(.slug == $s)) | .[0].report_directory // ""' \
      <<<"$void_review_current_repos_json" 2>/dev/null || true)"
    [[ -n "$vrv_report_directory" ]] || vrv_report_directory="$REPORT_DIRECTORY_DEFAULT"
    vrv_current="$(gather_review_current "$vrv_slug" "$vrv_branch" "$vrv_report_directory")"
    if [[ "$(jq -r '.ok // false' <<<"$vrv_current" 2>/dev/null || true)" == "true" ]]; then
      vrv_date="$(jq -r '.date // ""' <<<"$vrv_current" 2>/dev/null || true)"
      void_review_current_json="$(jq -c --arg s "$vrv_slug" --arg d "$vrv_date" '. + {($s): $d}' \
        <<<"$void_review_current_json" 2>/dev/null || printf '%s' "$void_review_current_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
    fi
  done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
           <<<"$(work_gone_review_refs "$void_json")" 2>/dev/null || true)

  void_plan_status_json='{}'
  while IFS=$'\t' read -r vrp_slug vrp_ids; do
    [[ -n "$vrp_slug" && -n "$vrp_ids" ]] || continue
    vrp_entry="$(jq -c --arg s "$vrp_slug" 'map(select(.slug == $s)) | .[0] // {}' \
      <<<"$ordered_repos_json" 2>&1)" || { guard_warn "void:vrp_entry" "$vrp_entry"; vrp_entry='{}'; }
    vrp_branch="$(jq -r '.default_branch // ""' <<<"$vrp_entry" 2>/dev/null || true)"
    vrp_path="$(jq -r '.implementation_plan_path // ""' <<<"$vrp_entry" 2>/dev/null || true)"
    [[ -n "$vrp_branch" && -n "$vrp_path" ]] || continue
    # shellcheck disable=SC2086  # $vrp_ids is a deliberate word-split id list.
    vrp_map="$(gather_plan_status "$vrp_slug" "$vrp_branch" "$vrp_path" void $vrp_ids)"
    void_plan_status_json="$(jq -c --arg s "$vrp_slug" --argjson m "$vrp_map" '. + {($s): $m}' \
      <<<"$void_plan_status_json" 2>/dev/null || printf '%s' "$void_plan_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
  done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
           <<<"$(work_gone_plan_ids "$void_json")" 2>/dev/null || true)

  # The six liveness shapes (TD-PPagop-26081303, extended by TD-PPagop-26081409
  # for `dequeued` and by agent-ops#646 for `human-visibility`): per repo,
  # whatever gather_findings/gather_register_hygiene/gather_merge_conflicts/
  # gather_dequeued/gather_human_visibility_hygiene
  # already wrote to the cycle dir during the repo loop — the `.ok` marker
  # (this cycle's own read of that source succeeded) and the ids it currently
  # yields — read straight off those tee files, so alert/register-hygiene/
  # merge-conflict/dequeued/human-visibility liveness costs no further `gh`
  # call at all.
  # `failed-run` is the one exception: gather-source-state.sh's own `workflows`
  # digest names
  # each still-failing workflow by id, not by the basename the item id is
  # minted from, so the id -> basename map is fetched here, bounded to the
  # repos that actually carry unretired `failed-run-` void residue (usually
  # none).
  void_failed_run_repos_json="$(jq -r --arg re "$VOID_LIVENESS_FAILED_RUN_RE" '
    [ .[] | select((.repo // "") != "" and ((.item // "") | test($re))) | .repo ] | unique' \
    <<<"$void_json" 2>&1)" \
    || { guard_warn "void_failed_run_repos_json" "$void_failed_run_repos_json"; void_failed_run_repos_json='[]'; }

  void_liveness_gather_json='{}'
  while IFS= read -r vl_slug; do
    [[ -n "$vl_slug" ]] || continue
    vl_safe="${vl_slug//\//_}"

    vl_alert_ok=false; vl_alert_ids='[]'
    if [[ -f "$cycle_dir/findings-$vl_safe.ok" ]]; then
      vl_alert_ok=true
      vl_alert_ids="$(jq -c '[.[].ref]' "$cycle_dir/findings-$vl_safe.json" 2>&1)" \
        || { guard_warn "void-liveness:vl_alert_ids:$vl_safe" "$vl_alert_ids"; vl_alert_ids='[]'; }
    fi

    # The `prefetch` pass's own files, never requirement 34l's `void` pass:
    # that second pass folds the void evidence in (so its array answers a
    # different question) and can fail where the first succeeded, which is
    # why the two carry separate `purpose` prefixes at all.
    vl_rh_ok=false; vl_rh_ids='[]'
    if [[ -f "$cycle_dir/register-hygiene-prefetch-$vl_safe.ok" ]]; then
      vl_rh_ok=true
      vl_rh_ids="$(jq -c '[.[].ref]' "$cycle_dir/register-hygiene-prefetch-$vl_safe.json" 2>&1)" \
        || { guard_warn "void-liveness:vl_rh_ids:$vl_safe" "$vl_rh_ids"; vl_rh_ids='[]'; }
    fi

    vl_mc_ok=false; vl_mc_ids='[]'
    if [[ -f "$cycle_dir/merge-conflicts-$vl_safe.ok" ]]; then
      vl_mc_ok=true
      vl_mc_ids="$(jq -c '[.[].ref]' "$cycle_dir/merge-conflicts-$vl_safe.json" 2>&1)" \
        || { guard_warn "void-liveness:vl_mc_ids:$vl_safe" "$vl_mc_ids"; vl_mc_ids='[]'; }
    fi

    vl_dq_ok=false; vl_dq_ids='[]'
    if [[ -f "$cycle_dir/dequeued-$vl_safe.ok" ]]; then
      vl_dq_ok=true
      vl_dq_ids="$(jq -c '[.[].ref]' "$cycle_dir/dequeued-$vl_safe.json" 2>/dev/null || echo '[]')"
    fi

    # The human-visibility gather's own tee (agent-ops#646). Its array is the
    # candidate objects, so the ids come from `.ref` exactly as the four
    # shapes above take theirs; the walk that writes it is widened, further
    # up, to cover a repo carrying this shape's void residue but no live
    # violation, which is the case that otherwise never produces a marker.
    vl_hv_ok=false; vl_hv_ids='[]'
    if [[ -f "$cycle_dir/human-visibility-hygiene-$vl_safe.ok" ]]; then
      vl_hv_ok=true
      vl_hv_ids="$(jq -c '[.[].ref]' "$cycle_dir/human-visibility-hygiene-$vl_safe.json" 2>&1)" \
        || { guard_warn "void-liveness:vl_hv_ids:$vl_safe" "$vl_hv_ids"; vl_hv_ids='[]'; }
    fi

    vl_fr_ok=false; vl_fr_ids='[]'
    if jq -e --arg r "$vl_slug" 'index($r) != null' <<<"$void_failed_run_repos_json" >/dev/null 2>&1; then
      vl_basenames_json="$(gather_workflow_basenames "$vl_slug")"
      if [[ "$(jq -r '.ok // false' <<<"$vl_basenames_json" 2>/dev/null)" == "true" ]]; then
        vl_state_json="$(jq -c --arg s "$vl_slug" \
          '[.[] | select((.slug // "") == $s and .ok == true)] | first // {}' \
          <<<"$source_states_json" 2>&1)" \
          || { guard_warn "void-liveness:vl_state_json" "$vl_state_json"; vl_state_json='{}'; }
        if [[ "$(jq -r 'has("slug")' <<<"$vl_state_json" 2>/dev/null)" == "true" ]]; then
          vl_fr_ok=true
          vl_fr_ids="$(jq -c --argjson bn "$vl_basenames_json" '
            [ (.workflows // [])[] | select(.c == "failure") | (.w | tostring) as $id
              | ($bn.basenames[$id] // null) | select(. != null) | ("failed-run-" + .) ]' \
            <<<"$vl_state_json" 2>&1)" \
            || { guard_warn "void-liveness:vl_fr_ids" "$vl_fr_ids"; vl_fr_ids='[]'; }
        fi
      fi
    fi

    void_liveness_gather_json="$(jq -c --arg s "$vl_slug" \
      --argjson alert_ok "$vl_alert_ok" --argjson alert_ids "$vl_alert_ids" \
      --argjson rh_ok "$vl_rh_ok" --argjson rh_ids "$vl_rh_ids" \
      --argjson mc_ok "$vl_mc_ok" --argjson mc_ids "$vl_mc_ids" \
      --argjson dq_ok "$vl_dq_ok" --argjson dq_ids "$vl_dq_ids" \
      --argjson hv_ok "$vl_hv_ok" --argjson hv_ids "$vl_hv_ids" \
      --argjson fr_ok "$vl_fr_ok" --argjson fr_ids "$vl_fr_ids" \
      '. + {($s): {alert: {ok: $alert_ok, ids: $alert_ids},
                   "register-hygiene": {ok: $rh_ok, ids: $rh_ids},
                   "merge-conflict": {ok: $mc_ok, ids: $mc_ids},
                   "dequeued": {ok: $dq_ok, ids: $dq_ids},
                   "human-visibility": {ok: $hv_ok, ids: $hv_ids},
                   "failed-run": {ok: $fr_ok, ids: $fr_ids}}}' \
      <<<"$void_liveness_gather_json" 2>/dev/null || printf '%s' "$void_liveness_gather_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
  done < <(jq -r '.[].slug' <<<"$ordered_repos_json" 2>/dev/null || true)

  # The closed set grows with every void ever actioned, so it arrives on
  # stdin, never in argv (requirement 4g), and is intersected with the
  # extract's own pairs before it travels any further: retirement can only
  # drop what is in the extract, so the intersection loses nothing and is
  # what keeps `void_actioned_json` — which does ride an --argjson below —
  # bounded by the unretired residue rather than by history. `by` names the
  # actioned signal, for the `void-retired` event to carry. The liveness,
  # review/plan and config pairs are already bounded the same way — each is
  # computed straight from `void_json`'s own residue, never from history, and
  # each entry is three short fields whatever the entry it was derived from.
  # shellcheck disable=SC2016  # jq's $void/$closed/$reg et al., not the shell's.
  void_actioned_json="$(jq -c -n --argjson reg "$void_register_status_json" \
    --argjson liveness "$(void_liveness_actioned "$void_json" "$void_liveness_gather_json")" \
    --argjson revplan "$(void_review_plan_actioned "$void_json" "$void_review_status_json" "$void_plan_status_json" "$void_review_current_json")" \
    --argjson config "$(void_config_actioned "$void_json" "$all_repos_json")" '
    input as $void | input as $closed
    | ($void | map((.repo // "") + "|" + (.item // ""))) as $pairs
    | ($closed
       | map(select((.repo + "|" + .item) as $k | ($pairs | index($k)) != null)
             | {repo, item, by: "object-closed"})) as $closed_here
    | ($reg | to_entries | map(.key as $repo | .value | to_entries[]
       | select((.value | ascii_downcase) == "resolved" or (.value | ascii_downcase) == "not-debt")
       | {repo: $repo, item: .key, by: "register-resolved"})) as $reg_done
    | $closed_here + $reg_done + $liveness + $revplan + $config' \
    <<<"$void_json"$'\n'"$(void_object_closed_items "$union_log")" 2>&1)" \
    || { guard_warn "void_actioned_json:closed-merge" "$void_actioned_json"; void_actioned_json='[]'; }

  void_json_before_retire="$void_json"
  void_json="$(retire_void_items "$void_json" "$void_actioned_json" "$void_retire_after_days" "$now_epoch")"

  if ! (( DRY_RUN )); then
    # Both extracts on stdin (requirement 4g); a retire_void_items failure
    # returns its input verbatim, so before == after and nothing is recorded.
    # shellcheck disable=SC2016  # jq's $before/$after/$actioned et al.
    void_retired_now_json="$(jq -c -n --argjson actioned "$void_actioned_json" '
      input as $before | input as $after
      | ($after | map((.repo // "") + "|" + (.item // ""))) as $kept
      | [ $before[]
          | ((.repo // "") + "|" + (.item // "")) as $k
          | select(($kept | index($k)) == null)
          | {repo, item, void_ts: .ts,
             by: (($actioned | map(select(((.repo // "") + "|" + (.item // "")) == $k))
                   | first | .by) // "actioned")} ]' \
      <<<"$void_json_before_retire"$'\n'"$void_json" 2>&1)" \
      || { guard_warn "void_retired_now_json" "$void_retired_now_json"; void_retired_now_json='[]'; }
    while IFS= read -r void_retired_entry; do
      [[ -n "$void_retired_entry" ]] || continue
      log_event "void-retired" "$void_retired_entry"
    done < <(jq -c '.[]' <<<"$void_retired_now_json" 2>/dev/null || true)
  fi
fi

# Defence in depth alongside requirement 4g's stdin-only delivery (which is
# what actually stops this reaching `MAX_ARG_STRLEN` again — retirement bounds
# the steady state, not any one cycle's worst case): a `warning`, well under
# the 131072-byte cap, if the extract stays large enough after retirement to
# be worth a human's attention.
void_json_bytes="$(printf '%s' "$void_json" | wc -c)"
if (( void_json_bytes > 100000 )); then
  log_event "warning" "$(jq -nc \
    --argjson n "$(v="$(jq 'length' <<<"$void_json" 2>&1)" || { guard_warn "void_json_bytes:n" "$v"; v=0; }; printf '%s' "$v")" --argjson b "$void_json_bytes" \
    '{detail: ("void extract is " + ($b | tostring) + " bytes across " + ($n | tostring)
               + " entries after retirement — approaching the 131072-byte MAX_ARG_STRLEN cap; check void_retire_after_days and whether requirements 34k/34l are actioning items")}')"
fi

}
