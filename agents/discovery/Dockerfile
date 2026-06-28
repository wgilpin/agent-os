# Use Python 3.11 slim image for a small container footprint
FROM python:3.11-slim

# Set recommended Python environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app

# Create a non-root user 'app' and group 'app' for security (FR-008)
RUN groupadd -g 1000 app && \
    useradd -u 1000 -g app -s /bin/bash -m app

WORKDIR /app

# Copy uv binary from the official image to manage dependencies cleanly without pip overhead
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Copy python project definition files to cache dependency layer
COPY pyproject.toml uv.lock ./

# Install dependencies into virtual environment (excluding dev dependencies)
RUN uv sync --frozen --no-dev

# Copy python agent code
COPY agents/ /app/agents/

# Ensure all files are owned by the non-root app user
RUN chown -R app:app /app

# Switch to the non-root user
USER app

# Set entrypoint to execute the discovery agent via the virtual environment's python runner
ENTRYPOINT ["/app/.venv/bin/python", "agents/discovery/main.py"]
