# Phase 1 Poetic-specifics audit

This is the inventory `docs/ROADMAP.md` Phase 1's first checklist item asks
for: every place `prompts/`, `lib/`, `scripts/`, `deploy/` and
`config.schema.json` assume Poetic-Poems' own arrangement — a repository
slug, the owner's username, a label name, a branch convention, a
`CODEOWNERS` assumption, the poetic-fiddle implementation-plan/preview
reference, or a schema `default` that is really Poetic's configured value —
rather than reading it from configuration. It does not sweep or fix any of
them; each hit that needs code or documentation work gets a linked follow-up
issue instead, so the sweep can be scoped and landed one item at a time.

Four specifics were already swept before this audit and are not repeated
here: the Enabler's assignee, the entrypoint's git identity, the
implementation-plan path, and the Co-Ordinator's repo/source table (all
`repos[]`/`sources`-driven).

## Method

Every file under `prompts/`, `lib/`, `scripts/` and `deploy/`, plus
`config.schema.json` in full, was read and grepped for repository slugs
(`Poetic-Poems/…`), the owner's username (`warwickallen`/`wallen`/
`Warwick-Allen`), hardcoded label names, branch-naming conventions,
`CODEOWNERS` assumptions, poetic-fiddle/Vercel references, the vendored
review skill's provenance, and any other literal "Poetic" brand reference.
Each hit is classified:

- **configuration** — a config surface already exists (an env var, a schema
  key, a runtime-input field); only the shipped default value or the
  surrounding prose is Poetic's own rather than generic.
- **needs a key** — no config surface exists at all; an adopter has no way
  to change this short of editing code or a prompt.
- **genuinely generic** — a false positive: a comment naming a real
  incident, PR or repo as illustrative evidence, not load-bearing; or a
  deliberate, documented design choice that is not actually Poetic-specific.
- **out of scope** — belongs to Poetic's own consumer configuration and
  deployment once D8's repository split happens, or to a separately tracked
  roadmap decision (D13's rename, D20's tooling delivery); fixing it here
  would be scope creep on this item.

## Summary

