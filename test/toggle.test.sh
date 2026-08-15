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
# The offline e2e section below also covers `agent-cycle.sh --kill-merge-
# autonomy`/`--restore-merge-autonomy` (D18, requirement 2.3b): a third fleet
# flag built on this file's own `fleet_flag_*` machinery, exercised here
# rather than in test/merge-autonomy.test.sh because the CLI harness — the
# node/log/gh-backing scaffolding — already lives in this file for the switch
# and the limit flag, and a third flag reusing the identical mechanism does
# not earn a second copy of it. lib/merge-autonomy.sh's own config-resolution
# and kill-switch unit coverage is test/merge-autonomy.test.sh's job.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/toggle.test.sh
#
# Exit status is 0 iff every assertion passed.

# lib/toggle.sh declares `local state_dir="$1"` in each of its functions, and
# this file happens to call them with a global of the same name. Reading them
# together, shellcheck takes the locals for writes to our global and warns that
# the writes are lost in the command substitutions they happen in — but there
# is no write: every one is a `local`, and this file only ever reads its own.
# shellcheck disable=SC2031

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

# --- toggle_parse_until ---

assert_eq "an absolute timestamp in the future" \
  "2026-07-17T16:00:00Z" "$(toggle_parse_until "2026-07-17T16:00:00Z")"
assert_eq "a GNU date -d string, not just ISO-8601" \
  "2026-07-17T16:00:00Z" "$(toggle_parse_until "2026-07-17 16:00:00 UTC")"

toggle_parse_until "not a date" >/dev/null 2>&1
assert_eq "an unparseable --until is an error, not a guess" "64" "$?"

toggle_parse_until "2026-07-17T10:00:00Z" >/dev/null 2>&1
assert_eq "a --until already in the past is an error" "64" "$?"

# The examples --help and the unparseable-timestamp error advertise must
# themselves parse. An example that errors is worse than no example, because
# it is precisely what a hurried operator copies — and GNU date has no `noon`
# keyword, so the obvious-looking 'tomorrow noon' is not one of them.
for example in "2026-08-10 18:00" "tomorrow 12:00"; do
  toggle_parse_until "$example" >/dev/null 2>&1
  assert_eq "the advertised example '$example' actually parses" "0" "$?"
done

# --- toggle_resolve_disable_spec ---

assert_eq "only --for given passes through unchanged" \
  "2h" "$(toggle_resolve_disable_spec "2h" "" 4)"

# Only --until given: the resulting spec must still resolve, through
# toggle_parse_ttl, to the instant --until named.
assert_eq "only --until given resolves to that instant via toggle_parse_ttl" \
  "2026-07-17T16:00:00Z" \
  "$(toggle_parse_ttl "$(toggle_resolve_disable_spec "" "2026-07-17T16:00:00Z" 4)" 4)"

# Both given, --for later (20:00 vs 16:00): --for's own spec wins outright.
assert_eq "both given, --for is the later deadline: --for wins" \
  "8h" "$(toggle_resolve_disable_spec "8h" "2026-07-17T16:00:00Z" 4 2>/dev/null)"
resolve_stderr="$(toggle_resolve_disable_spec "8h" "2026-07-17T16:00:00Z" 4 2>&1 >/dev/null)"
assert_eq "picking --for over --until is announced on stderr" \
  "1" "$(grep -c 'both --for and --until' <<<"$resolve_stderr")"

# Both given, --until later (20:00 vs 14:00): resolves to --until's instant.
assert_eq "both given, --until is the later deadline: --until wins" \
  "2026-07-17T20:00:00Z" \
  "$(toggle_parse_ttl "$(toggle_resolve_disable_spec "2h" "2026-07-17T20:00:00Z" 4 2>/dev/null)" 4)"
resolve_stderr="$(toggle_resolve_disable_spec "2h" "2026-07-17T20:00:00Z" 4 2>&1 >/dev/null)"
assert_eq "picking --until over --for is announced on stderr" \
  "1" "$(grep -c 'both --for and --until' <<<"$resolve_stderr")"

# Both given, --for forever: indefinite always outlasts a named instant.
assert_eq "both given, --for forever always wins" \
  "forever" "$(toggle_resolve_disable_spec "forever" "2026-08-01T00:00:00Z" 4 2>/dev/null)"

toggle_resolve_disable_spec "2h" "not a date" 4 >/dev/null 2>&1
assert_eq "both given, an unparseable --until fails" "64" "$?"

toggle_resolve_disable_spec "4hours" "2026-07-17T20:00:00Z" 4 >/dev/null 2>&1
assert_eq "both given, an unparseable --for fails" "64" "$?"

# --- Setting and reading the switch ---

