# Summary

## What this project is

`agent-ops` is the operations tooling for the "Poetic" autonomous coding-agent system: a
self-hosted, unattended pipeline that runs Claude agents (via the `claude` CLI) against three
target repositories — `Poetic-Poems/poetic`, `Poetic-Poems/poetic-fiddle`, and `agent-ops`
itself — once an hour, selecting, implementing, and reviewing work items, then landing pull
requests under a configurable trust ladder that can, at its top rungs, merge with no human in
the loop. It also hosts the repository-review pipeline that produced this very review
(`review-cycle.sh`), and a static local monitoring dashboard.

Almost the entire codebase is Bash: 304 `.sh` files (~122k lines including tests), plus 5 Perl
scripts for the tech-debt register tooling and exactly one JS file (a Node test harness for the
dashboard's own inline script). There is no language package manager — dependencies are OS
packages plus the `claude` and `gh` CLIs. Deployment is Docker, with a Tailscale sidecar and an
egress allowlist/proxy that fences the container's outbound network access. The project is
maintained by a single person (Warwick Allen), MIT licensed, with 612 commits since
2026-07-13 — this is genuinely young (under two months old) but unusually mature for its age,
carrying 173 test files, 11 CI workflows, a 203-item tech-debt register, and ~40,000 words of
as-built specification documents.

## Overall assessment

This is a well-engineered, actively-maintained system with an unusually strong engineering
culture for its size and age. Zero Critical or High findings were raised in this pass. The
project's own investment in guardrails is real, not decorative: branch protection genuinely
blocks merges on 9 required status checks plus a required human review; the test suite (171
files, ~8,400 assertions) is overwhelmingly built from regression tests tied to named, numbered
production incidents, and every file spot-run for this review passed; credential handling
throughout the GitHub-App-token machinery is unusually careful for a bash codebase (stdin, not
argv, for secrets; tmpfs-checked caching; author/approver identity separation with fail-closed
kill switches); and the health/liveness/crash-loop machinery (`lib/crash-loop.sh`,
`lib/stage-health.sh`, `lib/updater-health.sh`) each trace to a specific real production
incident and demonstrably closed the gap that incident exposed.

The most important single fact this review surfaces is comparative: measured against the prior
review 8 days ago (2026-08-23), the project's largest architectural debt — a 9,920-line
undecomposed `agent-cycle.sh` — was substantially addressed in the intervening week (PR #771,
verified: the file is now 3,341 lines, with the bulk of its logic relocated into 29 new `lib/`
files). That is a genuinely fast, genuinely real turnaround on the previous review's top
recommendation, and it is the strongest evidence in this review that the tech-debt register and
review-cycle machinery this project built for itself actually works as intended. The residue of
that same refactor — a still-undecomposed top-level cycle flow, and five relocated functions
that grew rather than shrank — is this review's own top finding (R-01), a smaller version of the
same problem one layer down.

Nothing in this review rises to Critical or High. The most substantive individual finding is a
dashboard helper function (`esc()`) whose name promises HTML-escaping it doesn't perform — not
currently exploitable given what data reaches it and the dashboard's loopback-only exposure, but
a real trap for a future maintainer. The rest of the findings are the ordinary residue of a fast-
moving, single-maintainer project: some duplicated utility code the codebase's own "promote to
`lib/`" convention hasn't yet reached, a security-scanning tool (CodeQL) that is honestly
documented as unable to cover the codebase's actual language, some missing but low-urgency
governance documents (SECURITY.md, a personal-data inventory), and a config-drift CI check that
runs but doesn't yet block a merge. Fourteen of this review's 29 findings turned out to already
be tracked by open GitHub issues from the prior review — itself a sign the register is a living,
consulted record rather than a filing exercise — and one tech-debt item was found already
resolved in code but not yet marked so; that bookkeeping was corrected directly as part of this
review.

## Headline strengths

- Branch protection and CI are real and verified, not assumed: a required-status-check ruleset
  covering build/test/lint/security-scan/commit-format/tech-debt-register checks, a required
  human review, and a merge queue, confirmed directly against the GitHub API.
- The test suite is large (171 files, ~8,400 assertions), demonstrably passing on every file
  sampled, and overwhelmingly composed of regression tests traceable to specific numbered
  incidents rather than generic coverage padding.
- Credential handling (GitHub App tokens, Approver/Author identity separation, egress fencing)
  is disciplined well beyond what's typical for a bash-native project.
- The prior review's top architectural finding (`agent-cycle.sh`'s size) was substantially
  fixed within 8 days, evidence the project's own review→register→fix loop functions in
  practice, not just on paper.
