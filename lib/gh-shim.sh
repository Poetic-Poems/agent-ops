#!/usr/bin/env bash
#
# lib/gh-shim.sh — the logic behind `scripts/gh-shim.sh`, the `gh` transport
# seam installed on `PATH` ahead of the real binary (agent-ops#1084), and,
# since agent-ops#1021, the front door for the forge authoring App's
# on-demand credential seam as well (D18 decision 1 as amended): every `gh`
# call reaches `gh_shim_resolve_token` (below) before this file's
# classification and transport logic ever runs, and `git`'s own credential
# helper (`!gh auth git-credential`, `deploy/docker/entrypoint.sh`) resolves
# through `PATH` to this same shim, so both front doors mint through the one
# resolver. See `gh_shim_resolve_token`'s own header for the mechanics.
#
# Which of that App's installations a given call mints against is
# `gh_shim_target_owner`'s answer for that call (agent-ops#913's per-owner
# map, applied to the authoring identity): a GitHub App installation is per
# account, and this fleet's repositories span two of them, so one token
# cannot back every call. See `gh_shim_target_owner`'s own header for how an
# owner is recovered from an invocation whose argv this file does not write.
#
# ## Why a `PATH` shim, not another library wrapper
#
# `lib/github-limit.sh` already shadows `gh` for every script that sources
# it, but that reach stops at the shell: the Co-Ordinator, Implementer,
# Reviewer, Enabler and Refiner stages are `claude -p` subprocesses, and every
# `gh` call the *model* makes inside one of them never goes near a sourced
# bash function — prompts/reviewer.md alone names `gh` 25 times. A `PATH`
# shim is the one seam wide enough to cover both: `command gh` (the retry
# wrapper's own call, `lib/repo-clone.sh`'s stub seam, every script's `gh …`)
# and a model's bare `gh …` invocation resolve through the same `PATH`
# lookup, so installing this ahead of the real binary (Dockerfile) catches
# both without editing either.
#
# ## What this does, and does not, touch
#
# Only a plain `gh api <endpoint>` **GET** — no `-X`/`--method` other than
# GET, no `-f`/`-F`/`--raw-field`/`--field`/`--input` (gh's own rule: any of
# those switches the default method to POST), not the literal `graphql`
# endpoint, and not a call that already asks for `-i`/`--include` itself — is
# ever conditioned, and a `--paginate`/`--slurp` call not even that (see the
# scope limit below; it is still stored and still ledgered). Everything else
# (`gh pr view`, `gh issue list`, a write, the `graphql` endpoint of `gh api`,
# a caller already reading raw headers) is passed
# to the real binary completely unmodified: same argv, same stdout, same
# stderr, same exit status. `gh_shim_classify` is the one place that decision
# is made; see its own header for why each case is excluded.
#
# No pathway here ever reshapes what the real binary printed. A conditioned
# read is the only one whose argv this file adds to at all, and what it hands
# back on stdout is byte-for-byte the body a plain call would have printed.
#
# The already-asks-for-`-i` exclusion matters most for
# `github_limit_snapshot`'s own probe (`command gh api -i "$GITHUB_LIMIT_PROBE_PATH"`,
# lib/github-limit.sh) — which, once this shim sits ahead of the real binary
# on `PATH`, is a call *through* this file. That probe's entire job is to
# read the bucket's live headers, and serving it a cached or last-known-good
# reading on a refusal would feed a stale `x-ratelimit-remaining` straight
# into the exhaustion check requirement 2.0 makes from it — turning a real
# refusal into a false "ok". So a caller that names `-i`/`--include` itself
# always reaches the network for real; this file only ever synthesises
# headers for a caller that never asked to see any.
#
# ## The three properties (requirement 2.0e)
#
# 1. **Conditional reads.** A cacheable GET is retried with the stored
#    `ETag` as `If-None-Match`; a `304` is served from the cache with exit 0,
#    identical to what the caller would have seen from a `200` — GitHub's own
#    guidance is that this does not count against the primary limit.
# 2. **Last-known-good under a refusal.** A primary rate-limit 403
#    (`github_limit_kind` — the same detector requirement 2.0a's retry
#    wrapper uses, reused rather than re-implemented so the two can never
#    recognise a refusal differently) or a 5xx, with a stored body still
#    inside `PW_GH_STALE_CEILING_SECONDS`, is served from the cache with a
#    `PW_GH_CACHE=stale age=<s>` line on stderr and exit
#    `PW_GH_STALE_EXIT_CODE` (default 0, so an ordinary reader degrades
#    gracefully; a caller that must not act on stale data sets this to a
#    distinguishable code and checks for it).
# 3. **Ledger and budget.** Every call this file classifies logs one line to
#    `state_dir/gh-shim/ledger.ndjson` — `{ts, method, path, status, cache:
#    hit|miss|stale|bypass, resource, used}` — and a cacheable GET that
#    yielded ratelimit headers updates `state_dir/gh-shim/budget.json`,
#    keyed by identity (the App and the PAT can legitimately see different
#    data, so their readings never overwrite each other).
#
# A write invalidates the cached reads it feeds: on any `gh api` call whose
# method resolves to non-GET and which the real binary answered 2xx, every
# cache entry for the same identity whose stored path equals the write's own
# path, or equals that path with its last `/`-segment removed (the "one
# level up" resource — a review POST to `.../pulls/5/reviews` drops both that
# listing and `.../pulls/5` itself), is dropped. This is a heuristic, not a
# semantic model of the API: it matches the one example agent-ops#1084 gives
# and nothing more specific than "the write's own resource, and its parent".
#
# ## Known scope limit: `--paginate`/`--slurp` (agent-ops#1114)
#
# `gh api --paginate` fetches every page inside one real-binary invocation,
# each with its own `ETag`. Conditioning the *first* page's request would be
# unsound — a stale `If-None-Match` sent uniformly to every page could 304 a
# page whose content actually changed — so a paginated call is never sent a
# conditional header at all: it always reaches the network in full. Per-page
# conditioning is filed as tech debt rather than built here (agent-ops#1114)
# — it needs the shim to drive pagination itself rather than delegate it to
# the real binary in one call, which is a materially larger change than the
# rest of this file.
#
# It is also the one read shape this file must not add `-i` to, which is why
# it has a pathway of its own (`gh_shim_handle_paginate`) rather than sharing
# the cacheable-GET one. Adding `-i` does not merely prepend headers there —
# it changes the document `gh` prints:
#
#   * plain `--paginate` *merges* a paginated array response into one JSON
#     array; with `-i` it emits one complete array per page instead, so a
#     caller reading `gh api --paginate <path>` would get N documents where
#     the real binary gives it one;
#   * `--slurp` prints its opening `[` *ahead of* the first status line
#     (`[HTTP/2.0 200 OK`), so the response cannot be split on a status-line
#     anchor at all.
#
# So a paginated call is handed to the real binary with the caller's own argv
# untouched and its stdout passed through byte for byte. Its response is
# still stored, so property 2 (last-known-good) still applies to it, and it is
# still ledgered (property 3); only property 1 (the 304 saving) does not
# apply. Nothing here is allowed to reshape what the real binary printed.
#
# ## Files under `state_dir/gh-shim/`
#
#   http-cache/<key>.json   {identity, path, etag, fetched_at, body} — one
#                           file per (identity, full argv) cache key, written
#                           via a temp file and `mv -f` so a reader never sees
#                           a partial write.
#   ledger.ndjson           the per-call ledger, appended under `flock`.
#                           Rotated by `scripts/rotate-logs.sh` like the
#                           node's other diagnostic logs — unlike
#                           `log.jsonl`, nothing here is load-bearing for a
#                           pipeline decision, so bounding its size costs
#                           only some reporting history.
#   budget.json             the latest `{limit, used, remaining, reset}` per
#                           identity, `core` only — a cacheable GET is the
#                           only call this file adds headers to, and every
#                           one of those reads `core`, never `graphql` (the
#                           `graphql` endpoint of `gh api` is always
#                           excluded, see above).
#
# Sourced, never executed — `scripts/gh-shim.sh` is the thin executable
# entry point installed on `PATH`. Requires `lib/github-limit.sh` to already
# be sourced (it is, immediately below) for `github_limit_kind` and
# `github_limit_headers_to_resource`.
#
# Environment (test seams and operator knobs, all optional):
#   PW_GH_REAL_BIN               the real `gh` binary this shim calls through
#                                 to. Default /usr/bin/gh (where the image's
#                                 apt-installed `gh` lives). Tests point this
#                                 at a stub.
#   PW_GH_STATE_DIR               state_dir/gh-shim's parent — i.e. this
#                                 file's own state lives at
#                                 "$PW_GH_STATE_DIR/gh-shim". Default
#                                 "$HOME/.local/state/poetic-agents", the
#                                 product's own state_dir default; both
#                                 cycle scripts export the resolved
#                                 config.json state_dir here so a customised
#                                 value still reaches every subprocess,
#                                 model-driven calls included.
#   PW_GH_NO_CACHE                "1" skips all caching machinery for this one
#                                 call — pure passthrough, still ledgered as
#                                 "bypass".
#   PW_GH_STALE_CEILING_SECONDS   how old a cached body may be and still be
#                                 served under a refusal. Default 3600.
#   PW_GH_STALE_EXIT_CODE         the exit code a served last-known-good
#                                 answer returns. Default 0.
#   PW_GH_DEGRADE_TOKEN           the credential seam's fallback (owned and
#                                 documented in lib/forge-auth.sh):
#                                 deploy/docker/entrypoint.sh stashes the
#                                 node's ambient PAT here when the forge
#                                 authoring App is configured. Read only when
#                                 GH_TOKEN is empty and no App token could be
#                                 minted.
#   PW_GH_NOW_EPOCH               test seam only: the clock
#                                 gh_shim_resolve_token mints against, in
#                                 place of the real one, so a test can
#                                 advance past a minted token's expiry
#                                 without waiting on it.

