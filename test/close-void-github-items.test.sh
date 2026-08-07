#!/usr/bin/env bash
#
# test/close-void-github-items.test.sh — act on a corroborated void by
# closing the GitHub object it names (requirement 34k, issue #240).
#
# What this guards: poetic-fiddle #190/#214 were re-derived void on 7+
# separate cycles and never closed, resurfacing as candidates every time
# because nothing ever touched the object itself. This script's whole job is
# to close it once, on the first cycle that sees the void, and never again.
#
# `gh` is a stub on PATH via SWEEP_GH; no network.
#
# Run directly: ./test/close-void-github-items.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$SCRIPT_DIR/scripts/close-void-github-items.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

stub="$tmp_dir/gh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
S="$SWEEP_STUB_DIR"
printf '%s\n' "$*" >> "$S/calls.log"
args="$*"
case "$args" in
  "api repos/x/y/issues/198 --jq .state")
    [[ -f "$S/issue-198-closed" ]] && echo closed || echo open ;;
  "issue close 198 -R x/y --comment "*)
    [[ -f "$S/fail-close-198" ]] && exit 1
    exit 0 ;;
  "api repos/x/y/issues/199 --jq .state")
    exit 1 ;;
  "api repos/x/y/pulls/205 --jq .state")
    [[ -f "$S/pr-205-closed" ]] && echo closed || echo open ;;
  "pr close 205 -R x/y --comment "*)
    exit 0 ;;
  *)
    echo "stub gh: unexpected call: $args" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub"

run() {  # run STUB_DIR CANDIDATES_JSON
  SWEEP_STUB_DIR="$1" SWEEP_GH="$stub" \
    bash -c "printf '%s' \"\$1\" | \"$SWEEP\" x/y node-1 cycle-1" _ "$2"
}

# --- Case 1: an open void'd issue is closed with the evidence ---------------------
c="$tmp_dir/case1"; mkdir -p "$c"
out="$(run "$c" '[{"item":"198","detail":"already fixed elsewhere","evidence":"see PR #206","stage":"coordinator"}]')"
calls="$(cat "$c/calls.log")"
assert_eq "the issue is closed by the sweep" \
  '{"action":"closed","item":"198","kind":"issue","closed_by":"sweep"}' \
  "$(jq -c 'select(.item == "198")' <<<"$out")"
assert_contains "the close call carries a comment" "issue close 198 -R x/y --comment" "$calls"

# --- Case 1b: an empty `detail` must not swallow the evidence ---------------------
# The three fields cross into the shell as TSV, and bash's `read` collapses
# consecutive tabs even with IFS narrowed to one: an empty middle field would
# shift the evidence into the reason's place and drop it from the comment.
c="$tmp_dir/case1b"; mkdir -p "$c"
out="$(run "$c" '[{"item":"198","detail":"","evidence":"the fix merged in PR #206","stage":"coordinator"}]')"
calls="$(cat "$c/calls.log")"
assert_eq "an empty reason still closes the issue" \
  '{"action":"closed","item":"198","kind":"issue","closed_by":"sweep"}' \
  "$(jq -c 'select(.item == "198")' <<<"$out")"
assert_contains "and the evidence still reaches the comment" \
  "the fix merged in PR #206" "$calls"

# --- Case 2: the object is already closed (a human, or another route) -------------
c="$tmp_dir/case2"; mkdir -p "$c"
touch "$c/issue-198-closed"
out="$(run "$c" '[{"item":"198","detail":"already fixed elsewhere","stage":"coordinator"}]')"
assert_eq "an already-closed issue is reported, not re-closed" \
  '{"action":"closed","item":"198","kind":"issue","closed_by":"already"}' \
  "$(jq -c . <<<"$out")"
assert_eq "no close call was made" "0" \
  "$(grep -c '^issue close' "$c/calls.log" 2>/dev/null)"

