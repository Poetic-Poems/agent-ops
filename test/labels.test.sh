#!/usr/bin/env bash
#
# test/labels.test.sh — self-contained regression test for lib/labels.sh
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 6a).
#
# The two failure directions are not alike, and only one of them is loud:
#
#   - **Too shy** is what this requirement exists to fix, and it is silent: a
#     label that does not exist means the projection onto an item quietly does
#     not happen, the pipeline carries on, and the human never sees the signal.
#     So every label the product applies is asserted to be created when absent,
#     for each of the three roles a repository can play.
#   - **Too eager** is the new risk it introduces. Creating a label that is
#     already there is refused by GitHub and would be reported as a failure;
#     *modifying* one that is already there would silently undo an operator's
#     own colour and description on a schedule, every cycle, for as long as
#     nobody noticed. So this asserts not only that existing labels are left
#     alone but that no request other than a listing and a create is ever
#     issued at all.
#
# `gh` is stubbed, recording every invocation, so the assertions are about the
# requests the library actually makes rather than about a copy of its logic.
# No network is used and nothing is created anywhere real.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/labels.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"

SCHEMA="$SCRIPT_DIR/config.schema.json"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# --- The stub. `LABELS_GH` is the seam lib/labels.sh leaves for exactly this.
#     It reproduces the two calls the library makes and the shapes GitHub
#     answers them with: a listing, and a create that refuses a duplicate. ---
cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [[ "$1" == "api" && "$2" == "-X" && "$3" == "POST" ]]; then
  name=""
  for arg in "$@"; do [[ "$arg" == name=* ]] && name="${arg#name=}"; done
  # The failure the caller must survive: a token without permission to create.
  if [[ -n "${GH_REFUSE_CREATE:-}" ]] && grep -qxF "$name" <<<"$GH_REFUSE_CREATE"; then
    echo "gh: HTTP 403" >&2
    exit 1
  fi
  # A duplicate is refused, exactly as GitHub refuses one.
  if grep -qixF "$name" "$GH_LABELS"; then
    echo "gh: HTTP 422 already_exists" >&2
    exit 1
  fi
  printf '%s\n' "$name" >> "$GH_LABELS"
  exit 0
