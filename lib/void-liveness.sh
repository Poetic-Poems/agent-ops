#!/usr/bin/env bash
#
# lib/void-liveness.sh — the actioned signal for the void shapes requirement
# 34n's original two rules (a closed GitHub object, a resolved register row)
# never covered (TD-PPagop-26081303).
#
# Requirement 34n retires a void entry once it is both actioned and old, but
# "actioned" was only ever defined for the two shapes requirements 34k and 34l
# already act on. Every other shape a cycle can void —
# `dependabot-alert-<n>`/`code-scanning-alert-<n>`, `register-hygiene-<hash>`,
# `failed-run-<workflow>`, and `pr-<n>-conflict-<head-sha>` (later joined by
# its sibling shape `pr-<n>-superseded-<head-sha>`, TD-PPagop-26081304, by
# `pr-<n>-dequeued-<head-sha>`, TD-PPagop-26081409, and by
# `human-visibility-<hash>`, agent-ops#646) — had
# no actioned signal at all, so a void of one of those shapes never retired and
# the extract kept the same unbounded growth curve requirement 34n exists to
# stop, underneath the part it does bound.
#
# The decided direction (TD-PPagop-26081303, filed against PR #311's review):
# age-only retirement is rejected, because a void whose id is *still being
# gathered* — a still-open alert, a register-hygiene finding the register
# still has, a workflow still failing, a PR still conflicted or dequeued — is
# doing live suppression work every cycle, and retiring it on age alone
# re-exposes the item to be rediscovered void all over again (the exact churn
# requirement 34k exists to stop). The actioned analogue these six shapes
# have is liveness:
# the source that mints the id no longer yields it, this cycle, and the
# source's own gather succeeded — "unknown is not gone" (requirement 34i)
# applies here exactly as it does to the blocked set.
#
# Two other shapes a cycle can void — a project-review ref
# (`review-<date>-R-NN`) and an implementation-plan task id — are not
# pre-fetched as structured data at all; for those, requirement 34i's existing
# on-demand readers (`scripts/gather-review-status.sh`,
# `scripts/gather-plan-status.sh`) are the actioned signal, read for the void
# residue the same way they already are for the blocked one.
#
# A third rule sits alongside those two, for the residue neither can reach
# (PR #340 review, decided 2026-08-13): liveness decides nothing without the
# source's own successful gather, and a source is only gathered for a repo
# whose configured `sources` still list it — so a repo that drops
# `merge-conflicts` (or `security`, or `register-hygiene`) freezes every void
# of that shape it had already accumulated, and a repo dropped from the config
# altogether freezes every shape but the closed-object one. `void_config_
# actioned` reads that config fact directly. It is not a weakening of
# "unknown is not gone": that rule is about a *failed read*, which is
# indistinguishable from absence, whereas a source missing from `sources` is a
# definite fact the cycle reads locally for free — the pipeline is not
# uncertain whether the alert is still open, it has decided it will not look.
# What a void buys is suppression of a candidate the Co-Ordinator would
# otherwise be offered; an ungathered source offers nothing, so the void buys
# nothing and retiring it costs nothing.
#
# A void naming no repo at all (the hand-appended form requirement 34c allows)
# matches none of these shapes by construction — a repo-scoped GATHER_JSON
# lookup on an empty repo key finds nothing, and the config rule below skips it
# explicitly — so it is left, as it always was, for a human to retract.
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail`.

# The id shapes this file can decide, kept in one place for the same reason
# lib/work-gone.sh's own regexes are (requirement 34a): the classifier below
# and the Script, which asks each side-channel only about ids that could
# possibly be its shape, both need them to agree.
#
# The alert refs are minted by scripts/gather-findings.sh ("dependabot-alert-"
# / "code-scanning-alert-" + the alert number).
VOID_LIVENESS_ALERT_RE='^(dependabot|code-scanning)-alert-[0-9]+$'

# scripts/gather-register-hygiene.sh's own ref: `register-hygiene-` plus a
# 12-hex-character digest of the register's tree and policy blob SHAs.
VOID_LIVENESS_REGISTER_HYGIENE_RE='^register-hygiene-[0-9a-f]{12}$'

# scripts/gather-human-visibility-hygiene.sh's own ref (agent-ops#646):
# `human-visibility-` plus a 12-hex-character sha256 of the surviving
# violations' own `pr_url|detail` pairs. The same digest-over-a-set shape as
# the register-hygiene ref above, and it retires the same way, but note what
# makes an id absent here: the digest is scoped to *this* violation set, so a
# set that has merely changed mints a different ref rather than dropping this
# one, and the void of the old ref is dead weight from that moment on. That is
# the same reasoning the register-hygiene shape rests on — neither ref is ever
# re-offered once its set has moved — and it is why the absent-from-the-gather
# test is sound for both despite the ref never repeating.
VOID_LIVENESS_HUMAN_VISIBILITY_RE='^human-visibility-[0-9a-f]{12}$'

# Requirement 19's `failed-runs` item id: `failed-run-` plus the workflow
# file's basename, without extension — free-form beyond that (a workflow
# filename may carry dots, underscores or hyphens).
VOID_LIVENESS_FAILED_RUN_RE='^failed-run-.+$'

# scripts/gather-merge-conflicts.sh's own two ref shapes, both scoped to a
# head SHA's leading 12 hex characters (`${head_sha:0:12}`): `pr-<n>-conflict-`,
# the shape requirement 34k deliberately excludes from its close (the addendum
# to TD-PPagop-26081303), and `pr-<n>-superseded-`, the shape a Dependabot
# supersession (requirement 3s) mints instead and that 34k *does* close
# (TD-PPagop-26081304). Both retire from the void extract the same way — this
# file's own absent-from-this-cycle's-gather test — and the superseded shape
# additionally earns a `void-object-closed` once 34k closes its pull request;
# the two signals coincide (a closed pull request also leaves the gather), so
# sharing one regex here is redundant-but-safe rather than a competing rule.
VOID_LIVENESS_MERGE_CONFLICT_RE='^pr-[0-9]+-(conflict|superseded)-[0-9a-f]{6,40}$'

# scripts/gather-dequeued.sh's own ref shape (TD-PPagop-26081409), scoped to
# a head SHA the same way: `pr-<n>-dequeued-<head-sha>`. It retires from the
# void extract by the same absent-from-this-cycle's-gather test the
# merge-conflict shapes use, since that script's candidate rule is re-read live
# each cycle — but note *what* makes it absent, which differs from the shapes
# above. A re-queue, a merge, a close or a draft ends the pull request's
# candidacy outright; the Implementer's own fix push does not, and is caught
# instead by that script's answered clause (its "Why the dequeue must still be
# unanswered" section). A push alone merely replaces this ref with one at the
# new head, which is why the clause and not the scoping is what stops the entry
# reappearing for ever.
VOID_LIVENESS_DEQUEUED_RE='^pr-[0-9]+-dequeued-[0-9a-f]{6,40}$'

# void_liveness_actioned VOID_JSON GATHER_JSON
# Print, as a JSON array of `{repo, item, by}`, the pairs from VOID_JSON that
# requirement 34n's liveness rule counts as actioned: an entry whose item
# matches one of the six shapes above, whose repo carries a GATHER_JSON entry
# for that shape with `ok: true`, and whose item is absent from that shape's
# `ids`.
#
# GATHER_JSON is keyed repo -> shape -> `{ok, ids}`, shape one of "alert",
# "register-hygiene", "failed-run", "merge-conflict", "dequeued",
# "human-visibility":
#
#   {"owner/repo": {"alert": {"ok": true, "ids": ["dependabot-alert-3"]},
#                    "register-hygiene": {"ok": true, "ids": []},
#                    "failed-run": {"ok": false, "ids": []},
#                    "merge-conflict": {"ok": true, "ids": ["pr-9-conflict-1a2b3c4d5e6f"]},
#                    "dequeued": {"ok": true, "ids": []},
#                    "human-visibility": {"ok": true, "ids": []}}}
#
# `ids` is this cycle's own gather for that repo+shape — the same array (or
# the same source) the Co-Ordinator itself was handed, before any claim
# exclusion narrows it: a claimed alert is still an open one, and narrowing by
# claim status here would retire a void whose object never actually closed.
# `ok` is whether that gather succeeded this cycle; `false` (or the repo+shape
# entry being absent entirely) decides nothing, the same "unknown is not gone"
# rule requirement 34i's own clearances observe — an item present in
# GATHER_JSON with `ok: false` is exactly as undecided as a repo missing from
# it altogether.
#
# The caller builds GATHER_JSON however it can afford to; this function reads
# it and nothing else, so it needs no network access and stays a pure,
# testable transform over state the caller already holds.
#
# Both VOID_JSON and GATHER_JSON travel on stdin, never in argv (requirement
# 4g): VOID_JSON is the unbounded extract itself. Fails safe to `[]` on any
# malformed input — the same "never retiring is the safe direction" rule
# `retire_void_items` already observes for the age half of this decision.
# shellcheck disable=SC2016  # jq's $void/$gather/$e/$shape, not the shell's.
void_liveness_actioned() {
  local void_json="${1:-[]}" gather_json="${2:-{\}}" out=""
  out="$(jq -c -n \
    --arg alert_re "$VOID_LIVENESS_ALERT_RE" \
    --arg rh_re "$VOID_LIVENESS_REGISTER_HYGIENE_RE" \
    --arg fr_re "$VOID_LIVENESS_FAILED_RUN_RE" \
    --arg mc_re "$VOID_LIVENESS_MERGE_CONFLICT_RE" \
    --arg dq_re "$VOID_LIVENESS_DEQUEUED_RE" \
    --arg hv_re "$VOID_LIVENESS_HUMAN_VISIBILITY_RE" '
    input as $void | input as $gather
    | def shape_of($item):
        if ($item | test($alert_re)) then "alert"
        elif ($item | test($rh_re)) then "register-hygiene"
        elif ($item | test($fr_re)) then "failed-run"
        elif ($item | test($mc_re)) then "merge-conflict"
        elif ($item | test($dq_re)) then "dequeued"
        elif ($item | test($hv_re)) then "human-visibility"
        else null end;
    [ $void[]
      | . as $e
      | ($e.repo // "") as $repo
      | ($e.item // "") as $item
      | select($repo != "" and $item != "")
      | shape_of($item) as $shape
      | select($shape != null)
      | (($gather[$repo][$shape]) // null) as $g
      | select($g != null and ($g.ok // false) == true)
      | select((($g.ids // []) | index($item)) == null)
      | {repo: $repo, item: $item, by: ("liveness-" + $shape)} ]
  ' <<<"$void_json"$'\n'"$gather_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# void_review_plan_actioned VOID_JSON REVIEW_STATUS_JSON PLAN_STATUS_JSON
# Print, as a JSON array of `{repo, item, by}`, the actioned pairs for the two
# shapes requirement 34n's direction assigns the *existing* on-demand readers
# rather than a fresh liveness rule: a project-review ref backed by a merged
# pull request, and an implementation-plan task id backed by a checked
# checkbox.
#
# REVIEW_STATUS_JSON and PLAN_STATUS_JSON are the same shape
# `scripts/gather-review-status.sh` / `scripts/gather-plan-status.sh` already
# print — repo -> ref/id -> `"merged"`/`"done"` (or anything else, which
# decides nothing) — read here for the void residue exactly as
# `lib/work-gone.sh`'s `work_gone_clearances` already reads them for the
# blocked one. The shape regexes are `lib/work-gone.sh`'s own
# (`WORK_GONE_REVIEW_RE`, `WORK_GONE_PLAN_RE`) — one definition, per
# requirement 34a — so a caller must source that file first.
#
# All three inputs travel on stdin, never in argv (requirement 4g): VOID_JSON
# is unbounded. Fails safe to `[]` on any malformed input.
#
# Known gap, tech-debt/TD-PPagop-26082309.md: the review half can only ever
# answer for a ref some merged pull request *names*, and a voided review ref
# is voided precisely because the work landed under a commit that named no
# ref — so this signal is defined for the population that never gets voided,
# and every such entry stays in the extract for ever.
# shellcheck disable=SC2016  # jq's $void/$review/$plan/$e, not the shell's.
void_review_plan_actioned() {
  local void_json="${1:-[]}" review_json="${2:-{\}}" plan_json="${3:-{\}}" out=""
  out="$(jq -c -n \
    --arg review_re "$WORK_GONE_REVIEW_RE" --arg plan_re "$WORK_GONE_PLAN_RE" '
    input as $void | input as $review | input as $plan
    | [ $void[]
        | . as $e
        | ($e.repo // "") as $repo
        | ($e.item // "") as $item
        | select($repo != "" and $item != "")
        | if ($item | test($review_re)) then
            ((($review[$repo] // {})[$item] // "" | ascii_downcase) as $status
             | select($status == "merged")
             | {repo: $repo, item: $item, by: "review-merged"})
          elif ($item | test($plan_re)) then
            ((($plan[$repo] // {})[$item] // "" | ascii_downcase) as $status
             | select($status == "done")
             | {repo: $repo, item: $item, by: "plan-task-done"})
          else empty
          end ]
  ' <<<"$void_json"$'\n'"$review_json"$'\n'"$plan_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# void_config_actioned VOID_JSON REPOS_JSON
# Print, as a JSON array of `{repo, item, by}`, the pairs the configuration
# itself retires, for the residue the two rules above cannot reach: an entry
# whose repo the config no longer names at all (`by: "repo-dropped"`), or
# whose item is shaped like a source's own id and whose repo no longer lists
# that source (`by: "source-dropped"`).
#
# REPOS_JSON is the configured repo array — `[{slug, sources: […]}, …]` — and
# it must be the **unnarrowed** one (`all_repos_json`, straight off
# `cfg_json '.repos'`). Two things narrow that array later in a cycle and
# neither means what this rule reads it as: `--repo`'s own filter, which
# would make every other repo read as dropped, and back-pressure, which
# rewrites `sources` down to the four finishing sources for a repo with work
# waiting and would mint a spurious `source-dropped` for `security` and
# `register-hygiene` on every back-pressured cycle.
#
# The shape -> source map is the inverse of the repo walk's own gating: each
# shape is minted by exactly one gather, and that gather runs only for a repo
# whose `sources` list the entry named here. The alert shape is the one with
# two, because `scripts/gather-findings.sh` serves `security` and
# `code-quality` together — either alone keeps its voids live.
#
# Deliberately scoped to the shapes whose id *form* names the source that
# mints them. A bare issue number or a `pr-<n>-…` shaped neither `-conflict-`
# nor `-superseded-` is offered by several sources (`issues:<band>`,
# `review-feedback`, `abandoned-drafts`), so no such
# inverse exists and no `source-dropped` verdict can be read off the id —
# those keep the closed-object signal they already had. `human-visibility` is
# not among them, though it was named here until agent-ops#646: it mints
# exactly one id shape, its own `human-visibility-<hash>` ref (the `hv_cands`
# arm of agent-cycle.sh's candidate build passes `.ref` through, never a pull
# request number), so the inverse is as well defined for it as for the five
# above and the shape belongs in the map. The `repo-dropped`
# half needs no map at all and so applies to
# every shape: nothing in a repo the config does not name can be offered by
# any source.
#
# Fails safe to `[]`: on malformed input, and — the case worth naming — on a
# REPOS_JSON that is empty or not an array, which would otherwise read as
# "every repo has been dropped" and retire the whole extract at once.
#
# Both inputs travel on stdin, never in argv (requirement 4g): VOID_JSON is
# the unbounded extract. The review/register/plan shape regexes are
# `lib/work-gone.sh`'s own (requirement 34a's one-definition rule), so a
# caller must source that file first.
# shellcheck disable=SC2016  # jq's $void/$repos/$cfg/$e et al., not the shell's.
void_config_actioned() {
  local void_json="${1:-[]}" repos_json="${2:-[]}" out=""
  out="$(jq -c -n \
    --arg alert_re "$VOID_LIVENESS_ALERT_RE" \
    --arg rh_re "$VOID_LIVENESS_REGISTER_HYGIENE_RE" \
    --arg fr_re "$VOID_LIVENESS_FAILED_RUN_RE" \
    --arg mc_re "$VOID_LIVENESS_MERGE_CONFLICT_RE" \
    --arg dq_re "$VOID_LIVENESS_DEQUEUED_RE" \
    --arg hv_re "$VOID_LIVENESS_HUMAN_VISIBILITY_RE" \
    --arg review_re "$WORK_GONE_REVIEW_RE" \
    --arg register_re "$WORK_GONE_REGISTER_RE" \
    --arg plan_re "$WORK_GONE_PLAN_RE" '
    input as $void | input as $repos
    | def minted_by($item):
        if ($item | test($alert_re)) then ["security", "code-quality"]
        elif ($item | test($rh_re)) then ["register-hygiene"]
        elif ($item | test($fr_re)) then ["failed-runs"]
        elif ($item | test($mc_re)) then ["merge-conflicts"]
        elif ($item | test($dq_re)) then ["dequeued"]
        elif ($item | test($hv_re)) then ["human-visibility"]
        elif ($item | test($review_re)) then ["project-review"]
        elif ($item | test($register_re)) then ["tech-debt"]
        elif ($item | test($plan_re)) then ["implementation-plan"]
        else null end;
      ( if ($repos | type) == "array"
        then [ $repos[] | select((type == "object") and ((.slug // "") != "")) ]
        else [] end ) as $cfg
    | if ($cfg | length) == 0 then []
      else
        ($cfg | map({key: .slug, value: [ (.sources // [])[] | tostring ]})
              | from_entries) as $by_repo
        | [ $void[]
            | . as $e
            | ($e.repo // "") as $repo
            | ($e.item // "") as $item
            | select($repo != "" and $item != "")
            | if ($by_repo | has($repo) | not) then
                {repo: $repo, item: $item, by: "repo-dropped"}
              else
                ($by_repo[$repo]) as $srcs
                | minted_by($item) as $need
                | select($need != null)
                | select((($need - $srcs) | length) == ($need | length))
                | {repo: $repo, item: $item, by: "source-dropped"}
              end ]
      end
  ' <<<"$void_json"$'\n'"$repos_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}
