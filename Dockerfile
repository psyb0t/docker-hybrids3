# Production image. Multi-stage:
#   builder: uv materializes a hash-verified venv from uv.lock
#   runtime: copies venv + app into a clean base, no uv / no build tools
#
# Base + uv pinned by digest. Bump deliberately, never silently.

# ── builder ──────────────────────────────────────────────────────────────────
# python:3.12-slim-bookworm
FROM python@sha256:93ab4b7fa528b25124c97bcc755415e60eb671a86b4dbe0328df2fe2d1c1193d AS builder

# uv 0.11.19
COPY --from=ghcr.io/astral-sh/uv@sha256:b46b03ddfcfbf8f547af7e9eaefdf8a39c8cebcba7c98858d3162bd28cf536f6 \
     /uv /uvx /usr/local/bin/

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /build

# Install ONLY locked runtime deps (no project source, no dev group).
# uv.lock carries sha256 hashes; --frozen refuses to re-resolve.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# ── runtime ──────────────────────────────────────────────────────────────────
# python:3.12-slim-bookworm
FROM python@sha256:93ab4b7fa528b25124c97bcc755415e60eb671a86b4dbe0328df2fe2d1c1193d AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends libmagic1 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 hybrids3 \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash hybrids3

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app
COPY app/ /app/

RUN mkdir -p /data /config \
    && chown -R hybrids3:hybrids3 /data /config /app /opt/venv

USER hybrids3

EXPOSE 8080

CMD ["python", "main.py"]
