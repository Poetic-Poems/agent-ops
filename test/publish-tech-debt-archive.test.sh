#!/usr/bin/env bash
#
# test/publish-tech-debt-archive.test.sh — regression test for
# scripts/publish-tech-debt-archive.sh (issue #878, D15 as revised): the
# daily `pw::type:tech-debt` archive mirror.
#
# `gh` is stubbed via `PATH`. The issue/pull-request *searches* apply the
# script's own `--jq` filter for real against a fixture array — the same
# technique test/publish-revert-rate.test.sh uses — so a change to that
# filter is exercised here, not bypassed. The *contents-API* calls
# (`repos/<state_repo>/contents/...`) are backed by a small stateful
# filesystem fake under `$STUB_DIR/server/`, each write recording a fake
# `sha` the next read or conditional write must agree with — close enough to
# GitHub's own optimistic concurrency to exercise the create/update/conflict
# paths for real.
#
# Run directly: ./test/publish-tech-debt-archive.test.sh — exit 0 iff all
# assertions passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH="$SCRIPT_DIR/scripts/publish-tech-debt-archive.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

mkdir -p "$tmp_dir/bin"
export STUB_DIR="$tmp_dir/fixtures"
mkdir -p "$STUB_DIR/server"

cat > "$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected command: $*" >&2; exit 1; }
shift

path="" filter="" paginate=0 method="GET"
declare -a fields=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) filter="$2"; shift 2 ;;
    --paginate) paginate=1; shift ;;
    -X) method="$2"; shift 2 ;;
    -f) fields+=("$2"); shift 2 ;;
    -*) shift ;;
    *) path="$1"; shift ;;
  esac
done

case "$path" in
  repos/*/issues\?labels=*)
    repo="${path#repos/}"; repo="${repo%%/issues*}"
    key="${repo//\//_}"
    if [[ ! -f "$STUB_DIR/issues-$key.json" ]]; then
      echo "stub gh: HTTP 404 (no issues fixture for $repo)" >&2
      exit 1
    fi
    body="$(cat "$STUB_DIR/issues-$key.json")"
    [[ -n "$filter" ]] || filter='.'
    jq -r "$filter" <<<"$body"
    ;;
  repos/*/pulls\?state=open*)
    repo="${path#repos/}"; repo="${repo%%/pulls*}"
    key="${repo//\//_}"
    body="$(cat "$STUB_DIR/prs-$key.json" 2>/dev/null || echo '[]')"
    [[ -n "$filter" ]] || filter='.'
    jq -r "$filter" <<<"$body"
    ;;
  repos/*/contents/*)
    rel="${path#*/contents/}"
    rel="${rel%%\?*}"
    server_file="$STUB_DIR/server/$rel"
    if [[ "$method" == "GET" ]]; then
      if [[ ! -f "$server_file" ]]; then
        echo "stub gh: HTTP 404: $rel" >&2
        exit 1
      fi
      content="$(base64 -w0 < "$server_file")"
      sha="$(cat "$server_file.sha")"
      jq -nc --arg content "$content" --arg sha "$sha" '{content: $content, sha: $sha}'
    elif [[ "$method" == "PUT" ]]; then
      msg="" content_b64="" sha_arg=""
      for f in "${fields[@]+"${fields[@]}"}"; do
        k="${f%%=*}"; v="${f#*=}"
        case "$k" in
          message) msg="$v" ;;
          content) content_b64="$v" ;;
          sha) sha_arg="$v" ;;
        esac
      done
      [[ -n "${STUB_FAIL_PUT_PATH:-}" && "$rel" == "$STUB_FAIL_PUT_PATH" ]] && {
        echo "stub gh: HTTP 500: injected failure for $rel" >&2
        exit 1
      }
      cur_sha=""
      [[ -f "$server_file.sha" ]] && cur_sha="$(cat "$server_file.sha")"
      if [[ -n "$sha_arg" ]]; then
        if [[ "$sha_arg" != "$cur_sha" ]]; then
          echo "stub gh: HTTP 409: sha mismatch for $rel (have $cur_sha, sent $sha_arg)" >&2
          exit 1
        fi
      elif [[ -n "$cur_sha" ]]; then
        echo "stub gh: HTTP 422: $rel already exists" >&2
        exit 1
      fi
      mkdir -p "$(dirname "$server_file")"
      printf '%s' "$content_b64" | base64 -d > "$server_file"
      counter=0
      [[ -f "$STUB_DIR/server/.counter" ]] && counter="$(cat "$STUB_DIR/server/.counter")"
      counter=$(( counter + 1 ))
      echo "$counter" > "$STUB_DIR/server/.counter"
      new_sha="sha-$counter"
      echo "$new_sha" > "$server_file.sha"
      echo "$rel" >> "$STUB_DIR/put-log"
      jq -nc --arg sha "$new_sha" '{content: {sha: $sha}}'
    else
      echo "stub gh: unexpected method $method for $path" >&2
      exit 1
    fi
    ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

