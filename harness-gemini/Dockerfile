# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

FROM node:26-alpine@sha256:ae8e1c19d56886270987e99b3cfcef13a919f0655b376ae322bc64ada76f88cd AS build
WORKDIR /opt/gemini
COPY package.json package-lock.json ./
# @google/gemini-cli ships no lifecycle scripts, so skipping them leaves nothing as a stub.
RUN npm ci --omit=dev --ignore-scripts

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER 0:0

COPY --from=build --chown=root:root /opt/gemini /opt/gemini
RUN ln -s /opt/gemini/node_modules/.bin/gemini /usr/local/bin/gemini

COPY <<'EOF' /etc/agents/links.d/harness-gemini
/.agents/INSTRUCTIONS.md=.gemini/GEMINI.md
/.agents/settings.gemini.json=.gemini/settings.json
EOF

# Google login, the file-backed keychain used when no system one exists, and MCP server logins. Not projects.json:
# with it empty each run, Gemini's tmp/<slug> is the one the launchers compute and mount.
COPY <<'EOF' /etc/agents/logins.d/harness-gemini
.gemini/oauth_creds.json
.gemini/google_accounts.json
.gemini/gemini-credentials.json
.gemini/mcp-oauth-tokens.json
EOF

# The folder the launchers mount each session into (kept, emptied).
COPY <<'EOF' /etc/agents/keep.d/harness-gemini
.gemini/tmp/
EOF

# TRUST_WORKSPACE: an untrusted folder disables every MCP server; the container is the boundary.
ENV GEMINI_CLI_TRUST_WORKSPACE=true

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "gemini"]
