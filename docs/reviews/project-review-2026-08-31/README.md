# Project review — agent-ops

**Date:** 2026-08-31 · **Reviewer:** Claude (project-review skill) · **Revision reviewed:** `857bc1d7` (`main`)

agent-ops is a young (under two months old) but unusually mature single-maintainer autonomous
coding-agent pipeline, almost entirely Bash, with real branch-protection CI, a large
incident-grounded test suite, and disciplined credential handling — this review raised zero
Critical or High findings, and its most striking result is comparative: the prior review's
top architectural concern (`agent-cycle.sh`'s size) was substantially fixed within the
intervening 8 days, real evidence that this project's review→register→fix loop works. The
single most important thing to act on is finishing that same decomposition one layer further
(R-01) — the pipeline's main entry-point flow, and the largest functions the last refactor
relocated but didn't shrink, are still the project's biggest concentration of untestable,
high-stakes complexity.

## Contents

| Document | What it contains |
|---|---|
| [Summary](01-summary.md) | What the project is, its overall health, headline strengths and risks, and this review's scope and method. |
| [Findings](02-findings.md) | All 29 findings by dimension: 0 critical, 0 high, 9 medium, 20 low. |
| [Recommendations](03-recommendations.md) | 13 prioritised recommendations, each mapped to the finding(s) it addresses and to a tracking GitHub issue. |
| [Improvement prompts](04-improvement-prompts.md) | One self-contained, ready-to-paste AI-agent prompt per recommendation, in priority order. |
| [Tech debt filed](https://github.com/Poetic-Poems/agent-ops/issues?q=label%3Apw%3A%3Atype%3Atech-debt) | 6 new issues filed this run (agent-ops#1144–#1149); 7 more findings matched issues already open from the 2026-08-23 review, cited rather than duplicated. One existing register item (`tech-debt/TD-PPagop-26082503.md`) was found already resolved in code and its frontmatter flipped to `status: resolved` as part of this review. |

## Scope note

This review was conducted against a fresh clone on `main`, with the 13 checklist dimensions
delegated to six parallel subagents. It samples deliberately rather than reading all ~122k
lines of shell exhaustively; see [Summary § Scope and method](01-summary.md#scope-and-method)
for exactly what was read in full, what was sampled, and what could not be run (notably: the
full Dockerized test suite, and an automated accessibility checker — both were unavailable in
the reviewing environment).
