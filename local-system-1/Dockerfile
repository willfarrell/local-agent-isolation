# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG ALPINE_IMAGE=alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Never $BUILDPLATFORM: pip picks the musllinux wheel for the target arch.
FROM ${ALPINE_IMAGE} AS build
RUN apk add --no-cache \
      py3-pip=26.1.2-r0 \
      python3=3.14.7-r1
COPY requirements.txt /tmp/requirements.txt
# --no-deps: tokenizers only pulls huggingface_hub for downloads, which julia.py does itself.
RUN pip install --no-cache-dir --no-deps --only-binary=:all: --require-hashes \
      --target /opt/julia/site -r /tmp/requirements.txt

# PyTorch has no musl build, so this runs upstream's ONNX export on alpine's onnxruntime.
FROM ${ALPINE_IMAGE}
RUN apk add --no-cache \
      ca-certificates=20260909-r0 \
      py3-numpy=2.4.6-r0 \
      py3-onnxruntime=1.24.4-r1 \
      python3=3.14.7-r1 \
      tini=0.19.0-r3 \
 && addgroup -g 1000 agent \
 && adduser -D -u 1000 -G agent -h /home agent \
 && mkdir -p /home/model \
 && chown -R agent:agent /home \
 && { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

COPY --from=build /opt/julia/site /opt/julia/site
COPY julia.py /opt/julia/julia.py

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
USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "python3", "/opt/julia/julia.py"]
CMD ["serve"]
