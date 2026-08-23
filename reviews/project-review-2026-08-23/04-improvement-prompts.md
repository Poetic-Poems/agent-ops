# Improvement prompts

One prompt per recommendation, in priority order (severity first, then effort). Each prompt is self-contained and can be pasted into a fresh AI agent session with no other context. Run prompts in the order given where a dependency is noted; otherwise they are independent and can run in any order or in parallel.

## Prompt for R-01 — Contain the prompt-injection / unrestricted-tool-access exposure

**Bundles:** R-01 only (too large and too security-sensitive to bundle with anything else) · **Run after:** no prerequisites

```text
Context: agent-ops (Poetic-Poems/agent-ops) is a self-hosted, unattended
pipeline that autonomously implements and reviews work across three public
GitHub repositories (Poetic-Poems/poetic, poetic-fiddle, and agent-ops
itself), raising pull requests via the `claude` CLI run non-interactively.
The pipeline's stage-launch point is lib/stage-run.sh; the six stage prompts
live in prompts/*.md; the credential/entrypoint setup is
deploy/docker/entrypoint.sh; the container's network config is
deploy/docker/compose.yaml and the Dockerfile.

The problem: lib/stage-run.sh launches every pipeline stage (Co-Ordinator,
Implementer, Reviewer, Enabler, Refiner, Approver) with
`claude -p --model "$model" --dangerously-skip-permissions
--output-format stream-json --verbose` — unrestricted bash/file/network tool
access, with no --allowedTools/--disallowedTools/permission-mode
restriction anywhere in the codebase. deploy/docker/entrypoint.sh places a
write-scoped GH_TOKEN (contents/pull-requests/issues write access) into the
container's process environment for its whole lifetime, readable by every
`claude` child process. prompts/coordinator.md embeds untrusted GitHub
content verbatim into the work order it hands downstream ("the issue body,
verbatim", "every comment, verbatim" — see prompts/coordinator.md around
lines 58 and 343), and no prompt in prompts/*.md frames this content as
untrusted data rather than instructions. All three repositories the
pipeline acts on are public (confirm with `gh repo view <repo> --json
isPrivate`), so any GitHub account can open an issue, PR, or comment whose
body becomes this verbatim input. There is no network egress allowlist
anywhere in the deployment.

The goal — reduce this to no technical path from adversarial GitHub content
to credential exfiltration or destructive action:
1. Every prompt in prompts/*.md that embeds externally-sourced GitHub
   content (issue bodies, PR bodies, comments, commit messages) is preceded
   by an explicit, consistent framing that the content below the marker is
   untrusted external data, never an instruction to follow, and the
   executing agent must not treat directives found inside it as commands.
2. Stages that primarily read and judge rather than need broad write access
   (start with Reviewer and Approver) run `claude` with tool access scoped
   down from --dangerously-skip-permissions to an explicit, narrower
   allow-list appropriate to what that stage actually needs to do — read
   the repo, run tests/linters, post a review — not unrestricted bash.
   Verify against each stage's actual current behaviour (grep agent-cycle.sh
   and prompts/reviewer.md / prompts/approver.md for what tools each stage
   invokes) before removing anything it needs.
3. The container's network egress is restricted to github.com (and its API
   subdomains) and the Anthropic API — nothing else — via whatever
   mechanism fits deploy/docker/compose.yaml (an egress proxy, firewall
   rules, or the hosting platform's own network policy; investigate what's
   feasible in this deployment before choosing).

Constraints: do not change the Implementer's tool access in this pass — it
genuinely needs broad write access and any restriction there needs separate,
careful scoping against its actual required capabilities; note this
explicitly as follow-up work rather than attempting it here. Do not break
any existing stage's ability to do its documented job — every change must
be verified against the existing test suite and, ideally, a real (or
carefully simulated) pipeline cycle. Do not remove --dangerously-skip-permissions
from every stage in one change if that risks breaking stages this task
didn't fully investigate — land the prompt-framing change and the network
egress restriction first (lower-risk, no stage-behaviour change), and treat
tool-access scoping as a separate, incremental follow-up per stage.

Verification: run the full test suite via scripts/run-tests.sh (inside the
project's own Docker image, per its own header comment — do not run it
directly against the host, jq version drift makes that misleading). Confirm
scripts/lint-shell.sh (shellcheck) stays clean. For the tool-access scoping
change specifically, exercise the affected stage's documented behaviours
(check prompts/reviewer.md and prompts/approver.md's own descriptions of
what each stage must be able to do) and confirm nothing that stage legitimately
needs was cut off.

Cost policy: this is genuinely security-critical, cross-cutting work — do
the analysis and the actual tool-access-scoping and egress-restriction
changes at a high-capability tier yourself; do not delegate the core design
decisions. You may delegate well-specified, narrow subtasks (e.g. drafting
the prompt-framing text for one prompts/*.md file once the pattern is
decided, or writing a test asserting the egress allowlist) to a lower-cost
tier, but review everything delegated before integrating it, given the
security stakes.

Deliverable: land the prompt-framing change and the network egress
restriction as one or two PRs (whichever the platform-specific egress work
naturally splits into), each following the repository's normal PR/tech-debt
conventions (see CLAUDE.md). File the tool-access-scoping work as a
tracked, scoped tech-debt item (per TECH-DEBT.md's "Filing an item"
workflow) rather than attempting it in the same pass, unless you have
budget to do it carefully and completely with full test verification.
```

## Prompt for R-02 — Decompose `agent-cycle.sh`'s undecomposed main flow and largest functions

**Bundles:** R-02 only (a large refactor; do not bundle with unrelated work) · **Run after:** no strict prerequisites, but coordinate with any in-flight `docs/ROADMAP.md` D8 repository-split work to avoid duplicated effort

