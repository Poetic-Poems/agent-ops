#!/usr/bin/env bash
#
# test/detect-classifier-escapes.test.sh — regression test for
# scripts/detect-classifier-escapes.sh (D18 Stage 2 exit criterion "zero
# classifier escapes"; agent-ops#572): the independent, post-hoc classifier-
# escape detector.
#
# Two halves:
#
#   - The reimplemented protected-path matching, protected-path resolution
#     and routine-sources resolution (`_escape_audit_is_protected`/
#     `_escape_audit_protected_paths`/`_escape_audit_routine_sources`, lifted
#     verbatim out of the script the same way test/landing-retry-sweep.test.sh
#     lifts `_landing_retry_sweep_repo` out of agent-cycle.sh) are pinned
#     byte-for-byte identical to lib/landing.sh's own
#     `_landing_is_protected`/`_landing_protected_paths`/`_landing_routine_sources`,
#     over the same battery of inputs — so the two can drift apart in the
#     same PR without it drifting *silently*, even though the detector
#     deliberately never sources lib/landing.sh at all (the issue's own
#     Refiner comment: "read there for the exact logic this detector must
#     reproduce independently (not call into)"). Both protected-path
#     fallbacks are additionally pinned to config.schema.json's own declared
#     `merge_autonomy_protected_paths` default, because that — not the two
#     literals against each other — is the pair production actually rests on:
#     lib/landing.sh is called with `$DEFAULTED_CONFIG` and takes the
#     top-level branch, while the detector is handed the raw `--config` file
#     and takes its own literal. The routine-sources fallbacks get the same
#     schema-default pin, plus scripts/doctor.sh's own two hand-copied
#     literals (extracted from the script text, since neither is a standalone
#     function this file can lift and eval) — closing the same gap for
#     `merge_autonomy_routine_sources` that its sibling key already had.
#   - The script itself, invoked as a subprocess against a stubbed `gh`
#     (PATH-prepended, the same technique test/mine-merge-history.test.sh
#     uses): a merged pull request whose merge commit touches a protected
#     path is an injected known escape, and must be caught, as are the other
#     three ways recomputation can disagree with a landing that happened — a
#     complexity above `medium`, a source outside the repository's routine
#     list, and an effective `merge_autonomy` level recorded at arming that
#     sits below `agent-merges-routine`; one whose four inputs all agree is
#     clean;
#     each of the ways an input can fail to reconstruct is unverifiable,
#     never clean; a pull request merged by anyone other than the passed-in
#     Approver login is not audited at all; and a pull request already
#     carrying an audit event in the log is skipped before any `gh` call is
#     spent on it at all, verified against the stub's own call log rather
#     than only the detector's output. The stub also refuses any
#     parameterised call that does not say
#     `--method GET`, because the real `gh api` would POST it — see its own
#     note below.
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

protected_paths_block="$(extract _escape_audit_protected_paths "$DETECTOR")"
[[ -n "$protected_paths_block" ]] || { echo "FAIL - could not extract _escape_audit_protected_paths from $DETECTOR — has it moved?" >&2; exit 1; }
eval "$protected_paths_block"

routine_sources_block="$(extract _escape_audit_routine_sources "$DETECTOR")"
[[ -n "$routine_sources_block" ]] || { echo "FAIL - could not extract _escape_audit_routine_sources from $DETECTOR — has it moved?" >&2; exit 1; }
eval "$routine_sources_block"

# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/landing.sh
. "$SCRIPT_DIR/lib/landing.sh"

default_protected='[".github/*","deploy/*","prompts/*","lib/*","config.schema.json","config.json","agent-cycle.sh","review-cycle.sh","CODEOWNERS"]'
for path in ".github/workflows/ci.yml" "deploy/docker/Dockerfile" "prompts/implementer.md" \
            "lib/landing.sh" "config.schema.json" "config.json" "agent-cycle.sh" \
            "review-cycle.sh" "CODEOWNERS" \
            "README.md" "scripts/detect-classifier-escapes.sh" "test/landing.test.sh" \
            "libfoo.sh" "deploying.txt" ".github" "githubby/file.txt"; do
  landing_rc=0; escape_rc=0
  _landing_is_protected "$default_protected" "$path" || landing_rc=$?
  _escape_audit_is_protected "$default_protected" "$path" || escape_rc=$?
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

