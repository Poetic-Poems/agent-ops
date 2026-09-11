#!/usr/bin/env bash
#
# test/monitor-cycle.test.sh — the Pipeline Monitor end to end
# (agent-ops#1284, docs/MONITOR-PIPELINE-SPEC.md).
#
# Every case here drives the **real** `monitor-cycle.sh` against a shim node:
# a directory of symlinks back into the tree with its own `config.json`, which
# works because the script takes SCRIPT_DIR from its own path and reads its
# config from beside itself. Two stubs stand in for everything outside the
# process — `claude`, which returns a canned findings object, and `gh`, which
# records every call and answers the listings — so the assertions are about
# what the Script *did*, not about what a library would have done if called.
#
# The five behaviours this file exists for, and why each would fail quietly:
#
#   the budget      four findings must file three and defer the fourth **with
#                   its key**. A deferral that lost the key is indistinguishable
#                   next run from a finding nobody ever stated, so the fault
#                   would silently drop out of the record rather than being
#                   re-offered.
#   the dedup       a second run restating the same keys must file nothing and
#                   cite the open issues. Without it the Monitor's own
#                   persistence — restating a fault that is still true, which
#                   the prompt asks for — turns into a duplicate every day.
#   the tactical    gate `monitor_tactical_keys` is empty by default, and a
#                   tactical finding must then produce a proposal and **no**
#                   `pw::decision`. This is the one path where the pipeline
#                   would be acting on its own authority, and "gated closed"
#                   is the whole claim.
#   the page rule   a mechanical page gets one comment linking its fix; no page
#                   is ever closed here. A close from this script would leave
#                   the union log saying `fired` for ever, so the invariant
#                   could never clear and never fire again — a failure with no
#                   symptom until the next real incident.
#   the cadence     an hourly tick that is neither due nor pager-triggered
#                   must launch no model. The cost of getting this wrong is
#                   24 Sonnet runs a day, invisible except on the bill.
#
# Plus the stage-health verdict (M17), the role guard and the switch.
#
# No network: `state_repo` is empty in every fixture (which makes the slot
# claim vacuously won, `lib/claim.sh`), and the stub `gh`/`claude` are ahead of
# everything on PATH.
#
# Run directly: ./test/monitor-cycle.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="${MONITOR_TEST_TMP:-$(mktemp -d)}"
mkdir -p "$tmp_dir"
[[ -n "${MONITOR_TEST_TMP:-}" ]] || trap 'rm -rf "$tmp_dir"' EXIT

failures=0
TODAY="$(date -u +%Y-%m-%d)"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "${haystack:0:600}"
    failures=$(( failures + 1 ))
  fi
}

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     in: %s\n' \
      "$desc" "$needle" "${haystack:0:600}"
    failures=$(( failures + 1 ))
  fi
}

