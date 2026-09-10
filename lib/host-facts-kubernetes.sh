#!/usr/bin/env bash
#
# lib/host-facts-kubernetes.sh — the Kubernetes driver's own section of the
# host-facts record (docs/HOST-FACTS-SCHEMA.md: "pods"/"rollouts"/
# "cronjobs"/"node_conditions"/"pvcs"). Reads the Kubernetes API directly
# over `curl` with the pod's own in-cluster ServiceAccount credentials,
# never the `kubectl` binary, which this image does not install (the same
# "bash-plus-jq container" property `lib/host-facts-compose.sh` holds for
# the Docker Engine API). The API's own `List` JSON is exactly what
# `kubectl get -o json` prints — a thin CLI wrapper over exactly this
# response — which is why `test/collect-host-facts-kubernetes.test.sh` can
# drive the pure functions below with fixture files literally captured
# from `kubectl get -o json`.
#
# Every function here holds lib/host-facts.sh's own contract: one compact
# JSON array (never an object wrapper, never non-zero), skipping a
# malformed element rather than failing the whole array, and never
# fabricating a value this API did not actually report.

# host_facts_k8s_pods_json PODS-LIST-JSON — the `pods[]` array.
host_facts_k8s_pods_json() {
  jq -c '
    [ (.items // [])[] | {
        name: (.metadata.name // "unknown"),
        namespace: (.metadata.namespace // "default"),
        phase: (.status.phase // "Unknown"),
        restart_count: ([(.status.containerStatuses // [])[].restartCount // 0] | add // 0),
        last_terminated_reason: (
          [(.status.containerStatuses // [])[].lastState.terminated.reason // empty] | first // null
        ),
        waiting_reason: (
          [(.status.containerStatuses // [])[].state.waiting.reason // empty] | first // null
        )
      }
    ]' <<<"${1:-{\}}" 2>/dev/null || printf '[]'
}

# host_facts_k8s_rollouts_json DEPLOYMENTS-LIST-JSON [NOW-EPOCH] — the
# `rollouts[]` array. `stalled` is true only when the rollout is both short
# of its desired replica count *and* its own `Progressing` condition has not
# moved past `progressDeadlineSeconds` — a rollout still within its own
# deadline is merely rolling, not stalled.
host_facts_k8s_rollouts_json() {
  local now="${2:-$(date +%s)}"
  jq -c --argjson now "$now" '
    [ (.items // [])[] | {
        name: (.metadata.name // "unknown"),
        namespace: (.metadata.namespace // "default"),
        kind: (.kind // "Deployment"),
        desired_replicas: (.spec.replicas // 0),
        ready_replicas: (.status.readyReplicas // 0),
        progress_deadline_seconds: (.spec.progressDeadlineSeconds // null),
        stalled: (
          ((.status.readyReplicas // 0) < (.spec.replicas // 0)) and
          ((.spec.progressDeadlineSeconds // null) != null) and
          (
            [(.status.conditions // [])[] | select(.type == "Progressing")] as $p
            | if ($p | length) == 0 then false
              else ($now - (($p[0].lastUpdateTime // "1970-01-01T00:00:00Z") | fromdateiso8601))
                   > (.spec.progressDeadlineSeconds)
              end
          )
        )
      }
    ]' <<<"${1:-{\}}" 2>/dev/null || printf '[]'
}

# host_facts_k8s_cronjobs_json CRONJOBS-LIST-JSON [NOW-EPOCH] —
# `cronjobs[]`. `stopped_scheduling` is true when `lastScheduleTime` is older
# than a fixed 600 seconds — two ticks of the five-minute schedule
# deploy/kubernetes/collector-cronjob.yaml itself runs on, so a CronJob on
# that cadence reads `false` between ticks and `true` only once it has
# genuinely stopped. `.spec.schedule` is carried in the record but not parsed
# here: a CronJob on a slower cadence than every ten minutes therefore reads
# `true` routinely, which agent-ops#1331 tracks.
host_facts_k8s_cronjobs_json() {
  local now="${2:-$(date +%s)}"
  jq -c --argjson now "$now" '
    [ (.items // [])[] | {
        name: (.metadata.name // "unknown"),
        namespace: (.metadata.namespace // "default"),
        schedule: (.spec.schedule // ""),
        last_schedule_time: (.status.lastScheduleTime // null),
        stopped_scheduling: (
          if (.status.lastScheduleTime // null) == null then false
          else ($now - (.status.lastScheduleTime | fromdateiso8601)) > 600
          end
        )
      }
    ]' <<<"${1:-{\}}" 2>/dev/null || printf '[]'
}

# host_facts_k8s_node_conditions_json NODES-LIST-JSON — `node_conditions[]`:
# one entry per pressure condition (MemoryPressure/DiskPressure/PIDPressure)
# whose own status is not "False" — a healthy node contributes nothing.
host_facts_k8s_node_conditions_json() {
  jq -c '
    [ (.items // [])[] as $n
      | ($n.status.conditions // [])[]
      | select(.type as $t | ["MemoryPressure","DiskPressure","PIDPressure"] | index($t))
      | select(.status != "False")
      | {node: ($n.metadata.name // "unknown"), type: .type, status: .status}
    ]' <<<"${1:-{\}}" 2>/dev/null || printf '[]'
}

# host_facts_k8s_pvcs_json PVCS-LIST-JSON — `pvcs[]`. `used_percent` is
# always `null` here: this image has no metrics-API client, so usage
# against capacity is never guessed from `spec.resources.requests.storage`
# alone (docs/HOST-FACTS-SCHEMA.md's own "never populated by guessing"
# rule) — present for the identity list, honestly `null` for the figure.
host_facts_k8s_pvcs_json() {
  jq -c '
    [ (.items // [])[] | {
        name: (.metadata.name // "unknown"),
        namespace: (.metadata.namespace // "default"),
        used_percent: null
      }
    ]' <<<"${1:-{\}}" 2>/dev/null || printf '[]'
}

# _host_facts_k8s_token / _host_facts_k8s_cacert / _host_facts_k8s_namespace
# — the in-cluster ServiceAccount credentials every kubelet-mounted pod
# carries, or empty when this is not running in a pod (a developer's
# checkout, a test).
_host_facts_k8s_token() {
  cat "${HOST_FACTS_K8S_TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}" 2>/dev/null
}
_host_facts_k8s_cacert() {
  printf '%s' "${HOST_FACTS_K8S_CACERT_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}"
}
_host_facts_k8s_namespace() {
  cat "${HOST_FACTS_K8S_NAMESPACE_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/namespace}" 2>/dev/null
}

# host_facts_k8s_get PATH [CURL-CMD] — one Kubernetes API GET against the
# in-cluster API server, or empty on any failure. CURL-CMD defaults to
# `curl`; the test suite points it at a fixture standing in for the API
# server, the same override shape `IMAGE_DRIFT_CURL_CMD` already gives
# `lib/image-drift.sh` and `HOST_FACTS_DOCKER_CURL_CMD` gives the compose
# driver.
host_facts_k8s_get() {
  local path="${1:-}" curl_cmd="${2:-${HOST_FACTS_K8S_CURL_CMD:-curl}}" \
    token="" cacert="" host="${KUBERNETES_SERVICE_HOST:-}" \
    port="${KUBERNETES_SERVICE_PORT:-443}"
  token="$(_host_facts_k8s_token)"
  cacert="$(_host_facts_k8s_cacert)"
  [[ -n "$host" ]] || return 0
  "$curl_cmd" -fsS --max-time 5 \
    --cacert "$cacert" -H "Authorization: Bearer $token" \
    "https://$host:$port$path" 2>/dev/null
}

# host_facts_kubernetes_section [CURL-CMD] — the whole Kubernetes-driver
# section: `{"pods":[...], "rollouts":[...], "cronjobs":[...],
# "node_conditions":[...], "pvcs":[...]}`. Scoped to this collector's own
# namespace for every namespaced kind (the "read-only Role" the issue asks
# for), and cluster-wide for `nodes` — pressure conditions are a
# cluster-scoped fact no namespaced Role can read, so that one list alone
# needs the narrow `nodes` get/list ClusterRole
# deploy/kubernetes/collector-cronjob.yaml grants alongside it.
host_facts_kubernetes_section() {
  local curl_cmd="${1:-${HOST_FACTS_K8S_CURL_CMD:-curl}}" ns=""
  ns="$(_host_facts_k8s_namespace)"
  [[ -n "$ns" ]] || ns="default"

  local pods_json="" deployments_json="" cronjobs_json="" nodes_json="" pvcs_json=""
  pods_json="$(host_facts_k8s_get "/api/v1/namespaces/$ns/pods" "$curl_cmd")"
  deployments_json="$(host_facts_k8s_get "/apis/apps/v1/namespaces/$ns/deployments" "$curl_cmd")"
  cronjobs_json="$(host_facts_k8s_get "/apis/batch/v1/namespaces/$ns/cronjobs" "$curl_cmd")"
  nodes_json="$(host_facts_k8s_get "/api/v1/nodes" "$curl_cmd")"
  pvcs_json="$(host_facts_k8s_get "/api/v1/namespaces/$ns/persistentvolumeclaims" "$curl_cmd")"

  jq -nc \
    --argjson pods "$(host_facts_k8s_pods_json "$pods_json")" \
    --argjson rollouts "$(host_facts_k8s_rollouts_json "$deployments_json")" \
    --argjson cronjobs "$(host_facts_k8s_cronjobs_json "$cronjobs_json")" \
    --argjson node_conditions "$(host_facts_k8s_node_conditions_json "$nodes_json")" \
    --argjson pvcs "$(host_facts_k8s_pvcs_json "$pvcs_json")" \
    '{pods:$pods, rollouts:$rollouts, cronjobs:$cronjobs,
      node_conditions:$node_conditions, pvcs:$pvcs}'
}
