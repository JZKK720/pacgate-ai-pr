"""Pacgate-ai adapter for deer-flow.

Implements deer-flow's pluggable memory-storage contract by routing matter
memory to pacgate-api over HTTP.

Two backends, one per deer-flow generation:

* **v2.0.x** - ``PacgateMemoryStorage`` (``deerflow.agents.memory.storage.MemoryStorage``),
  configured via ``memory.storage_class``.
* **v2.2.0+** - ``PacgateMatterMemoryStorage`` (``...backends.deermem.deermem.core.storage
  .MemoryStorage``), configured via ``memory.backend_config.storage_class`` and
  consumed by DeerMem's ``create_storage``. See ``matter_memory.py``.

Which backend is importable depends on the deer-flow version in the image; each
is imported defensively so one bind-mount set works on both. The one you use is
selected by config, not by this file.

Configuration via environment variables:
    PACGATE_API_URL     - base URL of pacgate-api (default: http://pacgate-api:8080)
    PACGATE_TENANT_ID   - the tenant ID for this deployment
    PACGATE_JWT_TOKEN   - JWT token for authentication (or set via deer-flow config)
    PACGATE_MATTER_ID   - the matter this deer-flow process serves (required)
"""

from .client import PacgateApiClient
from .storage import PacgateArtifactStore

__all__ = [
    "PacgateApiClient",
    "PacgateArtifactStore",
]

try:  # deer-flow >= 2.2.0
    from .matter_memory import PacgateMatterMemoryStorage
except ImportError:  # deer-flow 2.0.x: backends.deermem does not exist
    PacgateMatterMemoryStorage = None  # type: ignore[assignment]
else:
    __all__.append("PacgateMatterMemoryStorage")

try:  # deer-flow <= 2.1.x
    from .storage import PacgateMemoryStorage
except RuntimeError:  # deer-flow >= 2.2.0: storage.py raises on instantiation only,
    PacgateMemoryStorage = None  # type: ignore[assignment]
else:
    __all__.append("PacgateMemoryStorage")

__version__ = "0.2.0"
