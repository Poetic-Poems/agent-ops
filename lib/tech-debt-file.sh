#!/usr/bin/env bash
#
# lib/tech-debt-file.sh — file deferred work on the Script's own behalf
# (agent-ops#631), for a stage that must never write to GitHub or a branch
# itself: the Approver ("What you must never do": never write code, push,
# amend the branch, or write to GitHub at all) and the Enabler (same rule,
# and it runs with no clone of any repo at all). Both may set `file_debt` or
# `file_issue` in their final JSON; the Script is what actually files it,
# under the calling stage's own identity where one applies.
#
# techdebt_file_issue REPO ITEM_REF TITLE BODY_FILE [TOKEN]
#   Files one plain GitHub issue, or returns an existing one that already
#   covers ITEM_REF. No label or assignee — unlike an escalation
#   (create_escalation_issue) this is not addressed at a specific human and
#   is legitimate autonomous work for a later cycle to pick up, not a
#   request excluded from the `issues` source. Prints "<number>\t<url>" on
#   success; prints nothing and returns 1 otherwise.
#
# techdebt_file_debt REPO TITLE BODY PROVENANCE [TOKEN] [GIT_DIR] [PR_LABEL]
#   Reserves a tech-debt id, writes tech-debt/<id>.md, and opens a pull
#   request carrying it alone, labelled PR_LABEL (default "autonomous-agent")
#   so it is visible to every gatherer that filters pull requests by the
#   repository's configured label — gather-review-feedback.sh,
#   gather-abandoned-drafts.sh, gather-merge-conflicts.sh,
#   gather-dequeued.sh, gather-human-visibility-hygiene.sh — rather than
#   stranding it unlabelled and invisible to all of them at once
#   (agent-ops TD-PPagop-26082426). The Approver and the Enabler each resolve
#   the fleet's configured `pr_label` from `DEFAULTED_CONFIG` at their own
#   call site and pass it here, neither having it otherwise in hand.
#   Follows TECH-DEBT.md's "Filing alongside other work" exactly, except the
#   filing lands in its own small pull request rather than riding along on a
#   branch the caller already holds: neither the Approver nor the Enabler is
#   ever the author of one. Prints "<id>\t<pr-url>" on success; prints
#   nothing and returns 1 otherwise.
#
#   Reservation runs scripts/reserve-tech-debt-id.pl exactly as committed on
#   REPO's own origin/main — never GIT_DIR's checked-out branch, which for
#   the Approver is the pull request under review and could carry an edited
#   (or malicious) copy of a script this function is about to execute with
#   write credentials. It is a governed, cross-repo-synced canonical copy
#   (TECH-DEBT.md, .github/workflows/td-tooling-drift.yml); this file must
#   never reimplement its collision-avoidance logic independently — "A rule
#   with two implementations",
#   docs/IMPLEMENTATION-PIPELINE-SPEC.md's own Gotchas table, is exactly the
#   failure mode a second implementation invites.
#
#   GIT_DIR, if given, is an existing local clone of REPO to fetch
#   origin/main into and run the reservation against — its checked-out
#   branch and working tree are never read or written, only
#   `fetch`/`show`/`rev-parse` against `origin/main` and whatever
#   reserve-tech-debt-id.pl itself does (fetch, commit-tree, push refs;
#   never a checkout). Omitted, a throwaway directory is created and torn
#   down — the Enabler's own case, which holds no clone of anything.
#
#   The filing commit itself never touches a working tree, on GIT_DIR or
#   otherwise: the new branch and its one file are written purely through
#   the API (POST .../git/refs, then PUT .../contents/<path>), the same
#   no-clone primitive lib/claim.sh's own do_claim_branch/registry_put
#   already use for every other one-off write this pipeline makes without a
#   working checkout — safe regardless of what GIT_DIR happens to be
#   checked out to.
#
#   Invariant: td-record/<id> and its td/<id> reservation survive this
#   function's own return only alongside the filing pull request that makes
#   them reachable. Every failure after the id is reserved — the base-sha
#   lookup, the branch-create call, the contents-write call, and `gh pr
#   create` itself — deletes td-record/<id> and releases td/<id> before
#   returning 1 (_techdebt_unfile), rather than leaving either behind
#   unreachable from any pull request, open or closed
#   (agent-ops TD-PPagop-26082203). A pull request that opens successfully
#   and is later closed without merging is not a failure of this function
#   and is out of its scope — TECH-DEBT.md's "Filing an item" releases that
#   reservation by deleting the branch, the same way an abandoned claim
#   does.
#
#   _techdebt_unfile's own deletes are themselves best-effort against a
#   GitHub API this function has often just seen fail: a delete that cannot
#   land here writes a durable marker instead of simply logging and
#   swallowing the failure (TD-PPagop-26082427), so
#   scripts/release-pending-reservations.sh's later, independent pass can
#   retry it on some future cycle. Reads the cycle's own `state_repo` global
#   (agent-cycle.sh sources every lib/*.sh into one process, #771); a caller
#   with no `state_repo` set — including this file sourced standalone, as
#   the test suite does — simply gets no durable fallback, same as
#   `lib/claim.sh`'s own registry when `state_repo` is unset.
#
# TOKEN, given to either function, files under that identity
# (GH_TOKEN="$TOKEN") rather than the ordinary pipeline login — the
# Approver's own posture never writes to GitHub under the pipeline's own
# account, so its calls always pass the Approver App token already minted
# for posting its review (lib/approver-token.sh). The Enabler has no
# App identity of its own and always omits TOKEN, filing under the ordinary
# pipeline login exactly as create_escalation_issue already does.