record="$(toggle_disable "$state_dir" "editing lib/toggle.sh" "2h" 4 "tester pid 1")"
assert_eq "disable writes the reason" "editing lib/toggle.sh" "$(jq -r '.reason' <<<"$record")"
assert_eq "disable stamps the expiry from the spec" \
  "2026-07-17T14:00:00Z" "$(jq -r '.expires_at' <<<"$record")"
assert_eq "disable records who set it" "tester pid 1" "$(jq -r '.by' <<<"$record")"
assert_eq "disable records a manual kind by default" "manual" "$(jq -r '.kind' <<<"$record")"
assert_eq "disable derives the actor when none is given" \
  "$(toggle_actor)" "$(jq -r '.actor' <<<"$record")"
assert_eq "a set switch reads as disabled" "disabled" "$(state_of)"

# --- toggle_actor (#244): attribution, never "unknown" ---
# The record's actor is what tells a reader whose decision a stand-down was;
# `unknown@<container-id>` is exactly the reading requirement 2.3 forbids.
assert_eq "NODE_NAME names the actor outright" "node-x" \
  "$(NODE_NAME=node-x bash -c ". '$SCRIPT_DIR/lib/toggle.sh'; toggle_actor")"
actor_no_user="$(env -u USER -u NODE_NAME bash -c ". '$SCRIPT_DIR/lib/toggle.sh'; toggle_actor")"
assert_eq "with no USER at all the actor is still someone, never unknown" "0" \
  "$([[ -n "$actor_no_user" && "$actor_no_user" != unknown* ]] && echo 0 || echo 1)"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
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

delete_word="$(fleet_flag_delete "$slug" "$fs_b" disabled)"
assert_eq "deleting a set flag succeeds" "0" "$?"
assert_eq "and reports that it actually deleted something (issue #426)" "deleted" "$delete_word"
assert_eq "the flag is gone from the repo" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
assert_eq "a successful delete drops the local cache too" "0" \
  "$(test -f "$(fleet_cache_file "$fs_b" disabled)" && echo 1 || echo 0)"
delete_word="$(fleet_flag_delete "$slug" "$fs_b" disabled)"
assert_eq "deleting an absent flag is already-clear, not an error" "0" "$?"
assert_eq "and reports there was nothing to delete, distinctly from a real delete (issue #426)" \
  "absent" "$delete_word"
GH_STUB_MODE=down fleet_flag_delete "$slug" "$fs_b" disabled >/dev/null
assert_eq "an unreachable repo must NOT report the flag cleared" "1" "$?"

assert_eq "fleet_flag_delete_outcome maps a real delete to ok" "ok" \
  "$(fleet_flag_write "$slug" disabled "$rec" "set for the outcome test" \
     && fleet_flag_delete_outcome "$slug" "$fs_b" disabled)"
assert_eq "and an already-absent flag to unconfigured, not ok" "unconfigured" \
  "$(fleet_flag_delete_outcome "$slug" "$fs_b" disabled)"
assert_eq "and an unreachable repo to failed" "failed" \
  "$(fleet_flag_write "$slug" disabled "$rec" "set for the outcome test" \
     && GH_STUB_MODE=down fleet_flag_delete_outcome "$slug" "$fs_b" disabled)"
fleet_flag_delete "$slug" "$fs_b" disabled >/dev/null

assert_eq "fleet_flag_write_outcome maps a real write to ok" "ok" \
  "$(fleet_flag_write_outcome "$slug" disabled "$rec" "set for the outcome test")"
fleet_flag_delete "$slug" "$fs_b" disabled >/dev/null
assert_eq "and no state repo to unconfigured" "unconfigured" \
  "$(fleet_flag_write_outcome "" disabled "$rec" "set for the outcome test")"
assert_eq "and an unreachable repo to failed" "failed" \
  "$(GH_STUB_MODE=down fleet_flag_write_outcome "$slug" disabled "$rec" "set for the outcome test")"

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

# The published record attributes itself (#244): an automatic kind, the node
# as actor, and the API response that justified the write as evidence.
fleet_limit_publish "$slug" "$fs_b" "2026-07-17T20:00:00Z" "monthly-spend" false node-b \
  "HTTP 429: You've hit your monthly spend limit"
assert_eq "a publish carries its evidence" \
  "HTTP 429: You've hit your monthly spend limit" \
  "$(fleet_flag_fetch "$slug" "$fs_a" limit | jq -r '.evidence')"