for cfg in '{"repos":[]}' \
           '{"repos":[{"slug":"acme/widgets","merge_autonomy_protected_paths":["scripts/*"]}]}' \
           '{"merge_autonomy_protected_paths":["lib/*","CODEOWNERS"]}' \
           '{}'; do
  landing_out="$(_landing_protected_paths "$cfg" "acme/widgets")"
  escape_out="$(_escape_audit_protected_paths "$cfg" "acme/widgets")"
  assert_eq "protected-paths resolution for config '$cfg' matches lib/landing.sh's own" \
    "$landing_out" "$escape_out"
done

# ... and both against config.schema.json's own declared default, which is the
# pair that actually has to agree in production: agent-cycle.sh calls
# lib/landing.sh with $DEFAULTED_CONFIG, where config_defaults has already
# written the schema default into the top-level key, so the literal in
# lib/landing.sh is never reached there; the detector is handed the raw
# --config file, where the key is absent, so it does reach its own. Pinning
# the two literals to each other alone would let an edit to the schema default
# leave the gate protecting one list and the audit recomputing another —
# manufactured escapes, which is the whole thing requirement 8e exists to rule
# out.
schema_default="$(jq -c '.properties.merge_autonomy_protected_paths.default' \
  "$SCRIPT_DIR/config.schema.json")"
assert_eq "the shipped protected-paths fallback matches config.schema.json's declared default" \
  "$schema_default" "$(_landing_protected_paths '{}' "acme/widgets")"
assert_eq "  ... and so does the detector's own" \
  "$schema_default" "$(_escape_audit_protected_paths '{}' "acme/widgets")"

# ... and the same pin for merge_autonomy_routine_sources: lib/landing.sh's
# fallback is fed $DEFAULTED_CONFIG (already schema-defaulted, so this branch
# is never reached in production), while the detector is handed the raw
# --config file, where the key is absent — so its fallback is the one that
# actually decides. scripts/doctor.sh carries its own two copies, checked
# against the raw script text below since neither is a standalone function
# this file can extract and eval.
schema_routine_default="$(jq -c '.properties.merge_autonomy_routine_sources.default' \
  "$SCRIPT_DIR/config.schema.json")"
assert_eq "the shipped routine-sources fallback matches config.schema.json's declared default" \
  "$schema_routine_default" "$(_landing_routine_sources '{}' "acme/widgets")"
assert_eq "  ... and so does the detector's own" \
  "$schema_routine_default" "$(_escape_audit_routine_sources '{}' "acme/widgets")"

# shellcheck disable=SC2016  # literal source text to match, not meant to expand
mapfile -t rs_doctor_literals < <(grep -A1 '\$r\.merge_autonomy_routine_sources // \.merge_autonomy_routine_sources' \
  "$SCRIPT_DIR/scripts/doctor.sh" | grep -oE '\[[^]]*\]')
assert_eq "scripts/doctor.sh carries exactly two routine-sources fallback literals" \
  "2" "${#rs_doctor_literals[@]}"
assert_eq "  ... and its first fallback matches config.schema.json's declared default" \
  "$schema_routine_default" "${rs_doctor_literals[0]:-}"
assert_eq "  ... and its second fallback matches config.schema.json's declared default" \
  "$schema_routine_default" "${rs_doctor_literals[1]:-}"

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
printf '%s\n' "${args[*]}" >> "$f/calls.log"

jqfilter=""
prev=""
for a in "${args[@]}"; do
  [[ "$prev" == "--jq" ]] && jqfilter="$a"
  prev="$a"
