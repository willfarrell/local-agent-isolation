# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG NODE_IMAGE=node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
ARG PAPERCLIP_VERSION=2026.916.1
ARG NPM_BEFORE=2026-09-22T21:00:00Z

# Never $BUILDPLATFORM: sharp is per-arch/libc. @embedded-postgres is glibc-only, so the DB is compose's paperclip-db.
FROM ${NODE_IMAGE} AS build
ARG PAPERCLIP_VERSION
ARG NPM_BEFORE
RUN npm install -g --ignore-scripts --before="${NPM_BEFORE}" --prefix /opt/paperclip paperclipai@${PAPERCLIP_VERSION} \
 && find /opt/paperclip -type d -name '@embedded-postgres' -prune -exec rm -rf {} + \
 && test -f /opt/paperclip/lib/node_modules/paperclipai/node_modules/@paperclipai/server/dist/index.js

# Placeholder for docker-build.hcl's named context: herdr already ships every harness paperclip runs.
FROM scratch AS herdr

FROM herdr AS runtime
USER root

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
exec node /opt/paperclip/lib/node_modules/paperclipai/node_modules/@paperclipai/server/dist/index.js
EOF

RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

# No login by default; PAPERCLIP_DEPLOYMENT_MODE=authenticated turns it back on.
ENV PATH=/opt/paperclip/bin:$PATH \
    AGENTS_LINKS="${AGENTS_LINKS} /.agents/settings.paperclip.json=.paperclip/instances/default/config.json" \
    PAPERCLIP_DEPLOYMENT_MODE=local_trusted \
    PORT=3100 \
    PAPERCLIP_TELEMETRY_DISABLED=1

EXPOSE 3100
# --spider writes nothing, which a read-only rootfs requires.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/bin/wget", "-q", "--spider", "http://127.0.0.1:3100/api/health"]

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "paperclip-server"]
