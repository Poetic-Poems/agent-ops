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

# --- Fixture: three merged PRs in one repo, covering every code path -------
#
#   #10  created 2026-08-10T00:00Z, ready 02:00Z, merged 05:00Z (open 5h,
#        ready 3h). Review: alice APPROVED. Files: a.txt, b.txt.
#   #11  created 2026-08-11T00:00Z, ready 00:30Z, merged 01:00Z (open 1h,
#        ready 0.5h). Reviews: alice CHANGES_REQUESTED, alice APPROVED.
#        Files: c.txt. Cross-referenced by #13 ("Revert ..."), merged
#        10:00Z the same day (9h later) — a revert.
#   #12  created 2026-08-11T22:00Z, merged 2026-08-12T00:00Z (open+ready 2h,
#        never a draft). Review: bob COMMENTED. Files: b.txt, d.txt — shares
#        b.txt with #10, merged inside #10's 48h window, so #10 also gets a
#        file-overlap follow-up (from #12). #12 itself has no follow-up.
#
# Expected aggregate: count=3; open median/p90 = 2/5 (sorted 1,2,5); ready
# median/p90 = 2/3 (sorted 0.5,2,3); alice APPROVED=2, CHANGES_REQUESTED=1,
# bob COMMENTED=1; #10 -> follow-up-fix by #12 (file-overlap), #11 -> revert
# by #13 (reference), #12 -> clean.

mkdir -p "$tmp_dir/bin"
export STUB_DIR="$tmp_dir/fixtures"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/hits.json" <<'EOF'
[
  {"number": 10, "title": "Add the a.txt/b.txt pair", "created_at": "2026-08-10T00:00:00Z",
   "pull_request": {"merged_at": "2026-08-10T05:00:00Z"}},
  {"number": 11, "title": "Change c.txt", "created_at": "2026-08-11T00:00:00Z",
   "pull_request": {"merged_at": "2026-08-11T01:00:00Z"}},
  {"number": 12, "title": "Touch b.txt and d.txt", "created_at": "2026-08-11T22:00:00Z",
   "pull_request": {"merged_at": "2026-08-12T00:00:00Z"}}
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
[{"event": "ready_for_review", "created_at": "2026-08-10T02:00:00Z"}]
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
[{"filename": "a.txt"}, {"filename": "b.txt"}]
EOF
cat > "$STUB_DIR/files-11.json" <<'EOF'
[{"filename": "c.txt"}]
EOF
cat > "$STUB_DIR/files-12.json" <<'EOF'
[{"filename": "b.txt"}, {"filename": "d.txt"}]
EOF

# `--jq` runs `jq -r`, which is why a bare-string filter (the files read)
# prints unquoted — the real behaviour scripts/mine-merge-history.sh's own
# header now documents and its files fetch works around.
cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
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

assert_contains "fleet summary: count, latency medians/p90, reverts, follow-ups" "$content" \
  "| o/r | 3 | 2 / 5 | 2 / 3 | 1 | 1 |"

assert_contains "review tally: alice's two states" "$content" "| alice | 2 | 1 | 0 |"
assert_contains "review tally: bob's COMMENTED" "$content" "| bob | 0 | 0 | 1 |"

assert_contains "post-merge: #11 classified as a revert by #13 (reference)" "$content" \
  "o/r#11 reverted by o/r#13"
assert_contains "post-merge: #10 classified as a follow-up by #12 (file-overlap)" "$content" \
  "o/r#10 followed up by o/r#12"
assert_contains "  ... via file-overlap, not a reference" "$content" "file-overlap"
assert_eq "#12 itself has no follow-up line (nothing merged in its own window)" "0" \
  "$(grep -c 'by o/r#12' <<<"$content" | grep -c '^[2-9]\|^1[0-9]' || true)"

# --- The raw JSON block carries the same figures, machine-readably ---------
raw_json="$(awk '/```json/{flag=1;next}/```/{flag=0}flag' "$expect_file")"
assert_eq "raw JSON: label" "lbl" "$(jq -r '.label' <<<"$raw_json")"
assert_eq "raw JSON: count" "3" "$(jq -r '.repos["o/r"].count' <<<"$raw_json")"
assert_eq "raw JSON: reverts" "1" "$(jq -r '.repos["o/r"].post_merge.reverts' <<<"$raw_json")"
assert_eq "raw JSON: follow_up_fixes" "1" "$(jq -r '.repos["o/r"].post_merge.follow_up_fixes' <<<"$raw_json")"
assert_eq "raw JSON: clean" "1" "$(jq -r '.repos["o/r"].post_merge.clean' <<<"$raw_json")"

# --- Idempotent: re-running against the same (stubbed) GitHub state --------
"$MINER" --repo o/r --label lbl --out-dir "$out_dir" >/dev/null 2>"$tmp_dir/run2.err"
content2="$(cat "$expect_file")"
assert_eq "re-running overwrites the same file byte-for-byte" "$content" "$content2"

# --- Fails loud, not silently, on an unreadable repo ------------------------
cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "stub gh: HTTP 500" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin/gh"
rm -f "$expect_file"
fail_out_dir="$tmp_dir/out-fail"
if "$MINER" --repo o/r --label lbl --out-dir "$fail_out_dir" >/dev/null 2>"$tmp_dir/fail.err"; then
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