# --- The shim node ----------------------------------------------------------
# `$2` is a jq filter applied to the shipped config, so each case states only
# its difference and every other required key stays in step with the real
# file — the acceptance-check rule that no test may assert a particular value
# from `config.json`.
make_node() {  # make_node <name> <jq-filter> -> prints its directory
  local name="$1" filter="$2"
  local dir="$tmp_dir/$name"
  mkdir -p "$dir" "$dir/home" "$dir/stub/bodies"
  local item
  for item in lib prompts scripts docs .claude monitor-cycle.sh review-cycle.sh \
              agent-cycle.sh config.schema.json; do
    # `-fn`, not a bare `-s`: a second `ln -s dir existing-symlink-to-dir`
    # follows the existing link and creates the target *inside* it — which,
    # for a symlink pointing back into the checkout, means writing a stray
    # `lib/lib` into the repository itself.
    [[ -e "$SCRIPT_DIR/$item" ]] && ln -sfn "$SCRIPT_DIR/$item" "$dir/$item"
  done
  jq "$filter" "$SCRIPT_DIR/config.json" > "$dir/config.json"

  printf '[]\n'  > "$dir/stub/open-findings.json"
  printf '[]\n'  > "$dir/stub/open-pages.json"
  printf '900\n' > "$dir/stub/next-issue-number"
  : > "$dir/stub/calls.log"

  # The `gh` stub. It answers the four listings the Script takes, records
  # every call, and — on a create — files the issue into open-findings.json
  # under the `monitor-finding-key` its body carries. That last part is what
  # makes the dedup case a genuine second run rather than a hand-written
  # fixture: run two sees exactly what run one left behind.
  cat > "$dir/stub/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
D='$dir/stub'
printf '%s\n' "\$*" >> "\$D/calls.log"

args=("\$@")
have() { local n="\$1" a; for a in "\${args[@]}"; do [[ "\$a" == "\$n" ]] && return 0; done; return 1; }
after() { local n="\$1" i; for i in "\${!args[@]}"; do [[ "\${args[\$i]}" == "\$n" ]] && { printf '%s' "\${args[\$(( i + 1 ))]:-}"; return 0; }; done; return 1; }

case "\${1:-}" in
  issue)
    case "\${2:-}" in
      list)
        if have --label && [[ "\$(after --label)" == "pw::pager" ]]; then
          cat "\$D/open-pages.json"
        elif have --search && [[ "\$(after --search)" == *monitor-finding-key* ]]; then
          cat "\$D/open-findings.json"
        else
          printf '[]\n'
        fi
        exit 0
        ;;
      create)
        n="\$(cat "\$D/next-issue-number")"
        printf '%s\n' "\$(( n + 1 ))" > "\$D/next-issue-number"
        body_file="\$(after --body-file)"
        title="\$(after --title)"
        repo="\$(after -R)"
        cp "\$body_file" "\$D/bodies/\$n.md"
        printf '%s\n' "\$title" > "\$D/bodies/\$n.title"
        key="\$(grep -oE 'monitor-finding-key: [a-z0-9][a-z0-9-]*' "\$body_file" | head -n1 | awk '{print \$2}')"
        if [[ -n "\$key" ]]; then
          jq --arg k "\$key" --argjson n "\$n" --arg u "https://github.com/\$repo/issues/\$n" \\
             --arg t "\$title" '. + [{key: \$k, number: \$n, url: \$u, title: \$t, body: ("monitor-finding-key: " + \$k)}]' \\
             "\$D/open-findings.json" > "\$D/open-findings.json.tmp" && mv "\$D/open-findings.json.tmp" "\$D/open-findings.json"
        fi
        printf 'https://github.com/%s/issues/%s\n' "\$repo" "\$n"
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  pr) printf '[]\n'; exit 0 ;;
  api) printf '[]\n'; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$dir/stub/gh"

  # The `claude` stub: emits the stream-json envelope `run_claude_stage`
  # truncates to `<stage>.out`, carrying whatever result.json holds as the
  # final message's `result` string. It also keeps the prompt it was handed,
  # so a case can assert the digest actually reached the stage.
  cat > "$dir/stub/claude" <<STUB
#!/usr/bin/env bash
set -uo pipefail
D='$dir/stub'
cat > "\$D/prompt.txt"
printf '{"type":"system","subtype":"init"}\n'
jq -c -n --rawfile r "\$D/result.json" \\
  '{type: "result", subtype: "success", is_error: false, num_turns: 1,
    total_cost_usd: 0.01, duration_ms: 10, result: \$r}'
exit 0
STUB
  chmod +x "$dir/stub/claude"
  printf '{"status":"complete","report_markdown":"## What is broken now\\n\\nnothing","findings":[],"page_triage":[]}' \
    > "$dir/stub/result.json"
  printf '%s' "$dir"
}

