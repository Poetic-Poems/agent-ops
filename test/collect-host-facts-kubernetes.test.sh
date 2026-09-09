#!/usr/bin/env bash
#
# test/collect-host-facts-kubernetes.test.sh — the Kubernetes driver of the
# host-facts collector (issue #1283, docs/HOST-FACTS-SCHEMA.md), against
# fixture Kubernetes API JSON — the same `List` shape `kubectl get -o json`
# prints, since it is a thin client over exactly this API
# (lib/host-facts-kubernetes.sh's own header). No real cluster exists where
# this suite runs, so every API call goes through a fixture `curl` stub
# keyed on the URL it is asked for, the same override shape
# test/collect-host-facts-compose.test.sh exercises for the Docker Engine
# API.
#
# The properties that matter:
#   - a pod's phase, restart count (summed across containers), terminated
#     reason and waiting reason all come through;
#   - a pod with neither a terminated nor a waiting container status reads
#     both null, never a fabricated reason;
#   - a rollout short of its desired replicas but still inside its own
#     progressDeadlineSeconds reads stalled: false; one that has overrun it
#     reads stalled: true;
#   - a CronJob whose lastScheduleTime is recent reads
#     stopped_scheduling: false; one well past it reads true;
#   - node_conditions carries only pressure conditions whose own status is
#     not "False" — a healthy node contributes nothing;
#   - pvcs always reads used_percent: null (no metrics-API client in this
#     image) — present for identity, honest about the figure;
#   - a malformed/empty list response degrades every array to `[]`, never
#     a crash.
#
# Run directly: ./test/collect-host-facts-kubernetes.test.sh — exit 0 iff
# all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/host-facts-kubernetes.sh
. "$SCRIPT_DIR/lib/host-facts-kubernetes.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

now="$(date -u -d '2026-09-09T00:20:00Z' +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-09-09T00:20:00Z' +%s)"

# --- Pods ------------------------------------------------------------------
pods_json='{"items":[
  {"metadata":{"name":"p-oom","namespace":"ns1"},
   "status":{"phase":"Running",
     "containerStatuses":[{"restartCount":3,"lastState":{"terminated":{"reason":"OOMKilled"}}}]}},
  {"metadata":{"name":"p-pull","namespace":"ns1"},
   "status":{"phase":"Pending",
     "containerStatuses":[{"restartCount":0,"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}},
  {"metadata":{"name":"p-healthy","namespace":"ns1"},
   "status":{"phase":"Running","containerStatuses":[{"restartCount":0}]}}
]}'
pods="$(host_facts_k8s_pods_json "$pods_json")"
assert_eq "three pods parsed" "3" "$(jq 'length' <<<"$pods")"
assert_eq "OOMKilled reason comes through" "OOMKilled" \
  "$(jq -r '.[] | select(.name=="p-oom") | .last_terminated_reason' <<<"$pods")"
assert_eq "restart_count summed across container statuses" "3" \
  "$(jq -r '.[] | select(.name=="p-oom") | .restart_count' <<<"$pods")"
assert_eq "ImagePullBackOff waiting reason comes through" "ImagePullBackOff" \
  "$(jq -r '.[] | select(.name=="p-pull") | .waiting_reason' <<<"$pods")"
assert_eq "a healthy pod's terminated reason is null, not fabricated" "null" \
  "$(jq -r '.[] | select(.name=="p-healthy") | .last_terminated_reason' <<<"$pods")"
assert_eq "a healthy pod's waiting reason is null, not fabricated" "null" \
  "$(jq -r '.[] | select(.name=="p-healthy") | .waiting_reason' <<<"$pods")"

# --- Rollouts ---------------------------------------------------------------
deploy_within_deadline='{"items":[
  {"metadata":{"name":"d-ok"},"kind":"Deployment",
   "spec":{"replicas":3,"progressDeadlineSeconds":600},
   "status":{"readyReplicas":1,
     "conditions":[{"type":"Progressing","lastUpdateTime":"2026-09-09T00:15:00Z"}]}}
]}'
rollouts_ok="$(host_facts_k8s_rollouts_json "$deploy_within_deadline" "$now")"
assert_eq "a rollout still inside its own deadline is not stalled" "false" \
  "$(jq -r '.[0].stalled' <<<"$rollouts_ok")"

deploy_overrun='{"items":[
  {"metadata":{"name":"d-stalled"},"kind":"Deployment",
   "spec":{"replicas":3,"progressDeadlineSeconds":600},
   "status":{"readyReplicas":1,
     "conditions":[{"type":"Progressing","lastUpdateTime":"2026-09-09T00:00:00Z"}]}}
]}'
rollouts_stalled="$(host_facts_k8s_rollouts_json "$deploy_overrun" "$now")"
assert_eq "a rollout past its own deadline is stalled" "true" \
  "$(jq -r '.[0].stalled' <<<"$rollouts_stalled")"