assert_eq "and records an automatic kind with the node as actor" "auto/node-b" \
  "$(fleet_flag_fetch "$slug" "$fs_a" limit | jq -r '"\(.kind)/\(.actor)"')"
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
  # DASHBOARD_GH_CMD: agent-cycle.sh's --disable/--enable/--clear-limit/
  # --kill-merge-autonomy/--restore-merge-autonomy paths all end in
  # refresh_dashboard(), which shells out to publish-dashboard.sh as a
  # separate process — TOGGLE_GH's PATH-independent stub reaches every other
  # `gh` call this section makes, but not that one, since publish-dashboard.sh
  # resolves `gh` through this seam instead of PATH (see its own PATH comment).
  # Left unset, that call reaches the real `gh` and the real network the rest
  # of this section is built to avoid (TD-PPagop-26080701). $stub_bin/gh's
  # unconditional `exit 1` is exactly the "fail fast" this offline e2e wants.
  env HOME="$home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$home")" \
    PATH="$stub_bin:$PATH" TOGGLE_GH="$gh_stub" GH_STUB_BACKING="$gh_backing" \
    DASHBOARD_GH_CMD="$stub_bin/gh" \
    CLAIM_GH=/bin/false STATE_SYNC_REMOTE="$state_remote" \
    GIT_USER_NAME="Test Node" GIT_USER_EMAIL="test-node@example.invalid" \
    "$SCRIPT_DIR/$script" "$@"
}

a_home="$(new_home fleet-node-a)"
b_home="$(new_home fleet-node-b)"
a_log="$a_home/.local/state/poetic-agents/log.jsonl"
b_log="$b_home/.local/state/poetic-agents/log.jsonl"
b_review_log="$b_home/.local/state/poetic-agents/review-log.jsonl"

# A disables; the flag must land in the state repo, not just locally.
disable_out="$(run_node "$a_home" agent-cycle.sh --disable "fleet e2e halt" --for forever 2>&1)"
assert_contains "--disable reports the fleet switch set" "fleet switch set" "$disable_out"
assert_eq "--disable publishes fleet/disabled.json" "1" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
# The published record attributes itself (#244): the node that set it, never
# `unknown`, and the manual kind that tells a probe to keep its hands off.
assert_eq "the fleet switch names the node that set it" "fleet-node-a" \
  "$(jq -r '.actor' "$gh_backing/fleet/disabled.json")"
assert_eq "and records a manual kind" "manual" \
  "$(jq -r '.kind' "$gh_backing/fleet/disabled.json")"
# Requirement 33 (issue #426): the `disabled` event records the scope the
# operator asked for and the outcome of reaching the fleet flag, so a reader
# can tell a fleet-wide stop from a node-scoped one without cross-referencing
# fleet/disabled.json.
assert_contains "and the disabled event carries fleet scope" '"scope":"fleet"' \
  "$(cat "$a_log" 2>/dev/null)"
assert_contains "and reports the fleet flag write as ok" '"fleet_flag":"ok"' \
  "$(cat "$a_log" 2>/dev/null)"

# A second --disable over the live switch is an extension, and the log says
# so rather than presenting a fresh stop.
run_node "$a_home" agent-cycle.sh --disable "fleet e2e halt, extended" --for forever >/dev/null 2>&1
assert_contains "re-disabling records the switch it extends" '"extends"' \
  "$(cat "$a_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"

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
assert_contains "and the enabled event carries fleet scope" '"scope":"fleet"' \
  "$(cat "$a_log" 2>/dev/null)"
assert_contains "and reports the fleet flag delete as ok" '"fleet_flag":"ok"' \
  "$(cat "$a_log" 2>/dev/null)"

# Requirement 33 (issue #426, acceptance 4): a node with no local disable of
# its own must still log `enabled` when a live fleet flag it clears — the
# defect this closes let the fleet coming back up go unlogged whenever the
# node running --enable had no local record to report.
rec_fleet_only="$(jq -nc '{disabled_at: "2026-07-17T09:00:00Z", expires_at: null, by: "operator@laptop pid 1", reason: "another node froze the fleet", actor: "operator@laptop", kind: "manual"}')"
fleet_flag_write "$slug" disabled "$rec_fleet_only" "fleet freeze set by another node"
assert_eq "no local record on A going into this scenario" "0" \
  "$(test -f "$a_home/.local/state/poetic-agents/disabled.json" && echo 1 || echo 0)"
rm -f "$a_log"
no_local_enable_out="$(run_node "$a_home" agent-cycle.sh --enable 2>&1)"
assert_contains "--enable still reports the fleet switch clear with no local record" \
  "fleet switch clear" "$no_local_enable_out"
assert_contains "and logs enabled even though there was nothing local to clear" \
  '"event":"enabled"' "$(cat "$a_log" 2>/dev/null)"
assert_contains "naming the fleet scope" '"scope":"fleet"' "$(cat "$a_log" 2>/dev/null)"
assert_contains "and the fleet flag outcome as ok" '"fleet_flag":"ok"' "$(cat "$a_log" 2>/dev/null)"

