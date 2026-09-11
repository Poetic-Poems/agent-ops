#!/usr/bin/env bash
#
# test/monitor-digest.test.sh — lib/monitor-digest.sh, the deterministic
# digest the Pipeline Monitor reads instead of the fleet's own records
# (agent-ops#1284, docs/MONITOR-PIPELINE-SPEC.md M6/M6a/M6b/M7).
#
# Every function under test is a pure reader, which is what makes this file
# possible at all: fixture logs and a fixture state tree on disk, no network,
# no `gh`, no config.json. What it guards:
#
#   the window        an event outside the 24 h window contributes to nothing
#                     — not the counts, not the samples, not the folds. A
#                     digest that quietly widened its window would read as a
#                     spike on the day it did.
#   the samples       newest first, capped, and the cap is what the caller
#                     asked for. The count is the reading and the sample is
#                     its evidence, so a class whose count says 9 and whose
#                     samples say 3 is correct, and a class whose samples are
#                     the *oldest* three is describing yesterday.
#   the folds         selections per band, stand-downs per cause,
#                     `none-selected` reasons verbatim, the fit rung
#                     histogram. These are the three readings agent-ops#1126
#                     had to reconstruct by hand; if any of them silently
#                     returns `[]` the Monitor's second question has no
#                     evidence behind it and nothing says so.
#   the nodes         a peer's verdicts come from its own heartbeat, this
#                     node's from the files its heartbeat is folded from, and
#                     a node with no host-facts record reads `null` rather
#                     than being omitted.
#   the bound         M7's ladder, measured in bytes: the rendered digest is
#                     never larger than the bound at any rung, including the
#                     truncating one, and the rung climbs as the bound
#                     tightens. This is the requirement with the most ways to
#                     be quietly wrong — a character count instead of a byte
#                     count overshoots by exactly the multi-byte overhead the
#                     bound exists to keep out.
#   degradation       every reader returns its empty shape for a missing
#                     file. A monitor run over a fleet whose peers have not
#                     synced is a run with less to say, never a failed one.
#
# No network. Run directly: ./test/monitor-digest.test.sh — exit 0 iff all
# passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/monitor-digest.sh
. "$SCRIPT_DIR/lib/monitor-digest.sh"

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
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "${haystack:0:400}"
    failures=$(( failures + 1 ))
  fi
}

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n' "$desc" "$needle"
    failures=$(( failures + 1 ))
  fi
}

# --- The fixture ------------------------------------------------------------
# A fixed "now" so the window boundary is an assertion rather than a race:
# every timestamp below is placed relative to it deliberately, and the one
# event at 25 h old is the window's own negative control.
NOW_ISO="2026-09-11T12:00:00Z"
NOW_EPOCH="$(date -u -d "$NOW_ISO" +%s)"
SINCE="$(monitor_digest_since "$NOW_EPOCH" 24)"
assert_eq "the window's lower bound is 24 h before now" "2026-09-10T12:00:00Z" "$SINCE"
assert_eq "an unparseable now falls back to a real clock rather than empty" \
  "1" "$([[ -n "$(monitor_digest_since "not-a-number" 24)" ]] && echo 1 || echo 0)"

