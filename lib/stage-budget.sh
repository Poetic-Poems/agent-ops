#!/usr/bin/env bash
#
# lib/stage-budget.sh — how long a stage is allowed (requirement 4f of
# docs/IMPLEMENTATION-PIPELINE-SPEC.md).
#
# Requirement 4e gave every stage two caps: a backstop and a liveness
# watchdog. This file decides what those two numbers should be, per
# (actor, repository, model), from the pipeline's own record of itself —
# because a number chosen by hand is a guess that decays. The cost of
# reviewing this repository rises with every specification edit, so whatever
# figure is picked becomes wrong on the same trajectory that made the last one
# wrong; and for an installation that is not this one, nobody should be asked
# to pick at all.
#
# Nothing here is stored. Every value is a pure function of the fleet log
# union, recomputed at the top of each cycle — the same way the blocked
# extract, the void extract and the no-op fingerprint are derived rather than
# kept. That is not a shortcut: a stored controller state is a second thing to
# replicate, to reconcile between four nodes, and to be wrong. A fold over the
# events every node already shares gives every node the same answer with
# nothing to synchronise.
#
# The two numbers are estimated quite differently, and that is the point.
#
#   the watchdog threshold is ESTIMATED, from a statistic that converges fast.
#     Its sample is inter-event gaps (requirement 33a), so one long stage
#     contributes an observation of the thing being measured rather than one
#     data point about a whole run. A new repository has a usable gap
#     distribution within a few cycles, not weeks.
#
#   the backstop is CONTROLLED, not estimated, so it needs no data at all to
#     start. Run durations give exactly one observation per stage per cycle,
#     and — worse — a killed run enters the sample at its cap rather than at
#     its true length, so fitting a cap to them drags the estimate down, which
#     lowers the cap, which censors more runs. Simulated over the real
#     distributions that spiral does not converge; it wanders and never
#     recovers the tail. So the backstop is not fitted. It starts generous and
#     moves only in response to kills that actually happened.
#
# Both directions of both mechanisms are chosen so that censoring pushes them
# the safe way. See `stage_budget_table`.

# The shipped priors, in minutes, and the only numbers here that are not
# derived from something. They exist so that an installation with no history
# whatever — a customer on its first cycle — gets sensible behaviour without
# being asked to choose anything.
#
# Every one sits above the fixed cap it replaces, because a backstop equal to
# that cap is not a backstop: under requirement 4e the watchdog does the
# killing, and the backstop only bounds the pathological case of a session
# looping productively without converging, so it must sit clear of the
# durations the watchdog is expected to let through. They err high on purpose.
# The loss function is violently asymmetric: too generous costs the marginal
# minutes of a session that was going to fail anyway, at roughly a tenth of a
# dollar a minute and bounded by the lock above it, while too tight throws
# away everything — on the run that prompted this, $13.79 of Implementor work,
# $2.92 of Reviewer, an Enabler engagement, and the review gate itself.
STAGE_BUDGET_PRIORS='{
  "coordinator":      {"backstop": 20,  "inactivity": 10},
  "implementor":      {"backstop": 150, "inactivity": 10},
  "reviewer":         {"backstop": 90,  "inactivity": 10},
  "approver":         {"backstop": 30,  "inactivity": 10},
  "enabler":          {"backstop": 30,  "inactivity": 10},
  "refiner":          {"backstop": 30,  "inactivity": 10},
  "project-reviewer": {"backstop": 150, "inactivity": 10}
}'

# The tuning constants, all overridable from `config.json`'s `stage_budget`.
# Defaults here rather than there, for requirement 4e's reason: a value an
# installation must set is a value it can set wrongly, and every one of these
# has a defensible answer that no customer should have to find.
STAGE_BUDGET_SETTINGS='{
  "gap_multiplier": 4,
  "shrinkage_runs": 20,
  "window_days": 30,
  "window_runs": 200,
  "increase_factor": 1.5,
  "decrease_after_runs": 20,
  "decrease_step_min": 5,
  "kill_rate_slo": 0.005,
  "ceiling_multiple": 2
}'

