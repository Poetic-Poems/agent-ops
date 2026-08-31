#!/usr/bin/env bash
#
# test/sweep-inline-refinement-specs.test.sh — regression test for
# `scripts/sweep-inline-refinement-specs.sh`'s selection (agent-ops#1128).
#
# The sweep posts public comments to real issues, so what it selects is the
# whole safety story: a false positive writes a comment nobody asked for, and a
# false negative leaves kilobytes in the band requirement 4i cannot shed. The
# three exclusions are asserted here directly — an entry that already has a
# pointer, an entry whose item has no thread to post to, and an entry belonging
# to another repository — together with the idempotence that falls out of the
# first of them.
#
# `sweep_candidates` is lifted out of the script the way
# test/coordinator-refinements.test.sh lifts its own, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
# ./test/sweep-inline-refinement-specs.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$SCRIPT_DIR/scripts/sweep-inline-refinement-specs.sh"

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

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

block="$(extract_block '^sweep_candidates\(\) \{' '^\}$' "$SWEEP")"
if [[ -z "$block" || "$block" != *'jq'* ]]; then
  echo "FAIL - could not extract sweep_candidates from $SWEEP — has it moved?" >&2
  exit 1
fi
eval "$block"

refinements='{
  "o/r": {
    "101": {"ts": "t", "cycle": "c", "spec": "STRANDED-101"},
    "102": {"ts": "t", "cycle": "c", "spec": "STRANDED-102"},
    "103": {"ts": "t", "cycle": "c", "comment_url": "https://example/103"},
    "104": {"ts": "t", "cycle": "c", "comment_url": "https://example/104", "spec": "PAIRED-104"},
    "TD-PPagop-26081407": {"ts": "t", "cycle": "c", "spec": "NO-THREAD"},
    "pr-202-abandoned-71f7e8b9e663": {"ts": "t", "cycle": "c", "spec": "ALSO-NO-THREAD"}
  },
  "o/other": {
    "201": {"ts": "t", "cycle": "c", "spec": "OTHER-REPO"}
  }
}'

out="$(sweep_candidates "$refinements" "o/r")"

assert_eq "only the stranded issue entries are selected" "101 102" \
  "$(jq -rs 'map(.item) | sort | join(" ")' <<<"$out")"
assert_eq "the spec travels with the item it belongs to" "STRANDED-101" \
  "$(jq -rs 'map(select(.item == "101")) | .[0].spec' <<<"$out")"
assert_eq "an entry that already has a pointer is left alone" "0" \
  "$(jq -rs 'map(select(.item == "103")) | length' <<<"$out")"
assert_eq "…and so is one whose payload already sits beside a pointer" "0" \
  "$(jq -rs 'map(select(.item == "104")) | length' <<<"$out")"
assert_eq "an item with no thread to post to is never selected" "0" \
  "$(jq -rs 'map(select(.item | test("^[0-9]+$") | not)) | length' <<<"$out")"
assert_eq "another repository's stranded entry is not swept by this run" "0" \
  "$(jq -rs 'map(select(.spec == "OTHER-REPO")) | length' <<<"$out")"
assert_eq "that entry is selected when its own repo is swept" "201" \
  "$(sweep_candidates "$refinements" "o/other" | jq -rs 'map(.item) | join(" ")')"

# Idempotence: a second run reads a ledger in which the swept entries have
# become pointers, and selects nothing.
after="$(jq -c '."o/r"."101" = {"ts":"t2","cycle":"c2","comment_url":"https://example/101"}
              | ."o/r"."102" = {"ts":"t2","cycle":"c2","comment_url":"https://example/102"}' \
          <<<"$refinements")"
assert_eq "a second run over an already-swept ledger selects nothing" "0" \
  "$(sweep_candidates "$after" "o/r" | grep -c . || true)"

# Degradation: neither a malformed ledger nor an unknown repo may abort a
# script that is mid-way through posting comments.
assert_eq "a malformed ledger yields no candidates rather than an error" "0" \
  "$(sweep_candidates 'not json' "o/r" | grep -c . || true)"
assert_eq "a repo the ledger does not name yields no candidates" "0" \
  "$(sweep_candidates "$refinements" "o/absent" | grep -c . || true)"

# --- Read the union, append to a node's own log -------------------------------
#
# The two logs are different files and the script must not let them be
# confused. A per-cycle union log is rebuilt every cycle and deleted with its
# cycle directory, so a pointer appended there is discarded before anything
# reads it — and the payload it was meant to supersede survives, which is a
# silent no-op dressed as a successful sweep. Refusing that one case is what
# stops the sweep reporting 81 entries moved and moving none.

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
: > "$tmp_dir/.fleet-log.jsonl"

out="$(bash "$SWEEP" o/r "$tmp_dir/.fleet-log.jsonl" 2>&1)"; rc=$?
assert_eq "a per-cycle union log with no --append-to is refused" "2" "$rc"
case "$out" in
  *"rebuilt every cycle"*) assert_eq "…and the refusal says why" "yes" "yes" ;;
  *)                       assert_eq "…and the refusal says why" "yes" "no ($out)" ;;
