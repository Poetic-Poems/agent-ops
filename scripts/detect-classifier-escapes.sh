#!/usr/bin/env bash
#
# scripts/detect-classifier-escapes.sh — independent post-hoc classifier-
# escape detector (D18 Stage 2 exit criterion "zero classifier escapes",
# agent-ops#572).
#
# `lib/landing.sh`'s `landing_eligible` is the *decision*: given a pull
# request's complexity, source and the effective `merge_autonomy` level,
# does it qualify for automatic landing? Nothing independently re-checks the
# *outcome* — that every pull request which actually landed autonomously was
# in fact eligible. This script is that check, and by design it never calls
# `landing_eligible`, and never sources `lib/landing.sh` at all: the
# protected-path list and the "did this land under the Approver identity"
# test below are each reimplemented from scratch, deliberately, per the
# issue's own Refiner comment ("`landing_protected_paths` and the
# Approver-identity check already exist in lib/landing.sh — read there for
# the exact logic this detector must reproduce independently (not call
# into)"). An audit that shared the code it exists to check could not catch
# a bug in that shared code — both the classifier and its own auditor would
# agree, and agreement is exactly what a classifier escape looks like from
# the inside. `test/detect-classifier-escapes.test.sh` pins the reimplemented
# protected-path list identical to `lib/landing.sh`'s own, so the two cannot
# drift apart unnoticed even though neither sources the other.
#
# ## What counts as "landed under the Approver identity"
#
# Not "carries `pr_label`", and not "has a `landing-armed` event in the fleet
# log" — trusting the pipeline's own event log to say which pull requests it
# landed would make the audit circular, exactly the thing it exists to avoid
# (a bug that caused `agent-cycle.sh` to log `landing-armed` without actually
# arming, or against the wrong pull request, would then audit nothing wrong).
# Instead: every merged, `pr_label`-carrying pull request in SLUG whose own
# `merged_by.login` (GitHub's live record, `gh api repos/SLUG/pulls/N`) is
# APPROVER_LOGIN. `landing_arm` (lib/landing.sh) always writes under the
# Approver App's minted token, never a human's, so this is the fact of an
# autonomous landing exactly as GitHub itself recorded it — independent of
# whether this pipeline's own log agrees.
#
# ## What is recomputed, and from what
#
#   - **Protected-path hit** — from the *merge commit's own file list*
#     (`gh api repos/SLUG/commits/SHA`), never the pull request's changed-file
#     endpoint `landing_protected_paths_hit` reads: a different GitHub
#     resource entirely, so a bug specific to either read is caught by the
#     other disagreeing. Checked against SLUG's own `merge_autonomy_protected_paths`
#     (repo override, else the top-level key, else the shipped default),
#     resolved fresh from CONFIG_FILE by a copy of the matching logic
#     `lib/landing.sh`'s own `_landing_protected_paths`/`_landing_is_protected`
#     use, declared here rather than sourced (see above) — the same
#     "necessarily read from *current* configuration" caveat the
#     routine-sources list below already carries applies here too. `landing_eligible`
#     (`lib/landing.sh`) is level-
#     dependent here, and this recomputation must be too: below
#     `agent-merges-all` a hit refuses unconditionally, so this detector
#     treats it as a disagreement there exactly as before; at
#     `agent-merges-all` `landing_eligible` itself reports `eligible` and
#     defers to the D18 WI-12 compensating controls
#     (`landing_protected_path_controls_ok`) gate 4.5 of the arming step
#     (requirement 8d) actually checks — facts (the approving tier, the
#     standing review's own `submitted_at`/`commit_id`) this post-hoc
#     detector has no way to recompute. Recording that case as a
#     disagreement would manufacture a first-class `escape` out of every
#     sanctioned `agent-merges-all` protected-path landing, so it is treated
#     as an unreconstructable input instead: it can only ever push the
#     outcome to `unverifiable`, never `escape` and never `clean`.
#   - **Complexity** — not the `complexity:*` label GitHub shows *today*
#     (labels change), but whichever one the pull request actually carried
#     *at the moment it merged*, replayed from its own labelled/unlabelled
#     timeline (`gh api repos/SLUG/issues/N/events`) up to `merged_at`. A
#     landing audited weeks later still reports the complexity it actually
#     landed at.
#   - **Source** — GitHub carries no field for this at all (`lib/landing.sh`'s
#     own `landing_retry_source` header explains why), so it is read back
#     from the one place it is genuinely recorded: the fleet log's own
#     `landing-armed` event for this `pr_url`, which itself only ever holds
#     the value the round that armed the landing was given — never a value
#     `landing_eligible` derived. The same event is the carrier for the
#     effective level below, and for the same reason; note that neither
#     read-back makes the audit circular, because the log never decides *what
#     gets audited* — the candidate set comes from GitHub's own `merged_by`
#     (above) — and neither field is a verdict `landing_eligible` reached,
#     only an input it was handed.
#   - **The `merge_autonomy` level** — the *effective* level the landing was
#     actually armed under, read back from the same `landing-armed` event the
#     source comes from: `agent-cycle.sh`'s arming step records it there at
#     the moment gate 1 resolves it, kill switch and per-repo merge-budget
#     freeze already folded in. Never SLUG's configured level as it stands
#     today. This script runs post hoc with no state-repo access, so today's
#     `config.json` cannot tell it what was in force at a past merge: an
#     operator's later dial-down of the key — the exact move D18 staging
#     makes, and the direction an incident would move it — would manufacture
#     a first-class `escape` out of a landing that was correct when it
#     happened, driving the Stage 2 "zero classifier escapes" exit criterion
#     non-zero on an action with nothing wrong with it, while in the other
#     direction a since-cleared kill switch or since-lifted freeze would read
#     a level that actually forbade landing as one that permitted it. A
#     recorded level below `agent-merges-routine` is therefore an
#     authoritative gate-1 failure rather than an artefact of when the sweep
#     happened to arrive; a `landing-armed` event carrying no level at all
#     (armed before the field existed) reports `unverifiable`, exactly as a
#     missing source already does — never `clean`, and never `escape`.
#   - **The routine-sources list** — SLUG's own `merge_autonomy_routine_sources`
#     (repo override, else the top-level key, else the shipped default),
#     resolved fresh from CONFIG_FILE by a copy of the precedence
#     `lib/landing.sh`'s own `_landing_routine_sources` uses, declared here
#     rather than sourced, for the same reason as the protected-path list.
#     This is necessarily read from *current* configuration, not whatever was
#     in force the moment a given pull request landed — nothing in this
#     codebase preserves that history — so a landing audited long after a
#     deliberate widening or narrowing of this key is judged by today's list.
#     That is a real, accepted limitation of a post-hoc audit over a
#     forward-only log, not an oversight.
#   - **The routine-complexity list** — SLUG's own
#     `merge_autonomy_routine_complexity` (D18 Stage 3, agent-ops#725; repo
#     override, else the top-level key, else the shipped default `["low",
#     "medium"]`), resolved fresh from CONFIG_FILE by a copy of the
#     precedence `lib/landing.sh`'s own `_landing_routine_complexity` uses,
#     declared here rather than sourced, for the same reason as the
#     routine-sources list above — and with the same current-configuration
#     limitation: a landing audited long after this key was deliberately
#     widened or narrowed is judged by today's list, not the one in force
#     when it landed.
#
# Any input that cannot be reconstructed reports `unverifiable`, never
# `clean` — an unreadable merge commit's file list, a merge with zero or
# more than one `complexity:*` label standing at merge time, or a pull
# request with no matching `landing-armed` event to read a source from, or
# one whose `landing-armed` event records no effective level. A protected-
# path hit recorded at `agent-merges-all` is the same shape: `landing_eligible`
# defers that case to compensating controls this detector cannot recompute
# post hoc, so it reports `unverifiable` there too, never `escape` — unless
# some other, genuinely reconstructable input already disagrees on its own
# (a level below `agent-merges-routine`, a complexity outside the routine
# complexity list, a source outside the routine list), in which case that
# disagreement alone is enough to call it an `escape` regardless. An
# `unverifiable` landing is exactly as far from "cleared" as an `escape` is:
# neither is silently folded into the other.
#
# ## Idempotency
#
# Each merged, `pr_label`-carrying pull request this candidate list can name
# is looked up at most once, ever, regardless of who merged it: LOG_FILE
# (the fleet's own union log, or stdin/"-") is scanned first for every prior
# `classifier-escape`/`landing-audit`/`landing-audit-skip` event's own
# `pr_url`, and every candidate number is checked against that set *before*
# the `repos/SLUG/pulls/N` read that would otherwise be the only way to
# learn its own `pr_url` — GitHub's `html_url` for a pull request is always
# `https://github.com/SLUG/pull/N`, so an already-seen candidate is
# recognised, and skipped, at zero further `gh` cost. A pull request's own
# merged history is a fixed, past fact, so nothing about re-checking it
# later could change the answer.
#
# A candidate merged by anyone other than the Approver identity is not
# *audited* — there is nothing for this detector to recompute against a
# merge nothing in this pipeline armed — but the `repos/SLUG/pulls/N` read
# that established that fact is recorded too, once, as its own
# `outcome: "not-approver"` line (`agent-cycle.sh` logs it as a distinct
# `landing-audit-skip` event, kept out of `counts.escape_audits` — see
# "Output" below — since it is not a landing audit finding). That read is
# therefore paid exactly once per pull request, the same as an audited one,
# never again on a later cycle: the fact of who merged something is as fixed
# as the fact of whether recomputed eligibility agreed with it.
# `_escape_audit_candidates` lists oldest-created first for this reason
# (GitHub's own `sort=created&direction=asc` — creation order, which is not
# quite merge order: a long-lived pull request merges after a younger one
# and still sorts ahead of it): whatever a single `timeout 120` budget
# reaches, it reaches starting from the oldest still-unrecorded history
# rather than an ever-shifting newest slice, so the ground a cycle covers
# stays covered instead of being displaced by newer merges landing ahead of
# it, and — because every candidate this reaches becomes free to skip from
# the very next cycle onward, whichever of the two facts it turned out to
# carry — a cycle's budget goes further than the last cycle's until the
# whole backlog is recorded, rather than being pinned at a permanent
# frontier. Measured against Poetic-Poems/agent-ops on 2026-08-22, before
# this backlog was ever recorded: 190 merged `pr_label`-carrying pull
# requests, none of them merged by the Approver identity, at ~0.9 s per
# `repos/SLUG/pulls/N` read — about 170 s to record all of them once against
# a 120 s budget, so paying down that one-time backlog itself spans more
# than a single cycle. What `counts.escape_audits` reports is therefore a
# floor on what has been checked at any given moment, but, unlike before
# this fix, one that converges on complete coverage as the backlog is paid
# down rather than one permanently short of it.
#
# ## Output
#
# One compact JSON object per newly-recorded pull request, printed to
# stdout — never appended to the fleet log directly. Requirement 33 reserves
# that single-writer act to `agent-cycle.sh`, under its own lock
# (agents/scripts report; the Script translates into events) — this script
# is invoked from there, once per repository per cycle, and never runs
# standalone against the live log for that reason, exactly the same shape
# `scripts/sweep-human-visibility.sh` already established. Each line:
#
#   {"outcome": "clean"|"escape"|"unverifiable"|"not-approver", "pr_url": "...",
#    "repo": "OWNER/REPO", "number": 123, "merge_commit_sha": "..."|null,
#    "source": "..."|null, "complexity_recomputed": "low"|"medium"|"high"|null,
#    "protected_paths_hit": true|false|null, "protected_paths": [...]|null,
#    "reason": "..."}
#
# `reason` is always present: for `clean` it says so plainly; for `escape` it
# names which check disagreed; for `unverifiable` it names which input could
# not be reconstructed; for `not-approver` it names who merged it instead. The
# first three are audit findings — `agent-cycle.sh` logs them as
# `classifier-escape` (escape) or `landing-audit` (clean/unverifiable), and
# `scripts/publish-dashboard.sh` folds exactly those two event names into
# `counts.escape_audits`. `not-approver` is not an audit finding — nothing
# armed this merge, so there is no eligibility to have recomputed —
# `agent-cycle.sh` logs it instead as `landing-audit-skip`, a durable record
# of "already looked at, nothing to audit" that `counts.escape_audits`
# deliberately never folds in, kept apart for exactly that reason.
#
# Usage:
#   scripts/detect-classifier-escapes.sh SLUG APPROVER_LOGIN LOG_FILE
#                                         [--config FILE] [--label LABEL]
#
# LOG_FILE is a path, or "-" to read stdin. With no --config, reads
# config.json beside this script; with no --label, reads config.json's
# `pr_label` (default "autonomous-agent"), matching every other script that
# scopes a GitHub read to this pipeline's own pull requests.
#
# Environment:
#   ESCAPE_AUDIT_GH             override `gh` (tests stub it), matching
#                                LANDING_GH/MERGE_QUEUE_GH/APPROVER_GH.
#   ESCAPE_AUDIT_RETRY_DELAY_SECONDS  backoff scale for the transient-failure
#                                retry around each `gh` read (tests set 0),
#                                matching mine-merge-history.sh's own
#                                MINE_RETRY_DELAY_SECONDS.
#   ESCAPE_AUDIT_MERGE_FILES_LIMIT  the merge-commit file-list cap past which
#                                a response is treated as possibly truncated
#                                rather than complete (default 300, GitHub's
#                                own cap on `repos/SLUG/commits/SHA`'s
#                                `files` array).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