# --- --this-node (issue #379): a node-scoped stand-down that never touches
# the fleet flag -------------------------------------------------------------

# Reset the log so the scope/fleet_flag assertions below read only this
# block's own event, not the fleet-scoped ones the sections above logged.
rm -f "$a_log"

# `--disable --this-node` writes only the local record and never publishes
# the fleet flag.
this_disable_out="$(run_node "$a_home" agent-cycle.sh --disable "editing lib/" --this-node --for 1h 2>&1)"
assert_contains "--disable --this-node says plainly only this node stands down" \
  "only" "$this_disable_out"
assert_not_contains "--disable --this-node never reports the fleet switch set" \
  "fleet switch set" "$this_disable_out"
assert_eq "--disable --this-node writes the local record" "1" \
  "$(test -f "$a_home/.local/state/poetic-agents/disabled.json" && echo 1 || echo 0)"
assert_eq "--disable --this-node writes no fleet flag" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
assert_contains "and the disabled event carries node scope, not fleet" \
  '"scope":"node"' "$(cat "$a_log" 2>/dev/null)"
assert_not_contains "and carries no fleet_flag outcome at all" \
  '"fleet_flag"' "$(cat "$a_log" 2>/dev/null)"

# `--status` has to say which of the two levels is down and which command
# lifts it (requirement 2.3) — an operator who finds a node stopped learns
# nothing from "DISABLED" alone. Here only the local record is set.
local_only_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports the node-scoped switch as disabled" \
  "switch:   DISABLED" "$local_only_status"
assert_contains "and reports no fleet switch alongside it" \
  "fleet:    not set" "$local_only_status"
assert_contains "naming --enable --this-node as what clears it" \
  "--enable --this-node clears it" "$local_only_status"

# A peer is unaffected: no fleet flag was ever set, so its own cycle runs.
# (The log is reset first: it still carries the fleet-switch stand-downs the
# earlier block in this file logged, before that flag was cleared.)
rm -f "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a peer's cycle is unaffected by another node's --this-node disable" "0" "$?"
assert_not_contains "and does not stand the peer down" \
  '"event":"stand-down"' "$(cat "$b_log" 2>/dev/null)"

# `--enable --this-node` must leave a fleet flag someone else set alone: the
# local record is this node's own decision to undo, the fleet flag is not.
rec_fleet="$(jq -nc '{disabled_at: "2026-07-17T10:00:00Z", expires_at: null, by: "operator@laptop pid 1", reason: "fleet freeze", actor: "operator@laptop", kind: "manual"}')"
fleet_flag_write "$slug" disabled "$rec_fleet" "fleet freeze for the test"
rm -f "$a_log"
enable_this_out="$(run_node "$a_home" agent-cycle.sh --enable --this-node 2>&1)"
assert_not_contains "--enable --this-node does not claim the fleet switch cleared" \
  "fleet switch clear" "$enable_this_out"
assert_eq "--enable --this-node leaves the fleet flag set" "1" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
assert_eq "--enable --this-node clears the local record" "0" \
  "$(test -f "$a_home/.local/state/poetic-agents/disabled.json" && echo 1 || echo 0)"
assert_contains "and the enabled event carries node scope even with a live fleet flag" \
  '"scope":"node"' "$(cat "$a_log" 2>/dev/null)"
assert_not_contains "and never claims a fleet_flag outcome it never touched" \
  '"fleet_flag"' "$(cat "$a_log" 2>/dev/null)"

# The mirror image of the `--status` case above: the fleet flag alone is set,
# so what this node needs told is that a plain `--enable` is the one that
# lifts it, and that nothing local is holding it down as well.
fleet_only_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports a fleet switch this node did not set" \
  "fleet:    DISABLED" "$fleet_only_status"
assert_contains "carrying the record's own reason" "fleet freeze" "$fleet_only_status"
assert_contains "and says this node adds no node-scoped disable of its own" \
  "no node-scoped disable of its own" "$fleet_only_status"
assert_contains "so a plain --enable resumes the whole fleet" \
  "every node resumes" "$fleet_only_status"

# A node carrying both a node-scoped disable and the (still-set) fleet switch
# stays down when only the node-scoped one is cleared.
run_node "$a_home" agent-cycle.sh --disable "editing again" --this-node --for 1h >/dev/null 2>&1

# With both set, `--status` has to spell out the asymmetry rather than
# reporting two disables and leaving the operator to guess which `--enable`
# undoes which — the case the distinction exists for.
both_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status under both switches reports the node-scoped one" \
  "switch:   DISABLED" "$both_status"