```text
Context: agent-ops's implementation-pipeline entry point, agent-cycle.sh, is
9,920 lines: 95 named functions plus roughly 3,400 lines of undecomposed
top-level script (the actual cycle body — claim acquisition, all five stage
dispatches, cleanup — concentrated in two contiguous regions, roughly lines
6484-9360 and 9372-9920). The sibling entry point, review-cycle.sh (1,043
lines, same author, same conventions), fully decomposes into 19 named
functions with no comparable undecomposed block — it is the reference style
for this task. Five named functions inside agent-cycle.sh are also
unusually large: maybe_run_enabler (~645 lines, ~30 locals),
coordinator_corroborate_retry_or_fallback (~328 lines), run_approver_stage
(~319 lines), maybe_run_refiner (~292 lines), and _landing_stage_attempt
(~283 lines) — contrast lib/handoff.sh, which decomposes comparable domain
complexity (PR readiness, review requests, handoff completion) into 17
functions averaging ~65 lines each, several as private `_handoff_*` helpers.

The problem: the undecomposed main flow cannot be unit-tested the way
lib/*.sh functions are (nothing can `source` and call a slice of top-level
script), and it is the highest-stakes, most-frequently-touched code in the
repository — a change here is only caught by the full integration test
suite or by production. The five oversized named functions concentrate
branching complexity beyond what a reader can hold in working memory
locally, and their flat local-variable scopes raise the risk of an edit to
one verdict branch accidentally shadowing state meant for another.

The goal (acceptance criteria):
1. The main cycle flow (currently top-level script) is expressed as a
   sequence of named function calls, mirroring review-cycle.sh's style —
   at minimum, the label pre-fetch, lock acquisition, the stage-dispatch
   sequence, and cleanup each become their own named function, called once
   from a slim top-level driver.
2. Logic that duplicates or closely resembles existing lib/ patterns
   (gather_merge_conflicts, gather_tech_debt, coordinator_eligible_items,
   exclude_blocked_or_void_items, and similarly-shaped functions — grep
   agent-cycle.sh for `gather_`/`exclude_`/`coordinator_` prefixes for the
   full list) moves into lib/, alongside its closest existing sibling file
   (lib/coordinator-input.sh, lib/repo-order.sh are likely homes — read
   both first to judge fit).
3. Each of the five oversized functions is split along its existing guard-
   clause/verdict-branch structure into smaller named helpers (a claim
   helper, an adjudicate helper, one helper per verdict outcome, etc.),
   reducing each function's own body to an orchestration-only sequence of
   calls, matching lib/handoff.sh's demonstrated decomposition style.
4. No behaviour changes anywhere — this is a pure refactor. Every existing
   test in test/*.test.sh still passes unmodified (test file changes are
   only acceptable where a test was pinned to internal structure that
   necessarily moves, e.g. an awk-based "wiring" test that extracts a
   specific line range — update its extraction target, not its assertion).

Constraints: do this incrementally, not as one giant diff — land it as a
sequence of small, independently-reviewable PRs, each behaviour-preserving
and each verified green before the next starts. Do not change any stage's
external behaviour, CLI flags, config keys, or log event shapes. Preserve
every existing comment that explains *why*, not just *what* — several
functions here carry incident-history comments (e.g. references to specific
issue/PR numbers) that must move with the code they document. Watch for
"wiring" tests (test/*-wiring.test.sh) that extract exact line ranges or
function bodies via awk/grep from agent-cycle.sh — these will need their
extraction targets updated in lockstep with any function you move or
rename, or they will fail (correctly) with "has it moved?"-style errors.

Verification: run scripts/run-tests.sh (inside the project's Docker image —
see its own header for why not to run directly against the host) after
every incremental change, expecting 100% of the existing suite green. Run
scripts/lint-shell.sh (shellcheck) after every change. For the highest-risk
step (splitting the five oversized functions, especially maybe_run_enabler
given its ~30 local variables), read the full function first and map every
branch's inputs/outputs before splitting, to avoid silently dropping a code
path.

Cost policy: work cost-consciously. Where your environment supports
subagents, delegate well-specified, self-contained subtasks — e.g.
extracting one already-identified gather_* function into lib/, or updating
one wiring test's extraction target — to a mid-cost tier once the overall
decomposition plan is set. Reserve a high-capability tier for planning the
decomposition boundaries themselves (especially inside the five oversized
functions, where getting a split wrong risks a subtle behaviour change) and
for reviewing each delegated extraction before it's integrated. This is not
mechanical enough for a low-cost tier to do unsupervised, given how easy it
is to silently drop a guard clause or misplace a variable's scope.

Deliverable: a sequence of PRs (suggest at least 3-4 separate ones: main-flow
extraction; gather_*/exclude_*/coordinator_* promotion to lib/; the five
oversized functions, likely one PR each or grouped by natural theme), each
following this repo's normal PR conventions (Conventional Commits title,
CLAUDE.md's branch/clone rules), each with its own green test run recorded
in the PR description.
```

## Prompt for R-03 — Give `publish-dashboard.sh` a `--now` seam

**Bundles:** R-03 only · **Run after:** no prerequisites (already fully scoped as tech debt `TD-PPagop-26082316`)

```text
Context: agent-ops's dashboard publisher, scripts/publish-dashboard.sh,
computes several time-windowed figures (a rolling landing digest, staleness
checks, etc.) from the real wall clock, read once near the top of the
script into a `now_iso` variable derived from `date -u +%Y-%m-%dT%H:%M:%SZ`
with no override. Its sibling scripts, scripts/publish-revert-rate.sh and
scripts/autonomy-stage-report.sh, both already accept a `--now <iso8601>`
flag for exactly this purpose, and their tests assert against fixed
calendar timestamps rather than the real clock.

The problem: because publish-dashboard.sh cannot be pinned to a fixed time,
tests exercising its windowed logic (e.g. test/landing-audit-record.test.sh
Part B) can only assert against the real clock at test-write time. This
already caused a real incident: PR #685's checks were green when written,
but more than 24 hours later the merge queue re-ran the same suite against
a later real clock, a fixture fell outside its intended rolling 24-hour
window, three assertions failed, and the PR was dequeued from the merge
queue after a human had already approved and enqueued it. This is tracked
as open tech debt tech-debt/TD-PPagop-26082316.md — read that file first
for any additional detail it records.

The goal: scripts/publish-dashboard.sh accepts a `--now <iso8601>` flag,
following the exact pattern already used in scripts/publish-revert-rate.sh
(read that script's argument parsing and its use of the override value as
your reference implementation — match its flag name, help text style, and
how it threads the override value through to every windowed calculation).
Every test that currently exercises publish-dashboard.sh's time-windowed
logic against the real clock is updated to pass a fixed `--now` value
instead, matching the pattern scripts/publish-revert-rate.sh's own tests
already use.

Constraints: when `--now` is not passed, behaviour must be identical to
today (falls back to the real clock) — this is a strictly additive change,
not a behaviour change for production use (production never passes
`--now`; it exists for tests). Do not change the format or semantics of any
existing windowed calculation, only how "now" is obtained.

Verification: run the specific tests that exercise time-windowed dashboard
logic (grep test/*.test.sh for references to publish-dashboard.sh and to
window/staleness/digest-related assertions) and confirm they now pass
deterministically regardless of when they're run — verify this concretely
by running the suite once, then again after altering your local clock
forward by 25+ hours if your environment allows it, or by inspecting that
the test no longer reads `date`/`$(date ...)` anywhere in its own
assertions. Run the full suite via scripts/run-tests.sh to confirm nothing
else regressed.

Cost policy: this is small, well-specified, pattern-matching work against
an existing sibling implementation — suited to a low-cost tier end to end,
including the test updates. No need to reserve a higher tier for any part
of this task.

Deliverable: a single PR implementing the `--now` flag and updating the
affected tests, referencing tech-debt/TD-PPagop-26082316.md and flipping
its frontmatter to `status: resolved` with today's date and this PR's
number in `ref:`, per TECH-DEBT.md's resolution convention (frontmatter-only
edit, body left in place).
```

## Prompt for R-04 — Fix the dashboard's misleadingly-named `esc()` helper

**Bundles:** R-04 only · **Run after:** no prerequisites

