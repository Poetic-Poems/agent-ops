# Project review — agent-ops

**Date:** 2026-09-05 · **Reviewer:** Claude (project-review skill) · **Revision reviewed:** `916a951` (`main`)

agent-ops remains, on its third review, an unusually mature and actively self-improving pipeline
for its age: this run traced a real production incident — a GitHub-API pagination bug that twice
triggered a fleet-wide autonomous-pipeline stand-down on 2026-09-04 — that was found, fixed, and
regression-tested inside 24 hours, landing as the very commit this review is pinned to. No
Critical or High finding exists anywhere in the repository. All 13 recommendations from the prior
review (2026-08-31) remain open and unresolved in code, reconfirmed here with refreshed evidence;
the single most important thing to act on is unchanged — `agent-cycle.sh`'s ~2,000-line
undecomposed main flow and six oversized `lib/` stage functions (R-08) — and two commits landing
the day before this review both added to that same pattern rather than shrinking it. The most
useful new finding this round is R-05: `scripts/publish-dashboard.sh` carries an untested,
unpatched sibling of the exact pagination bug that caused the 2026-09-04 outage, silently
truncating the dashboard's issue-priority display today.

## Contents

| Document | What it contains |
|---|---|
| [Summary](01-summary.md) | What the project is, its overall health, headline strengths and risks, and this review's scope and method. |
| [Findings](02-findings.md) | All 34 findings by dimension: 0 critical, 0 high, 11 medium, 23 low. |
| [Recommendations](03-recommendations.md) | 18 prioritised recommendations, each mapped to the finding(s) it addresses and to a tracking GitHub issue or tech-debt record. |
| [Improvement prompts](04-improvement-prompts.md) | One self-contained, ready-to-paste AI-agent prompt per recommendation, in priority order. |
| [Tech debt filed](https://github.com/Poetic-Poems/agent-ops/issues?q=label%3Apw%3A%3Atype%3Atech-debt) | 4 new issues filed this run (agent-ops#1171–#1174); 14 findings matched issues or tech-debt register items already open from the 2026-08-23/2026-08-31 reviews, cited rather than duplicated. No existing register item was found resolved this run. |

## Scope note

This review was conducted against a fresh clone on `main`, treating the 2026-08-31 review
(revision `857bc1d7`, only 13 substantive commits earlier) as a verified baseline. The 13
checklist dimensions were delegated to six parallel subagents, each tasked with re-verifying
every prior finding with fresh evidence *and* hunting for new findings from the intervening
commits and from deeper sampling. See [Summary § Scope and method](01-summary.md#scope-and-method)
for exactly what was read in full, what was sampled, and what could not be run in this
environment (notably: the Dockerized test suite, and an automated accessibility checker).
