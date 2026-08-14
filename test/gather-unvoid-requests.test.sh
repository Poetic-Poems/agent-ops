#!/usr/bin/env bash
#
# test/gather-unvoid-requests.test.sh — regression test for
# scripts/gather-unvoid-requests.sh (requirement 34f): resolving every issue
# or pull request carrying the unvoid label to the item ids it names and the
# moment the label was applied, so lib/unvoid-label.sh has something to judge
# against — see the script's own header for why this source exists at all.
#
# No prior test covered this script at all. `gh` is stubbed via `PATH`, the
# same technique test/issues-prefetch.test.sh uses, so the assertions are
# about the shipped script rather than a copy of its logic.
#
# Run directly:
#
#   ./test/gather-unvoid-requests.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-unvoid-requests.sh"

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

# --- A stub `gh`, answering the three endpoints the script calls -----------
#
# The issues-with-label listing (`STUB_HITS`), each hit's labeling timeline
# (`$STUB_DIR/timeline-<n>.json`, default `[]`) and, for a pull request hit
# only, its branch name (`$STUB_DIR/branch-<n>.json`, default `""`).
mkdir -p "$tmp_dir/bin"
export STUB_DIR="$tmp_dir/fixtures"
mkdir -p "$STUB_DIR"
export STUB_HITS="$tmp_dir/hits.json"
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
  repos/*/issues\?labels=*) body="$(cat "$STUB_HITS")" ;;
  repos/*/issues/*/timeline)
    n="${path#repos/*/issues/}"; n="${n%%/*}"
    f="$STUB_DIR/timeline-$n.json"
    body="$([[ -f "$f" ]] && cat "$f" || echo '[]')"
    ;;
  repos/*/pulls/*)
    n="${path##*/pulls/}"
    f="$STUB_DIR/branch-$n.json"
    body="$([[ -f "$f" ]] && cat "$f" || echo '""')"
    ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1 ;;
esac
jq -rc "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# --- The ordinary case: one issue and one PR, each carrying the label ------
cat > "$STUB_HITS" <<'EOF'
[
  {"number": 52, "title": "Reopen this one", "body": "See TD26072114 for the record.",
   "html_url": "https://github.com/o/r/issues/52"},
  {"number": 92, "title": "A pull request", "body": "Fixes the thing.",
   "html_url": "https://github.com/o/r/pull/92",
   "pull_request": {"url": "https://api.github.com/repos/o/r/pulls/92"}}
]
EOF
cat > "$STUB_DIR/timeline-52.json" <<'EOF'
[{"event": "labeled", "label": {"name": "unvoided"}, "created_at": "2026-07-25T20:00:00Z"}]
EOF
cat > "$STUB_DIR/timeline-92.json" <<'EOF'
[{"event": "labeled", "label": {"name": "unvoided"}, "created_at": "2026-07-25T21:40:28Z"}]
EOF
printf '{"head": {"ref": "td/TD26072114-unvoid"}}' > "$STUB_DIR/branch-92.json"

out="$("$GATHER" o/r)"
assert_eq "both labelled hits are reported" "2" "$(jq 'length' <<<"$out")"

req52="$(jq -c '.[] | select(.number == 52)' <<<"$out")"
assert_eq "the issue names itself as an item id" "1" \
  "$(jq -r '.items | index("52") != null' <<<"$req52" | grep -c true)"
assert_eq "  ... and picks up an id from its body" "1" \
  "$(jq -r '.items | index("TD26072114") != null' <<<"$req52" | grep -c true)"
assert_eq "  ... kind is issue" "issue" "$(jq -r '.kind' <<<"$req52")"
assert_eq "  ... labelled_at is the timeline's own stamp" "2026-07-25T20:00:00Z" \
  "$(jq -r '.labelled_at' <<<"$req52")"

req92="$(jq -c '.[] | select(.number == 92)' <<<"$out")"
assert_eq "a pull request's own branch resolves an item id its prose does not" "1" \
  "$(jq -r '.items | index("TD26072114") != null' <<<"$req92" | grep -c true)"