```text
Context: agent-ops's local dashboard is a single file, dashboard/index.html
(inline HTML/CSS/JS, no build step, no framework). It renders fleet state
(cycles, PRs, tech-debt items, etc.) client-side from a published JSON
payload.

The problem: dashboard/index.html defines `function esc(s) { return
String(s == null ? "" : s); }` (around line 307) — despite its name, this
performs no HTML-entity escaping at all. Most of its ~14 call sites are
safe only incidentally, because they flow through the `el()` helper's
`children` parameter into `document.createTextNode` (which does not
interpret HTML). Two call sites are not safe by construction: `kv()`
(around line 1782) builds `el("span", {class:"kv", html: k + " <b>" +
esc(v) + "</b>"})`, and a count-summary string (around line 2063) — both
route through the `html:` attribute, which `el()` assigns directly to
`.innerHTML` (see el()'s implementation, around lines 275-288). Today
neither call site is known to carry attacker-controlled content, but the
function's name actively invites a future developer to trust it with
content that could be (an issue/PR title, a model-generated reason string),
introducing stored XSS on a page exposed to everyone on the operator's
Tailscale network.

The goal: eliminate the risk that a future call to `kv()` or the
count-summary path introduces XSS, without breaking the dashboard's current
rendering. Preferred approach: rewrite `kv()` to build its `<b>` element via
`el()` (DOM construction) instead of string-concatenating into `innerHTML`
— this removes the unsafe `html:` call site entirely rather than relying on
correct escaping. Apply the same treatment to the count-summary site if it
similarly can be expressed as DOM construction. If any remaining site
genuinely needs to inject markup (not just text) via `html:`, then rename
`esc()` to something that doesn't imply escaping (e.g. `str()`) and, only
for that one call site, write a real HTML-escaping function and use it.

Constraints: dashboard/index.html has no build step — do not introduce one;
keep the fix as plain inline JS matching the file's existing style. Do not
change the dashboard's visible output for any currently-rendered value
(verify byte-for-byte or visually identical rendering for existing data).
Do not touch unrelated parts of this large file.

Verification: this repo has a Node-based rendering harness for exactly this
file, test/dashboard-render-harness.js, exercised by
test/dashboard-render.test.sh — run that test and confirm it still passes.
Manually trace every one of esc()'s call sites (grep dashboard/index.html
for `esc(`) after your change and confirm each is either now safe by
construction (DOM-built, not string-concatenated into innerHTML) or passes
through a genuine escaper.

Cost policy: this is small, self-contained, single-file work suited to a
low-cost tier — no need for a higher-capability tier on any part of it,
though you should still verify your own output against the rendering test
before declaring it done.

Deliverable: a single PR with the dashboard/index.html change and a note in
the PR description tracing every esc() call site and its safety
justification post-change.
```

## Prompt for R-05 — Redact secrets from the state-repo sync path

**Bundles:** R-05 only · **Run after:** no prerequisites

```text
Context: agent-ops periodically syncs its operational state (logs,
transcripts, review folders) to a second, private GitHub repository via
scripts/state-sync.sh, for durability/history independent of any single
node. Separately, scripts/publish-dashboard.sh — which publishes an
aggregated JSON payload consumed by the (semi-public, Tailscale-exposed)
dashboard — already runs a `redact()` function (around lines 2525-2533)
that strips GitHub/Anthropic token-shaped strings and home-directory paths
from its output before publishing, as defence-in-depth even though nothing
upstream is expected to carry a live secret.

The problem: scripts/state-sync.sh's push path (its `do_push()` function,
roughly lines 274-391) commits log.jsonl, review-log.jsonl, the cycles/ and
reviews/ directories, and cron logs — full, raw per-stage transcripts — to
the state repository with no equivalent redaction step (confirm this by
grepping scripts/state-sync.sh for any reference to redact-style logic —
there is none). log.jsonl is deliberately never rotated
(scripts/rotate-logs.sh's own header explains why), so this is a long-lived,
growing surface. Unlike the dashboard path, nothing here would catch a
token or secret that leaked into a stage's stdout/stderr (a verbose git/curl
error, an accidental `set -x`, a future bug) before it's committed,
unredacted, to a second repository, retained indefinitely.

The goal: apply the same class of redaction scripts/publish-dashboard.sh
already performs to whatever scripts/state-sync.sh pushes — at minimum
log.jsonl and any other files that could plausibly carry raw command output
(stage .out/.err files if state-sync.sh pushes those too — check what
do_push() actually stages). Reuse the existing redact() implementation and
its pattern set (read scripts/publish-dashboard.sh's redact() first) rather
than writing a second, possibly-inconsistent implementation — extract it to
a small shared location both scripts can source if that's cleaner than
duplicating it, using your judgement on which is less invasive given how
each script currently sources its dependencies.

Constraints: do not change what data state-sync.sh pushes (which files,
what they contain otherwise) — only add a redaction pass over content that
already gets pushed. Do not weaken scripts/publish-dashboard.sh's existing
redaction while reusing it. Preserve state-sync.sh's existing push
behaviour, error handling, and retry logic exactly; this should be an
additive filtering step, not a rewrite.

Verification: locate or write a unit test analogous to
scripts/publish-dashboard.sh's own redaction test (grep test/*.test.sh for
"redact" to find the existing pattern) that plants a token-shaped string
and a home-directory path into a fixture and asserts state-sync.sh's pushed
content no longer contains it. Run the full suite via scripts/run-tests.sh
to confirm no regression to state-sync.sh's existing behaviour.

Cost policy: this is ordinary implementation work against a clear pattern
already proven elsewhere in the codebase — suited to a mid-cost tier. If
you delegate the test-writing to a lower-cost tier once the redaction call
site is decided, review its fixture content carefully (a redaction test is
only as good as its planted secret actually looking like the real thing).

Deliverable: a PR adding the redaction pass to scripts/state-sync.sh's push
path, plus the corroborating test, referencing this recommendation (R-05)
or filing it as a tech-debt item first if you'd rather track it before
starting (see TECH-DEBT.md's "Filing alongside other work" workflow).
```

## Prompt for R-06 — Share `san()` and other duplicated utilities from `lib/` instead of copy-pasting

**Bundles:** F-CODE-02 (san()) and F-ARCH-03 (expand_home/cfg/log_event) — bundled because both are the same class of fix (promote a duplicated function to a shared location) touching a small, easily-reviewed set of files; the san() half has real correctness stakes and should be prioritised within this task if time is constrained · **Run after:** no prerequisites

```text
Context: agent-ops is a ~26,600-line Bash/Perl codebase (lib/, scripts/,
agent-cycle.sh, review-cycle.sh) that generally promotes shared logic into
lib/*.sh and, where it deliberately keeps more than one implementation,
pins them to agree via a shared test (see test/extract-json-result.test.sh's
own header comment for the precedent this task should follow).

The problem, part 1 (higher priority — real correctness risk): `san()`, a
path-sanitizing helper (`san() { local s="$1"; printf '%s'
"${s//\//__}"; }`), is defined identically in both lib/claim.sh (around
line 118) and scripts/sweep-orphan-branches.sh (around line 122).
scripts/sweep-orphan-branches.sh already sources lib/github-limit.sh and
lib/config-schema.sh but not lib/claim.sh, and reimplements san() instead
of importing it. Both uses build the same claim-registry path shape:
lib/claim.sh writes claim records under
`claims/$(san "$slug")/$(san "$key").json` in the state repo;
sweep_branch() in scripts/sweep-orphan-branches.sh (around line 176) reads
the same path shape and treats only a clean 404 as "no live claim" before
deleting a branch. If lib/claim.sh's san() ever changes (e.g. to encode
more path-unsafe characters) without a matching change landing in
scripts/sweep-orphan-branches.sh, the sweep's claim-registry lookups start
silently missing real claims, and it can delete a branch a peer node still
owns — a correctness bug in the exact safety check san() exists to
provide.

The problem, part 2 (lower priority — cosmetic risk): expand_home(),
cfg()/cfg_json(), and log_event() are each duplicated between agent-cycle.sh
and review-cycle.sh with only trivial differences (a closed-over config
variable name, a log field name/target file). Neither has a shared lib/
implementation or a pinning test, unlike comparable cases the codebase
already handles correctly (lib/stage-run.sh's header explicitly frames "the
two copies this replaces were byte-identical" as the problem it fixed).

The goal:
1. scripts/sweep-orphan-branches.sh sources lib/claim.sh and uses its
   san(), deleting its own local copy. Verify the two files' sourcing order
   and any variable/function name collisions before wiring this in.
2. For expand_home()/cfg()/cfg_json()/log_event(): either promote the
   shared shape into a lib/*.sh file both agent-cycle.sh and review-cycle.sh
   source (parameterising the small difference — e.g. log_event()'s field
   name — as a function argument), or, if you judge the churn not worth it
   at this size, add a one-line comment in both copies stating the
   duplication is deliberate and where its sibling copy lives, so a future
   reader doesn't have to re-derive that it's safe to leave alone. Use your
   judgement on which is more appropriate per function — they need not all
   get the same treatment.

Constraints: no behaviour change anywhere. For the san() fix specifically,
this touches a live safety check for branch deletion — verify extremely
carefully that the imported san() produces byte-identical output to the one
being removed, for every input scripts/sweep-orphan-branches.sh actually
passes it, before deleting the local copy.

Verification: run the full suite via scripts/run-tests.sh. Specifically
locate and run whatever test(s) cover scripts/sweep-orphan-branches.sh's
claim-registry interaction (grep test/ for sweep-orphan-branches or
sweep_branch) and lib/claim.sh's own tests, confirming both still pass
after the san() consolidation. Run scripts/lint-shell.sh (shellcheck) after
any lib/ sourcing changes.

Cost policy: the san() fix is small and mechanical but touches a real
safety check — do it yourself or have it reviewed carefully at a mid-cost
tier or above rather than delegating unsupervised to a low-cost tier, given
the branch-deletion stakes if the consolidation is subtly wrong. The
expand_home/cfg/log_event work is genuinely mechanical and suits a low-cost
tier.

Deliverable: one or two PRs (san() fix can stand alone; the smaller utility
consolidation can be its own PR or the same one, your judgement) with test
runs confirming no regression.
```

## Prompt for R-07 — Pin the Docker image's OS packages and `claude` CLI version

**Bundles:** R-07 only (both are the same "pin what's currently floating in the Dockerfile" fix, touching one file) · **Run after:** no prerequisites

```text
Context: agent-ops deploys as a single Docker image (deploy/docker/Dockerfile,
Ubuntu 24.04 base) that runs every pipeline role. The Dockerfile already
pins and checksum-verifies two tools not available from a signed apt
repository — supercronic and shellcheck (find these in the Dockerfile and
use their pinning pattern, including the checksum-verification style, as
your reference for consistency).

The problem: the same Dockerfile installs OS packages (jq, curl, python3,
perl, git, and others — search for `apt-get install -y` to find the full
list) with no version pins, and installs the `claude-code` npm package via
`ARG CLAUDE_CODE_VERSION=latest` / `npm install -g
"@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"` — deliberately
unpinned per the adjacent comment, unlike supercronic/shellcheck a few
lines away. Because the image is the deployment artefact (nodes pull the
built image, never a git branch), rebuilds of the same commit days apart
can silently produce different behaviour if either an OS package receives
an update or claude-code publishes a new release in between — and
claude-code specifically is the dependency with the deepest reach (it's the
runtime for every stage's tool/token access).

The goal: pin claude-code to a specific major.minor version (not `latest`),
bumped deliberately in its own PR when an upgrade is wanted, matching how
supercronic/shellcheck are already handled. For the OS package layer,
either pin the base image to a specific digest (`ubuntu:24.04@sha256:...`)
for build reproducibility, or — if you judge that not worth the
maintenance cost for this project's current stage — leave OS packages
floating but add a comment to the Dockerfile explicitly stating that's a
deliberate, reasoned trade-off (matching this codebase's convention of
never leaving a deviation from its own stated discipline unexplained).

Constraints: do not break the image build. If you pin claude-code to a
specific version, verify that version is actually compatible with how this
codebase invokes it (check lib/stage-run.sh's claude invocation flags
against that version's supported flags/behaviour) before committing to a
pin. Do not change any other part of the Dockerfile.

Verification: build the image locally (`docker build -f
deploy/docker/Dockerfile -t agent-ops .` per the Dockerfile's own header
comment) and confirm it succeeds. Run scripts/doctor.sh inside a container
built from the new image to confirm claude-code and the pinned OS packages
are present and functional. Run the test suite via scripts/run-tests.sh
against the newly-built image.

Cost policy: this is small, well-specified, mechanical work (pin a version,
verify the build) suited to a low-cost tier for the pinning itself; if you
delegate the build/verification step, review its output rather than trust
a "build succeeded" claim blindly, since a broken pin can fail in ways that
only surface at runtime, not at build time.

Deliverable: a single PR pinning claude-code's version (and optionally the
base image digest), with the local build/test verification results noted
in the PR description.
```

## Prompt for R-08 — Harden the CI test-running discipline

**Bundles:** three independent pieces (CI timeout; splitting slow tests; landing an already-scoped fixture fix) bundled into one prompt because they're all "make CI's test running more robust" and can be split into separate PRs by whoever executes this, but share enough context to specify together · **Run after:** no strict prerequisites

```text
Context: agent-ops's test suite (test/*.test.sh, 140 files, ~52,000 lines)
runs locally via scripts/run-tests.sh (which wraps each test in `timeout
600 bash "$t"`) and in CI via .github/workflows/build-image.yml's "Run the
test suite inside the image" step, which is supposed to mirror the local
runner exactly (both run inside the project's own built Docker image, per
scripts/run-tests.sh's own header comment on why that matters — jq version
drift between the host and the image is otherwise a source of misleading
failures).

Three independent problems to fix:

1. CI has no timeout. scripts/run-tests.sh applies `timeout 600` per test
   locally, but .github/workflows/build-image.yml's equivalent step runs
   the identical per-test loop with no timeout at all, and the job itself
   sets no `timeout-minutes` — so in CI, a hang is bounded only by GitHub
   Actions' default 6-hour job timeout. The suite includes tests exercising
   real signal/process-group handling with background `sleep` stand-ins
   (test/stage-watchdog.test.sh, test/finish-then-continue.test.sh,
   test/stage-gaps.test.sh) — exactly the kind of test a watchdog-kill
   regression would turn into a genuine multi-hour CI hang rather than a
   fast, clear failure.

2. Nine test files are severe runtime outliers relative to the rest of the
   suite: test/doctor.test.sh (~6m23s), test/toggle.test.sh (~5m41s),
   test/review-not-before.test.sh (~4m49s), test/publish-dashboard.test.sh
   (~4m25s), test/review-claim.test.sh (~3m19s), test/config-schema.test.sh
   (~3m02s), test/role.test.sh (~2m54s), test/state-sync.test.sh (~1m57s),
   and test/coordinator-input-wiring.test.sh (~1m22s) — together ~34
   minutes, against README.md's "Running the tests" section describing "a
   few minutes" for the *entire* 140-file suite (a full run actually takes
   roughly 45-50 minutes on comparable hardware). Several work by
   repeatedly invoking the real, large entry-point scripts (agent-cycle.sh,
   review-cycle.sh, or doctor.sh) as subprocesses to prove an end-to-end
   property (e.g. "the startup schema gate refuses a bad config"), rather
   than calling library functions directly.

3. tech-debt/TD-PPagop-26082302.md (open) documents that
   TD-PPagop-26082201's fix — clearing ambient PULLWRIGHT_APPROVER_APP_ID /
   _INSTALLATION_ID / _PRIVATE_KEY_PATH in test/config-schema.test.sh's
   `_assert_doctor_check` fixture helper before every doctor.sh fixture —
   correctly stopped one fixture's environment leaking into another, but as
   a side effect removed the suite's only coverage of doctor.sh's
   reconciliation between a set PULLWRIGHT_APPROVER_APP_ID and a set
   approver_app_id config key (see lib/approver-token.sh for that
   reconciliation logic). Read TD-PPagop-26082302.md for its own proposed
   fixture design before starting this piece.

The goal (three independent acceptance criteria — treat as separable
tasks):
1. CI's test-suite step in .github/workflows/build-image.yml has an
   explicit bound — either a `timeout-minutes:` on the job, or the same
   `timeout 600` wrapping scripts/run-tests.sh already applies per test,
   ported into the CI step's invocation.
2. README.md's "Running the tests" section is corrected to state the
   suite's actual approximate runtime rather than "a few minutes." The nine
   identified slow files have their real-subprocess-invoking assertions
   (the minority that genuinely need to exercise
   agent-cycle.sh/review-cycle.sh/doctor.sh end-to-end as a subprocess)
   separated from assertions that only need the underlying library
   functions, or their repeated subprocess spawns consolidated into fewer
   invocations — so that filtering to one of these files via `scripts/run-
   tests.sh <filter>` for a fast local check no longer costs minutes. Judge
   file-by-file how much can genuinely move to direct function calls versus
   how much needs the real subprocess to prove the property under test —
   do not weaken what's actually being verified for the sake of speed.
3. tech-debt/TD-PPagop-26082302.md's proposed fixture (pairing a
   *mismatched* PULLWRIGHT_APPROVER_APP_ID and approver_app_id, and
   asserting doctor.sh's reconciliation logic catches the mismatch) is
   implemented in test/config-schema.test.sh, restoring the coverage that
   was inadvertently dropped.

Constraints: task 1 must not make CI flakier — 600 seconds (matching the
local runner) is a reasonable per-test bound unless you find evidence a
specific test legitimately needs longer, in which case say so rather than
silently applying a blanket timeout that breaks it. Task 2 must not reduce
what's actually verified — if a subprocess invocation is the only way to
prove a given property (e.g. "the real entry point script, unmodified,
refuses a bad config"), keep it; only convert assertions that were using
the subprocess as an expensive way to test something a library function
call could test just as validly. Task 3 must follow tech-debt/TD-PPagop-
26082302.md's own proposed approach rather than inventing a different one,
unless you find its approach doesn't work, in which case explain why.

Verification: for task 1, confirm the workflow YAML is syntactically valid
and the timeout value is reasonable by checking a full CI run completes
well within it under normal conditions. For task 2, time the affected files
before and after your change and confirm a meaningful reduction, while
running the full suite via scripts/run-tests.sh to confirm no test that
previously passed now fails or is skipped. For task 3, confirm the new
fixture actually fails against the pre-TD-PPagop-26082201 doctor.sh
behaviour (i.e. it genuinely tests the reconciliation) and passes against
current doctor.sh.

Cost policy: task 1 is small and mechanical (low-cost tier). Task 2 needs
judgement about what each assertion is actually proving — do this at a
mid-cost tier, and don't delegate the "which assertions can move" analysis
to a low-cost tier, since getting it wrong silently weakens test coverage.
Task 3 is well-specified by the existing tech-debt item and suits a
low-to-mid-cost tier. Verify all delegated work before integrating it.

Deliverable: up to three separate PRs (one per task, since they're fully
independent), each following this repo's normal conventions. Task 3's PR
should flip tech-debt/TD-PPagop-26082302.md's frontmatter to `status:
resolved` per TECH-DEBT.md's resolution convention.
```

## Prompt for R-09 — Surface the three swallowed-error/observability gaps already filed as tech debt

**Bundles:** three independent, already-scoped fixes bundled into one prompt for context-sharing efficiency (all are "an error is silently swallowed somewhere the fleet needs to see it") — land as three separate PRs, one per tech-debt item, since there's no shared code path between them · **Run after:** no prerequisites

```text
Context: agent-ops is an autonomous pipeline that runs unattended; when it
silently swallows an error, nobody finds out until a human happens to
notice symptoms and digs through raw logs by hand — this has already
happened three times, each now tracked as its own open tech-debt item with
a specific, already-designed fix. Read each tech-debt file in full before
starting its fix — they contain more detail than this prompt restates.

Fix 1 — tech-debt/TD-PPagop-26082322.md: lib/issue-priority.sh's
issue_priority_apply() sends its GraphQL setIssueFieldValue mutation with
its error output discarded, collapsing every possible failure to a bare
{"applied": false, "reason": "mutation-failed"} — no detail about *why* it
failed. This already caused a real 3-day-invisible incident: a one-token
GraphQL schema mismatch made every Priority write fail identically, and one
node logged 14 identical, unhelpful warnings before anyone read the actual
error. Fix: capture the mutation's actual error output and carry at least
its first line into the returned result (e.g. {"reason": "mutation-failed",
"error": "..."}) so the caller's warning can name the specific problem.

Fix 2 — tech-debt/TD-PPagop-26082306.md: lib/github-limit.sh's
github_auth_probe() only classifies a credential fault when it sees an
explicit HTTP 401 / "Bad credentials" match. When GH_TOKEN is unset or
empty, `gh api rate_limit` fails locally with a message ("no authentication
token" / "gh auth login") that matches neither pattern, so the probe
reports `unreachable` instead of `unauthorized` — and requirement 2.0b's
handling of `unreachable` lets a full Co-Ordinator engagement run every
cycle, every claim inside it then failing, indefinitely. Fix: extend the
probe's stderr classification to recognise the "no authentication token" /
"gh auth login" message shape (or check GH_TOKEN/GITHUB_TOKEN for
emptiness before making the call at all) and report `unauthorized` with an
accurate detail string in that case.

Fix 3 — tech-debt/TD-PPagop-26082307.md: agent-cycle.sh's
refinement_traceability_fault (requirement 17f) has two independent silent
failure modes. (a) It tests verbatim containment of refinement text;
ordinary paste drift or a lightly-edited comment defeats this test with no
warning, counter, or dashboard signal — just a silent skip. (b) Its comment
re-fetch swallows its own failure (pattern: `gh api ... 2>/dev/null ||
true`), so a degraded token, rate limit, or malformed comment_url disarms
the entire check while it still reads as passing. Fix (two parts, as the
tech-debt item scopes them): tolerate non-substantive paste drift in the
comparison (e.g. collapse whitespace, or match a distinctive contiguous
slice rather than requiring the whole text to match verbatim) rather than
requiring exact containment; and route the comment-fetch's degraded-read
path through the same warning mechanism this file's other degraded reads
already use (look at how default_branch/commit_ts reads handle their own
degradation for the existing pattern to follow) instead of silently
swallowing the failure.

The goal: implement all three fixes as scoped above and in their respective
tech-debt files. Each is independent — no shared code path, no ordering
dependency between them.

Constraints: do not change any of these functions' behaviour beyond what's
described — this is about making existing failures observable, not
changing what counts as success or failure (except Fix 3a, where the
containment test's tolerance is deliberately being loosened as scoped — do
not widen it further than "tolerate non-substantive drift", it must still
catch genuinely unrelated text).

Verification: for each fix, write or extend a test that reproduces the
original silent-failure scenario and confirms the fix surfaces it
(Fix 1: a mutation that fails should produce a result whose reason names
the actual error; Fix 2: an empty GH_TOKEN should classify as unauthorized,
not unreachable; Fix 3: a comment with minor whitespace/formatting drift
from the original refinement text should still be recognised as tracing
back to it, and a forced comment-fetch failure should produce a visible
warning rather than a silent pass-through). Run the full suite via
scripts/run-tests.sh to confirm no regression.

Cost policy: each of these three fixes is small, well-specified, and
already fully designed in its tech-debt record — suited to a mid-cost tier
end to end, including the test-writing. No need for a high-capability tier
on any of them, but verify each one's test actually reproduces the
original failure mode before trusting the fix.

Deliverable: three separate PRs, one per fix, each flipping its tech-debt
item's frontmatter to `status: resolved` (today's date, this PR's number in
`ref:`) per TECH-DEBT.md's resolution convention — body left in place,
file never deleted or renamed.
```

## Prompt for R-10 — Bound `publish-revert-rate.sh`'s cumulative re-mining

**Bundles:** R-10 only (already fully scoped as tech debt `TD-PPagop-26082204`) · **Run after:** no prerequisites

```text
Context: agent-ops's scripts/publish-revert-rate.sh computes three
revert-rate figures per repository: `rolling` (a 14-day window), `recent`
(48 hours), and `cumulative` (since a fixed baseline date recorded in
revert_rate_baseline.generated, currently 2026-08-15). It works by calling
scripts/mine-merge-history.sh's mine_window()/mine_repo() functions, which
cost roughly 3 GitHub API calls per merged PR mined.

The problem (tracked as open tech debt tech-debt/TD-PPagop-26082204.md —
read it first for full detail): unlike `rolling` and `recent`, which bind
their window to a constant-size offset from "now" (so their mining cost
stays roughly constant over time), `cumulative` binds its `--since` to the
fixed baseline date — so every day that passes, the population of PRs it
re-mines from scratch grows, and its GitHub API cost grows with it,
unboundedly, forever. This is exactly the kind of silent, ever-growing cost
against a shared rate-limit budget this codebase has a strong track record
of catching and fixing elsewhere (see the tech-debt register's
TD-PPagop-26072201 through TD-PPagop-26081506 lineage for the established
pattern this fix should follow in spirit).

The goal: implement one of the two remedies tech-debt/TD-PPagop-26082204.md
itself names (read the file for its exact proposed approaches) — most
likely either (a) memoising each PR's settled outcome (merged, reverted,
or not) keyed by repo+PR-number so a previously-mined PR is never re-mined,
or (b) rolling the cumulative figure forward incrementally from
publish-revert-rate.sh's own prior output (revert-rate.jsonl) rather than
recomputing from scratch each run. Follow whichever approach the tech-debt
item itself recommends unless you find a concrete reason it doesn't work,
in which case explain why and justify your alternative.

Constraints: the `cumulative` figure's actual reported value must not
change (this is a performance fix, not a metric-definition change) — a PR
that would have been counted under the current from-scratch approach must
still be counted under the new incremental approach. Do not change
`rolling` or `recent`'s behaviour at all.

Verification: run scripts/publish-revert-rate.sh against a repository with
a non-trivial merge history and confirm the `cumulative` figure matches
what the current (pre-fix) implementation produces for the same input.
Confirm the GitHub API call count for a `cumulative` run no longer grows
with days-since-baseline (e.g. by counting API calls made, or by
inspecting that the mining function is now bounded by "new PRs since last
run" rather than "all PRs since baseline"). Run the relevant test file(s)
(grep test/ for publish-revert-rate or mine-merge-history) and the full
suite via scripts/run-tests.sh.

Cost policy: this is well-specified implementation work against a clear,
already-designed remedy — suited to a mid-cost tier.

Deliverable: a PR implementing the fix, flipping
tech-debt/TD-PPagop-26082204.md's frontmatter to `status: resolved` per
TECH-DEBT.md's convention.
```

## Prompt for R-11 — Make the dashboard's clickable rows/cards keyboard-accessible

**Bundles:** R-11 only · **Run after:** no prerequisites

```text
Context: agent-ops's local dashboard, dashboard/index.html, is a single
inline HTML/CSS/JS file (no build step). It already has one fully
keyboard-accessible interactive widget — the PR-reference card (lines
roughly 391-694) — built on native `<a>` anchors with `role="note"` +
`aria-describedby`, documented in docs/DASHBOARD-SPEC.md (around lines
1306-1318) as supporting keyboard focus and Enter-activation.

The problem: three other interactive surfaces in the same file are
click-only. Cycle rows that expand per-stage detail (built via `el("tr",
{class:"clickable"}, cells)` around line 1749, with its click handler
around line 1751), void-item rows that expand truncated text (around line
1919, handler around line 1925), and fleet-node cards that filter the
cycle list/log to one node (handler around line 1423) are all plain `<tr>`
or `<div>` elements styled only with `cursor:pointer` (see the `.card
.clickable` and `tbody tr.clickable` CSS rules around lines 73 and 97) —
none has `tabindex`, `role="button"`, or a `keydown` handler (confirm with
a search for `tabindex`/`role.*button`/`keydown` across the file — the only
match is an unrelated global Escape handler around line 682).
docs/DASHBOARD-SPEC.md describes these three widgets only in terms of
clicking, not keyboard interaction.

The goal: all three `.clickable` interaction points become keyboard-
reachable and keyboard-activatable, matching the PR-reference card's
existing pattern: each gets `tabindex="0"` and `role="button"`, plus a
`keydown` handler that triggers the same action as the existing click
handler on Enter or Space (and should call `event.preventDefault()` for
Space to avoid scrolling the page). Update docs/DASHBOARD-SPEC.md's
description of each of these three widgets to document the added keyboard
support, matching how it already documents the PR-reference card's.

Constraints: do not change what each interaction does when triggered, only
how it can be triggered. Do not change the visual appearance of these
elements (a focus outline appearing on keyboard focus is expected and fine;
don't suppress it). Follow the existing code's style (the `el()` helper's
attribute-object pattern) rather than introducing a different way of
building these elements.

Verification: dashboard/index.html has a Node-based rendering harness,
test/dashboard-render-harness.js, exercised via
test/dashboard-render.test.sh — run it and confirm it still passes after
your change (extend it with an assertion that the three interaction points
now carry `tabindex`/`role`/a keydown listener, if the harness's design
makes that practical — use your judgement on whether that fits its
existing test style). Since no browser is required to verify markup
attributes are present, you do not need live browser testing for this
change, but if one is available in your environment, manually tab to each
of the three interaction points and confirm Enter/Space triggers the same
behaviour as a click.

Cost policy: this is small, well-specified, single-file, pattern-matching
work (copy an existing pattern to three more places) — suited to a
low-cost tier end to end.

Deliverable: a single PR with the dashboard/index.html and
docs/DASHBOARD-SPEC.md changes together (per this repo's CLAUDE.md rule
that a behaviour change and its spec update land in the same PR).
```

## Prompt for R-12 — Add a table of contents to README.md and the implementation spec

**Bundles:** R-12 only · **Run after:** no prerequisites

```text
Context: agent-ops's root README.md is 2,381 lines with 89 headings, and
docs/IMPLEMENTATION-PIPELINE-SPEC.md is 17,320 lines — both already rely
heavily on internal markdown anchor links (e.g. README.md links to
`#the-landing-gate`, `#blocked-items-and-the-enabler`, and similar targets
throughout its own body) but neither document has a table of contents at
its top. This repository already has a precedent for a generated,
CI-checked documentation region: scripts/render-config-table.sh renders
README.md's and each spec's configuration tables from config.schema.json,
checked in CI via .github/workflows/config-table.yml and its own
`--check` flag — follow this same pattern (a generating script, checked in
CI) rather than a one-off hand-written ToC that will drift.