RC=0
run_monitor() {  # run_monitor <dir> [args...] -> prints stdout+stderr, sets RC
  local dir="$1"; shift
  local out
  out="$(env HOME="$dir/home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$dir")" \
    PATH="$dir/stub:$PATH" LABELS_GH="$dir/stub/gh" CLAIM_GH="$dir/stub/gh" \
    TOGGLE_GH="$dir/stub/gh" \
    timeout 180 "$dir/monitor-cycle.sh" "$@" 2>&1)"
  RC=$?
  printf '%s' "$out"
}

state_of() { printf '%s' "$1/home/.local/state/poetic-agents"; }
events_of() { cat "$(state_of "$1")/monitor-log.jsonl" 2>/dev/null || true; }
report_of() { cat "$(state_of "$1")/monitor/$TODAY/report.md" 2>/dev/null || true; }
# `grep -c` prints 0 *and* exits 1 when nothing matches, so a `|| printf 0`
# here would emit two zeroes and every comparison against it would fail while
# looking right.
creates_of() {
  local n
  n="$(grep -c '^issue create' "$1/stub/calls.log" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# `repos` keeps one real-looking slug so a mechanical finding has somewhere
# legitimate to be filed; `state_repo` empty keeps the slot claim off the
# network; the pager/escalation repositories are this fixture's own.
BASE='.state_repo = ""
      | .repos = [{slug: "o/target", sources: ["issues:medium", "tech-debt", "abandoned-drafts"]}]
      | .crash_loop_repo = "o/ops"
      | .pager_repo = "o/ops"
      | .enabler_assignee = "someone"'

# ============================================================================
# 1. Four findings file three and defer the fourth, with its key (M11/M12)
# ============================================================================
d="$(make_node budget "$BASE")"
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"## What is broken now\n\nthree things\n\n## What limited throughput\n\nthe fit ladder\n\n## What is new\n\nnothing\n\n## Pages\n\nnone open",
 "findings":[
   {"key":"first-fault","class":"mechanical","title":"The first fault","body":"what/why/where/fix","repo":"o/target"},
   {"key":"second-fault","class":"mechanical","title":"The second fault","body":"what/why/where/fix","repo":"o/target"},
   {"key":"third-fault","class":"mechanical","title":"The third fault","body":"what/why/where/fix","repo":"o/target"},
   {"key":"fourth-fault","class":"mechanical","title":"The fourth fault","body":"what/why/where/fix","repo":"o/target"}],
 "page_triage":[]}
EOF
out="$(run_monitor "$d" --once)"
assert_eq "the run ends 0" "0" "$RC"
assert_eq "exactly monitor_max_filings_per_run issues are created" "3" "$(creates_of "$d")"
report="$(report_of "$d")"
assert_contains "the first finding is recorded as filed" "\`first-fault\` | filed" "$report"
assert_contains "and the report carries the citation an issue body can be grepped for" \
  "Monitor: monitor/$TODAY M-01" "$report"
assert_contains "the third is too" "\`third-fault\` | filed" "$report"
assert_contains "the fourth is deferred, and the report says why" \
  "deferred — the run's filing budget" "$report"
assert_contains "and the deferral carries the finding's own key, so the next run can tell" \
  "\`fourth-fault\`" "$report"
assert_contains "the stage's own three readings reach the report" "## What limited throughput" "$report"
first_body="$(cat "$d/stub/bodies/900.md")"
assert_contains "a filed issue carries the R12a-shaped provenance line" \
  "Monitor: monitor/$TODAY M-01" "$first_body"
assert_contains "and the machine-readable key the dedup matches on" \
  "monitor-finding-key: first-fault" "$first_body"
assert_contains "the third filing's provenance numbers within the day" \
  "Monitor: monitor/$TODAY M-03" "$(cat "$d/stub/bodies/902.md")"
assert_contains "mechanical findings are filed under the tech-debt label" \
  "--label pw::type:tech-debt" "$(grep '^issue create' "$d/stub/calls.log" | head -n1)"
assert_contains "and into the repository the finding named" "-R o/target" \
  "$(grep '^issue create' "$d/stub/calls.log" | head -n1)"