write_config() {  # write_config <path> <repos-json>
  jq -n --argjson repos "$2" --arg state_repo "o/state-repo" \
    '{repos: $repos, state_dir: "unused", workspace_root: "unused", state_repo: $state_repo}' > "$1"
}

# ============================================================================
# Run A: first-ever run for o/r — two labelled issues, one open with a body,
# one closed (state_reason completed); no archive yet.
# ============================================================================
cfg_a="$tmp_dir/config-a.json"
write_config "$cfg_a" '[{"slug": "o/r", "sources": ["tech-debt"]}]'

cat > "$STUB_DIR/issues-o_r.json" <<'EOF'
[
  {"number": 10, "title": "Fix the thing", "state": "open", "state_reason": null,
   "user": {"login": "alice"}, "labels": [{"name": "pw::type:tech-debt"}],
   "created_at": "2026-08-01T00:00:00Z", "updated_at": "2026-08-02T00:00:00Z",
   "closed_at": null, "body": "The thing is broken."},
  {"number": 11, "title": "Fixed the other thing", "state": "closed", "state_reason": "completed",
   "user": {"login": "bob"}, "labels": [{"name": "pw::type:tech-debt"}],
   "created_at": "2026-07-01T00:00:00Z", "updated_at": "2026-07-05T00:00:00Z",
   "closed_at": "2026-07-05T00:00:00Z", "body": "Was fixed in #999."}
]
EOF
printf '[]\n' > "$STUB_DIR/prs-o_r.json"

"$PUBLISH" --config "$cfg_a" 2>"$tmp_dir/run-a.err"
rc_a=$?
assert_eq "run A exits 0" "0" "$rc_a"
assert_eq "issue #10 is archived" "10" "$(jq -r '.number' "$STUB_DIR/server/tech-debt-archive/o/r/10.json")"
assert_eq "  ... with its title" "Fix the thing" "$(jq -r '.title' "$STUB_DIR/server/tech-debt-archive/o/r/10.json")"
assert_eq "  ... its open state" "open" "$(jq -r '.state' "$STUB_DIR/server/tech-debt-archive/o/r/10.json")"
assert_eq "  ... a null state_reason" "null" "$(jq -r '.state_reason' "$STUB_DIR/server/tech-debt-archive/o/r/10.json")"
assert_eq "  ... its body" "The thing is broken." "$(jq -r '.body' "$STUB_DIR/server/tech-debt-archive/o/r/10.json")"
assert_eq "issue #11 is archived closed, with its close reason" "completed" \
  "$(jq -r '.state_reason' "$STUB_DIR/server/tech-debt-archive/o/r/11.json")"
assert_eq "the per-repo index records both issues' updated_at" '{"10":"2026-08-02T00:00:00Z","11":"2026-07-05T00:00:00Z"}' \
  "$(jq -Sc '.' "$STUB_DIR/server/tech-debt-archive/o/r/_index.json")"
assert_eq "three writes happened: two issues plus the index" "3" "$(wc -l < "$STUB_DIR/put-log" | tr -d ' ')"

# ============================================================================
# Run B: nothing changed — no issue is re-fetched or re-written
# ============================================================================
: > "$STUB_DIR/put-log"
"$PUBLISH" --config "$cfg_a" >/dev/null 2>"$tmp_dir/run-b.err"
assert_eq "run B exits 0" "0" "$?"
assert_eq "an unchanged repo writes nothing at all" "0" "$(wc -l < "$STUB_DIR/put-log" | tr -d ' ')"

