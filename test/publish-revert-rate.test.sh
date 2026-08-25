#!/usr/bin/env bash
#
# test/publish-revert-rate.test.sh — regression test for
# scripts/publish-revert-rate.sh (issue #579, D18 WI of umbrella #402): the
# daily revert-or-follow-up rate publisher.
#
# `gh` is stubbed via `PATH`, the same technique test/mine-merge-history.test.sh
# uses, reused here as-is because scripts/publish-revert-rate.sh shells out to
# the real scripts/mine-merge-history.sh (three bounded mining passes per
# repository) rather than reading GitHub itself.
#
# --- Fixture: repo o/r, `now` fixed at 2026-09-01T00:00:00Z ----------------
#
# window-days=14 -> since_window  = 2026-08-18T00:00:00Z
#                    since_recent  = 2026-08-30T00:00:00Z (now - 48h)
# baseline generated = 2026-08-15 -> baseline_since = 2026-08-15T00:00:00Z
#
#   #101-#105  merged 2026-08-10..14 (before the baseline): outside every
#              window this script publishes.
#   #106-#108  merged 2026-08-16, 2026-08-16, 2026-08-17 (baseline..window):
#              counted in cumulative-since-baseline, not in the 14-day
#              rolling window.
#   #109-#118  merged 2026-08-19..27, one per day (the rolling window's own
#              "settled" population — already 48h+ old as of `now`): #110 is
#              reverted by #111 (same day, "Revert ..."), #114 is followed up
#              by #115 (next day, "fix: ..."), the rest clean. n=10 exactly
#              at min-samples; reverts=1, follow_up_fixes=1, rate=0.2.
#   #119-#120  merged 2026-08-30, 2026-08-31 (the last 48h): excluded from
#              the rolling figure (still counted in cumulative). #119 is
#              followed up by #120 ("fix: ...", next day) sharing a file and
#              *not* cross-referencing it — the file-overlap detection path,
#              exercised here entirely inside the 48h-exclusion population so
#              the rolling figure's subtraction argument is tested on it too,
#              not only on the reference-based #110/#111 and #114/#115 pairs.
#
# cumulative-since-baseline: #106-#120 = 15 PRs, reverts=1, follow_up_fixes=2
# (#114/#115 by reference, #119/#120 by file overlap), rate = 3/15 = 0.2.
#
# Run directly:
#
#   ./test/publish-revert-rate.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH="$SCRIPT_DIR/scripts/publish-revert-rate.sh"
NOW="2026-09-01T00:00:00Z"

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

mkdir -p "$tmp_dir/bin"
export STUB_DIR="$tmp_dir/fixtures"
mkdir -p "$STUB_DIR"