# _techdebt_gh TOKEN ARGS...
# Run `gh` ARGS..., under TOKEN's identity if non-empty, the ordinary
# pipeline login otherwise — explicitly unset for that call (`env -u
# GH_TOKEN`), never merely left alone, so a GH_TOKEN this process happened to
# inherit from its own environment can never leak into a call this function
# was asked to make under the ordinary login.
_techdebt_gh() {
  local token="$1"; shift
  if [[ -n "$token" ]]; then
    GH_TOKEN="$token" gh "$@"
  else
    env -u GH_TOKEN gh "$@"
  fi
}

# _techdebt_err_log
# Where diagnostics from either function land — cycle_dir when the caller
# has one (both stages do by the time either function is ever called), /tmp
# as a last resort so a stray call from a test or a future caller with no
# cycle_dir still has somewhere to put stderr rather than losing it.
_techdebt_err_log() {
  printf '%s' "${cycle_dir:-/tmp}/tech-debt-file.err"
}

# _techdebt_yaml_scalar VALUE
# A double-quoted YAML scalar safe for a frontmatter value that may contain
# a colon, a quote, or (defensively) a newline a model should never have
# produced for a one-line title but this must not choke on either way.
_techdebt_yaml_scalar() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//$'\n'/ }"
  printf '"%s"' "$v"
}

# techdebt_file_issue REPO ITEM_REF TITLE BODY_FILE [TOKEN]
techdebt_file_issue() {
  local repo="$1" item_ref="$2" title="$3" body_file="$4" token="${5:-}"
  local existing raw url number errlog
  errlog="$(_techdebt_err_log)"
  existing="$(_techdebt_gh "$token" issue list -R "$repo" --state open --search "$item_ref" \
                --json number,url,body 2>>"$errlog" \
              | jq -r --arg it "$item_ref" \
                  'map(select(((.body // "") | contains($it)))) | first
                   | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi
  raw="$(_techdebt_gh "$token" issue create -R "$repo" --title "$title" --body-file "$body_file" \
           2>>"$errlog" || true)"
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  [[ -n "$url" ]] || return 1
  number="${url##*/}"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$number" "$url"
}

# _techdebt_pending_release_path REPO BRANCH -> path inside the state repo
# Mirrors lib/claim.sh's own `claims/<repo>/<key>.json` convention
# (registry_path) without sourcing that file: this tree is a distinct
# namespace, `reservation-releases/`, so a listing of one can never be
# mistaken for the other.
_techdebt_pending_release_path() {
  printf 'reservation-releases/%s/%s.json' "${1//\//__}" "${2//\//__}"
}

# _techdebt_record_pending_release REPO BRANCH ERRLOG
# Durable fallback for a DELETE _techdebt_unfile could not make land
# (TD-PPagop-26082427): write a marker into the state repository's
# `reservation-releases/` tree so scripts/release-pending-reservations.sh's
# later, independent pass can retry the same delete on some future cycle
# without depending on this failed engagement, or anything downstream of it,
# ever running again. Always under the ordinary pipeline login, never
# TOKEN — TOKEN, when this call carries one, is the Approver's own App
# token, minted only against the repository whose pull request it is
# reviewing (lib/approver-token.sh) and never against the state repository,
# so a write under it here would silently fail every time an Approver
# engagement is the one cleaning up. Best-effort and silent on its own
# failure, like every other registry write in this pipeline: a marker this
# call cannot land is still recoverable by a human running `git push origin
# --delete <branch>` by hand, the same fallback TECH-DEBT.md already
# documents for a stuck reservation.
_techdebt_record_pending_release() {
  local repo="$1" branch="$2" errlog="$3"
  [[ -n "${state_repo:-}" ]] || return 0
  local body payload
  body="$(jq -nc --arg repo "$repo" --arg branch "$branch" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{repo: $repo, branch: $branch, ts: $ts}')"
  payload="$(printf '%s' "$body" | base64 -w0)"
  _techdebt_gh "" api -X PUT \
    "repos/$state_repo/contents/$(_techdebt_pending_release_path "$repo" "$branch")" \
    -f "message=reservation release pending: $branch" -f "content=$payload" \
    >/dev/null 2>>"$errlog" || true
}