# ============================================================================
# Run C: issue #10 is edited (body + updated_at change) — only #10 and the
# index are rewritten; #11 is untouched
# ============================================================================
jq '(.[] | select(.number == 10) | .body) |= "The thing is broken worse now."
    | (.[] | select(.number == 10) | .updated_at) |= "2026-08-10T00:00:00Z"' \
  "$STUB_DIR/issues-o_r.json" > "$STUB_DIR/issues-o_r.json.tmp"
mv "$STUB_DIR/issues-o_r.json.tmp" "$STUB_DIR/issues-o_r.json"
: > "$STUB_DIR/put-log"
"$PUBLISH" --config "$cfg_a" >/dev/null 2>"$tmp_dir/run-c.err"
assert_eq "run C exits 0" "0" "$?"
assert_eq "only the changed issue and the index are rewritten" "2" "$(wc -l < "$STUB_DIR/put-log" | tr -d ' ')"
assert_eq "#10's archived body reflects the edit" "The thing is broken worse now." \
  "$(jq -r '.body' "$STUB_DIR/server/tech-debt-archive/o/r/10.json")"

# ============================================================================
# Run D: #11 is relabelled away (dropped from the label search entirely) —
# its already-archived record survives untouched
# ============================================================================
jq '[.[] | select(.number != 11)]' "$STUB_DIR/issues-o_r.json" > "$STUB_DIR/issues-o_r.json.tmp"
mv "$STUB_DIR/issues-o_r.json.tmp" "$STUB_DIR/issues-o_r.json"
"$PUBLISH" --config "$cfg_a" >/dev/null 2>"$tmp_dir/run-d.err"
assert_eq "run D exits 0" "0" "$?"
assert_eq "a relabelled-away issue's archived record is never deleted" "11" \
  "$(jq -r '.number' "$STUB_DIR/server/tech-debt-archive/o/r/11.json")"

# ============================================================================
# Run E: an empty-body labelled issue is archived and audited on stderr
# ============================================================================
cat > "$STUB_DIR/issues-o_empty.json" <<'EOF'
[
  {"number": 20, "title": "No detail given", "state": "open", "state_reason": null,
   "user": {"login": "carol"}, "labels": [{"name": "pw::type:tech-debt"}],
   "created_at": "2026-08-01T00:00:00Z", "updated_at": "2026-08-01T00:00:00Z",
   "closed_at": null, "body": "   "}
]
EOF
printf '[]\n' > "$STUB_DIR/prs-o_empty.json"
cfg_e="$tmp_dir/config-e.json"
write_config "$cfg_e" '[{"slug": "o/empty", "sources": ["tech-debt"]}]'
"$PUBLISH" --config "$cfg_e" >/dev/null 2>"$tmp_dir/run-e.err"
assert_eq "run E exits 0" "0" "$?"
assert_eq "the empty-body issue is still archived" "20" \
  "$(jq -r '.number' "$STUB_DIR/server/tech-debt-archive/o/empty/20.json")"
assert_contains "and the empty body is audited on stderr" "$(cat "$tmp_dir/run-e.err")" "issue #20 carries pw::type:tech-debt with an empty body"

# ============================================================================
# Run F: an open pull request from the pre-migration filing path
# (lib/tech-debt-file.sh's techdebt_file_debt, head branch td-record/<id>) is
# invisible to the label search and flagged by the legacy-filing audit
# ============================================================================
printf '[]\n' > "$STUB_DIR/issues-o_legacy.json"
cat > "$STUB_DIR/prs-o_legacy.json" <<'EOF'
[{"number": 55, "html_url": "https://github.com/o/legacy/pull/55",
  "head": {"ref": "td-record/TD-PPagop-26082310"}}]
EOF
cfg_f="$tmp_dir/config-f.json"
write_config "$cfg_f" '[{"slug": "o/legacy", "sources": ["tech-debt"]}]'
"$PUBLISH" --config "$cfg_f" >/dev/null 2>"$tmp_dir/run-f.err"
assert_eq "run F exits 0" "0" "$?"
assert_contains "the legacy filing PR is named on stderr" "$(cat "$tmp_dir/run-f.err")" \
  "PR #55 (https://github.com/o/legacy/pull/55, branch td-record/TD-PPagop-26082310) is a pre-migration tech-debt filing"

