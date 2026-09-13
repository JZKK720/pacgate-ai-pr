# Pacgate-ai deer-flow frontend wrapper image
#
# Builds the deer-flow Next.js web UI (research workspace) with the gateway
# URL baked in at BUILD time so the /api/* rewrites target the pacgate
# deer-flow backend (deer-flow:8001) instead of the upstream default
# (127.0.0.1:8001, which is unreachable from inside the container).
#
# Why a wrapper: the published ghcr.io/bytedance/deer-flow-frontend:latest
# bakes DEER_FLOW_INTERNAL_GATEWAY_BASE_URL=http://127.0.0.1:8001 at build
# time. Inside the compose network the backend is reachable as `deer-flow:8001`,
# so the upstream image requires a runtime patch to .next/routes-manifest.json
# (see plans/007-signin-status.md). Building from the pinned upstream tag with
# the correct build arg removes that patch and makes the image reproducible.
#
# Build context: the repository ROOT. The Dockerfile copies the upstream
# frontend source from a git checkout at deploy/deer-flow-src/frontend (the
# build script clones the bytedance tag into that path; the path is gitignored).
#
# Build (from repo root):
#   .\deploy\build-frontend.ps1
#   docker build -f deploy/deer-flow-frontend-pacgate/Dockerfile \
#     --build-arg DEER_FLOW_INTERNAL_GATEWAY_BASE_URL=http://deer-flow:8001 \
#     -t ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.1.0 .
#
# Run (compose.prod.yaml):
#   image: ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.1.0

ARG PNPM_STORE_PATH=/root/.local/share/pnpm/store
ARG NPM_REGISTRY

# ── Base: shared setup ────────────────────────────────────────────────────────
FROM node:22-alpine AS base
ARG PNPM_STORE_PATH
ARG NPM_REGISTRY
# Configure corepack registry before installing pnpm so the download itself
# succeeds in restricted networks (COREPACK_NPM_REGISTRY controls where
# corepack fetches package managers from).
RUN if [ -n "${NPM_REGISTRY}" ]; then \
      export COREPACK_NPM_REGISTRY="${NPM_REGISTRY}"; \
    fi && \
    corepack enable && corepack install -g pnpm@10.26.2
RUN pnpm config set store-dir ${PNPM_STORE_PATH}
# Optionally override npm registry for restricted networks (e.g. NPM_REGISTRY=https://registry.npmmirror.com)
RUN if [ -n "${NPM_REGISTRY}" ]; then pnpm config set registry "${NPM_REGISTRY}"; fi
WORKDIR /app
# The upstream deer-flow frontend source. This is cloned from the bytedance
# v2.0.0 tag by deploy/build-frontend.ps1 into deploy/deer-flow-src/frontend.
COPY deploy/deer-flow-src/frontend ./frontend

# ── Dev: install only, CMD is overridden by docker-compose ────────────────────
FROM base AS dev
RUN cd /app/frontend && pnpm install --frozen-lockfile
EXPOSE 3000

# ── Builder: install + compile Next.js with the gateway URL baked in ──────────
FROM base AS builder
ARG DEER_FLOW_INTERNAL_GATEWAY_BASE_URL=http://deer-flow:8001
ENV DEER_FLOW_INTERNAL_GATEWAY_BASE_URL=${DEER_FLOW_INTERNAL_GATEWAY_BASE_URL}
RUN cd /app/frontend && pnpm install --frozen-lockfile
# Skip env validation — runtime vars are injected by nginx/container
RUN cd /app/frontend && SKIP_ENV_VALIDATION=1 pnpm build

# ── Prod: minimal runtime with pre-built output ──────────────────────────────
FROM node:22-alpine AS prod
ARG PNPM_STORE_PATH
ARG NPM_REGISTRY
RUN if [ -n "${NPM_REGISTRY}" ]; then \
      export COREPACK_NPM_REGISTRY="${NPM_REGISTRY}"; \
    fi && \
    corepack enable && corepack install -g pnpm@10.26.2
RUN pnpm config set store-dir ${PNPM_STORE_PATH}
RUN if [ -n "${NPM_REGISTRY}" ]; then pnpm config set registry "${NPM_REGISTRY}"; fi
WORKDIR /app
COPY --from=builder /app/frontend ./frontend
EXPOSE 3000
CMD ["sh", "-c", "cd /app/frontend && pnpm start"]
