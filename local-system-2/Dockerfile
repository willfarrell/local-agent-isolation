# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

ARG OLLAMA_VERSION=0.17.7-r1

# Not FROM tools: a daemon needs none of the agent's bash/git/jq.
FROM alpine:3.24@sha256:c6b073f8e9e58d881f6ffba6ebf3b9ebd60b9e7d6e8337018c0e68bb5c356873

ARG OLLAMA_VERSION
RUN apk add --no-cache \
      ca-certificates=20261020-r0 \
      "ollama=${OLLAMA_VERSION}" \
      tini=0.19.0-r3 \
 && addgroup -g 1000 agent \
 && adduser -D -u 1000 -G agent -h /home agent \
 && mkdir -p /home/.ollama/models \
 && chown -R agent:agent /home

# 0.0.0.0: the loopback default reads as connection refused from sibling containers; models go in the volume.
ENV HOME=/home \
    OLLAMA_HOST=0.0.0.0:11434 \
    OLLAMA_MODELS=/home/.ollama/models

EXPOSE 11434
# --spider writes nothing, which a read-only rootfs requires.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/usr/bin/wget", "-q", "--spider", "http://127.0.0.1:11434/api/version"]

WORKDIR /home
# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "ollama", "serve"]
