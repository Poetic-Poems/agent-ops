# Tech debt

Deferred work and known gaps in agent-ops. Record an entry here whenever you
defer something, rather than leaving it only in a commit message or in chat.
Keep entries short and dated. Live items live under the "Current Items" heading
as `### <id> <title>` sections. Once an issue has been resolved, remove its
`### <id> <title>` section from Current Items below — but never remove its row
from the Ledger table at the bottom of this file; see "Ledger" below.

Format:
```
### <id> <short title>

A description of what, why it matters, where, and a suggested fix.
```
Where `<id>` is a literal "TD" then the date followed by a zero-padded
sequential number (starting at 1 for the first entry of a day). I.e.:
**TD*YYMMDDNN***. `NN` is one more than the highest `NN` already used for that
date **in the Ledger table**, not just what's currently visible above it — a
resolved entry's body is removed, but its Ledger row stays forever, so the
Ledger (not memory or scrollback) is the source of truth for the next free ID.
Compute it with `scripts/next-tech-debt-id.pl --ref origin/main` (after a
`git fetch origin`) rather than counting by hand — the `--ref` makes the
allocation reflect the shared state instead of a possibly stale checkout. It
still cannot see IDs allocated on unmerged branches, so also skim open pull
requests and `td/*` branches when filing.

IDs are only unique within this repository: sister repositories allocate from
the same date-based sequence, so the bare ID may exist in several of them.
When referring to an item anywhere outside this repository (a sister repo's
docs, a cross-repo PR, chat), qualify it with the repo name — e.g.
`agent-ops TD26072001`.

## Claiming an item

This repository is worked by concurrent agents: autonomous and interactive
sessions may pick up items at the same time, so a claim must be checked and
taken against the shared state, never against what a local checkout happens
to say. Before starting work on an open item:

1. `git fetch origin`, then confirm the item's Ledger row is `open` (not
   `in-progress`) **as of `origin/main`** — e.g. via
   `perl scripts/get-tech-debt-record.pl --ref origin/main <id>`.
2. Confirm nobody holds a claim: `git ls-remote origin "refs/heads/td/<id>"`
   must print nothing, and skim open pull requests for the ID (which also
   catches claims made on unconventionally named branches).
3. Create the claim branch, named exactly **`td/<id>`**, from `origin/main`;
   flip the item's Ledger row Status to `in-progress`; commit and push. The
   branch name is the claim lock: git refuses the push if the branch already
   exists, so a rejected push means another agent won the race — abandon
   quietly; never force-push over it.
4. Open a **draft** pull request right away — before the fix is finished — so
   `gh pr list` shows the claim too. The Ledger status flip can be its first
   commit.
5. Do the work, pushing further commits to the same branch/PR.
6. Once verified, flip the Ledger row to `resolved` (fill in `Resolved` and
   `Ref`), remove the entry's `### <id>` section from Current Items, and mark
   the PR ready for review.

If a claim is abandoned, close the draft PR and delete the `td/<id>` branch —
that releases the lock. The in-progress flip only ever lived on the branch,
so `main`'s Ledger still says `open` and nothing needs reverting.

## Current Items

The open and in-progress items, each as a `### <id> <title>` section. This
heading is permanent: when there are no current items it stays here (empty), so
it is always obvious where a new item's body belongs.

<!-- Add new items directly below, as `### <id> <title>` sections. -->

### TD26072002 The node image is amd64-only

`deploy/docker/Dockerfile` fetches a pinned `supercronic-linux-amd64` release
binary and verifies its SHA-1, so the image builds and runs on x86-64 only.
Every node today is x86-64 (the laptop under WSL2 and the intended cloud VMs),
so nothing is blocked — but an arm64 VM (often the cheaper instance class) or an
Apple-silicon machine cannot build or run it, and the failure would be a
mid-build checksum mismatch rather than a clear message.

Fix: select the release asset and its checksum from `TARGETARCH` in a
multi-platform build (`docker buildx build --platform linux/amd64,linux/arm64`),
and publish a manifest list from CI. Everything else in the image is already
architecture-independent — Ubuntu, NodeSource and the GitHub CLI apt repository
all publish arm64.

### TD26072003 The local dashboard profile needs Linux host networking

The `local` profile in `deploy/docker/compose.yaml` gives `dashboard-local`
`network_mode: host`, because `scripts/serve-dashboard.sh` binds `127.0.0.1`
and a published port would therefore reach nothing. Host networking is a Linux
container-runtime feature: on Docker Desktop for macOS or Windows the container
would share the Desktop VM's loopback, not the user's, and the page would be
unreachable. Nothing is blocked today — every node is Linux (cloud VMs and WSL2)
and the normal deployment is the `tailnet` profile — but the fallback profile is
less portable than it looks, and the failure mode is a page that simply does not
answer.

It also means the port is the host's: on a machine already serving something on
8787 (the laptop, via the legacy SysV dashboard) the container dies with
`Address already in use` until `DASHBOARD_PORT` is set.

