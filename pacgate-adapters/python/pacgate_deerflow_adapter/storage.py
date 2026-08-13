"""PacgateMemoryStorage — implements deer-flow's MemoryStorage interface.

deer-flow's config.yaml points at this class:
    memory:
      storage_class: pacgate_deerflow_adapter.storage:PacgateMemoryStorage

This adapter translates deer-flow's memory load/save/reload calls into
HTTP calls to pacgate-api's matter-scoped memory endpoints.
"""

from typing import Any

from .client import PacgateApiClient


class PacgateMemoryStorage:
    """Memory storage backed by pacgate-api (per-matter knowledge base)."""

    def __init__(self, **kwargs: Any):
        self.client = PacgateApiClient(
            base_url=kwargs.get("api_url"),
            jwt_token=kwargs.get("jwt_token"),
            tenant_id=kwargs.get("tenant_id"),
        )
        # The matter_id is passed at runtime via deer-flow's thread context.
        # For now, use a default matter or read from env.
        self.matter_id = kwargs.get("matter_id", "default")

    def load(self, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
        """Load memory from pacgate-api."""
        try:
            resp = self.client.get(f"/api/matters/{self.matter_id}/memory")
            if resp.status_code == 200:
                return resp.json()
        except Exception:
            pass
        # Return empty memory structure if API is unavailable
        return {
            "version": "2.0",
            "revision": 0,
            "lastUpdated": "",
            "user": {},
            "history": {},
            "facts": [],
        }

    def reload(self, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
        """Reload memory from pacgate-api (same as load)."""
        return self.load(agent_name, user_id=user_id)

    def save(
        self,
        memory_data: dict[str, Any],
        agent_name: str | None = None,
        *,
        user_id: str | None = None,
    ) -> bool:
        """Save memory to pacgate-api."""
        try:
            resp = self.client.post(
                f"/api/matters/{self.matter_id}/memory",
                json=memory_data,
            )
            return resp.status_code in (200, 201)
        except Exception:
            return False


class PacgateArtifactStore:
    """Redirects deer-flow's write_file/read_file artifacts to pacgate-api.

    When deer-flow's sandbox write_file tool writes a .docx artifact,
    this store redirects it to pacgate-api's document endpoint so the
    document is stored under the tenant/matter structure and versioned.
    """

    def __init__(self, **kwargs: Any):
        self.client = PacgateApiClient(
            base_url=kwargs.get("api_url"),
            jwt_token=kwargs.get("jwt_token"),
            tenant_id=kwargs.get("tenant_id"),
        )
        self.matter_id = kwargs.get("matter_id", "default")

    def write_artifact(self, filename: str, content: bytes, doc_format: str = "docx") -> dict[str, Any]:
        """Write a document to pacgate-api (creates a new version)."""
        import tempfile

        with tempfile.NamedTemporaryFile(suffix=f".{doc_format}", delete=False) as f:
            f.write(content)
            f.flush()
            resp = self.client.upload("/api/documents", f.name, self.matter_id)

        import os

        os.unlink(f.name)

        if resp.status_code in (200, 201):
            return resp.json()
        return {"error": f"upload failed: {resp.status_code} {resp.text}"}

    def read_artifact(self, doc_id: str, version: int | None = None) -> bytes:
        """Read a document from pacgate-api."""
        path = f"/api/documents/{doc_id}/download"
        if version is not None:
            path += f"?version={version}"
        resp = self.client.get(path)
        if resp.status_code == 200:
            return resp.content
        raise FileNotFoundError(f"document {doc_id} not found: {resp.status_code}")

    def list_artifacts(self, matter_id: str) -> list[dict[str, Any]]:
        """List documents for a matter."""
        resp = self.client.get(f"/api/matters/{matter_id}/documents")
        if resp.status_code == 200:
            return resp.json()
        return []