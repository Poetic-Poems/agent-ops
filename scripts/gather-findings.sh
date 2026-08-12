#!/usr/bin/env bash
#
# gather-findings.sh — pre-fetch a repo's open security and code-quality
# findings for the Co-Ordinator (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 3a).
#
# Given a GitHub repo slug (owner/repo), pull the repo's open Dependabot
# alerts and open code-scanning alerts via `gh api`, normalise each into a
# compact finding, and print the lot as a single JSON array on stdout, most
# security-relevant and most severe first.
#
# This runs in the Script, not in a model, precisely so the cheap Co-Ordinator
# session never spends tokens paginating and digesting those verbose APIs.
#
# Fails safe: a disabled feature (Dependabot or code scanning turned off, which
# GitHub answers with 404, or 403 with a message naming the feature rather
# than a rate limit) contributes no findings and the script still prints valid
# JSON and exits 0 — a missing feature must never abort a cycle. A real
# failure (a timeout, a rate limit, an outage) is different: it must not
# render exactly like "nothing to report" (TD-PPagop-26080201), so it is
# distinguished from an absent feature the same way
# scripts/gather-register-hygiene.sh tells a repo with no register apart from
# an API that would not answer — the error body's own `.status` — and the
# script exits 1 rather than swallowing it. 403 alone cannot carry that
# distinction on its own, unlike 404: GitHub uses it both for "this feature is
# turned off here" and for "you have been rate-limited", so a 403 is only
# legitimate when its own message does not say rate limit.
#
# Usage: gather-findings.sh <owner/repo>
#
# Normalised finding shape:
#   {
#     "source": "security" | "code-quality",
#     "kind": "dependabot" | "code-scanning",
#     "security": true | false,
#     "severity": "critical|high|medium|low|error|warning|note|unknown",
#     "number": 42,
#     "ref": "dependabot-alert-42" | "code-scanning-alert-17",
#     "title": "…",
#     "url": "https://github.com/…",
#     ...source-specific: package/manifest (dependabot), rule/location/tool (code-scanning)
#   }

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "gather-findings: usage: gather-findings.sh <owner/repo>" >&2
  exit 64
fi

work="$(mktemp -d)" || { printf '[]'; exit 0; }
trap 'rm -rf "$work"' EXIT

# Marked by fetch() the moment any call fails for a reason other than a
# disabled feature, checked once at the end. A file, not a shell variable:
# every caller below pipes fetch's output onward (`fetch … | jq -s …`), and
# both that pipe and the `$(...)` around it run fetch in a subshell, where a
# plain variable set inside it would vanish the moment the subshell exits.
fail_file="$work/fail"

# Stream every element of a paginated GitHub list endpoint as newline-separated
# JSON objects. A disabled feature or a repo the token can't see (403/404)
# prints nothing and leaves `fail_file` untouched — the caller's `jq -s` slurps
# the silence to an empty array, exactly as it always has. Anything else (rate
# limit, timeout, outage) leaves gh's own diagnosis on stderr and marks
# `fail_file`. `--paginate` means one non-2xx page fails the whole call, so its
# exit status speaks for every page.
# DASHBOARD_GH_CMD is the Publisher's test seam (see scripts/publish-dashboard.sh);
# honouring it here is what keeps a stubbed publish from reaching the network
# through this script's back door. Unset everywhere else, where it is `gh`.
fetch() {
  local errfile body rc status message legitimate
  errfile="$(mktemp "$work/err.XXXXXX")"
  body="$("${DASHBOARD_GH_CMD:-gh}" api --paginate "$1" 2>"$errfile")"
  rc=$?
  if (( rc != 0 )); then
    status="$(jq -r '.status // ""' <<<"$body" 2>/dev/null)"
    message="$(jq -r '.message // ""' <<<"$body" 2>/dev/null)"
    legitimate=0
    [[ "$status" == "404" ]] && legitimate=1
    [[ "$status" == "403" ]] && ! grep -qi 'rate limit' <<<"$message" && legitimate=1
    if (( ! legitimate )); then
      cat "$errfile" >&2
      echo 1 >> "$fail_file"
    fi
    rm -f "$errfile"
    return 0
  fi
  rm -f "$errfile"
  printf '%s' "$body" | jq -c '.[]?' 2>/dev/null
}

# Dependabot alerts are security by definition.
dependabot_json="$(fetch "repos/$slug/dependabot/alerts?state=open&per_page=100" | jq -s '
  [ .[] | {
    source: "security",
    kind: "dependabot",
    security: true,
    severity: (.security_advisory.severity // .security_vulnerability.severity // "unknown"),
    number: .number,
    ref: ("dependabot-alert-" + (.number | tostring)),
    title: ((.dependency.package.name // "dependency") + ": " + (.security_advisory.summary // "known vulnerability")),
    package: (.dependency.package.name // null),
    manifest: (.dependency.manifest_path // null),
    url: .html_url,
    state: .state
  } ]
')"

# Code-scanning alerts: security when the rule carries a security severity,
# otherwise a code-quality (maintainability/correctness/style) finding.
code_scanning_json="$(fetch "repos/$slug/code-scanning/alerts?state=open&per_page=100" | jq -s '
  [ .[] | (.rule.security_severity_level) as $ssl | {
    source: (if $ssl != null then "security" else "code-quality" end),
    kind: "code-scanning",
    security: ($ssl != null),
    severity: ($ssl // .rule.severity // "warning"),
    number: .number,
    ref: ("code-scanning-alert-" + (.number | tostring)),
    rule: (.rule.id // .rule.name // null),
    title: (.rule.description // .most_recent_instance.message.text // .rule.name // "code scanning alert"),
    location: ((.most_recent_instance.location.path // "?") + ":" + ((.most_recent_instance.location.start_line // 0) | tostring)),
    tool: (.tool.name // null),
    url: .html_url,
    state: .state
  } ]
')"

# Combine and order: security first, then by descending severity, so the
# Co-Ordinator meets the highest-stakes finding at the top of the list.
jq -n --argjson dep "$dependabot_json" --argjson cs "$code_scanning_json" '
  def rank($s): {critical:5, high:4, error:3, medium:3, warning:2, low:2, note:1}[$s] // 0;
  ($dep + $cs)
  | sort_by([ (if .security then 1 else 0 end), rank(.severity) ])
  | reverse
'

# A real failure on either call exits 1 so the Publisher (and any other
# caller) can tell it apart from a repo with neither alert type enabled —
# exactly the distinction TD-PPagop-26080201 exists to draw. The findings
# gathered from whichever call *did* answer are still printed above; a partial
# read is safe to show, and the caller discards it anyway once it sees this
# exit code, the same way every other source here treats a failed read.
[[ -s "$fail_file" ]] && exit 1
exit 0