done
apply() {
  if [[ -n "$jqfilter" ]]; then jq -c "$jqfilter" "$1" 2>/dev/null; else cat "$1"; fi
}

# The real `gh api` switches a request carrying `-f`/`-F` fields to POST
# unless it is told `--method GET` (lib/review-gate.sh's own reads carry the
# same note), and a POST to any of the endpoints below answers 404/422
# instead of the listing the detector needs — silently, since gh_retry sends
# stderr to /dev/null, so the detector would simply audit nothing at all
# for ever. A stub that answered such a call anyway would prove the detector
# works against a GitHub that does not exist, so refuse it here instead.
for a in "${args[@]}"; do
  case "$a" in
    -f|-F)
      if [[ "${args[*]}" != *"--method GET"* ]]; then
        echo "gh-stub: parameterised call with no --method GET — real gh would POST this: ${args[*]}" >&2
        exit 1
      fi
      ;;
  esac
done

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
# The level is no longer read from configuration at all — it comes off each
# pull request's own `landing-armed` event (see the fixture log below) — so
# this file's `merge_autonomy` is deliberately set to a level that would
# forbid landing outright. Every fixture below still resolves the level it
# was armed under, which is exactly the point: were the detector to fall back
# to current configuration, the whole battery would report `escape`.
echo '{"merge_autonomy":"human","repos":[]}' > "$config_file"

SLUG="acme/widgets"
LOGIN="pullwright-approver[bot]"

# --- Fixture set: eight candidate pull requests -------------------------------
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
#       an audit finding: reports outcome "not-approver" instead, naming who
#       merged it.
#   #8  merged by the Approver, no protected path, complexity:low, source
#       register-hygiene — every input the other checks look at agrees, but
#       the effective merge_autonomy level its own landing-armed event
#       recorded is below agent-merges-routine — the fourth way recomputation
#       can disagree, and the one none of #1/#6/#7 cover.
#   #9  merged by the Approver, every other input agreeing, but its
#       landing-armed event predates the `level` field — unverifiable, never
#       clean and never an escape.
#   #6  merged by the Approver, no protected path, source register-hygiene,
#       but complexity:high standing at merge — an escape the protected-path
#       check alone would have called clean.
#   #7  merged by the Approver, no protected path, complexity:low, but the
#       source recorded for it is `issues`, which is not in this repository's
#       routine list — the third of the three ways recomputation can
#       disagree, and the only one neither of the two above covers.
cat > "$STUB_DIR/issues.json" <<EOF
[{"number": 1, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 2, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 3, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 4, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 5, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 6, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}},
 {"number": 7, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}}]
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
pr_json 6 "$LOGIN" > "$STUB_DIR/pr-6.json"
pr_json 7 "$LOGIN" > "$STUB_DIR/pr-7.json"

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
cat > "$STUB_DIR/commit-sha6.json" <<'EOF'
{"files": [{"filename": "scripts/foo.sh"}]}
EOF
cat > "$STUB_DIR/commit-sha7.json" <<'EOF'
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
cat > "$STUB_DIR/events-6.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:high"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF
cat > "$STUB_DIR/events-7.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:low"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF

log_file="$tmp_dir/log.jsonl"
cat > "$log_file" <<EOF
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/1","source":"tech-debt","complexity":"low","level":"agent-merges-routine"}
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/2","source":"register-hygiene","complexity":"medium","level":"agent-merges-routine"}
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/3","source":"tech-debt","complexity":"low","level":"agent-merges-routine"}
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/4","source":"tech-debt","complexity":"low","level":"agent-merges-routine"}
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/6","source":"register-hygiene","complexity":"low","level":"agent-merges-routine"}
{"event":"landing-armed","repo":"$SLUG","pr_url":"https://github.com/$SLUG/pull/7","source":"issues","complexity":"low","level":"agent-merges-all"}
EOF

out="$("$DETECTOR" "$SLUG" "$LOGIN" "$log_file" --config "$config_file")"