assert_eq "the run records what it filed on its own event" "3" \
  "$(events_of "$d" | jq -r 'select(.event == "monitor-report-written") | .findings_filed')"
assert_eq "and how many were stated" "4" \
  "$(events_of "$d" | jq -r 'select(.event == "monitor-report-written") | .findings_stated')"
assert_contains "the stage was handed the digest, not the raw records" \
  "# Pipeline digest" "$(cat "$d/stub/prompt.txt")"
assert_contains "and the prompt itself" "You are the **Pipeline Monitor**" "$(cat "$d/stub/prompt.txt")"

# --- The stage-health verdict (M17) ----------------------------------------
sh_file="$(state_of "$d")/.stage-health.json"
assert_eq "the monitor pipeline has a stage-health verdict of its own" "ok" \
  "$(jq -r '.stages.monitor.verdict' "$sh_file" 2>/dev/null)"
assert_eq "recorded against the stage name lib/stage-health.sh already reads" "1" \
  "$(events_of "$d" | jq -s '[.[] | select(.event == "stage-end" and .stage == "monitor")] | length')"

# ============================================================================
# 2. Dedup: a second run restating the same keys files nothing (M13)
# ============================================================================
# The stub filed run one's issues into its own open-findings listing, so this
# is a real second run against real prior state rather than a hand-written
# fixture. It restates the three keys run one actually filed — which is what
# the prompt asks a Monitor to do with a fault that is still true.
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"## What is broken now\n\nstill the same three\n\n## What limited throughput\n\nunchanged\n\n## What is new\n\nnothing\n\n## Pages\n\nnone open",
 "findings":[
   {"key":"first-fault","class":"mechanical","title":"The first fault","body":"still true","repo":"o/target"},
   {"key":"second-fault","class":"mechanical","title":"The second fault","body":"still true","repo":"o/target"},
   {"key":"third-fault","class":"mechanical","title":"The third fault","body":"still true","repo":"o/target"}],
 "page_triage":[]}
EOF
before="$(creates_of "$d")"
out="$(run_monitor "$d" --once)"
assert_eq "a second run with the same finding keys creates nothing" "$before" "$(creates_of "$d")"
report="$(report_of "$d")"
assert_contains "and the report says the finding is already open" "already-open" "$report"
assert_contains "citing the open issue's URL" "https://github.com/o/target/issues/900" "$report"
assert_eq "the run's own event records nothing filed" "0" \
  "$(events_of "$d" | jq -rs '[.[] | select(.event == "monitor-report-written")] | last | .findings_filed')"
assert_contains "the day's report is appended to, not overwritten — run one's ledger is still there" \
  "filed — filed as a mechanical finding" "$report"
assert_eq "and both runs have their own section in it" "2" \
  "$(grep -c '^## Run ' "$(state_of "$d")/monitor/$TODAY/report.md")"
assert_contains "the second run's numbering continues the day's, rather than restarting at 01" \
  "Monitor: monitor/$TODAY M-05" "$report"

# And the finding run one deferred is filed by a run that reaches it, since
# its key was never open anywhere — which is the whole point of recording a
# deferral by key rather than dropping it.
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"## What is broken now\n\nthe deferred one\n\n## What limited throughput\n\nunchanged\n\n## What is new\n\nnothing\n\n## Pages\n\nnone open",
 "findings":[
   {"key":"fourth-fault","class":"mechanical","title":"The fourth fault","body":"what/why/where/fix","repo":"o/target"}],
 "page_triage":[]}
EOF
out="$(run_monitor "$d" --once)"
assert_eq "a later run files the finding an earlier one deferred" "$(( before + 1 ))" "$(creates_of "$d")"

# ============================================================================
# 3. The tactical gate is closed by default (M14b)
# ============================================================================
d="$(make_node tactical-closed "$BASE | .monitor_tactical_keys = []")"
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"## What is broken now\n\nnothing\n\n## What limited throughput\n\na cadence\n\n## What is new\n\nnothing\n\n## Pages\n\nnone",
 "findings":[
   {"key":"review-cadence-slow","class":"tactical","title":"The review cadence is too slow","body":"evidence","config_key":"project_review.defaults.min_days_between_reviews"}],
 "page_triage":[]}
