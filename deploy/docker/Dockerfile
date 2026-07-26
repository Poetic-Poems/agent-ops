# syntax=docker/dockerfile:1
#
# The agent-ops node image: the whole pipeline toolchain, plus this repository
# at /app. One image serves every role a node plays — the scheduler runs
# supercronic against deploy/docker/crontab, the dashboard runs
# scripts/serve-dashboard.sh — because they are the same code reading the same
# state, and two images would be two things to keep in step.
#
# Build (from the repository root):
#   docker build -f deploy/docker/Dockerfile -t agent-ops .
#
# The image is built from the repository at CI time, so /app *is* the deployed
# version of agent-ops: a node updates by pulling a new image, never by pulling
# a git branch. Nothing here is host-specific and nothing is secret — tokens
# and Claude credentials arrive at run time (see entrypoint.sh).

FROM ubuntu:24.04

# The node major deliberately matches the laptop's, so a cycle that works
# there works here. Supercronic is pinned to a release and verified against
# its SHA-1: it is the one binary not coming from a signed apt repository.
ARG NODE_MAJOR=26
ARG SUPERCRONIC_VERSION=v0.2.47
ARG SUPERCRONIC_SHA1SUM=712d2ece75da6f6e530192a151488578153e4e96
# `latest` at build time rather than a pin: CI rebuilds on every merge, the
# CLI moves fast, and a stale claude is a broken pipeline sooner than a
# surprising one. Pin it here if a release ever breaks a cycle.
ARG CLAUDE_CODE_VERSION=latest
# The container user's ids. They matter because the state, workspace and
# Claude-config volumes outlive the container: mounting a host directory owned
# by a different uid is the classic way to make a persistent volume read-only
# by accident.
ARG PUID=1000
ARG PGID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Etc/UTC

# The pipelines' hard requirements (bash, git, jq, curl, python3, perl,
# coreutils, and rsync for scripts/state-sync.sh) plus the small comforts an
# operator needs when they exec into a node to work out what went wrong.
# util-linux is already in the base image and carries `flock`, which the
# dashboard heartbeat relies on.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        coreutils \
        curl \
        git \
        gnupg \
        jq \
        less \
        perl \
        python3 \
        rsync \
        tzdata \
        vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# gh from GitHub's own apt repository: the distro package is years behind, and
# the pipelines use flags it does not have.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && printf 'deb [arch=%s signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
        "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Node.js from NodeSource, for the `claude` CLI and for any target repo whose
# checks are npm-driven.
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' \
        "$NODE_MAJOR" > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# supercronic: a cron implementation that runs as pid 1 in a container without
# a system cron daemon, logs to stdout, and needs no root. The crontab it runs
# is deploy/docker/crontab.
RUN curl -fsSL -o /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
    && echo "${SUPERCRONIC_SHA1SUM}  /usr/local/bin/supercronic" | sha1sum -c - \
    && chmod +x /usr/local/bin/supercronic

# A non-root user with a real home, because config.json's paths are ~-relative
# and Claude's credentials live under it. ubuntu:24.04 ships a stock `ubuntu`
# user already holding uid/gid 1000, so it goes first.
#
# HOME is set only after this point, and the home directory is chowned
# unconditionally: the root-run steps above must not be tempted to write into
# it (an npm cache built as root leaves a directory `agent` cannot write, and
# ~/.claude then cannot be created at all — a failure that shows up only at
# run time, as a container that starts and can never authenticate).
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && groupadd -g "$PGID" agent \
    && useradd -m -u "$PUID" -g "$PGID" -s /bin/bash agent \
    && chown -R "$PUID:$PGID" /home/agent

ENV HOME=/home/agent