# Computed inline, not kept in a variable: this file is sourced, and a
# top-level `SCRIPT_DIR="..."` here would clobber whatever the sourcing
# script (or a test) already keeps under that same common name.
# shellcheck source=lib/github-limit.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-limit.sh"
# shellcheck source=lib/author-token.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/author-token.sh"

# GH_SHIM_STDIN_FILE
# Set by gh_shim_main, and only for `gh auth git-credential`: the path of the
# file this invocation's stdin was buffered into before anything read it, so
# gh_shim_target_owner can name the repository `git` is asking a credential
# for. Empty for every other call shape — nothing else here ever reads the
# caller's stdin, which would break `gh api --input -`.
GH_SHIM_STDIN_FILE=""

# _gh_shim_owner_valid NAME
# True (exit 0) iff NAME is shaped like a GitHub account name. Everything
# below routes its answer through here, so a parse that went wrong on some
# argv shape this file has never seen yields *no owner* — which resolves to
# the scalar default installation, the pre-agent-ops#913 behaviour — rather
# than a nonsense owner that would resolve nowhere and degrade a perfectly
# well-configured node to its PAT.
_gh_shim_owner_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# gh_shim_owner_from_url SPEC
# The owner named by a **github.com URL**, or nothing at all. Pure. Accepts
# the web form (`https://github.com/OWNER/REPO`, with or without a `.git`
# suffix or a trailing `/pull/5`) and the two SSH remote forms
# `git remote get-url origin` can print. A URL on any other host prints
# nothing: this identity is a github.com App, and minting for a GitLab
# remote's "owner" would be meaningless.
#
# Kept apart from gh_shim_owner_from_spec below because a URL is *always* a
# repository — nothing else in a `gh` argv is shaped like one — whereas a
# bare `owner/repo` is ambiguous with a branch name, and so is only read as a
# repository where `gh` itself would read it as one.
gh_shim_owner_from_url() {
  local spec="${1:-}" rest owner
  [[ -n "$spec" ]] || return 0
  spec="${spec%/}"
  case "$spec" in
    https://github.com/*)     rest="${spec#https://github.com/}" ;;
    http://github.com/*)      rest="${spec#http://github.com/}" ;;
    https://www.github.com/*) rest="${spec#https://www.github.com/}" ;;
    http://www.github.com/*)  rest="${spec#http://www.github.com/}" ;;
    git@github.com:*)         rest="${spec#git@github.com:}" ;;
    ssh://git@github.com/*)   rest="${spec#ssh://git@github.com/}" ;;
    *)                        return 0 ;;
  esac
  owner="${rest%%/*}"
  _gh_shim_owner_valid "$owner" || return 0
  printf '%s' "$owner"
}

# gh_shim_owner_from_spec SPEC
# The owner named by a repository specifier, or nothing at all. Pure.
# Accepts every shape `gh` itself does for `-R`/`--repo` and for `gh repo`'s
# own positional argument: a github.com URL (as above), `OWNER/REPO`, or
# `HOST/OWNER/REPO`.
#
# The three-segment form requires its first segment to look like a hostname —
# to contain a `.` — because without that check any three-segment path
# (`docs/foo/bar.md`, `a/b/c`) would read its *second* segment as an owner.
# No GitHub account name contains a dot in a position that matters here: the
# host half is what dots belong to.
gh_shim_owner_from_spec() {
  local spec="${1:-}" rest owner
  [[ -n "$spec" ]] || return 0
  owner="$(gh_shim_owner_from_url "$spec")"
  [[ -z "$owner" ]] || { printf '%s' "$owner"; return 0; }
  spec="${spec%/}"
  case "$spec" in
    *://*|*@*:*) return 0 ;;
    */*/*)
      case "${spec%%/*}" in *.*) ;; *) return 0 ;; esac
      rest="${spec#*/}" ;;
    */*) rest="$spec" ;;
    *)   return 0 ;;
  esac
  owner="${rest%%/*}"
  _gh_shim_owner_valid "$owner" || return 0
  printf '%s' "$owner"
}

# gh_shim_owner_from_api_path PATH
# The owner named by a `gh api` endpoint path — `repos/OWNER/…`,
# `orgs/OWNER…` or `users/OWNER…`, with or without a leading slash and with
# any query string ignored — or nothing for a path that names none
# (`rate_limit`, `user`, `meta`, `/installation/repositories`). Pure.
gh_shim_owner_from_api_path() {
  local p owner=""
  p="$(gh_shim_strip_query "${1:-}")"
  p="${p#/}"
  case "$p" in
    repos/*) owner="${p#repos/}" ;;
    orgs/*)  owner="${p#orgs/}" ;;
    users/*) owner="${p#users/}" ;;
    *) return 0 ;;
  esac
  owner="${owner%%/*}"
  _gh_shim_owner_valid "$owner" || return 0
  printf '%s' "$owner"
}

# gh_shim_credential_owner FILE
# The owner named by a buffered `gh auth git-credential` request — git's own
# credential protocol, one `key=value` line per attribute — or nothing. Pure
# (given the file).
#
# `path=OWNER/REPO(.git)` is the attribute that carries it, and git sends it
# only when `credential.https://github.com.useHttpPath` is true, which
# deploy/docker/entrypoint.sh sets beside the helper itself (component 7). A
# request without one simply names no owner here and falls through to the
# rules below, ending at the `origin` remote of whatever work tree git
# invoked the helper from — so an older node whose entrypoint predates that
# setting degrades to the scalar default rather than to nothing.
#
# A `host=` naming anything but github.com prints nothing: the helper is
# wired per host, but a node whose git config gained another one must never
# have a github.com App token offered to it.
gh_shim_credential_owner() {
  local file="${1:-}" line host="" path="" owner
  [[ -n "$file" && -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      host=*) host="${line#host=}" ;;
      path=*) path="${line#path=}" ;;
    esac
  done < "$file"
  case "${host%%:*}" in ""|github.com|www.github.com) ;; *) return 0 ;; esac
  path="${path#/}"
  [[ "$path" == */* ]] || return 0
  owner="${path%%/*}"
  _gh_shim_owner_valid "$owner" || return 0
  printf '%s' "$owner"
}