line1="$(grep '"number":1,' <<<"$out")"
line2="$(grep '"number":2,' <<<"$out")"
line3="$(grep '"number":3,' <<<"$out")"
line4="$(grep '"number":4,' <<<"$out")"
line5="$(grep '"number":5,' <<<"$out")"
line6="$(grep '"number":6,' <<<"$out")"
line7="$(grep '"number":7,' <<<"$out")"

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

assert_contains "a pull request merged by someone other than the Approver login is not an audit finding" \
  "$line5" '"outcome":"not-approver"'
assert_contains "  ... naming who merged it instead" \
  "$line5" "merged by a-human"

# The other two ways recomputation can disagree, neither of which the
# protected-path escape above would have caught: the merge commit is clean
# and the source is routine, so only the recomputed complexity (#6) or the
# recorded source (#7) is left to disagree.
assert_contains "a landing whose recomputed complexity was high is an escape" \
  "$line6" '"outcome":"escape"'
assert_contains "  ... naming the complexity it recomputed, not the low the log recorded" \
  "$line6" "complexity was high"

assert_contains "a landing whose source is outside the repository's routine list is an escape" \
  "$line7" '"outcome":"escape"'
assert_contains "  ... naming the source and the list it is not in" \
  "$line7" "source issues is not in"

# --- A merge commit whose file list reaches the truncation cap: isolated
# under its own STUB_DIR/ESCAPE_AUDIT_MERGE_FILES_LIMIT so the cap can be
# small enough to fixture without disturbing the battery above, which relies
# on the real (300-file) default never tripping on its own small fixtures --
STUB_DIR_TRUNC="$tmp_dir/fixtures-trunc"
mkdir -p "$STUB_DIR_TRUNC"
cat > "$STUB_DIR_TRUNC/issues.json" <<EOF
[{"number": 1, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}}]
EOF
pr_json 1 "$LOGIN" > "$STUB_DIR_TRUNC/pr-1.json"
cat > "$STUB_DIR_TRUNC/commit-sha1.json" <<'EOF'
{"files": [{"filename": "scripts/foo.sh"}, {"filename": "scripts/bar.sh"}]}
EOF
cat > "$STUB_DIR_TRUNC/events-1.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:low"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF
log_file_trunc="$tmp_dir/log-trunc.jsonl"
echo "{\"event\":\"landing-armed\",\"repo\":\"$SLUG\",\"pr_url\":\"https://github.com/$SLUG/pull/1\",\"source\":\"tech-debt\",\"complexity\":\"low\",\"level\":\"agent-merges-routine\"}" \
  > "$log_file_trunc"

out_trunc="$(STUB_DIR="$STUB_DIR_TRUNC" ESCAPE_AUDIT_MERGE_FILES_LIMIT=2 \
  "$DETECTOR" "$SLUG" "$LOGIN" "$log_file_trunc" --config "$config_file")"
assert_contains "a merge commit whose file list reaches the truncation cap is unverifiable, never clean" \
  "$out_trunc" '"outcome":"unverifiable"'
assert_contains "  ... naming the cap as the reason" \
  "$out_trunc" "capped at the 2-file limit"

# --- Fixture #8: every other input agrees, but the effective merge_autonomy
# level recorded on its own landing-armed event is below agent-merges-routine
# — isolated under its own STUB_DIR so the main battery above can stay armed
# at a sufficient level -----------------------------------------------------
STUB_DIR_LEVEL="$tmp_dir/fixtures-level"
mkdir -p "$STUB_DIR_LEVEL"
cat > "$STUB_DIR_LEVEL/issues.json" <<EOF
[{"number": 8, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}}]
EOF
pr_json 8 "$LOGIN" > "$STUB_DIR_LEVEL/pr-8.json"
cat > "$STUB_DIR_LEVEL/commit-sha8.json" <<'EOF'
{"files": [{"filename": "scripts/foo.sh"}]}
EOF
cat > "$STUB_DIR_LEVEL/events-8.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:low"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF
log_file_level="$tmp_dir/log-level.jsonl"
echo "{\"event\":\"landing-armed\",\"repo\":\"$SLUG\",\"pr_url\":\"https://github.com/$SLUG/pull/8\",\"source\":\"register-hygiene\",\"complexity\":\"low\",\"level\":\"agent-approves\"}" \
  > "$log_file_level"

