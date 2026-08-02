#!/usr/bin/env bash
#
# test/work-gone.test.sh — regression test for requirement 34i: the blocks whose
# work no longer exists, and the register read that decides one of the three
# classes.
#
# Both halves are asserted from both sides, because the two failure directions
# are not alike and only one of them is loud:
#
#   - **Too eager** clears a block out from under work that is still real. The
#     item goes back in the candidate pool, a Co-Ordinator selects it, an
#     Implementor runs, and it re-blocks — a full cycle spent to arrive where it
#     started, hourly, for as long as the mistake stands. So every "unknown"
#     shape is asserted to clear nothing: a repo missing from the digest, a repo
#     whose digest says `ok: false`, an id no register file claims, an id two of
#     them claim, and every class the rule does not cover.
#   - **Too shy** is the defect this requirement exists to fix and is silent: the
#     item stays on the dashboard as blocked and the Enabler pays for a full
#     re-examination to learn what a `gh` read already on disk would have said.
#     So the positives are asserted just as hard — the closed issue, the merged
#     pull request, the resolved and `not-debt` register entries, and the legacy
#     id that names an item whose file has since been renamed.
#
# `scripts/gather-register-status.sh` is run for real against a stubbed `gh`
# reproducing the contents API's own shapes, so what is asserted is the shipped
# script rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/work-gone.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-register-status.sh"

# shellcheck source=lib/work-gone.sh
. "$SCRIPT_DIR/lib/work-gone.sh"

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

# --- work_gone_clearances -------------------------------------------------------

# One repo, sampled cleanly: issue 126 and pull request 9 are open, everything
# else named below is not.
states='[{"slug":"o/a","ok":true,
          "issues":[{"n":126},{"n":130}],
          "open_prs":[{"n":9},{"n":12}]}]'

blocked_of() {  # blocked_of <item> [repo]
  jq -nc --arg i "$1" --arg r "${2-o/a}" '[{repo: $r, item: $i, ts: "2026-07-01T00:00:00Z"}]'
}
reason_of() {  # reason_of <clearances-json>
  jq -r 'if length == 0 then "" else .[0].reason end' <<<"$1"
}

assert_eq "a closed issue clears its block" \
  "issue #125 is closed" \
  "$(reason_of "$(work_gone_clearances "$(blocked_of 125)" "$states")")"
assert_eq "an open issue does not" \
  "" "$(reason_of "$(work_gone_clearances "$(blocked_of 126)" "$states")")"

for ref in pr-146-abandoned-719c4c5d6aa1 pr-146-conflict-719c4c5d6aa1 pr-146-review-3312; do
  assert_eq "a merged or closed pull request clears its $(cut -d- -f3 <<<"$ref") block" \
    "pull request #146 is closed or merged" \
    "$(reason_of "$(work_gone_clearances "$(blocked_of "$ref")" "$states")")"
done
assert_eq "an open pull request does not" \
  "" "$(reason_of "$(work_gone_clearances "$(blocked_of pr-9-abandoned-abc123abc123)" "$states")")"

register='{"o/a":{"TD26072401":"resolved","TD-PPpoet-26072602":"not-debt","TD-PPpoet-26072605":"open"}}'
assert_eq "a resolved register item clears its block" \
  "the tech-debt register records it resolved" \
  "$(reason_of "$(work_gone_clearances "$(blocked_of TD26072401)" "$states" "$register")")"
assert_eq "so does one ruled not-debt" \
  "the tech-debt register records it not-debt" \
  "$(reason_of "$(work_gone_clearances "$(blocked_of TD-PPpoet-26072602)" "$states" "$register")")"
assert_eq "an open register item does not" \
  "" "$(reason_of "$(work_gone_clearances "$(blocked_of TD-PPpoet-26072605)" "$states" "$register")")"
assert_eq "and neither does one the register read never answered for" \
  "" "$(reason_of "$(work_gone_clearances "$(blocked_of TD-PPpoet-26072606)" "$states" "$register")")"

# Unknown is not gone. Each of these is a state the cycle could not read, and
# each must leave the item exactly where it was.
assert_eq "a repo whose digest could not be sampled clears nothing" \
  "0" "$(work_gone_clearances "$(blocked_of 125)" \
          '[{"slug":"o/a","ok":false}]' | jq 'length')"