# gh_shim_target_owner ARGS...
# The GitHub account one `gh` invocation acts against, or nothing at all when
# no rule below names one. Pure: it reads argv, GH_SHIM_STDIN_FILE (already
# buffered by gh_shim_main) and — last of all, only when nothing in argv
# named an owner — the current directory's own `origin` remote. It sets no
# globals and makes no network call.
#
# Why this exists: agent-ops#913's answer for the Approver could take the
# repository slug as a function argument, because every Approver call site
# holds one. This identity's call site is `gh` itself — a `PATH` shim in
# front of a binary whose argv is written by five model-driven stages and
# every script in this repository — so the slug has to be *recovered* from
# the invocation. The rules, in the order they are tried:
#
#   1. `gh auth git-credential` — git's own protocol on stdin, whose
#      `path=` attribute names the repository being pushed to or fetched
#      from. First, because it is the only shape whose argv says nothing at
#      all and whose stdin says everything.
#   2. `-R`/`--repo`, in either the space- or `=`-separated form, anywhere
#      in argv — gh's own explicit override, so it outranks everything else.
#   3. For `gh api`: the endpoint path (`repos/OWNER/…`, `orgs/OWNER…`,
#      `users/OWNER…`), or, for the literal `graphql` endpoint, an
#      `owner=OWNER` field (`-f`/`-F`/`--field`/`--raw-field`) and then a
#      `repository(owner: "OWNER"` literal in the query text.
#   4. For everything else: the first positional argument that is a
#      **github.com URL** (`gh pr view <url>`, `gh issue view <url>`,
#      `gh repo clone <url>`) — and, **only under `gh repo <subcommand>`**
#      (`clone`, `view`, `fork`, `edit`, `sync`, `rename`, …), a bare
#      `OWNER/REPO` or `HOST/OWNER/REPO` as well.
#
#      The `gh repo` restriction is the whole of rule 4's correctness, not a
#      tidiness: a bare `a/b` is exactly as much a *branch name* as a
#      repository, and on this fleet every branch carries a slash
#      (`agent/1051`, `feat/x`, `fix/x`, `docs/x`). The model-driven stages
#      run `gh pr checkout agent/1051`, `gh pr view feat/x` and `gh pr diff
#      docs/x` bare inside a cloned workspace constantly; reading `agent` or
#      `feat` as an owner would resolve to no installation, fall through to
#      the scalar default, and present the wrong organisation's token — a 404
#      at write time, which is the exact failure this whole change exists to
#      prevent. `gh repo` is the one command family whose positional is a
#      repository and never a branch, and a URL can never be a branch under
#      any command, so those two are what rule 4 reads. Everything else falls
#      to rule 5, the `origin` remote — which is what `gh` itself resolves
#      those commands against anyway.
#
#      A flag's *value* is never read as one either: `gh repo clone --branch
#      feat/x acme/widgets` names `acme`, not `feat`.
#   5. The `origin` remote of the work tree the call was made from, github.com
#      only. This is what covers the large remainder — `gh pr list`, `gh pr
#      checks`, `gh issue comment 12`, every stage's bare `gh` call inside a
#      cloned workspace — none of which names a repository at all, because
#      `gh` itself resolves them exactly this way.
#
# Nothing here is required to succeed: an invocation no rule names an owner
# for is the ordinary case (`gh auth status`, `gh api rate_limit`, `gh
# --version`), and gh_shim_resolve_token answers it with the scalar default
# installation.
gh_shim_target_owner() {
  local owner=""

  if [[ "${1:-}" == "auth" && "${2:-}" == "git-credential" ]]; then
    owner="$(gh_shim_credential_owner "${GH_SHIM_STDIN_FILE:-}")"
    [[ -z "$owner" ]] || { printf '%s' "$owner"; return 0; }
  fi

  local -a args=("$@")
  local -a positionals=()
  local i j a skip_next=0

  for (( i = 0; i < ${#args[@]}; i++ )); do
    a="${args[i]}"
    case "$a" in
      -R=*|--repo=*) owner="$(gh_shim_owner_from_spec "${a#*=}")" ;;
      -R|--repo)     owner="$(gh_shim_owner_from_spec "${args[i + 1]:-}")" ;;
      *) continue ;;
    esac
    [[ -z "$owner" ]] || { printf '%s' "$owner"; return 0; }
  done

  # Which arguments are positional. A flag's value is skipped rather than
  # read (see rule 4 above): the list is every `gh` flag whose value can
  # legitimately contain a `/`, which is the only shape rule 4 looks at.
  # A flag this list does not know is treated as a boolean, so its value
  # reaches the positional scan — failing towards "an owner we may not have
  # wanted", which _gh_shim_owner_valid and the map/scalar fallback both
  # absorb, rather than towards a crash.
  for (( i = 0; i < ${#args[@]}; i++ )); do
    a="${args[i]}"
    if (( skip_next )); then skip_next=0; continue; fi
    case "$a" in
      --)
        for (( j = i + 1; j < ${#args[@]}; j++ )); do positionals+=("${args[j]}"); done
        break ;;
      -R|--repo|-B|--base|-H|--head|-b|--body|-F|--body-file|-f|--field|--raw-field \
      |--header|-t|--template|-q|--jq|-T|--title|--json|--search|-l|--label \
      |-a|--assignee|-m|--message|-c|--comment|-d|--directory|-L|--limit \
      |-A|--author|--milestone|--project|--reviewer|--add-label|--remove-label \
      |--add-assignee|--remove-assignee|--add-reviewer|--remove-reviewer \
      |--branch|--filename|--file|--input|--hostname|--cache|--method|-X)
        skip_next=1 ;;
      -*) ;;
      *) positionals+=("$a") ;;
    esac
  done

  if [[ "${positionals[0]:-}" == "api" ]]; then
    local endpoint="${positionals[1]:-}"
    if [[ "$endpoint" == "graphql" ]]; then
      local field=""
      for (( i = 0; i < ${#args[@]}; i++ )); do
        case "${args[i]}" in
          -f|-F|--field|--raw-field) field="${args[i + 1]:-}" ;;
          -f=*|-F=*|--field=*|--raw-field=*) field="${args[i]#*=}" ;;
          *) continue ;;
        esac
        case "$field" in owner=*) owner="${field#owner=}" ;; *) continue ;; esac
        _gh_shim_owner_valid "$owner" && { printf '%s' "$owner"; return 0; }
        owner=""
      done
      owner="$(printf '%s' "$*" | tr '\n' ' ' \
        | grep -oE 'repository[[:space:]]*\([[:space:]]*owner[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n1 | sed -E 's/.*"([^"]*)"$/\1/')"
      if [[ -n "$owner" ]] && _gh_shim_owner_valid "$owner"; then
        printf '%s' "$owner"; return 0
      fi
    else
      owner="$(gh_shim_owner_from_api_path "$endpoint")"
      [[ -z "$owner" ]] || { printf '%s' "$owner"; return 0; }
    fi
  elif (( ${#positionals[@]} > 0 )); then
    # A github.com URL is a repository under any command …
    for a in "${positionals[@]}"; do
      owner="$(gh_shim_owner_from_url "$a")"
      [[ -z "$owner" ]] || { printf '%s' "$owner"; return 0; }
    done
    # … a *bare* slug only under `gh repo <subcommand>` (see rule 4 above).
    if [[ "${positionals[0]}" == "repo" ]] && (( ${#positionals[@]} > 1 )); then
      for a in "${positionals[@]:1}"; do
        owner="$(gh_shim_owner_from_spec "$a")"
        [[ -z "$owner" ]] || { printf '%s' "$owner"; return 0; }
      done
    fi
  fi

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    owner="$(gh_shim_owner_from_url "$(git remote get-url origin 2>/dev/null)")"
    [[ -z "$owner" ]] || { printf '%s' "$owner"; return 0; }
  fi

  return 0
}

# gh_shim_resolve_token ARGS...
# "Explicit wins; empty resolves" (D18 decision 1 as amended, agent-ops#1021):
# mints a forge authoring App installation token into GH_TOKEN when — and
# only when — the caller's own environment leaves it empty. A non-empty
# GH_TOKEN (a human's own export, or lib/approver.sh's own
# `GH_TOKEN="$(approver_token_get)" gh …`) is never touched, which is what
# keeps the Approver's calls posting under its own identity rather than
# being re-minted as the author.
#
# *Which* installation it mints against is gh_shim_target_owner's answer for
# this invocation (agent-ops#913's map, applied to this identity): a named
# owner mints for that owner's installation; a named owner the map and the
# scalar default are both silent about falls back to PW_GH_DEGRADE_TOKEN,
# because an App token minted for the wrong account is a 404 at write time
# rather than a credential; and an invocation naming no owner at all resolves
# to the scalar default installation, or to PW_GH_DEGRADE_TOKEN when there is
# none. This is what makes provisioning the App (agent-ops#1083) safe on a
# fleet whose repositories sit in two organisations — before it, one minted
# token went into GH_TOKEN for every call whatever repository it targeted,
# and the PAT was reached for only when a mint *failed*, never when a
# perfectly good token simply did not cover the target.
#
# A cache hit (lib/github-app-token.sh's own refresh_buffer=300) costs
# nothing, so this runs unconditionally, ahead of classification, on every
# single invocation — the one place that guarantees every `git`/`gh`
# authoring act this node makes, however long the cycle or the stage
# running it has been alive, starts with at least five minutes of token
# life left. Falls back to PW_GH_DEGRADE_TOKEN (lib/forge-auth.sh owns the
# name) when no App is configured, or a mint attempt fails; leaves GH_TOKEN
# empty when neither is available, exactly the pre-existing "nothing
# configured" case. Never fails its caller.
gh_shim_resolve_token() {
  [[ -z "${GH_TOKEN:-}" ]] || return 0
  local now owner token
  # The cheap, owner-less gate first, and deliberately: with no App
  # configured at all there is no installation to choose between, and
  # gh_shim_target_owner's own last rule forks `git` twice. A node that has
  # never been given this identity must not pay for it on every call.
  # shellcheck disable=SC2119 # "is this identity configured at all", not a per-owner question
  if author_token_credential_present; then
    now="${PW_GH_NOW_EPOCH:-$(date +%s)}"
    owner="$(gh_shim_target_owner "$@")"
    if token="$(author_token_get "$now" "$owner" 2>/dev/null)" && [[ -n "$token" ]]; then
      export GH_TOKEN="$token"
      return 0
    fi
  fi
  [[ -n "${PW_GH_DEGRADE_TOKEN:-}" ]] && export GH_TOKEN="$PW_GH_DEGRADE_TOKEN"
  return 0
}
# gh_shim_real_bin
# The real `gh` binary this shim calls through to. Never resolved via `gh` or
# `command gh` — either would search `PATH` again and could recurse back into
# this same shim if it were ever installed twice or misconfigured.
gh_shim_real_bin() {
  printf '%s' "${PW_GH_REAL_BIN:-/usr/bin/gh}"
}

# gh_shim_state_dir
# "$PW_GH_STATE_DIR/gh-shim" (default "$HOME/.local/state/poetic-agents/gh-shim"),
# created — with its http-cache/ subdirectory — if absent. Printed with no
# trailing slash.
gh_shim_state_dir() {
  local base dir
  base="${PW_GH_STATE_DIR:-${HOME:-/tmp}/.local/state/poetic-agents}"
  dir="$base/gh-shim"
  mkdir -p "$dir/http-cache" 2>/dev/null || true
  printf '%s' "$dir"
}

# gh_shim_identity
# A stable, short tag for whichever credential this process authenticates
# with — the App and the PAT can legitimately see different data for the same
# path, and so can two installations of the same App, so their cache entries
# and budget readings must never collide. Hashing the token itself is what
# gives that for free: a per-owner mint (gh_shim_target_owner) yields a
# different token and therefore a different tag, with nothing here needing to
# know an installation id.
# Read after gh_shim_resolve_token has already run, so a token that function
# just minted is the one hashed here, not the empty value it was handed.
# "no-token" when neither GH_TOKEN nor GITHUB_TOKEN is set (gh's own
# keyring/`gh auth login` session, or no credential at all) — rare in this
# fleet, since gh_shim_resolve_token above leaves GH_TOKEN empty only when
# neither an App nor PW_GH_DEGRADE_TOKEN is configured — and safe to lump
# together since there is exactly one such identity per process either way.
gh_shim_identity() {
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -z "$token" ]]; then
    printf 'no-token'
    return 0
  fi
  printf '%s' "$token" | sha256sum | cut -c1-16
}

# gh_shim_strip_query PATH
# PATH with any "?…" query string removed. Pure.
gh_shim_strip_query() {
  printf '%s' "${1%%\?*}"
}

# gh_shim_parent_path PATH
# PATH with its last "/"-segment removed, or empty when PATH has none. Pure.
gh_shim_parent_path() {
  local p="$1"
  [[ "$p" == */* ]] || { printf ''; return 0; }
  printf '%s' "${p%/*}"
}

# gh_shim_cache_key IDENTITY ARGS...
# A short, stable key for this (identity, exact argv) pair. Deliberately the
# whole argv rather than just the endpoint: two calls that differ only in a
# `-f`/`-F` field are different requests and must not share a cache entry.
gh_shim_cache_key() {
  local identity="$1"
  shift
  { printf '%s\x1e' "$identity"; printf '%s\x1e' "$@"; } | sha256sum | cut -c1-24
}

# gh_shim_header_value HEADER_FILE NAME
# NAME's value from a file of "Name: value" lines (one match, the last one),
# case-insensitive, CR stripped. Empty when absent. Pure (given the file).
gh_shim_header_value() {
  local file="$1" name="$2"
  [[ -f "$file" ]] || return 0
  grep -i "^${name}:" "$file" 2>/dev/null | tail -1 | sed -E 's/^[^:]*:[ \t]*//' | tr -d '\r'
}

# gh_shim_header_end_offset RAW_FILE
# The byte offset of the end of RAW_FILE's first header block — the first
# empty line, a CR tolerated — so that `tail -c +<offset + 1>` is the response
# body exactly as the wire carried it: every CR kept, no newline added to a
# body that never ended with one. Prints 0 when RAW_FILE carries no header
# terminator at all. Reassembling the body line by line out of
# gh_shim_split_blocks' own capture cannot do this — `print` re-terminates
# every line it writes, and the CR strip that makes the *headers* readable
# would be applied to the body too. Pure (given the file).
gh_shim_header_end_offset() {
  LC_ALL=C awk '
    { n += length($0) + 1
      line = $0; sub(/\r$/, "", line)
      if (line == "") { off = n; done = 1; exit }
    }
    END { print (done ? off : 0) }
  ' "$1" 2>/dev/null || printf '0'
}

# gh_shim_split_blocks RAW_FILE OUT_DIR
# Splits a `gh api -i` (or `-i --paginate`) capture into per-page blocks —
# one HTTP response GitHub sent, per page — writing OUT_DIR/<n>.status (the
# status code alone), OUT_DIR/<n>.hdr (header lines, CR stripped) and
# OUT_DIR/<n>.body (the page's own body) for n = 1..count, and prints count.
# A status line is any line matching `HTTP/<version> <3-digit-code>`, which
# is what `-i` prints ahead of a page's headers; JSON never produces a line
# shaped like that, so this is unambiguous. Prints 0 for input that carries
# no such line at all (a real-binary invocation that failed before it ever
# received a response — DNS, a timeout, a missing binary).
gh_shim_split_blocks() {
  local raw="$1" outdir="$2"
  awk -v outdir="$outdir" '
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^HTTP\/[0-9]+(\.[0-9]+)?[ \t]+[0-9][0-9][0-9]/ {
      n++
      split(line, parts, /[ \t]+/)
      print parts[2] > (outdir "/" n ".status")
      close(outdir "/" n ".status")
      mode = "hdr"
      next
    }
    mode == "hdr" {
      if (length(line) == 0) { mode = "body"; next }
      print line >> (outdir "/" n ".hdr")
      next
    }
    mode == "body" {
      print line >> (outdir "/" n ".body")
      next
    }
    END { print n + 0 > (outdir "/count") }
  ' "$raw" 2>/dev/null
  cat "$outdir/count" 2>/dev/null || printf '0'
}

# gh_shim_parse ARGS...
# Parses one `gh` invocation, setting (never printing, so a caller reads them
# straight off — no subshell, no serialisation of a body that may be large):
#   GH_SHIM_IS_API        1 iff the first argument is literally "api"
#   GH_SHIM_ENDPOINT      the endpoint path (api calls only)
#   GH_SHIM_METHOD        GET, or whatever -X/--method resolves to, or POST
#                         when a body-supplying flag (-f/-F/--raw-field/
#                         --field/--input) is present with no explicit
#                         override — gh's own default-method rule
#   GH_SHIM_HAS_INCLUDE   1 iff -i/--include is already in ARGS
#   GH_SHIM_HAS_PAGINATE  1 iff -p/--paginate is already in ARGS
#   GH_SHIM_HAS_SLURP     1 iff --slurp is already in ARGS
# Not exhaustive against every `gh api` flag gh itself accepts (concatenated
# short-flag values like `-XPOST` are not recognised, only `-X POST`/
# `-X=POST`/`--method POST`/`--method=POST`) — every call site in this
# repository uses the space- or `=`-separated forms, and a flag this does not
# recognise is treated as a boolean and simply skipped, which only ever
# widens what counts as a GET, never narrows it, so an unrecognised form fails
# towards "leave it uncached", not towards a wrongly-cached write.
GH_SHIM_IS_API=0
GH_SHIM_ENDPOINT=""
GH_SHIM_METHOD="GET"
GH_SHIM_HAS_INCLUDE=0
GH_SHIM_HAS_PAGINATE=0
GH_SHIM_HAS_SLURP=0
gh_shim_parse() {
  GH_SHIM_IS_API=0; GH_SHIM_ENDPOINT=""; GH_SHIM_METHOD="GET"
  GH_SHIM_HAS_INCLUDE=0; GH_SHIM_HAS_PAGINATE=0; GH_SHIM_HAS_SLURP=0
  [[ "${1:-}" == "api" ]] || return 0
  GH_SHIM_IS_API=1
  shift
  local explicit_method="" has_body_flag=0 endpoint="" a
  while [[ $# -gt 0 ]]; do
    a="$1"
    case "$a" in
      -i|--include) GH_SHIM_HAS_INCLUDE=1; shift ;;
      -p|--paginate) GH_SHIM_HAS_PAGINATE=1; shift ;;
      --slurp) GH_SHIM_HAS_SLURP=1; shift ;;
      --silent|--verbose) shift ;;
      -X=*|--method=*) explicit_method="${a#*=}"; shift ;;
      -X|--method) explicit_method="${2:-}"; shift 2 ;;
      --input=*) has_body_flag=1; shift ;;
      --input) has_body_flag=1; shift 2 ;;
      -f=*|-F=*|--raw-field=*|--field=*) has_body_flag=1; shift ;;
      -f|-F|--raw-field|--field) has_body_flag=1; shift 2 ;;
      -H=*|--header=*|--hostname=*|-q=*|--jq=*|-t=*|--template=*|--cache=*) shift ;;
      -H|--header|--hostname|-q|--jq|-t|--template|--cache) shift 2 ;;
      --) shift
          while [[ $# -gt 0 ]]; do [[ -n "$endpoint" ]] || endpoint="$1"; shift; done
          ;;
      -*) shift ;;
      *) [[ -n "$endpoint" ]] || endpoint="$a"; shift ;;
    esac
  done
  GH_SHIM_ENDPOINT="$endpoint"
  if [[ -n "$explicit_method" ]]; then
    GH_SHIM_METHOD="$(printf '%s' "$explicit_method" | tr '[:lower:]' '[:upper:]')"
  elif [[ "$has_body_flag" == 1 ]]; then
    GH_SHIM_METHOD="POST"
  fi
}

