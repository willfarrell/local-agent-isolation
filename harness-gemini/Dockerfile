# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG NODE_IMAGE=node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
ARG GEMINI_VERSION=0.60.0
ARG NPM_BEFORE=2026-09-22T21:00:00Z

FROM ${NODE_IMAGE} AS build
ARG GEMINI_VERSION
ARG NPM_BEFORE
# @google/gemini-cli ships no lifecycle scripts, so skipping them leaves nothing as a stub.
RUN npm install -g --ignore-scripts --before="${NPM_BEFORE}" --prefix /opt/gemini @google/gemini-cli@${GEMINI_VERSION}

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER root

COPY --from=build /opt/gemini /opt/gemini

RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

# TRUST_WORKSPACE: an untrusted folder disables every MCP server; the container is the boundary.
ENV PATH=/opt/gemini/bin:$PATH \
    GEMINI_CLI_TRUST_WORKSPACE=true \
    AGENTS_LINKS="${AGENTS_LINKS} /.agents/INSTRUCTIONS.md=.gemini/GEMINI.md /.agents/settings.gemini.json=.gemini/settings.json"

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "gemini"]