union="$tmp_dir/union.jsonl"
cat > "$union" <<'EOF'
{"ts":"2026-09-09T11:00:00Z","cycle":"old","node":"n1","event":"limit-hit","class":"weekly","resume_at":"2026-09-09T15:00:00Z"}
{"ts":"2026-09-10T13:00:00Z","cycle":"c1","node":"n1","event":"selection","source":"issues:high","repo":"o/r","item":"11"}
{"ts":"2026-09-10T14:00:00Z","cycle":"c2","node":"n2","event":"selection","source":"tech-debt","repo":"o/r","item":"12"}
{"ts":"2026-09-10T15:00:00Z","cycle":"c3","node":"n1","event":"selection","source":"tech-debt","repo":"o/r","item":"13"}
{"ts":"2026-09-10T16:00:00Z","cycle":"c4","node":"n1","event":"selection","source":"tech-debt","repo":"o/r","item":"14"}
{"ts":"2026-09-11T01:00:00Z","cycle":"c5","node":"n2","event":"stand-down","reason":"no candidates","cause":"none-selected","candidates":0}
{"ts":"2026-09-11T01:05:00Z","cycle":"c5","node":"n2","event":"none-selected","reason":"budget: 1 resolves to a negative allowance"}
{"ts":"2026-09-11T02:00:00Z","cycle":"c6","node":"n2","event":"stand-down","reason":"peers hold everything","cause":"raced","candidates":4}
{"ts":"2026-09-11T02:30:00Z","cycle":"c7","node":"n1","event":"coordinator-input-fitted","rung":3,"fits":true}
{"ts":"2026-09-11T02:40:00Z","cycle":"c8","node":"n1","event":"coordinator-input-fitted","rung":3,"fits":true}
{"ts":"2026-09-11T02:50:00Z","cycle":"c9","node":"n1","event":"coordinator-input-fitted","rung":5,"fits":false}
{"ts":"2026-09-11T03:00:00Z","cycle":"c9","node":"n1","event":"coordinator-input-fit-unassessable","detail":"unmeasurable"}
{"ts":"2026-09-11T04:00:00Z","cycle":"c9","node":"n1","event":"pr-ready","pr_url":"https://github.com/o/r/pull/1"}
{"ts":"2026-09-11T04:10:00Z","cycle":"c9","node":"n2","event":"claim-lost","repo":"o/r","item":"15"}
{"ts":"2026-09-11T05:00:00Z","cycle":"pub","node":"n1","event":"pager-fired","key":"node-stale","evidence":"poetic-1 has published nothing for 3 h","issue_number":99,"issue_url":"https://github.com/o/r/issues/99","remedy_class":"owner-only","nodes":["poetic-1"]}
{"ts":"2026-09-11T06:00:00Z","cycle":"pub","node":"n1","event":"pager-cleared","key":"updater-stuck","cleared_at":"2026-09-11T06:00:00Z","evidence":"the ledger advanced"}
EOF

# --- Events by class --------------------------------------------------------
events="$(monitor_digest_events "$union" "$SINCE" 3)"

assert_eq "an event older than the window is excluded entirely" \
  "0" "$(jq '[.[] | select(.event == "limit-hit")] | length' <<<"$events")"
assert_eq "selections are counted, not sampled-and-guessed" \
  "4" "$(jq -r '.[] | select(.event == "selection") | .count' <<<"$events")"
assert_eq "the sample cap is the caller's, not the class's size" \
  "3" "$(jq -r '.[] | select(.event == "selection") | .samples | length' <<<"$events")"
assert_eq "samples are the newest of the class, so a fault still in force is the one shown" \
  "14" "$(jq -r '.[] | select(.event == "selection") | .samples[0].item' <<<"$events")"
assert_eq "a lower cap is honoured" \
  "1" "$(jq -r '.[] | select(.event == "selection") | .samples | length' \
         <<<"$(monitor_digest_events "$union" "$SINCE" 1)")"
assert_eq "every contributing node is named, so one-node and every-node faults differ" \
  "n1 n2" "$(jq -r '.[] | select(.event == "selection") | .nodes | join(" ")' <<<"$events")"
assert_eq "a sample keeps its ts" \
  "2026-09-10T16:00:00Z" \
  "$(jq -r '.[] | select(.event == "selection") | .samples[0].ts' <<<"$events")"
assert_eq "a sample drops the cycle id, which names a run the Monitor cannot open" \
  "null" "$(jq -r '.[] | select(.event == "selection") | .samples[0].cycle // "null"' <<<"$events")"
assert_eq "pager-fired sorts ahead of selection, whatever the alphabet says" \
  "1" "$(jq '([.[] | .event] | index("pager-fired")) < ([.[] | .event] | index("selection"))
            | if . then 1 else 0 end' <<<"$events")"
assert_eq "an empty log yields an empty array, not an error" \
  "[]" "$(monitor_digest_events "$tmp_dir/does-not-exist.jsonl" "$SINCE" 3)"

