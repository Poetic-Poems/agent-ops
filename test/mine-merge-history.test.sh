#!/usr/bin/env bash
#
# test/mine-merge-history.test.sh — regression test for
# scripts/mine-merge-history.sh (issue #404, D18 WI-1): the repeatable
# merged-PR history miner and Stage 0 autonomy baseline.
#
# `gh` is stubbed via `PATH`, the same technique test/gather-unvoid-
# requests.sh uses, including its raw-output behaviour under `--jq`
# (unquoted strings) — the real bug this test would have caught, since the
# script's first draft slurped a raw filename stream as if it were JSON.
#
# Run directly:
#
#   ./test/mine-merge-history.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINER="$SCRIPT_DIR/scripts/mine-merge-history.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n' "$desc" "$needle"
    failures=$(( failures + 1 ))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n' "$desc" "$needle"
    failures=$(( failures + 1 ))
  fi
}

# --- Fixture: four merged PRs in one repo, covering every code path --------
#
#   #10  created 2026-08-10T00:00Z, ready 02:00Z, merged 05:00Z (open 5h,
#        ready 3h). Review: alice APPROVED. Files: a.txt, b.txt,
#        CHANGELOG.md. Cross-referenced by #15 ("Build on the a.txt
#        groundwork"), merged 08:00Z the same day — in the window but not
#        corrective-titled, so it must NOT count; instead #10 gets a
#        file-overlap follow-up from fix-titled #12 (shared b.txt — the
#        shared CHANGELOG.md is boilerplate and invisible).
#   #11  created 2026-08-11T00:00Z, ready 00:30Z, merged 01:00Z (open 1h,
#        ready 0.5h). Reviews: alice CHANGES_REQUESTED, alice APPROVED.
#        Files: c.txt. Cross-referenced by #13 ("Revert ..."), merged
#        10:00Z the same day (9h later) — a revert.
#   #12  created 2026-08-11T22:00Z, merged 2026-08-12T00:00Z (open+ready 2h,
#        never a draft). Review: bob COMMENTED. Files: b.txt, d.txt,
#        CHANGELOG.md. Fix-titled #14 merges inside #12's window sharing
#        only CHANGELOG.md — boilerplate-only overlap, so #12 stays clean.
#   #14  created 2026-08-12T02:00Z, merged 06:00Z (open+ready 4h, never a
#        draft). No reviews. Files: e.txt, CHANGELOG.md. Clean.
#
# Expected aggregate: count=4; open median/p90 = 4/5 (sorted 1,2,4,5,
# nearest-rank); ready median/p90 = 3/4 (sorted 0.5,2,3,4); alice
# APPROVED=2, CHANGES_REQUESTED=1, bob COMMENTED=1; #10 -> follow-up-fix by
# #12 (file-overlap), #11 -> revert by #13 (reference), #12 and #14 -> clean.

mkdir -p "$tmp_dir/bin"
export STUB_DIR="$tmp_dir/fixtures"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/hits.json" <<'EOF'
[
  {"number": 10, "title": "Add the a.txt/b.txt pair", "created_at": "2026-08-10T00:00:00Z",
   "pull_request": {"merged_at": "2026-08-10T05:00:00Z"}},
  {"number": 11, "title": "Change c.txt", "created_at": "2026-08-11T00:00:00Z",
   "pull_request": {"merged_at": "2026-08-11T01:00:00Z"}},
  {"number": 12, "title": "fix: harden b.txt against a missed edge case", "created_at": "2026-08-11T22:00:00Z",
   "pull_request": {"merged_at": "2026-08-12T00:00:00Z"}},
  {"number": 14, "title": "fix: correct a typo in e.txt", "created_at": "2026-08-12T02:00:00Z",
   "pull_request": {"merged_at": "2026-08-12T06:00:00Z"}}
]
EOF

cat > "$STUB_DIR/reviews-10.json" <<'EOF'
[{"state": "APPROVED", "user": {"login": "alice"}}]
EOF
cat > "$STUB_DIR/reviews-11.json" <<'EOF'
[{"state": "CHANGES_REQUESTED", "user": {"login": "alice"}},
 {"state": "APPROVED", "user": {"login": "alice"}}]
EOF
cat > "$STUB_DIR/reviews-12.json" <<'EOF'
[{"state": "COMMENTED", "user": {"login": "bob"}}]
EOF

cat > "$STUB_DIR/timeline-10.json" <<'EOF'
[{"event": "ready_for_review", "created_at": "2026-08-10T02:00:00Z"},
 {"event": "cross-referenced",
  "source": {"issue": {"number": 15, "title": "Build on the a.txt groundwork",
                        "pull_request": {"merged_at": "2026-08-10T08:00:00Z"}}}}]