fi
if [[ "$1" == "api" && "$2" == repos/*/labels ]]; then
  [[ -n "${GH_LIST_FAILS:-}" ]] && { echo "gh: HTTP 404" >&2; exit 1; }
  cat "$GH_LABELS"
  exit 0
fi
echo "stub gh: unexpected invocation: $*" >&2
exit 64
STUB
chmod +x "$tmp/gh"
export LABELS_GH="$tmp/gh"

reset_stub() {
  : > "$tmp/labels"
  : > "$tmp/log"
  export GH_LABELS="$tmp/labels" GH_LOG="$tmp/log"
  unset GH_REFUSE_CREATE GH_LIST_FAILS
  [[ $# -eq 0 ]] || printf '%s\n' "$@" > "$tmp/labels"
}

config() { jq "${1:-.}" "$SCRIPT_DIR/config.json" > "$tmp/config.json"; }

# --- The catalogue: what each role needs, and the names coming from config
#     rather than from this library. ---
config
assert_eq "the target role wants every label the pipeline applies" \
  "autonomous-agent enabler-escalation needs-refinement refined unvoided blocked obsolete complexity:low complexity:medium complexity:high" \
  "$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the review role wants only the caller's resolved review pull request label" \
  "project-review" \
  "$(labels_catalogue "$tmp/config.json" "$SCHEMA" review "project-review" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the review role wants nothing when no label is passed (project_review's pr_label is resolved per repo, not read from config)" \
  "" \
  "$(labels_catalogue "$tmp/config.json" "$SCHEMA" review | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the review role reflects whatever resolved label the caller passes, e.g. a repo's own project_review override" \
  "custom-review-label" \
  "$(labels_catalogue "$tmp/config.json" "$SCHEMA" review "custom-review-label" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the escalation role wants only the escalation label" \
  "enabler-escalation" \
  "$(labels_catalogue "$tmp/config.json" "$SCHEMA" escalation | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "an unknown role wants nothing" "" \
  "$(labels_catalogue "$tmp/config.json" "$SCHEMA" nonsense)"

config '.pr_label = "house-agent" | .unvoid_label = "reopen-please"'
assert_eq "a renamed label is created under the name the config gives it" \
  "house-agent reopen-please" \
  "$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | cut -f1 | grep -E 'house-agent|reopen-please' | tr '\n' ' ' | sed 's/ $//')"

# An empty label is the documented way to switch a projection off. Creating one
# anyway would put a label in the repository that nothing will ever apply.
config '.needs_refinement_label = "" | .unvoid_label = "" | .refined_label = ""'
assert_eq "a label switched off by an empty value is not created" \
  "autonomous-agent enabler-escalation blocked obsolete complexity:low complexity:medium complexity:high" \
  "$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | cut -f1 | tr '\n' ' ' | sed 's/ $//')"

# Every catalogue entry must be complete: a create with an empty colour is
# rejected by GitHub, and one with an empty description is merely useless.
config
incomplete="$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | awk -F'\t' 'NF != 3 || $2 == "" || $3 == "" {print $1}')"
assert_eq "every catalogue entry carries a colour and a description" "" "$incomplete"

# --- Ensuring: create what is absent, touch nothing else. ---
config
reset_stub
out="$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | labels_ensure "Owner/repo")"
assert_eq "an empty repository gets every label, each reported created" \
  "autonomous-agent enabler-escalation needs-refinement refined unvoided blocked obsolete complexity:low complexity:medium complexity:high" \
  "$(cut -f2 <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and every line reports a creation" "" \
  "$(grep -v '^created' <<<"$out")"

# The steady state, which is every cycle after the first: nothing to say.
out="$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | labels_ensure "Owner/repo")"
assert_eq "a second pass over the same repository reports nothing" "" "$out"

reset_stub autonomous-agent blocked obsolete complexity:low complexity:medium complexity:high
out="$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | labels_ensure "Owner/repo")"
assert_eq "a partly-labelled repository gets only what it is missing" \
  "enabler-escalation needs-refinement refined unvoided" \
  "$(cut -f2 <<<"$out" | tr '\n' ' ' | sed 's/ $//')"

# GitHub compares label names case-insensitively, so a differently-cased match
# is the same label; trying to create it would be refused as a duplicate and
# reported as a failure that is really a success.
reset_stub Autonomous-Agent BLOCKED
out="$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | labels_ensure "Owner/repo")"
assert_eq "a label that differs only in case is treated as present" "" \
  "$(cut -f2 <<<"$out" | grep -ixE 'autonomous-agent|blocked')"

# --- The property that protects an operator's own work. ---
reset_stub autonomous-agent
labels_catalogue "$tmp/config.json" "$SCHEMA" target | labels_ensure "Owner/repo" >/dev/null
assert_eq "an existing label is never modified — no PATCH, PUT or DELETE is issued" "" \
  "$(grep -E '(^|[[:space:]])-X[[:space:]]+(PATCH|PUT|DELETE)' "$tmp/log" || true)"
assert_eq "and the only requests made are listings and creates" "" \
  "$(grep -vE '^api (repos/[^ ]+/labels --paginate|-X POST repos/[^ ]+/labels )' "$tmp/log" || true)"

# --- Failure: reported, never fatal. ---
reset_stub
export GH_REFUSE_CREATE="unvoided"
out="$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | labels_ensure "Owner/repo")"
rc=$?
assert_eq "a label the token may not create is reported failed" \
  "failed	unvoided" "$(grep '^failed' <<<"$out")"
assert_eq "and the labels either side of it are still created" \
  "autonomous-agent enabler-escalation needs-refinement refined blocked obsolete complexity:low complexity:medium complexity:high" \
  "$(grep '^created' <<<"$out" | cut -f2 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and one refused create does not fail the pass" "0" "$rc"

reset_stub
export GH_LIST_FAILS=1
out="$(labels_catalogue "$tmp/config.json" "$SCHEMA" target | labels_ensure "Owner/repo")"
rc=$?
assert_eq "a repository whose labels cannot be listed returns 1" "1" "$rc"
assert_eq "and says nothing rather than claiming failures it did not observe" "" "$out"
assert_eq "and creates nothing" "0" "$(grep -c 'POST' "$tmp/log" || true)"
unset GH_LIST_FAILS

# A caller must be able to run this under `set -e` without the failure path
# taking the cycle down with it — every call site guards, and this proves the
# guard is what makes it safe rather than luck.
reset_stub
probe="$(GH_LIST_FAILS=1 bash -euo pipefail -c '
  source "'"$SCRIPT_DIR"'/lib/config-schema.sh"
  source "'"$SCRIPT_DIR"'/lib/labels.sh"
  echo before
  labels_ensure_role "'"$tmp"'/config.json" "'"$SCHEMA"'" "Owner/repo" target >/dev/null 2>&1 || true
  echo after
' 2>/dev/null || true)"
assert_eq "a guarded call survives a total failure under set -e" \
  "before after" "$(tr '\n' ' ' <<<"$probe" | sed 's/ $//')"

reset_stub
assert_eq "an empty repository slug is refused rather than guessed at" "1" \
  "$(labels_ensure "" </dev/null >/dev/null 2>&1; echo $?)"

echo
if (( failures == 0 )); then
  echo "All labels assertions passed."
  exit 0
else
  echo "$failures labels assertion(s) FAILED."
  exit 1
fi
