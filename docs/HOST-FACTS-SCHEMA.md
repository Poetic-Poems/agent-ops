# Host-facts schema — as-built specification

Sibling to `docs/FLOW-SCHEMA.md` and `docs/METERING-SCHEMA.md`, under the
same stability policy. Where those two are the contract for what a stage
*spent* and what happened to a work item, this one is the contract for the
one record `scripts/collect-host-facts.sh` produces: the facts no container
running the pipeline can see for itself, because the runtime deliberately
holds neither the Docker socket nor the Kubernetes API (a design property
since the agent-ops#603 postmortem, restated at `docs/ROADMAP.md`'s Phase 2
"host-side vantage" bullet). Like its companions this document is as-built —
it describes the record that exists today, not a plan for one that will
exist later. Where it says "requirement N", it means requirement N of
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`.

## What this covers

One JSON object per node, `host-facts/<node>.json`, written by
`scripts/collect-host-facts.sh` into `state_dir` and carried out to the rest
of the fleet by the ordinary state-sync push — no dedicated sync code, no
`EXCLUDES` entry, because a host fact is exactly the kind of thing the
node's own state tree already exists to publish. Two drivers produce the
same envelope and the same shared fields; each also carries its own
vantage-specific section, present only under its own driver:

- **`compose`** — the host vantage: one entry per container on the node's
  Docker Engine, read over the Docker socket **read-only** (the collector's
  own container holds it; the pipeline's runtime container still holds
  none, so the post-#603 property is unchanged).
- **`kubernetes`** — the cluster vantage: pods, rollouts, CronJobs, node
  pressure conditions and PVC usage, read over the Kubernetes API with a
  read-only Role.

Both drivers also run the **viewer-vantage probe** (`viewer_probe` below),
fetch each node's own host/disk/memory/load facts, and read the updater's
own ledger — the three sections every record carries regardless of driver.

**What this record is not for.** It publishes facts; it never acts on one.
Applying a `memory.high` after a recreate, or correcting a host's MTU, is a
configuration change, and D16 (`docs/ROADMAP.md`) says configuration reaches
a node only as a versioned change — the compose file, or the Kubernetes
manifest — never a write this collector, or anything reading its output,
performs. A consumer proposing an action on the strength of this record is
proposing a separate, versioned change; this document, and the script that
produces it, only ever read.

## The envelope

Every record, whichever driver produced it, carries these five fields at
its top level:

| Field | Type | Meaning |
| --- | --- | --- |
| `node` | string | The node's own name — `NODE_NAME`, or a bare `hostname` fallback, the same identity `state-sync.sh` publishes under. |
| `driver` | string | `"compose"` or `"kubernetes"` — which vantage produced this record. |
| `generated_at` | string | UTC `YYYY-MM-DDTHH:MM:SSZ`, this collection pass's own timestamp. |
| `host` | object | Facts about the node's own host — disk, memory, load, network. Present on both drivers; a Kubernetes collector populates whatever its own pod's vantage can read and fills the rest `null` (see "Degradation" below) rather than omitting the section. |
| `updater` | object \| null | The watchtower ledger tail and last session result — `null` where no updater runs on this node (a cluster with no watchtower-equivalent). |

Six further fields are driver-specific and present only under their own
driver — `containers` (`compose`), and `pods`/`rollouts`/`cronjobs`/
`node_conditions`/`pvcs` (`kubernetes`) — and one, `viewer_probe`, is present
on both.

## `host`

| Field | Type | Meaning |
| --- | --- | --- |
| `host.mem_available_bytes` | integer \| null | `MemAvailable` from `/proc/meminfo`, `null` when unreadable. |
| `host.load` | object \| null | `{"1m", "5m", "15m"}`, each a number, read from `/proc/loadavg`; `null` whole when unreadable. |
| `host.disk.state_dir` | object | `{"path", "free_bytes", "total_bytes"}` for the filesystem `state_dir` sits on. |
| `host.disk.workspace_root` | object | Same shape, for `workspace_root`. |
| `host.network.egress_mtu` | integer \| null | The MTU of the interface the host's default route uses — the number `DOCKER_MTU` is supposed to track (`deploy/docker/README.md`). `null` when no default route is readable. |
| `host.network.docker_mtu_configured` | integer | The `DOCKER_MTU` this node's own `.env` sets, `1500` when unset — the same default `deploy/docker/compose.yaml`'s `driver_opts` falls back to. |
| `host.network.mtu_match` | boolean \| null | `egress_mtu == docker_mtu_configured`; `null` when `egress_mtu` is `null` (nothing to compare). |

A `host.disk.*` entry's own `free_bytes`/`total_bytes` are `null`, never a
guessed number, when the collector's own container cannot see that path at
all (a Kubernetes pod with no `hostPath` mount for it, for instance) — see
"Degradation" below.

## `containers` (`compose` only)

An array, one entry per container the Docker Engine reports, in the order
the engine itself returns them:

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | The container's own name (Docker strips the leading `/`). |
| `service` | string \| null | `com.docker.compose.service` label, `null` when the container carries none (not part of this stack). |
| `state` | string | `Docker inspect`'s own `State.Status` (`running`, `exited`, `restarting`, ...). |
| `restart_count` | integer | `State.RestartCount`. |
| `started_at` | string \| null | `State.StartedAt`, `null` for the zero-value Docker reports on a container that has never started. |
| `image.digest` | string \| null | The running image's own `RepoDigests[0]` (the `sha256:...` half), `null` when the image carries no repo digest (built locally, never pulled). |
| `image.registry_digest` | string \| null | The registry's current `:latest` manifest digest for **this container's own** repository, `null` when the registry could not be read *or* when this container does not run the one repository the collector was configured to compare against (`HOST_FACTS_IMAGE_REPO`) — the collector fetches one repository's digest, so a container running another image (watchtower, tailscale, anything else on the host) reads `null` here rather than a foreign repository's digest. The same "unverified, never guessed" contract `lib/image-drift.sh` already holds for the commit-level comparison this one complements. |
| `image.digest_match` | boolean \| null | `digest == registry_digest`; `null` whenever either side is `null`. |
| `memory.current_bytes` | integer \| null | `memory.current`, read from the container's own cgroup. |
| `memory.high_bytes` | integer \| null | `memory.high`, `null` for the literal `max`. |
| `memory.max_bytes` | integer \| null | `memory.max`, `null` for the literal `max`. |
| `memory.oom_kill_count` | integer \| null | The `oom_kill` field of `memory.events`. |
| `cpu.limit_nanos` | integer \| null | `HostConfig.NanoCpus` (0 reads as `null` — no limit set). |

Every `memory.*`/`cpu.*` field is `null`, never a fabricated number, when
the collector's container cannot read that container's cgroup files (see
"Degradation" below) — this is routinely true for a container on a
different cgroup slice than the one the collector's own host mount
exposes, and is not itself a fault.

## `pods` / `rollouts` / `cronjobs` / `node_conditions` / `pvcs` (`kubernetes` only)

| Array | Field | Type | Meaning |
| --- | --- | --- | --- |
| `pods[]` | `name`, `namespace` | string | The pod's own identity. |
| | `phase` | string | `status.phase`. |
| | `restart_count` | integer | Sum of every container status's own `restartCount`. |
| | `last_terminated_reason` | string \| null | The first container status's `lastState.terminated.reason` that is non-empty (e.g. `OOMKilled`), `null` when none. |
| | `waiting_reason` | string \| null | The first container status's `state.waiting.reason` that is non-empty (e.g. `ImagePullBackOff`), `null` when none. |
| `rollouts[]` | `name`, `namespace`, `kind` | string | The Deployment's (or StatefulSet's) own identity. |
| | `desired_replicas`, `ready_replicas` | integer | `spec.replicas`, `status.readyReplicas` (0 when absent). |
| | `progress_deadline_seconds` | integer \| null | `spec.progressDeadlineSeconds`. |
| | `stalled` | boolean | `ready_replicas < desired_replicas` **and** a `Progressing` condition's own `lastUpdateTime` is older than `progress_deadline_seconds` — a rollout that is merely still rolling reads `false`. |
| `cronjobs[]` | `name`, `namespace`, `schedule` | string | The CronJob's own identity and cron expression. |
| | `last_schedule_time` | string \| null | `status.lastScheduleTime`. |
| | `stopped_scheduling` | boolean | `true` when `last_schedule_time` is older than a fixed 600 seconds — two ticks of the five-minute cadence `deploy/kubernetes/collector-cronjob.yaml` itself runs on. `schedule` is carried in the entry but not parsed, so a CronJob on a slower cadence than every ten minutes reads `true` routinely rather than only once it has genuinely stopped; agent-ops#1331 tracks deriving the threshold from the entry's own `schedule`. |
| `node_conditions[]` | `node`, `type`, `status` | string | One entry per condition on `status.conditions` whose own `type` names a pressure kind (`MemoryPressure`, `DiskPressure`, `PIDPressure`) and whose `status` is not `"False"` — a healthy node contributes no entries at all. |
| `pvcs[]` | `name`, `namespace` | string | The PersistentVolumeClaim's own identity. |
| | `used_percent` | number \| null | Usage against capacity from the metrics API, `null` where that API is unavailable — this array is never populated by guessing from `spec.resources.requests.storage` alone. |

## `updater`

| Field | Type | Meaning |
| --- | --- | --- |
| `updater.ledger_tail` | array | The last five entries across **every** `updater-ledger/*.jsonl` on this node, merged, ordered by each entry's own `ts`, oldest first — the same ledger `lib/updater-health.sh` already reads from inside the scheduler container, read here from the host/cluster side instead. Every file, not one named for this node: the ledger's writer keys each file by the *writing container's* `$HOSTNAME` (a container ID on this stack), which `NODE_NAME` never equals, and a roll's replacement writes under a new one — so one node's updater history is spread across files by construction. Sibling services share the directory, so read each entry's own `service` field to tell them apart. Truncated, never the whole ledger: it is unbounded within its own 7-day prune, and five entries is enough to see a streak. |
| `updater.last_session` | object \| null | `{"ts", "failed", "scanned", "updated"}` — the newest `Session done Failed=<n> Scanned=<n> Updated=<n>` line this collector can read from the updater container's own log, `null` when no such line exists (no updater on this node, or it has not completed a scan since the container last started). |

## `viewer_probe`

An object keyed by node name, one entry per node this collector could
attempt to reach — every peer this node's state-sync fetch has ever
materialised, plus itself:

| Field | Type | Meaning |
| --- | --- | --- |
| `viewer_probe.<node>.ok` | boolean | Whether the fetch of that node's own dashboard `data.js` succeeded and parsed as JSON. |
| `viewer_probe.<node>.bytes` | integer \| null | The response body's size, `null` when nothing was fetched at all. A body that arrived but would not parse reads its own size here alongside `ok: false` — the size is a real measurement either way, and "it answered, with 40 KB of the wrong thing" is a different fault from "it did not answer". |
| `viewer_probe.<node>.seconds` | number \| null | Wall time the fetch took, `null` on any `ok: false` — a timing for a fetch that did not deliver usable JSON would read like a healthy latency figure in any consumer that averaged it. |
| `viewer_probe.<node>.reason` | string \| null | Why `ok` is `false` — a timeout, a non-200 status, a body that did not parse — `null` when `ok` is `true`. |

This is the check agent-ops#1286 exists for: it answers "does `data.js`
actually arrive, from a vantage that is not the dashboard's own container,"
which is exactly the self-certification gap the 2026-08-08 four-day silent
outage (`docs/ROADMAP.md`'s health bullet) already burned this installation
once on a different signal.

## Degradation

Every field in this document is `null` (or the array it belongs to is
simply empty), never a fabricated value, when the fact behind it cannot be
read — the same contract `lib/compose-drift.sh`, `lib/image-drift.sh` and
`lib/updater-health.sh` already hold, restated here because a collector
that guessed at a host fact would be worse than one that admitted it did
not know. `scripts/collect-host-facts.sh` never returns non-zero for a
degraded fact and never aborts a whole record because one section could not
be read — the record it does have is still worth publishing.

## Stability policy

Identical to `docs/FLOW-SCHEMA.md`'s and `docs/METERING-SCHEMA.md`'s own,
restated here for the same reason: this is a contract other code (`doctor.sh`,
the dashboard, a future pager invariant) will depend on.

- **Additive, non-breaking:** a new field on any object in this document; a
  new array entry shape gaining a field; a new node-pressure condition type
  recognised in `node_conditions[]`; a new driver added alongside `compose`
  and `kubernetes`.
- **Breaking, and must land in the same pull request as the code that makes
  it (`CLAUDE.md`, "As-built specifications"):** renaming or removing a
  field; changing a field's type or unit; changing what `digest_match`/
  `mtu_match`/`stalled`/`stopped_scheduling` mean; changing the envelope's
  five top-level fields.

## Where it's produced and consumed

**Produced:** `scripts/collect-host-facts.sh`, over `lib/host-facts.sh` (the
envelope, `host`, `updater`, `viewer_probe` — driver-independent) and
`lib/host-facts-compose.sh` / `lib/host-facts-kubernetes.sh` (the two
driver-specific sections). Written to `state_dir/host-facts/<node>.json`
atomically (temp file, then `mv`), on the collector's own schedule — the
compose service's own loop, or the Kubernetes CronJob's own tick — and
carried to the rest of the fleet by the next ordinary `state-sync.sh push`
and `fetch`, the same as every other file under `state_dir` requirement 2.5's
own "What replicates" does not name in `EXCLUDES`.

**Consumed:**

- `scripts/doctor.sh`'s Egress section, which reads `host.network` and
  compares `docker_mtu_configured` against `egress_mtu`, surfacing a
  mismatch this node's own container could never detect for itself.
- `dashboard/index.html`'s node card, which shows a `host` line whenever
  this record carries something worth flagging — surfaced via
  `scripts/publish-dashboard.sh` folding `host-facts/<node>.json` (self)
  and `<peers_dir>/<peer>/host-facts/<peer>.json` (each peer) into that
  node's row, `host: null` when no record exists for that node yet.
- The Enabler's own 36a text (`docs/IMPLEMENTATION-PIPELINE-SPEC.md`,
  "The owner-only boundary"), and `prompts/enabler.md`'s `escalate` verdict
  which implements it: conditions 7 and 8 are refused when this record
  already answers the fact being asked for.

## Verifying conformance

`test/collect-host-facts-compose.test.sh` and
`test/collect-host-facts-kubernetes.test.sh` each drive their own driver
function directly against fixture Docker-Engine-API / Kubernetes-API JSON —
the same JSON `docker inspect` and `kubectl get -o json` show, since both
tools are thin clients over exactly these responses — asserting the record
shape above field by field, including the degradations this document names:
an unreadable cgroup file, a container carrying no compose-service label, an
unreachable registry, a container running an image from a repository other
than the one the registry digest was fetched for, a pod with no
terminated/waiting container status, a CronJob that has stopped scheduling,
and a viewer probe that times out or receives a body that will not parse as
JSON.
