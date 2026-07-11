# Substrate image (feature 045): runs the BEAM control plane INSIDE the OrbStack Linux VM so a
# sandboxed agent container shares the same kernel as the inference broker's Unix socket. On
# macOS a host-bind UDS is refused across the VM boundary (kernel-local socket); running the
# substrate here, with the socket on a shared named volume, is the empirically-proven fix.
#
# This image is for real in-VM runs and the docker-tagged test suite ONLY. The default host
# workflow (`mix test`) does not use it. The repo is bind-mounted at the identical absolute
# host path at run time (see docker-compose.yml) so generated-agent code mounts resolve for
# sibling containers; source is NOT copied in here.
FROM elixir:1.20-otp-29

# curl (fetch the static docker CLI) + a C toolchain (the exqlite NIF compiles during
# `mix deps.get`). No daemon is installed — the substrate talks to the VM's daemon over the
# mounted /var/run/docker.sock.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

# Static Docker CLI ONLY (client, no daemon) to dispatch SIBLING agent containers via the
# mounted VM daemon socket. Arch-aware so it builds on both arm64 (Apple Silicon) and amd64.
ARG DOCKER_CLI_VERSION=27.5.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) dl_arch=x86_64 ;; \
      arm64) dl_arch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${dl_arch}/docker-${DOCKER_CLI_VERSION}.tgz" -o /tmp/docker.tgz; \
    tar -xzf /tmp/docker.tgz -C /usr/local/bin --strip-components=1 docker/docker; \
    rm /tmp/docker.tgz; \
    docker --version

RUN mix local.hex --force && mix local.rebar --force

# A LINUX Python venv with the project's agent-workload deps, so PortRunner/host-process agent
# bodies (discovery, elicitor, generated) run in-container. The bind-mounted repo's .venv is a
# macOS binary and cannot exec here; docker-compose.yml points PYTHON_BIN at /opt/aos/venv.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
COPY pyproject.toml uv.lock /opt/aos/proj/
RUN cd /opt/aos/proj \
    && UV_PROJECT_ENVIRONMENT=/opt/aos/venv uv sync --frozen --no-dev

# Bake the Elixir deps (fetch + compile, dev and test envs) into the image so `docker compose up`
# does not recompile the dependency tree in every fresh container — that recompile floods startup
# logs with third-party warnings (phoenix/live_view type warnings, yamerl catch-deprecations) and
# buries the substrate's real log lines. The paths match the MIX_DEPS_PATH/MIX_BUILD_PATH the
# compose services set, and are absolute, so the artifacts are valid from the bind-mounted repo
# root at run time; startup then only compiles the project's own (warning-clean) code.
ENV MIX_DEPS_PATH=/opt/aos/deps \
    MIX_BUILD_PATH=/opt/aos/_build
COPY mix.exs mix.lock /opt/aos/mix/
COPY config /opt/aos/mix/config
RUN cd /opt/aos/mix \
    && mix deps.get \
    && MIX_ENV=dev mix deps.compile \
    && MIX_ENV=test mix deps.compile

# The BEAM runs as root here on purpose: it must chgrp/chmod the shared-volume socket dir to the
# inference GID (the earlier macOS-host :eperm was an unprivileged-host limitation) and reach the
# mounted docker socket. Agents remain non-root (uid 1000) in their own sibling containers.

# Working dir is the identical absolute host path so Path.expand-derived sibling code mounts stay
# valid (docker-compose.yml bind-mounts the repo here).
WORKDIR /Users/will/projects/agent_os

# No ENTRYPOINT/CMD: docker-compose.yml supplies the command (deps.get + mix test, or a run).
