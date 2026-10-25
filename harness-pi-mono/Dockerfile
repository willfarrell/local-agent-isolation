# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

FROM node:26-alpine@sha256:ae8e1c19d56886270987e99b3cfcef13a919f0655b376ae322bc64ada76f88cd AS build
WORKDIR /opt/pi
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER 0:0

COPY --from=build --chown=root:root /opt/pi /opt/pi

# pi runs any value in auth.json that starts with "!" as a shell command. agents-logins-save strips that; this
# also covers an orchestrator's kept home. Fails closed: not a file, or anything jq cannot clear, refuses.
COPY --chmod=0755 <<'EOF' /usr/local/bin/pi
#!/bin/sh
auth=$HOME/.pi/agent/auth.json
if { [ -e "$auth" ] || [ -L "$auth" ]; } && ! { [ -f "$auth" ] && [ ! -L "$auth" ] \
    && jq -e 'all(..; type != "string" or (startswith("!") | not))' "$auth" >/dev/null 2>&1; }; then
  echo "pi: $auth is not a plain file or holds a shell command (a value starting with !); delete it and log in again" >&2
  exit 1
fi
exec /opt/pi/node_modules/.bin/pi "$@"
EOF

COPY <<'EOF' /etc/agents/links.d/harness-pi-mono
/.agents/INSTRUCTIONS.md=.pi/agent/AGENTS.md
/.agents/settings.pi.json=.pi/agent/settings.json
EOF

# Not models.json: an apiKey there can be a shell command pi runs.
COPY <<'EOF' /etc/agents/logins.d/harness-pi-mono
.pi/agent/auth.json
EOF

# sessions/ holds the launchers' mounts (kept, emptied).
COPY <<'EOF' /etc/agents/keep.d/harness-pi-mono
.pi/agent/sessions/
EOF

# Install and update telemetry, on by default.
ENV PI_TELEMETRY=0

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "pi"]