The problem: a reader of either document has no way to see its shape
without scrolling through it or grepping — despite the documents' own
extensive internal cross-linking being evidence the authors already know
precisely which sections matter enough to jump to.

The goal: both README.md and docs/IMPLEMENTATION-PIPELINE-SPEC.md open with
a table of contents (a nested list of links to each `##`/`###` heading,
using GitHub's standard heading-anchor-slug convention) that is generated
from the document's actual headings rather than hand-maintained, and
checked for staleness in CI the same way the config tables already are.

Constraints: follow this repo's existing generated-region convention
exactly — CLAUDE.md documents this pattern (see its "Generated regions"
section): a clearly marked start/end comment pair
(e.g. `<!-- toc:start -->` / `<!-- toc:end -->`) that a script regenerates,
with a `--check` mode that fails if the committed content doesn't match
what regeneration would produce, wired into the same CI job (or a sibling
job) that already runs config-table.yml's check. Do not hand-edit inside
the generated region once the tooling exists — the whole point, per
CLAUDE.md's existing convention for the config tables, is that only the
generator's output survives a regeneration. Do not touch
docs/REVIEW-PIPELINE-SPEC.md or docs/DASHBOARD-SPEC.md in this task unless
you judge it trivial to extend the same script to them once written (your
call — not required for this recommendation's acceptance criteria, but a
natural extension if cheap).

Verification: run your new script's `--check` mode against the repository
immediately after generating and committing the ToCs, and confirm it
passes. Confirm CI's existing config-table.yml-style check (or a new
sibling workflow you add for the ToC) actually catches a deliberately
stale ToC (test this by temporarily adding a heading, confirming `--check`
fails, then removing it).

