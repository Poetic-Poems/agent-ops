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
# A ceiling on the container's *parent* governs the container just as well and
# outlives it, because the parent is not what gets recreated. That is the only
# property that distinguishes this from the one-shot recipe it replaces, and
# it is the whole point.
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
#   --limit SIZE   ceiling as bytes, or with a `k`/`m`/`g` suffix. Default 768m.
#   --check        report what is in force and change nothing.
#   --no-boot-hook skip installing the reboot persistence (cgroupfs hosts).
#
# Exit status: 0 on success or a clean `--check`, 1 on error, 2 on a `--check`
# that found the parent absent or unbounded.

set -uo pipefail

name=""
limit="768m"
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
  [[ "$n" =~ ^[0-9]+$ ]] || die "--limit is not a size: $v"
  case "$unit" in
    k|K) printf '%s' $(( n * 1024 )) ;;
    m|M) printf '%s' $(( n * 1024 * 1024 )) ;;
    g|G) printf '%s' $(( n * 1024 * 1024 * 1024 )) ;;
    '')  printf '%s' "$n" ;;
    *)   die "--limit has an unknown unit: $v" ;;
  esac
}
limit_bytes="$(to_bytes "$limit")"

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

report() {
  printf 'driver        %s (cgroup v%s)\n' "$driver" "$version"
  printf 'parent        %s\n' "$name${unit:+.slice}"
  printf 'cgroup path   %s\n' "$parent_dir"
  if [[ -r "$high_file" ]]; then
    printf 'memory.high   %s\n' "$(cat "$high_file")"
    printf 'memory.current %s\n' "$(cat "$parent_dir/memory.current" 2>/dev/null || echo '-')"
  else
    printf 'memory.high   (parent does not exist yet)\n'
  fi
}

if ((check)); then
  report
  if [[ -r "$high_file" ]] && [[ "$(cat "$high_file")" != "max" ]]; then
    exit 0
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

[Install]
WantedBy=slices.target
UNIT
    systemctl daemon-reload || die "systemctl daemon-reload failed"
    systemctl enable --now "$name.slice" >/dev/null 2>&1 \
      || die "could not enable $name.slice"
    # Re-derive: creating the unit may have made the slice resolvable.
    live="$(systemctl show -p ControlGroup --value "$name.slice" 2>/dev/null)"
    [[ -n "$live" ]] && { parent_dir="/sys/fs/cgroup$live"; high_file="$parent_dir/memory.high"; }
    printf 'wrote %s (MemoryHigh=%s)\n' "$unit" "$limit_bytes"
    ;;
  cgroupfs)
    mkdir -p "$parent_dir" || die "cannot create $parent_dir"
    printf '%s\n' "$limit_bytes" > "$high_file" \
      || die "cannot write $high_file"
    printf 'set %s = %s\n' "$high_file" "$limit_bytes"
    # A cgroupfs parent is a directory in a virtual filesystem: it survives
    # container recreation (verified 2026-09-08) but not a reboot, which
    # repopulates /sys/fs/cgroup empty. Docker will recreate the directory
    # when the container starts — with no ceiling on it — so something has to
    # put the number back.
    if ((boot_hook)); then
      hook="mkdir -p $parent_dir && echo $limit_bytes > $high_file"
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
printf '\nThen confirm from inside the container:\n\n'
printf '  docker compose exec scheduler /app/scripts/doctor.sh --offline | grep "container memory"\n'
