#!/usr/bin/env bash
#
# publish-tech-debt-archive.sh — D15-as-revised durable-ledger mitigation
# (issue #878, following #869/#875/#879): a scheduled export that mirrors
# every `pw::type:tech-debt`-labelled issue, per configured repository, into
# the state repository (`state_repo`) as one JSON file per issue under
# `tech-debt-archive/<owner>/<repo>/<number>.json`.
#
# Why a mirror at all: the working store is a GitHub issue — mutable, and
# deletable or relabellable by anyone with triage. `gather-tech-debt.sh`
# (the Co-Ordinator's own read of this band) only ever sees the label's
# *current* membership, so an edited body, a closed-without-fix, or a
# relabelled-away item all vanish from that view with no trace of what was
# there before. This export's target is the state repository's own git
# history: every write below lands as a commit on `main`, so the archive's
# trail is exactly as durable as `claims/` and `fleet/*.json` already are —
# the same contents-API upsert `lib/toggle.sh`'s `fleet_flag_write` and
# `lib/claim.sh`'s `registry_put` use, applied to a new path prefix.
#
# ## Placement (D14)
#
# Follows `scripts/publish-revert-rate.sh`'s own precedent (D18 issue #579)
# rather than either a GitHub Actions workflow or a hook into
# `scripts/publish-dashboard.sh`'s 5-minute heartbeat: a GitHub Actions
# workflow would need its own credential wired up for cross-repo writes to
# `state_repo`, a repeat of the very cost this component is meant to avoid
# under D14's "no container pays for a capability it does not need" rule,
# when every node already carries working `gh` credentials on its own daily
# cron. Riding the dashboard's own tick was the other option this issue's
# body named, and was rejected for the reverse reason: that tick runs every
# five minutes because its own panels are meant to look near-live, and
# tech-debt volume does not move at anything like that cadence — forcing
# this export onto that schedule would only ever waste four ticks out of
# five. A once-a-day cadence, on its own crontab line
# (`deploy/docker/crontab.tmpl`, `schedule.tech_debt_archive_hour`/
# `tech_debt_archive_offset_minutes`), costs this node nothing between runs
# and needs no new secret.
#
# ## Budgeting the API cost
#
# Two listings per configured repository, whatever the archive's size:
#
#   - one label search — `GET /repos/{slug}/issues?labels=pw::type:tech-
#     debt&state=all`, paginated — which is also the audit source for empty
#     bodies (no separate call: the search already returns each issue's
#     `body`);
#   - one open-pull-request listing, for the unlabelled-legacy-filing audit
#     below.
#
# Past those two, every further call is bounded by *what changed*, never by
# how much debt exists: this node's own memo of each issue's last-seen
# `updated_at` (`tech-debt-archive/<owner>/<repo>/_index.json`, itself one
# more GET) decides which issues are unchanged since the last run and skips
# them outright. An issue whose `updated_at` moved costs one GET (the
# archive file's current blob `sha`, needed for the contents API's optimistic
# concurrency — absent when the file is new) and one PUT. So a repository
# with 200 archived issues and 3 changed since yesterday costs 2 + 1 + 2*3
# calls, not 2 + 200.
#
# ## The audits
#
# Both are logged, never fixed here — this script only ever writes into
# `state_repo`, never into a target repository:
#
#   - **empty bodies**: a `pw::type:tech-debt` issue whose body is blank is a
#     data-quality defect in the working store itself (nothing to archive
#     that says why the debt matters), read off the same label search that
#     builds the archive.
#   - **unlabelled debt from `file_debt`'s degrade path**: `techdebt_file_debt`
#     (`lib/tech-debt-file.sh`) predates this repository's own D15-as-revised
#     migration and still files a debt record the old way — a
#     `tech-debt/<id>.md` file on a `td-record/<id>` branch, carried by a
#     pull request labelled `pr_label`, never `pw::type:tech-debt` — so
#     every record it produces is invisible to the label search above by
#     construction, not merely on a failure path. An open pull request whose
#     head branch starts with `TECHDEBT_RECORD_BRANCH_PREFIX`
#     (`lib/tech-debt-file.sh`) is exactly one of these; flagging it here is
#     what gives an operator visibility into debt this archive cannot yet
#     see, until that filing path is itself migrated.
#
# ## What is never done here
#
# Deleting or relabelling an issue removes it from the *next* label search,
# but this script only ever adds or updates a file — it never deletes one —
# so an already-archived record survives both untouched, exactly the
# guarantee the working store cannot offer on its own.
#
# Usage:
#   scripts/publish-tech-debt-archive.sh [--config FILE] [--repo OWNER/REPO ...]
#                                         [--state-repo OWNER/REPO]
#
# With no flags, reads the repository list from config.json's `repos[].slug`
# and the mirror target from `state_repo` (both next to this script). A
# `state_repo` of "" (single-node operation, as `lib/claim.sh` and
# `lib/toggle.sh` both already treat it) is a silent no-op, exit 0 — there is
# nowhere to archive into, the same posture every other `state_repo`-gated
# mode in this pipeline already takes.
#
# Exit status: 0 iff every configured repository's label search and archive
# write succeeded; 1 if any repository's search failed or any archive write
# was left unresolved after its retry (that repository's changed issues are
# simply retried on the next run, never fabricated) — the crontab line's own
# `|| true` keeps a partial run from reading as a crashed script, the same
# reasoning `scripts/publish-revert-rate.sh`'s own crontab line uses.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# Rate-limit-aware `gh`, and `gh_retry`-equivalent handling of a transient
# failure — see lib/github-limit.sh's own header.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# For TECHDEBT_RECORD_BRANCH_PREFIX alone (the unlabelled-legacy-filing
# audit below) — never call any function this file defines, since it is
# meant for the Script's own Approver/Enabler filing path, not this reader.
# shellcheck source=lib/tech-debt-file.sh
. "$SCRIPT_DIR/lib/tech-debt-file.sh"

CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
LABEL="pw::type:tech-debt"
declare -a REPOS=()
state_repo_override=""

usage() {
  cat <<'EOF'
usage: publish-tech-debt-archive.sh [--config FILE] [--repo OWNER/REPO ...]
                                     [--state-repo OWNER/REPO]

With no flags, reads the repository list from config.json's `repos[].slug`
and the mirror target from `state_repo`. Each configured repository's open
and closed `pw::type:tech-debt`-labelled issues are mirrored, one JSON file
per issue, into `tech-debt-archive/<owner>/<repo>/<number>.json` in the
state repository.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --repo) REPOS+=("$2"); shift 2 ;;
    --state-repo) state_repo_override="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || { echo "publish-tech-debt-archive: config file not found: $CONFIG_FILE" >&2; exit 1; }
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")" || {
  echo "publish-tech-debt-archive: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
  exit 1
}

if [[ ${#REPOS[@]} -eq 0 ]]; then
  mapfile -t REPOS < <(jq -r '.repos[].slug' <<<"$DEFAULTED_CONFIG")
  [[ ${#REPOS[@]} -gt 0 ]] || { echo "publish-tech-debt-archive: $CONFIG_FILE names no repos" >&2; exit 1; }
fi

state_repo="$state_repo_override"
[[ -n "$state_repo" ]] || state_repo="$(jq -r '.state_repo // ""' <<<"$DEFAULTED_CONFIG")"
if [[ -z "$state_repo" ]]; then
  echo "publish-tech-debt-archive: no state_repo configured — single-node operation, nothing to archive into" >&2
  exit 0
fi

# --- Contents-API upsert, generalised from lib/toggle.sh's fleet_flag_write
#     (fixed to the fleet/ prefix) and lib/claim.sh's registry_put (create-
#     only) to an arbitrary path and an update-or-create PUT. -----------------

# _archive_get PATH -> sets ARCHIVE_CONTENT to the decoded content and
# ARCHIVE_SHA to the blob sha, or both to "" when the path does not exist.
# Returns 1 only on a failure this call cannot tell apart from "does not
# exist" (network, auth) — the caller treats both the same way a fresh
# archive already must (nothing to diff against yet).
#
# Sets globals rather than printing, and every call site below invokes it
# as a plain statement, never inside `$(...)`: a command substitution forks
# a subshell, and an assignment made inside one is invisible to the parent
# shell the instant the subshell exits — the exact way to lose the very
# value ARCHIVE_SHA exists to carry out.
ARCHIVE_SHA=""
ARCHIVE_CONTENT=""
_archive_get() {
  local path="$1" resp
  resp="$(gh api "repos/$state_repo/contents/$path?ref=main" 2>/dev/null)" || {
    ARCHIVE_SHA=""
    ARCHIVE_CONTENT=""
    return 1
  }
  ARCHIVE_SHA="$(jq -r '.sha // ""' <<<"$resp")"
  ARCHIVE_CONTENT="$(jq -r '.content // ""' <<<"$resp" | tr -d '\n' | base64 -d 2>/dev/null)"
}

# _archive_put PATH BODY MESSAGE [SHA] -> the written content's own new blob
# sha on stdout (for the caller's own index bookkeeping), or nothing on
# failure. SHA omitted (or already stale) means "create" — the contents API
# itself distinguishes create from update by whether `sha` is present.
_archive_put() {
  local path="$1" body="$2" msg="$3" sha="${4:-}" payload resp
  payload="$(printf '%s' "$body" | base64 -w0)"
  if [[ -n "$sha" ]]; then
    resp="$(gh api -X PUT "repos/$state_repo/contents/$path" \
      -f "message=$msg" -f "content=$payload" -f "branch=main" -f "sha=$sha" 2>/dev/null)" || return 1
  else
    resp="$(gh api -X PUT "repos/$state_repo/contents/$path" \
      -f "message=$msg" -f "content=$payload" -f "branch=main" 2>/dev/null)" || return 1
  fi
  jq -r '.content.sha // ""' <<<"$resp"
}

exit_code=0

for slug in "${REPOS[@]}"; do
  owner="${slug%%/*}"
  name="${slug#*/}"
  archive_dir="tech-debt-archive/$owner/$name"
  index_path="$archive_dir/_index.json"

  # The one label search this repository costs per run — every state, so a
  # closed-without-fix or a since-edited issue is picked up the same way an
  # open one is. Streamed per page (`.[] | ...`, never `[.[] | ...]`) and
  # slurped afterwards, the discipline scripts/mine-merge-history.sh's own
  # header explains: `--paginate` re-runs a wrapping filter once per page.
  issues_json="$(gh api --paginate \
    "repos/$slug/issues?labels=$LABEL&state=all&per_page=100" \
    --jq '.[] | select(has("pull_request") | not) |
          {number, title, state, state_reason, author: (.user.login // ""),
           labels: [(.labels[]?.name)], created_at, updated_at, closed_at,
           body: (.body // "")}' \
    | jq -s -c '.')"
  issues_rc=$?
  if (( issues_rc != 0 )) || ! jq -e 'type == "array"' <<<"$issues_json" >/dev/null 2>&1; then
    echo "publish-tech-debt-archive: $slug: label search failed — skipping this repo" >&2
    exit_code=1
    continue
  fi

  # Audit: a labelled issue with no body at all — read off the same search,
  # no extra call.
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    echo "publish-tech-debt-archive: $slug: issue #$n carries $LABEL with an empty body" >&2
  done < <(jq -r '.[] | select((.body // "") | gsub("\\s"; "") == "") | .number' <<<"$issues_json")

  # Audit: an open pull request already filed the old way (lib/tech-
  # debt-file.sh's techdebt_file_debt, pre-D15-as-revised) is invisible to
  # the label search above by construction — flag it rather than silently
  # missing it. TECHDEBT_RECORD_BRANCH_PREFIX has no character a jq double-
  # quoted string needs to escape (lib/tech-debt-file.sh fixes it to
  # "td-record/"), so it is interpolated directly rather than needing a
  # `--jq`-side `--arg` this flag has no way to take (unlike the jq binary
  # itself, `gh api --jq` accepts only the filter expression).
  legacy_prs="$(gh api --paginate "repos/$slug/pulls?state=open&per_page=100" \
    --jq ".[] | select(.head.ref | startswith(\"$TECHDEBT_RECORD_BRANCH_PREFIX\")) | {number, html_url, head_ref: .head.ref}" \
    | jq -s -c '.')"
  legacy_prs_rc=$?
  if (( legacy_prs_rc != 0 )); then
    echo "publish-tech-debt-archive: $slug: legacy-filing audit could not list open pull requests — skipping this audit" >&2
    legacy_prs='[]'
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n="$(jq -r '.number' <<<"$line")"
    ref="$(jq -r '.head_ref' <<<"$line")"
    url="$(jq -r '.html_url' <<<"$line")"
    echo "publish-tech-debt-archive: $slug: PR #$n ($url, branch $ref) is a pre-migration tech-debt filing — invisible to the $LABEL archive" >&2
  done < <(jq -c '.[]' <<<"$legacy_prs" 2>/dev/null)

  # The per-repository memo of each issue's last-seen updated_at — the diff
  # base that keeps every unchanged issue out of the GET/PUT loop below.
  _archive_get "$index_path"
  index_raw="$ARCHIVE_CONTENT"
  index_sha="$ARCHIVE_SHA"
  jq -e 'type == "object"' <<<"$index_raw" >/dev/null 2>&1 || index_raw='{}'

  new_index="$index_raw"
  repo_failed=0
  changed=0
  while IFS= read -r issue; do
    [[ -n "$issue" ]] || continue
    n="$(jq -r '.number' <<<"$issue")"
    updated="$(jq -r '.updated_at' <<<"$issue")"
    prev_updated="$(jq -r --arg n "$n" '.[$n] // ""' <<<"$new_index")"
    [[ "$updated" != "$prev_updated" ]] || continue

    file_path="$archive_dir/$n.json"
    _archive_get "$file_path"
    file_sha="$ARCHIVE_SHA"

    new_sha="$(_archive_put "$file_path" "$issue" \
      "tech-debt archive: $slug#$n" "$file_sha")"
    if [[ -z "$new_sha" ]]; then
      echo "publish-tech-debt-archive: $slug#$n: archive write failed — will retry next run" >&2
      repo_failed=1
      continue
    fi
    new_index="$(jq -c --arg n "$n" --arg u "$updated" '.[$n] = $u' <<<"$new_index")"
    changed=$(( changed + 1 ))
  done < <(jq -c '.[]' <<<"$issues_json")

  if (( changed > 0 )); then
    if ! _archive_put "$index_path" "$new_index" \
           "tech-debt archive: refresh index for $slug" "$index_sha" >/dev/null; then
      echo "publish-tech-debt-archive: $slug: index write failed — unchanged issues will be re-fetched next run" >&2
      repo_failed=1
    fi
  fi

  (( repo_failed == 0 )) || exit_code=1
done

exit "$exit_code"
