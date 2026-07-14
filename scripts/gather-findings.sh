#!/usr/bin/env bash
#
# gather-findings.sh — pre-fetch a repo's open security and code-quality
# findings for the Co-Ordinator (docs/BUILD-PROMPT.md, requirement 3a).
#
# Given a GitHub repo slug (owner/repo), pull the repo's open Dependabot
# alerts and open code-scanning alerts via `gh api`, normalise each into a
# compact finding, and print the lot as a single JSON array on stdout, most
# security-relevant and most severe first.
#
# This runs in the Script, not in a model, precisely so the cheap Co-Ordinator
# session never spends tokens paginating and digesting those verbose APIs.
#
# Fails safe: if a feature is disabled on the repo, or the token can't read it,
# that source contributes no findings and the script still prints valid JSON
# and exits 0 — a missing feature must never abort a cycle.
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

set -euo pipefail

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "gather-findings: usage: gather-findings.sh <owner/repo>" >&2
  exit 64
fi

# Stream every element of a paginated GitHub list endpoint as newline-separated
# JSON objects. On any failure (feature off, 403/404, no gh) print nothing, so
# the caller's `jq -s` slurps it to an empty array.
fetch() {
  gh api --paginate "$1" --jq '.[]' 2>/dev/null || true
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