EOF
cat > "$STUB_DIR/timeline-11.json" <<'EOF'
[{"event": "ready_for_review", "created_at": "2026-08-11T00:30:00Z"},
 {"event": "cross-referenced",
  "source": {"issue": {"number": 13, "title": "Revert #11's c.txt change",
                        "pull_request": {"merged_at": "2026-08-11T10:00:00Z"}}}}]
EOF
cat > "$STUB_DIR/timeline-12.json" <<'EOF'
[]
EOF

cat > "$STUB_DIR/files-10.json" <<'EOF'
[{"filename": "a.txt"}, {"filename": "b.txt"}, {"filename": "CHANGELOG.md"}]
EOF
cat > "$STUB_DIR/files-11.json" <<'EOF'
[{"filename": "c.txt"}]
EOF
cat > "$STUB_DIR/files-12.json" <<'EOF'
[{"filename": "b.txt"}, {"filename": "d.txt"}, {"filename": "CHANGELOG.md"}]
EOF
cat > "$STUB_DIR/files-14.json" <<'EOF'
[{"filename": "e.txt"}, {"filename": "CHANGELOG.md"}]
EOF

# `--jq` runs `jq -r`, which is why a bare-string filter (the files read)
# prints unquoted — the real behaviour scripts/mine-merge-history.sh's own
# header now documents and its files fetch works around.
cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
# One-shot simulated network failure: when FLAKY_FAIL_FILE names an existing
# file, consume it and die the way a dropped connection does — the next call
# succeeds, which is what the miner's gh_retry loop must absorb.
if [[ -n "${FLAKY_FAIL_FILE:-}" && -f "$FLAKY_FAIL_FILE" ]]; then
  rm -f "$FLAKY_FAIL_FILE"
  echo "stub gh: net/http: TLS handshake timeout" >&2
  exit 1
fi
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected command: $*" >&2; exit 1; }
shift
path=""
filter='.'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) filter="$2"; shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) path="$1"; shift ;;
  esac
