#!/usr/bin/env bash
#
# scripts/preview-deploy.sh — did this pull request's preview actually deploy,
# and does the deployed page answer?
#
# poetic-fiddle deploys from GitHub through Vercel's Git integration, so every
# pull request head SHA gets its own Preview deployment. Nothing a stage
# already looks at says whether that deployment built or serves: the Vercel
# integration reports through GitHub's *deployments* API, not through the check
# runs `gh pr checks` reads, so a pull request can be entirely green over a
# preview that failed to build. This script is how a stage asks.
#
# It exists mostly for one trap. Preview deployments sit behind Vercel
# Authentication (the project's SSO protection), and an unauthenticated request
# for one is answered with a 302 to vercel.com/login — which `curl -L` turns
# into a **200**, so any check reading a status code alone certifies a login
# page as a healthy deployment. This script therefore judges where a response
# goes rather than what it is numbered, and reports a wall as "could not check"
# rather than as either a pass or a deployment failure: a preview nobody can
# reach is a statement about this node's configuration, not about the branch.
#
# What it reads from the environment:
#   GH_TOKEN                         the deployment and its status. Already set
#                                    on every node.
#   VERCEL_AUTOMATION_BYPASS_SECRET  Vercel → the project → Settings →
#                                    Deployment Protection → Protection Bypass
#                                    for Automation. Sent as the
#                                    x-vercel-protection-bypass header; without
#                                    it every preview reads as protected.
#   VERCEL_TOKEN                     optional. The tail of the build log when a
#                                    deployment failed; without it a failure
#                                    still names the deployment's inspector URL,
#                                    which is where a human would go.
#
# One secret serves one Vercel project, which is all this operation has. A
# second deployed repository needs the secret chosen per repo rather than read
# from one variable — the only line here that would have to change.
#
# Exit: 0 deployed and answering · 1 the deployment failed, or the page does
# not answer · 2 could not check (no deployment yet, still building, protected,
# no pull request, GitHub unreachable).

set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: preview-deploy.sh [--repo <owner/name>] [--pr <n> | --sha <sha>]
                         [--path <path>] [--wait <seconds>]

Report the state of the Vercel preview deployment for a pull request, and
whether the deployed page actually answers.

With no arguments it asks about the pull request for the branch checked out in
the current directory, which is how a pipeline stage runs it from its own
workspace clone.

  --repo   owner/name (default: the repository in the current directory)
  --pr     pull request number (default: the one for the current branch)
  --sha    a head SHA, instead of a pull request
  --path   the path to request (default: /) — e.g. /api/health
  --wait   seconds to keep polling while the deployment is still building
           (default: 0, answer immediately)

Needs GH_TOKEN, and VERCEL_AUTOMATION_BYPASS_SECRET to get past Vercel
Authentication. VERCEL_TOKEN is optional and buys the build log on a failure.

Exit 0 deployed and answering, 1 failed or not answering, 2 could not check.
USAGE
}

slug=""
pr=""
sha=""
path="/"
wait_seconds=0
repo_explicit=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) slug="${2:-}"; repo_explicit=1; shift 2 ;;
    --pr)   pr="${2:-}";   shift 2 ;;
    --sha)  sha="${2:-}";  shift 2 ;;
    --path) path="${2:-}"; shift 2 ;;
    --wait) wait_seconds="${2:-}"; shift 2 ;;
    *) echo "preview-deploy: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$wait_seconds" =~ ^[0-9]+$ ]]; then
  echo "preview-deploy: --wait takes a whole number of seconds" >&2
  exit 2
