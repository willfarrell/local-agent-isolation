# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG NODE_IMAGE=node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
ARG COPILOT_VERSION=1.0.88
ARG NPM_BEFORE=2026-09-22T21:00:00Z

# Never $BUILDPLATFORM: the payload is a per-arch, per-libc optionalDependency.
FROM ${NODE_IMAGE} AS build
ARG COPILOT_VERSION
ARG NPM_BEFORE
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
# @github/copilot ships no lifecycle scripts, so skipping them leaves nothing as a stub.
RUN npm install -g --ignore-scripts --before="${NPM_BEFORE}" --prefix /opt/copilot @github/copilot@${COPILOT_VERSION}

# The SEA can't load its napi addon on musl (upstream bug in 1.0.88) but unpacks its JS first; `test` is the real gate.
RUN HOME=/tmp /opt/copilot/bin/copilot --version >/dev/null 2>&1 || true; \
    mv /tmp/.cache/copilot/pkg/*/"${COPILOT_VERSION}" /opt/copilot-app; \
    test -f /opt/copilot-app/index.js

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER root

COPY --from=build /opt/copilot-app /opt/copilot

# Replaces the published `copilot` bin, which is the broken SEA.
COPY --chmod=0755 <<'EOF' /usr/local/bin/copilot
#!/bin/sh
exec node /opt/copilot/index.js "$@"
EOF

RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

ENV AGENTS_LINKS="${AGENTS_LINKS} /.agents/INSTRUCTIONS.md=.copilot/copilot-instructions.md /.agents/settings.copilot.json=.copilot/mcp-config.json"

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "copilot"]
