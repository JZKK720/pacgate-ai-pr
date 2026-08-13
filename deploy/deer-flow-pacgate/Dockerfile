# Deer-flow wrapper image for Pacgate-ai
# Layers the pacgate_deerflow_adapter on top of deer-flow's published backend image.
# Never forks deer-flow source — the adapter is pip-installed on top.

FROM ghcr.io/bytedance/deer-flow-backend:2.1.0

# Copy the adapter package
COPY pacgate-adapters/python/pacgate_deerflow_adapter /app/adapters/pacgate_deerflow_adapter
RUN pip install --no-cache-dir /app/adapters/pacgate_deerflow_adapter

# Configure deer-flow to use the pacgate adapter for memory storage
ENV DEERFLOW_CONFIG_MEMORY_STORAGE=pacgate_deerflow_adapter.storage:PacgateMemoryStorage
ENV PACGATE_API_URL=http://pacgate-api:8080
ENV PACGATE_TENANT_ID=default-firm

# Keep deer-flow's original startup command unchanged
CMD ["sh", "-c", "cd backend && PYTHONPATH=. uv run --no-sync uvicorn app.gateway.app:app --host 0.0.0.0 --port 8001"]