# Pullwright day-one autonomy — provisioning checklist

**Status: preparation.** The Pullwright product repository does not exist yet
— `docs/ROADMAP.md`'s Phase 1 checklist still carries "Create the product
repository in the Pullwright organisation" unchecked. This checklist is
written ahead of that step so the repository starts at the level below
records rather than at the product default (`human`) and climbing the D18
ladder a second time. Written for issue #581.

Design material this checklist draws on rather than re-derives:
`docs/reviews/2026-08-14-autonomy-investigation.md` §5.2 ("The Approver
gate") for the cost tiers, and §5.3 ("Identity") for the "Pullwright
Approver" App identity, its permission set and the ruleset it needs.
`docs/reviews/2026-08-23-d18-stage-3-promotion.md` is the closest precedent —
the same kind of exercise (a `config.json` diff, its preconditions, its
validation) for repositories the ladder already governs — and this document
follows its shape.

**Out of scope, on purpose.** `docs/ROADMAP.md`'s Phase 2 "Zero-touch fleet"
section (~line 626, the bullet beginning "for a long-running node") is still
deciding *how* the fleet authenticates to the forge at scale — one App per
installation vs. one App per node, priced under both public- and
private-organisation billing shapes. That decision is product-wide and still
open; this checklist does not re-litigate it. It assumes today's decided
identity shape (§5.3: one "Pullwright Approver" App per installation) and
describes extending that App's existing installation to cover the new
repository. If the wider decision changes the identity shape, step 1b below
is what changes — the parity rule (below) does not.

## The parity rule

`docs/ROADMAP.md`'s Principles now state it directly (added alongside this
checklist): **no repository the product is developed in sits below the
`merge_autonomy` level agent-ops has reached.** Pullwright's product
repository is exactly such a repository once Phase 1's "move the suite
across" step lands the pipeline's own code there — the same status agent-ops
holds today, the reference installation and customer zero (D8). Provisioning
it at the product default and climbing from `human` again would be a
regression in the one place it matters most, and the customer-zero rule (that
Poetic's own installation is never special) cuts the same way: a product that
cannot be developed at the autonomy level it ships is its own counter-evidence.

## Checklist

Each item states who performs it. **Owner act** — only a repository or
organisation admin can do it, at GitHub's own settings surfaces. **System
configuration** — a `config.json` edit, checked the same way any other
configuration change is.

### 1. Forge configuration (owner acts)

1a. **Default-branch ruleset**, matching agent-ops's own (§5.3, D18 Stage 3,
    agent-ops#575):
    - `required_approving_review_count`: `1`
    - `require_code_owner_review`: `false` — an App cannot satisfy a
      code-owner rule, and leaving it on would re-summon the human review the
      level exists to retire
    - `dismiss_stale_reviews_on_push`: `true` — an Approver review must not
      outlive the commit it reviewed
    - `bypass_actors`: none, for any actor, including the Approver App itself
      — it lands through the front door or not at all
    - A merge queue on the default branch (`ALLGREEN` / `SQUASH`), **or**, if
      the repository has none, both `allow_auto_merge` and
      `allow_squash_merge` enabled — `landing_arm`'s no-queue fallback
      (`gh pr merge --auto --squash`) is refused outright otherwise

1b. **Extend the existing "Pullwright Approver" App installation** to cover
    the new repository. This is not a new App: `approver_app_id` is one
    fleet-wide scalar by design (config.schema.json), and the Approver's
    per-repository reach comes from the installation's own repository
    selection, not from configuration. If the installation is scoped
    `selected`, add the new repository to that list (or confirm it already
    reads `all`).

1c. **Confirm the installation's live granted permissions remain exactly**
    `contents: write`, `metadata: read`, `pull_requests: write` — no more, no
    less (`scripts/doctor.sh`, D18 Stage 3, agent-ops#575). This is an
    installation-wide grant already set for agent-ops; re-verify it after 1b,
    since GitHub's own consent screen can re-scope an installation at any
    time outside `config.json`.

### 2. System configuration

2a. **Add the `repos[]` entry**, mirroring agent-ops's *own current* entry in
    `config.json` at the moment the repository is provisioned — read
    agent-ops's live entry fresh rather than copying the snapshot below,
    since the ladder is expected to keep climbing (§6 below) between now and
    when Phase 1's "create the product repository" step actually runs:

    ```json
    {
      "slug": "Pullwright/<product-repo>",
      "merge_autonomy": "agent-merges-routine",
      "merge_autonomy_routine_sources": ["register-hygiene", "tech-debt", "issues"],
      "merge_budget_per_day": 24,
      "sources": ["security", "issues:urgent", "review-feedback", "merge-conflicts",
        "dequeued", "human-visibility", "abandoned-drafts", "failed-runs",
        "issues:high", "tech-debt", "issues:medium", "issues:low", "code-quality",
        "register-hygiene"]
    }
    ```

    (`<product-repo>`'s exact name is set by the "create the product
    repository" step itself; the values above are agent-ops's own as at
    2026-08-27 — see §6.) Fields to leave alone rather than set:
    - **`merge_autonomy_protected_paths`** — leave unset. The schema default
      is agent-ops's own nine paths (`.github/*`, `deploy/*`, `prompts/*`,
      `lib/*`, `config.schema.json`, `config.json`, `agent-cycle.sh`,
      `review-cycle.sh`, `CODEOWNERS`), and because the product repository
      *is* this same pipeline's code once Phase 1's "move the suite across"
      step lands, those nine paths name real gate-bearing files there too —
      unlike poetic and poetic-fiddle (2026-08-23-d18-stage-3-promotion.md
      §1), which needed their own list because agent-ops's paths name
      nothing in their trees.
    - **`merge_autonomy_routine_complexity`** — leave unset unless
      agent-ops's own entry carries it (it does not, as at 2026-08-27): the
      schema default `["low", "medium"]` is what agent-ops itself runs at
      today.
    - **`approver_app_id`, `approver_model_default`/`_complex`/`_critical`,
      `escalation_autonomy`, `enabler_model`/`_critical`** — already set
      fleet-wide (agent-ops#936: `escalation_autonomy` ships at
      `decide-tactical`, the rung agent-ops itself runs at, as at 2026-08-29);
      nothing repository-specific to add.
    - `sources` must actually gather every source
      `merge_autonomy_routine_sources` names (`scripts/doctor.sh` warns
      otherwise) — the list above mirrors agent-ops's own for that reason.

## Evidence bar: why day-1, not a climb from `human`

D18's ladder (`docs/reviews/2026-08-14-autonomy-investigation.md` §6) gates
each *promotion* behind mined evidence — a Stage 0 baseline, ≥15
Approver-approved pull requests before `agent-approves` exits, ≥15 autonomous
landings or 14 days before `agent-merges-routine` exits. That evidence is
about the **pipeline's own mechanism** — the classifier, the Approver's
adversarial review, the budget governor, the kill switch — not about any one
repository's content. It has already been mined once, on agent-ops, at the
level agent-ops has reached (Stage 2 was entered 2026-08-18; see
`docs/reviews/2026-08-23-d18-stage-3-promotion.md` §2.3 for the accrued
counts). Requiring Pullwright's product repository to mine that same evidence
a second time, from `human`, would be measuring the identical mechanism
twice — at the cost of gating the pipeline's own development behind a slower
rung than the tool it produces has already cleared, which is exactly the
customer-zero rule's own bug case (`docs/ROADMAP.md` Principles #4).

**What does *not* carry over, and must be freshly confirmed per repository:**
the forge configuration — checklist §1 above. A ruleset, an App installation
and a merge queue are per-repository facts, not evidence the pipeline's
behaviour transfers. `scripts/doctor.sh`'s consolidated autonomy-readiness
verdict (D18 Stage 3, agent-ops#575) is what checks this, per repository, and
Pullwright's entitlement to start at agent-ops's level is real only once that
verdict reads `ok` for the new repository — never asserted from the parity
rule alone. Until the repository exists and the App installation covers it,
that verdict cannot run at all (§4 below).

**If agent-ops's own level is ever lower than assumed** — the fleet-wide kill
switch is set, a budget anomaly has frozen agent-ops to `agent-approves`, or
a human has manually downgraded it — Pullwright inherits the level agent-ops
is *actually at* when provisioned, not a historical high-water mark. §2a's
instruction to read agent-ops's live entry at provisioning time, rather than
copy this document's dated snapshot, is what keeps that true.

## 3. Order

1. Confirm §1a–1c (owner acts) against the new repository once it exists.
2. Add the §2a `repos[]` entry.
3. Run `scripts/doctor.sh --config <path>` against the edited configuration
   (§4) and resolve every `fail`; a `skip` on the readiness verdict is
   expected from a workstation (§4) and is not a blocker to opening the
   configuration pull request, but is a blocker to merging it — re-run on a
   node with the Approver's runtime credential before merging.
4. Open the configuration pull request; the owner merges it, same as any
   other `merge_autonomy` change (`docs/ROADMAP.md`'s "each promotion is a
   one-line IaC config PR the owner merges").

**Rollback** is the same one-line reversal any `repos[]` `merge_autonomy`
override uses: remove the override (or set it to `human`) and the repository
falls back to the fleet-wide default. The fleet-wide kill switch
(`agent-cycle.sh --kill-merge-autonomy`) already covers Pullwright the moment
its entry exists, with no repository-specific action needed.

## 4. Validation

The §2a entry was appended to a copy of `config.json` (agent-ops's own
`merge_autonomy`, `merge_autonomy_routine_sources` and `merge_budget_per_day`
values, read 2026-08-27) and checked without being applied to the live file:

- `jq -e .` — parses.
- `scripts/doctor.sh --config <copy> --offline` — **exit 0, no failures, no
  new warnings.** Every line the new entry adds reads `ok`:
  `Pullwright/pullwright's merge_autonomy override is "agent-merges-routine"`,
  `Pullwright/pullwright's merge_budget_per_day override is 24`, and
  `Pullwright/pullwright's merge_autonomy_routine_sources are all sources it
  actually gathers`. A diff against the same check run for the unmodified
  `config.json` shows only these three additive lines — the new entry
  introduces no new warning.
- The **consolidated autonomy-readiness verdict** (checklist §1, D18 Stage 3)
  could not be exercised here: it reads GitHub live (the ruleset, the App
  installation's granted permissions, its repository selection), and
  `Pullwright/<product-repo>` does not exist yet to read. This is the one
  check this document cannot stand in for, exactly as
  `docs/reviews/2026-08-23-d18-stage-3-promotion.md` §6 notes for its own
  promotion diff — run `scripts/doctor.sh` (without `--offline`) on a fleet
  node, against the real repository, once §1 is complete, and confirm it
  reads `ok` before merging the §2a configuration pull request.
