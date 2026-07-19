# Output document templates

All outputs are Markdown. Follow these templates in structure; adapt headings only where the project genuinely demands it. `<angle brackets>` mark material to replace. Keep the index brief — it is a table of contents, not a fifth report.

## `README.md` (the index)

```markdown
# Project review — <project name>

**Date:** <YYYY-MM-DD> · **Reviewer:** Claude (project-review skill) · **Revision reviewed:** <commit hash / version / "uploaded archive">

<One paragraph: the overall verdict in plain language — what this project is, its general health, and the single most important thing to act on.>

## Contents

| Document | What it contains |
|---|---|
| [Summary](01-summary.md) | <One or two sentences.> |
| [Findings](02-findings.md) | <One or two sentences, including the finding count by severity, e.g., "31 findings: 2 critical, 7 high, 14 medium, 8 low.".> |
| [Recommendations](03-recommendations.md) | <One or two sentences, including the number of recommendations.> |
| [Improvement prompts](04-improvement-prompts.md) | <One or two sentences.> |
| [Tech debt register](<relative path to TECH-DEBT.md>) | <One or two sentences; note whether it was updated or newly created.> |
```

Add rows for any supplementary annexes.

## `01-summary.md` (high-level summary)

```markdown
# Summary

## What this project is
<Two or three paragraphs: purpose, audience, stack, size, maturity — established from the project's own evidence.>

## Overall assessment
<A candid paragraph or two. Lead with the overall health; name the headline risks and the headline strengths. No hedging, no padding.>

## Headline strengths
<Three to six bullet points, each one sentence, each pointing at something real and specific.>

## Headline risks
<Three to six bullet points, each one sentence, each with the finding ID(s) in brackets.>

## Scope and method
<What was examined and how: exhaustive or sampled (and the sampling strategy); which automated tools were run and which could not be (and why); which dimensions were judged inapplicable. This section is what makes the review trustworthy — be precise.>
```

## `02-findings.md` (detailed findings)

```markdown
# Findings

<One short orienting paragraph, then a severity tally table.>

| Severity | Count |
|---|---|
| Critical | <n> |
| High | <n> |
| Medium | <n> |
| Low | <n> |

## <Dimension name> (<CODE>)

**Strengths:** <One to three sentences on what this dimension gets right, or "None observed.".>

### F-<CODE>-<NN> — <short title> · **<Severity>**

**Evidence:** <Paths with line references, command output, or excerpts.>

**Impact:** <Why this matters for this project.>

**Direction:** <One line; the full remedy lives in the recommendations. Cross-reference: addressed by R-<NN>.>
```

Repeat the finding block per finding and the dimension block per dimension, in the checklist's dimension order. Inapplicable dimensions still get their heading, with a one-line explanation.

## `03-recommendations.md` (prioritised recommendations)

```markdown
# Recommendations

<One short paragraph explaining the ordering: severity first, then quick wins before long campaigns.>

| ID | Recommendation | Severity | Effort | Addresses |
|---|---|---|---|---|
| R-01 | <Short title.> | <Severity> | <Effort> | F-SEC-01, F-SEC-03 |

## R-<NN> — <title>

**Severity:** <highest severity among addressed findings> · **Effort:** Small/Medium/Large · **Addresses:** <finding IDs>

**Current state:** <One or two sentences.>

**Intended end state:** <What "done" looks like, concretely — this doubles as the acceptance criteria for the improvement prompt.>

**Approach:** <A few sentences or a short list: the suggested route, notable constraints, and any dependency on other recommendations.>
```

Every `Critical` and `High` finding must appear in some recommendation's **Addresses** list.

## `04-improvement-prompts.md` (agent prompts)

```markdown
# Improvement prompts

<Short preamble: one prompt per recommendation, in priority order; each prompt is self-contained and may be pasted into a fresh AI agent session. Note any ordering dependencies here as well as within the prompts.>

## Prompt for R-<NN> — <title>

**Bundles:** <"R-<NN> only", or the bundled IDs and the positive reason for bundling.> · **Run after:** <prompt IDs, or "no prerequisites">

​```text
<The prompt itself — see references/prompt-writing.md for its required contents.>
​```
```

## `TECH-DEBT.md` (tech-debt register)

If the project already has a tech-debt file, **preserve its format and its existing entries**: update statuses, mark items the review found to be resolved (do not delete them), and append newly found debt in the file's own style, noting the review date. Only if no such file exists, create `TECH-DEBT.md` at the project root:

```markdown
# Tech debt register

Deferred work and known compromises, most severe first. Each live item is a level-three `### <id> <title>` section under the "Current Items" heading; when an item is resolved its `### ` section is removed but its Ledger row is kept forever, so IDs are never reused. Last reviewed: <YYYY-MM-DD> (project-review).

`<id>` is `TD<YYMMDD><NN>`: a "TD" prefix, the date, then a zero-padded per-day sequence number — one more than the highest `NN` for that date in the Ledger (use the repo's `next-tech-debt-id` helper if it has one, otherwise count from the Ledger, which is the source of truth for the next free ID).

## Review provenance

Where an item mirrors a recommendation, map it here so the review and the register are not double-counted.

| Recommendation | Ledger ID |
|----------------|-----------|
| R-<NN> — <short title> | <id> |

## Current Items

The open items, each as a `### <id> <title>` section. This heading is permanent: when there are no current items it stays here (empty), so it is always obvious where a new item's body belongs.

### <id> <short title>
- **Severity:** <Critical / High / Medium / Low>
- **What:** <The compromise, with paths.>
- **Why it exists:** <The reason, if discernible; otherwise "Unknown — predates this register.".>
- **Ongoing cost:** <What it slows, risks, or breaks.>
- **Suggested remedy:** <One or two lines; cross-reference R-<NN> / F-<CODE>-<NN> where applicable.>

## Ledger

Every tech-debt ID ever allocated, in ID order. A row is never removed — even after its `### ` body is — so a resolved item's ID is never reused.

| ID | Title | Status | Resolved | Ref |
|----|-------|--------|----------|-----|
| <id> | <short title> | Open | | |
```

Tech debt overlaps with, but is not identical to, the findings: debt is a known compromise that lives with the project; the register is the durable file that survives after the dated review folder is archived. Duplication between the two is acceptable and expected.
