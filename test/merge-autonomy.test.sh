#!/usr/bin/env bash
#
# test/merge-autonomy.test.sh — regression test for lib/merge-autonomy.sh.
#
# Two things worth breaking separately: the config resolution
# (merge_autonomy_configured_level — top-level default, per-repo override,
# same precedence stage_timeouts uses) and the kill switch
# (merge_autonomy_kill_set/_state/_clear, wrapping lib/toggle.sh's generic
# fleet-flag machinery under its own flag name). merge_autonomy_effective_level
# is the one function that combines both, and the acceptance this whole item
# is graded on — "the kill switch flips every repo's effective level to
# `human` and back without a container restart" — is exactly what its own
# assertions below prove: the same process, the same config, flipping only the
# fleet flag between reads.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/merge-autonomy.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/merge-budget.sh
. "$SCRIPT_DIR/lib/merge-budget.sh"
# shellcheck source=lib/merge-autonomy.sh
. "$SCRIPT_DIR/lib/merge-autonomy.sh"

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

# --- merge_autonomy_rank ---

assert_eq "human ranks 0" "0" "$(merge_autonomy_rank human)"
assert_eq "agent-approves ranks 1" "1" "$(merge_autonomy_rank agent-approves)"
assert_eq "agent-merges-routine ranks 2" "2" "$(merge_autonomy_rank agent-merges-routine)"
assert_eq "agent-merges-all ranks 3" "3" "$(merge_autonomy_rank agent-merges-all)"
merge_autonomy_rank bogus >/dev/null 2>&1
assert_eq "an unknown level returns non-zero" "1" "$?"

# --- merge_autonomy_configured_level ---

no_repos_cfg='{}'
assert_eq "no merge_autonomy key anywhere defaults to human" "human" \
  "$(merge_autonomy_configured_level "$no_repos_cfg" "acme/widgets")"

top_level_cfg='{"merge_autonomy": "agent-approves"}'
assert_eq "the top-level key governs a repo with no override" "agent-approves" \
  "$(merge_autonomy_configured_level "$top_level_cfg" "acme/widgets")"

override_cfg='{"merge_autonomy": "agent-approves", "repos": [
  {"slug": "acme/widgets", "merge_autonomy": "agent-merges-all"},
  {"slug": "acme/gizmos"}
]}'
assert_eq "a repo's own override wins over the top-level key" "agent-merges-all" \
  "$(merge_autonomy_configured_level "$override_cfg" "acme/widgets")"
assert_eq "a repo with no override of its own falls through to the top-level key" "agent-approves" \
  "$(merge_autonomy_configured_level "$override_cfg" "acme/gizmos")"
assert_eq "a repo absent from repos[] entirely still falls through to the top-level key" "agent-approves" \
  "$(merge_autonomy_configured_level "$override_cfg" "acme/unlisted")"

