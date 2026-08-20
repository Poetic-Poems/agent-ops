#!/usr/bin/env bash
#
# test/detect-classifier-escapes.test.sh — regression test for
# scripts/detect-classifier-escapes.sh (D18 Stage 2 exit criterion "zero
# classifier escapes"; agent-ops#572): the independent, post-hoc classifier-
# escape detector.
#
# Two halves:
#
#   - The reimplemented protected-path list and routine-sources resolution
#     (`_escape_audit_is_protected`/`_escape_audit_routine_sources`, lifted
#     verbatim out of the script the same way test/landing-retry-sweep.test.sh
#     lifts `_landing_retry_sweep_repo` out of agent-cycle.sh) are pinned
#     byte-for-byte identical to lib/landing.sh's own
#     `_landing_is_protected`/`_landing_routine_sources`, over the same
#     battery of inputs — so the two can drift apart in the same PR without
#     it drifting *silently*, even though the detector deliberately never
#     sources lib/landing.sh at all (the issue's own Refiner comment: "read
#     there for the exact logic this detector must reproduce independently
#     (not call into)").
#   - The script itself, invoked as a subprocess against a stubbed `gh`
#     (PATH-prepended, the same technique test/mine-merge-history.test.sh
#     uses): a merged pull request whose merge commit touches a protected
#     path is an injected known escape, and must be caught; one whose three
#     recomputed inputs all agree is clean; each of the ways an input can
#     fail to reconstruct is unverifiable, never clean; a pull request
#     merged by anyone other than the passed-in Approver login is not
#     audited at all; and a pull request already carrying an audit event in
#     the log is skipped before any further `gh` call.
#
# Run directly:
#
#   ./test/detect-classifier-escapes.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$SCRIPT_DIR/scripts/detect-classifier-escapes.sh"

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
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual: %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# =============================================================================
# Part 1: the reimplemented constants, pinned against lib/landing.sh's own,
# never sourced from it.
# =============================================================================

extract() {  # <function name> <file>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$2"
}

is_protected_block="$(extract _escape_audit_is_protected "$DETECTOR")"
[[ -n "$is_protected_block" ]] || { echo "FAIL - could not extract _escape_audit_is_protected from $DETECTOR — has it moved?" >&2; exit 1; }
eval "$is_protected_block"

routine_sources_block="$(extract _escape_audit_routine_sources "$DETECTOR")"
[[ -n "$routine_sources_block" ]] || { echo "FAIL - could not extract _escape_audit_routine_sources from $DETECTOR — has it moved?" >&2; exit 1; }
eval "$routine_sources_block"

# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/landing.sh
. "$SCRIPT_DIR/lib/landing.sh"

for path in ".github/workflows/ci.yml" "deploy/docker/Dockerfile" "prompts/implementor.md" \
            "lib/landing.sh" "config.schema.json" "config.json" "agent-cycle.sh" \
            "review-cycle.sh" "CODEOWNERS" \
            "README.md" "scripts/detect-classifier-escapes.sh" "test/landing.test.sh" \
            "libfoo.sh" "deploying.txt" ".github" "githubby/file.txt"; do
  landing_rc=0; escape_rc=0
  _landing_is_protected "$path" || landing_rc=$?
  _escape_audit_is_protected "$path" || escape_rc=$?
  assert_eq "protected-path verdict for '$path' matches lib/landing.sh's own" \
    "$landing_rc" "$escape_rc"
done

for cfg in '{"repos":[]}' \
           '{"repos":[{"slug":"acme/widgets","merge_autonomy_routine_sources":["issues"]}]}' \
           '{"merge_autonomy_routine_sources":["register-hygiene"]}' \
           '{}'; do
  landing_out="$(_landing_routine_sources "$cfg" "acme/widgets")"
  escape_out="$(_escape_audit_routine_sources "$cfg" "acme/widgets")"
  assert_eq "routine-sources resolution for config '$cfg' matches lib/landing.sh's own" \
    "$landing_out" "$escape_out"