assert_contains "and the fleet one beside it" "fleet:    DISABLED" "$both_status"
assert_contains "saying --enable clears both" "--enable clears both" "$both_status"
assert_contains "and that --enable --this-node leaves the node down under the fleet switch" \
  "leaving the fleet switch" "$both_status"

rm -f "$a_log"
run_node "$a_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a node under both switches exits cleanly" "0" "$?"
assert_contains "and stands down for its own node-scoped switch first" \
  '"reason":"disabled:' "$(cat "$a_log" 2>/dev/null)"

run_node "$a_home" agent-cycle.sh --enable --this-node >/dev/null 2>&1
rm -f "$a_log"
run_node "$a_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "clearing only the node-scoped switch still exits cleanly" "0" "$?"
assert_contains "but the node still stands down, now for the fleet switch" \
  'fleet switch' "$(cat "$a_log" 2>/dev/null)"

# Clean up the fleet flag this block set, so the baseline the rest of this
# file assumes ("nothing set" going into the limit tests below) still holds.
fleet_flag_delete "$slug" "$fs_a" disabled >/dev/null

# A node-scoped disable still expires on its own TTL, exactly like the fleet
# one — --this-node changes only which levels a write reaches, never how a
# record already written decides it has lapsed.
TOGGLE_NOW_EPOCH=1784289600 run_node "$a_home" agent-cycle.sh --disable "editing" --this-node --for 1h >/dev/null 2>&1
rm -f "$a_log"
TOGGLE_NOW_EPOCH=$(( 1784289600 + 3900 )) run_node "$a_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle past a node-scoped disable's TTL exits cleanly" "0" "$?"
assert_contains "and the expired node-scoped disable is cleared and logged" \
  '"detail":"disable expired"' "$(cat "$a_log" 2>/dev/null)"
assert_eq "the local record is gone once it has expired" "0" \
  "$(test -f "$a_home/.local/state/poetic-agents/disabled.json" && echo 1 || echo 0)"
# Requirement 33 (issue #426): the two automatic-expiry sites fold into the
# same scope/fleet_flag vocabulary the --disable/--enable command paths use —
# this one only ever touches the local record, so it is node-scoped and
# carries no fleet_flag at all.
assert_contains "and the expiry event carries node scope" \
  '"scope":"node"' "$(cat "$a_log" 2>/dev/null)"
assert_not_contains "and no fleet_flag outcome, since only the local record was touched" \
  '"fleet_flag"' "$(cat "$a_log" 2>/dev/null)"

# The fleet-level counterpart: a fleet-wide disable past its TTL is cleared by
# whichever node's cycle sees it first, and that clear now reports whether the
# fleet flag delete actually succeeded (defect 3 in issue #426 — the old code
# discarded fleet_flag_delete's result with `|| true`).
rec_fleet_ttl="$(jq -nc '{disabled_at: "2026-07-17T11:00:00Z", expires_at: "2026-07-17T12:00:00Z", by: "operator@laptop pid 1", reason: "fleet TTL test", actor: "operator@laptop", kind: "manual"}')"
fleet_flag_write "$slug" disabled "$rec_fleet_ttl" "fleet freeze for the expiry test"
rm -f "$a_log"
TOGGLE_NOW_EPOCH=$(( 1784289600 + 4 * 3600 )) run_node "$a_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle past a fleet-wide disable's TTL exits cleanly" "0" "$?"
assert_contains "and the expired fleet disable is cleared and logged" \
  '"detail":"fleet disable expired"' "$(cat "$a_log" 2>/dev/null)"
assert_contains "carrying fleet scope" '"scope":"fleet"' "$(cat "$a_log" 2>/dev/null)"
assert_contains "and reporting the delete as ok" '"fleet_flag":"ok"' "$(cat "$a_log" 2>/dev/null)"
assert_eq "the fleet flag is actually gone, not just locally forgotten" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"

# --this-node is a modifier on --disable/--enable only.
this_status_out="$(run_node "$a_home" agent-cycle.sh --status --this-node 2>&1)"
assert_eq "--this-node with --status is a usage error" "64" "$?"
assert_contains "and says so" "only modifies --disable or --enable" "$this_status_out"

# --- `scope` (requirement 2.3): the local half of a fleet-wide --disable is a
# mirror, not a second decision ----------------------------------------------
#
# An unmodified --disable writes both levels, so the node that issues a
# fleet-wide stand-down ends up holding a local record byte-identical to a
# --this-node one. Untagged, every reader announced a node-scoped disable
# nobody had asked for, and that one node of a uniformly-down fleet wore the
# dashboard's amber `disabled` badge while its equally-stopped peers wore none.