# gh_shim_classify ARGS...
# Sets GH_SHIM_CLASS (plus GH_SHIM_PARSE's own globals, via gh_shim_parse) to
# one of:
#   read     a plain `gh api` GET with a real endpoint — the only class this
#            file ever conditions
#   paginate a `gh api` GET carrying --paginate/--slurp: stored and served
#            last-known-good like a `read`, but never conditioned and never
#            reshaped — see this file's header for why `-i` cannot be added
#            to one
#   write    a `gh api` call whose method resolved to non-GET
#   graphql  the literal `graphql` endpoint of `gh api` — always POST, never
#            conditional, per GitHub's own semantics
#   include  a `gh api` call that already asks for -i/--include itself — see
#            this file's header for why that always bypasses
#   other    anything that is not `gh api` at all (`gh pr view`, `gh issue
#            list`, …), or `gh api` with no endpoint this file could find
# Every class but `read` reaches the real binary with the caller's own argv,
# unmodified; every class but `read` and `paginate` has its stdout passed
# straight through without this file ever reading it.
GH_SHIM_CLASS="other"
gh_shim_classify() {
  gh_shim_parse "$@"
  if [[ "$GH_SHIM_IS_API" != 1 ]]; then GH_SHIM_CLASS="other"; return 0; fi
  if [[ "$GH_SHIM_HAS_INCLUDE" == 1 ]]; then GH_SHIM_CLASS="include"; return 0; fi
  if [[ -z "$GH_SHIM_ENDPOINT" ]]; then GH_SHIM_CLASS="other"; return 0; fi
  if [[ "$GH_SHIM_ENDPOINT" == "graphql" ]]; then GH_SHIM_CLASS="graphql"; return 0; fi
  if [[ "$GH_SHIM_METHOD" != "GET" ]]; then GH_SHIM_CLASS="write"; return 0; fi
  if [[ "$GH_SHIM_HAS_PAGINATE" == 1 || "$GH_SHIM_HAS_SLURP" == 1 ]]; then
    GH_SHIM_CLASS="paginate"; return 0
  fi
  GH_SHIM_CLASS="read"
}

