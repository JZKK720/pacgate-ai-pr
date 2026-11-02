# laya as a local decision engine (2026-10-31; weights baked 2026-11-02).
#
# WHAT THIS IMAGE IS. laya judges a single clause with typed questions - how
# risky, which risk flags, which party it favours - and returns calibrated
# probabilities instead of a verdict. It is a triage filter, not an adjudicator.
#
# TWO CORRECTIONS TO EARLIER VERSIONS OF THIS FILE, both measured 2026-11-02.
#
# 1. The "saves ~2.5 GB by avoiding PyTorch" claim was false and is now moot.
#    `laya[onnx]` installs torch regardless: `laya/agent.py` imports
#    `safetensors.torch`, and the published ONNX *graph* artifacts do not exist
#    in the repo (checked the HF and ModelScope trees, zero matches) - only
#    `model.safetensors`, i.e. PyTorch weights.
#
# 2. The same comment claimed pip reports `torch 2.15.0+cpu`. It did not. A plain
#    `pip install laya[serve]` resolved torch from PyPI's default CUDA build and
#    dragged in 4.2 GB of `nvidia-*` packages onto a CPU-only box: the image was
#    9.23 GB. Installing torch from the CPU-only index FIRST makes that claim true
#    and drops it to 1.79 GB before weights (measured). TORCH_VERSION is a build
#    argument so a future laya release cannot silently swap the wheel.
#
# WHY NO NPU BACKEND. Considered and rejected on measured grounds, 2026-11-02.
# An NPU is real hardware - this fleet's AIPCs are AMD Ryzen AI 9 HX 370 class
# and report an "NPU Compute Accelerator Device". It is still the wrong target:
#   - laya exposes no NPU backend. It is PyTorch, and its only accelerator path
#     is `cuda`; LAYA_DEVICE is parsed by `torch.device`, which has no `npu`.
#     Running on an AMD XDNA NPU needs a separate compiler with per-model
#     operator support - a different runtime, not a flag.
#   - The NPU is not reachable from the shipped container. The Linux guest
#     exposes no /dev/accel and loads no amdxdna, so an --device passthrough has
#     nothing to bind. The Windows driver serves Windows processes only.
#   - There is no time to save. These are 0.6-0.8 GB encoder models producing one
#     number per clause: measured 0.3 s English and 0.1 s Chinese per clause on
#     CPU. NPU offload would move a rounding error.
# What WOULD cut startup cost is pre-converted ONNX (onnxruntime does ship an
# XDNA execution provider), but nothing is published per checkpoint, so that is
# a separate evaluation - not an image change.
#
# WHY THE WEIGHTS ARE BAKED, reversed 2026-11-02. They were previously staged
# into a mounted HF cache, which required a client-machine step and produced two
# silent failure modes: an empty cache crash-loops at boot, and a partial cache
# reports healthy while the missing checkpoint's language returns HTTP 500.
# Baking removes both, and removes the staging step. The checkpoint is
# Apache-2.0 (verified via the ModelScope model API), so redistribution is fine.
#
# SIZING. Weights are 1.45 GB (803.6 MB English + 614.0 MB multilingual + 35 MB
# tokenizers). Measured on 0.2.13: 1.64 GB COMPRESSED in the registry, 2.8 GB as
# an uncompressed rootfs (`du -sh /`). `docker images` shows 4.69 GB, which is
# Docker Desktop accounting rather than what a client downloads - use the registry
# figure. That cost is paid ONLY by machines that enable the `laya` profile: the
# service declares `profiles: ["laya"]`, and `docker compose config --images`
# omits this image entirely without it. Clients who never opt in never pull it.
#
# THE MOUNT THAT CAN HIDE ALL OF THIS. An earlier revision of compose.prod.yaml
# bind-mounted ${LAYA_HF_CACHE} over /home/laya/.cache/huggingface. A bind mount
# does not merge with the image layer - it REPLACES it. Proven 2026-11-02: with an
# empty source directory the baked weights vanish and the container sees an empty
# cache. That mount is gone from both shipped lanes. Pinning a different revision
# means rebuilding with a different LAYA_REVISION build arg, not mounting over the
# baked layer - the same class of defect as a COPY source shadowed by a read-only
# mount.
#
# HF_HUB_OFFLINE=1 stays: the snapshot is present, and a failed lookup must fail
# loudly rather than reach for the network on a machine that may not have one.
FROM python:3.12-slim

ARG LAYA_VERSION=0.4.19
ARG TORCH_VERSION=2.15.0

# CPU torch first, from the CPU index. Order matters: laya requires
# torch>=2.0.0, so an installed 2.15.0+cpu satisfies it and pip never goes
# looking for the CUDA build.
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu \
        "torch==${TORCH_VERSION}" \
    && pip install --no-cache-dir "laya[serve]==${LAYA_VERSION}"

ARG LAYA_REVISION=7b928d828b7b0e022f929d9bd2e44165aa270148

RUN useradd --create-home --uid 10001 laya \
    && mkdir -p "/home/laya/.cache/huggingface/hub/models--convaiinnovations--laya/refs" \
    && chown -R laya:laya /home/laya

USER laya
WORKDIR /home/laya

# Build context is deploy/laya-serve (see build-ghcr.yml). laya-weights/ is exactly
# the directory scripts/stage-laya-models.ps1 writes, copied in unchanged:
#   pwsh -NoProfile -File scripts/stage-laya-models.ps1 -OutDir deploy/laya-serve/laya-weights
# One layout, not a second invented one, so staging and baking cannot drift.
# It is gitignored and is NOT in the client bundle. A release build therefore
# fails on the COPY below when the weights were not staged, so a weightless image
# cannot ship silently.
COPY --chown=laya:laya laya-weights/ /home/laya/.cache/huggingface/

# Both checkpoints ship, so the image is complete for an en/zh product. The
# checksums turn a corrupted or substituted weight file into a BUILD failure
# instead of a clause that returns a meaningless number at run time.
RUN python - <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path("/home/laya/.cache/huggingface/hub/models--convaiinnovations--laya/snapshots")
expected = {
    "model.safetensors": "891102d372688fc2a094dac56a384bc537b87c63f21f9f3dac0be2b7cbc8d86c",
    "multilingual/model.safetensors": "9d628fd971b700382ac6f65920a86f149777b2e748e0c955fb3b19695aa8f204",
}
snaps = [p for p in root.iterdir() if p.is_dir()]
if len(snaps) != 1:
    sys.exit("expected exactly one snapshot under %s, found %d" % (root, len(snaps)))
for rel, want in expected.items():
    f = snaps[0] / rel
    if not f.is_file():
        sys.exit("baked weights are missing %s" % rel)
    h = hashlib.sha256()
    with f.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    got = h.hexdigest()
    if got != want:
        sys.exit("baked weights %s has sha256 %s, expected %s" % (rel, got, want))
print("baked weights verified: " + ", ".join(expected))
PY

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HF_HUB_OFFLINE=1 \
    LAYA_PORT=8000 \
    LAYA_HOST=0.0.0.0 \
    LAYA_MODELS=multilingual,english \
    LAYA_MAX_LOADED=2

EXPOSE 8000

# laya-serve reads its configuration from the LAYA_* environment. No
# LAYA_API_KEY: this service is reachable only on the compose network, and
# requiring a key would contradict the reason we picked a local engine over a
# metered API in the first place.
CMD ["laya-serve"]