#!/usr/bin/env bash
#
# scripts/cgroup-parent-setup.sh — create the persistent parent cgroup a
# scheduler is bounded by, and print the two .env lines that put it to use.
#
# ## Why a parent cgroup at all
#
# The knob worth setting on a scheduler is cgroup v2's `memory.high`: a soft
# ceiling above which the kernel reclaims proactively instead of letting the
# cgroup ratchet page cache up to its hard limit and then OOM-killing the
# stage that touched it last. Docker exposes no setting for it, so it has to
# be written to the cgroup directly — and a cgroup written directly is wiped
# the moment the container is recreated, which on this fleet is a median of
# well under an hour (`docker compose up -d`, a watchtower roll, a reboot).
# Measured 2026-09-08: three of four schedulers lost a hand-applied ceiling
# within 90 minutes, and one then hit its hard ceiling 23,995 times before a
# human happened to look at a dashboard (TD-PPagop-26090401, agent-ops#1266).
#
# On a systemd-driver host it does not even last that long: any `systemctl
# daemon-reload` resets it on a live container, because systemd re-applies the
# properties a unit declares and a `docker-<id>.scope` declares no MemoryHigh.
# Verified on the poetic node 2026-09-08 — written, read back, one unrelated
# reload, back to `max` with the container still running.
#
# A ceiling on the container's *parent* governs the container just as well and
# outlives it, because the parent is not what gets recreated — and, where the
# parent is a slice, because it *is* declared, so a daemon-reload re-asserts
# it rather than clearing it (verified the same day, same host). That is the
# only property that distinguishes this from the one-shot recipe it replaces,
# and it is the whole point.
#
# ## The livelock band, and why the parent also needs a hard ceiling
#
# `memory.high` alone is not enough. It only throttles — it never kills — so
# it needs a hard `memory.max` somewhere in the hierarchy for the kernel to
# actually reclaim past, or actually kill, once. Setting `memory.high` on the
# parent with `memory.max` left at `max` there (this script's own behaviour
# before agent-ops#1305) opens exactly that gap: the container sits above the
# parent's soft ceiling and below both cgroups' hard ones, `memory.high`
# throttles forever without ever disengaging, and every allocating task parks
# in uninterruptible `D` state. Measured on `ockham-container` 2026-09-09:
# 2,788,595 throttle events climbing at ~96/second, 14 processes wedged in
# `D` state, `docker exec` itself hanging, and 75 minutes before a human
# broke it by hand (`echo max > memory.high`). `doctor.sh`'s own `parented`
# verdict read this exact state as `[ ok ]` throughout (lib/memory.sh,
# `memory_cgroup_verdict`'s `livelocked`/`unconfirmed` branches close that
# gap; see that file for the full mechanism).
#
# So this script also sets the parent's `memory.max` (`--max`, default the sum
# of what runs under it — 1536m, the scheduler's own `AGENT_OPS_SCHEDULER_
# MEMORY`) and `memory.swap.max` (`--swap`, default `0`): a hard ceiling
# somewhere above `memory.high` closes the band, and a capped swap keeps a
# cgroup over its ceiling from instead swapping the *host* to a crawl — the
# same incident took 100% of host swap on a 5.8 GiB WSL2 VM. Raising
# `memory.high` above the children's `memory.max` instead — closing the band
# by making `memory.high` inert — was considered and rejected: it would
# discard the proactive reclaim this parent exists for and return the fleet to
# the unbounded, ratcheting behaviour agent-ops#1296 was merged to end.
#
# ## What this script does, and why it asks rather than assumes
#
# Nothing here hardcodes a path, because every path involved is a function of
# the host and this fleet's own hosts disagree:
#
#   * Docker's cgroup driver decides the layout. Under `cgroupfs` the parent
#     is a plain directory, `/sys/fs/cgroup/<name>`. Under `systemd` it is a
#     slice, and systemd owns it.
#   * systemd reads `-` in a slice name as a hierarchy separator, so
#     `agentops-1.slice` lives at `/sys/fs/cgroup/agentops.slice/
#     agentops-1.slice` — one level deeper than the name suggests. Assuming
#     otherwise is exactly the mistake that left a node unbounded for four
#     days (agent-ops#1266); it is repeated here at a different depth if you
#     let it be.
#   * systemd is not always PID 1 even when it is installed. The ockham node
#     is a WSL2 host with `systemd 249` on disk and `init(Ubuntu)` as PID 1,
#     so it gets a crontab `@reboot` hook where a systemd host gets a unit.
#
# So the driver is read from `docker info`, the slice path is derived from
# systemd's own naming rule and cross-checked against `systemctl show` where
# the slice is live, and the printed .env lines are whatever those two
# actually produced.
#
# ## Usage
#
# On the host, as root. A node holds compose.yaml and .env, not a clone, so
# lift this out of the image the node already runs:
#
#   docker compose exec -T scheduler cat /app/scripts/cgroup-parent-setup.sh \
#     > cgroup-parent-setup.sh
#   sudo bash cgroup-parent-setup.sh --name agentops-1 --limit 768m
#
# Then put the two printed lines in that stack's .env and `docker compose up
# -d`. One parent per scheduler, never one shared between the two stacks on a
# host: a ceiling on a parent bounds the aggregate of everything beneath it,
# so a shared 768 MiB is 768 MiB between them, not each.
#
#   --name NAME    parent cgroup name; letters, digits and `-`. Required.
#   --limit SIZE   memory.high ceiling: bytes, or with a `k`/`m`/`g` suffix.
#                  Default 768m.
#   --max SIZE     memory.max hard ceiling: bytes, a `k`/`m`/`g` suffix, or
#                  `max` for none (not recommended — see "the livelock band"
#                  above). Default 1536m, the sum of this parent's own
#                  children's `mem_limit` (one scheduler today,
#                  AGENT_OPS_SCHEDULER_MEMORY). This is what makes
#                  `memory.high`'s proactive reclaim actually matter: without
#                  a hard ceiling somewhere, nothing ever kills what
#                  `memory.high` failed to reclaim in time.
#   --swap SIZE    memory.swap.max ceiling: bytes, a `k`/`m`/`g` suffix, or
#                  `max` for unbounded (the previous, unsafe default).
#                  Default 0 — on a memory-capped host, unbounded swap
#                  degrades every other container and the host itself long
#                  before anything is killed.
#   --check        report what is in force and change nothing.
#   --no-boot-hook skip installing the reboot persistence (cgroupfs hosts).
#
# Exit status: 0 on success or a clean `--check`, 1 on error, 2 on a `--check`
# that found the parent absent, unbounded, or in the livelock band (a real
# `memory.high` with `memory.max` left at `max`).