assert_eq "a repo absent from the digest clears nothing" \
  "0" "$(work_gone_clearances "$(blocked_of 125 o/z)" "$states" | jq 'length')"
assert_eq "a block naming no repo clears nothing" \
  "0" "$(work_gone_clearances "$(blocked_of 125 '')" "$states" | jq 'length')"
assert_eq "an empty register map clears no register item" \
  "0" "$(work_gone_clearances "$(blocked_of TD26072401)" "$states" '{}' | jq 'length')"

# The classes deliberately left to the Enabler: a review recommendation, an
# implementation-plan item, a security finding. A finding is the one that must
# never be inferred from absence — gather-findings.sh degrades to [] on an API
# error by design, so "no alerts" and "the alerts API is down" look identical.
for item in review-2026-07-11-R-02 W10-breach-handling dependabot-alert-4 \
            code-scanning-alert-7 register-hygiene-413128de0d60; do
  assert_eq "a $item block is left for the Enabler" \
    "0" "$(work_gone_clearances "$(blocked_of "$item")" "$states" "$register" | jq 'length')"
done

# Several at once, across repos, with only the decidable ones cleared.
many='[{"repo":"o/a","item":"125"},{"repo":"o/a","item":"126"},
       {"repo":"o/a","item":"pr-146-abandoned-719c4c5d6aa1"},
       {"repo":"o/a","item":"TD26072401"},{"repo":"o/a","item":"review-2026-07-11-R-02"},
       {"repo":"o/b","item":"7"}]'
assert_eq "a mixed blocked list clears exactly the decidable ones" \
  "125 TD26072401 pr-146-abandoned-719c4c5d6aa1" \
  "$(work_gone_clearances "$many" "$states" "$register" | jq -r '[.[].item] | sort | join(" ")')"

# Malformed input costs a clearance, never the cycle it runs in.
assert_eq "unreadable input yields no clearances" \
  "[]" "$(work_gone_clearances 'not json' "$states" "$register")"

# --- work_gone_register_ids -----------------------------------------------------

assert_eq "only register-shaped ids are asked about, grouped by repo" \
  '{"o/a":["TD-PPpoet-26072602","TD26072401"],"o/b":["TD26080101"]}' \
  "$(work_gone_register_ids '[{"repo":"o/a","item":"TD26072401"},
                              {"repo":"o/a","item":"TD-PPpoet-26072602"},
                              {"repo":"o/a","item":"125"},
                              {"repo":"o/a","item":"pr-9-abandoned-abc123abc123"},
                              {"repo":"o/a","item":"review-2026-07-11-R-02"},
                              {"repo":"o/b","item":"TD26080101"}]')"
assert_eq "a repo with no register blocks is not named at all" \
  "{}" "$(work_gone_register_ids '[{"repo":"o/a","item":"125"}]')"
assert_eq "and neither is a blocked item with no repo to read it in" \
  "{}" "$(work_gone_register_ids '[{"repo":"","item":"TD26072401"}]')"

