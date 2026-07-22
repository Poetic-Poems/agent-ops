#!/usr/bin/env bash
#
# test/toggle.test.sh — regression test for lib/toggle.sh.
#
# The switch has one job (stop cycles starting) and one way to fail badly: to
# resolve toward "enabled" when it shouldn't, or to stay "disabled" when
# nothing will ever clear it. Both are silent. The assertions below are almost
# all about those two directions rather than about the happy path:
#
#   - an unreadable or half-written record must read as disabled, not enabled;
#   - an unparseable `expires_at` must not expire;
#   - a TTL typo must be an error, not a guess in either direction;
#   - `--enable` on an already-enabled pipeline is a normal outcome and must
#     not return non-zero, because every call site is `x="$(toggle_clear …)"`
#     under `set -e` (the trap in the Gotchas table).
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/toggle.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"

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

state_dir="$tmp_dir/state"
mkdir -p "$state_dir"

# A pinned clock: 2026-07-17T12:00:00Z. Expiry is the feature most worth
# testing and the least testable by waiting.
export TOGGLE_NOW_EPOCH=1784289600

state_of() { jq -r '.state' <<<"$(toggle_state "$state_dir")"; }

# --- No switch ---

assert_eq "no record reads as enabled" "enabled" "$(state_of)"

# The call-site shape, under `set -e`, in a subshell: the absence of a switch is
# the normal case, and a non-zero here would kill every cycle at line one.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/toggle.sh"
  s="$(toggle_state "$state_dir")"
  r="$(toggle_clear "$state_dir")"
  printf '%s%s' "$s" "$r" >/dev/null
  exit 0
) >/dev/null 2>&1
assert_eq "an absent switch does not abort its caller under set -e" "0" "$?"

assert_eq "clearing an unset switch is silent, not an error" "" "$(toggle_clear "$state_dir")"

# --- toggle_parse_ttl ---

assert_eq "a bare number means hours" "2026-07-17T16:00:00Z" "$(toggle_parse_ttl "4" 9)"
assert_eq "hours" "2026-07-17T16:00:00Z" "$(toggle_parse_ttl "4h" 9)"
assert_eq "minutes" "2026-07-17T13:30:00Z" "$(toggle_parse_ttl "90m" 9)"
assert_eq "days" "2026-07-19T12:00:00Z" "$(toggle_parse_ttl "2d" 9)"
assert_eq "an empty spec falls back to the configured default" \
  "2026-07-17T16:00:00Z" "$(toggle_parse_ttl "" 4)"
assert_eq "forever has no expiry" "" "$(toggle_parse_ttl "forever" 4)"
assert_eq "never is a synonym for forever" "" "$(toggle_parse_ttl "never" 4)"

# A typo must not silently become either 4 hours or forever: one resumes the
# pipeline while an agent is still editing, the other never resumes it.
toggle_parse_ttl "4hours" 4 >/dev/null 2>&1
assert_eq "an unparseable duration is an error, not a default" "64" "$?"
toggle_parse_ttl "0" 4 >/dev/null 2>&1
assert_eq "a zero duration is an error, not an indefinite disable" "64" "$?"

# --- Setting and reading the switch ---

record="$(toggle_disable "$state_dir" "editing lib/toggle.sh" "2h" 4 "tester pid 1")"
assert_eq "disable writes the reason" "editing lib/toggle.sh" "$(jq -r '.reason' <<<"$record")"
assert_eq "disable stamps the expiry from the spec" \
  "2026-07-17T14:00:00Z" "$(jq -r '.expires_at' <<<"$record")"
assert_eq "disable records who set it" "tester pid 1" "$(jq -r '.by' <<<"$record")"
assert_eq "a set switch reads as disabled" "disabled" "$(state_of)"

# --- Expiry ---

TOGGLE_NOW_EPOCH=$(( 1784289600 + 7199 ))   # one second before the TTL
assert_eq "a switch one second short of its TTL is still disabled" "disabled" "$(state_of)"
TOGGLE_NOW_EPOCH=$(( 1784289600 + 7200 ))   # exactly at the TTL
assert_eq "a switch at its TTL has expired" "expired" "$(state_of)"
TOGGLE_NOW_EPOCH=1784289600

