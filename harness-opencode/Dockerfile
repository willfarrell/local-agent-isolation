# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG NODE_IMAGE=node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
ARG OPENCODE_VERSION=1.18.32
ARG NPM_BEFORE=2026-09-22T21:00:00Z

FROM ${NODE_IMAGE} AS build
ARG OPENCODE_VERSION
ARG NPM_BEFORE
# pipefail: a failing od in `od | tr` is otherwise masked by tr's exit status.
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
# opencode.exe is a stub until postinstall hardlinks the musl binary over it; assert ELF before pruning.
RUN bin=/opt/opencode/lib/node_modules/opencode-ai/bin/opencode.exe \
 && npm install -g --allow-scripts=opencode-ai --before="${NPM_BEFORE}" --prefix /opt/opencode "opencode-ai@${OPENCODE_VERSION}" \
 && { [ "$(od -An -tx1 -N4 "$bin" | tr -d ' ')" = "7f454c46" ] \
      || { echo "FATAL: $bin is not ELF; postinstall did not place the native binary" >&2; exit 1; }; } \
 && find /opt/opencode/lib/node_modules/opencode-ai/node_modules -maxdepth 1 \
      -name 'opencode-*' -exec rm -rf {} +

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER root

COPY --from=build --chown=root:root /opt/opencode /opt/opencode

RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

# home-init wipes ~/.config/opencode (auto-loaded plugins) and relinks it; login in ~/.local/share survives.
ENV PATH=/opt/opencode/bin:$PATH \
    AGENTS_LINKS="${AGENTS_LINKS} /.agents/INSTRUCTIONS.md=.config/opencode/AGENTS.md /.agents/settings.opencode.json=.config/opencode/opencode.json /.agents/agents=.config/opencode/agents /.agents/commands=.config/opencode/commands"

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "opencode"]
