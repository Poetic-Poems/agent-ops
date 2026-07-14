# Writing the improvement prompts

The prompts in `04-improvement-prompts.md` are the part of the review most likely to be *executed*, verbatim, by an AI agent that has none of the review's context. Write them accordingly.

## One prompt per recommendation

Default to exactly one prompt per recommendation. Bundle two or more recommendations into a single prompt only when there is a positive reason:

- they modify the same files, so separate passes would conflict or duplicate effort;
- one is a strict precondition of the other and the second is small;
- they are two faces of one change (e.g., "add CI" and "make the linter pass" when CI's first job is the linter).

State the reason for any bundling in the document, in the prompt's **Bundles** line. "They are both documentation-ish" is not a positive reason.

## What every prompt must contain

Each prompt must stand alone in a fresh agent session. Include, in roughly this order:

1. **Context.** One short paragraph: what the project is, the stack, and where the relevant code lives (concrete paths). Assume the agent can read the repository but knows nothing about it.
2. **The problem.** The finding, restated with its evidence (paths and line references). Do not merely cite `F-SEC-01` — the executing agent will not have the review documents unless told where they are; restate what it needs.
3. **The goal.** The intended end state from the recommendation, as concrete acceptance criteria the agent can check itself against.
4. **Constraints.** What must not change: public APIs, behaviour, style conventions to follow, files to leave alone, licence or dependency policies.
5. **Verification.** Exactly how to prove the work is done: commands to run (tests, linters, audits, builds) and what their output should show. Require the agent to run these before declaring completion.
6. **Cost policy.** The cost-sensitivity block below.
7. **Deliverable.** What to hand back: a diff/commit with a summary, an updated `TECH-DEBT.md` entry marked resolved, a short report — whatever fits.

Keep prompts as short as completeness allows. A prompt that pads its context wastes the very tokens the cost policy is trying to save.

## The cost policy block

Include a cost-sensitivity instruction in every prompt, adapted to the task. Refer to model capability **only in generic tiers** — low-cost, mid-cost, high-capability — never by product or model name, which would date the prompt. The canonical wording, to adapt rather than copy blindly:

```text
Work cost-consciously. Where your environment supports subagents, delegate
well-specified, self-contained subtasks to subagents running the lowest-cost
model tier that has a high probability of completing the subtask correctly at
the first attempt — a failed cheap attempt that must be redone costs more than
doing it right once. As a rule of thumb: mechanical, well-specified work
(renames, applying a documented pattern across files, writing tests for
specified behaviour, formatting) suits a low-cost tier; ordinary implementation
against clear acceptance criteria suits a mid-cost tier; reserve a
high-capability tier for ambiguous, cross-cutting, security-critical, or
design-level work, and for reviewing the output of cheaper tiers where the
risk warrants it. Verify all delegated work before integrating it. If
subagents are unavailable, simply complete the task directly and keep the
work focused.
```

Tune the rule-of-thumb line to the specific task: a prompt that is *entirely* mechanical can say so ("this whole task suits a low-cost tier"); a security fix should insist the fix itself is done and reviewed at a high-capability tier even if its test-writing is delegated cheaply.

## Ordering and dependencies

Present prompts in the recommendation order (severity first, quick wins first at equal severity). Where one prompt's work depends on another's — CI must exist before a prompt can "make CI green" — say so both in the preamble and in the dependent prompt's **Run after** line, and repeat the dependency inside the prompt text itself ("This task assumes R-02 has been completed; verify that <artefact> exists before starting.").

## Tone and address

Write prompts in the imperative, addressed to the executing agent. Do not include pleasantries, and do not include the review's own prose style — the prompt is an instrument, not a report.