out_level="$(STUB_DIR="$STUB_DIR_LEVEL" \
  "$DETECTOR" "$SLUG" "$LOGIN" "$log_file_level" --config "$config_file")"
assert_contains "a landing armed at a merge_autonomy level below agent-merges-routine is an escape" \
  "$out_level" '"outcome":"escape"'
assert_contains "  ... naming the level recorded at arming, not one resolved from today's config" \
  "$out_level" "level recorded at arming was agent-approves"

# --- Fixture #9: the same landing, but armed before `landing-armed` carried
# a level at all. The level is then an input that cannot be reconstructed —
# this script has no state-repo access and current configuration is not
# evidence of what was in force at a past merge — so it is unverifiable, and
# in particular is never allowed to become an escape. This is the direction
# that matters: `config.json` here reads `human`, so a detector that fell
# back to it would report a first-class classifier escape against a landing
# nothing is known to be wrong with, and drive the D18 Stage 2 "zero
# classifier escapes" exit criterion non-zero on an operator's dial-down.
log_file_nolevel="$tmp_dir/log-nolevel.jsonl"
echo "{\"event\":\"landing-armed\",\"repo\":\"$SLUG\",\"pr_url\":\"https://github.com/$SLUG/pull/8\",\"source\":\"register-hygiene\",\"complexity\":\"low\"}" \
  > "$log_file_nolevel"

out_nolevel="$(STUB_DIR="$STUB_DIR_LEVEL" \
  "$DETECTOR" "$SLUG" "$LOGIN" "$log_file_nolevel" --config "$config_file")"
assert_contains "a landing whose landing-armed event records no level at all is unverifiable" \
  "$out_nolevel" '"outcome":"unverifiable"'
assert_eq "  ... and never an escape, however low today's configured level sits" \
  "" "$(grep '"outcome":"escape"' <<<"$out_nolevel")"
assert_contains "  ... naming the unrecorded level as the reason" \
  "$out_nolevel" "records the effective merge_autonomy level"

# --- Fixture #10: a protected-path hit recorded at agent-merges-all, with
# every other input agreeing — the sanctioned case PR #621's review found
# missing: `landing_eligible` (lib/landing.sh) does not refuse this, it
# defers to the WI-12 compensating controls (`landing_protected_path_controls_ok`,
# gate 4.5 of the arming step) that only `_landing_stage_attempt` can check.
# This detector has no post-hoc way to recompute those controls, so it must
# report `unverifiable`, never `escape` — the fixture #7 armed at
# agent-merges-all exercises only the source check and does not cover a
# protected-path hit at that level, so this is a distinct case from it.
STUB_DIR_ALL="$tmp_dir/fixtures-all"
mkdir -p "$STUB_DIR_ALL"
cat > "$STUB_DIR_ALL/issues.json" <<EOF
[{"number": 10, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}}]
EOF
pr_json 10 "$LOGIN" > "$STUB_DIR_ALL/pr-10.json"
cat > "$STUB_DIR_ALL/commit-sha10.json" <<'EOF'
{"files": [{"filename": "lib/landing.sh"}]}
EOF
cat > "$STUB_DIR_ALL/events-10.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:low"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF
log_file_all="$tmp_dir/log-all.jsonl"
echo "{\"event\":\"landing-armed\",\"repo\":\"$SLUG\",\"pr_url\":\"https://github.com/$SLUG/pull/10\",\"source\":\"register-hygiene\",\"complexity\":\"low\",\"level\":\"agent-merges-all\"}" \
  > "$log_file_all"

