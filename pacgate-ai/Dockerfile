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

# Build the API server binary
RUN cargo build --release --bin pacgate-server

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the compiled binary
COPY --from=builder /build/target/release/pacgate-server /usr/local/bin/pacgate-server

# Copy migrations (for startup migration)
COPY migrations /app/migrations

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