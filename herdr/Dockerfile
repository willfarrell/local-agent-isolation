# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG ALPINE_IMAGE=alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
ARG HERDR_VERSION=0.9.1

# Fetches and checksums only, so run it native on the builder; TARGETARCH still picks the asset.
FROM --platform=$BUILDPLATFORM ${ALPINE_IMAGE} AS build
ARG HERDR_VERSION
ARG TARGETARCH
# -e is what enforces the checksum gate below; pipefail only covers a command appended after the pipe.
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
RUN apk add --no-cache \
      ca-certificates=20260909-r0 \
      wget=1.25.0-r3
# Upstream publishes no checksums file, so these were computed once per arch.
RUN case "$TARGETARCH" in \
      amd64) arch=x86_64;  sha=2a02fed16beb651ef006e1d43f048f652ca4dc58ad053cd2d44450563d5c54b7 ;; \
      arm64) arch=aarch64; sha=f4ccf4de745f2cb9a39a983e9ba3703dad50ec2a58dea83026ceab721bbd8d9e ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -qO /herdr "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${arch}"; \
    echo "${sha}  /herdr" | sha256sum -c -; \
    chmod 0755 /herdr

# Placeholders for docker-build.hcl's named contexts; a bare `docker build` fails at the COPY below, by design.
FROM scratch AS harness-claude-code
FROM scratch AS harness-codex
FROM scratch AS harness-copilot
FROM scratch AS harness-gemini
FROM scratch AS harness-hermes
FROM scratch AS harness-opencode
FROM scratch AS harness-pi-mono
FROM scratch AS tools

FROM tools AS runtime
USER root

# ncurses is terminfo for the TUI; openssh-client is a virtual provider, so pin the real package.
RUN apk add --no-cache \
      ncurses=6.6_p20260516-r0 \
      openssh-client-default=10.3_p1-r1

COPY --from=build /herdr /usr/local/bin/herdr
COPY --from=harness-claude-code --chown=root:root /opt/claude-code /opt/claude-code
COPY --from=harness-claude-code --chown=root:root /usr/local/lib/seed-mcp.mjs /usr/local/lib/seed-mcp.mjs
COPY --from=harness-claude-code --chown=root:root /usr/local/bin/claude /usr/local/bin/claude
COPY --from=harness-codex       --chown=root:root /opt/codex       /opt/codex
COPY --from=harness-copilot     --chown=root:root /opt/copilot     /opt/copilot
COPY --from=harness-copilot     --chown=root:root /usr/local/bin/copilot /usr/local/bin/copilot
COPY --from=harness-gemini      --chown=root:root /opt/gemini      /opt/gemini
COPY --from=harness-hermes      --chown=root:root /opt/hermes      /opt/hermes
COPY --from=harness-hermes      --chown=root:root /usr/local/bin/hermes /usr/local/bin/hermes-acp /usr/local/bin/
COPY --from=harness-opencode    --chown=root:root /opt/opencode    /opt/opencode
COPY --from=harness-pi-mono     --chown=root:root /opt/pi          /opt/pi

# Last, so it also covers anything setuid inside the seven copied harness trees.
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

# Union of every harness image's ENV plus herdr's config; /usr/local/bin first so claude's wrapper wins.
ENV PATH=/usr/local/bin:/opt/claude-code/bin:/opt/codex/bin:/opt/gemini/bin:/opt/opencode/bin:/opt/pi/bin:$PATH \
    USE_BUILTIN_RIPGREP=0 \
    CLAUDE_CODE_SANDBOXED=1 \
    GEMINI_CLI_TRUST_WORKSPACE=true \
    PYTHONDONTWRITEBYTECODE=1 \
    AGENTS_LINKS="${AGENTS_LINKS} \
/.agents/INSTRUCTIONS.md=.claude/CLAUDE.md /.agents/agents=.claude/agents /.agents/skills=.claude/skills /.agents/commands=.claude/commands \
/.agents/INSTRUCTIONS.md=.codex/AGENTS.md /.agents/settings.codex.toml=.codex/config.toml \
/.agents/INSTRUCTIONS.md=.copilot/copilot-instructions.md /.agents/settings.copilot.json=.copilot/mcp-config.json \
/.agents/INSTRUCTIONS.md=.gemini/GEMINI.md /.agents/settings.gemini.json=.gemini/settings.json \
/.agents/INSTRUCTIONS.md=.config/opencode/AGENTS.md /.agents/settings.opencode.json=.config/opencode/opencode.json /.agents/agents=.config/opencode/agents /.agents/commands=.config/opencode/commands \
/.agents/INSTRUCTIONS.md=.pi/agent/AGENTS.md /.agents/settings.pi.json=.pi/agent/settings.json \
/.agents/settings.hermes.yaml=.hermes/config.yaml \
/.agents/settings.herdr.toml=.config/herdr/config.toml"

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "herdr"]
