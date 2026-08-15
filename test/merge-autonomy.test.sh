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

# Once reachable again (or once a cache exists), the same fresh node reads
# clear exactly as before — the fail-closed direction is confined to the
# unreachable-with-no-cache case, nothing broader.
assert_eq "a reachable repo confirms clear on that same node once network returns" "enabled" \
  "$(merge_autonomy_kill_state "$slug" "$fs_fresh" | jq -r '.state')"

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
assert_eq "the synthesised record carries no manual kind, so doctor.sh can tell it apart from a real kill" \
  "" \
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
rm -f "$gh_backing/fleet/merge-autonomy-kill.json"

echo
if (( failures == 0 )); then
  echo "All merge-autonomy assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
