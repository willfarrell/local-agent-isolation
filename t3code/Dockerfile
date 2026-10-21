# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

ARG T3CODE_VERSION=v0.1.0
ARG T3CODE_COMMIT=81493efb71e8e8244f95d3e9f71d8369654ab151
ARG COREPACK_VERSION=0.36.0
# Bump with the version: npm view corepack@VERSION dist.integrity
ARG COREPACK_INTEGRITY=sha512-SiiJsBhZqdBiPHTEl6OT3sASrRrKIcYTQMsVGXx6EE/gM8WFMwYjeIX8Tt8RiU4Iv2J6LbT8KpGfCOsBpRWB/w==
# Upstream's packageManager pins no hash. Bump with the t3code tag: dist.integrity of pnpm@VERSION, as hex.
ARG PNPM_VERSION=11.10.0
ARG PNPM_SHA512=0b7f8b98060031904c017e3a41eb187a16d40eeb829b95c4f8cb03681761fc4ab53dd219115b9b447f4dce1a05a214764461e7d3703392a9f32f9511ce8c86c8

# Built from source: the published `t3` is a glibc Node SEA. Never $BUILDPLATFORM: node-pty compiles here (no linux prebuilds).
FROM node:26-alpine@sha256:6f08a523443ddedf52941874c203475b0ad503e859ad70cb26ab8be9a517dbd5 AS build
ARG T3CODE_VERSION
ARG T3CODE_COMMIT
ARG COREPACK_VERSION
ARG COREPACK_INTEGRITY
ARG PNPM_VERSION
ARG PNPM_SHA512
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
# Corepack fetches the pnpm that packageManager pins. The filter keeps the desktop and mobile apps out;
# @t3tools/scripts is in because the server build imports the root scripts/ (typescript-legacy).
# The root `prepare` is dev-only tooling (effect-tsgo patch rejects musl); dropping it keeps dependency install scripts.
ENV CI=true \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
# Node 25+ no longer bundles corepack, so it is fetched and checked against its pinned integrity. Corepack checks
# pnpm against a hash in packageManager only when there is one, so the pinned one is added.
RUN npm pkg delete scripts.prepare \
 && { [ "$(npm pkg get packageManager)" = "\"pnpm@${PNPM_VERSION}\"" ] \
      || { echo "FATAL: upstream packageManager is not pnpm@${PNPM_VERSION}; bump PNPM_VERSION and PNPM_SHA512" >&2; exit 1; }; } \
 && npm pkg set "packageManager=pnpm@${PNPM_VERSION}+sha512.${PNPM_SHA512}" \
 && npm pack --silent --pack-destination /tmp "corepack@${COREPACK_VERSION}" >/dev/null \
 && test "$(node -e 'process.stdout.write("sha512-" + require("crypto").createHash("sha512").update(require("fs").readFileSync(process.argv[1])).digest("base64"))' "/tmp/corepack-${COREPACK_VERSION}.tgz")" = "${COREPACK_INTEGRITY}" \
 && npm install -g --ignore-scripts "/tmp/corepack-${COREPACK_VERSION}.tgz" \
 && corepack enable \
 && pnpm install --frozen-lockfile --filter . --filter 't3...' --filter '@t3tools/scripts...' \
 && pnpm exec vp run --filter t3 build \
 && pnpm --filter t3 deploy --prod --legacy /opt/t3code \
 && test -f /opt/t3code/dist/client/index.html

# Placeholder for docker-build.hcl's named context: herdr already ships every harness T3 Code drives.
FROM scratch AS herdr

FROM herdr AS runtime
USER 0:0

COPY --from=build --chown=root:root /opt/t3code /opt/t3code

COPY --chmod=0755 <<'EOF' /usr/local/bin/t3
#!/bin/sh
exec node /opt/t3code/dist/bin.mjs "$@"
EOF

# ~/.t3/userdata is the server state (pairings, threads); not ~/.t3/tools, which holds binaries it downloads and runs.
# The claude and codex sessions its threads resume are not mounted here; kept whole, as the home volume is per workspace.
COPY <<'EOF' /etc/agents/keep.d/t3code
.t3/userdata
.claude/projects
.codex/sessions
EOF

# Binds every interface inside the container; compose publishes it on loopback only. Pairing is always required.
ENV T3CODE_HOST=0.0.0.0 \
    T3CODE_PORT=3773 \
    T3CODE_TELEMETRY_ENABLED=false

EXPOSE 3773
# --spider writes nothing, which a read-only rootfs requires.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/bin/wget", "-q", "--spider", "http://127.0.0.1:3773/.well-known/t3/environment"]

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "t3", "serve"]
