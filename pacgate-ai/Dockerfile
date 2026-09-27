# Pacgate-ai API server — multi-stage Rust build
# Produces a slim image with just the pacgate-server binary.

# ── Stage 1: Builder ──────────────────────────────────────────────────────────
# Rust 1.88+ is required: time 0.3.55 + idna_adapter 1.2.2 need rustc 1.88.
FROM rust:1.94-bookworm AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy the entire workspace
COPY . .

# Source revision, so the running process can report WHICH commit it is.
#
# An ARG, not a LABEL: the api reports this at runtime, and the whole point of
# a staleness marker is to catch the case where the deployed tag and the running
# binary disagree. A label can only echo what was asked for; this comes from the
# process itself. Defaults to "unknown" rather than a wrong value when unset -
# the Dockerfile is also built outside CI, where no SHA is known.
ARG PAC_SOURCE_REVISION=unknown
ENV PAC_SOURCE_REVISION=${PAC_SOURCE_REVISION}

# Build the API server binary
RUN cargo build --release --bin pacgate-server && \
    cargo build --release --bin pacgate-seed

# ── Stage 1.5: NER model weights ─────────────────────────────────────────────
# Fetched at BUILD time, not at runtime. The deciding reason is egress, not size:
# this is a data-residency product, and a runtime fetch to huggingface.co would
# sit INSIDE the sanitize path - the one operation whose whole job is to stop
# data leaving. ocr-service downloads its model on first extraction
# (compose.prod.yaml), and that precedent is deliberately NOT followed here.
#
# Everything is verified, not assumed: the revision pins WHAT is fetched, and the
# SHA-256 plus byte length below pin WHAT ARRIVED. A revision pin alone cannot
# detect a swapped or truncated artifact.
#
# Cost, MEASURED 2026-09-27 by summing image layers for both builds (the same
# method on each, because Docker's own size reports disagree with each other):
# 128.6 MiB without the weights, 535.7 MiB with them - a 407 MiB increase, which
# matches the 387.9 MiB of weights plus layer overhead. The delta is the
# trustworthy figure; absolutes from `inspect`/`save`/`history` do not agree.
FROM debian:bookworm-slim AS ner-model

# Pinned upstream revision of shibing624/bert4ner-base-chinese (Apache-2.0).
ARG NER_MODEL_REV=5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a
ARG NER_BASE_URL=https://huggingface.co/shibing624/bert4ner-base-chinese/resolve

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /ner

RUN set -eux; \
    for f in config.json model.safetensors vocab.txt; do \
        curl -fsSL --retry 3 --retry-delay 2 -o "$f" "${NER_BASE_URL}/${NER_MODEL_REV}/${f}"; \
    done

# Verify BEFORE the runtime stage can use them. `set -eux` plus an explicit
# `exit 1` on each check: a wrong-weights image that starts cleanly is worse than
# a failed build, because it looks like success.
RUN set -eux; \
    echo "c5b24a4a4b825b01ebe7b101b80826091a5a03b688383d9261a60964747778df  config.json" > /ner/SHA256SUMS; \
    echo "1d2f0ea479431c1907bbaa75f872c26267ce3c19ea78e4266980b0d49b5a825a  model.safetensors" >> /ner/SHA256SUMS; \
    echo "45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c  vocab.txt" >> /ner/SHA256SUMS; \
    sha256sum -c /ner/SHA256SUMS; \
    test "$(stat -c %s model.safetensors)" = "406763404" || { echo "model.safetensors is the WRONG SIZE"; exit 1; }; \
    test "$(stat -c %s config.json)" = "1133" || { echo "config.json is the WRONG SIZE"; exit 1; }; \
    test "$(stat -c %s vocab.txt)" = "109540" || { echo "vocab.txt is the WRONG SIZE"; exit 1; }; \
    echo "NER weights verified: revision ${NER_MODEL_REV}"

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the compiled binaries
COPY --from=builder /build/target/release/pacgate-server /usr/local/bin/pacgate-server
COPY --from=builder /build/target/release/pacgate-seed /usr/local/bin/pacgate-seed

# Copy migrations (for startup migration)
COPY migrations /app/migrations

# NER weights, verified in the ner-model stage. The API reads this path from
# PACGATE_NER_MODEL_DIR, which both compose files set. `NerDetector::load`
# requires exactly these three files and fails closed if any is missing, so a
# malformed copy surfaces at first sanitize rather than silently degrading.
COPY --from=ner-model /ner /app/models/ner

# Create data directory
RUN mkdir -p /data

# Environment defaults
ENV DATABASE_URL=postgres://pacgate:pacgate@pacgate-db:5432/pacgate
ENV DATA_DIR=/data/tenants
ENV RUST_LOG=info
ENV PACGATE_DEFAULT_TENANT=default-firm

EXPOSE 8080

WORKDIR /app

CMD ["pacgate-server"]