set -uo pipefail

name=""
limit="768m"
max="1536m"
swap="0"
check=0
boot_hook=1

die() { printf 'cgroup-parent-setup: %s\n' "$1" >&2; exit 1; }

usage() {
  sed -n '2,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --name) [[ $# -ge 2 ]] || die "--name needs a value"; name="$2"; shift 2 ;;
    --limit) [[ $# -ge 2 ]] || die "--limit needs a value"; limit="$2"; shift 2 ;;
    --max) [[ $# -ge 2 ]] || die "--max needs a value"; max="$2"; shift 2 ;;
    --swap) [[ $# -ge 2 ]] || die "--swap needs a value"; swap="$2"; shift 2 ;;
    --check) check=1; shift ;;
    --no-boot-hook) boot_hook=0; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$name" ]] || die "--name is required (e.g. --name agentops-1)"
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]$ || "$name" =~ ^[A-Za-z0-9]$ ]] \
  || die "--name must be letters, digits and internal '-' only: $name"
name="${name%.slice}"

# to_bytes SIZE — `768m`, `1G`, `805306368` all become bytes. A ceiling is
# only ever compared against `memory.current`, which is in bytes, so this is
# the one unit that never needs a reader to convert in their head.
to_bytes() {
  local v="${1:-}" n unit
  n="${v%%[kKmMgG]}"
  unit="${v#"$n"}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "size is not a number: $v"
  case "$unit" in
    k|K) printf '%s' $(( n * 1024 )) ;;
    m|M) printf '%s' $(( n * 1024 * 1024 )) ;;
    g|G) printf '%s' $(( n * 1024 * 1024 * 1024 )) ;;
    '')  printf '%s' "$n" ;;
    *)   die "size has an unknown unit: $v" ;;
  esac
}
# to_ceiling SIZE — as to_bytes, but `max` passes through verbatim: the one
# value `--max`/`--swap` accept that `--limit` never needs to, since cgroup v2
# spells "no ceiling" as the literal word `max` rather than a number.
to_ceiling() {
  [[ "${1:-}" == "max" ]] && { printf 'max'; return 0; }
  to_bytes "$1"
}
limit_bytes="$(to_bytes "$limit")"
max_val="$(to_ceiling "$max")"
swap_val="$(to_ceiling "$swap")"
# systemd's unit-file grammar spells "no ceiling" `infinity`, not the sysfs
# `max` cgroupfs itself accepts — the two paths below write the same decision
# in each one's own vocabulary.
systemd_ceiling() { [[ "${1:-}" == "max" ]] && printf 'infinity' || printf '%s' "$1"; }

