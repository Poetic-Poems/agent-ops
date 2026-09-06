#!/usr/bin/env bash
#
# test/review-context.test.sh — regression test for lib/review-context.sh
# (issue #589, D7 in docs/ROADMAP.md: per-repository instructions and
# context for the Reviewer-Agent).
#
# What matters here is the trust boundary the whole facility exists to
# enforce: a configured (installation-held) source is exactly as trustworthy
# as `prompt_overrides`, but — unlike a `prompt_overrides` path — a missing
# one is a loud failure rather than a silent skip (review_context_missing_configured,
# shared by review-cycle.sh's own fail-fast sweep and scripts/doctor.sh's
# `fail`); a repository-held source (`repo_context_file`) is the opposite —
# admissible as context only, and simply absent when the file is not there,
# never a fault. So the assertions below are, in order: path resolution,
# the missing-configured-path detector, config_project_review_repos'
# resolution precedence (requirement 342) as read by this facility, building
# the runtime-input JSON (instructions/context, in order, each attributed),
# the absent-repo-file case, the size cap and its truncation flag, and that
# the digest reduction never carries the text itself.
#
# The structural shape of the new config.schema.json keys — array-only,
# never a bare string — is that schema's concern, not this file's;
# test/config-schema.test.sh covers it.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/review-context.test.sh
#
# Exit status is 0 iff every assertion passed.

# shellcheck disable=SC2317  # assertions run indirectly, inside command substitutions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/review-context.sh
. "$SCRIPT_DIR/lib/review-context.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

state_dir="$tmp_dir/state"
clone_dir="$tmp_dir/clone"
mkdir -p "$state_dir" "$clone_dir/.github"

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
assert_json_eq() {
  local desc="$1" expected_expr="$2" actual_json="$3"
  if jq -e "$expected_expr" <<<"$actual_json" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     check: %s\n     against: %s\n' "$desc" "$expected_expr" "$actual_json"
    failures=$(( failures + 1 ))
  fi
}

# --- review_context_resolve_path: ~ expansion, relative-to-BASE, absolute as-is ---
assert_eq "a relative path resolves against BASE" \
  "$state_dir/instructions.md" \
  "$(review_context_resolve_path "$state_dir" "instructions.md")"
assert_eq "an absolute path is used as-is" \
  "/etc/instructions.md" \
  "$(review_context_resolve_path "$state_dir" "/etc/instructions.md")"
# shellcheck disable=SC2088  # the literal ~ here is the function's own input, not shell expansion.
assert_eq "a ~-prefixed path expands against \$HOME, not BASE" \
  "$state_dir/instructions.md" \
  "$(HOME="$state_dir" review_context_resolve_path "$state_dir" "~/instructions.md")"
assert_eq "an empty RAW resolves to nothing" \
  "" \
  "$(review_context_resolve_path "$state_dir" "")"

# --- review_context_missing_configured: the fail-fast detector shared by
#     review-cycle.sh (before its lock) and scripts/doctor.sh (a `fail`) ---
printf 'weigh security first\n' > "$state_dir/present.md"
repos_ok='[{"slug":"a/b","review_instructions":["present.md"],"review_context":[]}]'
assert_eq "every configured path readable: nothing is reported missing" \
  "" \
  "$(review_context_missing_configured "$state_dir" "$repos_ok")"

repos_missing='[{"slug":"a/b","review_instructions":["present.md","absent.md"],"review_context":["also-absent.md"]}]'
missing_out="$(review_context_missing_configured "$state_dir" "$repos_missing")"
assert_eq "two missing paths across two fields are both reported, present.md is not" \
  "2" "$(wc -l <<<"$missing_out")"
case "$missing_out" in
  *$'a/b\treview_instructions\tabsent.md\t'*) printf 'ok   - %s\n' "the missing review_instructions entry names its slug, field and configured path" ;;
  *) printf 'FAIL - missing review_instructions entry not reported as expected\n     actual: %s\n' "$missing_out"; failures=$(( failures + 1 )) ;;
esac
case "$missing_out" in
  *$'a/b\treview_context\talso-absent.md\t'*) printf 'ok   - %s\n' "the missing review_context entry names its slug, field and configured path" ;;
  *) printf 'FAIL - missing review_context entry not reported as expected\n     actual: %s\n' "$missing_out"; failures=$(( failures + 1 )) ;;
esac

repos_empty='[{"slug":"a/b","review_instructions":[],"review_context":[]}]'
assert_eq "no configured review_instructions/review_context is vacuously not a fault" \
  "" \
  "$(review_context_missing_configured "$state_dir" "$repos_empty")"

# --- review_context_build_json: instructions and context, each attributed,
#     in configured order ---
printf 'installation instructions text\n' > "$state_dir/instr.md"
printf 'installation context text\n' > "$state_dir/ctx-a.md"
printf 'more installation context\n' > "$state_dir/ctx-b.md"
printf 'contributor-written repo context\n' > "$clone_dir/.github/REVIEW-CONTEXT.md"

