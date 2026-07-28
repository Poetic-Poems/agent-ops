# Metering schema — as-built specification

Companion to `docs/IMPLEMENTATION-PIPELINE-SPEC.md` (requirement 33a) and
`docs/REVIEW-PIPELINE-SPEC.md` (R16), and referenced by `docs/DASHBOARD-SPEC.md`.
This document is the field-by-field contract for the per-stage, per-cycle
token and cost accounting both pipelines produce: field names, types, units,
aggregation rules, and a stability policy for changing any of it later. Like
its companions it is as-built — it describes the metering data that exists
today, not a plan for data that will exist later. Where it says "requirement
N", it means requirement N of `docs/IMPLEMENTATION-PIPELINE-SPEC.md`.

## What this covers

Two related things carry the pipelines' spend data, and this document is the
contract for both:

- The **per-stage metering record**, attached to every `stage-end` /
  `review-stage-end` event in `log.jsonl` / `review-log.jsonl` (requirement
  33a): what one invocation of `claude` cost, how long it took, which model it
  ran, and how many tokens it moved.
- The **per-cycle and roll-up aggregates** the monitoring dashboard computes
  from those transcripts across both pipelines' history
  (`docs/DASHBOARD-SPEC.md`): a cycle's total cost, and fleet-wide spend by
  day, by model, and by actor.

Both derive from the same upstream source: the JSON envelope
`claude --output-format json` writes to `<stage>.out` (dashboard spec,
"`cycles/<cycle-id>/<stage>.out`"). This document does not restate that
envelope's own schema — that is Anthropic's contract, not this repo's, and
only a subset of it is used here. It documents the fields **this repo depends
on**, the shape it derives from them, and the guarantee it makes about that
shape going forward.

## Per-stage record

Carried on every `stage-end` (`agent-cycle.sh`) and `review-stage-end`
(`review-cycle.sh`) event, alongside that event's existing `stage`/`repo` and
`exit_code` fields (requirement 33). Produced by `lib/metering.sh`'s
`metering_fields` — the one implementation both pipelines call, so a stage in
either emits the same shape.

| Field | Type | Unit | Meaning |
| --- | --- | --- | --- |
| `model` | string \| null | — | The model id passed to the `claude` invocation (the same string `config.json` names, resolved per `lib/model-id.sh`). `null` only if the stage never ran. |
| `cost_usd` | number \| null | US dollars | The envelope's own `total_cost_usd` — a **client-side estimate** Claude Code computes from token counts, not a charge or a draw against any plan limit (`docs/DASHBOARD-SPEC.md`'s design decision on plan limits makes the same point about the dashboard's own cost figures). Includes any subagents the stage's own invocation spawned. `null` if the envelope is missing or unparseable. |
| `duration_ms` | integer \| null | milliseconds | The envelope's `duration_ms`: wall-clock time for the invocation. |
| `num_turns` | integer \| null | count | The envelope's `num_turns`. |
| `is_error` | boolean \| null | — | The envelope's `is_error`. |
| `tokens` | object \| null | — | Token counts by kind, summed across every model the invocation's own tree used — see below. `null` if the envelope carries no `modelUsage` map (an empty or malformed envelope). |
| `tokens.input` | integer | tokens | Sum of each model's `inputTokens`. |
| `tokens.output` | integer | tokens | Sum of each model's `outputTokens`. |
| `tokens.cache_creation` | integer | tokens | Sum of each model's `cacheCreationInputTokens` — tokens written to the prompt cache. |
| `tokens.cache_read` | integer | tokens | Sum of each model's `cacheReadInputTokens` — tokens served from the prompt cache. |

A field's absence from the envelope is distinct from it being genuinely zero
or `false` — a stage entirely served from cache can have `cost_usd: 0`, and
`is_error: false` is the common case, not a null. `metering_fields` preserves
that distinction rather than treating a present-but-falsy value as missing.

`tokens` sums the envelope's own `modelUsage` map (one entry per model
actually used, keyed by model id) rather than reading its top-level `usage`
object, because `usage` excludes subagent activity while `modelUsage` — like
`cost_usd` — includes it; the two fields would otherwise disagree about what
"this stage" spent. A stage that used one model end to end has one entry to
sum; a stage whose subagents ran a different model has several, and `tokens`
reports their total, not a per-model breakdown — `model` above already names
the invocation's own model, and a full per-model breakdown was not needed by
any reader this schema serves.