esac

out="$(bash "$SWEEP" --append-to "$tmp_dir/log.jsonl" o/r "$tmp_dir/.fleet-log.jsonl" 2>&1)"; rc=$?
assert_eq "…and is accepted once an append target is named" "0" "$rc"

# An ordinary log is not second-guessed: a node sweeping its own log is the
# shape the default exists for.
: > "$tmp_dir/log.jsonl"
out="$(bash "$SWEEP" o/r "$tmp_dir/log.jsonl" 2>&1)"; rc=$?
assert_eq "an ordinary log needs no --append-to" "0" "$rc"

# --- The comment wears the pipeline's envelope --------------------------------
#
# Every write this system makes lands under the maintainer's own GitHub
# account (lib/pipeline-marker.sh), so the visible header is the only thing
# telling a human reading the thread that the pipeline wrote this, and the
# invisible marker is the only thing telling gather-abandoned-drafts.sh the
# same. A sweep posting 81 bare specifications would read, to both, as the
# maintainer suddenly hand-specifying 81 issues in one minute.

assert_eq "the sweep sources the marker library rather than spelling the strings out" "yes" \
  "$(grep -q 'lib/pipeline-marker.sh' "$SWEEP" && echo yes || echo no)"
assert_eq "the comment body opens with the visible header" "yes" \
  "$(grep -q 'pipeline_comment_header script' "$SWEEP" && echo yes || echo no)"
# shellcheck disable=SC2016  # the pattern is the script's literal source text, not an expansion
assert_eq "…and closes with the invisible marker" "yes" \
  "$(grep -q 'pipeline_comment_marker "\$sweep_cycle_id" script' "$SWEEP" && echo yes || echo no)"

# The rendered article, not just its ingredients: header first (GitHub
# truncates the middle of a long comment, never the top) and marker last.
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
rendered="$(printf '%s\n\n%s\n\n%s\n' \
  "$(pipeline_comment_header script node-x)" "PROSE" "$(pipeline_comment_marker c script)")"
# shellcheck disable=SC2016  # the backticks are literal Markdown in the header, not command substitution — the same disable lib/pipeline-marker.sh carries over the line that prints them
assert_eq "the rendered header names the Script and the node" "yes" \
  "$(head -n1 <<<"$rendered" | grep -q '^\*\*Script\*\* · autonomous pipeline · node `node-x`$' && echo yes || echo no)"
assert_eq "the rendered marker carries the detection prefix" "yes" \
  "$(tail -n1 <<<"$rendered" | grep -qF "$PIPELINE_COMMENT_MARKER_PREFIX" && echo yes || echo no)"

# --- What was selected is not what moved ---------------------------------------
#
# An issue that is closed, deleted or unreadable is skipped, correctly — but
# the first cut of this script counted it as moved anyway, so a sweep that
# left 2 of 81 payloads exactly where they were reported all 81 as moved out
# of the band. That is the same false-success the script exists to undo, so
# the two counts are asserted apart here, through a stubbed `gh`.

stub_dir="$tmp_dir/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
# issue view <n> ... -> OPEN for 101, CLOSED for 102
# issue comment <n> ... -> a comment URL
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
  case "$3" in 102) echo CLOSED ;; *) echo OPEN ;; esac
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
  echo "https://github.com/o/r/issues/$3#issuecomment-1"
  exit 0
fi
exit 0
STUB
chmod +x "$stub_dir/gh"

cat >"$tmp_dir/two.jsonl" <<'LOG'
{"ts":"t1","cycle":"c","node":"n","event":"item-refined","repo":"o/r","item":"101","spec":"AAAA"}
{"ts":"t1","cycle":"c","node":"n","event":"item-refined","repo":"o/r","item":"102","spec":"BBBBBB"}
LOG

out="$(PATH="$stub_dir:$PATH" bash "$SWEEP" --apply o/r "$tmp_dir/two.jsonl" 2>&1)"
assert_eq "the summary counts what moved against what was selected" "yes" \
  "$(grep -q '1 of 2 entr(ies) moved, 4 of 10 bytes' <<<"$out" && echo yes || echo "no ($out)")"
assert_eq "…and says the remainder was left where it was" "yes" \
  "$(grep -q '1 entr(ies) were left where they were' <<<"$out" && echo yes || echo no)"
assert_eq "the closed issue is named as skipped" "yes" \
  "$(grep -q "o/r#102: not an open issue (state 'CLOSED')" <<<"$out" && echo yes || echo no)"
assert_eq "only the open issue got a pointer event appended" "1" \
  "$(grep -c '"by":"sweep"' "$tmp_dir/two.jsonl")"
assert_eq "…and it names the issue that was actually posted to" "101" \
  "$(grep '"by":"sweep"' "$tmp_dir/two.jsonl" | jq -r .item)"

printf '\n%s\n' "$( (( failures == 0 )) && echo "All assertions passed." || echo "$failures assertion(s) failed." )"
exit $(( failures > 0 ))
