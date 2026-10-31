FROM python:3.12-slim

# laya as a local decision engine (2026-10-31).
#
# CORRECTION (2026-10-31): an earlier version of this file claimed `laya[onnx]`
# avoided PyTorch and saved ~2.5 GB. That is FALSE and was measured false: with
# `laya[onnx]` installed, `pip list` reports torch 2.15.0+cpu alongside
# onnxruntime 1.31.1, and `laya/agent.py` imports `safetensors.torch` at
# construction. The published ONNX *graph* artifacts (`onnx/` paths) are not in
# the repo at all - checked the HF and ModelScope file trees, zero matches - and
# the shipped checkpoints are `model.safetensors`, i.e. PyTorch weights. So this
# image carries torch whatever extra is requested; the `serve` extra is what
# provides `laya-serve`, and that is what we actually need.
#
# The weights are NOT baked in. They are mounted read-only at /models and
# HF_HUB_OFFLINE=1 is set by compose, so nothing is fetched at run time on a
# client machine. See the LAYA_MODEL_DIR note in .env.example for staging.
ARG LAYA_VERSION=0.4.19
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir "laya[serve]==${LAYA_VERSION}"

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