# gh_shim_cache_read STATE_DIR KEY
# The cache entry for KEY as compact JSON, or nothing when absent or
# unreadable.
gh_shim_cache_read() {
  local f="$1/http-cache/$2.json"
  [[ -f "$f" ]] || return 0
  jq -c '.' "$f" 2>/dev/null || true
}

# gh_shim_cache_write STATE_DIR KEY IDENTITY PATH ETAG BODY_FILE FETCHED_AT
# Writes the cache entry for KEY via a temp file plus `mv -f`, so a
# concurrent reader never observes a partial write. BODY_FILE is read
# directly (`--rawfile`), never through a shell variable, so an arbitrarily
# large response body is never copied through bash.
gh_shim_cache_write() {
  local state_dir="$1" key="$2" identity="$3" path="$4" etag="$5" bodyfile="$6" fetched_at="$7"
  local dir="$state_dir/http-cache" tmp
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || return 0
  if jq -n --arg identity "$identity" --arg path "$path" --arg etag "$etag" \
        --argjson fetched_at "$fetched_at" --rawfile body "$bodyfile" \
      '{identity: $identity, path: $path, etag: $etag, fetched_at: $fetched_at, body: $body}' \
      > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dir/$key.json"
  else
    rm -f "$tmp"
  fi
}