# The reason the TTL exists at all: an agent that disables the pipeline and
# then dies leaves this file behind, and nothing else would ever clear it.
assert_eq "an expired switch still carries its record, so the log can say what expired" \
  "editing lib/toggle.sh" \
  "$(TOGGLE_NOW_EPOCH=$(( 1784289600 + 7200 )) toggle_state "$state_dir" | jq -r '.record.reason')"

cleared="$(toggle_clear "$state_dir")"
assert_eq "clearing returns the record it removed" "editing lib/toggle.sh" "$(jq -r '.reason' <<<"$cleared")"
assert_eq "a cleared switch reads as enabled" "enabled" "$(state_of)"

# --- forever ---

toggle_disable "$state_dir" "long maintenance" "forever" 4 "tester" >/dev/null
assert_eq "an indefinite switch stores a null expiry" "null" \
  "$(jq -r '.expires_at' "$(toggle_file "$state_dir")")"
assert_eq "an indefinite switch does not expire, ever" "disabled" \
  "$(TOGGLE_NOW_EPOCH=$(( 1784289600 + 86400 * 365 )) toggle_state "$state_dir" | jq -r '.state')"
toggle_clear "$state_dir" >/dev/null

# --- Everything ambiguous resolves toward disabled ---

# A half-written record. The file exists because something meant to stop the
# pipeline; reading "enabled" out of a truncated write would run the very cycle
# the switch was set to prevent.
printf '{"disabled_at": "2026-07-17T09:00:00Z", "rea' > "$(toggle_file "$state_dir")"
assert_eq "an unreadable record reads as disabled, not enabled" "disabled" "$(state_of)"
assert_eq "an unreadable record still describes itself to the operator" \
  "0" "$([[ -n "$(toggle_describe "$(toggle_state "$state_dir" | jq -c '.record')")" ]] && echo 0 || echo 1)"
rm -f "$(toggle_file "$state_dir")"

# An expiry that doesn't parse has no expiry — it must not be treated as long
# past and cleared on the next tick.
jq -n '{disabled_at: "2026-07-17T09:00:00Z", expires_at: "next tuesday-ish", by: "t", reason: "r"}' \
  > "$(toggle_file "$state_dir")"
assert_eq "an unparseable expiry does not expire the switch" "disabled" "$(state_of)"
rm -f "$(toggle_file "$state_dir")"

# A failed disable must leave no switch: an operator told "that didn't work"
# who is nonetheless disabled has been lied to in the more dangerous direction.
toggle_disable "$state_dir" "reason" "banana" 4 "tester" >/dev/null 2>&1
assert_eq "a disable with an unparseable duration fails" "64" "$?"
assert_eq "a failed disable writes no switch" "enabled" "$(state_of)"

# --- toggle_lock_held ---

lock="$tmp_dir/lock.json"
assert_eq "an absent lock is not held" "" "$(toggle_lock_held "$lock")"
jq -n '{pid: 999999, started_at: "2026-07-17T11:00:00Z"}' > "$lock"
assert_eq "a lock held by a dead pid is not held" "" "$(toggle_lock_held "$lock")"
jq -n --argjson p "$$" '{pid: $p, started_at: "2026-07-17T11:00:00Z"}' > "$lock"
assert_eq "a lock held by a live pid is reported" \
  "held by pid $$ since 2026-07-17T11:00:00Z" "$(toggle_lock_held "$lock")"

# --- toggle_status_report ---

toggle_disable "$state_dir" "editing" "1h" 4 "tester" >/dev/null
report="$(toggle_status_report "$state_dir" "cycle=$lock" "review=$tmp_dir/absent.json")"
assert_eq "status reports the switch" "1" "$(grep -c 'DISABLED' <<<"$report")"
assert_eq "status reports a running pipeline" "1" "$(grep -c 'cycle:.*RUNNING' <<<"$report")"
assert_eq "status reports an idle pipeline" "1" "$(grep -c 'review:.*idle' <<<"$report")"
# Disabling stops the next cycle, not the one already running. An agent that
# doesn't know that disables the pipeline, starts editing, and is puzzled when
# the cycle it thought it stopped fails on its half-written file.
assert_eq "status warns when a cycle is running despite the switch" \
  "1" "$(grep -c 'does not stop one already running' <<<"$report")"