a_switch="$a_home/.local/state/poetic-agents/disabled.json"

run_node "$a_home" agent-cycle.sh --disable "resize the VM" --for forever >/dev/null 2>&1
assert_eq "an unmodified --disable tags its local record as a fleet mirror" "fleet" \
  "$(jq -r '.scope' "$a_switch" 2>/dev/null)"
assert_eq "and still publishes the fleet flag" "1" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"

assert_eq "and caches the flag it just wrote, like a successful fetch would" "1" \
  "$(test -f "$a_home/.local/state/poetic-agents/fleet-cache/disabled.json" && echo 1 || echo 0)"

mirror_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status names the local record as this fleet switch's mirror" \
  "mirrors this fleet switch" "$mirror_status"
assert_not_contains "and never reports it as a second, node-scoped disable" \
  "also carries its own node-scoped disable" "$mirror_status"

# The writer must not be the one node blind to a flag it set: with the state
# repo unreachable it reads its own cache and still reports the fleet switch,
# rather than falling through this level's fail-open to the orphan wording
# below — which would tell an operator mid-outage that the switch they had
# just set had been cleared.
export GH_STUB_MODE=down
offline_mirror_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
unset GH_STUB_MODE
assert_contains "an unreachable state repo still reports the fleet switch from cache" \
  "fleet:    DISABLED" "$offline_mirror_status"
assert_not_contains "and never mistakes an outage for a switch cleared elsewhere" \
  "has since been cleared" "$offline_mirror_status"

# The mirror is this node's fail-*closed* hold on itself for exactly the window
# where the fleet flag cannot be read — that flag fails open — so clearing it
# under a live fleet switch is how a node resumes the work the fleet was stood
# down to prevent. --enable --this-node must refuse rather than oblige.
mirror_enable_out="$(run_node "$a_home" agent-cycle.sh --enable --this-node 2>&1)"
assert_eq "--enable --this-node refuses a fleet mirror" "64" "$?"
assert_contains "naming plain --enable as what undoes a fleet-wide disable" \
  "Use --enable" "$mirror_enable_out"
assert_eq "and leaves the mirror in place" "1" \
  "$(test -f "$a_switch" && echo 1 || echo 0)"

# The orphan, and the reason the tag is worth carrying: --enable on a *peer*
# clears the fleet flag but cannot reach this node's file, so this node alone
# stays down under a decision lifted elsewhere — indefinitely, on `--for
# forever`. Untagged it read as a node-scoped disable nobody had set.
run_node "$b_home" agent-cycle.sh --enable >/dev/null 2>&1
assert_eq "a peer's --enable clears the fleet flag" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
orphan_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports a surviving mirror as a cleared switch's leftover" \
  "mirrors a fleet switch that has since been cleared" "$orphan_status"
assert_contains "and names --enable as what clears it" \
  "--enable clears it" "$orphan_status"

run_node "$a_home" agent-cycle.sh --enable >/dev/null 2>&1
assert_eq "--enable clears the orphaned mirror" "0" \
  "$(test -f "$a_switch" && echo 1 || echo 0)"

# A --disable whose fleet publish fails leaves this node standing down alone,
# so the optimistic `fleet` tag has to be corrected: a record still claiming to
# mirror a switch that was never set would have --status and the dashboard
# describe a fleet-wide stand-down that does not exist.
export GH_STUB_MODE=down
run_node "$a_home" agent-cycle.sh --disable "fleet write will fail" --for 1h >/dev/null 2>&1
unset GH_STUB_MODE
assert_eq "a failed fleet publish retags the local record node-scoped" "node" \
  "$(jq -r '.scope' "$a_switch" 2>/dev/null)"
assert_eq "leaving its disabled_at as first written" "2026-07-17T12:00:00Z" \
  "$(jq -r '.disabled_at' "$a_switch" 2>/dev/null)"
assert_eq "and no fleet flag was published" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
run_node "$a_home" agent-cycle.sh --enable --this-node >/dev/null 2>&1
assert_eq "--enable --this-node clears that one, since it is genuinely node-scoped" "0" \
  "$(test -f "$a_switch" && echo 1 || echo 0)"

# The deliberate single-node case is unchanged, and travels to peers: a card
# rendering another node's switch has to be able to tell the two apart, and
# only the node holding the record knows which it is.
run_node "$a_home" agent-cycle.sh --disable "editing lib/" --this-node --for 1h >/dev/null 2>&1
assert_eq "--disable --this-node tags its record node-scoped" "node" \
  "$(jq -r '.scope' "$a_switch" 2>/dev/null)"
assert_eq "and toggle_switch_summary carries the scope to peers" "node" \
  "$(jq -r '.scope' <<<"$(toggle_switch_summary "$a_home/.local/state/poetic-agents")")"

