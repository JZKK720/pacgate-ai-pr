# Deer-flow wrapper image for Pacgate-ai
# Layers the pacgate_deerflow_adapter on top of deer-flow's published backend image.
# Never forks deer-flow source — the adapter is pip-installed on top.

FROM ghcr.io/bytedance/deer-flow-backend@sha256:e7c503a803c99a039e08da61359932877a9e0d0196799429698244117338af13

# Copy the adapter package
COPY pacgate-adapters/python/pacgate_deerflow_adapter /app/adapters/pacgate_deerflow_adapter

# Install the adapter package globally and also expose the copied source tree on
# PYTHONPATH, because DeerFlow itself runs from /app/backend via `uv run --no-sync`.
RUN pip install --no-cache-dir /app/adapters/pacgate_deerflow_adapter

# Ship a minimal startup-safe DeerFlow config. This keeps the wrapper bootable
# on a clean machine; runtime env can still override the memory backend inputs.
COPY deploy/deer-flow-pacgate/config.yaml /app/backend/config.yaml

# The adapter package is installed here and enabled via config.yaml. For actual
# Pacgate-backed memory, pass PACGATE_API_EMAIL/PASSWORD or PACGATE_JWT_TOKEN
# plus PACGATE_MATTER_ID at runtime.
ENV DEER_FLOW_CONFIG_PATH=/app/backend/config.yaml
ENV PYTHONPATH=/app/adapters:/app/backend
ENV PACGATE_API_URL=http://pacgate-api:8080
ENV PACGATE_TENANT_ID=default-firm

# Keep deer-flow's original startup command unchanged
CMD ["sh", "-c", "cd backend && uv run --no-sync uvicorn app.gateway.app:app --host 0.0.0.0 --port 8001"]