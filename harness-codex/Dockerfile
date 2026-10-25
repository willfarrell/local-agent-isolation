# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

FROM node:26-alpine@sha256:ae8e1c19d56886270987e99b3cfcef13a919f0655b376ae322bc64ada76f88cd AS build
WORKDIR /opt/codex
COPY package.json package-lock.json ./
# @openai/codex ships no lifecycle scripts, so skipping them leaves nothing as a stub.
RUN npm ci --omit=dev --ignore-scripts

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER 0:0

COPY --from=build --chown=root:root /opt/codex /opt/codex
RUN ln -s /opt/codex/node_modules/.bin/codex /usr/local/bin/codex

COPY <<'EOF' /etc/agents/links.d/harness-codex
/.agents/INSTRUCTIONS.md=.codex/AGENTS.md
/.agents/settings.codex.toml=.codex/config.toml
EOF

COPY <<'EOF' /etc/agents/logins.d/harness-codex
.codex/auth.json
EOF

COPY <<'EOF' /etc/agents/keep.d/harness-codex
.codex/sessions/
EOF

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
# bwrap can't run unprivileged, so settings.codex.toml uses danger-full-access; the container is the sandbox.
ENTRYPOINT ["/sbin/tini", "--", "home-init", "codex"]