command -v docker >/dev/null 2>&1 || die "docker is not on PATH; run this on the host, not in a container"
driver="$(docker info --format '{{.CgroupDriver}}' 2>/dev/null)" \
  || die "cannot read 'docker info' — run this as root on the host"
[[ -n "$driver" ]] || die "docker did not report a cgroup driver"

version="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)"
[[ "$version" == "2" ]] || die "this host is on cgroup v$version; memory.high is a cgroup v2 knob"

# systemd_slice_path NAME — systemd's own naming rule, applied rather than
# guessed: each `-` in a slice name starts another level, so `a-b-c.slice`
# sits at /a.slice/a-b.slice/a-b-c.slice. The intermediate slices are implicit
# and carry no limits of their own, which is why bounding only the leaf is
# correct.
systemd_slice_path() {
  local n="${1%.slice}" acc="" path="" part
  local -a parts
  IFS='-' read -ra parts <<< "$n"
  for part in "${parts[@]}"; do
    acc="${acc:+$acc-}$part"
    path="$path/$acc.slice"
  done
  printf '%s' "$path"
}

case "$driver" in
  systemd)
    slice="$name.slice"
    unit="/etc/systemd/system/$slice"
    rel="$(systemd_slice_path "$name")"
    # Where systemd says it is, when it is running, beats where the rule says
    # it should be — the rule is how this works with the slice stopped.
    live="$(systemctl show -p ControlGroup --value "$slice" 2>/dev/null)"
    [[ -n "$live" ]] && rel="$live"
    parent_dir="/sys/fs/cgroup$rel"
    ;;
  cgroupfs)
    parent_dir="/sys/fs/cgroup/$name"
    unit=""
    ;;
  *)
    die "unknown cgroup driver '$driver'; expected systemd or cgroupfs"
    ;;
esac

high_file="$parent_dir/memory.high"
max_file="$parent_dir/memory.max"
swap_file="$parent_dir/memory.swap.max"

report() {
  printf 'driver        %s (cgroup v%s)\n' "$driver" "$version"
  printf 'parent        %s\n' "$name${unit:+.slice}"
  printf 'cgroup path   %s\n' "$parent_dir"
  if [[ -r "$high_file" ]]; then
    printf 'memory.high   %s\n' "$(cat "$high_file")"
    printf 'memory.max    %s\n' "$(cat "$max_file" 2>/dev/null || echo '-')"
    printf 'memory.swap.max %s\n' "$(cat "$swap_file" 2>/dev/null || echo '-')"
    printf 'memory.current %s\n' "$(cat "$parent_dir/memory.current" 2>/dev/null || echo '-')"
  else
    printf 'memory.high   (parent does not exist yet)\n'
  fi
}

if ((check)); then
  report
  if [[ -r "$high_file" ]]; then
    high_now="$(cat "$high_file" 2>/dev/null)"
    if [[ "$high_now" != "max" ]]; then
      max_now="$(cat "$max_file" 2>/dev/null || printf 'max')"
      if [[ "$max_now" == "max" ]]; then
        printf '\nIn the livelock band: memory.high (%s) is set but memory.max is unbounded, so nothing anywhere ever kills what memory.high fails to reclaim in time (agent-ops#1305). Re-run without --check.\n' \
          "$high_now" >&2
        exit 2
      fi
      exit 0
    fi
  fi
  printf '\nNot in force. Re-run without --check to set it.\n' >&2
  exit 2
fi

[[ "$(id -u)" == "0" ]] || die "must run as root (try: sudo bash $0 ...)"

case "$driver" in
  systemd)
    # The unit file *is* the persistence. systemd re-applies MemoryHigh every
    # time the slice starts, which is every time a container is created under
    # it, so there is nothing to re-run after a roll or a reboot.
    #
    # `WantedBy=slices.target` and `enable --now` matter for a second reason,
    # and it is not tidiness. compose bind-mounts this slice's `memory.high`
    # into the scheduler, and Docker creates a *directory* at a bind source
    # that does not exist — inside /sys/fs/cgroup, that would mean creating a
    # bogus cgroup rather than reading the real one. An enabled slice holds
    # its cgroup directory open with MemoryHigh already applied even with no
    # container in it (verified on the poetic node 2026-09-08), and
    # `Before=docker.service` puts it there before the daemon starts, so the
    # source is present the first time a container is created after a reboot.
    cat > "$unit" <<UNIT