# A record written before the field existed reads as node-scoped: what such a
# record effectively was, and the direction that keeps a node down rather than
# talking itself out of a stand-down.
jq -c 'del(.scope)' "$a_switch" > "$tmp_dir/legacy-switch.json" && mv "$tmp_dir/legacy-switch.json" "$a_switch"
assert_eq "a record with no scope reads as node-scoped" "node" \
  "$(toggle_scope "$(jq -c '.record // {}' <<<"$(toggle_state "$a_home/.local/state/poetic-agents")")")"
assert_eq "and toggle_switch_summary defaults it the same way" "node" \
  "$(jq -r '.scope' <<<"$(toggle_switch_summary "$a_home/.local/state/poetic-agents")")"

# Back to the baseline the limit tests below assume: nothing set at either level.
run_node "$a_home" agent-cycle.sh --enable >/dev/null 2>&1

# A usage limit published by one node stands another node down until resume_at.
fleet_limit_publish "$slug" "$fs_a" "2030-01-01T00:00:00Z" "monthly-spend" true node-a
rm -f "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle under a fleet limit flag exits cleanly" "0" "$?"
assert_contains "and stands down until the flag's resume_at" \
  'usage-limit cooldown until 2030-01-01T00:00:00Z' "$(cat "$b_log" 2>/dev/null)"

# --- --clear-limit (2.1a) -------------------------------------------------
# The stand-down must have a supported exit. It arrives on two carriers and
# lifts only when BOTH are retired, so this exercises both at once: the flag
# published by node A above, and a limit-hit in B's own log — the carrier no
# amount of flag-deleting can reach, and the one that made a stand-down
# outlive the limit that caused it.
printf '%s\n' \
  '{"ts":"2026-01-01T00:00:00Z","cycle":"seed","node":"node-b","event":"limit-hit","resume_at":"2030-06-01T00:00:00Z","class":"monthly","reset_known":false}' \
  >> "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_contains "a limit-hit in the node's own log also stands it down" \
  'usage-limit cooldown' "$(cat "$b_log" 2>/dev/null)"

clear_out="$(run_node "$b_home" agent-cycle.sh --clear-limit "cap raised" 2>&1)"
assert_contains "--clear-limit reports what it lifted" "stand-down lifted" "$clear_out"
assert_contains "--clear-limit reports the fleet flag cleared" "fleet usage-limit flag clear" "$clear_out"
assert_eq "--clear-limit removes fleet/limit.json" "0" \
  "$(test -f "$gh_backing/fleet/limit.json" && echo 1 || echo 0)"
assert_contains "--clear-limit logs a limit-cleared event" \
  '"event":"limit-cleared"' "$(cat "$b_log" 2>/dev/null)"
assert_contains "recording the reason it was given" 'cap raised' "$(cat "$b_log" 2>/dev/null)"

# And the proof it was worth doing: the next cycle no longer stands down for
# the limit. The log is NOT truncated first — the superseded limit-hit must
# still be sitting in it, or this asserts nothing. Only the events the new
# cycle appends are examined.
b_log_before="$(wc -l < "$b_log")"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle after --clear-limit exits cleanly" "0" "$?"
assert_contains "the superseded limit-hit is still in the log" \
  '2030-06-01T00:00:00Z' "$(cat "$b_log" 2>/dev/null)"
assert_not_contains "and the cycle no longer stands down for the usage limit" \
  'usage-limit cooldown' "$(tail -n +$(( b_log_before + 1 )) "$b_log" 2>/dev/null)"
rm -f "$gh_backing/fleet/limit.json"

# --- --kill-merge-autonomy / --restore-merge-autonomy (D18, requirement 2.3b) ---
# A third fleet flag, independent of the switch and the limit above: killing
# merge autonomy must publish its own file under its own name and must not
# touch fleet/disabled.json or fleet/limit.json (both already confirmed clear
# by this point in the run).
kill_out="$(run_node "$a_home" agent-cycle.sh --kill-merge-autonomy "Approver App misbehaving" 2>&1)"
assert_contains "--kill-merge-autonomy reports the switch set" \
  "merge-autonomy kill switch set" "$kill_out"
assert_eq "--kill-merge-autonomy publishes fleet/merge-autonomy-kill.json" "1" \
  "$(test -f "$gh_backing/fleet/merge-autonomy-kill.json" && echo 1 || echo 0)"
assert_eq "the record names the actor that set it" "fleet-node-a" \
  "$(jq -r '.actor' "$gh_backing/fleet/merge-autonomy-kill.json")"
assert_eq "and records a manual kind" "manual" \
  "$(jq -r '.kind' "$gh_backing/fleet/merge-autonomy-kill.json")"
