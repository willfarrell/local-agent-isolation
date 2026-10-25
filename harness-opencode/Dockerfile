# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

FROM node:26-alpine@sha256:ae8e1c19d56886270987e99b3cfcef13a919f0655b376ae322bc64ada76f88cd AS build
# pipefail: a failing od in `od | tr` is otherwise masked by tr's exit status.
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
WORKDIR /opt/opencode
COPY package.json package-lock.json ./
# opencode.exe is a stub until postinstall hardlinks the musl binary over it. No other lifecycle
# script runs: --ignore-scripts, then that one by path. Assert the ELF before pruning.
RUN npm ci --omit=dev --ignore-scripts
WORKDIR /opt/opencode/node_modules/opencode-ai
RUN node ./postinstall.mjs \
 && { [ "$(od -An -tx1 -N4 bin/opencode.exe | tr -d ' ')" = "7f454c46" ] \
      || { echo "FATAL: bin/opencode.exe is not ELF; postinstall did not place the native binary" >&2; exit 1; }; } \
 && find /opt/opencode/node_modules -mindepth 1 -maxdepth 1 \
      -name 'opencode-*' ! -name opencode-ai -exec rm -rf {} +
WORKDIR /opt/opencode

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER 0:0

COPY --from=build --chown=root:root /opt/opencode /opt/opencode
RUN ln -s /opt/opencode/node_modules/.bin/opencode /usr/local/bin/opencode

COPY <<'EOF' /etc/agents/links.d/harness-opencode
/.agents/INSTRUCTIONS.md=.config/opencode/AGENTS.md
/.agents/settings.opencode.json=.config/opencode/opencode.json
/.agents/agents=.config/opencode/agents
/.agents/commands=.config/opencode/commands
EOF

# The login. Not the session database in the home, used only where the launchers set no OPENCODE_DB: shared by
# every directory, it would carry one repo's sessions into another. Nor bin/, tools opencode downloads and runs.
COPY <<'EOF' /etc/agents/logins.d/harness-opencode
.local/share/opencode/auth.json
EOF

# That database (opencode.db, or opencode-<channel>.db, with -wal/-shm) stays only in an orchestrator's home,
# which is per workspace.
COPY <<'EOF' /etc/agents/keep.d/harness-opencode
.local/share/opencode/opencode*.db*
.local/share/opencode/storage
EOF

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "opencode"]
