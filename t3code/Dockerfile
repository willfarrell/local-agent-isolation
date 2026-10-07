# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG NODE_IMAGE=node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
ARG T3CODE_VERSION=v0.0.45
ARG T3CODE_COMMIT=6c8fed35dded9ff71c5b46807125457acbb76be6

# Built from source: the published `t3` is a glibc Node SEA. Never $BUILDPLATFORM: node-pty compiles here (no linux prebuilds).
FROM ${NODE_IMAGE} AS build
ARG T3CODE_VERSION
ARG T3CODE_COMMIT
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
RUN apk add --no-cache \
      g++=15.2.0-r5 \
      git=2.54.0-r0 \
      linux-headers=7.0.0-r1 \
      make=4.4.1-r4 \
      python3=3.14.8-r0
WORKDIR /src
# A tag can move, so the commit is checked as well.
RUN git clone --depth 1 --branch "${T3CODE_VERSION}" https://github.com/pingdotgg/t3code.git . \
 && test "$(git rev-parse HEAD)" = "${T3CODE_COMMIT}"
# Corepack fetches the pnpm that packageManager pins. The filter keeps the desktop and mobile apps out.
ENV CI=true \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable \
 && pnpm install --frozen-lockfile --filter . --filter 't3...' \
 && pnpm exec vp run --filter t3 build \
 && pnpm --filter t3 deploy --prod --legacy /opt/t3code \
 && test -f /opt/t3code/dist/client/index.html

# Placeholder for docker-build.hcl's named context: herdr already ships every harness T3 Code drives.
FROM scratch AS herdr

FROM herdr AS runtime
USER root

COPY --from=build --chown=root:root /opt/t3code /opt/t3code

COPY --chmod=0755 <<'EOF' /usr/local/bin/t3
#!/bin/sh
exec node /opt/t3code/dist/bin.mjs "$@"
EOF

RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

# Binds every interface inside the container; compose publishes it on loopback only. Pairing is always required.
ENV T3CODE_HOST=0.0.0.0 \
    T3CODE_PORT=3773 \
    T3CODE_TELEMETRY_ENABLED=false

EXPOSE 3773
# --spider writes nothing, which a read-only rootfs requires.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/bin/wget", "-q", "--spider", "http://127.0.0.1:3773/.well-known/t3/environment"]

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "t3", "serve"]