# ===== Fleet flags (requirements 2.3a and 2.1) ================================
#
# The failure directions here mirror the local switch's, one level up:
#
#   - a flag one node set must read as set on another node (that is the flag's
#     whole job);
#   - an unreachable state repo must fall back to the cached copy, and to
#     enabled with none — never crash a cycle;
#   - a 404 is "clear", definitively, and must also clear the cache;
#   - a garbage flag reads as disabled, like a garbage local record;
#   - the limit flag only ever extends, whatever order writes land in;
#   - "cleared" must never be reported for a flag that is still set.

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# A stub `gh` backed by a directory: the contents API reduced to GET/PUT/DELETE
# with sha compare-and-swap, exactly the subset lib/toggle.sh uses.
# GH_STUB_MODE=down makes every call fail the way an unreachable GitHub does.
gh_backing="$tmp_dir/fleet-remote"
mkdir -p "$gh_backing"
gh_stub="$tmp_dir/gh-stub"
cat > "$gh_stub" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${GH_STUB_MODE:-ok}" == "down" ]]; then
  echo "dial tcp: could not resolve host github.com" >&2
  exit 1
fi
backing="${GH_STUB_BACKING:?}"
method=GET path="" jq_expr=""
declare -A f=()
args=("$@"); i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  case "$a" in
    -X)      i=$((i+1)); method="${args[$i]}" ;;
    --jq)    i=$((i+1)); jq_expr="${args[$i]}" ;;
    -f)      i=$((i+1)); kv="${args[$i]}"; f["${kv%%=*}"]="${kv#*=}" ;;
    repos/*) path="$a" ;;
  esac
  i=$((i+1))
done
rel="${path#repos/*/*/contents/}"; rel="${rel%%\?*}"
file="$backing/$rel"
sha_of() { sha1sum "$1" | awk '{print $1}'; }
case "$method" in
  GET)
    [[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    if [[ "$jq_expr" == ".sha" ]]; then sha_of "$file"; exit 0; fi
    jq -n --arg c "$(base64 -w0 < "$file")" --arg s "$(sha_of "$file")" '{content: $c, sha: $s}'
    ;;
  PUT)
    if [[ -f "$file" ]]; then
      [[ "${f[sha]:-}" == "$(sha_of "$file")" ]] || { echo "gh: sha mismatch (HTTP 409)" >&2; exit 1; }
    elif [[ -n "${f[sha]:-}" ]]; then
      echo "gh: sha given for a missing file (HTTP 422)" >&2; exit 1
    fi
    mkdir -p "$(dirname "$file")"
    printf '%s' "${f[content]:?}" | base64 -d > "$file"
    ;;
  DELETE)
    [[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    [[ "${f[sha]:-}" == "$(sha_of "$file")" ]] || { echo "gh: sha mismatch (HTTP 409)" >&2; exit 1; }
    rm -f "$file"
    ;;
esac
STUB
chmod +x "$gh_stub"
export TOGGLE_GH="$gh_stub" GH_STUB_BACKING="$gh_backing"

slug="example/agent-ops-state"
fs_a="$tmp_dir/fleet-state-a"; fs_b="$tmp_dir/fleet-state-b"
mkdir -p "$fs_a" "$fs_b"

# --- Fetch, cache, and the failure directions ---

assert_eq "an absent fleet flag fetches as nothing" "" \
  "$(fleet_flag_fetch "$slug" "$fs_b" disabled)"
assert_eq "an absent fleet flag leaves no cache" "0" \
  "$(test -f "$(fleet_cache_file "$fs_b" disabled)" && echo 1 || echo 0)"
assert_eq "no state repo means no fleet: everything is a quiet no-op" "enabled" \
  "$(fleet_disabled_state "" "$fs_b" | jq -r '.state')"

rec="$(jq -nc '{disabled_at: "2026-07-17T11:00:00Z", expires_at: "2026-07-17T13:00:00Z", by: "node-a", reason: "fleet halt"}')"
fleet_flag_write "$slug" disabled "$rec" "set by the test"
assert_eq "writing a fleet flag succeeds" "0" "$?"
assert_eq "a flag node A set reads as disabled on node B" "disabled" \
  "$(fleet_disabled_state "$slug" "$fs_b" | jq -r '.state')"
assert_eq "the record round-trips through the contents API" "fleet halt" \
  "$(fleet_disabled_state "$slug" "$fs_b" | jq -r '.record.reason')"
assert_eq "a successful fetch caches the flag" "1" \
  "$(test -f "$(fleet_cache_file "$fs_b" disabled)" && echo 1 || echo 0)"

assert_eq "an unreachable repo falls back to the cached copy" "disabled" \
  "$(GH_STUB_MODE=down fleet_disabled_state "$slug" "$fs_b" | jq -r '.state')"
fs_c="$tmp_dir/fleet-state-c"; mkdir -p "$fs_c"
assert_eq "an unreachable repo with no cache reads as enabled (claims are the backstop)" "enabled" \
  "$(GH_STUB_MODE=down fleet_disabled_state "$slug" "$fs_c" | jq -r '.state')"

assert_eq "a fleet flag past its expiry reads as expired" "expired" \
  "$(TOGGLE_NOW_EPOCH=$(( 1784289600 + 4 * 3600 )) fleet_disabled_state "$slug" "$fs_b" | jq -r '.state')"

printf 'not json at all' > "$gh_backing/fleet/disabled.json"
assert_eq "a garbage fleet flag reads as disabled, not enabled" "disabled" \
  "$(fleet_disabled_state "$slug" "$fs_b" | jq -r '.state')"

# --- Delete: absent is cleared, unreachable is NOT ---

fleet_flag_delete "$slug" "$fs_b" disabled
assert_eq "deleting a set flag succeeds" "0" "$?"
assert_eq "the flag is gone from the repo" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
assert_eq "a successful delete drops the local cache too" "0" \
  "$(test -f "$(fleet_cache_file "$fs_b" disabled)" && echo 1 || echo 0)"
fleet_flag_delete "$slug" "$fs_b" disabled
assert_eq "deleting an absent flag is already-clear, not an error" "0" "$?"
GH_STUB_MODE=down fleet_flag_delete "$slug" "$fs_b" disabled
assert_eq "an unreachable repo must NOT report the flag cleared" "1" "$?"

# A 404 on fetch clears a stale cache: the flag was cleared remotely and the
# cached copy must not keep this node standing down.
fleet_flag_write "$slug" disabled "$rec" "set again"
fleet_flag_fetch "$slug" "$fs_b" disabled >/dev/null
rm -f "$gh_backing/fleet/disabled.json"
fleet_flag_fetch "$slug" "$fs_b" disabled >/dev/null
assert_eq "a 404 clears the cached copy" "0" \
  "$(test -f "$(fleet_cache_file "$fs_b" disabled)" && echo 1 || echo 0)"

# --- The limit flag only ever extends ---

fleet_limit_publish "$slug" "$fs_a" "2026-07-17T15:00:00Z" "monthly-spend" true node-a
assert_eq "the first limit publish creates the flag" "0" "$?"
assert_eq "the flag carries its resume_at" "2026-07-17T15:00:00Z" \
  "$(fleet_limit_resume_at "$slug" "$fs_b")"
fleet_limit_publish "$slug" "$fs_b" "2026-07-17T14:00:00Z" "weekly" false node-b
assert_eq "an earlier resume_at does not shorten the stand-down" "2026-07-17T15:00:00Z" \
  "$(fleet_limit_resume_at "$slug" "$fs_b")"
fleet_limit_publish "$slug" "$fs_b" "2026-07-17T18:00:00Z" "monthly-spend" true node-b
assert_eq "a later resume_at extends it" "2026-07-17T18:00:00Z" \
  "$(fleet_limit_resume_at "$slug" "$fs_a")"
assert_eq "the extending node signs the flag" "node-b" \
  "$(fleet_flag_fetch "$slug" "$fs_a" limit | jq -r '.node')"
rm -f "$gh_backing/fleet/limit.json"

# ===== The pipelines honour the fleet flags (offline e2e) =====================
#
# Node A sets the fleet switch with the real management command; node B runs
# the real pipelines. Every external surface is stubbed: TOGGLE_GH is the
# contents-API stub above, STATE_SYNC_REMOTE is a local bare repository (the
# cycle's cleanup push needs somewhere to land), CLAIM_GH fails fast, and a
# PATH shim makes `gh` and `claude` fail fast — a regression that let a cycle
# continue past the fleet checks must die at the next fence, never reach the
# network or a model.

stub_bin="$tmp_dir/stub-bin"
mkdir -p "$stub_bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_bin/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_bin/claude"
chmod +x "$stub_bin/gh" "$stub_bin/claude"

state_remote="$tmp_dir/state-remote.git"
git init --quiet --bare --initial-branch=main "$state_remote"

new_home() {  # new_home <name> -> prints a throwaway node HOME
  local home="$tmp_dir/$1"
  mkdir -p "$home/.local/state/poetic-agents" "$home/.cache/poetic-agents/workspaces"
  printf '%s' "$home"
}

run_node() {  # run_node <home> <script> [args…]
  local home="$1" script="$2"; shift 2
  env HOME="$home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$home")" \
    PATH="$stub_bin:$PATH" TOGGLE_GH="$gh_stub" GH_STUB_BACKING="$gh_backing" \
    CLAIM_GH=/bin/false STATE_SYNC_REMOTE="$state_remote" \
    "$SCRIPT_DIR/$script" "$@"
}

a_home="$(new_home fleet-node-a)"
b_home="$(new_home fleet-node-b)"
b_log="$b_home/.local/state/poetic-agents/log.jsonl"
b_review_log="$b_home/.local/state/poetic-agents/review-log.jsonl"

# A disables; the flag must land in the state repo, not just locally.
disable_out="$(run_node "$a_home" agent-cycle.sh --disable "fleet e2e halt" --for forever 2>&1)"
assert_contains "--disable reports the fleet switch set" "fleet switch set" "$disable_out"
assert_eq "--disable publishes fleet/disabled.json" "1" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"

# B's implementation cycle stands down for it.
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle on another node exits cleanly under the fleet switch" "0" "$?"
assert_contains "and logs a fleet-switch stand-down" '"event":"stand-down"' "$(cat "$b_log" 2>/dev/null)"
assert_contains "naming the fleet switch as the reason" 'fleet switch' "$(cat "$b_log" 2>/dev/null)"

# B's review cycle stands down for it too.
run_node "$b_home" review-cycle.sh >/dev/null 2>&1
assert_eq "a review on another node exits cleanly under the fleet switch" "0" "$?"
assert_contains "and logs a fleet-switch review-stand-down" 'fleet switch' "$(cat "$b_review_log" 2>/dev/null)"

# A re-enables; the fleet flag must actually be gone.
enable_out="$(run_node "$a_home" agent-cycle.sh --enable 2>&1)"
assert_contains "--enable reports the fleet switch clear" "fleet switch clear" "$enable_out"
assert_eq "--enable removes fleet/disabled.json" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"

# A usage limit published by one node stands another node down until resume_at.
fleet_limit_publish "$slug" "$fs_a" "2030-01-01T00:00:00Z" "monthly-spend" true node-a
rm -f "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle under a fleet limit flag exits cleanly" "0" "$?"
assert_contains "and stands down until the flag's resume_at" \
  'usage-limit cooldown until 2030-01-01T00:00:00Z' "$(cat "$b_log" 2>/dev/null)"
rm -f "$gh_backing/fleet/limit.json"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