assert_eq "and the reason given" "Approver App misbehaving" \
  "$(jq -r '.reason' "$gh_backing/fleet/merge-autonomy-kill.json")"
assert_eq "neither the fleet switch nor the limit flag is touched" "0 0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo -n 1 || echo -n 0)$(printf ' ')$(test -f "$gh_backing/fleet/limit.json" && echo -n 1 || echo -n 0)"
assert_contains "the merge-autonomy-killed event is logged" \
  '"event":"merge-autonomy-killed"' "$(cat "$a_log" 2>/dev/null)"

status_out="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports the kill switch set" "merge_autonomy: KILLED" "$status_out"
assert_contains "  ... naming what clears it" "--restore-merge-autonomy clears it" "$status_out"

restore_out="$(run_node "$a_home" agent-cycle.sh --restore-merge-autonomy 2>&1)"
assert_contains "--restore-merge-autonomy reports the switch cleared" \
  "merge-autonomy kill switch cleared" "$restore_out"
assert_eq "--restore-merge-autonomy removes fleet/merge-autonomy-kill.json" "0" \
  "$(test -f "$gh_backing/fleet/merge-autonomy-kill.json" && echo 1 || echo 0)"
assert_contains "the merge-autonomy-restored event is logged" \
  '"event":"merge-autonomy-restored"' "$(cat "$a_log" 2>/dev/null)"

status_out2="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports the kill switch clear again" "merge_autonomy: not killed" "$status_out2"

# A required reason, the same terms as --disable's.
bare_kill_out="$(run_node "$a_home" agent-cycle.sh --kill-merge-autonomy 2>&1)"
bare_kill_rc=$?
assert_eq "--kill-merge-autonomy with no reason is a usage error" "64" "$bare_kill_rc"
assert_contains "naming what is missing" "needs a reason" "$bare_kill_out"

# Restoring an already-clear switch is a normal, idempotent outcome.
already_clear_out="$(run_node "$a_home" agent-cycle.sh --restore-merge-autonomy 2>&1)"
# Captured here, not after the assert_contains below: assert_contains always
# returns 0 (it counts a failure rather than returning one), so reading `$?`
# after it would compare 0 against 0 and assert nothing at all.
already_clear_rc=$?
assert_contains "--restore-merge-autonomy on an already-clear switch says so" \
  "was not set" "$already_clear_out"
assert_eq "and exits cleanly" "0" "$already_clear_rc"

rm -f "$gh_backing/fleet/merge-autonomy-kill.json"

# --- A manual fleet/limit.json is honoured, never probed (#244) -----------
# An operator's stand-down is a decision, not an inference: the cycle must
# stand down naming the actor and the manual kind, must not spend a probe on
# it, and must not clear it.
jq -n '{resume_at: "2030-03-01T00:00:00Z", class: "other", reset_known: false,
        node: "operator", actor: "warwick@laptop", kind: "manual",
        ts: "2026-08-12T00:00:00Z"}' > "$gh_backing/fleet/limit.json"
rm -f "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle under a manual limit flag exits cleanly" "0" "$?"
assert_contains "a manual stand-down names its actor and kind" \
  'manual stand-down until 2030-03-01T00:00:00Z, set by warwick@laptop' \
  "$(cat "$b_log" 2>/dev/null)"
assert_not_contains "a manual stand-down is never probed" \
  '(probe:' "$(cat "$b_log" 2>/dev/null)"
assert_not_contains "and never auto-cleared" \
  '"event":"limit-cleared"' "$(cat "$b_log" 2>/dev/null)"
assert_eq "the manual flag survives the cycle" "1" \
  "$(test -f "$gh_backing/fleet/limit.json" && echo 1 || echo 0)"
rm -f "$gh_backing/fleet/limit.json"

# --- A long-running automatic freeze attempts its escalation (#244) -------
# The seeded hit is months old with no limit-cleared after it, so the freeze
# is far past `limit_escalate_after_hours`. Offline, `gh` fails fast, so the
# attempt surfaces as the warning naming the freeze's start — which is the
# assertion: the escalation fired, and a manual stand-down (above) never
# reached it.
printf '%s\n' \
  '{"ts":"2026-01-01T00:00:00Z","cycle":"seed","node":"node-b","event":"limit-hit","resume_at":"2030-06-01T00:00:00Z","class":"monthly","reset_known":false}' \
  > "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle under a stale automatic freeze exits cleanly" "0" "$?"
assert_contains "the freeze escalation is attempted and its failure recorded" \
  'automatic usage-limit freeze since 2026-01-01T00:00:00Z' \
  "$(cat "$b_log" 2>/dev/null)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