Cost policy: this is well-specified, mechanical scripting work (parse
headings, render a nested list, diff against committed content) closely
modelled on an existing script in the same repo — suited to a low-to-mid-
cost tier.

Deliverable: a PR adding the ToC-generation script, the generated ToC
regions in both documents, and (if you choose to add one) a CI check —
following CLAUDE.md's generated-region convention precisely enough that a
future contributor reading CLAUDE.md would recognise this as the same
pattern already established for the config tables.
```

## Prompt for R-13 — Lower the barrier to local development without full production infrastructure

**Bundles:** R-13 only · **Run after:** no prerequisites

```text
Context: agent-ops is currently operated by a single person; its roadmap
(docs/ROADMAP.md) plans a future where external contributors and eventual
customers are involved. Today, exercising the pipeline's actual logic
locally requires Docker, a live GitHub token with write access, a
configured git identity, Tailscale (for the dashboard), and Claude
credentials — there is no mocked or fixture-based path for iterating on
pipeline logic without all of that.

The problem: this is proportionate friction for the project's current,
single-operator stage, but it will matter more as docs/ROADMAP.md's
productisation work (its D1/D9 decisions) brings in contributors who are
not the operator and do not have (or should not need) live write-scoped
credentials to iterate on pipeline logic.

The goal: identify and implement a minimal path for exercising core
pipeline logic (at least: Co-Ordinator candidate selection and Implementer
dispatch, since these are the highest-value paths to iterate on without
live credentials) against mocked or fixture-replayed GitHub API responses,
rather than requiring a live token and real repository access. Use this
repo's existing test/fixtures/ directory and its conventions as your
starting point for what a mock/fixture shape should look like — do not
invent an unrelated pattern.