# _techdebt_release_ref TOKEN REPO BRANCH ERRLOG
# One best-effort branch delete, made durable. A DELETE that fails is not
# necessarily a leak: it can fail because BRANCH was never there to begin
# with — the ordinary case for td-record/<ID> whenever the failure that sent
# techdebt_file_debt down this path happened at or before its own
# branch-create call — and a marker for a branch that does not exist would
# send scripts/release-pending-reservations.sh chasing nothing forever. So a
# failed DELETE is followed by one direct question: does BRANCH still exist?
# A confirmed "no" (an HTTP 404 on the ref itself) needs no marker. Anything
# else — a confirmed "yes", or the confirmation call itself failing, which
# answers nothing either way — is treated the same, fail-closed: recording a
# marker for a branch that turns out already gone costs one wasted retry
# that clears its own marker (release-pending-reservations.sh's own "already
# absent" case, below), while skipping the marker on a confirmation this
# call could not actually get would leave exactly the silent gap this
# function exists to close.
_techdebt_release_ref() {
  local token="$1" repo="$2" branch="$3" errlog="$4"
  local get_err get_rc
  _techdebt_gh "$token" api -X DELETE "repos/$repo/git/refs/heads/$branch" \
    >/dev/null 2>>"$errlog" && return 0
  # `&& get_rc=0 || get_rc=$?`, never a bare assignment followed by
  # `get_rc=$?`: this file is sourced into agent-cycle.sh, which runs under
  # `set -e`, where an assignment whose command substitution fails aborts the
  # caller outright — and the 404 this call exists to detect *is* a failure.
  # An abort here would skip the `td/<id>` delete `_techdebt_unfile` makes
  # straight after, leaking exactly the reservation this function exists to
  # keep. The same idiom, for the same reason, as lib/github-limit.sh's own
  # `gh` wrapper.
  get_err="$(_techdebt_gh "$token" api "repos/$repo/git/ref/heads/$branch" 2>&1 >/dev/null)" \
    && get_rc=0 || get_rc=$?
  if (( get_rc == 0 )) || [[ "$get_err" != *"HTTP 404"* ]]; then
    [[ -n "$get_err" ]] && printf '%s\n' "$get_err" >>"$errlog"
    _techdebt_record_pending_release "$repo" "$branch" "$errlog"
  fi
  return 0
}

# _techdebt_unfile TOKEN REPO ID ERRLOG
# Undo whatever a half-finished techdebt_file_debt has already written to
# GitHub: the td-record/<ID> branch, where the branch-create call got that
# far, and the td/<ID> reservation reserve-tech-debt-id.pl pushed before it.
# Nothing else ever will — td-record/ is not a prefix
# scripts/sweep-orphan-branches.sh sweeps at all, and a bare td/<ID>
# carrying only its reservation commit is one it deliberately leaves alone
# (issue #545) — so a branch a first attempt here cannot release is left for
# scripts/release-pending-reservations.sh's later pass, via
# _techdebt_release_ref's own durable marker (TD-PPagop-26082427), rather
# than left for good (agent-ops TD-PPagop-26082203).
#
# The record branch goes first and the reservation last, never the other way
# round: releasing the id while td-record/<ID> still existed would let a
# later reservation hand that id out again and then fail its own
# branch-create against the ref this call left behind.
#
# Best-effort throughout — a delete this call cannot make land is never
# raised as a second failure of its own.
_techdebt_unfile() {
  local token="$1" repo="$2" id="$3" errlog="$4"
  _techdebt_release_ref "$token" "$repo" "td-record/$id" "$errlog"
  _techdebt_release_ref "$token" "$repo" "td/$id" "$errlog"
}

