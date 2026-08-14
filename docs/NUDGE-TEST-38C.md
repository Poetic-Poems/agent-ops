# Disposable test vehicle — requirement 38c nudge spot-check

This file exists only to give a pull request a diff. It is **not** documentation
of anything, and nothing in the repository refers to it.

## Why it is here

agent-ops#261 asks for one live observation that requirement 38a's re-request is
additive (it does not dismiss a standing approval) and that requirement 38c's
idle nudge still fires afterwards. The observation needs a pull request that is
approved, green, mergeable and *left alone for more than
`human_nudge_idle_hours`* — a state real work never stays in, because an
approved pull request in this fleet is merged within the minute.

Holding a real pull request open for a day to get that state costs a day of the
work it carries, so this one carries nothing.

## Why its base is not `main`

`scripts/sweep-human-visibility.sh`'s requirement 38c gate requires **every**
entry in the pull request's status-check rollup to be `SUCCESS` or `NEUTRAL`.
Every pull request against `main` in this repository carries a `SKIPPED`
`Publish to GHCR` (build-image.yml's `publish` job is gated off on pull
requests), which the gate rejects — so the nudge cannot fire on a pull request
against `main` at all.

Basing this on `nudge-test/base` keeps the three `branches: [main]` workflows
(build-image.yml, codeql.yml, shellcheck.yml) from triggering, so nothing
contributes a `SKIPPED` entry and the rollup is all-`SUCCESS`.

That `SKIPPED` rejection is a real defect in its own right, filed separately;
this vehicle deliberately routes around it so that #261's own question can be
answered against the current code.

## Disposal

Close the pull request and delete both `nudge-test/head` and `nudge-test/base`
once #261 records its observation. Neither branch is swept automatically —
`scripts/sweep-orphan-branches.sh` only touches `td/*` and `agent/*`.
