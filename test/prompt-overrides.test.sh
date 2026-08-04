#!/usr/bin/env bash
#
# test/prompt-overrides.test.sh — regression test for
# lib/prompt-overrides.sh (docs/IMPLEMENTATION-PIPELINE-SPEC.md
# requirement 4a).
#
# The mechanism's whole safety argument is "absent overrides change nothing":
# every consumer who has not opted in must see today's exact prompt bytes and
# today's exact fingerprint behaviour. So the assertions here are, in order:
# no-op fidelity, then that `extend` and `replace` do what they say, then that
# the fingerprint (`stage_prompt_sha`) moves for every change that
# `stage_prompt_text` would reflect — including a configured file going
# missing, which `stage_prompt_text` silently tolerates but the fingerprint
# must not — and holds still for every change that `stage_prompt_text` would
# not reflect: the digest is content-addressed, so relocating the
# installation without changing a byte of served content computes the same
# fingerprint (it is compared fleet-wide across the shared log). The
# structural shape of `prompt_overrides` itself — an unknown stage key, a
# non-object stage value, a non-array `extend` — is config.schema.json's
# concern, not this file's; test/config-schema.test.sh covers it.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/prompt-overrides.test.sh
#
# Exit status is 0 iff every assertion passed.

# shellcheck disable=SC2317  # assertions run indirectly, inside command substitutions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/prompt-overrides.sh
. "$SCRIPT_DIR/lib/prompt-overrides.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

prompts_dir="$tmp_dir/prompts"
state_dir="$tmp_dir/state"
mkdir -p "$prompts_dir" "$state_dir"
printf 'base coordinator prompt\n' > "$prompts_dir/coordinator.md"
printf 'base implementor prompt\n' > "$prompts_dir/implementor.md"

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
assert_ne() {
  local desc="$1" a="$2" b="$3"
  if [[ "$a" != "$b" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     both were: %s\n' "$desc" "$a"
    failures=$(( failures + 1 ))
  fi
}

# --- Absent overrides: byte-identical to `cat prompts/<stage>.md` ---
assert_eq "no override: prompt text is byte-identical to the base file" \
  "$(cat "$prompts_dir/coordinator.md")" \
  "$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator '{}')"

assert_eq "a stage missing from prompt_overrides behaves the same as {}" \
  "$(cat "$prompts_dir/coordinator.md")" \
  "$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator '{"implementor":{"extend":["x.md"]}}')"

sha_none="$(stage_prompt_sha "$prompts_dir" "$state_dir" coordinator '{}')"
assert_eq "no override: the fingerprint is just the base file's content hash, hashed — no path" \
  "$(sha256sum "$prompts_dir/coordinator.md" | cut -d' ' -f1 | sha256sum | cut -d' ' -f1)" \
  "$sha_none"

# --- extend: appended, in order, each wrapped with the specs-outrank-prompts
#     disclaimer, and the fingerprint moves ---
printf 'house rule one\n' > "$state_dir/one.md"
printf 'house rule two\n' > "$state_dir/two.md"
overrides_extend='{"coordinator":{"extend":["one.md","two.md"]}}'
extended="$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator "$overrides_extend")"

case "$extended" in
  *"base coordinator prompt"*"house rule one"*"house rule two"*)
    printf 'ok   - %s\n' "extend: base text precedes fragment one, which precedes fragment two" ;;
  *)
    printf 'FAIL - extend: fragments are not appended in configured order\n     actual: %s\n' "$extended"
    failures=$(( failures + 1 )) ;;
esac
case "$extended" in
  *"specs outrank every prompt"*)
    printf 'ok   - %s\n' "extend: each fragment carries the specs-outrank-prompts disclaimer" ;;
  *)
    printf 'FAIL - extend: missing the specs-outrank-prompts disclaimer\n'
    failures=$(( failures + 1 )) ;;
esac
case "$extended" in
  *"## Installation extension (one.md)"*)
    printf 'ok   - %s\n' "extend: a fragment's heading names the configured path, not the node-resolved one" ;;
  *)
    printf 'FAIL - extend: fragment heading does not use the configured path\n     actual: %s\n' "$extended"
    failures=$(( failures + 1 )) ;;
esac

sha_extend="$(stage_prompt_sha "$prompts_dir" "$state_dir" coordinator "$overrides_extend")"
assert_ne "extend changes the fingerprint relative to no override" "$sha_none" "$sha_extend"

# A ~-relative and a bare-relative extend path both resolve — the bare path
# against state_dir, the ~ path against $HOME (stubbed here to state_dir so
# the test needs no real home directory).
HOME="$state_dir" assert_eq "a bare relative extend path resolves against state_dir" \
  "$state_dir/one.md" \
  "$(HOME="$state_dir" resolve_prompt_override_path "$state_dir" "one.md")"
# shellcheck disable=SC2088  # the literal ~ here is the function's own input, not shell expansion.
assert_eq "a ~-relative extend path resolves against \$HOME" \
  "$state_dir/one.md" \
  "$(HOME="$state_dir" resolve_prompt_override_path "$state_dir" "~/one.md")"

# --- A configured extend file that is not readable is tolerated by the text
#     (no crash, nothing printed for it) but still changes the fingerprint,
#     so a broken path cannot reproduce the exact prior "no work" verdict. ---
overrides_missing='{"coordinator":{"extend":["one.md","does-not-exist.md"]}}'
text_missing="$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator "$overrides_missing")"
case "$text_missing" in
  *"does-not-exist"*)
    printf 'FAIL - a missing extend file must not appear in the assembled prompt\n'
    failures=$(( failures + 1 )) ;;
  *)
    printf 'ok   - %s\n' "a missing extend file is silently skipped in the assembled text" ;;