entry_full='{"review_instructions":["instr.md"],"review_context":["ctx-a.md","ctx-b.md"],"repo_context_file":".github/REVIEW-CONTEXT.md"}'
built_full="$(review_context_build_json "$state_dir" "$clone_dir" "$entry_full")"

assert_json_eq "one instructions entry, source config, correct origin and text" \
  '.instructions | length == 1 and .[0].source == "config" and .[0].origin == "instr.md"
   and (.[0].text | test("installation instructions text"))' "$built_full"
assert_json_eq "two config context entries precede the one repository-sourced entry, in order" \
  '.context | length == 3
   and .[0].source == "config" and .[0].origin == "ctx-a.md"
   and .[1].source == "config" and .[1].origin == "ctx-b.md"
   and .[2].source == "repository" and .[2].origin == ".github/REVIEW-CONTEXT.md"
   and (.[2].text | test("contributor-written"))' "$built_full"
assert_json_eq "nothing is reported truncated below the size cap" \
  '([.instructions, .context] | flatten | map(.truncated) | any) == false' "$built_full"

# --- Absent repo_context_file: simply absent, never a fault, unlike a
#     configured review_instructions/review_context path ---
entry_no_repo_file='{"review_instructions":[],"review_context":["ctx-a.md"],"repo_context_file":"NOPE.md"}'
built_no_repo_file="$(review_context_build_json "$state_dir" "$clone_dir" "$entry_no_repo_file")"
assert_json_eq "a repo_context_file that does not exist in the clone contributes no context entry" \
  '.context | length == 1 and .[0].source == "config"' "$built_no_repo_file"

entry_empty='{"review_instructions":[],"review_context":[],"repo_context_file":""}'
built_empty="$(review_context_build_json "$state_dir" "$clone_dir" "$entry_empty")"
assert_eq "nothing configured resolves to two empty arrays" \
  '{"instructions":[],"context":[]}' "$(jq -c . <<<"$built_empty")"

# --- Path traversal in repo_context_file: silently not configured, on the
#     same "a typo does not fail a cycle" terms as an absent file (never a
#     fail-fast key, unlike review_instructions/review_context) ---
printf 'outside the clone\n' > "$tmp_dir/outside.txt"
entry_traversal='{"review_instructions":[],"review_context":[],"repo_context_file":"../outside.txt"}'
built_traversal="$(review_context_build_json "$state_dir" "$clone_dir" "$entry_traversal")"
assert_eq "a repo_context_file containing .. contributes nothing, rather than escaping the clone" \
  '{"instructions":[],"context":[]}' "$(jq -c . <<<"$built_traversal")"

# --- Size cap and truncation flag: a fixed bound, with truncated set rather
#     than the text silently trimmed without saying so ---
python3 -c "import sys; sys.stdout.write('x' * (${REVIEW_CONTEXT_SOURCE_MAX_BYTES} + 500))" > "$state_dir/big.md"
entry_big='{"review_instructions":["big.md"],"review_context":[],"repo_context_file":""}'
built_big="$(review_context_build_json "$state_dir" "$clone_dir" "$entry_big")"
assert_json_eq "an oversized source is capped at REVIEW_CONTEXT_SOURCE_MAX_BYTES and marked truncated" \
  ".instructions[0].truncated == true and .instructions[0].bytes == ${REVIEW_CONTEXT_SOURCE_MAX_BYTES}" \
  "$built_big"

# --- review_context_sources_digest: every resolved source, typed and
#     attributed, with a digest — but never the text itself ---
digested="$(review_context_sources_digest "$built_full")"
assert_json_eq "the digest array carries one entry per resolved source (four here)" \
  'length == 4' "$digested"
assert_json_eq "every digest entry is typed instructions/context and carries no text field" \
  'map(has("text")) | any == false' "$digested"
# The text is carried through a `$(...)` capture (see _review_context_entry),
# which strips trailing newlines exactly as `cat`-in-command-substitution
# does elsewhere in this repo (e.g. lib/prompt-overrides.sh's own fragment
# assembly) — so the digest is of the trailing-newline-stripped text, not the
# raw file bytes.
capped_instr="$(head -c "$REVIEW_CONTEXT_SOURCE_MAX_BYTES" "$state_dir/instr.md")"
expected_digest="sha256:$(printf '%s' "$capped_instr" | sha256sum | cut -d' ' -f1)"
assert_eq "the instructions entry's digest matches a direct sha256 of the same (possibly capped) text" \
  "$expected_digest" \
  "$(jq -r '.[] | select(.type == "instructions") | .digest' <<<"$digested")"

echo
if (( failures == 0 )); then
  echo "All review-context assertions passed."
  exit 0
else
  echo "$failures review-context assertion(s) FAILED."
  exit 1
fi