fi
[[ "$path" == /* ]] || path="/$path"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; }
info() { printf 'info - %s\n' "$1"; }

# --- Which pull request, and so which SHA -------------------------------------
# `gh` answers all three questions from the working directory, which is the
# ephemeral clone a stage is already standing in.
if [[ -z "$slug" ]]; then
  if ! slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>"$tmp_dir/err")"; then
    echo "preview-deploy: cannot tell which repository this is" >&2
    echo "  run it inside a clone, or pass --repo owner/name" >&2
    exit 2
  fi
fi

if [[ -z "$sha" ]]; then
  # `gh pr view` infers "the PR for the current branch" from the ambient
  # repository context, but passing --repo overrides that context — and gh
  # then refuses to combine --repo with no PR number, URL or branch ("argument
  # required when using the --repo flag"). So --repo is only ever added to the
  # query below once a PR number is already in hand. An explicit --repo with
  # no --pr has to resolve the number itself first, through a call that names
  # the branch instead of relying on inference; slug filled in automatically
  # above (the common case, no --repo passed) already matches the working
  # directory's own repository, so inference alone is enough there.
  if [[ -z "$pr" ]] && (( repo_explicit )); then
    if ! branch="$(git branch --show-current 2>"$tmp_dir/err")" || [[ -z "$branch" ]]; then
      echo "preview-deploy: cannot tell which branch is checked out" >&2
      echo "  $(cat "$tmp_dir/err")" >&2
      exit 2
    fi
    if ! pr="$(gh pr list --head "$branch" --repo "$slug" --json number \
        --jq '.[0].number // empty' 2>"$tmp_dir/err")" || [[ -z "$pr" ]]; then
      echo "preview-deploy: no pull request for branch $branch in $slug" >&2
      [[ -s "$tmp_dir/err" ]] && echo "  $(cat "$tmp_dir/err")" >&2
      echo "  pass --pr <n> or --sha <sha>" >&2
      exit 2
    fi
  fi

  # The field list is quoted so the comma reads as part of one argument rather
  # than as an array separator — to shellcheck (SC2054) as much as to a reader.
  pr_query=( gh pr view --json "headRefOid,number" --jq '.headRefOid + " " + (.number|tostring)' )
  if [[ -n "$pr" ]]; then
    pr_query+=( "$pr" )
    [[ -n "$slug" ]] && pr_query+=( --repo "$slug" )
  fi
  if ! pr_answer="$("${pr_query[@]}" 2>"$tmp_dir/err")"; then
    echo "preview-deploy: no pull request to ask about" >&2
    echo "  $(cat "$tmp_dir/err")" >&2
    echo "  pass --pr <n> or --sha <sha>, or run this on a branch that has a PR" >&2
    exit 2
  fi
  sha="${pr_answer% *}"
  pr="${pr_answer##* }"
fi

if [[ -n "$pr" ]]; then
  info "$slug PR #$pr at ${sha:0:7}"
else
  info "$slug at ${sha:0:7}"
fi

# --- The deployment GitHub recorded for that SHA ------------------------------
# Vercel's integration writes a deployment per SHA and then a series of
# statuses against it; the newest status is the deployment's current state and
# the URL arrives on whichever status first had one. Both lists come back
# newest-first.
deadline=$(( $(date +%s) + wait_seconds ))
state=""
url=""
inspect_url=""

while true; do
  if ! deployments="$(gh api "repos/$slug/deployments?sha=$sha&per_page=100" \
      2>"$tmp_dir/err")"; then
    echo "preview-deploy: cannot read $slug's deployments" >&2
    echo "  $(cat "$tmp_dir/err")" >&2
    exit 2
  fi

  dep_id="$(jq -r '[.[] | select(.environment == "Preview")] | .[0].id // empty' \
    <<<"$deployments")"

  if [[ -n "$dep_id" ]]; then
    if ! statuses="$(gh api "repos/$slug/deployments/$dep_id/statuses?per_page=100" \
        2>"$tmp_dir/err")"; then
      echo "preview-deploy: cannot read deployment $dep_id's statuses" >&2
      echo "  $(cat "$tmp_dir/err")" >&2
      exit 2
    fi
    state="$(jq -r '.[0].state // empty' <<<"$statuses")"
    url="$(jq -r '[.[].environment_url | select(. != null and . != "")] | .[0] // empty' \
      <<<"$statuses")"
    inspect_url="$(jq -r '[.[].log_url | select(. != null and . != "")] | .[0] // empty' \
      <<<"$statuses")"
  fi

  # Terminal, or out of patience: stop asking. `inactive` is Vercel superseding
  # this deployment with a newer one for the same ref, which is terminal too.
  case "$state" in
    success|failure|error|inactive) break ;;
  esac
  (( $(date +%s) < deadline )) || break
  info "${state:-no deployment yet} — waiting"
  sleep 15
done

if [[ -z "$dep_id" ]]; then
  environments="$(jq -r '[.[].environment] | unique | join(", ")' <<<"$deployments")"
  bad "no Preview deployment for ${sha:0:7}"
  if [[ -n "$environments" ]]; then
    info "GitHub has deployments for this SHA in: $environments"
  else
    info "GitHub has no deployment for this SHA at all — either the branch is not"
    info "  pushed, Vercel has not picked it up yet (try --wait 120), or this"
    info "  repository is not deployed from Vercel"
  fi
  exit 2
fi

case "$state" in
  success) ok "the preview deployment built (${inspect_url:-no inspector URL})" ;;
  failure|error)
    bad "the preview deployment did not build — state: $state"
    [[ -n "$inspect_url" ]] && info "inspector: $inspect_url"
    ;;
  inactive)
    info "this deployment has been superseded by a newer one for the same ref"
    info "  — push again or re-run with the current head SHA"
    exit 2
    ;;
  "")
    bad "the deployment has no status yet"
    exit 2
    ;;
  *)
    bad "the preview deployment is still $state after ${wait_seconds}s"
    info "re-run with a longer --wait"
    exit 2
    ;;
esac

# --- The build log, when there is a failure to explain ------------------------
# Best-effort by design: the inspector URL above is the answer that always
# works, and this is the same answer without a browser. Vercel identifies a
# deployment by its host as readily as by its id, so the preview URL is the
# handle even when the build failed.
build_log() {
  [[ -n "${VERCEL_TOKEN:-}" ]] || {
    info "set VERCEL_TOKEN to get the build log here instead of the inspector"
    return 0
  }
  local handle="${url#https://}"
  handle="${handle%%/*}"
  [[ -n "$handle" ]] || return 0
  local events
  events="$(curl -sS --max-time 30 \
    -H "Authorization: Bearer $VERCEL_TOKEN" \
    "https://api.vercel.com/v3/deployments/$handle/events?builds=1&limit=100" \
    2>/dev/null)" || { info "could not reach the Vercel API for the build log"; return 0; }
  local lines
  lines="$(jq -r '[.[]? | .text // .payload.text // empty] | .[-40:] | .[]' \
    <<<"$events" 2>/dev/null)"
  if [[ -n "$lines" ]]; then
    info "the last of the build log:"
    printf '       %s\n' "${lines//$'\n'/$'\n'       }"
  else
    info "the Vercel API returned no build log for $handle"
  fi
}

if [[ "$state" == "failure" || "$state" == "error" ]]; then
  build_log
  exit 1
fi

# --- Does the deployed page answer? -------------------------------------------
if [[ -z "$url" ]]; then
  bad "the deployment succeeded but carries no URL to check"
  exit 2
fi

bypass="${VERCEL_AUTOMATION_BYPASS_SECRET:-}"

# A protected preview answers a 302 whose Location is the login flow, so the
# only reliable reading is of where the response points. Followed blindly it is
# a 200 from vercel.com — the failure mode this whole script is shaped around.
is_wall() {
  local location="$1" body_file="$2"
  case "$location" in
    https://vercel.com/login*|*"/sso-api"*) return 0 ;;
  esac
  grep -qi '_vercel_sso_nonce\|Authentication Required' "$body_file" 2>/dev/null
}

target="$url$path"
hops=0
final_code=""
while (( hops < 4 )); do
  curl_args=( -sS -o "$tmp_dir/body" -D "$tmp_dir/headers" -w '%{http_code}'
              --max-time 30 )
  [[ -n "$bypass" ]] && curl_args+=( -H "x-vercel-protection-bypass: $bypass" )
  if ! code="$(curl "${curl_args[@]}" "$target" 2>"$tmp_dir/err")"; then
    bad "$target could not be fetched: $(cat "$tmp_dir/err")"
    exit 1
  fi

  location="$(grep -i '^location:' "$tmp_dir/headers" | tail -n 1 \
    | tr -d '\r' | cut -d: -f2- | sed 's/^[[:space:]]*//')"

  if is_wall "$location" "$tmp_dir/body"; then
    if [[ -z "$bypass" ]]; then
      bad "the preview is behind Vercel Authentication and VERCEL_AUTOMATION_BYPASS_SECRET is not set"
      info "the deployment itself built fine — this says nothing about the branch"
      info "  generate the secret at Vercel → the project → Settings → Deployment"
      info "  Protection → Protection Bypass for Automation, and set it on this node"
    else
      bad "Vercel Authentication rejected the bypass secret"
      info "VERCEL_AUTOMATION_BYPASS_SECRET is set but not accepted — it has most"
      info "  likely been regenerated in the project's settings since this node"
      info "  was configured"
    fi
    exit 2
  fi

  case "$code" in
    3??)
      [[ -n "$location" ]] || break
      [[ "$location" == /* ]] && location="$url$location"
      info "$target → $code $location"
      target="$location"
      hops=$(( hops + 1 ))
      continue
      ;;
  esac
  final_code="$code"
  break
done

if [[ -z "$final_code" ]]; then
  bad "$target redirected more times than this check follows"
  exit 1
fi

case "$final_code" in
  2??)
    ok "$target answered $final_code"
    printf '\nthe preview is deployed and serving\n'
    exit 0
    ;;
  *)
    bad "$target answered $final_code"
    info "the deployment built, so this is the application failing rather than"
    info "  the build — the runtime logs are at ${inspect_url:-the Vercel dashboard}"
    exit 1
    ;;
esac
