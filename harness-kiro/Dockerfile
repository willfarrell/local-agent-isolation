# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

ARG KIRO_VERSION=2.33.1

# Fetches and checksums only, so run it native on the builder; TARGETARCH still picks the asset.
FROM --platform=$BUILDPLATFORM alpine:3.24@sha256:c6b073f8e9e58d881f6ffba6ebf3b9ebd60b9e7d6e8337018c0e68bb5c356873 AS build
ARG KIRO_VERSION
ARG TARGETARCH
# -e is what enforces the checksum gate below; pipefail only covers a command appended after the pipe.
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
RUN apk add --no-cache \
      ca-certificates=20261020-r0 \
      wget=1.25.0-r3
# The -musl build; the plain one is glibc. shas are upstream's, from latest/manifest.json on that bucket.
RUN case "$TARGETARCH" in \
      amd64) arch=x86_64;  sha=2cb595f941b19827776318ebc8e698bc6033706c848a3fcb21379bb793e60bf5 ;; \
      arm64) arch=aarch64; sha=59f0668de8d6303625326764dd624f63472a1f602648c06c657da68a0ea937e9 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -qO /kiro.tar.gz "https://desktop-release.q.us-east-1.amazonaws.com/${KIRO_VERSION}/kirocli-${arch}-linux-musl.tar.gz"; \
    echo "${sha}  /kiro.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/kiro; \
    tar -xzf /kiro.tar.gz -C /opt/kiro --strip-components=1 kirocli/bin; \
    test -x /opt/kiro/bin/kiro-cli

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER 0:0

COPY --from=build --chown=root:root /opt/kiro /opt/kiro

COPY <<'EOF' /etc/agents/links.d/harness-kiro
/.agents/INSTRUCTIONS.md=.kiro/steering/AGENTS.md
/.agents/settings.mcp.json=.kiro/settings/mcp.json
EOF

# Login and sessions, in one SQLite database; the rest of the folder and everything ~/.kiro auto-loads (agents
# carry hooks) go.
COPY <<'EOF' /etc/agents/logins.d/harness-kiro
.local/share/kiro-cli/data.sqlite3*
EOF

ENV PATH=/opt/kiro/bin:$PATH

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "kiro-cli"]
