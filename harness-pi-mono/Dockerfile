# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG NODE_IMAGE=node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
ARG PI_VERSION=0.73.1
ARG NPM_BEFORE=2026-09-22T21:00:00Z

# Never $BUILDPLATFORM: @mariozechner/clipboard is a per-arch, per-libc optionalDependency.
FROM ${NODE_IMAGE} AS build
ARG PI_VERSION
ARG NPM_BEFORE
# Keep only this platform's koffi prebuild (~25MB of 18); the test fails if koffi renames its dirs.
RUN npm install -g --ignore-scripts --before="${NPM_BEFORE}" --prefix /opt/pi @mariozechner/pi-coding-agent@${PI_VERSION} \
 && koffi=/opt/pi/lib/node_modules/@mariozechner/pi-coding-agent/node_modules/koffi/build/koffi \
 && keep="musl_$(node -p process.arch)" \
 && test -d "$koffi/$keep" \
 && find "$koffi" -mindepth 1 -maxdepth 1 ! -name "$keep" -exec rm -rf {} +

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER root

COPY --from=build --chown=root:root /opt/pi /opt/pi

RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

ENV PATH=/opt/pi/bin:$PATH \
    AGENTS_LINKS="${AGENTS_LINKS} /.agents/INSTRUCTIONS.md=.pi/agent/AGENTS.md /.agents/settings.pi.json=.pi/agent/settings.json"

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "/opt/pi/bin/pi"]
