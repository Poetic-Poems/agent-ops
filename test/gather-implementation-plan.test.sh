#!/usr/bin/env bash
#
# test/gather-implementation-plan.test.sh — regression test for
# scripts/gather-implementation-plan.sh (requirement 3y; TD-PPagop-26081307):
# the source that hands the Refiner every open task in a repo's
# implementation-plan document pre-fetched.
#
# Behaviours asserted, each of which fails silently if broken:
#
#   - **Only an open (`[ ]`) task-list line is a candidate.** A done (`[x]`)
#     one is never selectable.
#   - **Only a whole-word id matching `WORK_GONE_PLAN_RE`
#     (lib/work-gone.sh) counts** — a line with no colon-terminated id, or
#     whose id doesn't start with an upper-case letter, is skipped rather
#     than guessed at.
#   - **`-`, `*` and `N.` bullets are all recognised.**
#   - **Each candidate carries `source`, `ref`/`id` (the task's own id),
#     `title` (the text after the id) and `body` (the whole line
#     verbatim)** — everything the Refiner needs with no second read.
#   - **Document order is preserved** — this is not sorted, unlike
#     gather-tech-debt.sh's id order.
#   - **A missing or unreadable document contributes `[]`**, silently for a
#     404 and loudly (stderr) for a genuine API failure — the same
#     distinction gather-tech-debt.sh makes.
#
# The gatherer is run for real against a stubbed `gh`, the same shape
# test/gather-tech-debt.test.sh uses.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gather-implementation-plan.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-implementation-plan.sh"

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

cat >"$tmp_dir/PLAN.md" <<'EOF'
# Plan

- [x] W01-setup: done already, never a candidate
- [ ] W10-breach-handling: handle the breach case
- [ ] BAD_ID no colon here, skipped
* [ ] W11-followup: a starred bullet
1. [ ] W12-numbered: a numbered bullet
- [ ] lowercase-bad: does not match the plan-task id shape
EOF

# --- A stub `gh`, the same shape test/gather-tech-debt.test.sh uses --------
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
[[ "\${1:-}" == "api" ]] || { echo "stub gh: unexpected call: \$*" >&2; exit 1; }
path="\${2:-}"
case "\$path" in
  repos/o/r/contents/docs/PLAN.md\\?ref=*)
    case "\${STUB_MODE:-hit}" in
      hit)
        b64="\$(base64 -w0 "$tmp_dir/PLAN.md")"
        printf '{"content":"%s"}' "\$b64"
        ;;
      404)
        echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
        ;;
      *)
        echo "gh: error connecting to api.github.com" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "stub gh: unexpected call: \$*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

run() {  # prints stdout; stderr lands in $tmp_dir/err
  "$GATHER" "o/r" main docs/PLAN.md 2>"$tmp_dir/err"
}

# --- Open tasks with a valid id are candidates, in document order ----------
export STUB_MODE=hit
out="$(run)"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "exactly the three well-formed open tasks are candidates" "3" "$(jq 'length' <<<"$out")"
assert_eq "the done task never appears" "0" \
  "$(jq '[.[] | select(.id == "W01-setup")] | length' <<<"$out")"
assert_eq "a line with no colon-terminated id never appears" "0" \
  "$(jq '[.[] | select(.body | test("BAD_ID"))] | length' <<<"$out")"
assert_eq "an id not matching WORK_GONE_PLAN_RE never appears" "0" \
  "$(jq '[.[] | select(.id == "lowercase-bad")] | length' <<<"$out")"
assert_eq "document order is preserved, not sorted" "W10-breach-handling W11-followup W12-numbered" \
  "$(jq -r '[.[].id] | join(" ")' <<<"$out")"
assert_eq "source is implementation-plan" "implementation-plan" "$(jq -r '.[0].source' <<<"$out")"
assert_eq "ref is the task's own id" "W10-breach-handling" "$(jq -r '.[0].ref' <<<"$out")"
assert_eq "title is the text after the id" "handle the breach case" "$(jq -r '.[0].title' <<<"$out")"
assert_eq "url points at the plan document on the default branch" \
  "https://github.com/o/r/blob/main/docs/PLAN.md" "$(jq -r '.[0].url' <<<"$out")"
assert_eq "body is the whole task-list line, verbatim" \
  "- [ ] W10-breach-handling: handle the breach case" "$(jq -r '.[0].body' <<<"$out")"
assert_eq "a starred bullet is recognised" "a starred bullet" \
  "$(jq -r '.[] | select(.id == "W11-followup") | .title' <<<"$out")"
assert_eq "a numbered bullet is recognised" "a numbered bullet" \
  "$(jq -r '.[] | select(.id == "W12-numbered") | .title' <<<"$out")"

# --- A missing document is a normal, silent [] ------------------------------
export STUB_MODE=404
out="$(run)"; rc=$?
assert_eq "a missing document contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... and says nothing on stderr" "" "$(cat "$tmp_dir/err")"
export STUB_MODE=hit

# --- An API failure is [] as well, but a loud one --------------------------
export STUB_MODE=error
out="$(run)"; rc=$?
assert_eq "an API failure contributes [] too" "[]" "$out"
assert_eq "  ... and still exits 0" "0" "$rc"
assert_eq "  ... but leaves gh's diagnosis on stderr" "1" \
  "$( [[ -s "$tmp_dir/err" ]] && echo 1 || echo 0 )"
export STUB_MODE=hit

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
