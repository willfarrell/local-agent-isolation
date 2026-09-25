# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG ALPINE_IMAGE=alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
ARG NODE_IMAGE=node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
ARG CONTEXT_MODE_VERSION=1.0.169
ARG NPM_BEFORE=2026-09-22T21:00:00Z

# MCP servers every harness names in its settings.*; --ignore-scripts is safe because node:sqlite replaces better-sqlite3 (checked below).
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS mcp
ARG CONTEXT_MODE_VERSION
ARG NPM_BEFORE
RUN npm install -g --ignore-scripts --before="${NPM_BEFORE}" --prefix /opt/mcp context-mode@${CONTEXT_MODE_VERSION}

# safe.directory '*': repos are host-owned bind mounts at arbitrary host paths.
FROM ${ALPINE_IMAGE}

RUN apk add --no-cache \
      bash=5.3.9-r1 \
      ca-certificates=20260909-r0 \
      fd=10.2.0-r3 \
      git=2.54.0-r0 \
      jq=1.8.2-r0 \
      libgcc=15.2.0-r5 \
      libstdc++=15.2.0-r5 \
      nodejs=24.18.1-r0 \
      ripgrep=15.1.0-r0 \
      sqlite=3.53.4-r0 \
      tini=0.19.0-r3 \
 && addgroup -g 1000 agent \
 && adduser -D -u 1000 -G agent -h /home -s /bin/bash agent \
 && chown agent:agent /home \
 && mkdir -p /.agents \
 && git config --system --add safe.directory '*'

COPY --from=mcp --chown=root:root /opt/mcp /opt/mcp

# context-mode needs FTS5 in node:sqlite, else it falls back to a better-sqlite3 shipped without its binding.
RUN node -e "new (require('node:sqlite').DatabaseSync)(':memory:').exec('create virtual table t using fts5(x)')" \
 && { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

# Rebuilds the shared, agent-writable home volume each start: deletes AGENTS_SCRUB, relinks AGENTS_LINKS into read-only /.agents.
COPY --chmod=0755 <<'EOF' /usr/local/bin/home-init
#!/bin/sh
set -eu
for rel in ${AGENTS_SCRUB:-}; do
  rm -rf "${HOME:?}/$rel"
done
for pair in ${AGENTS_LINKS:-}; do
  src=${pair%%=*}
  dst=${HOME:?}/${pair#*=}
  mkdir -p "${dst%/*}"
  rm -rf "$dst"
  ln -s "$src" "$dst"
done
exec "$@"
EOF

ENV HOME=/home \
    SHELL=/bin/bash \
    PATH=/opt/mcp/bin:$PATH \
    AGENTS_SCRUB=".bashrc .bash_profile .bash_login .profile .gitconfig .config/git .env .claude/rules .codex/AGENTS.override.md .codex/rules .config/opencode .gemini/extensions .gemini/.env .pi/agent/extensions .hermes/plugins .hermes/hooks .hermes/scripts .hermes/profiles .hermes/.env" \
    AGENTS_LINKS="/.agents=.agents /.agents/settings.claude.json=.claude/settings.json"

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init"]
CMD ["bash"]
