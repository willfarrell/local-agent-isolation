# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

# Never $BUILDPLATFORM: the payload is a per-arch, per-libc optionalDependency.
FROM node:26-alpine@sha256:ae8e1c19d56886270987e99b3cfcef13a919f0655b376ae322bc64ada76f88cd AS build
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
WORKDIR /opt/copilot
COPY package.json package-lock.json ./
# @github/copilot ships no lifecycle scripts, so skipping them leaves nothing as a stub.
RUN npm ci --omit=dev --ignore-scripts

# The SEA can't load its napi addon on musl (upstream bug in 1.0.88) but unpacks its JS first; `test` is the real gate.
RUN version=$(node -p 'require("./node_modules/@github/copilot/package.json").version'); \
    HOME=/tmp /opt/copilot/node_modules/.bin/copilot --version >/dev/null 2>&1 || true; \
    mv /tmp/.cache/copilot/pkg/*/"${version}" /opt/copilot-app; \
    test -f /opt/copilot-app/index.js

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER 0:0

COPY --from=build --chown=root:root /opt/copilot-app /opt/copilot

# Replaces the published `copilot` bin, which is the broken SEA.
COPY --chmod=0755 <<'EOF' /usr/local/bin/copilot
#!/bin/sh
exec node /opt/copilot/index.js "$@"
EOF

COPY <<'EOF' /etc/agents/links.d/harness-copilot
/.agents/INSTRUCTIONS.md=.copilot/copilot-instructions.md
/.agents/settings.copilot.json=.copilot/mcp-config.json
EOF

# With no system keychain the login token is stored in config.json. Kept whole: its login fields are unverified
# (the SEA's JS is packed), so it also carries settings such as trusted folders from run to run.
COPY <<'EOF' /etc/agents/logins.d/harness-copilot
.copilot/config.json
EOF

COPY <<'EOF' /etc/agents/keep.d/harness-copilot
.copilot/session-state/
EOF

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "copilot"]
