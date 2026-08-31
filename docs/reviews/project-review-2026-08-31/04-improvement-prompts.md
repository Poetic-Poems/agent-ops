# Improvement prompts

One prompt per recommendation, in priority order (severity first, then effort within a
severity band). Each prompt is self-contained: paste it into a fresh AI agent session with a
clone of `Poetic-Poems/agent-ops` checked out and it has everything it needs. No prompt in this
set depends on another having been done first, so they can be run in any order or in parallel by
different agents — noted per-prompt for clarity anyway.

## Prompt for R-01 — Decompose `agent-cycle.sh`'s main flow and the largest relocated `lib/` stage functions

**Bundles:** R-01 only. **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops, the operations tooling for an autonomous
coding-agent pipeline, implemented almost entirely in Bash. Follow this repository's own
CLAUDE.md (read it first) — in particular: work in a dedicated fresh clone of origin/main, every
change lands via a pull request with a Conventional Commits title, and this repo's docs/*-SPEC.md
files are as-built specs that must stay accurate if your change alters what a component does.

THE PROBLEM: agent-cycle.sh (the implementation pipeline's entry point) recently had most of its
logic extracted into lib/*.sh (PR #771, 2026-08-23), but two things were left undecomposed:

1. agent-cycle.sh's own main flow. acquire_lock() (the last function definition) ends around
   line 1377; the file runs to about line 3341 — roughly 1,950 lines of claim acquisition, five
   stage dispatches, and cleanup execute at the top level with no enclosing function. Compare
   this to review-cycle.sh (the sibling review pipeline, same author, same repo), whose
   equivalent flow is a 26-line loop calling one review_one() function.

2. Four of the functions #771 relocated into lib/ grew larger rather than smaller in the weeks
   since: lib/enabler.sh's maybe_run_enabler (currently ~856 lines, roughly 59% of that file),
   lib/approver.sh's run_approver_stage (~418 lines), lib/landing.sh's _landing_stage_attempt
   (~360 lines), lib/refinement.sh's maybe_run_refiner (~318 lines). For comparison, lib/handoff.sh
   in the same repo decomposes its largest responsibility into a 115-line top function plus many
   small named helpers — that's the standard to match.

THE GOAL (acceptance criteria):
- agent-cycle.sh's main flow (currently top-level script) is refactored into named functions for
  its major phases (claim acquisition, per-stage dispatch, cleanup), the way review-cycle.sh's
  review_one() already models in this same repo.
- At least one of the four named lib/ functions is split into smaller named helpers for its
  guard clauses, claim logic, and per-verdict branches — you do not have to do all four in one
  PR; pick the one that is easiest to decompose safely, or address more than one if time allows.
- Zero behaviour change. Every existing test in test/*.test.sh must still pass unmodified — these
  tests assert externally observable behaviour (log events, exit codes, git state), not internal
  function names, so a pure decomposition should not require touching any test file. If a test
  genuinely needs updating, that is a signal you changed behaviour, not just structure — stop and
  reconsider.

CONSTRAINTS:
- Do not change what any stage does, what it logs, or its exit-code contract — this is a
  structural refactor only.
- Follow this codebase's existing conventions: set -euo pipefail, local for all function-local
  variables, the header-comment style already used throughout lib/ (design rationale, not just a
  one-line description).
- If your change alters anything docs/IMPLEMENTATION-PIPELINE-SPEC.md describes (it likely
  won't, since this is pure internal structure, but check), update the spec in the same PR per
  CLAUDE.md's rule.

VERIFICATION: run scripts/lint-shell.sh (shellcheck) and confirm it is still clean. Run the
affected test files directly (e.g. bash test/<relevant>.test.sh) and confirm they pass; if
Docker is available, scripts/run-tests.sh gives the full, CI-equivalent run — prefer it if you
have it. Do not declare this done without having actually run and observed passing output from
at least the tests that exercise the function(s) you touched.

COST POLICY: work cost-consciously. Where your environment supports subagents, delegate
well-specified, self-contained subtasks (e.g., "extract this 40-line guard-clause block into a
named helper function, preserving exact behaviour") to subagents running a low-cost model tier.
Reserve a high-capability tier for deciding *how* to split each function's responsibilities and
for reviewing the extracted result before integrating it — getting the split boundaries wrong is
the main risk here, not the mechanical extraction itself. If subagents are unavailable, complete
the task directly.

DELIVERABLE: a pull request (or several, if you split the four lib/ functions across multiple
PRs) with a Conventional Commits title, a description naming which function(s) were decomposed
and confirming the test suite still passes, referencing this review
(docs/reviews/project-review-2026-08-31, R-01) and GitHub issue agent-ops#964.
```

## Prompt for R-02 — Eliminate duplicated small utility functions across entry points and scripts

**Bundles:** R-02 only (F-ARCH-02 + F-CODE-02 — same root cause: duplicated code the codebase's
"promote to lib/" convention hasn't yet reached). **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops (an autonomous coding-agent pipeline's ops tooling,
almost entirely Bash). Read this repository's CLAUDE.md first and follow its conventions
(dedicated fresh clone, PR-based workflow, Conventional Commits PR titles).

THE PROBLEM: several small utility functions are defined more than once, verbatim or near-
verbatim, instead of living once in lib/ and being sourced:

1. expand_home() is byte-identical in agent-cycle.sh (~line 405) and review-cycle.sh (~line 128).
2. cfg()/cfg_json() are identical one-liners in agent-cycle.sh (~430-431) and review-cycle.sh
   (~163-164).
3. log_event() is structurally identical in agent-cycle.sh (~844-856) and review-cycle.sh
   (~257-266), differing only in the field name it closes over ("cycle" vs "review") and which
   log file it appends to.
4. san() — a claim-path sanitiser, `local s="$1"; printf '%s' "${s//\//__}"` — is duplicated
   between lib/claim.sh (~line 119) and scripts/sweep-orphan-branches.sh (~line 147).
   sweep-orphan-branches.sh already sources three other lib/ files (lib/github-limit.sh,
   lib/config-schema.sh, lib/tech-debt-file.sh) but not lib/claim.sh.

THE GOAL (acceptance criteria): each function above has exactly one definition, living in an
appropriate lib/*.sh file, sourced by every caller that needs it. No behavioural change — the
functions' bodies should end up byte-identical to (or a parameterised generalisation of) what
they replace.

CONSTRAINTS: log_event()'s two current variants differ in one closed-over field name and target
file — when unifying, either pass those as parameters or confirm both callers can share a single
implementation cleanly; do not silently make agent-cycle.sh and review-cycle.sh log to the same
file. Preserve existing shell option discipline (set -euo pipefail, local usage) throughout.

VERIFICATION: run scripts/lint-shell.sh and confirm clean. Run test/claim.test.sh and any test
file covering scripts/sweep-orphan-branches.sh, plus any agent-cycle.sh/review-cycle.sh wiring
tests that touch log_event/cfg/expand_home behaviour, and confirm all pass. Diff the old
duplicate function bodies against the new shared one before deleting either copy, to confirm you
aren't introducing a subtle behaviour change.

COST POLICY: this whole task is small and mechanical — well suited to a low-cost model tier
end to end, with a quick review pass at a higher tier before opening the PR given it touches the
pipeline's two entry points.

DELIVERABLE: one pull request, Conventional Commits title, referencing this review
(docs/reviews/project-review-2026-08-31, R-02) and GitHub issues agent-ops#964 and agent-ops#967.
```

## Prompt for R-03 — Fix the dashboard's misleadingly-named `esc()` helper

**Bundles:** R-03 only. **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops. The repository hosts dashboard/index.html, a single
static HTML file with inline JS/CSS that is the pipeline's local monitoring dashboard, served
loopback/tailnet-only (never publicly exposed). Read CLAUDE.md first for repo conventions.

THE PROBLEM: dashboard/index.html defines, around line 307:
    function esc(s) { return String(s == null ? "" : s); }
Despite its name, this performs no HTML entity-encoding — it's a plain string cast. Most call
sites are safe anyway because their result is passed as a DOM child (via el()'s child handling,
which uses document.createTextNode and so is correctly escaped regardless of esc()'s behaviour).
But one call site is not safe by construction: kv() (around line 2051) builds
  el("span", {class:"kv", html: k + " <b>" + esc(v) + "</b>"})
and el()'s "html:" attribute path (around line 279) does `e.innerHTML = attrs[k]` — a real
innerHTML sink. Today, kv()'s v arguments (g.model, g.terminal_reason, etc., around lines
2052-2056) are internal pipeline metadata, not attacker-controlled GitHub content, so this is not
currently exploitable — but the function's name actively invites a future author to reach for it
believing it's safe when routing GitHub-sourced text (an issue title, a PR body snippet, a
fail_detail string) into an html: slot.

THE GOAL (acceptance criteria): choose ONE of these two fixes and implement it fully:
  (a) Rename esc() to something that does not imply HTML-safety (e.g. str() or toStr()), and
      grep the whole file for every "html:" attribute usage to confirm each one only ever
      receives trusted, non-GitHub-sourced strings — document that constraint next to el()'s
      "html:" branch so it doesn't silently become false later.
  (b) Make esc() actually HTML-entity-escape its input (&, <, >, ", '), and confirm every
      existing esc() call site still renders correctly (the DOM-child call sites will now be
      double-escaping if you don't adjust them — check whether text-child call sites should call
      a *different*, non-escaping function instead, since createTextNode already escapes).
Option (a) is smaller and lower-risk; prefer it unless you have a specific reason GitHub-sourced
text needs to flow through the html: path in the near future.

CONSTRAINTS: dashboard/index.html has no build step — it must remain valid, directly-servable
HTML/JS after your edit. Do not change the dashboard's visual output for any currently-rendered
field.

VERIFICATION: this repo has a test harness specifically for this file — run
test/dashboard-render.test.sh (which drives test/dashboard-render-harness.js, a Node harness
that runs the page's own unmodified inline script against fixture data) and confirm it still
passes. Manually trace every "html:" call site in the file after your change and confirm none of
them can receive attacker-influenced text without going through actual escaping.

COST POLICY: the analysis and fix-choice here are the part that matters (a wrong choice
re-introduces the risk) — do that at a high-capability tier. Mechanical parts (the rename itself,
or writing the escape function) can be delegated to a lower-cost tier once the approach is
decided, with the result reviewed before integrating.

DELIVERABLE: a pull request, Conventional Commits title, referencing this review
(docs/reviews/project-review-2026-08-31, R-03) and GitHub issue agent-ops#965.
```

## Prompt for R-04 — Make the config-table check an actual required merge gate

**Bundles:** R-04 only. **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops. Read CLAUDE.md first.

THE PROBLEM: .github/workflows/config-table.yml runs on every pull request and checks that
README.md's and the specs' generated config-table regions match config.schema.json (via
scripts/render-config-table.sh --check). But it is absent from the repository's branch-
protection ruleset's required status checks — confirmed via
`gh api repos/Poetic-Poems/agent-ops/rulesets/18857310`, whose required_status_checks[].context
list is exactly: Analyze (actions), Build and test (linux/amd64), Build and test (linux/arm64),
Work out the version stamp, Work out what changed, closing-keyword, commit-format, register,
shellcheck — config-table is not among them. Yet CLAUDE.md describes it in gate language ("runs
the same check on every pull request"), implying it blocks a merge. It does not: a PR can leave
this check red and still enter the merge queue and land.

THE GOAL: the check either genuinely gates merges, or the documentation stops implying it does.
Prefer making it gate — that's the check's evident purpose (CLAUDE.md explains at length why
hand-editing a generated region is a real hazard) — unless you find a concrete reason the
maintainer would want it advisory-only, in which case fix the wording in CLAUDE.md instead and
say so in your PR description.

CONSTRAINTS: modifying a GitHub ruleset is a repository-settings change, not a code change — you
will need `gh api` write access to
repos/Poetic-Poems/agent-ops/rulesets/18857310 (a PATCH request adding "config-table" to
required_status_checks) rather than a file edit. If your environment does not have permission to
modify repository rulesets, stop and report that explicitly rather than guessing at a workaround
— do not attempt to route around branch protection.

VERIFICATION: after the change, re-run `gh api repos/Poetic-Poems/agent-ops/rulesets/18857310`
and confirm "config-table" now appears in required_status_checks[].context. If you instead chose
the documentation-only fix, verify by re-reading the updated CLAUDE.md passage.

COST POLICY: this is a small, well-specified task (either an API call or a short doc edit) — a
low-cost model tier should complete it correctly in one pass; verify the ruleset state
afterward regardless of which tier did the work.

DELIVERABLE: either a confirmed ruleset change (report the before/after required_status_checks
list) plus a short PR noting the change if any repo file also needed updating, or a pull request
correcting CLAUDE.md's wording — referencing this review (docs/reviews/project-review-2026-08-31,
R-04) and GitHub issue agent-ops#1144.
```

## Prompt for R-05 — Add an update mechanism and pin floating references in agent-ops's own supply chain

**Bundles:** R-05 (F-DEPS-01 + F-DEPS-02 + F-TOOL-03 — all "pin/update agent-ops's own external
references," naturally addressed together though independently shippable). **Run after:** no
prerequisites.

```text
You are working in Poetic-Poems/agent-ops. Read CLAUDE.md first.

THE PROBLEM (three related gaps, none currently addressed):
1. No .github/dependabot.yml (or Renovate config) exists for agent-ops's OWN dependencies.
   lib/dependabot-bump.sh and scripts/nudge-dependabot-rebase.sh only handle Dependabot PRs
   opened against the *target* repos this pipeline operates on (Poetic-Poems/poetic,
   poetic-fiddle) — they do nothing for agent-ops's own pins. Every version pin in this repo
   (SUPERCRONIC_VERSION, SHELLCHECK_VERSION in deploy/docker/Dockerfile and
   .github/workflows/shellcheck.yml, NODE_MAJOR, every `uses: actor/action@vN` line across
   .github/workflows/*.yml) is a hand-maintained literal with no bot proposing bumps.
2. deploy/docker/compose.yaml line ~637 (`image: tailscale/tailscale:latest`) and line ~804
   (`image: containrrr/watchtower:latest`) are both unpinned — in contrast to every other
   version-sensitive dependency in this repo, which is pinned (the base image, supercronic,
   shellcheck are all pinned or ARG-parameterised).
3. Every `uses:` line across .github/workflows/*.yml references a mutable version tag
   (actions/checkout@v7, docker/build-push-action@v7, etc.), not a commit SHA — unlike
   supercronic/shellcheck in the Docker build, which are pinned by tag AND verified against a
   published SHA-1/SHA-256 checksum.

THE GOAL (acceptance criteria):
- .github/dependabot.yml exists with at least a `github-actions` ecosystem entry (add a `docker`
  ecosystem entry too if practical, covering deploy/docker/Dockerfile's base image).
- deploy/docker/compose.yaml's tailscale and watchtower images are pinned to a specific tag (or
  digest) instead of `:latest`.
- At minimum, the Actions used in .github/workflows/build-image.yml's `publish` job (the one
  with contents: write / packages: write on pushes to main) are pinned to commit SHAs rather
  than version tags.

CONSTRAINTS: pinning the Compose sidecar images to a specific *current* tag, not an arbitrary
old one — check each image's current tags on its registry before choosing. Do not break
deploy/docker/compose.yaml's validity: run `docker compose config` (or equivalent) to confirm it
still parses after your edit if Docker is available in your environment; if not, note that you
could not verify this and say so.

VERIFICATION: `docker compose -f deploy/docker/compose.yaml config` should succeed with no
errors if Docker is available. For the Actions SHA-pinning, confirm the workflow still triggers
successfully (or at minimum that the YAML is well-formed and the SHA you pinned corresponds to
the version tag you replaced — check the action's repository's tags API). For dependabot.yml,
validate it against GitHub's schema (a JSON/YAML syntax check at minimum).

COST POLICY: this is mostly mechanical (finding current versions/SHAs, editing config files) —
a low-cost or mid-cost tier should manage it. Reserve a higher tier only if you hit ambiguity
about which Actions genuinely need SHA-pinning versus which are low-risk enough to leave as
version tags (e.g., a workflow with no write permissions is lower priority than one that
publishes images).

DELIVERABLE: a pull request (or up to three, one per item, if that's cleaner) with a
Conventional Commits title, referencing this review (docs/reviews/project-review-2026-08-31,
R-05) and GitHub issue agent-ops#1145.
```

## Prompt for R-06 — Make the dashboard's clickable rows/cards keyboard-operable

**Bundles:** R-06 only. **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops, specifically dashboard/index.html — a single static
HTML file with inline JS/CSS, the pipeline's local monitoring dashboard. Read CLAUDE.md first.

THE PROBLEM: two classes of interactive element in this file respond only to a mouse click, with
no keyboard equivalent:
1. `.card.clickable` — node-filter cards (built around line 1521 via
   `el("div", {class:"card clickable", ...})`), used to filter the whole dashboard by node.
2. `tr.clickable` — cycle/void-item table rows (around lines 2018, 2189), used to expand a
   cycle's stage/cost detail via `tr.addEventListener("click", ...)` (~line 2019).
Neither has a `tabindex`, a `role`, or a `keydown` handler — a `tabindex` search across the whole
file returns zero matches. By contrast, the PR-reference hover-cards elsewhere in the SAME file
already have correct keyboard support (`aria-describedby` at lines ~522, ~549, and documented
Enter-to-navigate / focus-triggered peek behaviour in docs/DASHBOARD-SPEC.md) — so this is a gap
in one part of the file, not a project-wide absence of keyboard-accessibility awareness.

THE GOAL (acceptance criteria): both `.card.clickable` and `tr.clickable` elements are reachable
via Tab and operable via Enter/Space, matching the standard the PR-hover-cards already meet in
this same file. Either:
  (a) add `tabindex="0"`, an appropriate `role` (`"button"` for the cards, consider whether the
      table rows need a different pattern given they're inside a `<table>`), and a `keydown`
      listener that treats Enter/Space the same as `click`; or
  (b) restructure the clickable regions to use real `<button>` elements where that's a cleaner
      fit without breaking the existing table/card layout and CSS.
Also add `scope="col"` to the dynamically-built `<th>` elements (around lines 1395, 1430-1431,
2856), a small related gap noted in the same review.

CONSTRAINTS: no visual/layout regression — the dashboard's appearance for a mouse user should be
unchanged. Preserve existing click behaviour exactly; you're adding a keyboard path alongside it,
not replacing the mouse path. No build step exists for this file — your edit must remain valid,
directly-servable HTML/JS.

VERIFICATION: run test/dashboard-render.test.sh (drives test/dashboard-render-harness.js against
fixture data) and confirm it still passes. Manually trace: can you reach a node-filter card via
Tab and activate it with Enter? Can you reach a cycle row and expand its detail with Enter/Space?
If you have a way to render the page (even opening the static file with a fixture data.js), do an
actual keyboard-only pass rather than reasoning about the JS alone.

COST POLICY: this whole task is well-specified, self-contained front-end work — a low-cost or
mid-cost tier should complete it correctly; a quick review pass afterward (did the click behaviour
survive unchanged?) is the main thing worth a second look.

DELIVERABLE: a pull request, Conventional Commits title, referencing this review
(docs/reviews/project-review-2026-08-31, R-06) and GitHub issue agent-ops#970.
```

## Prompt for R-07 — Refresh the vendored project-review skill's provenance stamp and add a drift-check

**Bundles:** R-07 only. **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops. Read CLAUDE.md first — in particular its rule that
docs/*-SPEC.md files are as-built and any disagreement between a spec and the code/artefact it
describes is a bug to be fixed, not worked around.

THE PROBLEM: docs/REVIEW-PIPELINE-SPEC.md, around lines 118-121, states that
.claude/skills/project-review/ (this repo's own committed copy of the project-review skill,
tracked in git — distinct from any copy injected at runtime into a review's ephemeral clone) is
"a pinned copy of the upstream skill... (upstream commit 2c8e18c, vendored 2026-07-19)". But
.claude/skills/project-review/SKILL.md has been directly edited twice since that provenance line
was last touched: commit 86bfbea (2026-08-01, PR #144, "refresh vendored review skill... from
warwickallen/claude-skills main") and commit 5daa821 (2026-08-28, PR #919, which changed the
skill's Step 0.3 and Step 4 tech-debt handling). Neither commit updated the provenance line in
REVIEW-PIPELINE-SPEC.md (confirm with `git show 86bfbea -- docs/REVIEW-PIPELINE-SPEC.md` and
`git show 5daa821 -- docs/REVIEW-PIPELINE-SPEC.md`, both currently empty).

Separately, docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md item #15 already recommended a drift-check
for this vendored skill, modeled on .github/workflows/td-tooling-drift.yml (which does exactly
this kind of check for a sibling piece of vendored tooling, the tech-debt register scripts) — no
such check exists yet for the project-review skill.

THE GOAL (acceptance criteria):
1. docs/REVIEW-PIPELINE-SPEC.md's provenance line accurately reflects the skill's actual current
   state — either update it to the correct current upstream commit/date if you can determine one
   (check whether warwickallen/claude-skills is a reachable source), or state plainly that the
   vendored copy has since diverged from a pure upstream mirror via #144/#919 and is no longer
   simply "pinned to commit X."
2. Some mechanism exists to catch this kind of drift going forward — ideally an automated CI
   check comparing the vendored copy against its canonical source, modeled on
   td-tooling-drift.yml's approach, if that source is reachable from CI. If a hard CI gate isn't
   practical (e.g. the upstream source isn't CI-reachable), a lighter "last synced" comment
   discipline with a clear update procedure is an acceptable fallback — say which you chose and
   why in your PR description.

CONSTRAINTS: do not change the skill's actual behavior/content as part of this task — this is
about the provenance record and drift-detection, not a skill content update.

VERIFICATION: re-read the corrected provenance line and confirm it matches what `git log --
.claude/skills/project-review/` actually shows. If you added a CI check, confirm it runs
(trigger it or trace its logic) and would have caught the #144/#919 drift had it existed then.

COST POLICY: the provenance-line fix is small and mechanical (low-cost tier). Deciding the
drift-check's design (what to compare against, whether a hard CI gate is practical given the
upstream source's reachability) needs more judgement — use a mid-to-high tier for that design
decision, low-cost tier for the mechanical implementation once decided.

DELIVERABLE: a pull request, Conventional Commits title, referencing this review
(docs/reviews/project-review-2026-08-31, R-07) and GitHub issue agent-ops#1146.
```

## Prompt for R-08 — Fill the security/privacy/ops documentation gaps

**Bundles:** R-08 (F-SEC-02 + F-GOV-01 + F-DATA-01 + F-OPS-02 — all "write a short missing
document" gaps around security/privacy/operations; genuinely separable if preferred, but small
enough to be one PR). **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops, an unattended pipeline with real GitHub write/merge
credentials and a live Anthropic API key. Read CLAUDE.md first.

THE PROBLEM (four related documentation gaps, all "something operationally important isn't
written down anywhere"):
1. No SECURITY.md exists — no disclosure route for a third party who finds a security flaw (e.g.
   in the trust-ladder logic in lib/merge-autonomy.sh, or the egress fence in
   deploy/docker/egress-allowlist.txt).
2. No in-place-compromise/incident-response guidance exists. README.md documents credential
   rotation only on the *full decommission* path (revoke the GitHub token, revoke the Tailscale
   auth key) — there's no equivalent procedure for "rotate this node's credentials while keeping
   it running."
3. No document inventories what personal/sensitive data the system touches — GitHub usernames,
   PR/issue authorship, commit identity (GIT_USER_NAME/GIT_USER_EMAIL) — even though this data is
   real and flows into a private state repository and the local dashboard.
4. Operational incident knowledge (e.g. the 2026-08-21 all-stages-failing incident, the
   2026-08-14 watchtower collision, the 2026-08-24 disk-fill incident) lives entirely in
   source-file header comments (lib/stage-health.sh, lib/updater-health.sh, lib/workspace.sh)
   with no cross-reference from the dashboard's own health/status badges telling an operator
   where to look.

THE GOAL (acceptance criteria):
- A short SECURITY.md exists, naming a disclosure contact/route, AND covering in-place
  credential rotation for a running node (GitHub App token, Tailscale key, Anthropic API key) —
  distinct from and complementary to README.md's existing full-decommission procedure.
- A short data-inventory statement exists (either a new short section in README.md, or a new
  docs/DATA-HANDLING.md) stating: what personal data is touched (GitHub identities, PR/issue
  text), that it is drawn from already-public repositories, where it's stored (the private state
  repo, the local dashboard), and its retention (point at the existing
  state_local_cycles_retained / state_local_streams_retained / log_retained_bytes config keys
  rather than restating their values, which would drift).
- A short cross-reference exists (in docs/DASHBOARD-SPEC.md, or linked directly from the
  dashboard's relevant badges) explaining what each health/crash-loop/updater-health badge means
  and which source file's header comment has the incident-derived detail, so an operator doesn't
  have to already know where to look.

CONSTRAINTS: keep each of these SHORT — this is filling a documentation gap cheaply, not writing
a comprehensive security or privacy policy. Do not restate values that live in config.json/
config.schema.json (e.g. actual retention day-counts) inside these new docs — reference the
config key by name instead, so the new docs can't drift from the schema the way CLAUDE.md warns
generated-region hand-edits can. If any of these new documents affects what docs/DASHBOARD-SPEC.md
or docs/IMPLEMENTATION-PIPELINE-SPEC.md describe as this repo's as-built behaviour, update the
relevant spec in the same PR per CLAUDE.md's rule.

VERIFICATION: re-read each new/updated document for accuracy against the actual code it
describes (e.g., confirm the config key names you reference for retention actually exist in
config.schema.json). No code changes are involved, so no test suite run is required — but if you
touch docs/DASHBOARD-SPEC.md, run scripts/render-config-table.sh --check afterward to confirm
you haven't disturbed a generated region.

COST POLICY: this whole task is documentation writing against material you can read directly
from the codebase — well suited to a low-cost or mid-cost tier throughout, with a light review
pass to check for accuracy against the actual config/code before finalizing.

DELIVERABLE: a pull request, Conventional Commits title, referencing this review
(docs/reviews/project-review-2026-08-31, R-08) and GitHub issues agent-ops#973, agent-ops#975,
and agent-ops#1149.
```

## Prompt for R-09 — Add `openssl` to `doctor.sh`'s toolchain check

**Bundles:** R-09 only. **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops. Read CLAUDE.md first.

THE PROBLEM: scripts/doctor.sh is this repo's preflight/health-check tool — it exists so a
missing dependency is caught before it causes a mid-cycle failure, not after. Its "Toolchain"
section (around lines 704-725) checks bash, jq, git, curl, perl, python3, rsync, flock, timeout,
plus gh, claude, and shellcheck individually — but never checks for `openssl`. Yet
deploy/docker/Dockerfile (lines ~65-67) explains openssl was deliberately added to the image's
package list specifically because lib/approver-token.sh (agent-ops#407) hard-depends on it for
RS256-signing the Pullwright Approver App's JWT — that file calls `openssl` directly at (roughly)
lines 226, 255, 287, and 314. A node missing openssl currently gets no doctor.sh warning and only
discovers the gap when an Approver-App token mint fails mid-cycle.

THE GOAL (acceptance criteria): scripts/doctor.sh's Toolchain section checks for `openssl` the
same way it checks for the other tools, and warns (or fails, matching the severity convention
doctor.sh already uses for the existing Approver-credential checks) specifically when it's
missing AND the node's configured merge_autonomy level is one that actually needs the Approver
App (i.e., don't warn about a missing openssl on a node that will never use it).

CONSTRAINTS: match doctor.sh's existing four-verdict model (ok/warn/fail/skip) and its existing
style for how it gates a check on configuration (look at how it already gates the Approver-
credential checks themselves for the pattern to follow). Do not change any other part of
doctor.sh's Toolchain section.

VERIFICATION: run test/doctor.test.sh and confirm it still passes; add a case to it (or confirm
an existing case covers it) exercising the new openssl check both when merge_autonomy needs the
Approver App and when it doesn't. Manually run `scripts/doctor.sh` (or `--offline` if you lack
live credentials) and confirm the new check appears with sensible output.

COST POLICY: small, well-specified, mechanical — a low-cost model tier should complete this
correctly in one pass, including its test.

DELIVERABLE: a pull request, Conventional Commits title, referencing this review
(docs/reviews/project-review-2026-08-31, R-09) and GitHub issue agent-ops#1147.
```

## Prompt for R-10 — Close small test-coverage gaps

**Bundles:** R-10 (F-TEST-01 + F-TEST-03 — both about the suite's coverage floor). **Run
after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops. Read CLAUDE.md first, and read a couple of existing
files under test/*.test.sh to pick up this repo's test conventions before writing anything — the
suite is hand-rolled bash with no framework, using assert_* helper functions; do not introduce a
new framework or dependency.

THE PROBLEM: lib/git-identity.sh (29 lines) is the sole guard that stops an unattended pipeline
cycle from committing under no git identity or under the wrong one — its own header comment cites
issue #76: "a silent fallback would commit every pull request this node opens under somebody
else's name." No test/*.test.sh file references git_identity or git-identity — it has zero test
coverage, despite being small, pure, and trivially testable (it checks two required environment
variables and, if both are set, calls `git config --global user.name`/`user.email`).

Separately (lower priority, informational): this repo has no coverage-measurement tool (kcov,
bashcov, or similar) anywhere, so there's no quantitative answer to how much of the riskiest code
paths (claim/merge concurrency, auth) are actually exercised by the 171-file suite — only the
qualitative signal that tests are added alongside nearly every fix.

THE GOAL (acceptance criteria):
- A new test/git-identity.test.sh exists, asserting: (a) the function's failure path when a
  required env var is missing (exact variable names: check lib/git-identity.sh's actual
  implementation, don't guess), and (b) that both `git config --global` calls happen with the
  correct values when both vars are set.
- No action is required on the coverage-tooling gap itself — this review's own judgement was that
  adding kcov/bashcov is not currently worth the cost, given bash coverage tooling's general
  awkwardness. If you disagree after looking at the codebase, you may propose it, but it is not
  part of this task's acceptance criteria.

CONSTRAINTS: match the existing test/*.test.sh style exactly — same shebang, same assert_*
helper usage pattern, same file-header comment convention (a short prose explanation of what
production behaviour/incident this test protects against). Do not modify lib/git-identity.sh
itself unless your new test reveals an actual bug (unlikely given the file's simplicity — if you
do find one, note it separately rather than silently fixing it as a side effect).

VERIFICATION: run your new test file directly (`bash test/git-identity.test.sh`) and confirm it
passes; also run it against a deliberately-broken copy of the function (e.g. comment out one
required-var check) to confirm the test would actually catch a regression, then revert.

COST POLICY: this whole task is small, mechanical, well-specified test-writing against a
29-line source file — well suited to a low-cost model tier end to end.

DELIVERABLE: a pull request, Conventional Commits title, referencing this review
(docs/reviews/project-review-2026-08-31, R-10) and GitHub issue agent-ops#1148.
```

## Prompt for R-11 — Developer-experience polish (`.editorconfig`, scripts/lib discoverability)

**Bundles:** R-11 (F-TOOL-01 + F-TOOL-02 — both low-cost DX polish items). **Run after:** no
prerequisites.

```text
You are working in Poetic-Poems/agent-ops. Read CLAUDE.md first.

THE PROBLEM: two small developer-experience gaps, both low priority:
1. No .editorconfig exists anywhere in the repo. The convention of 2-space indentation across
   the 304 *.sh files is consistent by inspection but exists only as an unwritten convention, not
   machine-readable config an editor can pick up automatically. No .shellcheckrc exists either —
   any shellcheck suppressions live inline per-file as `# shellcheck disable=...` comments.
2. No Makefile or scripts index exists. The 58 files under scripts/ and 89 under lib/ are
   discoverable only via directory listing plus reading each file's header comment — there's no
   single place that surfaces "what scripts exist and what do they do" at a glance.

THE GOAL (acceptance criteria):
- A minimal .editorconfig exists: 2-space indent for shell files, LF line endings, trim trailing
  whitespace, final newline — matching the codebase's actual existing convention (verify this
  against a sample of real files rather than assuming).
- A generated scripts index exists — one line per script under scripts/ (and optionally lib/),
  extracted from each file's existing header comment — in keeping with this repo's existing
  "generated region" pattern (see how scripts/render-config-table.sh generates and checks content
  in README.md/docs/*-SPEC.md for the established convention to follow: a checkable, regenerable
  region rather than a hand-maintained list that will drift).

CONSTRAINTS: if you build a generator script for the scripts index, follow the existing
generated-region convention (start/end markers, a --check mode, wired into CI the way
config-table.yml checks scripts/render-config-table.sh's output) rather than inventing a
different pattern. Keep the .editorconfig minimal — don't add rules for languages/file types this
repo doesn't actually use.

VERIFICATION: if you add a --check mode for the new generator, run it and confirm it passes
against its own freshly-generated output. Run scripts/lint-shell.sh to confirm nothing broke.

COST POLICY: this is low-stakes, mechanical DX work — a low-cost model tier should handle the
whole task; only escalate if the generated-index design turns out to need a genuinely fiddly
parser for the header-comment format (unlikely given the codebase's consistent header style).

DELIVERABLE: a pull request, Conventional Commits title, referencing this review
(docs/reviews/project-review-2026-08-31, R-11) and GitHub issue agent-ops#974 (note: #974 also
covers a `set -e` convention and missing `--help` flags on four entry points, which are a
separate, already-tracked concern — this task only needs to address the editorconfig/
discoverability half; leave the rest of #974 alone unless you're deliberately picking it up too).
```

## Prompt for R-12 — Add navigation to the 22,586-line implementation-pipeline spec

**Bundles:** R-12 only. **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops. Read CLAUDE.md first — in particular, this task must
not change any requirement's actual meaning, only its markup/navigability; docs/*-SPEC.md files
are as-built specs and their numbered requirements are referenced by number from commit messages
and code comments throughout the repo (e.g. commit 5b2385e, "requirement 17g") — those numbers
must not shift or be renumbered by this task.

THE PROBLEM: docs/IMPLEMENTATION-PIPELINE-SPEC.md is roughly 22,500 lines with only ~50 Markdown
headings total. Its `## Requirements` section (roughly 13,000 lines) has just 9 `###`
sub-headings, one per actor (e.g. "### The Script (agent-cycle.sh)" spans thousands of lines by
itself). Individual numbered requirements inside each actor's block are written as bold prose
(e.g. "**17g.** ...") rather than as their own headings, so finding a specific numbered
requirement has no navigational aid beyond full-text search, and GitHub's own file-heading-outline
UI is useless at this document's actual size.

THE GOAL (acceptance criteria): a reader (human or agent) can navigate to a specific numbered
requirement via the document's heading structure (GitHub's outline sidebar, or a Markdown TOC
tool) without full-text search. Two acceptable approaches — pick whichever is cheaper to do
correctly:
  (a) Convert each numbered requirement's existing bold-prose lead-in (e.g. "**17g.**") into an
      actual Markdown heading (e.g. "#### 17g" or similar, choosing a heading level that doesn't
      collide with the existing actor-level ### headings), preserving the requirement's exact
      existing text otherwise.
  (b) Add a generated table of contents at the top of the Requirements section (or the whole
      document) listing every requirement number with a working anchor link, without altering
      the existing heading structure at all.
Option (a) is more thorough but touches far more of the file; option (b) is smaller and lower-
risk. Given the document's size, prefer writing a small script to do this transformation
mechanically (matching the existing "**<number><letter?>.**" convention) over a manual pass —
verify the script's output carefully before applying it wholesale.

CONSTRAINTS: absolutely no change to any requirement's actual text or numbering — this task is
markup-only. If you write a transformation script, dry-run it and diff the result against the
original before committing, and check specifically that no existing internal cross-reference
(e.g. "see requirement 17g") breaks.

VERIFICATION: after your change, grep the document for a sample of specific requirement numbers
already cited elsewhere in the repo (e.g. "17g", "2.2", "35e" — search git log/commit messages
and lib/*.sh comments for real examples) and confirm each is now reachable via a heading/anchor,
not just full-text search. If this repo has any doc-linting CI step, run it and confirm it still
passes.

COST POLICY: the transformation is mechanical once the pattern is nailed down, but this is a
large, blast-radius-sensitive document — do the script design and the before/after verification
at a higher-capability tier; the mechanical script execution itself can run at a lower tier once
reviewed.

DELIVERABLE: a pull request, Conventional Commits title, referencing this review
(docs/reviews/project-review-2026-08-31, R-12) and GitHub issue agent-ops#971.
```

## Prompt for R-13 — Evaluate a bash-aware SAST tool as a supplementary security gate

**Bundles:** R-13 only. **Run after:** no prerequisites.

```text
You are working in Poetic-Poems/agent-ops. Read CLAUDE.md first.

THE PROBLEM: .github/workflows/codeql.yml's own header comment explains that CodeQL has no
Shell/Perl/HTML language support, so its one matrix entry (`language: actions, build-mode: none`)
only analyses the 11 files under .github/workflows/*.yml — it provides zero automated security
scanning for the ~304 shell scripts and 5 Perl scripts that make up this codebase's actual attack
surface, including credential-handling code (lib/forge-auth.sh, lib/github-app-token.sh) and the
gh-shim that mediates every GitHub API call. scripts/lint-shell.sh runs shellcheck, which catches
shell-scripting correctness bugs but is not a security-focused analyzer.

THE GOAL: this is an EVALUATION task, not a guaranteed-implementation task. Produce a short,
evidence-based written recommendation (a markdown doc, e.g. docs/SAST-EVALUATION.md, or a
comment on GitHub issue agent-ops#976) answering: is there a bash/shell-aware SAST tool mature
enough to add as a required CI gate here, and would it find real issues beyond what shellcheck
already catches?

Concretely:
1. Survey what's actually available for bash/shell static security analysis (options to
   consider: shellcheck's own security-relevant checks — confirm which ones are or aren't already
   enabled in this repo's invocation; shellharden; a targeted semgrep ruleset for bash; other
   tools you find in your research).
2. Run at least one candidate tool against this actual codebase (or a representative sample of
   it — lib/ and scripts/ together are large) and report its real output: how many findings, how
   many look like true positives on inspection versus noise, and whether any of them are genuinely
   new information shellcheck doesn't already surface.
3. Make a recommendation: adopt a specific tool as a new required CI job (and if so, sketch what
   that workflow file would look like, following this repo's existing workflow-file conventions —
   thorough rationale comments, `paths:` filtering where appropriate), OR conclude the signal-to-
   noise ratio isn't there yet and this gap should stay a documented, accepted limitation.

CONSTRAINTS: do not add a new required CI check without first demonstrating (with real tool
output from this repository, not a hypothetical) that it's worth the false-positive cost — an
overly noisy security gate that gets ignored is worse than no gate. If you do implement a new CI
workflow, follow this repo's existing conventions closely (see any current .github/workflows/*.yml
file for the expected header-comment style and structure).

VERIFICATION: your evaluation doc/recommendation must be backed by actual tool output you ran
against this real codebase — quote it. If you implement a CI workflow, confirm it actually runs
(trigger it, or trace through its logic carefully) before calling the task done.

COST POLICY: the tool survey and running candidates is exploratory work suited to a mid-cost
tier. The final adopt/don't-adopt judgement call, and any new CI workflow's design, deserves a
higher-capability tier given a wrong call here either adds a permanently-noisy gate or leaves a
real gap unaddressed.

DELIVERABLE: either a pull request adding a new, demonstrated-valuable CI workflow (referencing
this review, docs/reviews/project-review-2026-08-31, R-13, and GitHub issue agent-ops#976), or a
written evaluation (as a doc, or posted as a comment on agent-ops#976) explaining why no current
tool clears the bar, with the real tool output you gathered as evidence either way.
```
