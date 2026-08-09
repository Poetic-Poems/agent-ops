#!/usr/bin/env bash
#
# test/gather-human-visibility-hygiene.test.sh — regression test for
# scripts/gather-human-visibility-hygiene.sh (requirement 38e): turning a
# still-live human-visibility violation into an ordinary `register-hygiene`
# candidate, or dropping one a live re-check shows has already resolved.
#
# Three behaviours are asserted, and each fails silently if broken:
#
#   - **No violations handed in is `[]`.** The ordinary answer almost every
#     cycle gets — a repo with nothing recently logged against it.
#   - **A violation that still reproduces live becomes exactly one candidate**,
#     `source: "register-hygiene"` (so it is selected, branched and escaped
#     exactly like the register-content candidate gather-register-hygiene.sh
#     emits), with its own `human-visibility-<hash>` ref, never
#     `register-hygiene-<hash>` — the two must never collide or share a block.
#   - **A violation a live re-check shows has resolved is dropped**: a
#     repo-level listing failure whose listing now succeeds, or a pull request
#     that has since merged, closed, or gone to draft. An unreadable re-check
#     is the one exception — kept, not dropped, on the same "never guess a
#     read it could not make was clean" reasoning `sweep-human-visibility.sh`
#     itself uses.
#
# The script is run for real against a stubbed `gh`, so what is asserted is
# the shipped script rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gather-human-visibility-hygiene.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-human-visibility-hygiene.sh"

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

# --- A stub `gh`, answering only `pr list` and `pr view` -------------------
#
# `$STUB_LIST_RC` steers whether the repo-level listing re-check still fails
# (nonzero) or now succeeds (0, the default). `$STUB_PR_STATE`/`$STUB_PR_DRAFT`
# steer a named pull request's live state; `$STUB_VIEW_RC` set nonzero makes
# the re-check itself unreadable, the fail-safe case.
mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-} ${2:-}" in
  "pr list")
    exit "${STUB_LIST_RC:-0}"
    ;;
  "pr view")
    (( "${STUB_VIEW_RC:-0}" == 0 )) || exit "$STUB_VIEW_RC"
    printf '%s\t%s\n' "${STUB_PR_STATE:-OPEN}" "${STUB_PR_DRAFT:-false}"
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

repo_level='[{"repo":"o/a","pr_url":"","detail":"could not list o/a'"'"'s open pull requests — sweeping nothing","ts":"2026-08-08T01:00:00Z"}]'
pr_level='[{"repo":"o/a","pr_url":"https://github.com/o/a/pull/9","detail":"could not request review from foo","ts":"2026-08-08T02:00:00Z"}]'

# --- No input is [] ----------------------------------------------------------
out="$(STUB_LIST_RC=0 "$GATHER" "o/a")"
assert_eq "no violations-json argument is []" "[]" "$out"
out="$(STUB_LIST_RC=0 "$GATHER" "o/a" '[]')"
assert_eq "an empty array is []" "[]" "$out"

# --- Violations for a different repo are ignored ----------------------------
out="$(STUB_LIST_RC=0 "$GATHER" "o/other" "$pr_level")"
assert_eq "violations naming a different repo are ignored" "[]" "$out"

# --- A repo-level violation whose listing still fails survives -------------
out="$(STUB_LIST_RC=1 "$GATHER" "o/a" "$repo_level")"
assert_eq "a still-failing listing survives" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... source is register-hygiene" "register-hygiene" "$(jq -r '.[0].source' <<<"$out")"
assert_eq "  ... ref is scoped to human-visibility, not register-hygiene" \
  "human-visibility-" "$(jq -r '.[0].ref' <<<"$out" | grep -o '^human-visibility-')"
assert_eq "  ... names the repo in its problem line" \
  "1" "$(jq -r '.[0].problems | map(select(startswith("HUMAN VISIBILITY  o/a:"))) | length' <<<"$out")"

# --- A repo-level violation whose listing now succeeds is dropped ----------
out="$(STUB_LIST_RC=0 "$GATHER" "o/a" "$repo_level")"
assert_eq "a resolved listing is dropped" "[]" "$out"

# --- A pull-request violation that is still open and not draft survives ----
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=false "$GATHER" "o/a" "$pr_level")"
assert_eq "a still-open, non-draft pull request survives" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... naming the pull request" \
  "https://github.com/o/a/pull/9" "$(jq -r '.[0].problems[0]' <<<"$out" | grep -o 'https://[^:]*')"

# --- A merged pull request is dropped ---------------------------------------
out="$(STUB_PR_STATE=MERGED STUB_PR_DRAFT=false "$GATHER" "o/a" "$pr_level")"
assert_eq "a merged pull request is dropped" "[]" "$out"

# --- A closed pull request is dropped ---------------------------------------
out="$(STUB_PR_STATE=CLOSED STUB_PR_DRAFT=false "$GATHER" "o/a" "$pr_level")"
assert_eq "a closed pull request is dropped" "[]" "$out"

# --- A pull request now back in draft is dropped ----------------------------
out="$(STUB_PR_STATE=OPEN STUB_PR_DRAFT=true "$GATHER" "o/a" "$pr_level")"
assert_eq "a draft pull request is dropped" "[]" "$out"

# --- An unreadable re-check keeps the violation, fail-safe -----------------
out="$(STUB_VIEW_RC=1 "$GATHER" "o/a" "$pr_level")"
assert_eq "an unreadable re-check keeps the violation" "1" "$(jq 'length' <<<"$out")"

# --- A repo-level and a pull-request violation for the same repo combine ---
both="$(jq -c -n --argjson a "$repo_level" --argjson b "$pr_level" '$a + $b')"
out="$(STUB_LIST_RC=1 STUB_PR_STATE=OPEN STUB_PR_DRAFT=false "$GATHER" "o/a" "$both")"
assert_eq "a repo-level and a pull-request violation combine into one candidate" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... with two problem lines" "2" "$(jq -r '.[0].problems | length' <<<"$out")"

echo
if (( failures == 0 )); then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