- The health/liveness/crash-loop machinery is grounded in real, named incidents and
  demonstrably closes the specific gaps those incidents exposed, rather than being speculative
  hardening.
- The tech-debt register (203 items, `perl scripts/td-check.pl`-verified consistent) and the
  as-built spec documents together give this genuinely solo-maintained project an unusually
  strong bus-factor story for its size.

## Headline risks

- `agent-cycle.sh`'s ~2,000-line undecomposed main flow, and five relocated `lib/` stage
  functions that grew during the same refactor that was meant to shrink them [F-ARCH-01,
  F-CODE-01].
- A dashboard helper (`esc()`) whose name misleadingly implies HTML-escaping it doesn't perform
  — currently unreachable by attacker-controlled data, but a live trap for the next feature that
  reaches for it [F-SEC-01].
- No update mechanism (Dependabot/Renovate) for agent-ops's own pinned dependencies, and two
  Docker Compose sidecar images floating on `:latest` with no pin at all [F-DEPS-01, F-DEPS-02].
- A config-drift CI check (`config-table.yml`) that runs on every PR but is not actually a
  required merge gate, despite being documented as one [F-CI-01].
- The dashboard's primary interactive elements (clickable cards and rows) have no keyboard
  equivalent, unlike comparable UI elsewhere in the same file [F-UX-01].

## Scope and method

Exhaustive line-by-line reading of ~122k lines of shell plus ~67k lines of tests was not
attempted within this review's time budget. Reconnaissance (project structure, stack, CI,
governance surface) was read in full. Both pipeline entry points (`agent-cycle.sh`,
`review-cycle.sh`), all 11 CI workflow files, all 9 operating prompts, and all four `docs/
*-SPEC.md` as-built specs were read for structure and spot-checked for drift against the code
they describe. The 13 checklist dimensions were then delegated to six parallel subagents (grouped
ARCH+CODE, SEC+DATA, TEST+CI, DEPS+TOOL, PERF+OPS, UX+DOC+GOV), each given the same project map
and the checklist's guidance for its dimensions, and instructed to sample the `lib/`/`scripts/`
tree deliberately — reading security- and trust-sensitive modules in full (auth, tokens,
merge-autonomy, claim/lock, landing) and a representative cross-section of the rest — rather than
attempt exhaustive coverage. Every subagent was asked to corroborate reading with real tool runs
wherever feasible rather than presenting an unverified guess as a tool-confirmed result.

Tools actually run and their results, as verified by this review: `perl scripts/td-check.pl`
(203 items, consistent); `scripts/render-config-table.sh --check` (all four generated regions
match `config.schema.json`); `scripts/lint-shell.sh` (shellcheck 0.10.0, 308 files, exit 0,
clean); `gh api repos/Poetic-Poems/agent-ops/rulesets/18857310` (branch-protection ruleset,
read directly rather than inferred); 18 individual `test/*.test.sh` files run standalone on the
host (all 18 passed); `git log`/`git show`/`grep`/`git log -S` used extensively to verify claims
against actual commit history rather than commit messages alone. Docker was unavailable in the
reviewing environment, so the full Dockerized test suite (`scripts/run-tests.sh` with no
arguments, ~173 files) was **not** run — the 18-file host sample and the repo's own documented
CI behaviour (verified via the workflow files and the branch-protection ruleset, not by watching
a live CI run) stand in for it; this is the review's most significant coverage gap and is called
out explicitly in the relevant findings (F-TEST-02) rather than silently assumed away. No
automated accessibility checker (axe, Lighthouse) was available either; the UX dimension's
dashboard assessment rests on static markup/JS reading, noted explicitly in F-UX-01.

All 13 checklist dimensions were judged applicable to this project and none were skipped;
proportionality was applied throughout given the project's nature (single-maintainer internal
tooling, not a public product or a high-QPS service) — most visibly in PERF (judged as a
low-frequency batch pipeline, not a hot service) and GOV (absence of CONTRIBUTING.md/issue
templates not penalised the way it would be for a community open-source project), while security-
and credential-relevant findings were still weighed at full severity per the review's own "a
dangerous defect in a trivial project" principle, regardless of the project's youth or scale.