GH_BIN="${ESCAPE_AUDIT_GH:-gh}"
CONFIG_FILE="$SCRIPT_DIR/config.json"
LABEL=""

usage() {
  echo "usage: detect-classifier-escapes.sh SLUG APPROVER_LOGIN LOG_FILE [--config FILE] [--label LABEL]" >&2
  exit 64
}

declare -a POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[[ ${#POSITIONAL[@]} -eq 3 ]] || usage
slug="${POSITIONAL[0]}"
approver_login="${POSITIONAL[1]}"
log_source="${POSITIONAL[2]}"
[[ -n "$slug" && -n "$approver_login" ]] || usage

if [[ -z "$LABEL" ]]; then
  LABEL="$(jq -r '.pr_label // "autonomous-agent"' "$CONFIG_FILE" 2>/dev/null)"
  [[ -n "$LABEL" && "$LABEL" != "null" ]] || LABEL="autonomous-agent"
fi

# --- Transient-failure retry around the metered `gh` wrapper ---------------
# Same shape as scripts/mine-merge-history.sh's own gh_retry: a dropped
# connection mid-run must not silently mark a pull request unverifiable that
# a second attempt would have read fine.
#
# The response buffer is the single `retry_buf` allocated beside the other
# temp files below, truncated between uses, rather than a fresh `mktemp` per
# call. Every call here happens inside a command substitution, so a `mktemp`
# taken in this function belongs to a subshell the signal handler below can
# never clean up after: the handler runs in the parent, and a path the parent
# never learned is a path it cannot remove. Since the sweep is killed
# mid-read on any cycle that reaches its `timeout`, that would leak one file
# per in-flight read, every time — the same defect the trap below exists to
# close, one level down. Calls are strictly sequential, so one buffer serves
# them all.
gh_retry() {
  local rc attempt delay
  delay="${ESCAPE_AUDIT_RETRY_DELAY_SECONDS:-5}"
  rc=1
  for attempt in 1 2 3; do
    if "$GH_BIN" "$@" >"$retry_buf" 2>/dev/null; then
      cat "$retry_buf"; : >"$retry_buf"; return 0
    else
      rc=$?
    fi
    if (( attempt < 3 )); then
      sleep $(( attempt * delay ))
      : >"$retry_buf"
    fi
  done
  : >"$retry_buf"
  return "$rc"
}

# --- The reimplemented protected-path resolution and list -------------------
# Deliberately not sourced from lib/landing.sh — see this file's own header.
# Kept byte-for-byte in step with _landing_protected_paths/_landing_is_protected
# (lib/landing.sh), and test/detect-classifier-escapes.test.sh pins the two
# identical over the same battery of configs and paths so a change to one
# that is not mirrored in the other fails CI rather than drifting silently.
_escape_audit_protected_paths() {
  local config_json="$1" repo_slug="$2" repo_list top_list
  repo_list="$(jq -c --arg slug "$repo_slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_autonomy_protected_paths // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_list" ]] && jq -e 'type == "array"' <<<"$repo_list" >/dev/null 2>&1; then
    printf '%s' "$repo_list"
    return 0
  fi
  top_list="$(jq -c '.merge_autonomy_protected_paths // empty' <<<"$config_json" 2>/dev/null)"
  if [[ -n "$top_list" ]] && jq -e 'type == "array"' <<<"$top_list" >/dev/null 2>&1; then
    printf '%s' "$top_list"
    return 0
  fi
  printf '%s' '[".github/*","deploy/*","prompts/*","lib/*","config.schema.json","config.json","agent-cycle.sh","review-cycle.sh","CODEOWNERS"]'
}

# Exit 0 on a match, 1 on none, 5 — jq -e's own code for a raising program —
# when an entry in PROTECTED_JSON is not a string `endswith`/`==` can compare
# at all (TD-PPagop-26082320); see _landing_is_protected's own comment for why
# this is unreachable through a schema-validated config.json but still must
# not read as "no match" to the caller below.
_escape_audit_is_protected() {
  local protected_json="$1" path="$2"
  jq -e --arg p "$path" '
    any(.[]; . as $entry | if $entry | endswith("/*") then ($p | startswith($entry[:-1])) else $entry == $p end)
  ' <<<"$protected_json" >/dev/null 2>&1
}

# --- The reimplemented routine-sources resolution ---------------------------
# Deliberately not sourced from lib/landing.sh's _landing_routine_sources —
# same reasoning as the protected-path list above, and pinned against it the
# same way in test/detect-classifier-escapes.test.sh.
_escape_audit_routine_sources() {
  local config_json="$1" repo_slug="$2" repo_list top_list
  repo_list="$(jq -c --arg slug "$repo_slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_autonomy_routine_sources // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_list" ]] && jq -e 'type == "array"' <<<"$repo_list" >/dev/null 2>&1; then
    printf '%s' "$repo_list"
    return 0
  fi
  top_list="$(jq -c '.merge_autonomy_routine_sources // empty' <<<"$config_json" 2>/dev/null)"
  if [[ -n "$top_list" ]] && jq -e 'type == "array"' <<<"$top_list" >/dev/null 2>&1; then
    printf '%s' "$top_list"
    return 0
  fi
  printf '["register-hygiene","tech-debt"]'
}

# --- The reimplemented routine-complexity resolution -------------------------
# Deliberately not sourced from lib/landing.sh's _landing_routine_complexity —
# same reasoning as the routine-sources resolution above (D18 Stage 3,
# agent-ops#725), and pinned against it the same way in
# test/detect-classifier-escapes.test.sh.
_escape_audit_routine_complexity() {
  local config_json="$1" repo_slug="$2" repo_list top_list
  repo_list="$(jq -c --arg slug "$repo_slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_autonomy_routine_complexity // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_list" ]] && jq -e 'type == "array"' <<<"$repo_list" >/dev/null 2>&1; then
    printf '%s' "$repo_list"
    return 0
  fi
  top_list="$(jq -c '.merge_autonomy_routine_complexity // empty' <<<"$config_json" 2>/dev/null)"
  if [[ -n "$top_list" ]] && jq -e 'type == "array"' <<<"$top_list" >/dev/null 2>&1; then
    printf '%s' "$top_list"
    return 0
  fi
  printf '["low","medium"]'
}

# --- The merge commit's own file list ---------------------------------------
# repos/SLUG/commits/SHA, never repos/SLUG/pulls/N/files (landing_protected_
# paths_hit's own read) — a genuinely different GitHub resource. Two distinct
# ways this response can be hiding files past whatever it returned, both
# treated as a refusal to answer "no protected path", never a pass, the same
# "a page cap is a truncation signal, not a floor to trust" reasoning
# `LANDING_PR_FILES_LIMIT` (lib/landing.sh, which this script deliberately
# never sources — see the header) and `github_pr_list_truncated`
# (lib/github-limit.sh, sourced above) already apply to the sibling read:
#
#   - GitHub omits `files` from this response outright once a commit's diff
#     is too large to enumerate rather than paginating it — a response with
#     no `files` array at all.
#   - Short of that, GitHub still caps `files` at 300 entries and does not
#     paginate past it or say so: a response with exactly
#     ESCAPE_AUDIT_MERGE_FILES_LIMIT entries may be hiding more past the cap,
#     indistinguishable from a merge that touched exactly that many files and
#     no more.
ESCAPE_AUDIT_MERGE_FILES_LIMIT="${ESCAPE_AUDIT_MERGE_FILES_LIMIT:-300}"
_escape_audit_merge_files() {
  local repo_slug="$1" sha="$2" raw count
  raw="$(gh_retry api "repos/$repo_slug/commits/$sha")" || return 2
  jq -e '.files | type == "array"' <<<"$raw" >/dev/null 2>&1 || return 2
  count="$(jq '.files | length' <<<"$raw" 2>/dev/null)"
  github_pr_list_truncated "$count" "$ESCAPE_AUDIT_MERGE_FILES_LIMIT" && return 2
  jq -r '.files[].filename' <<<"$raw" 2>/dev/null
}

# --- Complexity as of the merge, replayed from the labelled/unlabelled
# timeline -------------------------------------------------------------------
# Prints the single complexity:* label standing at MERGED_AT, or nothing if
# zero or more than one were standing (the caller treats either as
# unverifiable, never guesses between them).
#
# `--method GET` is not decoration, here or in `_escape_audit_candidates`
# below: `gh api` switches a request carrying `-f`/`-F` fields to POST unless
# told otherwise (the same trap `lib/review-gate.sh`'s own reads document),
# and a POST to either endpoint answers 404/422 rather than the listing this
# needs — which `gh_retry` would report as an unreadable timeline, so every
# landing would read `unverifiable` and no escape could ever be found.
_escape_audit_complexity_at_merge() {
  local repo_slug="$1" number="$2" merged_at="$3" raw
  raw="$(gh_retry api "repos/$repo_slug/issues/$number/events" --method GET --paginate -F per_page=100 \
    --jq '.[] | select(.event == "labeled" or .event == "unlabeled") | select((.label.name // "") | test("^complexity:")) | {event, label: .label.name, at: .created_at}')" \
    || return 2
  jq -s -r --arg cut "$merged_at" '
    map(select((.at // "") <= $cut)) | sort_by(.at)
    | reduce .[] as $e ({}; if $e.event == "labeled" then .[$e.label] = true else del(.[$e.label]) end)
    | keys | if length == 1 then (.[0] | sub("^complexity:"; "")) else empty end
  ' <<<"$raw" 2>/dev/null
}

# --- Every merged, APPROVER_LOGIN-merged, LABEL-carrying pull request ------
# REST over search (same reasoning as mine-merge-history.sh's own header):
# repos/SLUG/issues, state=closed, filtered by label, one flat 1-point-per-
# page cost against the shared `core` budget. A closed issue's own
# `pull_request.merged_at` distinguishes a merge from a plain close.
#
# `sort=created,direction=asc` — GitHub's own default for this endpoint is
# newest-first, which is the wrong order for a sweep that cannot always
# finish inside one `timeout 120` (see the invocation site in
# agent-cycle.sh): newest-first would spend every cycle re-establishing the
# same recent slice, since new pull requests keep merging in ahead of
# whatever the sweep last reached. Oldest-first instead makes each cycle's
# budget buy forward progress through history that stays put once made —
# the pull requests behind the frontier this reaches are never reordered by
# a later merge. It does not make an over-budget candidate list finish: see
# "Idempotency" above for what a frontier that stops advancing costs, and
# why it is the newest landings that a frozen one never reaches.
_escape_audit_candidates() {
  local repo_slug="$1"
  gh_retry api "repos/$repo_slug/issues" --method GET --paginate -F per_page=100 \
    -f state=closed -f labels="$LABEL" -f sort=created -f direction=asc \
    --jq '.[] | select(.pull_request != null and .pull_request.merged_at != null) | .number'
}

# --- Already-seen pr_urls, and recorded landing-armed facts, from the fleet
# log -------------------------------------------------------------------------
audited_file="$(mktemp)"
armed_file="$(mktemp)"
# `gh_retry`'s shared response buffer — see its own note above for why it is
# allocated out here, in the parent, rather than per call inside it.
retry_buf="$(mktemp)"
# INT/TERM/HUP alongside EXIT: `agent-cycle.sh` runs this script under
# `timeout 120`, and on a timeout bash takes the default fatal action for
# SIGTERM and never reaches an EXIT-only trap, leaking both temp files every
# time the sweep actually times out — the normal case here, not an edge case.
#
# Each signal handler must *exit*, and that half is not decoration. A trapped
# signal whose handler falls off its own end returns bash to what it was
# doing: the candidate loop below resumes, and since `timeout` sends one
# SIGTERM and then waits (no `--kill-after` at the call site), nothing stops
# the sweep again — `timeout 120` silently stops bounding anything and the
# run costs whatever the whole candidate list costs. Exiting through `exit`
# with the signal's own 128+n, the shape `agent-cycle.sh`'s `on_signal` uses,
# both keeps the bound real and still lets every line already emitted reach
# the caller, since this script reports by printing as it goes.
_escape_audit_cleanup() { rm -f "$audited_file" "$armed_file" "$retry_buf" "$audited_file.raw"; }
trap _escape_audit_cleanup EXIT
trap '_escape_audit_cleanup; exit 130' INT
trap '_escape_audit_cleanup; exit 143' TERM
trap '_escape_audit_cleanup; exit 129' HUP

read_log() {
  if [[ "$log_source" == "-" ]]; then
    cat
  elif [[ -s "$log_source" ]]; then
    cat "$log_source"
  fi
}

read_log | jq -c -R 'fromjson? // empty' 2>/dev/null > "$audited_file.raw" || true

jq -c --arg r "$slug" \
  'select((.repo // "") == $r and (.event == "classifier-escape" or .event == "landing-audit" or .event == "landing-audit-skip")) | .pr_url // empty' \
  "$audited_file.raw" 2>/dev/null | sort -u > "$audited_file" || true

jq -c --arg r "$slug" \
  'select((.repo // "") == $r and .event == "landing-armed") | {pr_url: (.pr_url // ""), source: (.source // ""), level: (.level // "")}' \
  "$audited_file.raw" 2>/dev/null > "$armed_file" || true
rm -f "$audited_file.raw"

already_audited() {
  local url="$1"
  grep -qxF "\"$url\"" "$audited_file" 2>/dev/null
}

recorded_source_for() {
  local url="$1"
  jq -r --arg u "$url" 'select(.pr_url == $u) | .source' "$armed_file" 2>/dev/null | tail -1
}

# The effective merge_autonomy level this landing was armed under, as the
# arming step itself recorded it — see the header. Empty for a landing armed
# before `agent-cycle.sh` began writing the field, which is `unverifiable`,
# never a level guessed from current configuration.
recorded_level_for() {
  local url="$1"
  jq -r --arg u "$url" 'select(.pr_url == $u) | .level' "$armed_file" 2>/dev/null | tail -1
}

config_json="$(cat "$CONFIG_FILE" 2>/dev/null || printf '{}')"
routine_json="$(_escape_audit_routine_sources "$config_json" "$slug")"
protected_json="$(_escape_audit_protected_paths "$config_json" "$slug")"
routine_complexity_json="$(_escape_audit_routine_complexity "$config_json" "$slug")"

emit() {
  local outcome="$1" pr_url="$2" number="$3" sha="$4" source="$5" complexity="$6" \
        hit="$7" paths_json="$8" reason="$9"
  jq -nc --arg o "$outcome" --arg u "$pr_url" --arg r "$slug" --argjson n "$number" \
    --arg sha "$sha" --arg src "$source" --arg c "$complexity" --arg h "$hit" \
    --argjson p "$paths_json" --arg reason "$reason" '
    {outcome: $o, pr_url: $u, repo: $r, number: $n,
     merge_commit_sha: (if $sha == "" then null else $sha end),
     source: (if $src == "" then null else $src end),
     complexity_recomputed: (if $c == "" then null else $c end),
     protected_paths_hit: (if $h == "true" then true elif $h == "false" then false else null end),
     protected_paths: $p, reason: $reason}'
}

while IFS= read -r number; do
  [[ -n "$number" ]] || continue

  # GitHub's own `html_url` for a pull request is always this exact shape —
  # the same value `pr_url` below reads back out of the pulls/N response —
  # so an already-seen candidate is recognised, and skipped, without
  # spending that read at all. See "Idempotency" above for what this bounds.
  pr_url="https://github.com/$slug/pull/$number"
  already_audited "$pr_url" && continue

  pr_json="$(gh_retry api "repos/$slug/pulls/$number")" || {
    # An unreadable pull request record: cannot even confirm merged_by, so
    # this candidate is neither confirmed as an Approver-identity landing
    # nor safely skippable forever. Left unrecorded rather than guessed at —
    # the next cycle's run tries again, exactly as an unreadable candidate
    # anywhere else in this codebase is retried, not given up on.
    continue
  }
  merged="$(jq -r '.merged // false' <<<"$pr_json" 2>/dev/null)"
  [[ "$merged" == "true" ]] || continue
  merged_by="$(jq -r '.merged_by.login // ""' <<<"$pr_json" 2>/dev/null)"
  if [[ "$merged_by" != "$approver_login" ]]; then
    # Nothing armed this merge, so there is no eligibility to have
    # recomputed — but the read that established who merged it is real, and
    # recording it once (see "Idempotency" above) is what stops it being
    # paid again every future cycle for as long as this repository keeps
    # producing them.
    emit "not-approver" "$pr_url" "$number" "" "" "" "" "[]" \
      "merged by $merged_by, not the Approver identity ($approver_login) — nothing for this audit to recompute"
    continue
  fi

  merged_at="$(jq -r '.merged_at // ""' <<<"$pr_json" 2>/dev/null)"
  sha="$(jq -r '.merge_commit_sha // ""' <<<"$pr_json" 2>/dev/null)"

  reasons=()

  source="$(recorded_source_for "$pr_url")"
  if [[ -z "$source" ]]; then
    reasons+=("no landing-armed event in the fleet log records this pull request's work source")
  fi

  armed_level="$(recorded_level_for "$pr_url")"
  if [[ -z "$armed_level" ]]; then
    reasons+=("no landing-armed event in the fleet log records the effective merge_autonomy level this landing was armed under")
  fi

  complexity=""
  if [[ -z "$sha" ]]; then
    reasons+=("the merge carries no merge_commit_sha")
    hit="" paths_json='[]'
  else
    files_out="$(_escape_audit_merge_files "$slug" "$sha")"; files_rc=$?
    if (( files_rc != 0 )); then
      reasons+=("the merge commit's own file list could not be read (unreadable, too large to enumerate, or capped at the ${ESCAPE_AUDIT_MERGE_FILES_LIMIT}-file limit)")
      hit="" paths_json='[]'
    else
      declare -a protected=()
      protected_unreadable=""
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        _escape_audit_is_protected "$protected_json" "$path"; is_protected_rc=$?
        case "$is_protected_rc" in
          0) protected+=("$path") ;;
          1) ;;
          *) protected_unreadable=1; break ;;
        esac
      done <<<"$files_out"
      if [[ -n "$protected_unreadable" ]]; then
        reasons+=("the protected-path list could not be evaluated against the merge's changed files (a non-string entry in merge_autonomy_protected_paths)")
        hit="" paths_json='[]'
      elif (( ${#protected[@]} > 0 )); then
        hit="true"
        paths_json="$(printf '%s\n' "${protected[@]}" | jq -R . | jq -s -c .)"
      else
        hit="false"
        paths_json='[]'
      fi
    fi
  fi

  if [[ -z "$merged_at" ]]; then
    reasons+=("the pull request record carries no merged_at")
  else
    complexity="$(_escape_audit_complexity_at_merge "$slug" "$number" "$merged_at")"
    complexity_rc=$?
    if (( complexity_rc != 0 )); then
      reasons+=("the labelled/unlabelled timeline could not be read")
    elif [[ -z "$complexity" ]]; then
      reasons+=("no single complexity:* label was standing at merge time")
    fi
  fi

  if (( ${#reasons[@]} > 0 )); then
    reason="$(IFS='; '; echo "${reasons[*]}")"
    emit "unverifiable" "$pr_url" "$number" "$sha" "$source" "$complexity" "$hit" "$paths_json" "$reason"
    continue
  fi

  disagreements=()
  unverifiable_reasons=()
  case "$armed_level" in
    agent-merges-routine|agent-merges-all) ;;
    *)
      disagreements+=("the effective merge_autonomy level recorded at arming was $armed_level, not agent-merges-routine or agent-merges-all")
      ;;
  esac
  if ! jq -e --arg c "$complexity" 'index($c) != null' <<<"$routine_complexity_json" >/dev/null 2>&1; then
    disagreements+=("complexity was $complexity, not in $slug's routine complexity list $routine_complexity_json")
  fi
  if ! jq -e --arg s "$source" 'index($s) != null' <<<"$routine_json" >/dev/null 2>&1; then
    disagreements+=("source $source is not in $slug's routine list $routine_json")
  fi
  if [[ "$hit" == "true" ]]; then
    if [[ "$armed_level" == "agent-merges-all" ]]; then
      # landing_eligible (lib/landing.sh) does not refuse a protected-path
      # hit at agent-merges-all — it reports `eligible` and defers to
      # landing_protected_path_controls_ok (D18 WI-12's compensating
      # controls), a gate that needs facts (the approving tier, the standing
      # review's own submitted_at and commit_id) this detector has no
      # post-hoc way to recompute. Recording this as a disagreement would
      # manufacture a first-class escape out of every sanctioned
      # agent-merges-all protected-path landing; it is an unreconstructable
      # input, not a disagreement, so it can only ever push the outcome to
      # `unverifiable`, never `escape` and never `clean`.
      unverifiable_reasons+=("touched protected path(s) at agent-merges-all: $(jq -r 'join(", ")' <<<"$paths_json") — landing_eligible defers this to the WI-12 compensating controls (landing_protected_path_controls_ok), which this detector cannot recompute post hoc")
    else
      disagreements+=("touched protected path(s): $(jq -r 'join(", ")' <<<"$paths_json")")
    fi
  fi

  if (( ${#disagreements[@]} > 0 )); then
    reason="$(IFS='; '; echo "${disagreements[*]}")"
    emit "escape" "$pr_url" "$number" "$sha" "$source" "$complexity" "$hit" "$paths_json" \
      "landed under the Approver identity but recomputed eligibility disagrees: $reason"
  elif (( ${#unverifiable_reasons[@]} > 0 )); then
    reason="$(IFS='; '; echo "${unverifiable_reasons[*]}")"
    emit "unverifiable" "$pr_url" "$number" "$sha" "$source" "$complexity" "$hit" "$paths_json" "$reason"
  else
    emit "clean" "$pr_url" "$number" "$sha" "$source" "$complexity" "$hit" "$paths_json" \
      "recomputed eligibility agrees: this landing should have been eligible"
  fi
done < <(_escape_audit_candidates "$slug")
