# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG ALPINE_IMAGE=alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
ARG OLLAMA_VERSION=0.17.7-r1

# Not FROM tools: a daemon needs none of the agent's bash/git/jq.
FROM ${ALPINE_IMAGE}

ARG OLLAMA_VERSION
RUN apk add --no-cache \
      ca-certificates=20260909-r0 \
      "ollama=${OLLAMA_VERSION}" \
      tini=0.19.0-r3 \
 && addgroup -g 1000 agent \
 && adduser -D -u 1000 -G agent -h /home agent \
 && mkdir -p /home/.ollama/models \
 && chown -R agent:agent /home \
 && { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

# 0.0.0.0: the loopback default reads as connection refused from sibling containers; models go in the volume.
ENV HOME=/home \
    OLLAMA_HOST=0.0.0.0:11434 \
    OLLAMA_MODELS=/home/.ollama/models

EXPOSE 11434
# --spider writes nothing, which a read-only rootfs requires.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/usr/bin/wget", "-q", "--spider", "http://127.0.0.1:11434/api/version"]

WORKDIR /home
USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "ollama", "serve"]