done
case "$path" in
  repos/*/issues\?labels=*) body="$(cat "$STUB_DIR/hits.json")" ;;
  repos/*/pulls/*/reviews\?*)
    n="${path#repos/*/pulls/}"; n="${n%%/*}"
    body="$(cat "$STUB_DIR/reviews-$n.json" 2>/dev/null || echo '[]')"
    ;;
  repos/*/pulls/*/files\?*)
    n="${path#repos/*/pulls/}"; n="${n%%/*}"
    body="$(cat "$STUB_DIR/files-$n.json" 2>/dev/null || echo '[]')"
    ;;
  repos/*/issues/*/timeline\?*)
    n="${path#repos/*/issues/}"; n="${n%%/*}"
    body="$(cat "$STUB_DIR/timeline-$n.json" 2>/dev/null || echo '[]')"
    ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1 ;;
esac
jq -r "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

out_dir="$tmp_dir/out"
out="$("$MINER" --repo o/r --label lbl --out-dir "$out_dir" 2>"$tmp_dir/run.err")"
rc=$?
assert_eq "a clean run exits 0" "0" "$rc"

date_str="$(date -u +%F)"
expect_file="$out_dir/${date_str}-merge-autonomy-baseline.md"
assert_eq "it prints the baseline file's own path" "$expect_file" "$out"
assert_eq "the baseline file exists" "1" "$([[ -f "$expect_file" ]] && echo 1 || echo 0)"

content="$(cat "$expect_file")"

assert_contains "fleet summary: count, latencies, reverts, follow-ups split by reason" "$content" \
  "| o/r | 4 | 4 / 5 | 3 / 4 | 1 | 1 (0 / 1) |"
assert_contains "per-repo outcome line carries the by-reason split" "$content" \
  "**1** follow-up fix(es) — 0 detected by reference, 1 by file overlap alone"

assert_contains "review tally: alice's two states" "$content" "| alice | 2 | 1 | 0 |"
assert_contains "review tally: bob's COMMENTED" "$content" "| bob | 0 | 0 | 1 |"

assert_contains "post-merge: #11 classified as a revert by #13 (reference)" "$content" \
  "o/r#11 reverted by o/r#13"
assert_contains "post-merge: #10 classified as a follow-up by #12 (file-overlap)" "$content" \
  "o/r#10 followed up by o/r#12"
assert_contains "  ... via file-overlap, not a reference" "$content" "file-overlap"
assert_not_contains "a cross-reference without a corrective title is not an outcome" "$content" \
  "by o/r#15"
assert_not_contains "boilerplate-only file overlap is not an outcome (#12 vs fix-titled #14)" "$content" \
  "o/r#12 followed up"
assert_not_contains "  ... and is not a revert either" "$content" "o/r#12 reverted"

# --- The raw JSON block carries the same figures, machine-readably ---------
raw_json="$(awk '/```json/{flag=1;next}/```/{flag=0}flag' "$expect_file")"
assert_eq "raw JSON: label" "lbl" "$(jq -r '.label' <<<"$raw_json")"
assert_eq "raw JSON: count" "4" "$(jq -r '.repos["o/r"].count' <<<"$raw_json")"
assert_eq "raw JSON: reverts" "1" "$(jq -r '.repos["o/r"].post_merge.reverts' <<<"$raw_json")"
assert_eq "raw JSON: follow_up_fixes" "1" "$(jq -r '.repos["o/r"].post_merge.follow_up_fixes' <<<"$raw_json")"
assert_eq "raw JSON: follow_ups_by_reason.reference" "0" "$(jq -r '.repos["o/r"].post_merge.follow_ups_by_reason.reference' <<<"$raw_json")"
assert_eq "raw JSON: follow_ups_by_reason.file_overlap" "1" "$(jq -r '.repos["o/r"].post_merge.follow_ups_by_reason.file_overlap' <<<"$raw_json")"
assert_eq "raw JSON: clean" "2" "$(jq -r '.repos["o/r"].post_merge.clean' <<<"$raw_json")"

# --- Idempotent: re-running against the same (stubbed) GitHub state --------
"$MINER" --repo o/r --label lbl --out-dir "$out_dir" >/dev/null 2>"$tmp_dir/run2.err"
content2="$(cat "$expect_file")"
assert_eq "re-running overwrites the same file byte-for-byte" "$content" "$content2"

# --- One transient network failure is absorbed, not fatal ------------------
touch "$tmp_dir/flaky-once"
if FLAKY_FAIL_FILE="$tmp_dir/flaky-once" MINE_RETRY_DELAY_SECONDS=0 \
    "$MINER" --repo o/r --label lbl --out-dir "$out_dir" >/dev/null 2>"$tmp_dir/run3.err"; then
  flaky_rc=0
else
  flaky_rc=$?
fi
assert_eq "a single dropped call is retried and the run still exits 0" "0" "$flaky_rc"
content3="$(cat "$expect_file")"
assert_eq "  ... and the baseline is byte-for-byte identical" "$content" "$content3"
assert_contains "  ... and the retry announced itself on stderr" \
  "$(cat "$tmp_dir/run3.err")" "transient gh failure"

# --- --since bounds the mined population to merged_at >= that instant ------
#
# 2026-08-11T12:00:00Z sits between #11 (merged 01:00Z the same day) and #12
# (merged 2026-08-12T00:00Z): only #12 and #14 qualify. #12's only outcome
# partner in the unbounded run was #14 (boilerplate-only overlap, so #12
# stays clean) and #11's revert-by-#13 falls out of the window entirely —
# proving the precise merged_at filter runs after the REST `since` narrowing,
# not merely the REST parameter's own looser "updated after" semantics.
since_out_dir="$tmp_dir/out-since"
"$MINER" --repo o/r --label lbl --out-dir "$since_out_dir" --since "2026-08-11T12:00:00Z" \
  >/dev/null 2>"$tmp_dir/since.err"
since_rc=$?
assert_eq "--since: a bounded run exits 0" "0" "$since_rc"
since_content="$(cat "$since_out_dir/${date_str}-merge-autonomy-baseline.md")"
since_raw="$(awk '/```json/{flag=1;next}/```/{flag=0}flag' "$since_out_dir/${date_str}-merge-autonomy-baseline.md")"
assert_eq "--since: only PRs merged at/after the bound are counted" "2" \
  "$(jq -r '.repos["o/r"].count' <<<"$since_raw")"
assert_eq "--since: the bound itself is recorded in the raw JSON" "2026-08-11T12:00:00Z" \
  "$(jq -r '.since' <<<"$since_raw")"
assert_contains "--since: the report says it is a bounded window, not the Stage 0 baseline" \
  "$since_content" "not the Stage 0 baseline"
assert_eq "--since: an invalid instant is rejected before any network call" "64" \
  "$("$MINER" --repo o/r --label lbl --out-dir "$tmp_dir/out-badsince" --since "not-a-date" \
      >/dev/null 2>&1; echo $?)"

# --- Fails loud, not silently, on an unreadable repo ------------------------
cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "stub gh: HTTP 500" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin/gh"
rm -f "$expect_file"
fail_out_dir="$tmp_dir/out-fail"
if MINE_RETRY_DELAY_SECONDS=0 "$MINER" --repo o/r --label lbl --out-dir "$fail_out_dir" >/dev/null 2>"$tmp_dir/fail.err"; then
  fail_rc=0
else
  fail_rc=$?
fi
assert_eq "an unreadable repo exits non-zero" "1" "$fail_rc"
assert_eq "  ... and writes no baseline file" "0" \
  "$(find "$fail_out_dir" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_contains "  ... and says why on stderr" "$(cat "$tmp_dir/fail.err")" "mine-merge-history"

echo "---"
if [[ "$failures" -eq 0 ]]; then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