# gh_shim_cache_invalidate STATE_DIR IDENTITY PATH
# Drops every cache entry for IDENTITY whose stored path is PATH itself or
# PATH's parent (see this file's header). Scans http-cache/ rather than
# keeping a reverse index — cheap at the handful-to-low-hundreds of distinct
# calls one node caches, and simplicity here means an invalidation bug shows
# up as "read the wrong page's own path", not as an index silently drifting
# from the entries it is supposed to describe.
gh_shim_cache_invalidate() {
  local state_dir="$1" identity="$2" path="$3"
  local dir="$state_dir/http-cache" parent f p ident
  [[ -d "$dir" ]] || return 0
  parent="$(gh_shim_parent_path "$path")"
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    ident="$(jq -r '.identity // empty' "$f" 2>/dev/null)"
    [[ "$ident" == "$identity" ]] || continue
    p="$(jq -r '.path // empty' "$f" 2>/dev/null)"
    if [[ "$p" == "$path" ]] || { [[ -n "$parent" ]] && [[ "$p" == "$parent" ]]; }; then
      rm -f "$f"
    fi
  done
}

# gh_shim_ledger_line STATE_DIR METHOD PATH STATUS CACHE RESOURCE USED
# Appends one `{ts, method, path, status, cache, resource, used}` line to
# ledger.ndjson under `flock`, so two calls racing on the same node never
# interleave a line. STATUS is written as a number when it looks like one
# (an HTTP status) and as null otherwise (a call this file never got an HTTP
# status for at all); RESOURCE/USED are null when unknown. Never fails its
# caller — a ledger write is diagnostic, not load-bearing.
gh_shim_ledger_line() {
  local state_dir="$1" method="$2" path="$3" status="$4" cache="$5" resource="$6" used="$7"
  local ledger="$state_dir/ledger.ndjson" ts line
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(jq -nc --arg ts "$ts" --arg m "$method" --arg p "$path" --arg s "$status" \
              --arg c "$cache" --arg r "$resource" --arg u "$used" \
    '{ts: $ts, method: $m, path: $p,
      status: (if ($s | test("^[0-9]+$")) then ($s | tonumber) elif $s == "" then null else $s end),
      cache: $c,
      resource: (if $r == "" then null else $r end),
      used: (if ($u | test("^[0-9]+$")) then ($u | tonumber) else null end)}' 2>/dev/null)" || return 0
  [[ -n "$line" ]] || return 0
  ( flock -w 2 200 || exit 0; printf '%s\n' "$line" >> "$ledger" ) 200>"$ledger.lock" 2>/dev/null || true
}

# gh_shim_budget_update STATE_DIR IDENTITY RESOURCE_JSON
# Records RESOURCE_JSON ({limit, used, remaining, reset}) as IDENTITY's
# latest `core` reading in budget.json, under `flock` so a concurrent update
# from another call on this node cannot lose one. A no-op when RESOURCE_JSON
# is empty (no ratelimit headers were readable this call).
gh_shim_budget_update() {
  local state_dir="$1" identity="$2" resjson="$3"
  [[ -n "$resjson" ]] || return 0
  local file="$state_dir/budget.json" current tmp
  (
    flock -w 2 201 || exit 0
    current="$(cat "$file" 2>/dev/null || printf '{}')"
    jq -e 'type == "object"' <<<"$current" >/dev/null 2>&1 || current='{}'
    tmp="$(mktemp "$state_dir/.budget.tmp.XXXXXX" 2>/dev/null)" || exit 0
    if jq --arg id "$identity" --argjson r "$resjson" '.[$id].core = $r' <<<"$current" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$file"
    else
      rm -f "$tmp"
    fi
  ) 201>"$file.lock" 2>/dev/null || true
}

# gh_shim_prune_cache STATE_DIR CEILING_SECONDS
# Best-effort removal of cache entries so old the staleness ceiling could
# never serve them anyway (older than 7x CEILING_SECONDS). Called from
# gh_shim_main at low probability rather than every invocation, so a busy
# node is not `find`-ing the whole cache directory on every single call.
gh_shim_prune_cache() {
  local state_dir="$1" ceiling="${2:-3600}"
  local dir="$state_dir/http-cache" max_days
  [[ -d "$dir" ]] || return 0
  max_days=$(( (ceiling * 7 / 86400) + 1 ))
  find "$dir" -maxdepth 1 -name '*.json' -mtime "+$max_days" -delete 2>/dev/null || true
}

