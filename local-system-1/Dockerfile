# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

# Never $BUILDPLATFORM: pip picks the musllinux wheel for the target arch.
FROM alpine:3.24@sha256:c6b073f8e9e58d881f6ffba6ebf3b9ebd60b9e7d6e8337018c0e68bb5c356873 AS build
RUN apk add --no-cache \
      py3-pip=26.1.2-r0 \
      python3=3.14.8-r0
COPY requirements.txt /tmp/requirements.txt
# --no-deps: tokenizers only pulls huggingface_hub for downloads, which julia.py does itself.
RUN pip install --no-cache-dir --no-deps --only-binary=:all: --require-hashes \
      --target /opt/julia/site -r /tmp/requirements.txt

# PyTorch has no musl build, so this runs upstream's ONNX export on alpine's onnxruntime.
FROM alpine:3.24@sha256:c6b073f8e9e58d881f6ffba6ebf3b9ebd60b9e7d6e8337018c0e68bb5c356873
RUN apk add --no-cache \
      ca-certificates=20261020-r0 \
      py3-numpy=2.4.6-r0 \
      py3-onnxruntime=1.24.4-r1 \
      python3=3.14.8-r0 \
      tini=0.19.0-r3 \
 && addgroup -g 1000 agent \
 && adduser -D -u 1000 -G agent -h /home agent \
 && mkdir -p /home/model \
 && chown -R agent:agent /home

COPY --from=build --chown=root:root /opt/julia/site /opt/julia/site
COPY --chown=root:root julia.py /opt/julia/julia.py

# Weights are fetched into /home/model on first start, never baked into the image.
ENV HOME=/home \
    JULIA_MODEL=/home/model \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/opt/julia/site

EXPOSE 11435
# start-period covers the first-start download of ~610 MB.
HEALTHCHECK --interval=30s --timeout=3s --start-period=600s --retries=3 \
  CMD ["/usr/bin/wget", "-q", "--spider", "http://127.0.0.1:11435/healthz"]

WORKDIR /home
# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "python3", "/opt/julia/julia.py"]
CMD ["serve"]
