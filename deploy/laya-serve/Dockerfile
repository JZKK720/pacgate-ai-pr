FROM python:3.12-slim

# laya as a local decision engine (2026-10-31).
#
# Deliberately `laya[serve,onnx]` and NOT the default torch path: ONNX Runtime
# runs the same checkpoints without PyTorch, which is ~2.5 GB saved in an image
# that has to sit on a client machine. Measured: laya imports and runs without
# torch when only the onnx extra is present.
#
# The weights are NOT baked in. They are a 1.2 GB external-data sidecar per
# checkpoint, they are mounted read-only at /models, and HF_HUB_OFFLINE=1 is set
# by compose. Baking them would mean re-publishing 1.2 GB per release. This
# image stays small on purpose.
ARG LAYA_VERSION=0.4.19
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir "laya[serve,onnx]==${LAYA_VERSION}"

# Run unprivileged. The HF cache is the only writable path, so it must exist and
# be owned by this user before compose mounts the read-only model directory.
RUN useradd --create-home --uid 10001 laya \
    && mkdir -p /home/laya/.cache/huggingface \
    && chown -R laya:laya /home/laya

USER laya
WORKDIR /home/laya

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HF_HUB_OFFLINE=1 \
    LAYA_PORT=8000 \
    LAYA_HOST=0.0.0.0

EXPOSE 8000

# `laya-serve` is the documented entry point and reads its configuration from
# the LAYA_* environment. No LAYA_API_KEY: this service is reachable only on the
# compose network, and requiring a key would contradict the reason we picked a
# local engine over a metered API in the first place.
CMD ["laya-serve"]
