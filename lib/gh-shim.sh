#!/usr/bin/env bash
#
# lib/gh-shim.sh — the logic behind `scripts/gh-shim.sh`, the `gh` transport
# seam installed on `PATH` ahead of the real binary (agent-ops#1084).
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
# ever cached or conditioned. Everything else (`gh pr view`, `gh issue list`,
# a write, the `graphql` endpoint of `gh api`, a caller already reading raw
# headers) is passed
# to the real binary completely unmodified: same argv, same stdout, same
# stderr, same exit status. `gh_shim_classify` is the one place that decision
# is made; see its own header for why each case is excluded.
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
# ## Known scope limit: `--paginate` (agent-ops#1114)
#
# `gh api --paginate` fetches every page inside one real-binary invocation,
# each with its own `ETag`. Conditioning the *first* page's request would be
# unsound — a stale `If-None-Match` sent uniformly to every page could 304 a
# page whose content actually changed — so a `--paginate` call is never sent
# a conditional header at all: it always reaches the network in full. Its
# response is still stored, so property 2 (last-known-good) still applies to
# it; only property 1 (the 304 saving) does not. Per-page conditioning is
# filed as tech debt rather than built here (agent-ops#1114) — it needs the
# shim to drive pagination itself
# rather than delegate it to the real binary in one call, which is a
# materially larger change than the rest of this file.
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

# Computed inline, not kept in a variable: this file is sourced, and a
# top-level `SCRIPT_DIR="..."` here would clobber whatever the sourcing
# script (or a test) already keeps under that same common name.
# shellcheck source=lib/github-limit.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-limit.sh"

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
# path, so their cache entries and budget readings must never collide.
# "no-token" when neither GH_TOKEN nor GITHUB_TOKEN is set (gh's own
# keyring/`gh auth login` session, or no credential at all) — rare in this
# fleet (lib/forge-auth.sh always sets GH_TOKEN when anything is configured)
# and safe to lump together since there is exactly one such identity per
# process either way.
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
gh_shim_parse() {
  GH_SHIM_IS_API=0; GH_SHIM_ENDPOINT=""; GH_SHIM_METHOD="GET"
  GH_SHIM_HAS_INCLUDE=0; GH_SHIM_HAS_PAGINATE=0
  [[ "${1:-}" == "api" ]] || return 0
  GH_SHIM_IS_API=1
  shift
  local explicit_method="" has_body_flag=0 endpoint="" a
  while [[ $# -gt 0 ]]; do
    a="$1"
    case "$a" in
      -i|--include) GH_SHIM_HAS_INCLUDE=1; shift ;;
      -p|--paginate) GH_SHIM_HAS_PAGINATE=1; shift ;;
      --silent|--slurp|--verbose) shift ;;
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
#            file ever caches or conditions
#   write    a `gh api` call whose method resolved to non-GET
#   graphql  the literal `graphql` endpoint of `gh api` — always POST, never
#            conditional, per GitHub's own semantics
#   include  a `gh api` call that already asks for -i/--include itself — see
#            this file's header for why that always bypasses
#   other    anything that is not `gh api` at all (`gh pr view`, `gh issue
#            list`, …), or `gh api` with no endpoint this file could find
# Every class but `read` is a pure, unmodified passthrough to the real
# binary.
GH_SHIM_CLASS="other"
gh_shim_classify() {
  gh_shim_parse "$@"
  if [[ "$GH_SHIM_IS_API" != 1 ]]; then GH_SHIM_CLASS="other"; return 0; fi
  if [[ "$GH_SHIM_HAS_INCLUDE" == 1 ]]; then GH_SHIM_CLASS="include"; return 0; fi
  if [[ -z "$GH_SHIM_ENDPOINT" ]]; then GH_SHIM_CLASS="other"; return 0; fi
  if [[ "$GH_SHIM_ENDPOINT" == "graphql" ]]; then GH_SHIM_CLASS="graphql"; return 0; fi
  if [[ "$GH_SHIM_METHOD" != "GET" ]]; then GH_SHIM_CLASS="write"; return 0; fi
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
# The cacheable-GET pathway: conditions the request on a stored ETag (unless
# --paginate — see this file's header), always adds -i itself so it can read
# the response, and never lets that addition reach the caller: what comes
# back on stdout is exactly the body(ies) a plain `gh api` call without -i
# would have printed.
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
  if [[ "$GH_SHIM_HAS_PAGINATE" != 1 && -n "$etag" ]]; then
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

  local bodyfile="$work/full-body" i
  : > "$bodyfile"
  for (( i = 1; i <= blocks; i++ )); do
    [[ -f "$work/$i.body" ]] && cat "$work/$i.body" >> "$bodyfile"
  done

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
gh_shim_main() {
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
    read) gh_shim_handle_read "$state_dir" "$identity" "$@" ;;
    *)    gh_shim_run_bypass "$state_dir" "$identity" "$@" ;;
  esac
}