out_all="$(STUB_DIR="$STUB_DIR_ALL" \
  "$DETECTOR" "$SLUG" "$LOGIN" "$log_file_all" --config "$config_file")"
assert_contains "a protected-path hit recorded at agent-merges-all is unverifiable, never escape" \
  "$out_all" '"outcome":"unverifiable"'
assert_eq "  ... and never a classifier-escape, since landing_eligible itself defers this case" \
  "" "$(grep '"outcome":"escape"' <<<"$out_all")"
assert_contains "  ... naming the deferred compensating controls as the reason" \
  "$out_all" "WI-12 compensating controls"

# --- Fixture #11: the same protected-path hit at agent-merges-all, but this
# time complexity:high also stood at merge — a disagreement wholly
# independent of the protected-path hit's own unrecomputability, and one
# that must still surface as a classifier-escape rather than being masked by
# it -------------------------------------------------------------------------
STUB_DIR_ALL2="$tmp_dir/fixtures-all2"
mkdir -p "$STUB_DIR_ALL2"
cat > "$STUB_DIR_ALL2/issues.json" <<EOF
[{"number": 11, "pull_request": {"merged_at": "2026-08-20T10:00:00Z"}}]
EOF
pr_json 11 "$LOGIN" > "$STUB_DIR_ALL2/pr-11.json"
cat > "$STUB_DIR_ALL2/commit-sha11.json" <<'EOF'
{"files": [{"filename": "lib/landing.sh"}]}
EOF
cat > "$STUB_DIR_ALL2/events-11.json" <<'EOF'
[{"event": "labeled", "label": {"name": "complexity:high"}, "created_at": "2026-08-20T09:00:00Z"}]
EOF
log_file_all2="$tmp_dir/log-all2.jsonl"
echo "{\"event\":\"landing-armed\",\"repo\":\"$SLUG\",\"pr_url\":\"https://github.com/$SLUG/pull/11\",\"source\":\"register-hygiene\",\"complexity\":\"low\",\"level\":\"agent-merges-all\"}" \
  > "$log_file_all2"

out_all2="$(STUB_DIR="$STUB_DIR_ALL2" \
  "$DETECTOR" "$SLUG" "$LOGIN" "$log_file_all2" --config "$config_file")"
assert_contains "a genuinely reconstructable disagreement (complexity:high) still escapes, even alongside an unrecomputable agent-merges-all protected-path hit" \
  "$out_all2" '"outcome":"escape"'
assert_contains "  ... naming the complexity disagreement, not the protected path" \
  "$out_all2" "complexity was high"

# --- Idempotency: an already-audited pull request costs no gh call at all --
log_file2="$tmp_dir/log2.jsonl"
cat "$log_file" > "$log_file2"
echo "{\"event\":\"landing-audit\",\"repo\":\"$SLUG\",\"pr_url\":\"https://github.com/$SLUG/pull/2\",\"outcome\":\"clean\"}" >> "$log_file2"

: > "$STUB_DIR/calls.log"
out2="$("$DETECTOR" "$SLUG" "$LOGIN" "$log_file2" --config "$config_file")"
assert_eq "an already-audited pull request is skipped on a later run" \
  "" "$(grep '"number":2,' <<<"$out2")"
assert_eq "  ... and costs no gh call at all, not merely no output — never even the pulls/N read" \
  "" "$(grep -xF "api repos/$SLUG/pulls/2" "$STUB_DIR/calls.log" 2>/dev/null)"
assert_contains "  ... while an unaudited one in the same run still gets checked" \
  "$out2" '"number":1,'

# --- Idempotency: a previously-recorded not-approver skip also costs no gh
# call at all — the fact of who merged something is as fixed as an audit
# finding, so it must be free to skip the same way -------------------------
log_file2b="$tmp_dir/log2b.jsonl"
cat "$log_file" > "$log_file2b"
echo "{\"event\":\"landing-audit-skip\",\"repo\":\"$SLUG\",\"pr_url\":\"https://github.com/$SLUG/pull/5\",\"outcome\":\"not-approver\"}" >> "$log_file2b"

