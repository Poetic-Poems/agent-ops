# Project review — agent-ops

**Date:** 2026-08-23 · **Reviewer:** Claude (project-review skill) · **Revision reviewed:** `41414b0`

Poetic-Poems/agent-ops is a fast-moving, unusually disciplined 42-day-old autonomous CI/CD pipeline system (~27,000 lines of Bash/Perl, a 52,000-line test suite, and a 17,320-line as-built spec kept genuinely in sync with the code) — but it carries one Critical exposure that outweighs everything else this review found: every pipeline stage runs with unrestricted tool access and a live write-scoped GitHub token while processing verbatim, untrusted text from three confirmed-public repositories, with no technical barrier against a prompt-injection-to-exfiltration path. Fix that first (R-01); everything else here is real but secondary, including a second-priority architectural debt in the pipeline's main entry point and a test-suite clock-coupling bug that already caused one production incident.

## Contents

| Document | What it contains |
|---|---|
| [Summary](01-summary.md) | What the project is, its overall health, headline strengths and risks, and the review's scope and method. |
| [Findings](02-findings.md) | All 39 findings by dimension: 1 Critical, 2 High, 16 Medium, 20 Low. |
| [Recommendations](03-recommendations.md) | 17 prioritised recommendations grouping the 39 findings, each with its intended end state. |
| [Improvement prompts](04-improvement-prompts.md) | One self-contained, ready-to-paste AI agent prompt per recommendation, in priority order. |
| [Tech debt register](../../tech-debt/) | Updated in place (per-item format) with new items for findings not already tracked; see individual `TD-PPagop-*` items filed by this review. |