# --- The merged-PR listing, one fixed set the precise merged_at >= --since
#     filter (scripts/mine-merge-history.sh) narrows per mining pass -------
cat > "$STUB_DIR/hits-o_r.json" <<'EOF'
[
  {"number": 101, "title": "Add a", "created_at": "2026-08-10T00:00:00Z", "pull_request": {"merged_at": "2026-08-10T00:00:00Z"}},
  {"number": 102, "title": "Add b", "created_at": "2026-08-11T00:00:00Z", "pull_request": {"merged_at": "2026-08-11T00:00:00Z"}},
  {"number": 103, "title": "Add c", "created_at": "2026-08-12T00:00:00Z", "pull_request": {"merged_at": "2026-08-12T00:00:00Z"}},
  {"number": 104, "title": "Add d", "created_at": "2026-08-13T00:00:00Z", "pull_request": {"merged_at": "2026-08-13T00:00:00Z"}},
  {"number": 105, "title": "Add e", "created_at": "2026-08-14T00:00:00Z", "pull_request": {"merged_at": "2026-08-14T00:00:00Z"}},
  {"number": 106, "title": "Add f", "created_at": "2026-08-16T00:00:00Z", "pull_request": {"merged_at": "2026-08-16T00:00:00Z"}},
  {"number": 107, "title": "Add g", "created_at": "2026-08-16T12:00:00Z", "pull_request": {"merged_at": "2026-08-16T12:00:00Z"}},
  {"number": 108, "title": "Add h", "created_at": "2026-08-17T00:00:00Z", "pull_request": {"merged_at": "2026-08-17T00:00:00Z"}},
  {"number": 109, "title": "Add i", "created_at": "2026-08-19T00:00:00Z", "pull_request": {"merged_at": "2026-08-19T00:00:00Z"}},
  {"number": 110, "title": "Add j (soon reverted)", "created_at": "2026-08-20T00:00:00Z", "pull_request": {"merged_at": "2026-08-20T00:00:00Z"}},
  {"number": 111, "title": "Revert \"Add j (soon reverted)\"", "created_at": "2026-08-20T12:00:00Z", "pull_request": {"merged_at": "2026-08-20T12:00:00Z"}},
  {"number": 112, "title": "Add k", "created_at": "2026-08-21T00:00:00Z", "pull_request": {"merged_at": "2026-08-21T00:00:00Z"}},
  {"number": 113, "title": "Add l", "created_at": "2026-08-22T00:00:00Z", "pull_request": {"merged_at": "2026-08-22T00:00:00Z"}},
  {"number": 114, "title": "Add m (soon followed up)", "created_at": "2026-08-23T00:00:00Z", "pull_request": {"merged_at": "2026-08-23T00:00:00Z"}},
  {"number": 115, "title": "fix: correct m", "created_at": "2026-08-24T00:00:00Z", "pull_request": {"merged_at": "2026-08-24T00:00:00Z"}},
  {"number": 116, "title": "Add n", "created_at": "2026-08-25T00:00:00Z", "pull_request": {"merged_at": "2026-08-25T00:00:00Z"}},
  {"number": 117, "title": "Add o", "created_at": "2026-08-26T00:00:00Z", "pull_request": {"merged_at": "2026-08-26T00:00:00Z"}},
  {"number": 118, "title": "Add p", "created_at": "2026-08-27T00:00:00Z", "pull_request": {"merged_at": "2026-08-27T00:00:00Z"}},
  {"number": 119, "title": "Add q", "created_at": "2026-08-30T00:00:00Z", "pull_request": {"merged_at": "2026-08-30T00:00:00Z"}},
  {"number": 120, "title": "fix: correct q", "created_at": "2026-08-31T00:00:00Z", "pull_request": {"merged_at": "2026-08-31T00:00:00Z"}}
]
EOF

# Every PR is reviewless and file-overlap-free (distinct files each), except
# #119/#120 (see below) — so the reference-based pairs (#110/#111, #114/#115)
# exercise a population-independent outcome signal (a live GitHub timeline
# read), unaffected by which of the three --since bounds a given mining pass
# used, and #119/#120 exercises the file-overlap path instead.
for n in 101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119 120; do
  printf '[]\n' > "$STUB_DIR/reviews-$n.json"
  printf '[{"filename": "file-%s.txt"}]\n' "$n" > "$STUB_DIR/files-$n.json"
  printf '[]\n' > "$STUB_DIR/timeline-$n.json"
done
# #119 and #120 share a file and neither cross-references the other — #120
# ("fix: correct q") is detected as #119's follow-up by file overlap alone,
# entirely inside the last-48h population the rolling figure excludes.
printf '[{"filename": "shared-q.txt"}]\n' > "$STUB_DIR/files-119.json"
printf '[{"filename": "shared-q.txt"}]\n' > "$STUB_DIR/files-120.json"
cat > "$STUB_DIR/timeline-110.json" <<'EOF'
[{"event": "cross-referenced",
  "source": {"issue": {"number": 111, "title": "Revert \"Add j (soon reverted)\"",
                        "pull_request": {"merged_at": "2026-08-20T12:00:00Z"}}}}]
EOF
cat > "$STUB_DIR/timeline-114.json" <<'EOF'
[{"event": "cross-referenced",
  "source": {"issue": {"number": 115, "title": "fix: correct m",
                        "pull_request": {"merged_at": "2026-08-24T00:00:00Z"}}}}]