done

# =============================================================================
# Part 2: the script itself, subprocess, against a stubbed gh.
# =============================================================================

mkdir -p "$tmp_dir/bin"
STUB_DIR="$tmp_dir/fixtures"
mkdir -p "$STUB_DIR"

cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args=("$@")
f="$STUB_DIR"

jqfilter=""
prev=""
for a in "${args[@]}"; do
  [[ "$prev" == "--jq" ]] && jqfilter="$a"
  prev="$a"
done
apply() {
  if [[ -n "$jqfilter" ]]; then jq -c "$jqfilter" "$1" 2>/dev/null; else cat "$1"; fi
}

if [[ "${args[0]:-}" == "api" && "${args[1]:-}" == repos/*/issues && "${args[*]}" == *"state=closed"* ]]; then
  [[ -f "$f/issues-fail" ]] && exit 1
  apply "$f/issues.json"; exit 0
fi
if [[ "${args[0]:-}" == "api" && "${args[1]:-}" == repos/*/pulls/* ]]; then
  n="${args[1]##*/}"
  [[ -f "$f/pr-$n-fail" ]] && exit 1
  apply "$f/pr-$n.json" || exit 1
  exit 0
fi
if [[ "${args[0]:-}" == "api" && "${args[1]:-}" == repos/*/commits/* ]]; then
  sha="${args[1]##*/}"
  [[ -f "$f/commit-$sha-fail" ]] && exit 1
  apply "$f/commit-$sha.json" || exit 1
  exit 0
fi
if [[ "${args[0]:-}" == "api" && "${args[1]:-}" == repos/*/issues/*/events ]]; then
  n=$(sed -E 's#.*/issues/([0-9]+)/events#\1#' <<<"${args[1]}")
  [[ -f "$f/events-$n-fail" ]] && exit 1
  apply "$f/events-$n.json" || exit 1
  exit 0
fi
echo "gh-stub: unhandled invocation: ${args[*]}" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin/gh"
export STUB_DIR PATH="$tmp_dir/bin:$PATH"
export ESCAPE_AUDIT_RETRY_DELAY_SECONDS=0

config_file="$tmp_dir/config.json"
echo '{"repos":[]}' > "$config_file"

SLUG="acme/widgets"
LOGIN="pullwright-approver[bot]"

# --- Fixture set: five candidate pull requests -------------------------------
#
#   #1  merged by the Approver, merge commit touches lib/landing.sh (a
#       protected path) and README.md, complexity:low at merge, source
#       recorded as tech-debt in the log — an injected known escape.
#   #2  merged by the Approver, merge commit touches only scripts/foo.sh,
#       complexity:medium at merge, source register-hygiene — clean.
#   #3  merged by the Approver, but the merge commit's own file list is
#       unreadable (simulates "too large to enumerate") — unverifiable.
#   #4  merged by the Approver, two complexity:* labels standing at merge
#       (ambiguous) — unverifiable.
#   #5  merged by someone else entirely (a human's own manual merge) — not
#       audited at all: no output line for it.
cat > "$STUB_DIR/issues.json" <<EOF
[{"number": 1, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 2, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 3, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 4, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 5, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}}]
EOF

pr_json() {  # <number> <merged_by>
  cat <<EOF
{"merged": true, "merged_by": {"login": "$2"},
 "html_url": "https://github.com/$SLUG/pull/$1",
 "merged_at": "2026-08-20T10:00:00Z", "merge_commit_sha": "sha$1"}
EOF
}
pr_json 1 "$LOGIN" > "$STUB_DIR/pr-1.json"
pr_json 2 "$LOGIN" > "$STUB_DIR/pr-2.json"
pr_json 3 "$LOGIN" > "$STUB_DIR/pr-3.json"
pr_json 4 "$LOGIN" > "$STUB_DIR/pr-4.json"
pr_json 5 "a-human" > "$STUB_DIR/pr-5.json"

cat > "$STUB_DIR/commit-sha1.json" <<'EOF'
{"files": [{"filename": "lib/landing.sh"}, {"filename": "README.md"}]}
EOF
cat > "$STUB_DIR/commit-sha2.json" <<'EOF'
{"files": [{"filename": "scripts/foo.sh"}]}
EOF
echo '{"truncated": true}' > "$STUB_DIR/commit-sha3.json"
cat > "$STUB_DIR/commit-sha4.json" <<'EOF'
{"files": [{"filename": "scripts/foo.sh"}]}
EOF

cat > "$STUB_DIR/events-1.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:low"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF
cat > "$STUB_DIR/events-2.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:medium"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF
cat > "$STUB_DIR/events-3.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:low"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF
cat > "$STUB_DIR/events-4.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:low"}, "created_at": "2026-08-20T08:00:00Z"},
 {"event": "labeled", "label": {"name": "complexity:medium"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF

log_file="$tmp_dir/log.jsonl"
cat > "$log_file" <<EOF
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/1","source":"tech-debt","complexity":"low"}
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/2","source":"register-hygiene","complexity":"medium"}
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/3","source":"tech-debt","complexity":"low"}
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/4","source":"tech-debt","complexity":"low"}
EOF

out="$("$DETECTOR" "$SLUG" "$LOGIN" "$log_file" --config "$config_file")"

line1="$(grep '"number":1,' <<<"$out")"
line2="$(grep '"number":2,' <<<"$out")"
line3="$(grep '"number":3,' <<<"$out")"
line4="$(grep '"number":4,' <<<"$out")"
line5="$(grep '"number":5,' <<<"$out")"

assert_contains "an injected known escape (a protected-path landing) is caught" \
  "$line1" '"outcome":"escape"'
assert_contains "  ... naming the protected path it disagreed over" \
  "$line1" "lib/landing.sh"
assert_contains "  ... even though the log's own landing-armed recorded complexity: low" \
  "$(cat "$log_file")" '"complexity":"low"'

assert_contains "a landing whose recomputation agrees is clean" \
  "$line2" '"outcome":"clean"'

assert_contains "an unreadable merge commit is unverifiable, never clean" \
  "$line3" '"outcome":"unverifiable"'
assert_contains "  ... naming the unreadable file list as the reason" \
  "$line3" "file list"

assert_contains "an ambiguous (two-label) complexity at merge time is unverifiable, never clean" \
  "$line4" '"outcome":"unverifiable"'
assert_contains "  ... naming the ambiguity as the reason" \
  "$line4" "complexity"

assert_eq "a pull request merged by someone other than the Approver login is not audited at all" \
  "" "$line5"

# --- Idempotency: an already-audited pull request costs no further gh call --
log_file2="$tmp_dir/log2.jsonl"
cat "$log_file" > "$log_file2"
echo "{\"event\":\"landing-audit\",\"repo\":\"$SLUG\",\"pr_url\":\"https://github.com/$SLUG/pull/2\",\"outcome\":\"clean\"}" >> "$log_file2"

out2="$("$DETECTOR" "$SLUG" "$LOGIN" "$log_file2" --config "$config_file")"
assert_eq "an already-audited pull request is skipped on a later run" \
  "" "$(grep '"number":2,' <<<"$out2")"
assert_contains "  ... while an unaudited one in the same run still gets checked" \
  "$out2" '"number":1,'

# --- A source not recorded at all: unverifiable, never guessed -------------
log_file3="$tmp_dir/log3.jsonl"
cat > "$log_file3" <<EOF
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/2","source":"register-hygiene"}
EOF
out3="$("$DETECTOR" "$SLUG" "$LOGIN" "$log_file3" --config "$config_file")"
line1_3="$(grep '"number":1,' <<<"$out3")"
assert_contains "a landing with no recorded source at all is unverifiable, never guessed" \
  "$line1_3" '"outcome":"unverifiable"'
assert_contains "  ... naming the missing source as the reason" \
  "$line1_3" "source"

echo
if (( failures == 0 )); then
  echo "All detect-classifier-escapes assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
