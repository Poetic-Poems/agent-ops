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
# techdebt_file_issue REPO ITEM_REF TITLE BODY_FILE [TOKEN] [DEFAULT_FIX] \
#                      [OWNER_DECISION]
#   Files one plain GitHub issue, or returns an existing one that already
#   covers ITEM_REF. No label or assignee — unlike an escalation
#   (create_escalation_issue) this is not addressed at a specific human and
#   is legitimate autonomous work for a later cycle to pick up, not a
#   request excluded from the `issues` source. Prints "<number>\t<url>" on
#   success; prints nothing and returns 1 otherwise.
#
#   DEFAULT_FIX/OWNER_DECISION (agent-ops#938): see techdebt_default_section
#   below for what they add to the filed body, and pw::owner-decision for
#   what OWNER_DECISION additionally applies here — a fresh issue only; the
#   dedup hit above returns the existing issue untouched, label included. A
#   refused labelled create is retried once without the label, so a repository
#   that has not had `pw::owner-decision` ensured yet still gets its issue.
#
# techdebt_file_debt REPO TITLE BODY PROVENANCE [TOKEN] [DEFAULT_FIX] \
#                     [OWNER_DECISION]
#   Files TITLE/BODY as a GitHub issue in REPO labelled `pw::type:tech-debt`
#   (D15 as revised, agent-ops#869/#872/#874) — the same trust anchor
#   scripts/gather-tech-debt.sh reads to serve the band, and the one
#   `lib/labels.sh` ensures exists in every target repository. Deduped first
#   against REPO's own open `pw::type:tech-debt` issues by normalised title
#   (_techdebt_title_dedup_match, below): a match gets BODY/PROVENANCE as a
#   comment instead of a second filing, the same "don't file a duplicate"
#   outcome TECH-DEBT.md's "Filing alongside other work" always asked of a
#   human filer, now applied automatically here. Prints "<number>\t<url>" on
#   success — the new issue's, or the matched one's — and prints nothing and
#   returns 1 otherwise.
#
#   Retired by this move (agent-ops#874): the `td/<id>` reservation
#   (scripts/reserve-tech-debt-id.pl), the `td-record/<id>` filing branch,
#   the filing pull request, and `_techdebt_unfile`'s rollback of both —
#   filing is now the one API call techdebt_file_issue already makes for a
#   plain issue, plus the label and the dedup rule above. There is no
#   multi-step write left to half-finish, so there is no cleanup path either:
#   a create either succeeds or it doesn't, and a repository that does not
#   yet carry `pw::type:tech-debt` (the label-ensure pass has not reached it
#   yet) gets one retry without the label rather than a lost filing — logged
#   to errlog so the archive mirror's audit can flag the unlabelled issue for
#   reconciliation, the same shape techdebt_file_issue's own
#   `pw::owner-decision` retry already has.
#
# TECHDEBT_RECORD_BRANCH_PREFIX — no longer minted by this file
# (agent-ops#874 retired techdebt_file_debt's own td-record/<id> branch), but
# kept here as a constant rather than deleted: scripts/sweep-orphan-branches.sh
# and scripts/publish-tech-debt-archive.sh both source this file for it, to
# sweep and audit any td-record/<id> branch/pull request a pre-#874 filing
# already left behind, in a target repository this pipeline still gathers
# from. Deleting the constant would break both scripts' own sourcing rather
# than the (now dormant) minting it used to name.
# shellcheck disable=SC2034  # read by scripts/sweep-orphan-branches.sh and scripts/publish-tech-debt-archive.sh, which source this file for it
readonly TECHDEBT_RECORD_BRANCH_PREFIX="td-record/"

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

