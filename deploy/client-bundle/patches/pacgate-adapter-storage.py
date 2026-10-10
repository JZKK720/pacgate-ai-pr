"""PacgateMemoryStorage — implements DeerFlow's current MemoryStorage interface.

DeerFlow 2.x loads custom memory backends from `memory.storage_class`, for
example:

        memory:
            storage_class: pacgate_deerflow_adapter.storage.PacgateMemoryStorage

This adapter translates DeerFlow memory load/save/reload calls into HTTP calls
to Pacgate's matter-scoped memory endpoints.

Pacgate patch (2026-10-10): SHAPE NORMALIZATION on load().

Root cause of the frontend memory card crash ("This page couldn't load",
RangeError: Invalid time value): matter memory on disk is a flat process-note
document ({content, revision, tags}), NOT a deer-flow memory document. The
router's MemoryResponse model then fills every missing field with "" —
including lastUpdated and every section updatedAt — and the frontend calls
formatDistanceToNow("") which throws. The whole settings page dies on the
error boundary.

Fix: load() now guarantees the deer-flow memory shape. The matter's process
note is surfaced as the topOfMind summary (it IS the current process state);
everything else starts empty with real timestamps so the UI renders "just now"
instead of crashing. save() round-trips the full deer-flow shape, which
check_memory_scope already validates server-side.
"""

import os
from typing import Any

from deerflow.agents.memory.storage import MemoryStorage, utc_now_iso_z

from .client import PacgateApiClient


class MatterMemoryConflict(Exception):
    """Raised when a matter-memory write is rejected as stale (HTTP 409).

    Deliberately NOT swallowed into a generic failure. A conflict means another
    writer changed the memory since this process read it; silently retrying
    would discard their update, and silently ignoring the error would discard
    this one. The caller must decide.
    """


class MatterMemoryOutOfScope(Exception):
    """Raised when a matter-memory write is rejected as out of scope (HTTP 422).

    Memory lanes hold PROCESS, not matter facts. The server refuses a payload
    containing an identifier (resident ID, USCC, mobile, bank card, email) or one
    too large to be a summary. Matter facts belong in the RAG lane, which is
    sanitization-gated before retrieval.

    Deliberately separate from MatterMemoryConflict: a 409 means "retry after
    reloading", and a 422 means "do not retry this content at all". Collapsing
    them would make a caller retry a payload that can never be accepted.

    NOTE the deliberate asymmetry: person and organisation NAMES are permitted.
    A process summary legitimately says "the firm reviewed the matter", and a
    check that refused those would reject valid summaries. Do not "fix" that.
    """


def _empty_section() -> dict[str, Any]:
    return {"summary": "", "updatedAt": ""}


def _normalize_to_deerflow_shape(data: Any) -> dict[str, Any]:
    """Coerce a matter-memory payload into the deer-flow memory shape.

    Two shapes arrive here:
    - Legacy matter memory: {version: "2.0", revision, lastUpdated, content,
      tags} — a flat process-note document. The note maps to topOfMind.summary
      (it IS the current process state); other sections start empty.
    - Already-migrated memory: a full deer-flow shape written back by save().
      Its sections are preserved as-is.

    Empty sections keep updatedAt="" — the frontend guards those with
    truthiness before formatting. lastUpdated is ALWAYS a real timestamp: the
    frontend formats it unconditionally, and an empty string crashes the
    memory card (RangeError: Invalid time value).
    """
    if not isinstance(data, dict):
        data = {}

    # Already in deer-flow shape? Preserve sections verbatim.
    user = data.get("user")
    if isinstance(user, dict) and isinstance(user.get("workContext"), dict):
        last_updated = data.get("lastUpdated")
        if not isinstance(last_updated, str) or not last_updated.strip():
            last_updated = utc_now_iso_z()
        facts = data.get("facts")
        return {
            "version": "1.0",
            "lastUpdated": last_updated,
            "user": user,
            "history": data.get("history") if isinstance(data.get("history"), dict) else {},
            "facts": facts if isinstance(facts, list) else [],
        }

    content = data.get("content")
    if not isinstance(content, str):
        content = ""

    # lastUpdated: prefer the stored value when it parses as a timestamp;
    # fall back to now. NEVER emit "" — the frontend formats this field
    # unconditionally and an empty string crashes the memory card.
    last_updated = data.get("lastUpdated")
    if not isinstance(last_updated, str) or not last_updated.strip():
        last_updated = utc_now_iso_z()

    return {
        "version": "1.0",
        "lastUpdated": last_updated,
        "user": {
            "workContext": _empty_section(),
            "personalContext": _empty_section(),
            "topOfMind": {"summary": content, "updatedAt": last_updated if content else ""},
        },
        "history": {
            "recentMonths": _empty_section(),
            "earlierContext": _empty_section(),
            "longTermBackground": _empty_section(),
        },
        "facts": data.get("facts") if isinstance(data.get("facts"), list) else [],
    }