# ============================================================================
# Run G: two repos, one whose label search has no fixture at all (simulating
# an unreadable repo) — the readable one still gets archived, the run still
# reports failure
# ============================================================================
printf '[]\n' > "$STUB_DIR/prs-o_broken.json"
jq '(.[] | select(.number == 10) | .updated_at) |= "2026-08-11T00:00:00Z"' \
  "$STUB_DIR/issues-o_r.json" > "$STUB_DIR/issues-o_r.json.tmp"
mv "$STUB_DIR/issues-o_r.json.tmp" "$STUB_DIR/issues-o_r.json"
cfg_g="$tmp_dir/config-g.json"
write_config "$cfg_g" '[{"slug": "o/r", "sources": ["tech-debt"]}, {"slug": "o/broken", "sources": ["tech-debt"]}]'
: > "$STUB_DIR/put-log"
"$PUBLISH" --config "$cfg_g" >/dev/null 2>"$tmp_dir/run-g.err"
rc_g=$?
assert_eq "a repo with no fixture (unreadable) exits non-zero" "1" "$rc_g"
assert_contains "  ... and says why on stderr" "$(cat "$tmp_dir/run-g.err")" "o/broken"
assert_eq "  ... but the readable repo is still processed (its changed issue and index rewritten)" "2" \
  "$(wc -l < "$STUB_DIR/put-log" | tr -d ' ')"

# ============================================================================
# Run H: a write that fails is left for the next run, never fabricated —
# the index is not advanced for the issue whose write failed
# ============================================================================
cat > "$STUB_DIR/issues-o_flaky.json" <<'EOF'
[{"number": 30, "title": "Will fail once", "state": "open", "state_reason": null,
  "user": {"login": "dave"}, "labels": [{"name": "pw::type:tech-debt"}],
  "created_at": "2026-08-01T00:00:00Z", "updated_at": "2026-08-01T00:00:00Z",
  "closed_at": null, "body": "flaky"}]
EOF
printf '[]\n' > "$STUB_DIR/prs-o_flaky.json"
cfg_h="$tmp_dir/config-h.json"
write_config "$cfg_h" '[{"slug": "o/flaky", "sources": ["tech-debt"]}]'
STUB_FAIL_PUT_PATH="tech-debt-archive/o/flaky/30.json" "$PUBLISH" --config "$cfg_h" >/dev/null 2>"$tmp_dir/run-h1.err"
assert_eq "run H1 (write fails) exits non-zero" "1" "$?"
assert_eq "the failed issue is not archived" "absent" \
  "$([[ -f "$STUB_DIR/server/tech-debt-archive/o/flaky/30.json" ]] && echo "present" || echo "absent")"
assert_contains "  ... and says so on stderr" "$(cat "$tmp_dir/run-h1.err")" "archive write failed"

"$PUBLISH" --config "$cfg_h" >/dev/null 2>"$tmp_dir/run-h2.err"
assert_eq "run H2 (retried, no injected failure) exits 0" "0" "$?"
assert_eq "the retried issue is now archived" "30" \
  "$(jq -r '.number' "$STUB_DIR/server/tech-debt-archive/o/flaky/30.json")"

# ============================================================================
# Run I: state_repo unset — a silent single-node no-op, no gh calls at all
# ============================================================================
cfg_i="$tmp_dir/config-i.json"
jq -n '{repos: [{slug: "o/r", sources: ["tech-debt"]}], state_dir: "unused", workspace_root: "unused"}' > "$cfg_i"
mv "$tmp_dir/bin/gh" "$tmp_dir/bin/gh.disabled"
"$PUBLISH" --config "$cfg_i" >/dev/null 2>"$tmp_dir/run-i.err"
assert_eq "run I (no state_repo) exits 0 with no gh calls" "0" "$?"
mv "$tmp_dir/bin/gh.disabled" "$tmp_dir/bin/gh"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