# gh_shim_should_use_lkg STATUS TEXT
# True iff STATUS/TEXT describes the two refusal shapes property 2 (last-
# known-good) applies to: a primary rate limit (via `github_limit_kind`, the
# same detector requirement 2.0a's retry wrapper uses — never a secondary
# one, which is short and better served by that wrapper's own retry) or any
# 5xx. TEXT is checked against both the captured body and stderr, since a
# real refusal's recognisable phrase can land in either (gh's own diagnostic
# goes to stderr; the JSON body GitHub sent carries the same wording).
gh_shim_should_use_lkg() {
  local status="$1" text="$2"
  [[ "$(github_limit_kind "$text")" == "primary" ]] && return 0
  [[ "$status" =~ ^5[0-9][0-9]$ ]] && return 0
  return 1
}

# gh_shim_serve_lkg STATE_DIR CACHE_JSON NOW STATUS TEXT
# Serves CACHE_JSON's stored body on stdout and prints the stale marker on
# stderr — returning 0 — iff CACHE_JSON is non-empty, within
# PW_GH_STALE_CEILING_SECONDS of NOW, and gh_shim_should_use_lkg accepts
# STATUS/TEXT. Prints nothing and returns 1 otherwise, leaving the caller to
# fall through to reporting the real failure.
gh_shim_serve_lkg() {
  local state_dir="$1" cache_json="$2" now="$3" status="$4" text="$5"
  [[ -n "$cache_json" ]] || return 1
  gh_shim_should_use_lkg "$status" "$text" || return 1
  local fetched_at ceiling age
  fetched_at="$(jq -r '.fetched_at // 0' <<<"$cache_json" 2>/dev/null)"
  [[ "$fetched_at" =~ ^[0-9]+$ ]] || fetched_at=0
  ceiling="${PW_GH_STALE_CEILING_SECONDS:-3600}"
  age=$(( now - fetched_at ))
  (( age >= 0 && age <= ceiling )) || return 1
  printf 'PW_GH_CACHE=stale age=%ss\n' "$age" >&2
  jq -j '.body' <<<"$cache_json" 2>/dev/null
  return 0
}

# gh_shim_handle_read STATE_DIR IDENTITY ARGS...
# The cacheable-GET pathway: conditions the request on a stored ETag, always
# adds -i itself so it can read the response, and never lets that addition
# reach the caller: what comes back on stdout is exactly the body a plain
# `gh api` call without -i would have printed, byte for byte. A `--paginate`/
# `--slurp` call never arrives here — `-i` reshapes those (see this file's
# header), so gh_shim_handle_paginate takes them instead.
gh_shim_handle_read() {
  local state_dir="$1" identity="$2"
  shift 2
  local real path key cache_json etag=""
  real="$(gh_shim_real_bin)"
  path="$(gh_shim_strip_query "$GH_SHIM_ENDPOINT")"
  key="$(gh_shim_cache_key "$identity" "$@")"
  cache_json="$(gh_shim_cache_read "$state_dir" "$key")"
  [[ -n "$cache_json" ]] && etag="$(jq -r '.etag // empty' <<<"$cache_json" 2>/dev/null)"

  local -a call_args=("$@")
  if [[ -n "$etag" ]]; then
    call_args+=(-H "If-None-Match: $etag")
  fi
  call_args+=(-i)

  local work out err
  work="$(mktemp -d 2>/dev/null)" || { "$real" "$@"; return $?; }
  out="$work/out"; err="$work/err"
  "$real" "${call_args[@]}" >"$out" 2>"$err"
  local rc=$?
  local now blocks
  now="$(date -u +%s)"
  blocks="$(gh_shim_split_blocks "$out" "$work")"

  if [[ "$blocks" -eq 0 ]]; then
    if gh_shim_serve_lkg "$state_dir" "$cache_json" "$now" "" "$(cat "$err" 2>/dev/null)"; then
      gh_shim_ledger_line "$state_dir" GET "$path" "" stale "" ""
      rm -rf "$work"
      return "${PW_GH_STALE_EXIT_CODE:-0}"
    fi
    # Whatever the real binary printed goes to the caller even here, where
    # this file could not parse it: eating the real binary's stdout and still
    # reporting its exit status is the one failure mode a transport seam must
    # never have — a caller that checks only the body would read the silence
    # as an empty answer rather than as the failure it is.
    cat "$out"
    cat "$err" >&2
    gh_shim_ledger_line "$state_dir" GET "$path" "" miss "" ""
    rm -rf "$work"
    return "$rc"
  fi

  local last_status last_hdr resjson="" resource="" used="" first_hdr new_etag=""
  last_status="$(cat "$work/$blocks.status" 2>/dev/null || printf '')"
  last_hdr="$work/$blocks.hdr"
  if [[ -f "$last_hdr" || -n "$last_status" ]]; then
    resjson="$(github_limit_headers_to_resource "$(printf 'HTTP/2 %s\r\n' "$last_status"; cat "$last_hdr" 2>/dev/null; printf '\n')" 2>/dev/null)"
  fi
  if [[ -n "$resjson" ]]; then
    used="$(jq -r '.used // empty' <<<"$resjson" 2>/dev/null)"
    resource="core"
  fi
  first_hdr="$work/1.hdr"
  [[ -f "$first_hdr" ]] && new_etag="$(gh_shim_header_value "$first_hdr" etag)"

  local bodyfile="$work/full-body" i off
  : > "$bodyfile"
  if [[ "$blocks" -eq 1 ]]; then
    # The ordinary case, and the only one a non-paginated call can produce:
    # take the body byte-exactly, from just past the header terminator.
    off="$(gh_shim_header_end_offset "$out")"
    if [[ "$off" =~ ^[0-9]+$ ]] && (( off > 0 )); then
      tail -c "+$(( off + 1 ))" "$out" > "$bodyfile" 2>/dev/null || : > "$bodyfile"
    fi
  else
    # Belt and braces: no call reaching this function should answer in more
    # than one block, since `--paginate` is handled elsewhere. Reassembling
    # from the split capture is line-based rather than byte-exact, which is
    # why it is the fallback and not the rule.
    for (( i = 1; i <= blocks; i++ )); do
      [[ -f "$work/$i.body" ]] && cat "$work/$i.body" >> "$bodyfile"
    done
  fi

  if [[ "$blocks" -eq 1 && "$last_status" == "304" && -n "$cache_json" ]]; then
    jq -j '.body' <<<"$cache_json" 2>/dev/null
    gh_shim_ledger_line "$state_dir" GET "$path" 304 hit "$resource" "$used"
    gh_shim_budget_update "$state_dir" "$identity" "$resjson"
    rm -rf "$work"
    return 0
  fi

  if [[ "$last_status" =~ ^2[0-9][0-9]$ ]]; then
    gh_shim_cache_write "$state_dir" "$key" "$identity" "$path" "$new_etag" "$bodyfile" "$now"
    cat "$bodyfile"
    gh_shim_ledger_line "$state_dir" GET "$path" "$last_status" miss "$resource" "$used"
    gh_shim_budget_update "$state_dir" "$identity" "$resjson"
    rm -rf "$work"
    return 0
  fi

  local text
  text="$(cat "$err" 2>/dev/null; printf ' '; cat "$bodyfile" 2>/dev/null)"
  if gh_shim_serve_lkg "$state_dir" "$cache_json" "$now" "$last_status" "$text"; then
    gh_shim_ledger_line "$state_dir" GET "$path" "$last_status" stale "$resource" "$used"
    gh_shim_budget_update "$state_dir" "$identity" "$resjson"
    rm -rf "$work"
    return "${PW_GH_STALE_EXIT_CODE:-0}"
  fi

  cat "$bodyfile"
  cat "$err" >&2
  gh_shim_ledger_line "$state_dir" GET "$path" "$last_status" miss "$resource" "$used"
  gh_shim_budget_update "$state_dir" "$identity" "$resjson"
  rm -rf "$work"
  return "$rc"
}