# Written by agent-ops scripts/cgroup-parent-setup.sh.
#
# The parent cgroup the agent-ops scheduler is created under, carrying the
# soft memory ceiling that the scheduler's own cgroup cannot keep across a
# container recreation. See deploy/docker/compose.yaml.
[Unit]
Description=agent-ops scheduler ($name)
Before=docker.service

[Slice]
MemoryHigh=$limit_bytes
MemoryMax=$(systemd_ceiling "$max_val")
MemorySwapMax=$(systemd_ceiling "$swap_val")

[Install]
WantedBy=slices.target
UNIT
    systemctl daemon-reload || die "systemctl daemon-reload failed"
    systemctl enable --now "$name.slice" >/dev/null 2>&1 \
      || die "could not enable $name.slice"
    # Re-derive: creating the unit may have made the slice resolvable.
    live="$(systemctl show -p ControlGroup --value "$name.slice" 2>/dev/null)"
    if [[ -n "$live" ]]; then
      parent_dir="/sys/fs/cgroup$live"
      high_file="$parent_dir/memory.high"
      max_file="$parent_dir/memory.max"
      swap_file="$parent_dir/memory.swap.max"
    fi
    printf 'wrote %s (MemoryHigh=%s, MemoryMax=%s, MemorySwapMax=%s)\n' \
      "$unit" "$limit_bytes" "$max_val" "$swap_val"
    ;;
  cgroupfs)
    mkdir -p "$parent_dir" || die "cannot create $parent_dir"
    printf '%s\n' "$max_val" > "$max_file" || die "cannot write $max_file"
    printf 'set %s = %s\n' "$max_file" "$max_val"
    printf '%s\n' "$swap_val" > "$swap_file" || die "cannot write $swap_file"
    printf 'set %s = %s\n' "$swap_file" "$swap_val"
    printf '%s\n' "$limit_bytes" > "$high_file" \
      || die "cannot write $high_file"
    printf 'set %s = %s\n' "$high_file" "$limit_bytes"
    # A cgroupfs parent is a directory in a virtual filesystem: it survives
    # container recreation (verified 2026-09-08) but not a reboot, which
    # repopulates /sys/fs/cgroup empty. Docker will recreate the directory
    # when the container starts — with no ceiling on it — so something has to
    # put the numbers back, memory.max and memory.swap.max included: a
    # reboot-restored memory.high with no restored hard ceiling is the
    # livelock band all over again (agent-ops#1305).
    if ((boot_hook)); then
      hook="mkdir -p $parent_dir && echo $max_val > $max_file && echo $swap_val > $swap_file && echo $limit_bytes > $high_file"
      if [[ "$(ps -p 1 -o comm=)" == "systemd" ]]; then
        cat > "/etc/systemd/system/agent-ops-cgroup-parent-$name.service" <<UNIT
# Written by agent-ops scripts/cgroup-parent-setup.sh.
[Unit]
Description=agent-ops scheduler cgroup parent ($name)
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '$hook'

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload && systemctl enable "agent-ops-cgroup-parent-$name.service" >/dev/null \
          && printf 'installed reboot hook: agent-ops-cgroup-parent-%s.service\n' "$name"
      else
        # systemd is installed on the ockham node but is not PID 1, so a unit
        # would never run. root's crontab is what does run there.
        line="@reboot $hook"
        if crontab -l 2>/dev/null | grep -Fqx "$line"; then
          printf 'reboot hook already in root crontab\n'
        else
          { crontab -l 2>/dev/null; printf '%s\n' "$line"; } | crontab - \
            && printf 'installed reboot hook in root crontab\n'
        fi
      fi
    fi
    ;;
esac

printf '\nAdd to this .env, then re-create the container with "docker compose up -d":\n\n'
printf '  AGENT_OPS_SCHEDULER_CGROUP_PARENT=%s\n' "$name${unit:+.slice}"
printf '  AGENT_OPS_SCHEDULER_CGROUP_HIGH=%s\n' "$high_file"
printf '  AGENT_OPS_SCHEDULER_CGROUP_MAX=%s\n' "$max_file"
printf '  AGENT_OPS_SCHEDULER_CGROUP_EVENTS=%s\n' "$parent_dir/memory.events"
printf '\nThen confirm from inside the container:\n\n'
printf '  docker compose exec scheduler /app/scripts/doctor.sh --offline | grep "container memory"\n'