## Per-cycle aggregate

`cycles[].total_cost_usd` (`docs/DASHBOARD-SPEC.md`) is the sum of `cost_usd`
across every stage that ran in that cycle, treating a stage that never ran
(`cost_usd: null`) as `0`. No other per-cycle field is currently aggregated
from the per-stage token counts; a cycle's token totals can be derived by the
same sum over `tokens.*` if a future reader needs them, following the same
null-as-zero rule.

## Roll-up records

`counts.by_day` / `counts.by_model` / `counts.by_actor` /
`counts.spend_total_usd` / `counts.spend_today_usd` (`docs/DASHBOARD-SPEC.md`,
"Counts / roll-ups") are computed by the dashboard Publisher directly from the
raw transcripts across both pipelines' history, not from the per-stage record
above — a fleet-wide history spans more transcripts than any single node's
recent `log.jsonl` retains. Their fields:

| Field | Type | Unit | Meaning |
| --- | --- | --- | --- |
| `spend_total_usd` | number | US dollars | Sum of `cost_usd` across every transcript scanned (`COST_SCAN_DAYS` window). |
| `spend_today_usd` | number | US dollars | The same sum, restricted to today (UTC). |
| `by_day[].usd`, `.n` | number, integer | US dollars, count | Cost and transcript count for one UTC day. |
| `by_model[].usd`, `.n` | number, integer | US dollars, count | Cost and transcript count for one model id. |
| `by_actor[].usd`, `.n` | number, integer | US dollars, count | Cost and transcript count for one actor (`coordinator`, `implementor`, `reviewer`, `enabler`, or `project-reviewer` — see the dashboard spec's note on actor naming). |

## Stability policy

This is a contract other code depends on — the dashboard today, and (per
`docs/ROADMAP.md` Decision D4) whatever usage-based billing eventually reads
it. Two classes of change:

- **Additive, non-breaking:** a new field on the per-stage record or a
  roll-up row; a new roll-up dimension; a new event carrying the record (e.g.
  a future stage). A reader that ignores fields it doesn't recognise is
  unaffected.
- **Breaking, and must land in the same pull request as the code that makes
  it (`CLAUDE.md`, "As-built specifications"):** renaming or removing a
  field; changing a field's type or unit (e.g. milliseconds to seconds, or a
  string model id to a numeric one); changing what `tokens` sums (top-level
  `usage` instead of `modelUsage`, or vice versa); changing an aggregation
  rule (sum vs. max, or null-as-zero vs. null-propagates).

`cost_usd` and `tokens.*` both ultimately depend on fields Anthropic's own
Claude Code CLI writes to the envelope (`total_cost_usd`, `modelUsage`), which
this repo does not control. If that envelope's shape changes upstream in a
way that breaks the derivation above — a renamed field, a changed unit — that
is a bug in this document or in `lib/metering.sh`, to be fixed the same way
any other spec/code disagreement is.

## Where it's produced and consumed

- **Produced:** `lib/metering.sh` (`metering_fields`), called from
  `agent-cycle.sh`'s four stage-end sites (Co-Ordinator, Implementor,
  Reviewer, Enabler) and `review-cycle.sh`'s one (the weekly Reviewer), each
  passing its own model id and `.out` path (requirement 33a).
- **Consumed:** `scripts/publish-dashboard.sh` reads the same upstream
  envelope fields directly for its own per-stage and roll-up rendering
  (`docs/DASHBOARD-SPEC.md`) rather than reading the derived `log.jsonl`
  copy — the two are independent derivations of the same source and are
  expected to agree; a reader that finds them disagreeing has found a bug in
  one of them, not a second source of truth to reconcile.

## Verifying conformance

`test/metering.test.sh` is the validation helper: it feeds `metering_fields`
a well-formed single-model envelope, a multi-model envelope (the subagent
case), and the missing-file, empty-object and malformed-JSON degradations,
and asserts the exact shape documented above — including that a genuinely
zero or `false` value survives rather than collapsing to `null`. Because both
pipelines call the same function, "both pipelines emit conforming records"
reduces to one producer to check, rather than two.
