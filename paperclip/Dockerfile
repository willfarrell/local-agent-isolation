# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

# Never $BUILDPLATFORM: sharp is per-arch/libc. @embedded-postgres is glibc-only, so the DB is compose's paperclip-db.
FROM node:26-alpine@sha256:6f08a523443ddedf52941874c203475b0ad503e859ad70cb26ab8be9a517dbd5 AS build
WORKDIR /opt/paperclip
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts \
 && find /opt/paperclip -type d -name '@embedded-postgres' -prune -exec rm -rf {} + \
 && test -f /opt/paperclip/node_modules/@paperclipai/server/dist/index.js

# Placeholder for docker-build.hcl's named context: herdr already ships every harness paperclip runs.
FROM scratch AS herdr

FROM herdr AS runtime
USER 0:0

COPY --from=build --chown=root:root /opt/paperclip /opt/paperclip

# Runs the server directly (`paperclipai run` assumes a desktop) and generates the auth secret it requires.
COPY --chmod=0755 <<'EOF' /usr/local/bin/paperclip-server
#!/bin/sh
set -eu
secret=$HOME/.paperclip/auth-secret
if [ ! -s "$secret" ]; then
  mkdir -p "${secret%/*}"
  (umask 077 && head -c 32 /dev/urandom | base64 > "$secret")
fi
BETTER_AUTH_SECRET=$(cat "$secret")
export BETTER_AUTH_SECRET
if [ "$PAPERCLIP_DEPLOYMENT_MODE" = local_trusted ]; then
  # local_trusted binds loopback only; forward the published port to it.
  # Explicit: settings.paperclip.json's server.bind would otherwise win.
  export PORT=3101 PAPERCLIP_BIND=loopback
  node -e 'const net = require("net")
net.createServer(c => {
  const u = net.connect(3101, "127.0.0.1")
  c.pipe(u).pipe(c)
  c.on("error", () => u.destroy())
  u.on("error", () => c.destroy())
}).listen(3100, "0.0.0.0")' &
else
  export PAPERCLIP_BIND=lan
fi
exec node /opt/paperclip/node_modules/@paperclipai/server/dist/index.js
EOF

COPY <<'EOF' /etc/agents/links.d/paperclip
/.agents/settings.paperclip.json=.paperclip/instances/default/config.json
EOF

# ~/.paperclip is the instance (auth secret, storage, skills, agent homes and logins); nothing mounts claude sessions
# here. .claude/projects stays whole, memory included: compose gives each workspace a home volume of its own, so
# what one repo's agents write there no other repo's load. The harnesses' logins.d are kept too (home-init).
COPY <<'EOF' /etc/agents/keep.d/paperclip
.paperclip
.claude/projects
EOF

# Not node_modules/.bin on PATH: it also holds the bundled codex, which would shadow herdr's.
RUN ln -s /opt/paperclip/node_modules/.bin/paperclipai /usr/local/bin/paperclipai

# local_trusted (no login) is admin for every container that reaches the port, host.docker.internal included.
ENV PAPERCLIP_DEPLOYMENT_MODE=authenticated \
    PORT=3100 \
    PAPERCLIP_TELEMETRY_DISABLED=1

EXPOSE 3100
# --spider writes nothing, which a read-only rootfs requires.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/bin/wget", "-q", "--spider", "http://127.0.0.1:3100/api/health"]

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "paperclip-server"]
