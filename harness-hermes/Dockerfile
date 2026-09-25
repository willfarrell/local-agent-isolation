# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG HERMES_VERSION=v2026.9.21
ARG HERMES_COMMIT=d337b736aa1e8ebecfab043842d13e4a2d2f48a3
# Hermes needs Python < 3.14 and alpine ships 3.14, so uv supplies a checksummed musl 3.13.
ARG PYTHON_VERSION=3.13

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

# Never $BUILDPLATFORM: uv resolves arch/libc-specific Python and wheels; paths are absolute, so build in place.
FROM tools AS build
USER root
ARG HERMES_VERSION
ARG HERMES_COMMIT
ARG PYTHON_VERSION
RUN apk add --no-cache \
      uv=0.11.19-r0
ENV UV_PYTHON_INSTALL_DIR=/opt/hermes/python \
    UV_PROJECT_ENVIRONMENT=/opt/hermes/venv \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy
RUN git clone --quiet --depth 1 --branch "${HERMES_VERSION}" https://github.com/NousResearch/hermes-agent.git /opt/hermes/src \
 && test "$(git -C /opt/hermes/src rev-parse HEAD)" = "${HERMES_COMMIT}" \
 && rm -rf /opt/hermes/src/.git /opt/hermes/src/tests /opt/hermes/src/tests-js /opt/hermes/src/website
WORKDIR /opt/hermes/src
# --frozen installs upstream's hashed uv.lock; the self-test is upstream's SQLite >= 3.51.3 + FTS5 check.
RUN uv python install "${PYTHON_VERSION}" \
 && uv sync --frozen --no-dev --python "${PYTHON_VERSION}" --extra anthropic --extra mcp --extra acp \
 && /opt/hermes/venv/bin/python -m compileall -q /opt/hermes/src \
 && /opt/hermes/venv/bin/python -c "import sqlite3, sys; \
v = sqlite3.sqlite_version_info; \
sys.exit(f'SQLite {sqlite3.sqlite_version} has the WAL-reset bug') if v < (3, 51, 3) else None; \
db = sqlite3.connect(':memory:'); \
db.execute(\"CREATE VIRTUAL TABLE d USING fts5(c, tokenize='trigram')\"); \
db.execute(\"INSERT INTO d VALUES ('hermes')\"); \
sys.exit('SQLite FTS5 trigram self-test failed') if db.execute(\"SELECT count(*) FROM d WHERE d MATCH 'erm'\").fetchone()[0] != 1 else None"

FROM tools AS runtime
USER root

COPY --from=build --chown=root:root /opt/hermes /opt/hermes

# Link only the entry points: the venv's bin on PATH would put its python in front of everything the agent runs.
RUN ln -s /opt/hermes/venv/bin/hermes /usr/local/bin/hermes \
 && ln -s /opt/hermes/venv/bin/hermes-acp /usr/local/bin/hermes-acp \
 && { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

# ~/.hermes/skills is left alone: skills Hermes writes from experience are the point of it.
ENV PYTHONDONTWRITEBYTECODE=1 \
    AGENTS_LINKS="${AGENTS_LINKS} /.agents/settings.hermes.yaml=.hermes/config.yaml"

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "hermes"]