# --- The kill switch (fleet flag) ---
#
# The same stub-`gh`-backed-by-a-directory pattern test/toggle.test.sh uses
# for its own fleet-flag assertions, including its GH_STUB_MODE=down branch
# (TD-PPagop-26081507's own assertions below need it to simulate an
# unreachable state repo, same as toggle.test.sh's do).
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
if [[ "${GH_STUB_MODE:-ok}" == "ratelimit" ]]; then
  # agent-ops#1081: fails the call with a rate-limit-shaped refusal the first
  # $(cat ratelimit-fail-count) times, then falls through to the ordinary
  # backing-directory handling below — simulating a transient 403 that
  # clears on a retry, or one that does not, depending on the count a case
  # primes before it calls.
  n_file="${GH_STUB_STATE_DIR:?}/ratelimit-calls"
  n="$(cat "$n_file" 2>/dev/null || printf 0)"
  n=$(( n + 1 ))
  printf '%s' "$n" > "$n_file"
  fail_count="$(cat "${GH_STUB_STATE_DIR:?}/ratelimit-fail-count" 2>/dev/null || printf 0)"
  if (( n <= fail_count )); then
    # The secondary-limit message, deliberately, not the primary one: a
    # primary refusal's own retry asks github_limit_primary_reset_epoch for
    # a fresh snapshot, which reaches the real `gh` binary via `command gh`
    # rather than this stub (see that function's own header) — wrong in a
    # sandboxed test. The secondary wait is fixed
    # (GITHUB_LIMIT_SECONDARY_WAIT_SECONDS) and needs no snapshot at all,
    # the same reason test/approver.test.sh's own #1082 coverage picks it.
    echo "You have exceeded a secondary rate limit. Please wait a few minutes." >&2
    exit 1
  fi
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
if [[ "$path" == repos/*/* && "$path" != */contents/* ]]; then
  # Repo-existence probe (TD-PPagop-26081602): `repos/<repo>`, no
  # `/contents/...`. GH_STUB_MODE=repo-404 simulates a repo missing or
  # invisible to this token — the case a flag file's own 404 alone cannot
  # tell apart from the flag file genuinely not existing.
  if [[ "${GH_STUB_MODE:-ok}" == "repo-404" ]]; then
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
  echo '{}'
  exit 0
fi
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
fs="$tmp_dir/fleet-state"
mkdir -p "$fs"

assert_eq "the kill switch starts clear" "enabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs" | jq -r '.state')"
assert_eq "and merge_autonomy_effective_level reads the configured level" "agent-approves" \
  "$(merge_autonomy_effective_level "$top_level_cfg" "acme/widgets" "$slug" "$fs")"

set_outcome="$(merge_autonomy_kill_set "$slug" "the App is misbehaving" "test-operator pid 1")"
assert_eq "setting the kill switch reports ok" "ok" "$set_outcome"
assert_eq "the flag now reads disabled" "disabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs" | jq -r '.state')"
assert_eq "the record carries the reason" "the App is misbehaving" \
  "$(merge_autonomy_kill_state "$slug" "$fs" | jq -r '.record.reason')"
assert_eq "and a manual kind, never automatic" "manual" \
  "$(merge_autonomy_kill_state "$slug" "$fs" | jq -r '.record.kind')"
assert_eq "and no expiry — a permanent control until explicitly cleared" "null" \
  "$(merge_autonomy_kill_state "$slug" "$fs" | jq -c '.record.expires_at')"

# The acceptance this item is graded on: every repo's effective level flips
# to human while the switch is set, regardless of its own configured level —
# top-level default, per-repo override, or an unlisted repo alike — with
# nothing but the fleet flag changing.
assert_eq "the kill switch forces the top-level-governed repo to human" "human" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/gizmos" "$slug" "$fs")"
assert_eq "and the repo with its own override to agent-merges-all too" "human" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs")"
assert_eq "and an unlisted repo" "human" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/unlisted" "$slug" "$fs")"

clear_outcome="$(merge_autonomy_kill_clear "$slug" "$fs")"
assert_eq "clearing the kill switch reports ok" "ok" "$clear_outcome"
assert_eq "the flag reads clear again" "enabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs" | jq -r '.state')"

# ...and back: every repo's effective level reverts to its own configured
# one, without anything but the fleet flag having changed — no container
# restart, no re-read of config.json needed (the same $override_cfg is
# reused verbatim from before the kill).
assert_eq "restored: the top-level-governed repo reverts to agent-approves" "agent-approves" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/gizmos" "$slug" "$fs")"
assert_eq "restored: the repo with its own override reverts to agent-merges-all" "agent-merges-all" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs")"

clear_again="$(merge_autonomy_kill_clear "$slug" "$fs")"
assert_eq "clearing an already-clear switch reports unconfigured, not failed" "unconfigured" "$clear_again"

# --- issue #513 (PR #506 review follow-up): FRESH bypasses this process's
#     own memo of the kill switch, for a caller that is about to act on the
#     level rather than merely compute with it (run_approver_stage,
#     test/approver-wiring.test.sh's own coverage of the wiring). Simulated
#     here as a hand-edit straight at the backing store — the same device
#     this file already uses for "a human editing through GitHub's web
#     editor" — which bypasses fleet_flag_write/_delete and so leaves this
#     process's own memo of the switch untouched, exactly as a genuinely
#     external kill would. ---
fs_fresh="$tmp_dir/fleet-state-fresh-arg"
mkdir -p "$fs_fresh"
merge_autonomy_kill_state "$slug" "$fs_fresh" >/dev/null # primes the memo: enabled
cat > "$gh_backing/fleet/merge-autonomy-kill.json" <<'EXTERNAL'
{"reason": "an operator kills it from outside this process", "by": "another node", "expires_at": null}
EXTERNAL
assert_eq "an ordinary (non-fresh) read still replays the memoised enabled" "enabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs_fresh" | jq -r '.state')"
assert_eq "a FRESH read sees the externally-set kill immediately, without waiting for a new process" \
  "disabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs_fresh" fresh | jq -r '.state')"
assert_eq "and the fresh answer is written back: a later ordinary read benefits from it too" \
  "disabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs_fresh" | jq -r '.state')"
rm -f "$gh_backing/fleet/merge-autonomy-kill.json"
_fleet_flag_memo_clear "$MERGE_AUTONOMY_KILL_FLAG"

# The same FRESH argument, threaded through merge_autonomy_effective_level —
# a separate state_dir, so the memo it primes cannot be shadowed by the
# assertions just above.
fs_fresh_level="$tmp_dir/fleet-state-fresh-level"
mkdir -p "$fs_fresh_level"
merge_autonomy_effective_level "$top_level_cfg" "acme/widgets" "$slug" "$fs_fresh_level" >/dev/null # primes: agent-approves
cat > "$gh_backing/fleet/merge-autonomy-kill.json" <<'EXTERNAL2'
{"reason": "an operator kills it from outside this process", "by": "another node", "expires_at": null}
EXTERNAL2
assert_eq "without FRESH, merge_autonomy_effective_level still trusts the process memo" \
  "agent-approves" \
  "$(merge_autonomy_effective_level "$top_level_cfg" "acme/widgets" "$slug" "$fs_fresh_level")"
assert_eq "with FRESH, it answers human, seeing the externally-set kill immediately" \
  "human" \
  "$(merge_autonomy_effective_level "$top_level_cfg" "acme/widgets" "$slug" "$fs_fresh_level" fresh)"
rm -f "$gh_backing/fleet/merge-autonomy-kill.json"
_fleet_flag_memo_clear "$MERGE_AUTONOMY_KILL_FLAG"

# --- No state repo: a single-node install is a quiet no-op, same as every
#     other fleet flag lib/toggle.sh defines. ---
assert_eq "with no state_repo the switch reads enabled" "enabled" \
  "$(merge_autonomy_kill_state "" "$tmp_dir/no-fleet" | jq -r '.state')"
assert_eq "and merge_autonomy_effective_level falls through to the configured level" "agent-approves" \
  "$(merge_autonomy_effective_level "$top_level_cfg" "acme/widgets" "" "$tmp_dir/no-fleet")"

# --- TD-PPagop-26081507: an unreachable state repo with no cached copy of
#     the kill switch must fail *closed*, unlike every other fleet flag —
#     this one flag's risk profile inverts once something arms a landing
#     decision on it (see lib/merge-autonomy.sh's own header). An unreachable
#     state repo that *does* have a cached copy still falls back to it,
#     exactly as fleet_disabled_state does. ---

# An established node: kill the switch once while reachable so a cache
# exists holding the "disabled" record (a *clear* flag is never cached —
# there is nothing to cache on a 404 — so this is the only cache content
# a real node can hold).
fs_established="$tmp_dir/fleet-state-established"
mkdir -p "$fs_established"
merge_autonomy_kill_set "$slug" "established-node coverage" "test-operator pid 2" >/dev/null
merge_autonomy_kill_state "$slug" "$fs_established" >/dev/null
assert_eq "an established node with a cached (set) copy falls back to it when unreachable" "disabled" \
  "$(GH_STUB_MODE=down merge_autonomy_kill_state "$slug" "$fs_established" | jq -r '.state')"

# Clear the switch again via a state dir whose cache we no longer need, so
# the remaining assertions start from a known-clear remote without touching
# fs_established's cache (fleet_flag_delete drops the cache of the STATE_DIR
# it is passed, not every node's).
merge_autonomy_kill_clear "$slug" "$fs" >/dev/null

# A fresh node: never fetched successfully, so fleet-cache/ holds nothing at
# all. This is the case the item exists for.
fs_fresh="$tmp_dir/fleet-state-fresh"
mkdir -p "$fs_fresh"
assert_eq "a fresh node with no cache and an unreachable state repo fails the kill switch closed" "disabled" \
  "$(GH_STUB_MODE=down merge_autonomy_kill_state "$slug" "$fs_fresh" | jq -r '.state')"
assert_eq "and merge_autonomy_effective_level answers human regardless of the configured level" "human" \
  "$(GH_STUB_MODE=down merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs_fresh")"
assert_eq "the synthesised record names why, for a human reading --status/doctor.sh" \
  "state repo unreachable and no cached copy" \
  "$(GH_STUB_MODE=down merge_autonomy_kill_state "$slug" "$fs_fresh" | jq -r '.record.reason' | grep -o 'state repo unreachable and no cached copy')"
assert_eq "and names itself fail-closed rather than leaving doctor.sh to infer it from a missing kind" \
  "fail-closed" \
  "$(GH_STUB_MODE=down merge_autonomy_kill_state "$slug" "$fs_fresh" | jq -r '.record.kind // ""')"

# Once reachable again (or once a cache exists), the same fresh node reads
# clear exactly as before — the fail-closed direction is confined to the
# unreachable-with-no-cache case, nothing broader.
assert_eq "a reachable repo confirms clear on that same node once network returns" "enabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs_fresh" | jq -r '.state')"

# --- agent-ops#1081: the RETRY argument ----------------------------------------
# A lone rate-limited refusal is by far the common cause of the fail-closed
# read above (agent-ops#1101's own evidence: six `guard-degraded` events in
# one hour on the same node). RETRY has this function classify whatever it
# just left in $cache.err via github_limit_kind and, only when the cause was
# rate-limiting, wait (github_limit_wait_plan) and ask once more before
# giving up. GITHUB_LIMIT_SECONDARY_WAIT_SECONDS=1 keeps the real `sleep`
# this exercises well under a second, the same device
# test/approver.test.sh's own rate-limit section already uses for
# agent-ops#1082. Both facts a caller needs — whether the retry was actually
# taken, and whether the result is still the fail-closed synthesis — travel
# in the returned document itself (`.retried`, `.record.kind`), never a
# global: see merge_autonomy_kill_state's own header for why.
GITHUB_LIMIT_SECONDARY_WAIT_SECONDS=1
rl_state="$tmp_dir/ratelimit-state"
mkdir -p "$rl_state"
export GH_STUB_STATE_DIR="$rl_state"
reset_ratelimit_stub() {  # <fail-count>
  printf '%s' "$1" > "$rl_state/ratelimit-fail-count"
  rm -f "$rl_state/ratelimit-calls"
  GITHUB_LIMIT_WAITED_SECONDS=0
}

# Primed genuinely set (rather than clear) so the successful retry's GET
# returns real content directly, without the probe-404 mode's own extra
# repo-existence call a 404 would trigger (fleet_flag_fetch_status's own
# header) — keeping this case's own call count to exactly the two kill-flag
# reads the retry contract is about.
merge_autonomy_kill_set "$slug" "primed for the retry-succeeds case" "test-operator pid 4" >/dev/null
fs_retry_ok="$tmp_dir/fleet-state-retry-ok"
mkdir -p "$fs_retry_ok"
reset_ratelimit_stub 1
rl_ok="$(GH_STUB_MODE=ratelimit merge_autonomy_kill_state "$slug" "$fs_retry_ok" fresh retry)"
assert_eq "RETRY: a rate-limited refusal, real content on the retry, resolves disabled" "disabled" \
  "$(jq -r '.state' <<<"$rl_ok")"
assert_eq "  ... carrying the real manual kind, not the fail-closed synthesis" "manual" \
  "$(jq -r '.record.kind // ""' <<<"$rl_ok")"
assert_eq "  ... exactly two fetch attempts were made" "2" "$(cat "$rl_state/ratelimit-calls")"
assert_eq "  ... and the document reports the retry was actually taken" "true" \
  "$(jq -r '.retried' <<<"$rl_ok")"
merge_autonomy_kill_clear "$slug" "$fs" >/dev/null

fs_retry_fail="$tmp_dir/fleet-state-retry-fail"
mkdir -p "$fs_retry_fail"
reset_ratelimit_stub 99
rl_fail="$(GH_STUB_MODE=ratelimit merge_autonomy_kill_state "$slug" "$fs_retry_fail" fresh retry)"
assert_eq "RETRY: still rate-limited after the retry fails closed the same as before" "disabled" \
  "$(jq -r '.state' <<<"$rl_fail")"
assert_eq "  ... names itself fail-closed, distinguishable from a configured/manual human" \
  "fail-closed" "$(jq -r '.record.kind // ""' <<<"$rl_fail")"
assert_eq "  ... exactly two fetch attempts were made, not endless retries" "2" \
  "$(cat "$rl_state/ratelimit-calls")"
assert_eq "  ... and the document still reports the retry was taken" "true" \
  "$(jq -r '.retried' <<<"$rl_fail")"

fs_no_retry="$tmp_dir/fleet-state-no-retry"
mkdir -p "$fs_no_retry"
reset_ratelimit_stub 99
rl_noretry="$(GH_STUB_MODE=ratelimit merge_autonomy_kill_state "$slug" "$fs_no_retry" fresh)"
assert_eq "without RETRY, a rate-limited refusal still fails closed on the first attempt" "disabled" \
  "$(jq -r '.state' <<<"$rl_noretry")"
assert_eq "  ... with no retry attempted at all — unchanged behaviour for every caller but run_approver_stage" \
  "1" "$(cat "$rl_state/ratelimit-calls")"
assert_eq "  ... and the document says so" "false" "$(jq -r '.retried' <<<"$rl_noretry")"

# Not every failure is a rate limit — RETRY must not turn a genuine transport
# failure (the GH_STUB_MODE=down case above) into a retry loop.
fs_down_retry="$tmp_dir/fleet-state-down-retry"
mkdir -p "$fs_down_retry"
rl_down="$(GH_STUB_MODE=down merge_autonomy_kill_state "$slug" "$fs_down_retry" fresh retry)"
assert_eq "RETRY: a non-rate-limit transport failure is not retried" "disabled" \
  "$(jq -r '.state' <<<"$rl_down")"
assert_eq "  ... and the document says no retry was taken" "false" "$(jq -r '.retried' <<<"$rl_down")"

# RETRY threads through merge_autonomy_effective_level too — it still
# returns one word, never a cause, exactly as before (agent-ops#1081's own
# distinguishing behaviour is `run_approver_stage`'s to derive, by asking
# merge_autonomy_kill_state itself, ahead of this function — see
# lib/approver.sh).
fs_retry_level="$tmp_dir/fleet-state-retry-level"
mkdir -p "$fs_retry_level"
reset_ratelimit_stub 1
assert_eq "RETRY threads through merge_autonomy_effective_level too" "agent-approves" \
  "$(GH_STUB_MODE=ratelimit merge_autonomy_effective_level "$top_level_cfg" "acme/widgets" "$slug" "$fs_retry_level" fresh retry)"

fs_retry_level_fail="$tmp_dir/fleet-state-retry-level-fail"
mkdir -p "$fs_retry_level_fail"
reset_ratelimit_stub 99
assert_eq "  ... and a still-fail-closed read leaves the effective level human" "human" \
  "$(GH_STUB_MODE=ratelimit merge_autonomy_effective_level "$top_level_cfg" "acme/widgets" "$slug" "$fs_retry_level_fail" fresh retry)"

unset GH_STUB_STATE_DIR

# --- TD-PPagop-26081602: a repo-level 404 fails closed the same way a
#     transport-unreachable repo does — the contents API cannot tell "the
#     flag file does not exist" from "this repository does not exist, or is
#     invisible to this token", so a misconfigured state_repo slug or a
#     token that lost access to it must not resolve the kill switch as
#     clear. ---

fs_repo404="$tmp_dir/fleet-state-repo404"
mkdir -p "$fs_repo404"
assert_eq "a fresh node behind a repo-level 404, no cache, fails the kill switch closed too" \
  "disabled" \
  "$(GH_STUB_MODE=repo-404 merge_autonomy_kill_state "$slug" "$fs_repo404" | jq -r '.state')"
assert_eq "and merge_autonomy_effective_level answers human, same as a transport failure" "human" \
  "$(GH_STUB_MODE=repo-404 merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs_repo404")"
assert_eq "the synthesised record names itself fail-closed, so doctor.sh can tell it apart from a real kill" \
  "fail-closed" \
  "$(GH_STUB_MODE=repo-404 merge_autonomy_kill_state "$slug" "$fs_repo404" | jq -r '.record.kind // ""')"

# An established node with a cached (set) copy still falls back to it when
# the flag file's own 404 turns out to be the repo going invisible, exactly
# as it does for a transport failure.
fs_established_404="$tmp_dir/fleet-state-established-404"
mkdir -p "$fs_established_404"
merge_autonomy_kill_set "$slug" "established-node repo-404 coverage" "test-operator pid 3" >/dev/null
merge_autonomy_kill_state "$slug" "$fs_established_404" >/dev/null # primes the cache
rm -f "$gh_backing/fleet/merge-autonomy-kill.json" # the remote flag is now gone
assert_eq "an established node's cache survives a repo-level 404 too" "disabled" \
  "$(GH_STUB_MODE=repo-404 merge_autonomy_kill_state "$slug" "$fs_established_404" | jq -r '.state')"
assert_eq "and keeps the real manual kind from its cached copy, not the synthesised one" "manual" \
  "$(GH_STUB_MODE=repo-404 merge_autonomy_kill_state "$slug" "$fs_established_404" | jq -r '.record.kind')"

# The STATUS<TAB>RAW split must not truncate RAW: the flag is a file in the
# state repository, so an operator who set it by hand through GitHub's web
# editor leaves a pretty-printed record behind, and splitting with
# `IFS=$'\t' read` would hand _toggle_eval a lone "{" — still `disabled`, but
# with the operator's own reason replaced by "unreadable disable record" on
# every --status and doctor.sh that reads it.
mkdir -p "$gh_backing/fleet"
cat > "$gh_backing/fleet/merge-autonomy-kill.json" <<'PRETTY'
{
  "disabled_at": "2026-08-15T09:00:00Z",
  "expires_at": null,
  "by": "an operator editing on github.com",
  "reason": "hand-set through the web editor",
  "actor": "operator@laptop",
  "kind": "manual"
}
PRETTY
fs_pretty="$tmp_dir/fleet-state-pretty"
mkdir -p "$fs_pretty"
assert_eq "a hand-edited, pretty-printed flag still reads disabled" "disabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs_pretty" | jq -r '.state')"
assert_eq "and keeps the operator's own reason rather than truncating to line one" \
  "hand-set through the web editor" \
  "$(merge_autonomy_kill_state "$slug" "$fs_pretty" | jq -r '.record.reason')"

# The `kind` marker is what scripts/doctor.sh's report keys on, so the two
# genuine kills that carry no `kind` of their own must not be mistaken for
# the fail-closed synthesis: a hand-written record (nothing obliges an
# operator typing into the web editor to include the field toggle_disable
# would have written) and a garbled one (read as set, deliberately). Either
# reported as "could not be confirmed clear" would send its reader after a
# state-repo outage that is not happening.
#
# Each edit below gets its own fresh state_dir, the same "different node"
# device the rest of this file already uses: fleet_flag_fetch_status now
# memoises a live answer per (flag, state_dir) for this process
# (issue #502), and these edits go straight at $gh_backing —
# bypassing fleet_flag_write, exactly as a human editing on github.com would
# — so a state_dir that already cached the *previous* edit's answer would
# just replay it rather than seeing the new one. A real process picks up a
# hand-edit like this on its next fetch (a fresh process, i.e. next cycle);
# a fresh state_dir here is that same "next reader" for the test.
cat > "$gh_backing/fleet/merge-autonomy-kill.json" <<'MINIMAL'
{"reason": "stop everything now", "by": "an operator in a hurry", "expires_at": null}
MINIMAL
fs_minimal="$tmp_dir/fleet-state-minimal"
mkdir -p "$fs_minimal"
assert_eq "a hand-written record with no kind is still a real kill, not the synthesis" "disabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs_minimal" | jq -r '.state')"
assert_eq "and carries no fail-closed marker, so doctor.sh reports it SET" "" \
  "$(merge_autonomy_kill_state "$slug" "$fs_minimal" | jq -r '.record.kind // ""')"

printf 'not json at all\n' > "$gh_backing/fleet/merge-autonomy-kill.json"
fs_garbled="$tmp_dir/fleet-state-garbled"
mkdir -p "$fs_garbled"
assert_eq "a garbled record reads as set, the same as every other flag lib/toggle.sh evaluates" \
  "disabled" "$(merge_autonomy_kill_state "$slug" "$fs_garbled" | jq -r '.state')"
assert_eq "and carries no fail-closed marker either" "" \
  "$(merge_autonomy_kill_state "$slug" "$fs_garbled" | jq -r '.record.kind // ""')"
rm -f "$gh_backing/fleet/merge-autonomy-kill.json"

# --- merge_autonomy_status_report (#454): the --status headline tells "an
#     operator pulled the lever" (KILLED) apart from "this node cannot
#     confirm the switch is clear" (FAIL-CLOSED), branching on the
#     `record.kind: "fail-closed"` marker exactly as scripts/doctor.sh does.
#     Reporting-only — the effective-level assertions above already pin that
#     both states resolve to human. The block is lifted verbatim out of
#     lib/manage.sh (the same pattern test/approver-wiring.test.sh uses), so
#     these assertions are about the shipped reporter, not a copy of it. ---

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' \
    "$SCRIPT_DIR/lib/manage.sh"
}
status_block="$(extract merge_autonomy_status_report)"
if [[ -z "$status_block" || "$status_block" != *"merge_autonomy_kill_state"* ]]; then
  printf 'FAIL - could not extract merge_autonomy_status_report from lib/manage.sh — has it moved?\n'
  failures=$(( failures + 1 ))
else
  eval "$status_block"
  headline() { head -1 <<<"$1" | awk '{print $2}'; }
  state_repo="$slug"

  # A genuine kill: the operator's own record — headline KILLED, reason and
  # the restore command both present.
  state_dir="$tmp_dir/fleet-state-status-killed"
  mkdir -p "$state_dir"
  merge_autonomy_kill_set "$slug" "status-report coverage" "test-operator" >/dev/null
  out="$(merge_autonomy_status_report)"
  assert_eq "a genuine kill headlines KILLED" "KILLED" "$(headline "$out")"
  assert_eq "  ... carrying the operator's own reason" "status-report coverage" \
    "$(grep -o 'status-report coverage' <<<"$out" | head -1)"
  assert_eq "  ... and pointing at --restore-merge-autonomy" "--restore-merge-autonomy clears it" \
    "$(grep -o '\-\-restore-merge-autonomy clears it' <<<"$out")"

  # A cached set record survives the repo going unreachable: still a real
  # kill, still KILLED (the ambiguity #454 is about is only the no-cache
  # synthesis).
  out="$(GH_STUB_MODE=down merge_autonomy_status_report)"
  assert_eq "a cached set record on an unreachable repo still headlines KILLED" \
    "KILLED" "$(headline "$out")"
  merge_autonomy_kill_clear "$slug" "$state_dir" >/dev/null

  # The fail-closed synthesis: fresh node, no cache, unreachable state repo —
  # a different headline, no KILLED, and no pointer at a restore command
  # that would not help.
  state_dir="$tmp_dir/fleet-state-status-fresh"
  mkdir -p "$state_dir"
  out="$(GH_STUB_MODE=down merge_autonomy_status_report)"
  assert_eq "the unreachable-no-cache synthesis headlines FAIL-CLOSED" \
    "FAIL-CLOSED" "$(headline "$out")"
  assert_eq "  ... never KILLED" "" "$(grep -o 'KILLED' <<<"$out")"
  assert_eq "  ... naming the state repo as the thing to check" \
    "state repo unreachable and no cached copy" \
    "$(grep -o 'state repo unreachable and no cached copy' <<<"$out" | head -1)"
  assert_eq "  ... and not offering --restore-merge-autonomy as the fix" "" \
    "$(grep -o '\-\-restore-merge-autonomy clears it' <<<"$out")"

  # Clear switch, reachable repo: the quiet line.
  out="$(merge_autonomy_status_report)"
  assert_eq "a clear switch reports not killed" "not" "$(headline "$out")"
fi

# --- The per-repo merge-budget freeze (D18 WI-6, lib/merge-budget.sh) caps
#     merge_autonomy_effective_level at agent-approves, never all the way to
#     human — the one place merge_autonomy_effective_level's own behaviour
#     changed for this item. Fresh state dir: the kill-switch assertions
#     above leave the flag clear again, but a fresh cache avoids any doubt. ---
fs_budget="$tmp_dir/fleet-state-budget"
mkdir -p "$fs_budget"

assert_eq "with no freeze set, effective level is unaffected — still the repo's own override" \
  "agent-merges-all" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs_budget")"

freeze_outcome="$(merge_budget_freeze_set "$slug" "acme/widgets" 8 10)"
assert_eq "freezing acme/widgets reports ok" "ok" "$freeze_outcome"
assert_eq "and merge_autonomy_effective_level caps it at agent-approves, not human" \
  "agent-approves" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs_budget")"
assert_eq "a different repo's own level is unaffected — the freeze is per-repo" \
  "agent-approves" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/gizmos" "$slug" "$fs_budget")"

human_cfg='{"merge_autonomy": "human"}'
assert_eq "a frozen repo already configured at human (or agent-approves) is unaffected — the cap only ever lowers" \
  "human" \
  "$(merge_autonomy_effective_level "$human_cfg" "acme/widgets" "$slug" "$fs_budget")"

kill_during_freeze="$(merge_autonomy_kill_set "$slug" "kill wins over a freeze too" "test-operator pid 4")"
assert_eq "setting the kill switch while frozen still reports ok" "ok" "$kill_during_freeze"
assert_eq "the kill switch outranks the freeze — human, not agent-approves" \
  "human" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs_budget")"
merge_autonomy_kill_clear "$slug" "$fs_budget" >/dev/null

freeze_clear_outcome="$(merge_budget_freeze_clear "$slug" "$fs_budget" "acme/widgets")"
assert_eq "clearing the freeze reports ok" "ok" "$freeze_clear_outcome"
assert_eq "and the repo reverts to its own configured level" \
  "agent-merges-all" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs_budget")"

# --- PR #512 review follow-up: FRESH reaches the *freeze* read too, not the
#     kill switch alone. Same device as the kill-switch FRESH assertions
#     above — the record is written straight at the backing store, bypassing
#     fleet_flag_write and so leaving this process's memo of the freeze
#     untouched, exactly as a freeze set by another node would. Without the
#     threading, an arming step promised "the level at the moment of
#     decision" would still act on the memoised pre-freeze answer. ---
fs_freeze_fresh="$tmp_dir/fleet-state-freeze-fresh"
mkdir -p "$fs_freeze_fresh"
freeze_flag_name="$(_merge_budget_freeze_flag_name "acme/widgets")"
assert_eq "primed unfrozen: the repo's own configured level" "agent-merges-all" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs_freeze_fresh")"
cat > "$gh_backing/fleet/$freeze_flag_name.json" <<'EXTERNALFREEZE'
{"disabled_at": "2026-08-17T00:00:00Z", "expires_at": null, "by": "merge-budget governor",
 "reason": "another node's governor froze this repo mid-cycle", "actor": "another node",
 "kind": "anomaly", "cap": 8, "count": 10}
EXTERNALFREEZE
assert_eq "without FRESH, the freeze read replays this process's memo — still unfrozen" \
  "agent-merges-all" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs_freeze_fresh")"
assert_eq "with FRESH, the externally-set freeze binds immediately — capped at agent-approves" \
  "agent-approves" \
  "$(merge_autonomy_effective_level "$override_cfg" "acme/widgets" "$slug" "$fs_freeze_fresh" fresh)"
assert_eq "merge_budget_freeze_state's own FRESH argument does the same directly" "disabled" \
  "$(merge_budget_freeze_state "$slug" "$fs_freeze_fresh" "acme/widgets" fresh | jq -r '.state')"
rm -f "$gh_backing/fleet/$freeze_flag_name.json"
_fleet_flag_memo_clear "$freeze_flag_name"
# A repository at agent-approves or below never fetches the freeze at all, so
# FRESH must not make it start: the rank check still short-circuits first.
assert_eq "a repo configured at agent-approves stays there under FRESH, freeze unread" \
  "agent-approves" \
  "$(merge_autonomy_effective_level "$top_level_cfg" "acme/widgets" "$slug" "$fs_freeze_fresh" fresh)"

echo
if (( failures == 0 )); then
  echo "All merge-autonomy assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