esac
sha_one_only="$(stage_prompt_sha "$prompts_dir" "$state_dir" coordinator '{"coordinator":{"extend":["one.md"]}}')"
sha_missing="$(stage_prompt_sha "$prompts_dir" "$state_dir" coordinator "$overrides_missing")"
assert_ne "a configured-but-missing extend file still changes the fingerprint" \
  "$sha_one_only" "$sha_missing"

# --- replace: substitutes the base file; extend (if any) still appends after
#     it; an unreadable replace path falls back to the shipped prompt. ---
printf 'whole replacement prompt\n' > "$state_dir/replacement.md"
overrides_replace='{"coordinator":{"replace":"replacement.md"}}'
replaced="$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator "$overrides_replace")"
assert_eq "replace: substitutes the base file entirely (no extend configured)" \
  "$(cat "$state_dir/replacement.md")" \
  "$replaced"

overrides_replace_and_extend='{"coordinator":{"replace":"replacement.md","extend":["one.md"]}}'
replaced_extended="$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator "$overrides_replace_and_extend")"
case "$replaced_extended" in
  *"whole replacement prompt"*"house rule one"*)
    printf 'ok   - %s\n' "replace + extend: the fragment still appends after the replacement base" ;;
  *)
    printf 'FAIL - replace + extend: fragment did not append after the replacement base\n     actual: %s\n' "$replaced_extended"
    failures=$(( failures + 1 )) ;;
esac

overrides_bad_replace='{"coordinator":{"replace":"does-not-exist.md"}}'
fallback="$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator "$overrides_bad_replace")"
assert_eq "an unreadable replace path falls back to the shipped prompt" \
  "$(cat "$prompts_dir/coordinator.md")" \
  "$fallback"

sha_replace="$(stage_prompt_sha "$prompts_dir" "$state_dir" coordinator "$overrides_replace")"
assert_ne "replace changes the fingerprint relative to no override" "$sha_none" "$sha_replace"
assert_ne "replace and extend produce different fingerprints from each other" "$sha_extend" "$sha_replace"

# --- The digest is content-addressed (it is compared fleet-wide across the
#     shared log, so nodes serving identical prompt bytes must agree): the
#     same config and the same bytes compute the same fingerprint wherever
#     the installation lives, and a change that does not alter the served
#     bytes does not move it. ---
reloc="$tmp_dir/relocated"
mkdir -p "$reloc/prompts" "$reloc/state"
cp "$prompts_dir/coordinator.md" "$reloc/prompts/coordinator.md"
cp "$state_dir/one.md" "$reloc/state/one.md"
overrides_portable='{"coordinator":{"extend":["one.md","gone.md"]}}'
assert_eq "relocating the installation with identical content leaves the fingerprint unchanged" \
  "$(stage_prompt_sha "$prompts_dir" "$state_dir" coordinator "$overrides_portable")" \
  "$(stage_prompt_sha "$reloc/prompts" "$reloc/state" coordinator "$overrides_portable")"
assert_eq "relocating the installation with identical content leaves the assembled text unchanged" \
  "$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator "$overrides_portable")" \
  "$(stage_prompt_text "$reloc/prompts" "$reloc/state" coordinator "$overrides_portable")"

printf 'base coordinator prompt\n' > "$state_dir/shipped-twin.md"
assert_eq "a replace file with the shipped prompt's exact content computes the no-override fingerprint" \
  "$sha_none" \
  "$(stage_prompt_sha "$prompts_dir" "$state_dir" coordinator '{"coordinator":{"replace":"shipped-twin.md"}}')"

# --- A different stage's override does not leak into this one, and an
#     absolute extend path is used as-is. ---
overrides_other_stage='{"implementor":{"extend":["one.md"]}}'
assert_eq "an override configured for a different stage has no effect here" \
  "$(cat "$prompts_dir/coordinator.md")" \
  "$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator "$overrides_other_stage")"

# --- An unreadable *base* prompt is not tolerated the way an unreadable
#     override is: it is a broken installation, and the caller runs under
#     `set -e`, so the cycle must die rather than launch a stage on an empty
#     prompt. This is the behaviour the bare `cat prompts/<stage>.md` had. ---
if stage_prompt_text "$prompts_dir" "$state_dir" nosuchstage '{}' >/dev/null 2>&1; then
  printf 'FAIL - an unreadable base prompt must make stage_prompt_text fail, not return empty\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - %s\n' "an unreadable base prompt fails rather than yielding an empty prompt"
fi

abs_frag="$tmp_dir/absolute-fragment.md"
printf 'absolute fragment\n' > "$abs_frag"
overrides_abs="$(jq -nc --arg p "$abs_frag" '{coordinator:{extend:[$p]}}')"
case "$(stage_prompt_text "$prompts_dir" "$state_dir" coordinator "$overrides_abs")" in
  *"absolute fragment"*)
    printf 'ok   - %s\n' "an absolute extend path is used as-is, not resolved against state_dir" ;;
  *)
    printf 'FAIL - an absolute extend path was not honoured\n'
    failures=$(( failures + 1 )) ;;
esac

echo
if (( failures == 0 )); then
  echo "All prompt-overrides assertions passed."
  exit 0
else
  echo "$failures prompt-overrides assertion(s) FAILED."
  exit 1
fi