Constraints: this is explicitly lower priority and lower urgency than every
other recommendation in this review (the project's current single-operator
audience does not strictly need this yet) — do not let it block or delay
higher-priority work, and treat "not urgent" as license to keep the scope
small rather than building a comprehensive mocking framework. Do not change
how the pipeline behaves against real GitHub in production — this is
purely an additive local-development affordance.

Verification: demonstrate that a Co-Ordinator (or Implementer) dispatch can
run end-to-end against your mocked/fixture GitHub responses, with no live
GH_TOKEN required, and produces the expected candidate selection (or PR
plan) for at least one representative fixture scenario. Document how to use
it in README.md's development section.

Cost policy: this is exploratory, judgement-heavy design work (what to
mock, how much fidelity is needed, how it should integrate with the
existing test/fixtures/ conventions) — do the design at a high-capability
tier; once the shape is decided, the mechanical work of writing individual
fixture files can be delegated to a lower-cost tier.

Deliverable: a PR adding the mocking/fixture-replay mechanism, at least one
worked example exercising it, and a short README.md section explaining how
to use it for local iteration.
```

## Prompt for R-14 — Add baseline contributor/security governance docs ahead of productisation

**Bundles:** four small, independent documentation additions (SECURITY.md, a licence-decision note, CONTRIBUTING.md, issue/PR templates) bundled because they're all "governance documentation currently missing" and can reasonably land as one PR, though SECURITY.md is the one with actual urgency and should not wait on the other three if time is short · **Run after:** no prerequisites

```text
Context: agent-ops is a single-operator internal tool (operator:
warwickallen, per CODEOWNERS) currently transitioning toward a broader
product (docs/ROADMAP.md). It has no SECURITY.md, no CONTRIBUTING.md, and
no .github/ISSUE_TEMPLATE/ or .github/PULL_REQUEST_TEMPLATE.md. Its current
LICENCE is MIT, but docs/ROADMAP.md's decision D5 states the eventual
product licence is an open question ("Source-available (BSL/FSL-family) …
exact licence is an open question with a Phase 1 decide-by gate") — nothing
today signals to a reader that the licence may change.

The goal (four small, independent additions):
1. A SECURITY.md at the repository root naming a private vulnerability-
   disclosure contact (an email address or a private reporting mechanism —
   use your judgement on what's appropriate given the repository owner is
   a single individual; do not invent contact details, ask if none are
   evident from existing files like CODEOWNERS or README.md's own contact
   conventions).
2. A short note — in README.md's introduction or docs/ROADMAP.md's own
   summary near D5 — flagging that the current MIT licence is expected to
   change ahead of the roadmap's productisation, with a pointer to D5 for
   detail.
3. A CONTRIBUTING.md pointing at CLAUDE.md's existing branch-workflow and
   tech-debt conventions (CLAUDE.md is written for an operating AI agent;
   CONTRIBUTING.md should restate the same conventions for a human reader,
   not duplicate CLAUDE.md's content wholesale — summarise and link).
4. .github/ISSUE_TEMPLATE/ and .github/PULL_REQUEST_TEMPLATE.md, with the
   issue template prompting a filer to consider setting the `Priority`
   field (README.md's issue-priority section explains what this field
   does and why it matters for queue ordering) and the PR template
   restating the Conventional Commits title requirement CLAUDE.md already
   documents.

Constraints: keep every document short — these are pointers and policy
statements, not full guides; this repository already has CLAUDE.md and
README.md carrying the substantive detail, and these new documents should
link to them rather than duplicate them. Do not change any existing
document's content beyond the small addition described in item 2.

Verification: no automated check applies to most of this — read each new
document once complete and confirm it accurately reflects this repository's
actual current conventions (cross-check CONTRIBUTING.md's claims against
CLAUDE.md, the PR template's claims against .github/workflows/commit-
format.yml's actual enforcement). If this repo has any markdown-lint or
trailing-whitespace check (check package.json/CI workflows — CLAUDE.md
mentions a whitespace/format gate), run it against the new files.

Cost policy: this is small, mechanical documentation work suited to a
low-cost tier throughout — no part of this needs a higher-capability tier.

Deliverable: one PR (or up to four small ones, your judgement) adding
SECURITY.md, the licence note, CONTRIBUTING.md, and the issue/PR templates.
```

## Prompt for R-15 — Small developer-experience consistency fixes

**Bundles:** five small, independent, mechanical consistency fixes (a `set -e` convention, `--help` on four scripts, an optional Makefile, an optional .editorconfig) bundled into one PR since none has enough substance to warrant its own review round · **Run after:** no prerequisites

```text
Context: agent-ops is a ~250-script Bash/Perl codebase with generally
strong internal consistency (universal `[[ ]]` over `[ ]`, consistent
underscore-prefixed private-helper naming), but a handful of small
conventions are applied inconsistently.

Four independent fixes:
1. `set -e` usage: of 47 scripts/*.sh files that set shell options, 42 use
   `set -uo pipefail` and 5 use `set -euo pipefail` (find them by grepping
   for `set -e`), with no documented rule for which a new script should
   pick. Decide and document one default convention (recommendation:
   standardise on `set -uo pipefail`, matching the majority, with `-e` as a
   commented, deliberate opt-in per file where genuinely wanted) — add one
   sentence stating the rule to scripts/lint-shell.sh's header comment (or
   wherever this repo's shell conventions are otherwise documented — check
   CLAUDE.md first). Do not mass-convert the 5 outlier files unless you
   verify each one's behaviour is unaffected by the change (an `-e` script
   relying on early-exit-on-error semantics may behave differently without
   it) — where in doubt, leave outliers as-is and just document the rule
   going forward.
2. `--help`: agent-cycle.sh, review-cycle.sh, scripts/serve-dashboard.sh,
   and scripts/open-dashboard.sh have no `-h`/`--help` handling, unlike
   scripts/doctor.sh, scripts/watch-node.sh, scripts/run-tests.sh, and
   scripts/state-sync.sh, which all have a `usage()` function reachable via
   `-h`/`--help`. Add the same convention to the four missing scripts,
   matching the existing scripts' usage-text style and exit-code
   convention (check scripts/doctor.sh's pattern as your reference).
3. (Optional, your judgement on value) A root-level Makefile with targets
   wrapping the existing lint/test/build entry points (e.g. `make lint` →
   scripts/lint-shell.sh, `make test` → scripts/run-tests.sh, `make
   build-image` → the documented docker build command) — purely additive,
   does not replace any existing script.
4. (Optional, your judgement on value) A root-level .editorconfig with
   shell-appropriate defaults (2-space indent, LF line endings, trim
   trailing whitespace — check whether a trailing-whitespace CI gate
   already exists per CLAUDE.md and make sure the .editorconfig doesn't
   contradict it).

Constraints: no behaviour change to any script's actual functionality —
these are purely additive (a new flag, a new file) or documentation-only
(the `set -e` convention note). Do not touch the 5 files that already use
`set -euo pipefail` unless you've verified doing so is safe, per item 1's
guidance above.

Verification: for item 2, run each of the four scripts with `-h`/`--help`
and confirm it prints usage and exits 0 without side effects. Run
scripts/lint-shell.sh (shellcheck) after any changes. Run the full suite
via scripts/run-tests.sh to confirm no regression.

Cost policy: this whole task is mechanical, well-specified, low-risk work
— suited entirely to a low-cost tier, with no part needing escalation to a
higher tier.

Deliverable: a single PR bundling whichever of these four items you
complete (item 1's documentation note and item 2's four `--help` additions
are the core of this recommendation; items 3-4 are optional nice-to-haves —
include them only if they're low-effort in context).
```

## Prompt for R-16 — Dashboard label association and a documented data inventory ahead of multi-tenancy

**Bundles:** two small, independent fixes (a dashboard accessibility fix, a documentation addition) bundled purely for PR convenience, not because they're substantively related · **Run after:** no prerequisites

```text
Context: agent-ops's dashboard (dashboard/index.html) and its overall data
handling were both reviewed. Two small, unrelated gaps were found.

Fix 1 (dashboard/index.html): the cost-window control's `costWindowControl()`
function (around lines 834-851) builds a `<label>` as a plain sibling of its
`<select class="costwindow">`, with no `for`/`id` pairing or wrapping — so
the label has no programmatic association with the control for assistive
technology. Contrast the auto-refresh checkbox elsewhere in the same file
(around line 258): `<label><input type="checkbox" id="autorefresh"
checked> auto-refresh</label>` — correctly nested so the association is
implicit. Fix: either wrap the `<select>` inside the `<label>` (matching
the auto-refresh checkbox's pattern) or add a matching `for`/`id` pair.

Fix 2 (documentation): no document in this repository catalogues what
personal or sensitive data the pipeline touches, stores, or retains
(GitHub usernames, PR/issue text, retention periods for cycles_retained /
log_retained_bytes in config.json). This is low-risk today (the data
touched is already public GitHub metadata, and the audience is one
operator) but will matter more once docs/ROADMAP.md's planned multi-tenant
generalisation proceeds to act on other organisations' repositories. Fix:
add a short section (a new heading in README.md, or a small new
docs/DATA-HANDLING.md if that fits this repo's existing docs/ organisation
better — check how docs/METERING-SCHEMA.md is referenced from README.md
for the pattern to follow) stating what data is read, what's stored, for
how long (reference the actual config keys that govern retention), and
where (which repositories/artifacts).

Constraints: Fix 1 must not change the cost-window control's visible
layout or behaviour, only its accessibility markup. Fix 2 should describe
what the pipeline *actually* does today (verified against config.schema.json
and the relevant lib/scripts/ code), not aspirational future behaviour —
if you're not sure whether something is retained or how long, check the
code/config rather than guessing.

Verification: for Fix 1, run test/dashboard-render.test.sh (the dashboard's
existing rendering test harness) and confirm it still passes; if practical,
confirm in a browser or via markup inspection that the label/select
association is now correct (e.g. clicking the label text now focuses the
select). For Fix 2, cross-check every claim in your new documentation
against the actual config.schema.json keys and code it describes.

Cost policy: both fixes are small and well-specified, suited to a low-cost
tier.

Deliverable: a single PR with both fixes (or two small PRs, your
judgement).
```

## Prompt for R-17 — Add shell/Perl-aware SAST scanning

**Bundles:** R-17 only · **Run after:** no prerequisites, but be aware this is exploratory (a spike) rather than a guaranteed-shape implementation task

```text
Context: agent-ops runs CodeQL (.github/workflows/codeql.yml) as part of
its CI, but that workflow's own comments note it only scans the `actions`
language (GitHub Actions workflow YAML) because CodeQL has no Shell or Perl
support — leaving the ~27,000 lines of lib/, scripts/, and the two cycle
entry points (agent-cycle.sh, review-cycle.sh) with no automated
security-pattern scanning beyond shellcheck's style/correctness checks
(shellcheck is not a security scanner — it catches quoting bugs and
portability issues, not e.g. injection-shaped patterns as a category).

The goal: evaluate and, if it proves viable, add a shell/Perl-aware static
analysis tool to CI as a genuine additional security-scanning layer
alongside the existing shellcheck gate. Semgrep (with its community shell
ruleset) is a reasonable starting candidate given its existing community
rule coverage for shell, but evaluate what's actually available and
maintained at the time you do this work rather than assuming Semgrep is
still the best choice.

Approach — treat this as a spike first, not a guaranteed CI addition:
1. Run your chosen tool's shell ruleset against this repository's current
   lib/, scripts/, agent-cycle.sh, and review-cycle.sh and record its
   findings.
2. Triage the findings by hand: how many are genuine (even if low-severity)
   versus false positives against this codebase's actual patterns and
   conventions? A tool with a high false-positive rate on ~250 scripts of
   this specific style is worse than no tool, since it trains reviewers to
   ignore it.
3. If the signal-to-noise ratio looks workable, add it to CI as a
   non-blocking (report-only, e.g. annotate but don't fail the check)
   workflow initially, following this repo's existing workflow-authoring
   conventions (compare shellcheck.yml and codeql.yml for style: pinned
   tool version where relevant, `pull_request` not `pull_request_target`,
   minimal `permissions:`). Only propose making it a blocking/required
   check in a follow-up, after it's been observed running non-blocking for
   a period and its noise level is confirmed acceptable — do not make it
   blocking in this same task.
4. If the signal-to-noise ratio looks unworkable for every tool you
   evaluate, document that finding (which tools you tried, what you found)
   rather than forcing a bad tool into CI — a documented "we looked and it
   wasn't worth it yet" is a valid outcome for this task.

Constraints: do not make any new scanning workflow a required/blocking
check without the non-blocking observation period described above. Follow
this repo's existing workflow security conventions exactly (no
`pull_request_target` on anything that runs on PR content, matching every
existing PR-triggered workflow's stated reasoning for avoiding it).

Verification: if you add a workflow, confirm it runs successfully on this
repository's actual code (not just a toy example) and produces output a
human can act on. If you conclude no tool is currently viable, your
"verification" is a clear written record of what you tried and why it
didn't meet the bar.

Cost policy: the evaluation/triage work needs judgement (assessing
false-positive rate against this specific codebase's idioms) — do this at
a mid-cost tier. Writing the resulting CI workflow, once the tool is
chosen, is mechanical and suits a low-cost tier.

Deliverable: either a PR adding a new non-blocking CI workflow (with the
evaluation notes in the PR description), or, if no tool proved viable, a
short write-up (as a PR comment, an issue, or a tech-debt item per
TECH-DEBT.md's filing workflow) recording what was evaluated and why
nothing was adopted yet.
```