# --- gather-register-status.sh, against a stubbed contents API ------------------
#
# The stub answers the two endpoints the gatherer calls and reproduces GitHub's
# shapes: a directory listing of `{name, type}`, and a file whose body arrives
# base64-encoded in `.content`. `$STUB_MODE` steers the listing's failures — a
# 404 prints the API's error object on stdout and gh's summary on stderr (which
# is what real gh does, and why the gatherer reads the JSON rather than parsing
# the summary), any other failure prints only the stderr line.
mkdir -p "$tmp_dir/bin" "$tmp_dir/items"
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected call: $*" >&2; exit 1; }
path="${2:-}"
case "$path" in
  */contents/tech-debt\?*)
    case "${STUB_MODE:-hit}" in
      hit)
        for f in "$STUB_ITEMS"/*; do
          [[ -e "$f" ]] || continue
          printf '{"name":"%s","type":"file"}\n' "$(basename "$f")"
        done | jq -s '.'
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
  */contents/tech-debt/*)
    name="${path#*/contents/tech-debt/}"
    name="${name%%\?*}"
    [[ -f "$STUB_ITEMS/$name" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    # `--jq .content` makes real gh print the string raw, wrapped exactly as
    # the API encoded it — which is why the gatherer strips newlines before
    # decoding. Without the flag it would be the whole object.
    if [[ "$*" == *--jq* ]]; then
      base64 < "$STUB_ITEMS/$name"
    else
      printf '{"content":"%s","encoding":"base64"}\n' "$(base64 -w0 < "$STUB_ITEMS/$name")"
    fi
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"
export STUB_ITEMS="$tmp_dir/items"
export STUB_MODE=hit

item_file() {  # item_file <filename> <id> <legacy-id|-> <status>
  {
    printf -- '---\n'
    printf 'id: %s\n' "$2"
    [[ "$3" == "-" ]] || printf 'legacy-id: %s\n' "$3"
    printf 'title: something deferred\n'
    printf 'status: %s\n' "$4"
    printf -- '---\n\nThe body, which nothing here reads.\n'
  } > "$STUB_ITEMS/$1"
}

item_file "TD-PPpfid-26072401.md" "TD-PPpfid-26072401" "TD26072401" "resolved"
item_file "TD-PPpfid-26072605.md" "TD-PPpfid-26072605" "-"           "open"
item_file "TD-PPpfid-26072602.md" "TD-PPpfid-26072602" "-"           "not-debt"

run_gather() { "$GATHER" "o/a" main "$@" 2>"$tmp_dir/err"; }

assert_eq "a scoped id resolves to its status" \
  "open" "$(run_gather TD-PPpfid-26072605 | jq -r '.["TD-PPpfid-26072605"] // ""')"
assert_eq "a legacy id resolves through the file that carries it" \
  "resolved" "$(run_gather TD26072401 | jq -r '.["TD26072401"] // ""')"
assert_eq "several ids come back in one object" \
  "2" "$(run_gather TD26072401 TD-PPpfid-26072602 | jq 'length')"
assert_eq "an id no file claims is simply absent" \
  "{}" "$(run_gather TD-PPpfid-26079999)"
assert_eq "and so is an id asked of no ids at all" \
  "{}" "$(run_gather)"

# A file whose *name* ends in the right digits but whose frontmatter claims a
# different id must not answer for it: the filename is a shortlist, and a status
# read off the wrong item clears a block out from under real work.
item_file "TD-PPpfid-26072401.md" "TD-PPpfid-26072401" "-" "resolved"
assert_eq "a filename match with no frontmatter claim resolves nothing" \
  "{}" "$(run_gather TD26072401)"

# Two files claiming one id is a register that disagrees with itself. That is
# register-hygiene's repair, and until it lands this reports nothing rather than
# picking one of them.
item_file "TD-PPpfid-26072401.md" "TD-PPpfid-26072401" "TD26072401" "resolved"
item_file "TD-PPother-26072401.md" "TD-PPother-26072401" "TD26072401" "open"
assert_eq "two files claiming one id resolve nothing" \
  "{}" "$(run_gather TD26072401)"
rm -f "$STUB_ITEMS/TD-PPother-26072401.md"

# Both failure shapes print {} — a register that does not exist is normal and
# silent, and anything else is somebody's problem and says so.
STUB_MODE=404 assert_eq "a repo with no register resolves nothing" \
  "{}" "$(STUB_MODE=404 run_gather TD26072401)"
assert_eq "and says nothing about it" "" "$(cat "$tmp_dir/err")"
assert_eq "an API failure resolves nothing" \
  "{}" "$(STUB_MODE=fail run_gather TD26072401)"
assert_eq "but is diagnosed on stderr" \
  "1" "$(grep -c "error connecting" "$tmp_dir/err")"

# --- The two halves together ----------------------------------------------------
# The end the requirement is about: the register says resolved, so the block goes.
assert_eq "a resolved item read from the register clears its block" \
  "the tech-debt register records it resolved" \
  "$(reason_of "$(work_gone_clearances "$(blocked_of TD26072401)" "$states" \
       "$(jq -nc --argjson m "$(run_gather TD26072401)" '{"o/a": $m}')")")"

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