assert_eq "  ... kind is pr" "pr" "$(jq -r '.kind' <<<"$req92")"

assert_eq "results are sorted by labelled_at" '[52,92]' \
  "$(jq -c '[.[].number]' <<<"$out")"

# --- No timeline event: no request, guessing a timestamp is refused --------
cat > "$tmp_dir/hits-no-timeline.json" <<'EOF'
[{"number": 77, "title": "TD26072114", "body": "", "html_url": "https://github.com/o/r/issues/77"}]
EOF
cp "$STUB_HITS" "$tmp_dir/hits.json.bak"
cp "$tmp_dir/hits-no-timeline.json" "$STUB_HITS"
out_no_tl="$("$GATHER" o/r)"
assert_eq "a hit with no labeling timeline event yields no request" "[]" "$out_no_tl"
cp "$tmp_dir/hits.json.bak" "$STUB_HITS"

# --- Fails safe: an unreadable listing yields [] and exit 0 ----------------
cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "stub gh: HTTP 500" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin/gh"
degraded="$("$GATHER" o/r 2>/dev/null)"
degraded_rc=$?
assert_eq "a failing listing degrades to an empty array" "[]" "$degraded"
assert_eq "  ... and still exits 0" "0" "$degraded_rc"

# --- The argv cap (requirement 4g, TD-PPagop-26081406) ---
#
# The request build ($hit, the whole issue/PR listing hit, and $items, its
# matched item refs) and the per-request array append both used to ride into
# jq as --argjson: unbounded past this call, the same reasoning
# TD-PPagop-26081401 already applied elsewhere. Past MAX_ARG_STRLEN (131072
# bytes) the build died at execve, so this repo's whole unvoid-request band
# came out empty. Requirement 4g moves both onto stdin; this drives the real
# script over 20 labelled issues, each padded past what a single hit alone
# needs, so the array-assembly accumulator crosses the cap well before the
# last one.
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
  repos/*/issues\?labels=*) body="$(cat "$STUB_HITS")" ;;
  repos/*/issues/*/timeline)
    n="${path#repos/*/issues/}"; n="${n%%/*}"
    f="$STUB_DIR/timeline-$n.json"
    body="$([[ -f "$f" ]] && cat "$f" || echo '[]')"
    ;;
  repos/*/pulls/*)
    n="${path##*/pulls/}"
    f="$STUB_DIR/branch-$n.json"
    body="$([[ -f "$f" ]] && cat "$f" || echo '""')"
    ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1 ;;
esac
jq -rc "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"

oversized_body="$(head -c 8000 < /dev/zero | tr '\0' 'x')"
big_hits="$(jq -nc --arg body "$oversized_body" \
  '[range(100; 120) | {number: ., title: "padded", body: $body,
                        html_url: ("https://github.com/o/r/issues/" + (. | tostring))}]')"
assert_eq "the oversized hits fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_hits" | wc -c) > 131072 ))"
printf '%s' "$big_hits" > "$STUB_HITS"
for n in $(seq 100 119); do
  printf '[{"event": "labeled", "label": {"name": "unvoided"}, "created_at": "2026-07-25T21:%02d:00Z"}]' \
    "$(( n - 100 ))" > "$STUB_DIR/timeline-$n.json"
done

big_out="$("$GATHER" o/r 2>"$tmp_dir/big.err")"
big_rc=$?
assert_eq "a hits array past the argv cap still exits 0" "0" "$big_rc"
assert_eq "  ... and every one of the 20 labelled issues is reported" \
  "20" "$(jq 'length' <<<"$big_out")"
assert_eq "  ... none dropped, including the last one accumulated" \
  "1" "$(jq '[.[] | select(.number == 119)] | length' <<<"$big_out")"
assert_eq "  ... each still carries its own item id (itself, as an issue)" \
  "20" "$(jq '[.[] | (.number | tostring) as $n | select(.items | index($n))] | length' <<<"$big_out")"

echo
if (( failures == 0 )); then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