# techdebt_default_section DEFAULT_FIX [OWNER_DECISION]
# The `## Default` section every filed body carries (agent-ops#938): the
# option the filer would take (DEFAULT_FIX, one sentence), or `not stated`
# when the filer's verdict carried neither DEFAULT_FIX nor an OWNER_DECISION
# of exactly "true" — a malformed verdict is filed anyway rather than lost,
# so the caller (lib/approver.sh, lib/enabler.sh) logs the warning that
# distinguishes this fallback from a genuine, single-option filing that never
# needed a default at all. OWNER_DECISION "true" adds `Owner decision: yes`
# on its own line beside the heading — techdebt_file_issue applies the
# `pw::owner-decision` label instead, since a label, not body text, is what a
# later gatherer can trust (lib/labels.sh's own comment on why
# `pw::type:tech-debt` is a label and not a body convention applies here
# identically). Ends with a trailing newline so a caller can concatenate it
# straight onto a body that may or may not already end with one.
techdebt_default_section() {
  local default_fix="$1" owner_decision="${2:-false}" heading
  if [[ -n "$default_fix" ]]; then
    heading="## Default: $default_fix"
  else
    heading="## Default: not stated"
  fi
  if [[ "$owner_decision" == "true" ]]; then
    printf '%s\nOwner decision: yes\n' "$heading"
  else
    printf '%s\n' "$heading"
  fi
}