| # | What | Location(s) | Classification | Follow-up |
|---|------|--------------|-----------------|-----------|
| 1 | "Both target repos" / "either repo(sitory)" phrasing hardcodes a count of two | `prompts/coordinator.md`, `implementer.md`, `project-reviewer.md`, `reviewer.md` | configuration | #653 |
| 2 | Implementer's PR label is a literal in prose, not a work-order field | `prompts/implementer.md:515` | needs a key | #654 |
| 3 | poetic-fiddle/Vercel preview logic named by repo in two prompts | `prompts/implementer.md` (step 4a), `prompts/reviewer.md` (step 6) | needs a key | already tracked (#586) |
| 4 | Tech-debt claim branch prefix `td/` hardcoded, no config key | `lib/claim.sh`, `scripts/gather-dequeued.sh`, `gather-merge-conflicts.sh`, `gather-abandoned-drafts.sh`, `gather-review-feedback.sh`, `sweep-orphan-branches.sh` | needs a key | #655 |
| 5 | `deploy/docker` shipped defaults are Poetic's own real values | `deploy/agent-ops-dashboard.init`, `deploy/docker/compose.yaml` | configuration | #656 |
| 6 | `state_dir`/`workspace_root` directory name baked into the Docker image at build time | `deploy/docker/Dockerfile`, `crontab.tmpl`, `crontab`, `watchtower-pre-update.sh` | needs a key | #657 |
| 7 | `config.schema.json` wording documents Poetic's value as if generic (15 keys) | `config.schema.json` | configuration | already tracked (#585) |
| 8 | `agent-ops:` marker prefix and internal state filenames carry the product's own name | `lib/pipeline-marker.sh`, `reconciliation-gate.sh`, `dependabot-bump.sh`, `cycle-state.sh`, `fleet.sh`, `toggle.sh`, `compose.yaml` | out of scope (D13) | — |
| 9 | `td-tooling-drift.yml` fetches the vendored tech-debt tooling from `Poetic-Poems/poetic` by URL | `.github/workflows/td-tooling-drift.yml` | out of scope (D20) | — |
| 10 | `deploy/docker/README.md`/`.env.example` document Poetic's own live fleet (node names, hosts, token scope) | `deploy/docker/README.md`, `.env.example` | out of scope (D8) | — |
| 11 | `blocked`/`obsolete`/`complexity:*` label literals, not configurable | `lib/labels.sh:81-100` | genuinely generic (deliberate) | — |
| 12 | Illustrative sample-JSON values use real Poetic slugs instead of neutral placeholders | `prompts/enabler.md`, `enabler-adjudicate.md`, `refiner.md`, `project-reviewer.md` | genuinely generic (cosmetic) | — |
| 13 | Historical-incident comments citing real PRs/issues as rationale | scattered across `lib/*.sh`, `scripts/*.sh` | genuinely generic (false positive) | — |
| 14 | `CODEOWNERS` handling | `lib/handoff.sh`, `lib/landing.sh`, `scripts/gather-human-visibility-hygiene.sh` | genuinely generic (reacts to GitHub's own mechanism, no file parsing) | — |
| 15 | Vendored `project-review` skill has no provenance comment or drift-check at all | `.claude/skills/project-review/` | out of scope (not a Poetic-specific — a traceability gap; recommend a tech-debt item, not a sweep issue) | — |

## Detailed inventory

### 1 — "Both target repos" phrasing (configuration)

`prompts/coordinator.md:382`, `implementer.md:460`, `project-reviewer.md:101`
and `reviewer.md:145` each open a "Shared repository conventions" section
with "Both target repos follow these rules" (or, in `coordinator.md`,
"one of two GitHub repositories" at line 4, "either repository" at lines 7,
362 and 1058). The repositories these prompts actually operate over —
`repos[]` for the implementation pipeline, `project_review.repos` for the
review pipeline — are both arbitrary-length configured arrays; the count of
two is Poetic's own installation, not a constraint the code enforces
anywhere. **What removal implies:** reword each occurrence to
"every configured repository" (or equivalent), in all four files; no code
change, no new config surface — the array already carries any number of
repositories.

### 2 — Implementer's PR label has no work-order field (needs a key)

`prompts/implementer.md:515` reads "Label it `pr_label` (`autonomous-agent`)"
— a literal string with nothing behind it. Contrast
`prompts/project-reviewer.md:29,36,196`, where `pr_label` genuinely arrives
in the runtime-input JSON (`"pr_label": "project-review"`) and the prompt
just says "Label it `pr_label`." The Co-Ordinator's own work order to the
Implementer (documented earlier in `implementer.md`) carries no `pr_label`
field at all, so an adopter who wants a different PR label for the
implementation pipeline has no way to set one short of editing the prompt.
`config.schema.json`'s own `pr_label` key (line 575) is real and
config-backed; the gap is only that the Implementer's own invocation never
receives it. **What removal implies:** thread `pr_label` through the
Co-Ordinator's work order to the Implementer, the same way `repo` and
`branch` already are, and change the prompt line to reference the field
instead of the literal.

### 3 — poetic-fiddle/Vercel preview logic named by repo (already tracked)

`prompts/implementer.md`'s step 4a and `prompts/reviewer.md`'s step 6 both
assert "poetic-fiddle deploys every pull request to Vercel" by name and
instruct every run, for any repo, to invoke `preview-deploy.sh` on that
premise — there is no per-repo config gate deciding whether this applies.
This is exactly D19/#586's scope ("move the preview arrangement behind a
per-repository `preview` config block"); no new issue is filed here.

### 4 — Tech-debt claim branch prefix `td/` hardcoded (needs a key)

Unlike the general claim-branch prefix (`branch_prefix`, config-backed via
`cfg '.branch_prefix'`), the tech-debt claim prefix `td/` is a bare literal
with no config path anywhere it appears: `lib/claim.sh:361,366`,
`scripts/gather-dequeued.sh:238`, `gather-merge-conflicts.sh:249`,
`gather-abandoned-drafts.sh:227`, `gather-review-feedback.sh:242`, and
`sweep-orphan-branches.sh:130,225,373`. It bakes in the assumption that any
adopting repository follows Poetic's own `TECH-DEBT.md`-workflow branch
naming, with no way to disable or change it. **What removal implies:** a new
config key (e.g. `tech_debt_branch_prefix`, default `td/`) read by all six
sites in place of the literal.

### 5 — `deploy/docker` shipped defaults are Poetic's own values (configuration)

Every one of these is already parameterised — an env var can override it —
but the shipped default is Poetic's own real value, not a generic one:

- `deploy/agent-ops-dashboard.init:35` — `RUNAS=${RUNAS:-wallen}`, the
  owner's actual Unix username.
- `deploy/agent-ops-dashboard.init:37` —
  `APPDIR=${APPDIR:-$RUNHOME/Code/Poetic-Poems/agent-ops}`, the org slug
  baked into the default checkout path.
- `deploy/docker/compose.yaml:33` —
  `image: ${AGENT_OPS_IMAGE:-ghcr.io/poetic-poems/agent-ops:latest}`,
  Poetic's own published image.
- `deploy/docker/compose.yaml:73` — `TZ: ${TZ:-Pacific/Auckland}`, the
  owner's own timezone.
- `deploy/docker/compose.yaml:183,187` —
  `hostname`/`TS_HOSTNAME: ${NODE_NAME:-agent-ops}` — the product name as a
  hostname default; lower severity (cosmetic, not an org identity), listed
  for completeness.

**What removal implies:** no new config surface — these are already
overridable — but the shipped defaults for `RUNAS`, `APPDIR` and
`AGENT_OPS_IMAGE` should become genuinely generic (or documented as
required-to-set) rather than resolving quietly to Poetic's own arrangement.

### 6 — Docker image bakes the state/workspace directory name at build time (needs a key)

`config.schema.json`'s `state_dir`/`workspace_root` keys are configurable at
the application layer, but the Docker image itself pre-creates fixed
directories at build time with no build ARG or runtime remapping:
`deploy/docker/Dockerfile:208-210` (`/home/agent/.local/state/poetic-agents/
cycles`, `/reviews`, `/home/agent/.cache/poetic-agents/workspaces`),
`deploy/docker/crontab.tmpl:34` and the checked-in `deploy/docker/crontab:34`
(`LOGDIR=/home/agent/.local/state/poetic-agents`), and
`deploy/docker/watchtower-pre-update.sh:117` (same path as a fallback
default when `config.json` doesn't set `state_dir`). An installation that
sets `state_dir`/`workspace_root` to anything else inherits directories
pre-created (with matching ownership/permissions) for the *default* path
only. **What removal implies:** either a build ARG threading the directory
name into the image, or resolving these paths from `config.json` at
container start rather than at build time.

### 7 — `config.schema.json` wording (already tracked)

No key's actual JSON Schema `default` is Poetic-specific — all 63
`"default"` occurrences are generic values or empty/must-configure. The
problem is confined to `description`/`x-docs.readme`/`x-docs.spec`/
`x-docs.value` prose, on 15 keys: `repos`,
`repos[].implementation_plan_path`, `state_dir`, `workspace_root`,
`state_repo`, `enabler_assignee`, `crash_loop_repo`, `pr_label`,
`branch_prefix`, `project_review.defaults.pr_label`,
`project_review.defaults.branch_prefix`, `human_nudge_idle_hours`,
`schedule.excluded_minutes`, `schedule.excluded_minutes_reason`,
`project_review.repos`. This is exactly #585's scope
("sweep the schema's own defaults — Poetic's values are documented as the
product's"); no new issue is filed here. The audit narrows #585's actual
size: 0 keys need a new default value, ~15 need reworded/labelled prose.

### 8 — `agent-ops:` brand string in generated markers (out of scope, D13)

`lib/pipeline-marker.sh:53,99` hardcode the literal prefixes
`<!-- agent-ops:pipeline-comment` and `<!-- agent-ops:reconciles`, embedded
into every PR/issue comment the pipeline posts in every target repo; the
same string resurfaces as the fallback default in
`lib/reconciliation-gate.sh:250-251` and as a literal in
`lib/dependabot-bump.sh:30`. Related internal (never posted externally)
state filenames carry the same brand: `lib/cycle-state.sh:66`
(`.git/agent-ops-pr-url`), `lib/fleet.sh:10` (`.agent-ops-peers`),
`lib/toggle.sh:532` (`agent-ops-fleet-flag-memo.*`); `compose.yaml:21`'s
Compose project name (`agent-ops`) is the same pattern. None of these name
Poetic the *organisation* — they name this product, "agent-ops," by its own
current name. D13 already tracks the product rename (to Pullwright) as a
Phase-1-gated decision, and D8 tracks the eventual repository split; renaming
these markers is that rename landing, not a per-installation configuration
gap two different orgs running today's agent-ops would need. Left for the
rename item rather than filed here.

### 9 — Tech-debt tooling drift check pinned to `Poetic-Poems/poetic` (out of scope, D20)

`.github/workflows/td-tooling-drift.yml:34` fetches
`scripts/td-tooling-manifest` and every listed file directly from
`Poetic-Poems/poetic`'s `main` by raw URL, unconditionally, with matching
literal error strings at lines 36-71 naming that repository. The five
vendored `scripts/*.pl` tech-debt tools each carry a "canonical copy lives in
Poetic-Poems/poetic" provenance comment (confirmed in `next-tech-debt-id.pl`,
`check-tech-debt-open-rewrites.pl`, `reserve-tech-debt-id.pl`,
`get-tech-debt-record.pl`, `td-check.pl`) pointing at the same drift check.
D20 already records this whole vendoring-and-drift-check mechanism as the
defect, to be replaced by tooling the product *delivers* rather than a
repository vendors and drift-checks against a hardcoded source; parameterising
the source org today would be building toward a mechanism D20 already plans
to retire. Left for D20.

### 10 — `deploy/docker/README.md`/`.env.example` document Poetic's own fleet (out of scope, D8)

`deploy/docker/README.md` is written as the literal runbook for adding a
node to Poetic's own fleet: a worked table of its actual current node names,
hosts and cron-minute assignments (lines 461-464), bootstrap commands
hardcoded to `Poetic-Poems/agent-ops` raw URLs (lines 53, 57, 246, 282), and
GitHub-token scoping advice naming Poetic's actual four repositories (lines
19-22). `.env.example:34,75,115` carry the same pattern in comments. D7's
decision record states plainly: "agent-ops shrinks to Poetic's consumer
configuration and deployment — the reference installation and customer
zero" — this document *is* that consumer deployment documentation, and is
expected to describe Poetic's real arrangement even after Phase 1, not a
generic product runbook. Left as Poetic's own deployment record; the
generic parts of the same document (how to build the image, how compose is
laid out) contain no hardcoding of their own.

### 11 — `blocked`/`obsolete`/`complexity:*` labels (genuinely generic)

`lib/labels.sh:81-100` hardcodes these label names with no config key behind
them, unlike `pr_label`, `enabler_escalation_label`, `needs_refinement_label`,
`refined_label` and `unvoid_label` one line above/below in the same file.
The file's own header comment (lines 41-50) documents this as deliberate:
`blocked` and `obsolete` are "the exception that proves the interface... not
configurable" — internal pipeline-state labels the mechanism itself depends
on, not a naming choice Poetic happened to make. `scripts/doctor.sh:452,
460-461,470-471` actively rejects `obsolete` as a value for any of the
configurable label keys, reinforcing that this is a reserved literal by
design. No work implied.

### 12 — Illustrative sample values use real Poetic slugs (genuinely generic)

`prompts/enabler.md`, `enabler-adjudicate.md`, `refiner.md` and
`project-reviewer.md` each show sample runtime-input/output JSON using real
values (`"repo": "Poetic-Poems/poetic-fiddle"`, `"by": "warwick"`, a real
issue-comment URL) rather than the neutral placeholders `coordinator.md`
uses elsewhere (`org/repo-a`). None of this is load-bearing — the real
`repo` field is always populated by the Script at runtime — so it is
cosmetic only. No work implied; noted for completeness since it was asked
for by name (repository slugs, owner's username).

### 13 — Historical-incident comments (genuinely generic / false positives)

A large share of every "Poetic"/"poetic-fiddle"/`warwickallen` grep hit
across `lib/*.sh` and `scripts/*.sh` is a comment citing a real, specific
incident as the motivating evidence for a generic mechanism — e.g.
`lib/closing-keyword-gate.sh:9-10,31` (poetic-fiddle #190), `lib/handoff.sh`
(poetic-fiddle #200, #170, #216, agent-ops #350/#353/#355),
`lib/review-gate.sh` (poetic-fiddle #216, #190),
`lib/issue-priority.sh:12` (a live-verified GraphQL field id),
`lib/merge-queue.sh:113` (a live verification against agent-ops' own `main`),
`scripts/gather-issues.sh:48`, `scripts/sweep-human-visibility.sh:21`,
`scripts/gather-source-state.sh:159`, `scripts/autonomy-stage-report.sh:
278-279`, `scripts/gather-hand-flagged-refinements.sh:14,21`,
`scripts/gather-unvoid-requests.sh:14`, `scripts/gather-source-state.sh:18`.
In every case the code beneath the comment is generic (parameters, `$slug`,
runtime-resolved ids) — the comment is documentation of why the mechanism
exists, not a hardcoded assumption. No work implied; these are the "a
comment naming a real incident is not a Poetic-specific" case the issue's
own brief calls out.

### 14 — `CODEOWNERS` handling (genuinely generic)

Every `CODEOWNERS` reference in `lib/handoff.sh`, `lib/landing.sh` and
`scripts/gather-human-visibility-hygiene.sh` treats it as GitHub's own
platform mechanism — reacting to `requested_reviewers`/review-decision state
CODEOWNERS produces via the API, or naming the literal filename `CODEOWNERS`
as one of nine protected paths in `landing.sh:192`. Nothing in the codebase
parses a CODEOWNERS file itself or assumes its contents. No work implied.

### 15 — Vendored review skill has no provenance tracking (gap, not a specific)

`.claude/skills/project-review/` carries no comment or drift-check pointing
at a canonical source, unlike the tech-debt tooling (item 9), which names
`Poetic-Poems/poetic` explicitly and is drift-checked against it weekly.
This is not itself a Poetic-specific to remove — there is no hardcoded
Poetic reference here to sweep — it is the opposite gap: the skill's actual
provenance is untracked, so a future upstream fix has no mechanism to reach
this copy. Recommend a `tech-debt/<id>.md` item (scoped and filed the
ordinary way, not as a Phase-1 sweep follow-up) rather than folding it into
this audit's issue set.

## Follow-up issues filed

| Issue | Title | Classification |
|-------|-------|-----------------|
| #653 | Reword the four prompts' "both target repos" phrasing to the configured, arbitrary-length repo set | configuration |
| #654 | Thread `pr_label` through the Implementer's work order instead of a literal in the prompt | needs a key |
| #655 | Add a config key for the tech-debt claim branch prefix (`td/`) | needs a key |
| #656 | Genericise `deploy/docker`'s shipped defaults (`RUNAS`, `APPDIR`, `AGENT_OPS_IMAGE`) | configuration |
| #657 | Make the state/workspace directory name configurable at Docker image build time | needs a key |

Each carries `Blocked-by: #584` initially and is independently workable once
this audit lands; none should merge before a human triages it against this
inventory.