# --- Case 3: a void'd obsolete draft pull request is closed ------------------------
c="$tmp_dir/case3"; mkdir -p "$c"
out="$(run "$c" '[{"item":"pr-205-abandoned-abc123","detail":"superseded by #232","stage":"coordinator"}]')"
assert_eq "the pull request is closed" \
  '{"action":"closed","item":"pr-205-abandoned-abc123","kind":"pull-request","number":205,"closed_by":"sweep"}' \
  "$(jq -c . <<<"$out")"

# --- Case 3b: an uncorroborated void acts on nothing -------------------------------
# Only the Co-Ordinator's voids pass requirement 34d's guard before they are
# logged; the Implementor's and the Enabler's are the model's own unexamined
# verdict, and issue #240 scopes this action to a void that survives
# corroboration (WI-7, #243). Until that lands, an open issue named by an
# uncorroborated void must stay exactly as it is — not closed, not read, not
# marked done.
c="$tmp_dir/case3b"; mkdir -p "$c"
out="$(run "$c" '[{"item":"198","detail":"implementor says already done","stage":"implementor"},
                  {"item":"pr-205-abandoned-abc123","detail":"enabler retired it","stage":"enabler"},
                  {"item":"198","detail":"no stage recorded at all"}]')"
assert_eq "an implementor/enabler/stageless void is never actioned" "" "$out"
assert_eq "and gh is never even called for one" "" "$(cat "$c/calls.log" 2>/dev/null || true)"

# --- Case 3c: the corroboration gate must not eat the evidence column --------------
# `stage` rides as a fourth TSV column behind `evidence`; with an empty
# evidence the columns would collapse and the stage read "coordinator" out of
# the wrong field — this pins the alignment guard on both sides.
c="$tmp_dir/case3c"; mkdir -p "$c"
out="$(run "$c" '[{"item":"198","detail":"already fixed elsewhere","evidence":"","stage":"coordinator"}]')"
assert_eq "an empty evidence with a coordinator stage still closes" \
  '{"action":"closed","item":"198","kind":"issue","closed_by":"sweep"}' \
  "$(jq -c 'select(.item == "198")' <<<"$out")"

# --- Case 4: a shape that names no GitHub object is left alone --------------------
c="$tmp_dir/case4"; mkdir -p "$c"
out="$(run "$c" '[{"item":"TD-PPagop-26072401","detail":"voided, register not flipped","stage":"coordinator"}]')"
assert_eq "a register id is never actioned here" "" "$out"
assert_eq "and gh is never even called" "" "$(cat "$c/calls.log" 2>/dev/null || true)"

# --- Case 5: an unreadable object is left alone, not guessed at -------------------
c="$tmp_dir/case5"; mkdir -p "$c"
out="$(run "$c" '[{"item":"199","detail":"unreadable","stage":"coordinator"}]')"
assert_eq "an unreadable issue is a warning, not a close" \
  '{"action":"warning","item":"199","detail":"could not read issue #199 — leaving it alone"}' \
  "$(jq -c . <<<"$out")"

# --- Case 6: the action cap defers the rest ----------------------------------------
c="$tmp_dir/case6"; mkdir -p "$c"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
S="$SWEEP_STUB_DIR"
printf '%s\n' "$*" >> "$S/calls.log"
args="$*"
case "$args" in
  "api repos/x/y/issues/"*" --jq .state") echo open ;;
  "issue close "*) exit 0 ;;
  *) echo "stub gh: unexpected call: $args" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub"
out="$(run "$c" '[{"item":"11","stage":"coordinator"},{"item":"12","stage":"coordinator"},{"item":"13","stage":"coordinator"},{"item":"14","stage":"coordinator"}]')"
assert_eq "closes exactly the per-run cap" "3" \
  "$(jq -c 'select(.action == "closed")' <<<"$out" | wc -l | tr -d ' ')"
assert_eq "and reports the rest as deferred" \
  '{"action":"deferred","remaining":1}' \
  "$(jq -c 'select(.action == "deferred")' <<<"$out")"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