# techdebt_file_issue REPO ITEM_REF TITLE BODY_FILE [TOKEN] [DEFAULT_FIX] \
#                      [OWNER_DECISION]
techdebt_file_issue() {
  local repo="$1" item_ref="$2" title="$3" body_file="$4" token="${5:-}" \
        default_fix="${6:-}" owner_decision="${7:-false}"
  local existing raw url number errlog body_content combined_file label_args=()
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
  body_content="$(cat "$body_file" 2>/dev/null || true)"
  combined_file="$(mktemp)"
  # OWNER_DECISION omitted from techdebt_default_section here, deliberately:
  # for an issue, the `pw::owner-decision` label below is what a later
  # gatherer trusts, the same reason `pw::type:tech-debt` is a label and not
  # a body convention — the body stays untrusted data even though this
  # filing call is itself trusted (lib/labels.sh's own comment).
  printf '%s\n\n%s' "$body_content" "$(techdebt_default_section "$default_fix")" \
    > "$combined_file"
  [[ "$owner_decision" == "true" ]] && label_args=(--label pw::owner-decision)
  raw="$(_techdebt_gh "$token" issue create -R "$repo" --title "$title" --body-file "$combined_file" \
           "${label_args[@]}" 2>>"$errlog" || true)"
  # One retry without the label, exactly as requirement 36a's escalation
  # contract and create_escalation_issue (lib/enabler.sh) already do: `gh`
  # resolves a label name to an id as part of the create, so a repository that
  # has not had `pw::owner-decision` ensured yet fails the whole create and the
  # filing is lost — the one outcome agent-ops#938 exists to prevent, and the
  # failure class agent-ops#1009 already records for this file's own
  # `gh pr create --label`. Losing the label costs the Refiner its marker (the
  # issue reads to a later pass as a legacy no-marker item); losing the create
  # costs the filing itself.
  if [[ -z "$raw" && ${#label_args[@]} -gt 0 ]]; then
    raw="$(_techdebt_gh "$token" issue create -R "$repo" --title "$title" \
             --body-file "$combined_file" 2>>"$errlog" || true)"
  fi
  rm -f "$combined_file"
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  [[ -n "$url" ]] || return 1
  number="${url##*/}"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$number" "$url"
}

# _techdebt_normalize_title TITLE
# Lower-cased, punctuation folded to spaces, runs of whitespace collapsed —
# the same algorithm scripts/find-similar-tech-debt.sh's own normalize()
# uses for the register's `tech-debt/*.md` files. Reimplemented here rather
# than sourced from there because the two read different data (a local
# register vs REPO's live GitHub Issues) for the same "is this title already
# tracked" question; find-similar-tech-debt.sh stays the tool for this
# repository's own register (still per-item — see TECH-DEBT.md), never
# called by this file.
_techdebt_normalize_title() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# _techdebt_title_dedup_match NEEDLE LIST_JSON
# NEEDLE is an already-normalized title; LIST_JSON is a JSON array of
# `{number, url, title}`. Prints the `number` of the first entry whose own
# normalized title equals NEEDLE, or — both at least eight normalized
# characters, mirroring find-similar-tech-debt.sh's own containment floor so
# a short, generic title cannot match by containment inside an unrelated
# long one — contains it or is contained by it. Prints nothing on no match.
_techdebt_title_dedup_match() {
  local needle="$1" list_json="$2" allow_contains=0 hay number title
  [[ ${#needle} -ge 8 ]] && allow_contains=1
  while IFS=$'\t' read -r number title; do
    [[ -n "$number" ]] || continue
    hay="$(_techdebt_normalize_title "$title")"
    [[ -n "$hay" ]] || continue
    if [[ "$hay" == "$needle" ]]; then
      printf '%s' "$number"
      return 0
    fi
    if (( allow_contains )) && [[ ${#hay} -ge 8 ]] \
       && [[ "$hay" == *"$needle"* || "$needle" == *"$hay"* ]]; then
      printf '%s' "$number"
      return 0
    fi
  done < <(jq -r '.[] | [.number, .title] | @tsv' <<<"$list_json" 2>/dev/null)
}

# techdebt_file_debt REPO TITLE BODY PROVENANCE [TOKEN] [DEFAULT_FIX] \
#                     [OWNER_DECISION]
techdebt_file_debt() {
  local repo="$1" title="$2" body="$3" provenance="$4" token="${5:-}" \
        default_fix="${6:-}" owner_decision="${7:-false}"
  local errlog needle list match_number match_url combined_file raw url number
  errlog="$(_techdebt_err_log)"

  needle="$(_techdebt_normalize_title "$title")"
  if [[ -n "$needle" ]]; then
    list="$(_techdebt_gh "$token" issue list -R "$repo" --label pw::type:tech-debt \
              --state open --json number,url,title 2>>"$errlog" || true)"
    if jq -e 'type == "array"' <<<"$list" >/dev/null 2>&1; then
      match_number="$(_techdebt_title_dedup_match "$needle" "$list")"
      if [[ -n "$match_number" ]]; then
        match_url="$(jq -r --argjson n "$match_number" \
          'map(select(.number == $n)) | first | .url // empty' <<<"$list" 2>/dev/null || true)"
        combined_file="$(mktemp)"
        printf '%s\n\n%s\n%s\n' "$body" "$(techdebt_default_section "$default_fix" "$owner_decision")" \
          "$provenance" > "$combined_file"
        _techdebt_gh "$token" issue comment "$match_number" -R "$repo" \
          --body-file "$combined_file" >/dev/null 2>>"$errlog" || true
        rm -f "$combined_file"
        printf 'techdebt_file_debt: %s title matches open issue #%s -- commented instead of filing\n' \
          "$repo" "$match_number" >>"$errlog"
        printf '%s\t%s' "$match_number" "$match_url"
        return 0
      fi
    fi
  fi

  combined_file="$(mktemp)"
  printf '%s\n\n%s\n%s\n' "$body" "$(techdebt_default_section "$default_fix" "$owner_decision")" \
    "$provenance" > "$combined_file"
  raw="$(_techdebt_gh "$token" issue create -R "$repo" --title "$title" \
           --body-file "$combined_file" --label pw::type:tech-debt 2>>"$errlog" || true)"
  # A repository whose `pw::type:tech-debt` label the ensure pass (lib/labels.sh)
  # has not reached yet fails the whole labelled create -- `gh` resolves a
  # label name to an id as part of it -- so this is retried once unlabelled
  # rather than losing the filing, exactly as techdebt_file_issue's own
  # `pw::owner-decision` retry above. Logged so the archive mirror's audit can
  # flag the unlabelled issue for reconciliation once the label does exist.
  if [[ -z "$raw" ]]; then
    printf 'techdebt_file_debt: labelled issue create failed for %s -- retrying unlabelled\n' \
      "$repo" >>"$errlog"
    raw="$(_techdebt_gh "$token" issue create -R "$repo" --title "$title" \
             --body-file "$combined_file" 2>>"$errlog" || true)"
  fi
  rm -f "$combined_file"
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  [[ -n "$url" ]] || return 1
  number="${url##*/}"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$number" "$url"
}