class PacgateMemoryStorage(MemoryStorage):
    """Memory storage backed by pacgate-api (per-matter knowledge base)."""

    def __init__(self):
        self.client = PacgateApiClient(
            base_url=os.environ.get("PACGATE_API_URL"),
            jwt_token=os.environ.get("PACGATE_JWT_TOKEN"),
            tenant_id=os.environ.get("PACGATE_TENANT_ID"),
            email=os.environ.get("PACGATE_API_EMAIL"),
            password=os.environ.get("PACGATE_API_PASSWORD"),
        )
        self.matter_id = os.environ.get("PACGATE_MATTER_ID")
        if not self.matter_id:
            raise ValueError("PacgateMemoryStorage requires PACGATE_MATTER_ID")
        # The revision last observed. None means "never read", which sends no
        # If-Match and therefore keeps the unconditional write path working.
        self._revision: int | None = None

    def load(
        self, agent_name: str | None = None, *, user_id: str | None = None
    ) -> dict[str, Any]:
        """Load memory from pacgate-api, remembering the revision read.

        The raw matter payload is normalized to the deer-flow memory shape
        before returning — see _normalize_to_deerflow_shape for why.
        """
        resp = self.client.get(f"/api/matters/{self.matter_id}/memory")
        resp.raise_for_status()
        data = resp.json()
        if isinstance(data, dict):
            revision = data.get("revision", 0)
            self._revision = revision if isinstance(revision, int) else 0
        return _normalize_to_deerflow_shape(data)

    def reload(
        self, agent_name: str | None = None, *, user_id: str | None = None
    ) -> dict[str, Any]:
        """Reload memory from pacgate-api (same as load)."""
        return self.load(agent_name, user_id=user_id)

    def save(
        self,
        memory_data: dict[str, Any],
        agent_name: str | None = None,
        *,
        user_id: str | None = None,
    ) -> bool:
        """Save memory to pacgate-api, guarding against a lost update.

        Sends If-Match when a revision is known. On 409, raises
        MatterMemoryConflict and forgets the revision, so a caller that chooses
        to retry must reload first rather than replaying the stale value.
        """
        headers: dict[str, str] = {}
        if self._revision is not None:
            headers["If-Match"] = str(self._revision)

        resp = self.client.post(
            f"/api/matters/{self.matter_id}/memory",
            json=memory_data,
            headers=headers,
        )

        if resp.status_code == 409:
            self._revision = None
            raise MatterMemoryConflict(
                f"matter memory was modified concurrently: {resp.text}"
            )

        # 422 means the CONTENT is out of scope, not that the write raced. It must
        # not be retried: the same payload will be refused every time. Kept
        # distinct from the 409 so a caller's retry loop cannot spin on it.
        if resp.status_code == 422:
            raise MatterMemoryOutOfScope(
                f"memory content is out of scope for this lane: {resp.text}"
            )

        resp.raise_for_status()
        return True


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
            email=kwargs.get("email"),
            password=kwargs.get("password"),
        )
        self.matter_id = kwargs.get("matter_id")
        if not self.matter_id:
            raise ValueError("PacgateArtifactStore requires a real matter_id")

    def write_artifact(
        self, filename: str, content: bytes, doc_format: str = "docx"
    ) -> dict[str, Any]:
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
