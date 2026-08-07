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

Both derive from the same upstream source: the JSON envelope in
`<stage>.out` (dashboard spec, "`cycles/<cycle-id>/<stage>.out`") — the
`result` event of the stage's own stream, which `run_claude_stage` truncates
into that file and which is byte-for-byte what `claude --output-format json`
wrote there before the pipelines began streaming (requirement 4d). This
document does not restate that
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
| `model` | string | — | The model id passed to the `claude` invocation (the same string `config.json` names, resolved per `lib/model-id.sh`). Always present, including on a stage that never ran: it is what the invocation was *asked* for, not something read back out of the envelope. |
| `cost_usd` | number \| null | US dollars | The envelope's own `total_cost_usd` — a **client-side estimate** Claude Code computes from token counts, not a charge or a draw against any plan limit (`docs/DASHBOARD-SPEC.md`'s design decision on plan limits makes the same point about the dashboard's own cost figures). Includes any subagents the stage's own invocation spawned. `null` if the envelope is missing or unparseable. |
| `duration_ms` | integer \| null | milliseconds | The envelope's `duration_ms`: wall-clock time for the invocation. |
| `num_turns` | integer \| null | count | The envelope's `num_turns`. |
| `is_error` | boolean \| null | — | The envelope's `is_error`. |
| `tokens` | object \| null | — | Token counts by kind, summed across every model the invocation's own tree used — see below. `null` if the envelope carries no readable `modelUsage` entry: an absent, empty or malformed map, or an empty/missing envelope. |
| `tokens.input` | integer | tokens | Sum of each model's `inputTokens`. |
| `tokens.output` | integer | tokens | Sum of each model's `outputTokens`. |
| `tokens.cache_creation` | integer | tokens | Sum of each model's `cacheCreationInputTokens` — tokens written to the prompt cache. |
| `tokens.cache_read` | integer | tokens | Sum of each model's `cacheReadInputTokens` — tokens served from the prompt cache. |
| `gaps` | object \| null | — | How long the invocation went between one piece of output and the next — see below. `null` means the record was not measured (a stage that never ran, or a record derived after the fact from an envelope alone), never that the run was continuously busy: every run that happened has at least one gap. |
| `gaps.n` | integer | count | Gaps observed. |
| `gaps.p50`, `.p95`, `.p99` | integer | seconds | Nearest-rank percentiles of the gap sample. |
| `gaps.max` | integer | seconds | The longest single silence in the run. |

A field's absence from the envelope is distinct from it being genuinely zero
or `false` — a stage entirely served from cache can have `cost_usd: 0`, and
`is_error: false` is the common case, not a null. `metering_fields` preserves
that distinction rather than treating a present-but-falsy value as missing.

Every envelope shape yields a record: one whose `modelUsage` entries cannot be
read contributes nothing to `tokens` rather than failing the derivation, and
an envelope that defeats it entirely still produces the all-null record above.
Consumers therefore never see a `stage-end` event that lost its `stage` or
`exit_code` (requirement 33) to a metering failure — which is what an empty
derivation would cost, since the record is merged into that event as it is
logged.

`tokens` sums the envelope's own `modelUsage` map (one entry per model
actually used, keyed by model id) rather than reading its top-level `usage`
object, because `usage` excludes subagent activity while `modelUsage` — like
`cost_usd` — includes it; the two fields would otherwise disagree about what
"this stage" spent. A stage that used one model end to end has one entry to
sum; a stage whose subagents ran a different model has several, and `tokens`
reports their total, not a per-model breakdown — `model` above already names
the invocation's own model, and a full per-model breakdown was not needed by
any reader this schema serves.

### `gaps`

`gaps` is the odd field here, and in a way worth stating plainly: every other
field is read out of the envelope the invocation wrote when it finished, and
this one cannot be, because it is a fact about *when* the run was doing
things and the envelope records only that it did them.

A **gap** is the interval between one growth of the stage's own event stream
(`<stage>.stream.jsonl`, requirement 4d) and the next. `lib/stage-run.sh`
measures them by `stat`-ing that file inside the poll loop that already runs
every two seconds while a stage is in flight, so:

- **the unit of observation is bytes arriving, not events parsed.** The
  contract is "the runner streams progress to a file; liveness is monotonic
  growth of that file" — deliberately not "the events carry timestamps",
  which is a fact about one CLI's output format rather than about running a
  stage at all.
- **the stage cooperates in nothing and can fake nothing.** No heartbeat is
  emitted, no cadence is agreed, and an actor that hangs cannot report
  otherwise.
- **the resolution is the poll interval**, two seconds. Percentiles are
  therefore multiples of it, and `n` is a count of *observed growths*, not of
  events: several events arriving inside one interval are one observation.
  That is the correct unit for the purpose — what is being measured is how
  long the file stood still, and it did not stand still between them.
- **the first gap is the wait for the run's first byte** — model start-up,
  reliably one of the longer silences — and **the last is the interval from
  the final growth to the end of the stage**. That last one is included
  deliberately, and unconditionally: a stage that fell silent and was killed
  has its longest silence at the end, unterminated by any event, and a sample
  that dropped it would be missing precisely the population these numbers
  exist to describe. It is why a stage that emitted nothing at all still
  reports one gap, spanning the whole run, rather than none.

Percentiles are nearest-rank over the sorted sample (`ceil(p·n)`-th smallest),
not interpolated, so every figure printed is a silence that really happened.
`null` therefore means one thing only — this record carries no measurement —
and never "the run was never quiet".

## Per-cycle aggregate

`cycles[].total_cost_usd` (`docs/DASHBOARD-SPEC.md`) is the sum of `cost_usd`
across the cycle's three rendered stages — Co-Ordinator, Implementor,
Reviewer — treating a stage that never ran (`cost_usd: null`) as `0`. It is
the cost of the cycle's own attempt at its item, which is what the card
reporting it is about: spend the cycle incurred outside those three stages is
not in it. Two things fall outside today — the Enabler, which runs from the
exit trap over items other cycles left blocked (requirement 35a) and is
rendered as its own verdict rather than as a fourth stage, and the usage-limit
probe of requirement 1b. Both are counted in the roll-ups below, which scan
transcripts rather than stages, so neither goes missing from a spend total;
they are simply not attributed to one cycle's attempt.

No other per-cycle field is currently aggregated from the per-stage token
counts; a cycle's token totals can be derived by the same sum over `tokens.*`
if a future reader needs them, following the same null-as-zero rule.

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
| `by_actor[].usd`, `.n` | number, integer | US dollars, count | Cost and transcript count for one actor. The actor is the transcript's own filename stem, so the set is open, not enumerated: `coordinator`, `implementor`, `reviewer`, `enabler` and `limit-probe` from a cycle directory, `project-reviewer` normalised from a review's `reviewer-<repo>.out`, and any other stem verbatim — see the dashboard spec's note on actor naming. |

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
  passing its own model id, `.out` path and the gap statistics
  `lib/stage-run.sh` left in `stage_gaps_json` for the run that just ended
  (requirement 33a). Those five are
  every invocation either pipeline logs a stage for. The one other invocation
  that spends is the usage-limit probe of requirement 1b — a single
  minimal-model call that is deliberately not a stage, logs no
  `stage-start`/`stage-end` pair, and so carries no per-stage record; its
  transcript reaches the roll-ups like any other `.out`.
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
zero or `false` value survives rather than collapsing to `null`, and that
`gaps` passes through when given, is `null` when omitted, and is `null`
rather than fatal when the caller hands it something unparseable. Because both
pipelines call the same function, "both pipelines emit conforming records"
reduces to one producer to check, rather than two.

`test/stage-gaps.test.sh` covers the measurement itself, which
`metering_fields` only carries: the percentile arithmetic against a known
sample, and — against a stub that emits with controlled pauses — that a real
run's gaps are measured from stream growth, that the silence after the last
event is counted, and that a stage which emitted nothing reports `null`.