# --- Pager ------------------------------------------------------------------
open_pages='[{"number":99,"url":"https://github.com/o/r/issues/99","title":"Pager: node-stale","createdAt":"2026-09-11T05:00:01Z","assignees":[{"login":"warwickallen"}],"body":"ref: pager:node-stale","comments":[{"body":"monitor-finding-key: already-linked"}]}]'
pager="$(monitor_digest_pager "$union" "$SINCE" "$open_pages")"
assert_eq "both transitions in the window are carried" \
  "2" "$(jq '.transitions | length' <<<"$pager")"
assert_eq "a fired transition keeps the issue it filed" \
  "99" "$(jq -r '.transitions[] | select(.event == "pager-fired") | .issue_number' <<<"$pager")"
assert_eq "open pages are a separate array from the transitions" \
  "1" "$(jq '.open_pages | length' <<<"$pager")"
assert_eq "an open page carries its assignees, so an owner-only page is visible as one" \
  "warwickallen" "$(jq -r '.open_pages[0].assignees[0]' <<<"$pager")"
assert_eq "a malformed open-pages argument degrades to none rather than failing" \
  "0" "$(jq '.open_pages | length' <<<"$(monitor_digest_pager "$union" "$SINCE" 'not json')")"

# --- Nodes ------------------------------------------------------------------
state="$tmp_dir/state"
peers="$tmp_dir/peers"
mkdir -p "$state/host-facts" "$peers/n2/host-facts" "$peers/n3"
cat > "$state/.stage-health.json" <<'EOF'
{"computed_at":"2026-09-11T11:00:00Z","threshold":3,"idle_after_hours":48,
 "stages":{"coordinator":{"verdict":"ok","last_success":"2026-09-11T10:00:00Z","consecutive_failures":0,"last_detail":null},
           "implementer":{"verdict":"failing","last_success":null,"consecutive_failures":4,"last_detail":"clone refused"}}}
EOF
cat > "$state/.doctor-status.json" <<'EOF'
{"timestamp":"2026-09-11T11:30:00Z","verdict":"warn","fails":[],"warns":["one warning"]}
EOF
cat > "$state/host-facts/n1.json" <<'EOF'
{"node":"n1","driver":"compose","generated_at":"2026-09-11T11:45:00Z","host":{"mem_available_bytes":1000}}
EOF
cat > "$peers/n2/heartbeat.json" <<'EOF'
{"node":"n2","role":"active","ts":"2026-09-11T11:50:00Z",
 "stage_health":{"stages":{"reviewer":{"verdict":"failing","consecutive_failures":3}}},
 "updater":{"verdict":"ok"},"compose":{"verdict":"drift"},"image":{"verdict":"ok"},
 "mirror":{"verdict":"ok"},"doctor":{"verdict":"pass"}}
EOF
cat > "$peers/n2/host-facts/n2.json" <<'EOF'
{"node":"n2","driver":"kubernetes","generated_at":"2026-09-11T11:40:00Z"}
EOF
cat > "$peers/n3/heartbeat.json" <<'EOF'
{"node":"n3","role":"standby","ts":"2026-09-11T11:55:00Z"}
EOF

nodes="$(monitor_digest_nodes n1 "$state" "$peers")"
assert_eq "every node in the fleet gets a row" "3" "$(jq 'length' <<<"$nodes")"
assert_eq "self sorts first" "n1" "$(jq -r '.[0].node' <<<"$nodes")"
assert_eq "self's own stage health comes from the file its heartbeat is folded from" \
  "failing" "$(jq -r '.[0].stage_health.stages.implementer.verdict' <<<"$nodes")"
assert_eq "self's doctor verdict travels too" "warn" "$(jq -r '.[0].doctor.verdict' <<<"$nodes")"
assert_eq "a peer's verdicts come from its own heartbeat, never derived here" \
  "drift" "$(jq -r '.[] | select(.node == "n2") | .compose.verdict' <<<"$nodes")"