EOF

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
  repos/*/issues\?labels=*)
    repo="${path#repos/}"; repo="${repo%%/issues*}"
    key="${repo//\//_}"
    if [[ ! -f "$STUB_DIR/hits-$key.json" ]]; then
      echo "stub gh: HTTP 404 (no fixture for $repo)" >&2; exit 1
    fi
    body="$(cat "$STUB_DIR/hits-$key.json")"
    ;;
  repos/*/pulls/*/reviews\?*)
    n="${path#repos/*/pulls/}"; n="${n%%/*}"
    [[ -f "$STUB_DIR/blocked-numbers" ]] && grep -qx "$n" "$STUB_DIR/blocked-numbers" \
      && { echo "stub gh: #$n is a settled PR that should never be re-mined" >&2; exit 1; }
    body="$(cat "$STUB_DIR/reviews-$n.json" 2>/dev/null || echo '[]')"
    ;;
  repos/*/pulls/*/files\?*)
    n="${path#repos/*/pulls/}"; n="${n%%/*}"
    [[ -f "$STUB_DIR/blocked-numbers" ]] && grep -qx "$n" "$STUB_DIR/blocked-numbers" \
      && { echo "stub gh: #$n is a settled PR that should never be re-mined" >&2; exit 1; }
    body="$(cat "$STUB_DIR/files-$n.json" 2>/dev/null || echo '[]')"
    ;;
  repos/*/issues/*/timeline\?*)
    n="${path#repos/*/issues/}"; n="${n%%/*}"
    [[ -f "$STUB_DIR/blocked-numbers" ]] && grep -qx "$n" "$STUB_DIR/blocked-numbers" \
      && { echo "stub gh: #$n is a settled PR that should never be re-mined" >&2; exit 1; }
    body="$(cat "$STUB_DIR/timeline-$n.json" 2>/dev/null || echo '[]')"
    ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1 ;;
esac
jq -r "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

write_config() {  # write_config <path> <revert_rate_baseline-json-or-empty>
  local path="$1" baseline="$2"
  jq -n --arg repo "o/r" --argjson baseline "$baseline" \
    '{repos: [{slug: $repo, sources: ["tech-debt"]}], pr_label: "lbl",
      state_dir: "unused", workspace_root: "unused"} + (if $baseline == {} then {} else {revert_rate_baseline: $baseline} end)' \
    > "$path"
}

# ============================================================================
# Run A: a full baseline recorded for o/r — every block populated
# ============================================================================
cfg_a="$tmp_dir/config-a.json"
write_config "$cfg_a" '{"source": "docs/reviews/2026-08-15-merge-autonomy-baseline.md", "generated": "2026-08-15",
  "repos": [{"slug": "o/r", "count": 50, "reverts": 2, "follow_up_fixes": 8}]}'
state_a="$tmp_dir/state-a"
"$PUBLISH" --config "$cfg_a" --state-dir "$state_a" --now "$NOW" 2>"$tmp_dir/run-a.err"
rc_a=$?
assert_eq "run A exits 0" "0" "$rc_a"
assert_eq "run A writes exactly one row" "1" "$(wc -l < "$state_a/revert-rate.jsonl" | tr -d ' ')"

row_a="$(cat "$state_a/revert-rate.jsonl")"
assert_eq "row: event" "revert-rate" "$(jq -r '.event' <<<"$row_a")"
assert_eq "row: repo" "o/r" "$(jq -r '.repo' <<<"$row_a")"
assert_eq "row: ts is the fixed now" "$NOW" "$(jq -r '.ts' <<<"$row_a")"
assert_eq "row: window_days" "14" "$(jq -r '.window_days' <<<"$row_a")"

assert_eq "rolling: since" "2026-08-18T00:00:00Z" "$(jq -r '.rolling.since' <<<"$row_a")"
assert_eq "rolling: excludes_merged_after" "2026-08-30T00:00:00Z" "$(jq -r '.rolling.excludes_merged_after' <<<"$row_a")"
assert_eq "rolling: n is exactly min-samples (10)" "10" "$(jq -r '.rolling.n' <<<"$row_a")"
assert_eq "rolling: 1 revert (#110 by #111)" "1" "$(jq -r '.rolling.reverts' <<<"$row_a")"
assert_eq "rolling: 1 follow-up fix (#114 by #115)" "1" "$(jq -r '.rolling.follow_up_fixes' <<<"$row_a")"
assert_eq "rolling: not insufficient at exactly the floor" "false" "$(jq -r '.rolling.insufficient_samples' <<<"$row_a")"
assert_eq "rolling: rate = 2/10 = 0.2" "0.2" "$(jq -r '.rolling.rate' <<<"$row_a")"

assert_eq "cumulative: since is the baseline date" "2026-08-15T00:00:00Z" "$(jq -r '.cumulative.since' <<<"$row_a")"
assert_eq "cumulative: n = 15 (#106..#120)" "15" "$(jq -r '.cumulative.n' <<<"$row_a")"
assert_eq "cumulative: 1 revert (#110 by #111)" "1" "$(jq -r '.cumulative.reverts' <<<"$row_a")"
assert_eq "cumulative: 2 follow-ups (#114 by reference, #119 by file overlap)" "2" "$(jq -r '.cumulative.follow_up_fixes' <<<"$row_a")"
assert_eq "cumulative: rate = 3/15 = 0.2" "0.2" "$(jq -r '.cumulative.rate' <<<"$row_a")"

assert_eq "baseline: n = 50" "50" "$(jq -r '.baseline.n' <<<"$row_a")"
assert_eq "baseline: rate = 10/50 = 0.2" "0.2" "$(jq -r '.baseline.rate' <<<"$row_a")"
assert_eq "above_baseline: 0.2 is not above 0.2" "false" "$(jq -r '.above_baseline' <<<"$row_a")"

# --- Appending: a second run adds a second line, never overwrites ----------
"$PUBLISH" --config "$cfg_a" --state-dir "$state_a" --now "$NOW" >/dev/null 2>&1
assert_eq "a second run appends rather than overwrites" "2" "$(wc -l < "$state_a/revert-rate.jsonl" | tr -d ' ')"

# ============================================================================
# Run B: revert_rate_baseline recorded, but not for o/r — cumulative still
# reads, baseline reads unavailable
# ============================================================================
cfg_b="$tmp_dir/config-b.json"
write_config "$cfg_b" '{"source": "x", "generated": "2026-08-15", "repos": [{"slug": "o/other", "count": 1, "reverts": 0, "follow_up_fixes": 0}]}'
state_b="$tmp_dir/state-b"
"$PUBLISH" --config "$cfg_b" --state-dir "$state_b" --now "$NOW" >/dev/null 2>"$tmp_dir/run-b.err"
row_b="$(cat "$state_b/revert-rate.jsonl")"
assert_eq "run B: cumulative n still reads (the date alone is enough)" "15" "$(jq -r '.cumulative.n' <<<"$row_b")"
assert_eq "run B: baseline reads unavailable (null n)" "null" "$(jq -r '.baseline.n' <<<"$row_b")"
assert_eq "run B: above_baseline is null, never false" "null" "$(jq -r '.above_baseline' <<<"$row_b")"

# ============================================================================
# Run C: no revert_rate_baseline block at all — cumulative AND baseline both
# read unavailable; rolling is unaffected
# ============================================================================
cfg_c="$tmp_dir/config-c.json"
write_config "$cfg_c" '{}'
state_c="$tmp_dir/state-c"
"$PUBLISH" --config "$cfg_c" --state-dir "$state_c" --now "$NOW" >/dev/null 2>"$tmp_dir/run-c.err"
row_c="$(cat "$state_c/revert-rate.jsonl")"
assert_eq "run C: rolling is unaffected by an absent baseline" "10" "$(jq -r '.rolling.n' <<<"$row_c")"
assert_eq "run C: cumulative.since is null" "null" "$(jq -r '.cumulative.since' <<<"$row_c")"
assert_eq "run C: cumulative.n is null (no cumulative mining pass at all)" "null" "$(jq -r '.cumulative.n' <<<"$row_c")"
assert_eq "run C: baseline.n is null" "null" "$(jq -r '.baseline.n' <<<"$row_c")"
assert_eq "run C: above_baseline is null" "null" "$(jq -r '.above_baseline' <<<"$row_c")"

# ============================================================================
# --min-samples: raising the floor past the rolling n reports insufficient
# ============================================================================
state_d="$tmp_dir/state-d"
"$PUBLISH" --config "$cfg_a" --state-dir "$state_d" --now "$NOW" --min-samples 11 >/dev/null 2>&1
row_d="$(cat "$state_d/revert-rate.jsonl")"
assert_eq "a stricter floor: n is still reported" "10" "$(jq -r '.rolling.n' <<<"$row_d")"
assert_eq "  ... but insufficient_samples flips true" "true" "$(jq -r '.rolling.insufficient_samples' <<<"$row_d")"
assert_eq "  ... and rate reads null, never a rate an operator would over-read" "null" "$(jq -r '.rolling.rate' <<<"$row_d")"

# ============================================================================
# Run E: two repos, one unreadable — the readable one still gets a row, the
# run still reports failure
# ============================================================================
cfg_e="$tmp_dir/config-e.json"
jq -n '{repos: [{slug: "o/r", sources: ["tech-debt"]}, {slug: "o/broken", sources: ["tech-debt"]}],
        pr_label: "lbl", state_dir: "unused", workspace_root: "unused"}' > "$cfg_e"
state_e="$tmp_dir/state-e"
"$PUBLISH" --config "$cfg_e" --state-dir "$state_e" --now "$NOW" >/dev/null 2>"$tmp_dir/run-e.err"
rc_e=$?
assert_eq "a repo with no fixture (unreadable) exits non-zero" "1" "$rc_e"
assert_eq "  ... but the readable repo still gets its row" "1" \
  "$(jq -r 'select(.repo == "o/r")' "$state_e/revert-rate.jsonl" | jq -s 'length')"
assert_eq "  ... and the unreadable one gets none" "0" \
  "$(jq -r 'select(.repo == "o/broken")' "$state_e/revert-rate.jsonl" 2>/dev/null | jq -s 'length')"
assert_contains "  ... and says why on stderr" "$(cat "$tmp_dir/run-e.err")" "o/broken"

# ============================================================================
# Run G: cumulative rolls forward across two runs on a second repo (o/r2) —
# the second run mines only the delta since the first run's own settled
# boundary, and the settled portion (#201/#202, already >48h old at the
# first run's `now`) is never re-mined at all.
#
#   #201  merged 2026-08-20 (settled well before run 1)
#   #202  merged 2026-08-29 (settled well before run 1)
#   #203  merged 2026-08-30, #204 "fix: correct z" merged 2026-08-31,
#         referencing #203 — both still inside run 1's last-48h tail
#         (since_recent = 2026-08-30), so unsettled as of run 1.
#   Run 1: --now 2026-09-01T00:00:00Z. cumulative = #201-#204 (n=4, 1
#   follow-up), all mined fresh (no cache yet) — same figure a full re-mine
#   would give, seeding the cache.
#
#   #205  merged 2026-09-01, #206 "Revert \"Add w\"" merged 2026-09-01T12:00,
#         referencing #205 — both merge after run 1's settled boundary, so
#         run 2 must mine them.
#   #207  merged 2026-09-04 (inside run 2's own last-48h tail).
#   Run 2: --now 2026-09-05T00:00:00Z, same state dir, --window-days 3 (so
#   the rolling-window pass — unrelated to the cumulative cache — never
#   reaches back to #201/#202 either; run 1 already exercised the default
#   14-day window, so this doesn't lose coverage). #201/#202's per-PR detail
#   endpoints are blocked in the stub for this run — if the implementation
#   re-mines the whole since-baseline population instead of rolling the
#   cache forward, this run fails instead of quietly passing.
#   cumulative = #201-#207 (n=7: #203/#204's follow-up plus #205/#206's
#   revert, both now settled; #207 still in the tail) = 1 revert, 1
#   follow-up, rate = 2/7 = 0.286.
# ============================================================================
cat > "$STUB_DIR/hits-o_r2.json" <<'EOF'
[
  {"number": 201, "title": "Add x", "created_at": "2026-08-20T00:00:00Z", "pull_request": {"merged_at": "2026-08-20T00:00:00Z"}},
  {"number": 202, "title": "Add y", "created_at": "2026-08-29T00:00:00Z", "pull_request": {"merged_at": "2026-08-29T00:00:00Z"}},
  {"number": 203, "title": "Add z", "created_at": "2026-08-30T00:00:00Z", "pull_request": {"merged_at": "2026-08-30T00:00:00Z"}},
  {"number": 204, "title": "fix: correct z", "created_at": "2026-08-31T00:00:00Z", "pull_request": {"merged_at": "2026-08-31T00:00:00Z"}}
]
EOF
for n in 201 202 203 204; do
  printf '[]\n' > "$STUB_DIR/reviews-$n.json"
  printf '[{"filename": "file-%s.txt"}]\n' "$n" > "$STUB_DIR/files-$n.json"
  printf '[]\n' > "$STUB_DIR/timeline-$n.json"
done
cat > "$STUB_DIR/timeline-203.json" <<'EOF'
[{"event": "cross-referenced",
  "source": {"issue": {"number": 204, "title": "fix: correct z",
                        "pull_request": {"merged_at": "2026-08-31T00:00:00Z"}}}}]
EOF

cfg_g="$tmp_dir/config-g.json"
write_config "$cfg_g" '{"source": "x", "generated": "2026-08-15", "repos": []}'
jq '.repos = [{slug: "o/r2", sources: ["tech-debt"]}]' "$cfg_g" > "$cfg_g.tmp" && mv "$cfg_g.tmp" "$cfg_g"
state_g="$tmp_dir/state-g"

"$PUBLISH" --config "$cfg_g" --state-dir "$state_g" --now "$NOW" >/dev/null 2>"$tmp_dir/run-g1.err"
assert_eq "run G1 exits 0" "0" "$?"
row_g1="$(cat "$state_g/revert-rate.jsonl")"
assert_eq "run G1: cumulative n = 4 (#201-#204, no cache yet)" "4" "$(jq -r '.cumulative.n' <<<"$row_g1")"
assert_eq "run G1: 0 reverts" "0" "$(jq -r '.cumulative.reverts' <<<"$row_g1")"
assert_eq "run G1: 1 follow-up (#203 by #204)" "1" "$(jq -r '.cumulative.follow_up_fixes' <<<"$row_g1")"
assert_eq "run G1: rate = 1/4 = 0.25" "0.25" "$(jq -r '.cumulative.rate' <<<"$row_g1")"
assert_eq "run G1 seeds the settled-state cache" "2026-08-30T00:00:00Z" \
  "$(jq -r '.["o/r2"].settled_until' "$state_g/revert-rate-cumulative-state.json")"
assert_eq "  ... settled aggregate = #201/#202 only (n=2, clean)" '{"count":2,"post_merge":{"reverts":0,"follow_up_fixes":0}}' \
  "$(jq -c '.["o/r2"].settled_aggregate' "$state_g/revert-rate-cumulative-state.json")"

jq -s '.[0] + .[1]' "$STUB_DIR/hits-o_r2.json" - <<'EOF' > "$STUB_DIR/hits-o_r2.json.tmp"
[
  {"number": 205, "title": "Add w", "created_at": "2026-09-01T00:00:00Z", "pull_request": {"merged_at": "2026-09-01T00:00:00Z"}},
  {"number": 206, "title": "Revert \"Add w\"", "created_at": "2026-09-01T12:00:00Z", "pull_request": {"merged_at": "2026-09-01T12:00:00Z"}},
  {"number": 207, "title": "Add v", "created_at": "2026-09-04T00:00:00Z", "pull_request": {"merged_at": "2026-09-04T00:00:00Z"}}
]
EOF
mv "$STUB_DIR/hits-o_r2.json.tmp" "$STUB_DIR/hits-o_r2.json"
for n in 205 206 207; do
  printf '[]\n' > "$STUB_DIR/reviews-$n.json"
  printf '[{"filename": "file-%s.txt"}]\n' "$n" > "$STUB_DIR/files-$n.json"
  printf '[]\n' > "$STUB_DIR/timeline-$n.json"
done
cat > "$STUB_DIR/timeline-205.json" <<'EOF'
[{"event": "cross-referenced",
  "source": {"issue": {"number": 206, "title": "Revert \"Add w\"",
                        "pull_request": {"merged_at": "2026-09-01T12:00:00Z"}}}}]
EOF

printf '201\n202\n' > "$STUB_DIR/blocked-numbers"
"$PUBLISH" --config "$cfg_g" --state-dir "$state_g" --now "2026-09-05T00:00:00Z" --window-days 3 \
  >/dev/null 2>"$tmp_dir/run-g2.err"
assert_eq "run G2 exits 0 (never re-mines the already-settled #201/#202)" "0" "$?"
rm -f "$STUB_DIR/blocked-numbers"
row_g2="$(tail -n1 "$state_g/revert-rate.jsonl")"
assert_eq "run G2: cumulative n = 7 (#201-#207)" "7" "$(jq -r '.cumulative.n' <<<"$row_g2")"
assert_eq "run G2: 1 revert (#205 by #206, newly settled)" "1" "$(jq -r '.cumulative.reverts' <<<"$row_g2")"
assert_eq "run G2: 1 follow-up (#203 by #204, rolled forward from the cache)" "1" "$(jq -r '.cumulative.follow_up_fixes' <<<"$row_g2")"
assert_eq "run G2: rate = 2/7 = 0.286" "0.286" "$(jq -r '.cumulative.rate' <<<"$row_g2")"
assert_eq "run G2 rolls settled_until forward" "2026-09-03T00:00:00Z" \
  "$(jq -r '.["o/r2"].settled_until' "$state_g/revert-rate-cumulative-state.json")"
assert_eq "  ... settled aggregate now includes #203-#206" '{"count":6,"post_merge":{"reverts":1,"follow_up_fixes":1}}' \
  "$(jq -c '.["o/r2"].settled_aggregate' "$state_g/revert-rate-cumulative-state.json")"

echo "---"
if [[ "$failures" -eq 0 ]]; then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
