"""Pacgate-ai adapter for deer-flow.

This package implements deer-flow's pluggable storage interfaces (MemoryStorage,
AgentStore, and a write_file wrapper) by routing calls to pacgate-api's HTTP gateway.

Configuration via environment variables:
    PACGATE_API_URL     — base URL of pacgate-api (default: http://pacgate-api:8080)
    PACGATE_TENANT_ID   — the tenant ID for this deployment
    PACGATE_JWT_TOKEN   — JWT token for authentication (or set via deer-flow config)
"""

from .storage import PacgateMemoryStorage
from .client import PacgateApiClient

__all__ = ["PacgateMemoryStorage", "PacgateApiClient"]
__version__ = "0.1.0"