assert_eq "a peer's own stage health travels with it" \
  "failing" "$(jq -r '.[] | select(.node == "n2") | .stage_health.stages.reviewer.verdict' <<<"$nodes")"
assert_eq "a node's host-facts record is carried whole" \
  "kubernetes" "$(jq -r '.[] | select(.node == "n2") | .host.driver' <<<"$nodes")"
assert_eq "a node with no host-facts record reads null rather than vanishing" \
  "null" "$(jq -r '.[] | select(.node == "n3") | .host' <<<"$nodes")"
assert_eq "an absent peers directory is not a failure" \
  "1" "$(jq 'length' <<<"$(monitor_digest_nodes n1 "$state" "$tmp_dir/no-peers")")"

# --- Throughput -------------------------------------------------------------
work="$(monitor_digest_work "$union" "$SINCE")"
assert_eq "selections are counted per work band, commonest first" \
  "tech-debt" "$(jq -r '.selections_by_source[0].key' <<<"$work")"
assert_eq "and the band's count is right" \
  "3" "$(jq -r '.selections_by_source[0].count' <<<"$work")"
assert_eq "stand-downs are counted per cause, not pooled with none-selected" \
  "2" "$(jq '.stand_downs_by_cause | length' <<<"$work")"
assert_eq "a none-selected reason is carried verbatim — this is where #1128 was visible" \
  "budget: 1 resolves to a negative allowance" \
  "$(jq -r '.none_selected_reasons[0].key' <<<"$work")"
assert_eq "the fit rung histogram counts rungs, not events" \
  "2" "$(jq -r '.fit_rungs[] | select(.key == "3") | .count' <<<"$work")"
assert_eq "a rung reached once is still in the histogram" \
  "1" "$(jq -r '.fit_rungs[] | select(.key == "5") | .count' <<<"$work")"
assert_eq "an unassessable fit is its own count, not a rung" \
  "1" "$(jq -r '.fit_unassessable' <<<"$work")"
assert_eq "pull requests marked ready are counted" "1" "$(jq -r '.landed' <<<"$work")"
assert_eq "claims lost to peers are counted" "1" "$(jq -r '.raced' <<<"$work")"
assert_eq "a missing log yields the empty fold, not a failure" \
  "0" "$(jq -r '.landed' <<<"$(monitor_digest_work "$tmp_dir/nope.jsonl" "$SINCE")")"

# --- The forge --------------------------------------------------------------
forge="$(monitor_digest_forge \
  '[{"number":7,"url":"u7","title":"a pr","state":"OPEN","createdAt":"2026-09-11T01:00:00Z","labels":[{"name":"x"}]}]' \
  '[{"number":8,"url":"u8","title":"an issue","state":"OPEN","createdAt":"2026-09-11T01:00:00Z","labels":[]}]' \
  'not json')"
assert_eq "a pull request keeps its number" "7" "$(jq -r '.pull_requests[0].number' <<<"$forge")"
assert_eq "labels are flattened to names" "x" "$(jq -r '.pull_requests[0].labels[0]' <<<"$forge")"
assert_eq "an unreadable listing degrades to empty rather than failing the digest" \
  "0" "$(jq '.escalations | length' <<<"$forge")"

# --- Gotchas ----------------------------------------------------------------
cat > "$tmp_dir/with-gotchas.md" <<'EOF'
# A spec

## Requirements

R1. something

## Gotchas

| Signature | What it actually is |
| --- | --- |
| a thing that looks broken | the thing it really is |

## Design decisions

not part of the gotchas
EOF
cat > "$tmp_dir/no-gotchas.md" <<'EOF'
# A spec with none

## Requirements

R1. something
EOF
gotchas="$(monitor_digest_gotchas "$tmp_dir/with-gotchas.md" "$tmp_dir/no-gotchas.md" "$tmp_dir/absent.md")"
assert_eq "only a file with a Gotchas section contributes one" "1" "$(jq 'length' <<<"$gotchas")"
assert_contains "the section's own rows are lifted" "a thing that looks broken" \
  "$(jq -r '.[0].text' <<<"$gotchas")"