# techdebt_file_debt REPO TITLE BODY PROVENANCE [TOKEN] [GIT_DIR] [PR_LABEL]
techdebt_file_debt() {
  local repo="$1" title="$2" body="$3" provenance="$4" token="${5:-}" git_dir="${6:-}" \
        pr_label="${7:-autonomous-agent}"
  local made_dir=0 id base_sha branch record_file reserve_script content \
        pr_body_file pr_url errlog

  errlog="$(_techdebt_err_log)"

  if [[ -z "$git_dir" ]]; then
    git_dir="$(mktemp -d)" || return 1
    made_dir=1
    if ! { git -C "$git_dir" init -q \
             && git -C "$git_dir" remote add origin "https://github.com/$repo.git"; } \
           2>>"$errlog"; then
      (( made_dir )) && rm -rf "$git_dir"
      return 1
    fi
  fi

  if ! git -C "$git_dir" fetch -q origin main 2>>"$errlog"; then
    (( made_dir )) && rm -rf "$git_dir"
    return 1
  fi

  reserve_script="$(mktemp)"
  if ! git -C "$git_dir" show origin/main:scripts/reserve-tech-debt-id.pl \
        > "$reserve_script" 2>>"$errlog"; then
    rm -f "$reserve_script"
    (( made_dir )) && rm -rf "$git_dir"
    return 1
  fi

  id="$( (cd "$git_dir" && perl "$reserve_script") 2>>"$errlog")"
  rm -f "$reserve_script"
  if [[ -z "$id" ]]; then
    (( made_dir )) && rm -rf "$git_dir"
    return 1
  fi

  base_sha="$(git -C "$git_dir" rev-parse origin/main 2>/dev/null || true)"
  if [[ -z "$base_sha" ]]; then
    _techdebt_unfile "$token" "$repo" "$id" "$errlog"
    (( made_dir )) && rm -rf "$git_dir"
    return 1
  fi

  branch="td-record/$id"
  record_file="tech-debt/$id.md"
  content="$(techdebt_record_body "$id" "$title" "$body" "$provenance")"

  if ! _techdebt_gh "$token" api -X POST "repos/$repo/git/refs" \
        -f "ref=refs/heads/$branch" -f "sha=$base_sha" >/dev/null 2>>"$errlog"; then
    _techdebt_unfile "$token" "$repo" "$id" "$errlog"
    (( made_dir )) && rm -rf "$git_dir"
    return 1
  fi

  if ! _techdebt_gh "$token" api -X PUT "repos/$repo/contents/$record_file" \
        -f "message=chore(tech-debt): file $id" \
        -f "content=$(base64 -w0 <<<"$content")" \
        -f "branch=$branch" >/dev/null 2>>"$errlog"; then
    _techdebt_unfile "$token" "$repo" "$id" "$errlog"
    (( made_dir )) && rm -rf "$git_dir"
    return 1
  fi

  pr_body_file="$(mktemp)"
  # shellcheck disable=SC2016 # the backtick around %s is literal Markdown, not code
  printf 'Filed by the autonomous pipeline; see `%s`.\n\n%s\n' "$record_file" "$provenance" \
    > "$pr_body_file"
  pr_url="$(_techdebt_gh "$token" pr create -R "$repo" --base main --head "$branch" \
              --title "chore(tech-debt): file $id — $title" --body-file "$pr_body_file" \
              --label "$pr_label" \
              2>>"$errlog" || true)"
  rm -f "$pr_body_file"

  if [[ -z "$pr_url" ]]; then
    # The one failure point past which both writes have already landed: the
    # record commit is on td-record/<id> and the id is locked on td/<id>,
    # but no pull request will ever carry either one.
    _techdebt_unfile "$token" "$repo" "$id" "$errlog"
    (( made_dir )) && rm -rf "$git_dir"
    return 1
  fi

  (( made_dir )) && rm -rf "$git_dir"

  printf '%s\t%s' "$id" "$pr_url"
}

# techdebt_record_body ID TITLE BODY PROVENANCE
# The frontmatter+body TECH-DEBT.md's "Filing an item" describes, `filed:`
# derived from ID's own date component (never the host clock) so the two
# can never disagree regardless of the container's timezone.
techdebt_record_body() {
  local id="$1" title="$2" body="$3" provenance="$4"
  local datepart yy mm dd
  datepart="${id##*-}"
  yy="${datepart:0:2}" mm="${datepart:2:2}" dd="${datepart:4:2}"
  printf -- '---\nid: %s\ntitle: %s\nstatus: open\nfiled: 20%s-%s-%s\n---\n\n%s\n\nNoticed %s.\n' \
    "$id" "$(_techdebt_yaml_scalar "$title")" "$yy" "$mm" "$dd" "$body" "$provenance"
}