Fix: make the bind address a setting of the server (default `127.0.0.1`,
unchanged), have the `local` profile set it to `0.0.0.0` inside the container
and publish `127.0.0.1:${DASHBOARD_PORT}:8787`. The exposure is then identical —
the host's loopback and nothing else — while working on any runtime, and the
port becomes the container's again. `DASHBOARD-SPEC.md`'s loopback requirement
would need rewording to say what it protects (the host's loopback) rather than
naming the literal bind.

### TD26072004 An active node's state_dir grows without bound

`cycles_retained` (requirement 2.5) bounds the *replicated* copy of the state,
because that repository is force-pushed after every cycle and its size is a
cost paid on every clone. The node's own `state_dir` is deliberately not pruned
by it — deleting a machine's local history as a side effect of replicating it
would be a surprising thing for a sync to do — so an active node accumulates one
cycle directory an hour forever. Today that is 200 directories and 8 MB after a
week; a year of running would be roughly 9,000 and a quarter of a gigabyte.

Nothing is at risk yet, and a standby node is already bounded (its restore is a
mirror, so it holds exactly what the repository holds). The dashboard reads only
the newest 40 cycles in detail, so the tail is not even being looked at.

Fix: a retention pass over the local `state_dir` — its own key rather than
`cycles_retained`, since the two answer different questions ("how much history
does this machine keep?" against "how much do we ship to every node?") — run
from the same cleanup that pushes, and generous enough that the local copy stays
the longer record of the two.

### TD26072101 A blocked item's new evidence can never unblock it

The Co-Ordinator reconstructs blocked and void state from cycle-history
events keyed by item id, honouring a blocked marker until a later
`unblocked` event. But nothing makes it re-read the underlying item when
that item changes: source-state carries each open issue's `updated_at`
(so the change busts the no-op fingerprint and a cycle *runs*), yet the
Co-Ordinator repeats the historical verdict without revisiting the thread
the marker was minted from.

Observed 2026-07-21: poetic-fiddle issue #52 (a live production 500) was
reopened with a complete in-thread diagnosis — the very evidence its
"blocked awaiting Sentry/Vercel logs" marker said was missing. The 11:00Z
Co-Ordinator reported "one open issue (#52) but it's blocked" and selected
other work; `unblocked` stayed empty. The workaround (which is also the
spec's regression path) was to close #52 and re-file the work under a
fresh id (poetic-fiddle #86), which no marker covers.

Fix: in `prompts/coordinator.md`, require that when a blocked item's
`updated_at` is newer than the event that blocked it, the Co-Ordinator
re-reads the item before honouring the marker (and emits `unblocked` when
the recorded blocker no longer holds). Failing that, document
supersede-with-a-fresh-id as the canonical unblock path, so the next
person doesn't burn cycles posting evidence to a thread nothing reads.

### TD26072102 No sanctioned way to watch a node's cycle events from outside

Observing a running node — cycle starts, selections, PRs raised, stand-downs
— currently means knowing to run
`docker compose exec -T scheduler tail -f /home/agent/.local/state/poetic-agents/log.jsonl`
(or `cron.log`) from the node's stack directory, an incantation that appears
only in worked examples in the cutover checklist. Interactive AI agents hit
permission friction on it: each user must allow-list the docker-exec command
per machine (done on Ockham 2026-07-21, in that workspace's Claude settings
— which travels to no other machine, node, or teammate), and a permission
classifier may still deny ad-hoc variants, as one did mid-rehearsal. Humans
on a fresh host have nothing discoverable at all. The dashboard renders
cycle state but is not a substitute for following events as they happen.

Fix: a small read-only wrapper, e.g. `scripts/watch-node.sh [cron|events]
[-f]`, that resolves the stack directory and runs the exec/tail itself;
document it in the README and cutover checklist. Agents and humans then
share one discoverable entry point, and an allow-list rule covers the one
script rather than a docker incantation. Alternatively (or additionally),
extend the dashboard to stream recent events, which would remove the need
for a CLI path for humans.

### TD26072201 The publisher's per-cycle detail loop still forks ~300 jq serially

The transcript cost scan and the array accumulations are batched now, but
`cycle_json`/`stage_json` in `scripts/publish-dashboard.sh` still fork
roughly a dozen `jq` per shown cycle — about 5 s for the 40-cycle detail
window against real transcripts under WSL2, which is the whole 5-second
heartbeat budget on its own. The cost is bounded (`MAX_CYCLES`, not history
length), and the launcher's lock plus its end-of-window margin absorb the
occasional overshoot, so this is a budget squeeze rather than a failure.
Fix: assemble the detail window in one `jq` program over the 40 cycles'
envelope and event files (they are already individual files on disk),
which should take a `--no-github` publish to around a second.

## Ledger

Every tech-debt ID ever allocated — open, in-progress, resolved, or not-debt —
is listed here forever, in ID order. This is what makes numbering unambiguous:
the next free ID for a given date is one more than the highest `NN` seen below
for that date, regardless of whether the corresponding entry still has a body
above.

| ID | Title | Status | Resolved | Ref |
|----|-------|--------|----------|-----|
| TD26071401 | Usage-limit detector misses weekly & spend-limit phrasing; no graceful stand-down | resolved | 2026-07-14 | #11 |
| TD26072001 | shellcheck not clean at info level on two scripts | resolved | 2026-07-20 | #38 |
| TD26072002 | The node image is amd64-only | open | | |
| TD26072003 | The local dashboard profile needs Linux host networking | open | | |
| TD26072004 | An active node's state_dir grows without bound | open | | |
| TD26072101 | A blocked item's new evidence can never unblock it | open | | |
| TD26072102 | No sanctioned way to watch a node's cycle events from outside | open | | |
| TD26072201 | The publisher's per-cycle detail loop still forks ~300 jq serially | open | | |
