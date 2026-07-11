# Generic runtime image for generated ("machine-authored") agent bodies.
#
# Bakes the interpreter + venv dependencies ONLY. The specific agent body is bind-mounted
# read-only at /app/agents/<name> at run time (see run_worker.ex dispatch_spec/3), so no
# agent code is baked in and one image serves every generated agent (Constitution IX,
# FR-002/FR-003). The config/discovery agent keeps its own code-baked image.
FROM python:3.11-slim

# Recommended Python runtime env. PYTHONPATH=/app lets a mounted body resolve project-
# relative imports; a body run as `python /app/agents/<name>/main.py` also gets its own
# directory on sys.path[0], so bare `from models import ...` resolves.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app

# Non-root user 'app' (uid/gid 1000) — matches the sandbox's non-root posture (FR-001).
RUN groupadd -g 1000 app && \
    useradd -u 1000 -g app -s /bin/bash -m app

WORKDIR /app

# uv for fast, frozen dependency installs (same toolchain as the config-agent image).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Bake ONLY the dependency layer from the project lockfile — NO agent code (FR-002/FR-003).
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

RUN chown -R app:app /app
USER app

# Intentionally NO ENTRYPOINT: run_worker overrides it to
# `/app/.venv/bin/python /app/agents/<name>/main.py` against the read-only mounted body.