deploy_healthy='{"items":[
  {"metadata":{"name":"d-healthy"},"kind":"Deployment",
   "spec":{"replicas":3,"progressDeadlineSeconds":600},
   "status":{"readyReplicas":3}}
]}'
rollouts_healthy="$(host_facts_k8s_rollouts_json "$deploy_healthy" "$now")"
assert_eq "a fully-ready rollout is never stalled" "false" \
  "$(jq -r '.[0].stalled' <<<"$rollouts_healthy")"

# --- CronJobs ---------------------------------------------------------------
cron_recent='{"items":[{"metadata":{"name":"c-recent"},"spec":{"schedule":"*/5 * * * *"},
  "status":{"lastScheduleTime":"2026-09-09T00:18:00Z"}}]}'
assert_eq "a recently-scheduled CronJob has not stopped" "false" \
  "$(jq -r '.[0].stopped_scheduling' <<<"$(host_facts_k8s_cronjobs_json "$cron_recent" "$now")")"

cron_stopped='{"items":[{"metadata":{"name":"c-stopped"},"spec":{"schedule":"*/5 * * * *"},
  "status":{"lastScheduleTime":"2026-09-08T00:00:00Z"}}]}'
assert_eq "a long-unscheduled CronJob reads stopped_scheduling: true" "true" \
  "$(jq -r '.[0].stopped_scheduling' <<<"$(host_facts_k8s_cronjobs_json "$cron_stopped" "$now")")"

# --- Node conditions ---------------------------------------------------------
nodes_json='{"items":[
  {"metadata":{"name":"node1"},"status":{"conditions":[
    {"type":"Ready","status":"True"},
    {"type":"MemoryPressure","status":"True"},
    {"type":"DiskPressure","status":"False"}
  ]}},
  {"metadata":{"name":"node2"},"status":{"conditions":[
    {"type":"Ready","status":"True"},
    {"type":"MemoryPressure","status":"False"},
    {"type":"DiskPressure","status":"False"}
  ]}}
]}'
conditions="$(host_facts_k8s_node_conditions_json "$nodes_json")"
assert_eq "only the one real pressure condition is reported" "1" "$(jq 'length' <<<"$conditions")"
assert_eq "the reported condition names its own node" "node1" "$(jq -r '.[0].node' <<<"$conditions")"

# --- PVCs --------------------------------------------------------------------
pvcs_json='{"items":[{"metadata":{"name":"v1","namespace":"ns1"}}]}'
pvcs="$(host_facts_k8s_pvcs_json "$pvcs_json")"
assert_eq "pvcs carries the identity" "v1" "$(jq -r '.[0].name' <<<"$pvcs")"
assert_eq "used_percent is honestly null, never guessed" "null" "$(jq -r '.[0].used_percent' <<<"$pvcs")"

# --- Degradation: malformed/empty input never crashes -----------------------
assert_eq "empty pods list degrades to []" "[]" "$(host_facts_k8s_pods_json '{}')"
assert_eq "no-argument call degrades to []" "[]" "$(host_facts_k8s_pods_json)"
assert_eq "malformed JSON degrades to [] rather than aborting" "[]" \
  "$(host_facts_k8s_rollouts_json 'not json at all' "$now")"

# --- Full section, end to end through the fixture curl ----------------------
stub_curl="$tmp_dir/stub-curl.sh"
cat > "$stub_curl" <<'STUB'
#!/usr/bin/env bash
args=("$@")
url="${args[-1]}"
case "$url" in
  *"/api/v1/namespaces/testns/pods") echo '{"items":[]}' ;;
  *"/apis/apps/v1/namespaces/testns/deployments") echo '{"items":[]}' ;;
  *"/apis/batch/v1/namespaces/testns/cronjobs") echo '{"items":[]}' ;;
  *"/api/v1/nodes") echo '{"items":[]}' ;;
  *"/persistentvolumeclaims") echo '{"items":[]}' ;;
  *) echo "unhandled: $url" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub_curl"

token_file="$tmp_dir/token"
cacert_file="$tmp_dir/ca.crt"
ns_file="$tmp_dir/namespace"
printf 'faketoken\n' > "$token_file"
: > "$cacert_file"
printf 'testns\n' > "$ns_file"

export HOST_FACTS_K8S_TOKEN_FILE="$token_file" HOST_FACTS_K8S_CACERT_FILE="$cacert_file" \
  HOST_FACTS_K8S_NAMESPACE_FILE="$ns_file" KUBERNETES_SERVICE_HOST=127.0.0.1
section="$(host_facts_kubernetes_section "$stub_curl")"
assert_eq "section carries all five arrays, each present" \
  '["cronjobs","node_conditions","pods","pvcs","rollouts"]' \
  "$(jq -c '. | keys' <<<"$section")"
assert_eq "an empty cluster reads every array empty, not absent" "0" \
  "$(jq '[.pods,.rollouts,.cronjobs,.node_conditions,.pvcs] | map(length) | add' <<<"$section")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