EOF
out="$(run_monitor "$d" --once)"
assert_eq "a tactical finding with an empty allow-list creates no issue at all" "0" "$(creates_of "$d")"
report="$(report_of "$d")"
assert_contains "it is recorded as proposed" "proposed" "$report"
assert_contains "and the report names the key that was not delegated" \
  "project_review.defaults.min_days_between_reviews" "$report"
assert_lacks "no pw::decision is filed" "pw::decision" "$(cat "$d/stub/calls.log")"

# --- and the same finding with the key delegated does move ------------------
d="$(make_node tactical-open \
  "$BASE | .monitor_tactical_keys = [\"project_review.defaults.min_days_between_reviews\"]")"
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"## What is broken now\n\nnothing\n\n## What limited throughput\n\na cadence\n\n## What is new\n\nnothing\n\n## Pages\n\nnone",
 "findings":[
   {"key":"review-cadence-slow","class":"tactical","title":"The review cadence is too slow","body":"evidence","config_key":"project_review.defaults.min_days_between_reviews"}],
 "page_triage":[]}
EOF
out="$(run_monitor "$d" --once)"
assert_eq "a delegated key files exactly one record" "1" "$(creates_of "$d")"
assert_contains "as a pw::decision" "--label pw::decision" "$(grep '^issue create' "$d/stub/calls.log")"
assert_contains "filed into the escalation repository" "-R o/ops" "$(grep '^issue create' "$d/stub/calls.log")"
assert_contains "and closed immediately, which is what makes reopening it the veto" \
  "issue close 900 -R o/ops" "$(cat "$d/stub/calls.log")"
decision_body="$(cat "$d/stub/bodies/900.md")"
assert_contains "the record carries the #937 veto instruction" "vetoes the decision" "$decision_body"
assert_contains "and says in as many words that it changes no configuration" \
  "changes no configuration" "$decision_body"
assert_contains "with a reason_key, so a fresh reason gets a fresh record" \
  "reason_key=monitor-review-cadence-slow" "$decision_body"

# ============================================================================
# 4. A strategic finding is the one path to the owner (M14c)
# ============================================================================
d="$(make_node strategic "$BASE")"
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"## What is broken now\n\nnothing\n\n## What limited throughput\n\nthe shared quota\n\n## What is new\n\nyes\n\n## Pages\n\nnone",
 "findings":[
   {"key":"shared-quota-binds","class":"strategic","title":"The fleet exhausted its shared quota on 4 of 7 days","body":"evidence","options":"1. more accounts\n2. fewer nodes"}],
 "page_triage":[]}
EOF
out="$(run_monitor "$d" --once)"
assert_eq "one escalation is filed" "1" "$(creates_of "$d")"
create_call="$(grep '^issue create' "$d/stub/calls.log")"
assert_contains "assigned to enabler_assignee — assignment is what keeps it out of the issues source" \
  "--assignee someone" "$create_call"
assert_contains "and labelled as an escalation" "--label enabler-escalation" "$create_call"
assert_contains "the options are written down for the owner" "1. more accounts" \
  "$(cat "$d/stub/bodies/900.md")"

# ============================================================================
# 5. Pages triage: a comment, and never a close (M15/M15a)
# ============================================================================
d="$(make_node pages "$BASE")"
cat > "$d/stub/open-pages.json" <<'EOF'
[{"number":501,"url":"https://github.com/o/ops/issues/501","title":"Pager: node-stale",
  "createdAt":"2026-01-01T00:00:00Z","assignees":[],"body":"ref: pager:node-stale","comments":[]},
 {"number":502,"url":"https://github.com/o/ops/issues/502","title":"Pager: verdict-unanimous",
  "createdAt":"2026-01-01T00:00:00Z","assignees":[],"body":"ref: pager:verdict-unanimous",
  "comments":[{"body":"an earlier note\nmonitor-finding-key: already-commented"}]}]