: > "$STUB_DIR/calls.log"
out2b="$("$DETECTOR" "$SLUG" "$LOGIN" "$log_file2b" --config "$config_file")"
assert_eq "a previously-recorded not-approver skip is skipped on a later run" \
  "" "$(grep '"number":5,' <<<"$out2b")"
assert_eq "  ... and costs no gh call at all, never even the pulls/N read" \
  "" "$(grep -xF "api repos/$SLUG/pulls/5" "$STUB_DIR/calls.log" 2>/dev/null)"

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

# --- A SIGTERM actually stops the sweep, and takes its temp files with it ---
# `agent-cycle.sh` runs this script under `timeout 120`, which sends one
# SIGTERM and then waits — there is no `--kill-after` at the call site. So
# both halves of the signal trap are load-bearing, and only one of them is
# visible in the temp-file check: a handler that cleans up but falls off its
# own end returns bash to the candidate loop, and the sweep runs on for the
# whole candidate list with nothing left to bound it. This pins the exit as
# well as the cleanup, against a stub whose reads are slow enough that an
# unbounded run overshoots the budget by several multiples.
slow_dir="$tmp_dir/slow"
mkdir -p "$slow_dir/bin"
cat > "$slow_dir/bin/gh" <<'SLOWSTUB'
#!/usr/bin/env bash
if [[ "$*" == *"issues"* ]]; then printf '%s\n' 1 2 3 4 5 6 7 8 9 10 11 12; exit 0; fi
sleep 1
printf '{"merged":true,"merged_by":{"login":"a-human"},"merged_at":"2026-01-01T00:00:00Z","merge_commit_sha":"abc","html_url":"x"}'
SLOWSTUB
chmod +x "$slow_dir/bin/gh"
echo '{}' > "$slow_dir/config.json"
: > "$slow_dir/log.jsonl"

slow_start="$(date +%s)"
PATH="$slow_dir/bin:$PATH" timeout 3 "$DETECTOR" "$SLUG" "$LOGIN" \
  "$slow_dir/log.jsonl" --config "$slow_dir/config.json" \
  > "$slow_dir/out.txt" 2>/dev/null
slow_elapsed="$(( $(date +%s) - slow_start ))"

assert_eq "a SIGTERM from timeout(1) actually stops the sweep, rather than resuming the loop" \
  "yes" "$( (( slow_elapsed <= 5 )) && echo yes || echo "no — ran ${slow_elapsed}s under a 3s timeout" )"
assert_eq "  ... while still delivering the lines it had already emitted" \
  "yes" "$( [[ -s "$slow_dir/out.txt" ]] && echo yes || echo no )"

# --- ... and the ordinary exit takes every temp file this script owns with
# it: both scan buffers, the `.raw` intermediate, and `gh_retry`'s shared
# response buffer. Checked against a TMPDIR of its own rather than /tmp, so
# the assertion is about this script's own allocations and cannot be swayed
# by whatever else on the machine happens to be using /tmp. Only the clean
# exit is pinned here: `lib/github-limit.sh`'s `gh` wrapper allocates two
# further files per call and has no signal trap of its own, so a run killed
# mid-read still leaves those two behind — a library-level gap this script
# cannot close from the outside, and not one this fixture should assert away.
own_tmp="$tmp_dir/own-tmp"
mkdir -p "$own_tmp"
TMPDIR="$own_tmp" "$DETECTOR" "$SLUG" "$LOGIN" "$log_file" \
  --config "$config_file" >/dev/null 2>&1
assert_eq "an ordinary exit leaves none of the script's own temp files behind" \
  "0" "$(find "$own_tmp" -type f 2>/dev/null | wc -l)"

echo
if (( failures == 0 )); then
  echo "All detect-classifier-escapes assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