# gh_shim_handle_paginate STATE_DIR IDENTITY ARGS...
# The `--paginate`/`--slurp` pathway. The real binary is called with the
# caller's own argv, untouched — no `If-None-Match`, and above all no `-i`,
# which would change the shape of the document `gh` prints rather than merely
# prepend headers to it (this file's header sets out both shapes) — and its
# stdout is passed through byte for byte. Property 1 (the 304 saving) is
# therefore not available here, and is agent-ops#1114's; properties 2
# (last-known-good, from the body stored on a successful call) and 3 (the
# ledger) are, and are what this pathway exists to keep.
gh_shim_handle_paginate() {
  local state_dir="$1" identity="$2"
  shift 2
  local real path key cache_json
  real="$(gh_shim_real_bin)"
  path="$(gh_shim_strip_query "$GH_SHIM_ENDPOINT")"
  key="$(gh_shim_cache_key "$identity" "$@")"
  cache_json="$(gh_shim_cache_read "$state_dir" "$key")"

  local work out err
  work="$(mktemp -d 2>/dev/null)" || { "$real" "$@"; return $?; }
  out="$work/out"; err="$work/err"
  "$real" "$@" >"$out" 2>"$err"
  local rc=$?
  local now; now="$(date -u +%s)"

  # No status line is ever read here — the response was never asked to carry
  # one — so the ledger records this call's outcome by exit status, and the
  # budget file is left to the conditional reads that do see headers.
  if (( rc == 0 )); then
    gh_shim_cache_write "$state_dir" "$key" "$identity" "$path" "" "$out" "$now"
    cat "$out"
    cat "$err" >&2
    gh_shim_ledger_line "$state_dir" GET "$path" "" miss "" ""
    rm -rf "$work"
    return 0
  fi

  if gh_shim_serve_lkg "$state_dir" "$cache_json" "$now" "" \
       "$(cat "$err" 2>/dev/null; printf ' '; cat "$out" 2>/dev/null)"; then
    gh_shim_ledger_line "$state_dir" GET "$path" "" stale "" ""
    rm -rf "$work"
    return "${PW_GH_STALE_EXIT_CODE:-0}"
  fi

  cat "$out"
  cat "$err" >&2
  gh_shim_ledger_line "$state_dir" GET "$path" "" miss "" ""
  rm -rf "$work"
  return "$rc"
}

# gh_shim_run_bypass STATE_DIR IDENTITY ARGS...
# The unmodified-passthrough pathway shared by every class but `read`:
# GH_SHIM_CLASS/GH_SHIM_ENDPOINT/GH_SHIM_METHOD/GH_SHIM_IS_API must already
# be set (by gh_shim_classify, immediately before this is called) and are
# snapshotted into locals before ARGS is shifted, since gh_shim_classify is
# never called again here. A successful (`gh` exit 0) `write` invalidates the
# cache entries its own path feeds.
gh_shim_run_bypass() {
  local state_dir="$1" identity="$2"
  shift 2
  local class_was="$GH_SHIM_CLASS" endpoint_was="$GH_SHIM_ENDPOINT" \
        method_was="$GH_SHIM_METHOD" is_api_was="$GH_SHIM_IS_API"
  local real; real="$(gh_shim_real_bin)"
  "$real" "$@"
  local rc=$?
  local method path
  if [[ "$is_api_was" == 1 ]]; then
    method="$method_was"
    path="$(gh_shim_strip_query "$endpoint_was")"
  else
    method="cmd"
    path="$*"
  fi
  gh_shim_ledger_line "$state_dir" "$method" "$path" "$rc" bypass "" ""
  if [[ "$class_was" == "write" && "$rc" -eq 0 && -n "$endpoint_was" ]]; then
    gh_shim_cache_invalidate "$state_dir" "$identity" "$(gh_shim_strip_query "$endpoint_was")"
  fi
  return "$rc"
}

# gh_shim_main ARGS...
# The shim's entry point (`scripts/gh-shim.sh` calls this and nothing else).
# PW_GH_NO_CACHE=1 forces every call through gh_shim_run_bypass regardless of
# classification — still ledgered, never cached or conditioned.
#
# `gh auth git-credential` is the one invocation whose *stdin* has to be read
# before the token is resolved: git writes its request there (`protocol=`,
# `host=`, `path=`) and closes the pipe, and the `path=` line is the only
# thing in the whole call that names the repository being pushed to or
# fetched from. So that one shape — and only that one, because buffering
# anything else would break `gh api --input -` — is read whole into a
# temporary file, which then *replaces* this process's own stdin (`exec <`)
# before anything else runs. The real binary therefore receives the caller's
# bytes unchanged, in order, exactly as it would have straight off the pipe;
# the file is unlinked as soon as gh_shim_resolve_token has read it, the open
# descriptor keeping it alive for the exec that follows. A `mktemp` that
# fails costs only the owner (the call still works, resolving to the scalar
# default installation), never the call.
gh_shim_main() {
  local cred_stdin=""
  if [[ "${1:-}" == "auth" && "${2:-}" == "git-credential" ]]; then
    if cred_stdin="$(mktemp "${TMPDIR:-/tmp}/gh-shim-credential.XXXXXX" 2>/dev/null)"; then
      cat > "$cred_stdin"
      GH_SHIM_STDIN_FILE="$cred_stdin"
      exec < "$cred_stdin"
    else
      cred_stdin=""
    fi
  fi
  gh_shim_resolve_token "$@"
  [[ -z "$cred_stdin" ]] || rm -f "$cred_stdin"
  local state_dir identity
  state_dir="$(gh_shim_state_dir)"
  identity="$(gh_shim_identity)"

  if (( RANDOM % 40 == 0 )); then
    gh_shim_prune_cache "$state_dir" "${PW_GH_STALE_CEILING_SECONDS:-3600}"
  fi

  gh_shim_classify "$@"

  if [[ "${PW_GH_NO_CACHE:-0}" == "1" ]]; then
    gh_shim_run_bypass "$state_dir" "$identity" "$@"
    return $?
  fi

  case "$GH_SHIM_CLASS" in
    read)     gh_shim_handle_read "$state_dir" "$identity" "$@" ;;
    paginate) gh_shim_handle_paginate "$state_dir" "$identity" "$@" ;;
    *)        gh_shim_run_bypass "$state_dir" "$identity" "$@" ;;
  esac
}
