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
| [Tech debt filed](<the `pw::type:tech-debt` issue search URL for this repository, or the register's own path if the project still has one>) | <One or two sentences: how many new issues this review filed, and whether any existing register item was marked resolved.> |
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

## Tech debt

**New debt is always filed as a GitHub issue**, labelled `pw::type:tech-debt`,
in the project under review — never as a register file, whether or not the
project has a register in either format below, and never by inventing a
register where none exists. Search first:
`gh issue list --label pw::type:tech-debt --search "<working title>" --state
all` — a close match means the gap is already tracked, so cite its number
instead of filing a second issue for it. File each new item with
`gh issue create --label pw::type:tech-debt --title "<title>" --body
"<body>"`:

```markdown
**Severity:** <Critical / High / Medium / Low>

<Free prose: what the compromise is, with paths; why it exists, if discernible, otherwise "Unknown"; its ongoing cost — what it slows, risks, or breaks; and a suggested remedy.>

Review: <report_dir> R-<NN> F-<CODE>-<NN>
```

The `Review:` line is the item's provenance, in the same place a register's
`review:` frontmatter line or Ledger table would have carried it — write it
whenever the item mirrors a recommendation's whole *Intended end state*
(never for a partial match, which stays visible in the review channel
instead). In the Claude.ai chat, where GitHub is not directly reachable,
list each item that would be filed — title, body, and any recommendation it
mirrors — in the summary presented to the user instead, and tell them where
to file it.

**An existing register is history, not a filing destination.** Registers
come in two formats: **per-item** — a `tech-debt/` directory exists, or the
project's own `TECH-DEBT.md` declares `scope:` in its YAML frontmatter, and
each item lives in its own `tech-debt/<id>.md` file, with `TECH-DEBT.md`
holding only policy — or **legacy**: a single `TECH-DEBT.md` holding
`### <id> <title>` sections under a "Current Items" heading plus a permanent
"Ledger" table. Never file new debt into either format, and never migrate
one to the other as a side effect of a review. Where the review finds an
existing item already resolved, still update it **in place, in its own
format**:

- **Per-item:** flip the item's frontmatter only (`status: resolved`,
  `resolved:` date, `ref:`) — never its body, and never delete or rename the
  file.
- **Legacy:** update the item's status in `TECH-DEBT.md` directly, in the
  file's own established style (do not delete the entry).

Tech debt overlaps with, but is not identical to, the findings: debt is a
known compromise that lives with the project; a filed issue (or an existing
register entry) is the durable record that survives after the dated review
folder is archived. Duplication between the two is acceptable and expected.
