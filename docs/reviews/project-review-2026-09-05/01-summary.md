# Summary

## What this project is

`Poetic-Poems/agent-ops` is the operations tooling for the Poetic autonomous coding-agent
pipelines: a self-hosted, unattended system that selects, implements, and reviews work across
`poetic`, `poetic-fiddle`, and agent-ops itself, then raises mergeable pull requests for human
review at a configurable autonomy level. It is almost entirely Bash (310 `.sh` files, ~56,000
lines across `lib/`, `scripts/`, and the two entry points) plus five Perl scripts, a single-file
vanilla-JS/HTML monitoring dashboard, and unusually large as-built Markdown specifications
(`docs/IMPLEMENTATION-PIPELINE-SPEC.md` alone is 22,998 lines). It has a single maintainer
(`warwickallen`/`Warwick-Allen`, two deliberately distinct GitHub accounts used for authoring vs.
review), is under two months old, and runs hourly against the GitHub and Anthropic APIs with
real credentials and real autonomous-merge authority over production repositories.

## Overall assessment

agent-ops remains, on this its third review, an unusually mature and actively self-improving
project for its age. Its review→register→fix loop demonstrably works: this run traced a real
production incident (a GitHub-API pagination bug that twice triggered a fleet-wide autonomous
pipeline stand-down on 2026-09-04) that was discovered, root-caused, fixed, and covered by a
corrected regression test — all inside a 24-hour window, and landed as the very commit this
review's revision is pinned to. No Critical or High finding exists in this repository: no live
secret, no exploitable injection path, no unsafe credential handling. The 13 recommendations from
the prior review (2026-08-31) remain open — none has yet been acted on in the six days since,
though none has regressed either, and this review's re-verification found the codebase state
underlying each essentially unchanged. The single most important thing to act on is the same one
the prior review named: `agent-cycle.sh`'s ~2,000-line undecomposed main flow and the six
stage-orchestration functions that keep absorbing new feature work in place rather than shrinking
(R-08) — two commits landed the day before this review add directly to that pattern, which is a
live signal that the gap is not self-correcting through normal development. The second most
useful new finding this round is R-05: `scripts/publish-dashboard.sh` carries an untested,
unpatched sibling of the exact pagination bug that caused the 2026-09-04 incident, silently
truncating the dashboard's issue-priority display today.

## Headline strengths

- Credential handling remains exemplary: GitHub App tokens never touch `curl` argv, live only in
  a permission-checked tmpfs cache, and are never logged; a fresh full-history secret scan found
  nothing live [SEC].
- The as-built-spec discipline `CLAUDE.md` mandates is genuinely followed, not merely claimed —
  two spot-checked commits each landed code, dashboard copy, spec text, and test fixtures in
  perfect lockstep in a single commit [DOC].
- The project catches its own operational bugs fast: three separate incidents (a null-figure
  report bug, a rate-limit false reading, and the pagination outage) were each found, fixed, and
  regression-tested within a day of discovery [OPS, PERF, TEST].
- Rate-limit and budget engineering is disproportionately mature for an hourly-cron pipeline —
  primary/secondary rate-limit separation, a GraphQL migration for hot reads, and per-node
  load-spreading all landed as measured, tested improvements [PERF].
- The tech-debt register and issue-tracking discipline are healthy and consistent (204 register
  items, 95 open, 108 resolved; `td-check.pl` reports no anomalies) [GOV].

## Headline risks

- `agent-cycle.sh`'s main flow and six `lib/` stage-orchestration functions remain undecomposed,
  and the two most recent feature commits both added to the pattern rather than breaking it
  [F-ARCH-01, F-CODE-01].
- `scripts/publish-dashboard.sh`'s issues fetch has the identical untested single-page pagination
  gap that caused a real fleet-wide stand-down elsewhere in the codebase six days ago — it is
  live today, silently truncating Priority data for ~140 of agent-ops's own 170 open issues
  [F-TEST-04].
- The dashboard's misleadingly-named `esc()` helper still does not escape HTML; not exploitable
  today, but the codebase-wide "trust `esc()`" assumption it invites is a real latent hazard
  [F-SEC-01].
- No `SECURITY.md` or disclosure route exists for a project that holds live credentials and
  autonomous merge authority, and a decided-but-unapplied licence change (FSL-1.1-ALv2) leaves
  today's MIT-licensed public repository silently out of step with its own roadmap [F-SEC-02,
  F-GOV-01].
- The dashboard's clickable rows/cards remain entirely mouse-only, unlike the PR-hover-card code
  a few hundred lines away in the same file that already handles keyboard operation correctly
  [F-UX-01].

## Scope and method

This review re-examined the codebase against its current revision (`916a951`, 2026-09-05),
treating the 2026-08-31 review (revision `857bc1d7`) as a verified baseline since only 13
substantive commits separate the two. All 13 checklist dimensions were delegated to six parallel
subagents, paired to keep related evidence together (ARCH+CODE, SEC+DATA, TEST+CI, DEPS+TOOL,
PERF+OPS, UX+DOC+GOV). Each subagent was instructed to re-verify every prior finding against
current code with fresh evidence, explicitly flag anything now resolved, and separately hunt for
new findings — from the 13 intervening commits, from a deeper pass over areas the prior review
sampled lightly (notably `dashboard/index.html`'s CODE-dimension complexity), and from a fresh
full-history secret scan.

Full read: both entry points (`agent-cycle.sh`, `review-cycle.sh`); every credential/token-handling
`lib/` file (`lib/github-app-token.sh`, `lib/approver-token.sh`, `lib/author-token.sh`,
`lib/forge-auth.sh`, `lib/claim.sh`); `dashboard/index.html` in full for its security- and
accessibility-relevant sections and, this round, its complexity hot-spots. Sampled by risk: the
remaining `lib/` (73 files) and `scripts/` (59 files), weighted toward files touched by the 13
new commits and toward the six largest stage-orchestration functions; `test/*.test.sh` (176
files) cross-referenced by name and by scenario content against the riskiest `lib/` files; specs
and README checked for drift against code at specific, spot-checked commits rather than read
word-for-word given their combined size (over 40,000 lines).

Tools run directly: `shellcheck` 0.10.0 (both a raw invocation, which OOM-killed in this sandbox
and confirmed the repo's own `scripts/lint-shell.sh` memory-guard rationale, and the repo's own
guarded wrapper, which ran clean); `gh api`/`gh issue` extensively, to verify every cited issue's
live open/closed state and the branch-protection ruleset's actual required-check list rather than
trusting the prior review's snapshot; full-history `git log --all -S<pattern>` secret searches.

Not run: `docker` is unavailable in this reviewing environment, so `scripts/run-tests.sh` (which
runs the 176-file test suite inside a container by design, to pin `jq` version behaviour) could
not be executed — the same limitation the prior two reviews recorded. No automated accessibility
checker (axe, Lighthouse) was available for the dashboard's UX dimension. Both limitations are
stated explicitly in the relevant findings rather than silently worked around.

Judged inapplicable, with reasons stated at the point of finding rather than left silent:
`npm audit`/equivalent dependency-vulnerability scanning [DEPS] — no package manifest of any kind
exists anywhere in the repository; internationalisation [UX] — a single-operator local tool with
no localisation surface.
