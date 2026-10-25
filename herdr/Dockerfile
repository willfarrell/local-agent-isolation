# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

ARG HERDR_VERSION=0.9.5

# Fetches and checksums only, so run it native on the builder; TARGETARCH still picks the asset.
FROM --platform=$BUILDPLATFORM alpine:3.24@sha256:c6b073f8e9e58d881f6ffba6ebf3b9ebd60b9e7d6e8337018c0e68bb5c356873 AS build
ARG HERDR_VERSION
ARG TARGETARCH
# -e is what enforces the checksum gate below; pipefail only covers a command appended after the pipe.
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
RUN apk add --no-cache \
      ca-certificates=20261020-r0 \
      wget=1.25.0-r3
# Upstream publishes no checksums file, so these were computed once per arch.
RUN case "$TARGETARCH" in \
      amd64) arch=x86_64;  sha=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d ;; \
      arm64) arch=aarch64; sha=17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c ;; \
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
USER 0:0

# ncurses is terminfo for the TUI; openssh-client is a virtual provider, so pin the real package.
RUN apk add --no-cache \
      ncurses=6.6_p20260516-r0 \
      openssh-client-default=10.3_p1-r1

COPY --from=build /herdr /usr/local/bin/herdr
# Each harness has its install in /opt/<name>, its CLI in /usr/local/bin and its home links, logins and keeps in /etc/agents.
COPY --from=harness-claude-code --chown=root:root /opt/claude-code /opt/claude-code
COPY --from=harness-claude-code --chown=root:root /usr/local/bin/ /usr/local/bin/
COPY --from=harness-claude-code --chown=root:root /etc/agents/ /etc/agents/
COPY --from=harness-codex       --chown=root:root /opt/codex /opt/codex
COPY --from=harness-codex       --chown=root:root /usr/local/bin/ /usr/local/bin/
COPY --from=harness-codex       --chown=root:root /etc/agents/ /etc/agents/
COPY --from=harness-copilot     --chown=root:root /opt/copilot /opt/copilot
COPY --from=harness-copilot     --chown=root:root /usr/local/bin/ /usr/local/bin/
COPY --from=harness-copilot     --chown=root:root /etc/agents/ /etc/agents/
COPY --from=harness-gemini      --chown=root:root /opt/gemini /opt/gemini
COPY --from=harness-gemini      --chown=root:root /usr/local/bin/ /usr/local/bin/
COPY --from=harness-gemini      --chown=root:root /etc/agents/ /etc/agents/
COPY --from=harness-hermes      --chown=root:root /opt/hermes /opt/hermes
COPY --from=harness-hermes      --chown=root:root /usr/local/bin/ /usr/local/bin/
COPY --from=harness-hermes      --chown=root:root /etc/agents/ /etc/agents/
COPY --from=harness-opencode    --chown=root:root /opt/opencode /opt/opencode
COPY --from=harness-opencode    --chown=root:root /usr/local/bin/ /usr/local/bin/
COPY --from=harness-opencode    --chown=root:root /etc/agents/ /etc/agents/
COPY --from=harness-pi-mono     --chown=root:root /opt/pi /opt/pi
COPY --from=harness-pi-mono     --chown=root:root /usr/local/bin/ /usr/local/bin/
COPY --from=harness-pi-mono     --chown=root:root /etc/agents/ /etc/agents/

COPY <<'EOF' /etc/agents/links.d/herdr
/.agents/settings.herdr.toml=.config/herdr/config.toml
EOF

# The harness images' ENV other than links and PATH, which come from the copies above.
ENV USE_BUILTIN_RIPGREP=0 \
    CLAUDE_CODE_SANDBOXED=1 \
    DISABLE_AUTOUPDATER=1 \
    GEMINI_CLI_TRUST_WORKSPACE=true \
    PI_TELEMETRY=0 \
    PYTHONDONTWRITEBYTECODE=1

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "herdr"]