EOF
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"## What is broken now\n\na phantom page\n\n## What limited throughput\n\nnothing\n\n## What is new\n\nnothing\n\n## Pages\n\n#501 is a phantom; #502 needs the owner",
 "findings":[
   {"key":"node-stale-phantom","class":"mechanical","title":"node-stale fires on a node that is publishing","body":"what/why/where/fix","repo":"o/target"}],
 "page_triage":[
   {"issue":501,"verdict":"mechanical","finding_key":"node-stale-phantom","note":"the invariant reads a snapshot, not the clock"},
   {"issue":502,"verdict":"strategic","finding_key":"","note":"only the owner can say whether unanimity is wanted here"}]}
EOF
out="$(run_monitor "$d" --once)"
calls="$(cat "$d/stub/calls.log")"
assert_eq "the mechanical page's fix is filed" "1" "$(creates_of "$d")"
assert_contains "and one comment is posted on the page linking it" \
  "issue comment 501 -R o/ops" "$calls"
assert_eq "exactly one comment, not one per run-of-the-loop" "1" \
  "$(grep -c '^issue comment' "$d/stub/calls.log")"
assert_lacks "the Monitor never closes a page" "issue close 501" "$calls"
assert_lacks "nor the strategic one" "issue close 502" "$calls"
report="$(report_of "$d")"
assert_contains "the report carries a triage verdict for the mechanical page" \
  "| #501 | mechanical |" "$report"
assert_contains "and for the strategic one, left for the owner" "| #502 | strategic |" "$report"
assert_eq "a page that already carries this finding's comment is not commented on twice" "0" \
  "$(grep -c '^issue comment 502' "$d/stub/calls.log")"

# A second run must not comment again: the stub's page now carries the marker.
jq --arg u "https://github.com/o/target/issues/900" '
  map(if .number == 501
      then .comments = [{body: ("linked " + $u + "\nmonitor-finding-key: node-stale-phantom")}]
      else . end)' "$d/stub/open-pages.json" > "$d/stub/open-pages.json.tmp" \
  && mv "$d/stub/open-pages.json.tmp" "$d/stub/open-pages.json"
out="$(run_monitor "$d" --once)"
assert_eq "and a later run, seeing its own marker, posts no second comment" "1" \
  "$(grep -c '^issue comment' "$d/stub/calls.log")"

# ============================================================================
# 6. The cadence gate (M4)
# ============================================================================
# An hourly tick that is neither the daily slot nor pager-triggered must cost
# no model call. `schedule.monitor_hour` is set to an hour this run is not in,
# so the daily trigger cannot fire whenever the suite happens to run.
not_now="$(( ( 10#$(date -u +%H) + 5 ) % 24 ))"
d="$(make_node not-due "$BASE | .schedule.monitor_hour = $not_now")"
out="$(run_monitor "$d")"
assert_eq "a tick that is not due ends 0 — cron must not read it as a failure" "0" "$RC"
assert_eq "and stands down naming the cause" "not-due" \
  "$(events_of "$d" | jq -r 'select(.event == "monitor-stand-down") | .cause')"
assert_eq "launching no model at all" "0" \
  "$([[ -f "$d/stub/prompt.txt" ]] && echo 1 || echo 0)"
assert_eq "and writing no report" "" "$(report_of "$d")"

# The same node, with a pager-fired event newer than any report: now due.
mkdir -p "$(state_of "$d")"
printf '{"ts":"%s","cycle":"pub","node":"peer","event":"pager-fired","key":"node-stale","evidence":"e","issue_number":1,"issue_url":"u","remedy_class":"owner-only","nodes":[]}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$(state_of "$d")/log.jsonl"
out="$(run_monitor "$d")"
assert_eq "a pager-fired newer than the last report makes the same tick due" "pager" \
  "$(events_of "$d" | jq -rs '[.[] | select(.event == "monitor-report-written")] | last | .trigger')"