# stage_budget_settings CONFIG_JSON
# The settings above with any `stage_budget` key from the configuration laid
# over them. An unreadable or absent object leaves the defaults untouched:
# this is a tuning surface, and a malformed one must not stop a cycle.
stage_budget_settings() {
  local cfg="${1:-{\}}" merged
  merged="$(jq -nc --argjson d "$STAGE_BUDGET_SETTINGS" --argjson c "$cfg" \
    '$d + (if ($c | type) == "object" then ($c.stage_budget // {}) else {} end
           | with_entries(select(.value | type == "number")))' 2>/dev/null)" || merged=""
  [[ -n "$merged" ]] || merged="$STAGE_BUDGET_SETTINGS"
  printf '%s\n' "$merged"
}

# stage_budget_observations  < union JSONL on stdin
# One record per completed stage run, oldest first, as a JSON array:
#
#   {actor, repo, model, ts, duration_min, gap_max, killed}
#
# Three joins and one exclusion are worth naming:
#
#   the repository comes from the cycle, not the event. A `stage-end` names
#     only its stage; the cycle it belongs to named its repository in the
#     `selection` event. `review-stage-end` carries its own.
#   the Co-Ordinator and the Enabler are keyed `*`. Neither has a repository
#     naturally — the Co-Ordinator runs *before* selection, and the Enabler
#     spans repositories — so pretending otherwise would fragment their
#     samples for no gain.
#   a killed run contributes no duration. Its recorded length is its cap, not
#     its length: that is the censoring that makes fitting a cap to durations
#     self-defeating, and the fix begins with not pretending the observation
#     is one. It still counts as a run, and as a kill.
#   an event predating `kill_reason` is read the way it was true at the time:
#     exit 124 was a wall-clock kill and nothing else could produce it.
stage_budget_observations() {
  jq -c -R 'fromjson? // empty' 2>/dev/null \
  | jq -sc '
      (map(select(.event == "selection" and (.cycle // "") != "" and (.repo // "") != ""))
       | map({key: .cycle, value: .repo}) | from_entries) as $repo_of
      | [ .[]
          | select((.event == "stage-end" or .event == "review-stage-end")
                   and (.exit_code | type) == "number")
          | (if .event == "review-stage-end" then "project-reviewer" else (.stage // "") end) as $actor
          | select($actor != "")
          | (if (.kill_reason // "") != "" then .kill_reason
             elif .exit_code == 124 then "backstop"
             else "" end) as $killed
          | {
              actor: $actor,
              repo: (if $actor == "coordinator" or $actor == "enabler" then "*"
                     else (.repo // $repo_of[(.cycle // "")] // "*") end),
              model: (.model // "*"),
              ts: (.ts // ""),
              duration_min: (if $killed != "" or (.duration_ms | type) != "number"
                             then null else (.duration_ms / 60000) end),
              gap_max: (if (.gaps | type) == "object" and (.gaps.max | type) == "number"
                        then .gaps.max else null end),
              killed: $killed
            } ]
      | sort_by(.ts)' 2>/dev/null || printf '[]'
}

# stage_budget_table OBSERVATIONS_JSON SETTINGS_JSON NOW_ISO
# The whole derivation, as one object:
#
#   {settings, cutoff, cells: {<key>: {…}}, actors: {<actor>: {…}}}
#
# where a cell key is `<actor>|<repo>|<model>`.
#
# ## The cell is (actor, repository, model)
#
# Not (actor) — reviewing this repository costs three to four times what
# reviewing the others does, because every diff is checked against a
# five-thousand-line specification. Not (actor, repository) either: the
# strongest single predictor of how long a stage runs is the model it ran, and
# a cell that pools two of them has a bimodal duration distribution that no
# single moment or quantile describes. The complex-model reviews here run about
# twice as long at every quantile as the default-model ones and were killed
# roughly six times as often; pooling them gives a controller an average kill
# rate that is far too tight for one and needlessly loose for the other, and it
# converges for neither.
#
# Node is deliberately *not* a dimension, though nodes do differ in speed. It
# would divide the largest cell here to about eleven runs and the interesting
# one to about five, and no estimator recovers a distribution tail from five
# observations — while the tail is the entire quantity of interest. The
# thresholds are generous enough to absorb hardware variation instead.
#
# ## The watchdog threshold: a multiple of the largest gap seen
#
# `k x max(gap)`, and the choice of the *maximum* rather than a mean plus so
# many standard deviations is the load-bearing one. If a run is killed for
# inactivity at threshold T, its recorded maximum gap is T — censored — so the
# next threshold computed from it is k x T, which is larger. Censoring widens
# this estimator by construction. Under a mean-plus-sigma rule the same
# censored observation enters *below* its true value and pulls the estimate
# down, which tightens the threshold, which censors more: the death spiral.
# It also assumes nothing about the distribution, which matters because gaps
# are heavy-tailed — long test suites, continuous-integration waits, stalls.
#
# It is floored at the shipped prior and never narrows below it, whatever the
# data say. A threshold that tightens itself would reintroduce, from the other
# side, exactly the failure this mechanism exists to end.
#
# ## The backstop: multiplicative increase, additive decrease
#
# The mirror image of the congestion control everyone knows, and deliberately
# so. In a network the danger is a window grown too *large*, so it backs off
# hard and recovers slowly. Here the danger is a cap set too *small* — that is
# what destroys a stage — so the sharp, immediate move is upward and the
# cautious, gradual move is downward:
#
#   on a backstop kill        multiply. A kill is the only unambiguous
#                             evidence the cap is too tight, and it is exactly
#                             the censored observation that broke the
#                             estimator approach; here it is the control
#                             signal rather than a source of bias.
#   on sustained success      subtract a small step, and only when three
#                             things hold at once: a run of clean stages, an
#                             observed kill rate inside the objective, and a
#                             95th percentile that still sits well clear of
#                             the reduced cap.
#
# Floors and ceilings bound the fold: never below the shipped prior, never
# below twice the observed 95th percentile of *completed* runs, and never
# above a fixed multiple of the prior. When the floor and the ceiling
# disagree — a cell whose real durations have outgrown the ceiling — the floor
# wins. Throughput is a preference; discarding a finished stage is not.
stage_budget_table() {
  local obs="${1:-[]}" settings="${2:-$STAGE_BUDGET_SETTINGS}" now="${3:-}" out
  [[ -n "$now" ]] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(jq -nc --argjson obs "$obs" --argjson s "$settings" \
      --argjson priors "$STAGE_BUDGET_PRIORS" --arg now "$now" '
    # Every helper is defined up front, because jq allows no pipe between one
    # definition and the next, and the ones that need a binding take it as an
    # argument rather than closing over it.

    # Nearest-rank percentile of an already-sorted array: no interpolation, so
    # every figure is a run that really happened.
    def pct($a; $q):
      ($a | length) as $n
      | if $n == 0 then null
        else $a[ ((($n * $q) | ceil) - 1) | if . < 0 then 0 else . end ]
        end;

    # The hierarchical shrinkage of requirement 4f: an estimate starts at the
    # pooled value one level up and moves towards its own data as its own run
    # count grows, reaching the halfway point at `shrinkage_runs`. There is no
    # threshold at which a cell switches on; it slides. This is what makes the
    # model dimension affordable — a model used twice in a repository
    # contributes almost nothing of its own and sits essentially at the pooled
    # estimate, rather than producing the wild cell a hard split would.
    # Gaps are recorded in seconds (requirement 33a) and every threshold here
    # is in minutes, so the multiplier converts as it scales: `k x max(gap)`
    # arrives as `gap_multiplier * gap_max / 60`.
    def shrink($own; $prior; $n):
      if $own == null or $n <= 0 then $prior
      else ((($n * $own) + ($s.shrinkage_runs * $prior)) / ($n + $s.shrinkage_runs))
      end;

    # The window is both a time bound and a count bound. A time bound is what
    # lets a repository whose cost profile is changing be described by what it
    # costs now; a count bound is what keeps a quiet repository from being
    # judged on two runs from three weeks ago and one from today. The time
    # bound is applied by the caller below, the count bound here.
    def window($rows):
      ($rows | sort_by(.ts))
      | (if (length > $s.window_runs) then .[(length - $s.window_runs):] else . end);

    # Everything one grouping of runs has to say about itself.
    def stats($rows):
      window($rows) as $w
      | ([ $w[] | .gap_max | select(. != null) ]) as $gaps
      | ([ $w[] | .duration_min | select(. != null) ] | sort) as $durs
      | ([ $w[] | select(.killed == "backstop") ] | length) as $kills
      | {
          n: ($w | length),
          completed: ($durs | length),
          gap_max: (if ($gaps | length) == 0 then null else ($gaps | max) end),
          p95_duration_min: pct($durs; 0.95),
          backstop_kills: $kills,
          kill_rate: (if ($w | length) == 0 then 0 else ($kills / ($w | length)) end),
          runs: $w
        };

    # The controller, as a fold over the window in time order. Replaying it
    # from the log rather than storing it is what lets four nodes agree
    # without talking to each other.
    def controller($st; $prior):
      ($st.p95_duration_min // 0) as $p95
      | ($prior * $s.ceiling_multiple) as $ceiling
      | ([$prior, 2 * $p95] | max) as $floor
      | (reduce $st.runs[] as $r ({b: $prior, streak: 0};
          if $r.killed == "backstop"
          then {b: (.b * $s.increase_factor), streak: 0}
          else (.streak + 1) as $k
            | if $k >= $s.decrease_after_runs
                 and $st.kill_rate <= $s.kill_rate_slo
                 and (.b - $s.decrease_step_min) >= $prior
                 and (.b - $s.decrease_step_min) >= (2 * $p95)
              then {b: (.b - $s.decrease_step_min), streak: 0}
              else {b: .b, streak: $k}
              end
          end) | .b) as $b
      # Floor last, so a cell whose real durations have outgrown the ceiling
      # keeps a cap it can finish inside.
      | ([([$b, $ceiling] | min), $floor] | max);

    def prior_of($actor; $field):
      ($priors[$actor][$field] // $priors.implementor[$field]);

    # The two pooled levels above a cell: the same actor across every model,
    # and the same actor and model across every repository. The shipped prior
    # is the root of the hierarchy.
    def pooled_inactivity($actor; $by_actor):
      prior_of($actor; "inactivity") as $p
      | ($by_actor[$actor] // {n: 0, gap_max: null}) as $st
      | shrink((if $st.gap_max == null then null else ($s.gap_multiplier * $st.gap_max / 60) end);
               $p; $st.n);

    def model_inactivity($actor; $model; $by_actor; $by_actor_model):
      pooled_inactivity($actor; $by_actor) as $up
      | ($by_actor_model[$actor + "|" + $model] // {n: 0, gap_max: null}) as $st
      | shrink((if $st.gap_max == null then null else ($s.gap_multiplier * $st.gap_max / 60) end);
               $up; $st.n);

    ($now | fromdateiso8601) as $now_epoch
    | ($now_epoch - ($s.window_days * 86400)) as $cut_epoch
    | ($cut_epoch | todateiso8601) as $cutoff
    | [ $obs[] | select((.ts // "") >= $cutoff) ] as $recent
    | ($recent | group_by(.actor)
       | map({key: .[0].actor, value: stats(.)}) | from_entries) as $by_actor
    | ($recent | group_by([.actor, .model])
       | map({key: (.[0].actor + "|" + .[0].model), value: stats(.)}) | from_entries) as $by_actor_model
    | {
        settings: $s,
        cutoff: $cutoff,
        actors: ($by_actor
          | to_entries
          | map(.key as $a | .value as $st
            | {
                key: $a,
                value: {
                  n: $st.n,
                  gap_max: $st.gap_max,
                  p95_duration_min: $st.p95_duration_min,
                  backstop_kills: $st.backstop_kills,
                  backstop_min: (prior_of($a; "backstop") | floor),
                  # Clamped to the backstop here as it is per cell, and for
                  # the same reason: a watchdog allowed past the outer bound
                  # could never fire. It bites here more easily than there,
                  # because the pooled backstop is the shipped prior while the
                  # pooled threshold has every repository behind it.
                  inactivity_min: (
                    (prior_of($a; "backstop") | floor) as $b
                    | (([pooled_inactivity($a; $by_actor), prior_of($a; "inactivity")] | max) | ceil) as $i
                    | if $i > $b then $b else $i end),
                  basis: (if $st.n > 0 then "pooled" else "prior" end)
                }
              })
          | from_entries),
        cells: ($recent | group_by([.actor, .repo, .model])
          | map(
              .[0].actor as $a | .[0].repo as $r | .[0].model as $m
              | stats(.) as $st
              | controller($st; prior_of($a; "backstop")) as $b
              | ($b | ceil) as $bmin
              | shrink((if $st.gap_max == null then null else ($s.gap_multiplier * $st.gap_max / 60) end);
                       model_inactivity($a; $m; $by_actor; $by_actor_model); $st.n) as $inact
              | (([$inact, prior_of($a; "inactivity")] | max) | ceil) as $imin
              | {
                  key: ($a + "|" + $r + "|" + $m),
                  value: {
                    actor: $a, repo: $r, model: $m,
                    n: $st.n,
                    completed: $st.completed,
                    gap_max: $st.gap_max,
                    p95_duration_min: $st.p95_duration_min,
                    backstop_kills: $st.backstop_kills,
                    kill_rate: $st.kill_rate,
                    backstop_min: $bmin,
                    # Never above the backstop: a watchdog that let a stage
                    # past its own outer bound could never fire.
                    inactivity_min: (if $imin > $bmin then $bmin else $imin end),
                    # Requirement 4f: a cell running on the prior rather than
                    # on its own evidence says so, because a self-tuning
                    # number that cannot be traced is a mystery number.
                    basis: (if $st.n >= $s.shrinkage_runs then "own"
                            elif $st.n > 0 then "shrunk"
                            else "prior" end)
                  }
                })
          | from_entries)
      }' 2>/dev/null)" || out=""
  if [[ -z "$out" ]]; then
    out="$(jq -nc --argjson s "$settings" '{settings: $s, cutoff: null, actors: {}, cells: {}}')"
  fi
  printf '%s\n' "$out"
}

# stage_budget_resolve TABLE ACTOR REPO MODEL [OVERRIDES]
# The two numbers this launch will use, and where each came from:
#
#   {backstop_min, inactivity_min, basis, source}
#
# Resolution order, most specific first (requirement 4f):
#
#   1. an explicit override for this (actor, repository)   config.json
#   2. an explicit override for this actor                 config.json
#   3. the adaptive value for this (actor, repository, model)
#   4. the shrunk pooled value for this actor
#   5. the shipped prior                                   code
#
# The caller resolves 1 and 2 into OVERRIDES — `{backstop, inactivity}`, either
# a number or null — because it is the caller that holds the configuration; 3
# to 5 are decided here. Configuration outranks the derivation deliberately:
# an installation that has said what it wants is not to be argued with, and
# the pipeline never writes to `config.json`, so a self-tuning value can never
# turn into pull-request churn in somebody else’s repository.
stage_budget_resolve() {
  local table="${1:-{\}}" actor="$2" repo="${3:-*}" model="${4:-*}" overrides="${5:-{\}}" out
  out="$(jq -nc --argjson t "$table" --argjson o "$overrides" \
      --argjson priors "$STAGE_BUDGET_PRIORS" \
      --arg a "$actor" --arg r "$repo" --arg m "$model" '
    ($priors[$a] // $priors.implementor) as $prior
    | ($t.cells[$a + "|" + $r + "|" + $m] // null) as $cell
    | ($t.actors[$a] // null) as $pooled
    | (if $cell != null then {b: $cell.backstop_min, i: $cell.inactivity_min, src: "cell", basis: $cell.basis}
       elif $pooled != null then {b: $pooled.backstop_min, i: $pooled.inactivity_min, src: "pooled", basis: $pooled.basis}
       else {b: $prior.backstop, i: $prior.inactivity, src: "prior", basis: "prior"} end) as $d
    | {
        backstop_min: (if ($o.backstop | type) == "number" then $o.backstop else $d.b end),
        inactivity_min: (if ($o.inactivity | type) == "number" then $o.inactivity else $d.i end),
        source: (if ($o.backstop | type) == "number" or ($o.inactivity | type) == "number"
                 then "config" else $d.src end),
        basis: $d.basis
      }' 2>/dev/null)" || out=""
  if [[ -z "$out" ]]; then
    out="$(jq -nc --argjson priors "$STAGE_BUDGET_PRIORS" --arg a "$actor" \
      '($priors[$a] // $priors.implementor) as $p
       | {backstop_min: $p.backstop, inactivity_min: $p.inactivity, source: "prior", basis: "prior"}')"
  fi
  printf '%s\n' "$out"
}

# stage_budget_all_overrides CONFIG_JSON
# What the configuration says about every implementation actor at once, in
# the OVERRIDES_JSON shape stage_budget_lock_seconds takes — taking the
# *largest* configured value for each, across the plain `timeout_<actor>` /
# `inactivity_<actor>` key and every repository's `stage_timeouts` /
# `stage_inactivity`: the lock derivation has to cover whichever repository
# this cycle lands on, and a per-repository override may be wider than the
# plain key.
#
# CONFIG_JSON is the parsed content of config.json, not a path, so this stays
# a pure function like the rest of this file. agent-cycle.sh (deriving the
# cycle lock a running cycle will hold) and scripts/doctor.sh (reporting that
# same threshold before any cycle runs) both call this rather than each
# keeping its own expression of "the widest configured cap per actor" — two
# independently maintained lists is exactly how they drifted before: doctor's
# own read once covered the plain key alone, so a per-repository override
# could pin an actor's backstop while the reported lock silently stayed
# narrower than the one agent-cycle.sh actually derived.
stage_budget_all_overrides() {
  local cfg="${1:-{\}}"
  jq -nc --argjson c "$cfg" '
    ($c // {}) as $cfg
    | ["coordinator", "implementor", "reviewer", "approver", "enabler", "refiner"]
    | map(. as $a
          | {
              key: $a,
              value: {
                backstop: ([ $cfg["timeout_" + $a],
                             (($cfg.repos // [])[] | (.stage_timeouts // {})[$a]) ]
                           | map(select(type == "number"))
                           | if length == 0 then null else max end),
                inactivity: ([ $cfg["inactivity_" + $a],
                               (($cfg.repos // [])[] | (.stage_inactivity // {})[$a]) ]
                             | map(select(type == "number"))
                             | if length == 0 then null else max end)
              }
            })
    | from_entries' 2>/dev/null || printf '{}'
}

# stage_budget_lock_seconds TABLE OVERRIDES_JSON SLACK_MIN [CONFIGURED_HOURS]
# The cycle lock must outlast a cycle that runs every stage to its limits, and
# every stage limit now moves. So the lock is *derived* from the backstops in
# force rather than asserted against them: the sum, over the six
# implementation actors, of the largest backstop each could be given this
# cycle, plus slack — in whole seconds, and never less than whatever the
# configuration asked for.
#
# Deriving it is the whole point. A constant checked against other constants
# has to be re-derived by hand every time any of them moves, and in the two
# days before this was written that arithmetic was redone three times, each
# raise forcing a knock-on recalculation somewhere else. It is also one fewer
# number an installation has to understand.
#
# The *largest*, not the one that will actually be used, and per actor rather
# than per cell: a cycle can land on any repository and any model, so the lock
# has to cover the worst case it could draw. Erring long is close to free —
# the holder of a dead lock is taken over on its pid, not on its age, so the
# threshold only bounds how long a *live but hung* process may hold on.
#
# OVERRIDES_JSON is `{<actor>: {backstop, inactivity}}`, the configured values
# the caller has already resolved; each is folded in as another candidate for
# that actor rather than as a replacement, for the same worst-case reason.
stage_budget_lock_seconds() {
  local table="${1:-{\}}" overrides="${2:-{\}}" slack="${3:-30}" configured="${4:-0}" out
  out="$(jq -nr --argjson t "$table" --argjson o "$overrides" \
      --argjson priors "$STAGE_BUDGET_PRIORS" \
      --argjson slack "$slack" --argjson configured "$configured" '
    ["coordinator", "implementor", "reviewer", "approver", "enabler", "refiner"]
    | map(. as $a
          | [ ($priors[$a].backstop // 0),
              ($o[$a].backstop // empty),
              ((($t.cells // {}) | to_entries[]
                | select(.value.actor == $a) | .value.backstop_min) // empty) ]
          | map(select(type == "number"))
          | max)
    | add as $sum
    | (($sum + $slack) * 60) as $derived
    | ($configured * 3600) as $floor
    | ([$derived, $floor] | max | ceil)' 2>/dev/null)" || out=""
  if [[ -z "$out" || "$out" == "null" ]]; then
    out="$(jq -nr --argjson c "$configured" '($c * 3600) | ceil')"
  fi
  printf '%s\n' "$out"
}