# Claude Code keeps two things: a config *directory* (`~/.claude` by default —
# credentials, settings, projects, sessions) and a global config *file*, which
# by default is `~/.claude.json`, a sibling of that directory rather than a
# member of it. Only the directory is a volume, so the file lived in the
# container's writable layer and every watchtower roll destroyed it. Each new
# container then greeted every `claude` invocation with "Claude configuration
# file not found at: /home/agent/.claude.json" on stderr and rebuilt the file
# from nothing, over and over.
#
# `CLAUDE_CONFIG_DIR` moves the file inside the directory, which is already the
# `claude-config` volume, so it now survives a roll like everything else there.
# Pointing it at the default directory makes this a no-op for every other path:
# credentials, settings.json, projects/ and sessions/ resolve exactly where
# they already do. `.claude.json` is the only thing that moves, and it had no
# state worth migrating — it was being discarded on every roll anyway.
#
# Set in the image, not in each node's compose `environment:`, so watchtower
# delivers it with no `docker compose up -d` anywhere — a manual `up -d` kills
# a cycle in flight, which is a silly price for a stderr line.
#
# And set *here* rather than only defaulted in entrypoint.sh, because the two
# reach different processes. `docker compose exec scheduler claude` — the
# once-per-node interactive login — starts a process from the image's
# environment and never runs the entrypoint. With the default alone, that login
# would write its config to the ephemeral `~/.claude.json` while the cron
# cycles read the volume: an operator who authenticated successfully would
# watch the node fail to authenticate. The entrypoint keeps its default anyway,
# for any context that overrides the environment wholesale.
#
# One caveat, recorded because it is the kind of thing that rots quietly:
# `CLAUDE_CONFIG_DIR` is honoured by the CLI (verified against 2.1.215, and it
# appears in the binary's environment-variable tables) but is not in the public
# settings documentation. If a future CLI drops it, the symptom is the return
# of that same warning — harmless, and the CI check below fails first.
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude

# The mount points for the persistent volumes, created here and owned by
# `agent`. This is not tidiness: Docker seeds a new named volume from whatever
# is at its mount point in the image, ownership included, and creates the
# directory as root when there is nothing there. Without these lines the very
# first `docker compose up` gives the container three root-owned volumes it
# cannot write, and every service restart-loops on its first mkdir.
RUN mkdir -p /home/agent/.claude \
             /home/agent/.local/state/poetic-agents/cycles \
             /home/agent/.local/state/poetic-agents/reviews \
             /home/agent/.cache/poetic-agents/workspaces \
    && chown -R "$PUID:$PGID" /home/agent

COPY --chown=agent:agent . /app

USER agent
WORKDIR /app

# The version stamp. `.dockerignore` keeps `.git` out of the image — rightly,
# since the image is a deployment of this repository and not a copy of a
# working tree — which leaves the running code with no way to say which
# revision it is. That matters once several nodes update independently: a roll
# waits for the cycle it would otherwise kill (watchtower-pre-update.sh), so a
# fleet is routinely mid-update, and "which of these containers has the fix?"
# is a question the dashboard has to be able to answer.
#
# So CI passes what the image cannot work out for itself. The pull request
# number is the useful half: a SHA names the bytes, `#89` names the change, and
# the dashboard renders it as a link to the record. Empty by default, which is
# what a local `docker build` produces and what lib/version.sh treats as "no
# stamp" — it then falls back to git, so a developer's checkout still reports a
# version.
ARG AGENT_OPS_COMMIT=""
ARG AGENT_OPS_PR=""
ARG AGENT_OPS_BUILT_AT=""
ARG AGENT_OPS_REPO=""
RUN printf '{"commit":"%s","pr":"%s","built_at":"%s","repo":"%s"}\n' \
      "$AGENT_OPS_COMMIT" "$AGENT_OPS_PR" "$AGENT_OPS_BUILT_AT" "$AGENT_OPS_REPO" \
      > /app/build-info.json

# No CMD: each service in compose.yaml says what it is (supercronic, the
# dashboard server, a one-off cycle). A default here would only ever be the
# wrong one of those.
ENTRYPOINT ["/app/deploy/docker/entrypoint.sh"]