assert_eq "and the model does run" "1" "$([[ -f "$d/stub/prompt.txt" ]] && echo 1 || echo 0)"

# And having written the report, the same trigger does not fire again — the
# comparison has advanced past the event that caused it.
out="$(run_monitor "$d")"
assert_eq "a page that already produced a run does not produce a second" "not-due" \
  "$(events_of "$d" | jq -rs '[.[] | select(.event == "monitor-stand-down")] | last | .cause')"

# ============================================================================
# 7. The role guard and the switch (M2b/M2a)
# ============================================================================
d="$(make_node standby "$BASE")"
out="$(env HOME="$d/home" NODE_NAME=standby PATH="$d/stub:$PATH" \
  timeout 60 "$d/monitor-cycle.sh" 2>&1)"
rc=$?
assert_eq "a standby node exits 0" "0" "$rc"
assert_contains "saying which role it saw" "this node is standby" "$out"
assert_eq "and writes nothing under state_dir" "0" \
  "$([[ -d "$(state_of "$d")" ]] && echo 1 || echo 0)"

d="$(make_node switched-off "$BASE")"
mkdir -p "$(state_of "$d")"
cat > "$(state_of "$d")/disabled.json" <<'EOF'
{"state":"disabled","reason":"testing","since":"2026-01-01T00:00:00Z","mode":"stop"}
EOF
out="$(run_monitor "$d" --once)"
assert_eq "a disabled node stands the Monitor down too" "disabled-node" \
  "$(events_of "$d" | jq -r 'select(.event == "monitor-stand-down") | .cause')"
assert_eq "launching no model" "0" "$([[ -f "$d/stub/prompt.txt" ]] && echo 1 || echo 0)"

# ============================================================================
# 8. monitor_model empty switches the pipeline off (M9)
# ============================================================================
d="$(make_node model-off "$BASE | .monitor_model = \"\"")"
out="$(run_monitor "$d" --once)"
assert_eq "an empty monitor_model stands the pipeline down" "disabled-config" \
  "$(events_of "$d" | jq -r 'select(.event == "monitor-stand-down") | .cause')"
assert_eq "and takes no lock on the way past" "0" \
  "$([[ -f "$(state_of "$d")/monitor-lock.json" ]] && echo 1 || echo 0)"

# ============================================================================
# 9. --dry-run builds the digest and nothing else
# ============================================================================
d="$(make_node dry "$BASE")"
out="$(run_monitor "$d" --dry-run)"
assert_contains "--dry-run prints the digest" "# Pipeline digest" "$out"
assert_eq "and launches no model" "0" "$([[ -f "$d/stub/prompt.txt" ]] && echo 1 || echo 0)"
assert_eq "and files nothing" "0" "$(creates_of "$d")"
assert_eq "and writes no report" "" "$(report_of "$d")"

# ============================================================================
# 10. A refused finding is recorded rather than normalised (M11)
# ============================================================================
d="$(make_node refused "$BASE")"
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"## What is broken now\n\nnothing\n\n## What limited throughput\n\nnothing\n\n## What is new\n\nnothing\n\n## Pages\n\nnone",
 "findings":[
   {"key":"Bad Key!","class":"mechanical","title":"A finding with an unusable key","body":"x","repo":"o/target"},
   {"key":"wrong-repository","class":"mechanical","title":"A finding naming a repository we do not configure","body":"x","repo":"someone/else"}],
 "page_triage":[]}
EOF
out="$(run_monitor "$d" --once)"
assert_eq "neither finding is filed" "0" "$(creates_of "$d")"
report="$(report_of "$d")"
assert_contains "a malformed key is refused, not rewritten" "no usable finding_key" "$report"
assert_contains "and an unconfigured repository is refused by name" \
  "is not a repository this installation configures" "$report"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