assert_lacks "and the section stops at the next heading" "not part of the gotchas" \
  "$(jq -r '.[0].text' <<<"$gotchas")"
assert_eq "no readable file at all yields an empty array" "[]" \
  "$(monitor_digest_gotchas "$tmp_dir/absent.md")"

# --- The whole digest, and M7's ladder --------------------------------------
digest="$(monitor_digest_build \
  "$(jq -nc --arg f "$SINCE" --arg t "$NOW_ISO" '{from: $f, to: $t, hours: 24, node: "n1"}')" \
  "$events" "$pager" "$nodes" "$work" "$forge" \
  "$(monitor_digest_gotchas "$SCRIPT_DIR/docs/IMPLEMENTATION-PIPELINE-SPEC.md" \
       "$SCRIPT_DIR/docs/MONITOR-PIPELINE-SPEC.md")")"

for section in window events pager nodes work forge gotchas; do
  assert_eq "the digest carries its $section section" "1" \
    "$(jq --arg s "$section" 'has($s) | if . then 1 else 0 end' <<<"$digest")"
done

out="$tmp_dir/digest.md"

# Unbounded: the rung stays 0 and every section renders.
IFS=$'\t' read -r rung bytes < <(monitor_digest_render "$digest" 0 "$out")
assert_eq "an unbounded render stays at rung 0" "0" "$rung"
assert_eq "and reports the bytes it actually wrote" "$bytes" "$(wc -c < "$out" | tr -d ' ')"
full_bytes="$bytes"
rendered="$(cat "$out")"
assert_contains "the event table is rendered" '| `selection` | 4 |' "$rendered"
assert_contains "the throughput fold names the band" '- `tech-debt`: 3' "$rendered"
assert_contains "the none-selected reason survives into the text" \
  "budget: 1 resolves to a negative allowance" "$rendered"
assert_contains "every open page is flagged as owed a triage verdict" \
  "owed a triage verdict" "$rendered"
assert_contains "the node table names a failing stage" "implementer" "$rendered"
assert_contains "the gotcha sections are present at rung 0" "## Known signatures" "$rendered"

# Deterministic: the same inputs render byte-identically, which is what the
# dedup of M13 rests on.
monitor_digest_render "$digest" 0 "$tmp_dir/digest-again.md" >/dev/null
assert_eq "the same digest renders byte-identically twice" "0" \
  "$(cmp -s "$out" "$tmp_dir/digest-again.md" && echo 0 || echo 1)"

# The ladder. Each bound below is deliberately under the previous rung's own
# size, so the ladder has to descend to satisfy it — and the assertion that
# matters at every step is the same one: the file is never larger than the
# bound.
prev_rung=0
for bound in $(( full_bytes - 1 )) 20000 6000 2000 600 120; do
  IFS=$'\t' read -r rung bytes < <(monitor_digest_render "$digest" "$bound" "$out")
  actual="$(wc -c < "$out" | tr -d ' ')"
  assert_eq "at a bound of $bound the rendered digest fits ($actual bytes, rung $rung)" \
    "1" "$(( actual <= bound ? 1 : 0 ))"
  assert_eq "at a bound of $bound the reported byte count is the real one" "$actual" "$bytes"
  assert_eq "at a bound of $bound the rung has not gone backwards" \
    "1" "$(( rung >= prev_rung ? 1 : 0 ))"
  prev_rung="$rung"
done
assert_eq "a bound tight enough to force the last rung reports it" \
  "$MONITOR_DIGEST_MAX_RUNG" "$prev_rung"
assert_contains "and the truncation says so inside the bound it was given" \
  "truncated" "$(cat "$out")"

# Rung 3 sheds the gotcha sections — the largest single block — before rung 4
# sheds the counts' own evidence.
IFS=$'\t' read -r rung _ < <(monitor_digest_render "$digest" 20000 "$out")
assert_lacks "a rung that shed the gotchas really has none" "## Known signatures" "$(cat "$out")"
assert_contains "while the event counts it was protecting are still there" \
  '| `selection` | 4 |' "$(cat "$out")"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
