"""PacgateMemoryStorage (deer-flow v2.2.0) — pacgate-api as the memory backend.

Why this module exists
----------------------
deer-flow v2.0 stored memory through ``deerflow.agents.memory.storage.MemoryStorage``.
v2.2.0 deleted that module. The replacement contract is
``deerflow.agents.memory.backends.deermem.deermem.core.storage.MemoryStorage``
(``load`` / ``reload`` / ``save`` / ``apply_changes``), consumed by DeerMem via
``create_storage()``, which accepts a dotted class path in
``memory.backend_config.storage_class``.

This class is that dotted path. It keeps pacgate-api as the only writer of
matter memory (see docs/superpowers/decisions/2026-11-24-matter-memory-ownership.md):
the matter's ``memory.json`` on the pacgate-api side holds revision + content,
and every write here carries ``If-Match`` so a concurrent writer is refused by
the server (409), not by convention.

Scope mapping
-------------
A deer-flow memory scope is ``(agent_name, user_id)``; a pacgate matter IS the
scope. One matter = one document. ``agent_name`` and ``user_id`` are accepted
and deliberately ignored, exactly as the v2.0 adapter did. Per-fact ``revision``
fields are tracked inside the document purely to satisfy the change-set
contract; the authoritative counter is the document-level ``revision``, owned
by pacgate-api.

Failure semantics (matched to what DeerMem's updater actually catches)
----------------------------------------------------------------------
- 409 -> ``MemoryManifestRevisionConflict`` (subclass of ``MemoryRevisionConflict``).
  The updater retries the whole extraction up to 3 times against a fresh
  snapshot. Raising anything else, or returning False, defeats that retry.
- 422 -> ``MatterMemoryOutOfScope``. The matter lane holds PROCESS, not matter
  facts (pacgate-api's memory_scope check). Retrying can never succeed, so this
  is raised and NOT translated into a revision conflict.
- 5xx / network -> ``save`` returns False (DeerMem's legacy path); ``apply_changes``
  lets the exception propagate to the debounce worker, which logs and drops the
  batch. Never silently report success.
"""

from __future__ import annotations

import copy
import logging
from typing import Any

from .client import PacgateApiClient

logger = logging.getLogger(__name__)

try:  # deer-flow v2.2.0 layout
    from deerflow.agents.memory.backends.deermem.deermem.core.storage import (
        MemoryManifestRevisionConflict,
        MemoryRevisionConflict,
        MemoryStorage,
        MemoryStorageCorruption,
        create_empty_memory,
        utc_now_iso_z,
    )
except ImportError as exc:  # pragma: no cover - import-time guard
    raise ImportError(
        "pacgate_deerflow_adapter.matter_memory targets deer-flow >= 2.2.0 "
        "(deerflow.agents.memory.backends.deermem.deermem.core.storage). "
        "On deer-flow 2.0.x use pacgate_deerflow_adapter.storage.PacgateMemoryStorage."
    ) from exc


class MatterMemoryOutOfScope(Exception):
    """The pacgate-api scope check refused the payload (HTTP 422).

    Distinct from a conflict: a 409 means "reload and retry", a 422 means
    "this content can never be stored in the memory lane". Never retried,
    never folded into a revision conflict.
    """


def _legacy_source_value(source: Any) -> str:
    """Project structured source metadata to the legacy public string."""
    if isinstance(source, str):
        return source
    if not isinstance(source, dict):
        return "unknown"
    source_type = source.get("type")
    thread_id = source.get("threadId")
    if source_type == "conversation" and isinstance(thread_id, str) and thread_id:
        return thread_id
    if isinstance(source_type, str) and source_type:
        return source_type
    if isinstance(thread_id, str) and thread_id:
        return thread_id
    return "unknown"


def _compat_document(memory_data: dict[str, Any]) -> dict[str, Any]:
    """Return the public document shape (facts carry legacy `source` strings)."""
    result = copy.deepcopy(memory_data)
    for fact in result.get("facts", []):
        if isinstance(fact, dict):
            fact["source"] = _legacy_source_value(fact.get("source"))
    return result


def _empty_section() -> dict[str, Any]:
    return {"summary": "", "updatedAt": ""}


def _normalize_last_updated(value: Any) -> str:
    """The frontend formats lastUpdated unconditionally; never emit ""."""
    if isinstance(value, str) and value.strip():
        return value
    return utc_now_iso_z()


def normalize_to_deerflow_shape(data: Any) -> dict[str, Any]:
    """Coerce a pacgate matter-memory payload into the deer-flow memory shape.

    The matter document starts life as a flat process note
    (``{"version", "revision", "lastUpdated", "content", "tags"}``). Once the
    agent writes its first memory it is upgraded in place to the full deer-flow
    shape. Both shapes must load. The frontend crashes on an empty
    ``lastUpdated`` (RangeError in formatDistanceToNow), so it is always a real
    timestamp.
    """
    if not isinstance(data, dict):
        data = {}

    last_updated = _normalize_last_updated(data.get("lastUpdated"))
    user = data.get("user")
    facts = data.get("facts")
    facts = [f for f in facts if isinstance(f, dict)] if isinstance(facts, list) else []

    if isinstance(user, dict) and isinstance(user.get("workContext"), dict):
        # Already in full deer-flow shape; preserve sections, top up missing
        # ones so downstream normalisation has a stable document to work with.
        doc = create_empty_memory()
        doc["user"].update({k: v for k, v in user.items() if isinstance(v, dict)})
        history = data.get("history")
        if isinstance(history, dict):
            doc["history"].update({k: v for k, v in history.items() if isinstance(v, dict)})
        doc["facts"] = facts
        doc["lastUpdated"] = last_updated
        doc["revision"] = int(data.get("revision") or 0)
        if isinstance(data.get("version"), str):
            doc["version"] = data["version"]
        return _compat_document(doc)

    # Flat legacy process-note document: surface the note as topOfMind so the
    # agent sees it as current process state.
    content = data.get("content")
    content = content if isinstance(content, str) else ""
    doc = create_empty_memory()
    doc["lastUpdated"] = last_updated
    doc["revision"] = int(data.get("revision") or 0)
    if content:
        doc["user"]["topOfMind"] = {"summary": content, "updatedAt": last_updated}
    if isinstance(data.get("tags"), list):
        doc["tags"] = data["tags"]
    return _compat_document(doc)


def _doc_revision(doc: dict[str, Any]) -> int:
    try:
        return int(doc.get("revision") or 0)
    except (TypeError, ValueError):
        return 0


class PacgateMatterMemoryStorage(MemoryStorage):
    """deer-flow v2.2.0 MemoryStorage backed by pacgate-api matter memory.

    Constructed by DeerMem's ``create_storage`` from ``backend_config``; the
    ``config`` argument is accepted and ignored (all pacgate connection
    details come from the process environment, same as the rest of the
    adapter). Extra keyword arguments are tolerated so the factory may pass
    more in future.
    """

    def __init__(self, config: Any = None, **kwargs: Any) -> None:
        self._config = config
        self.client = PacgateApiClient(
            base_url=None,
            jwt_token=None,
            tenant_id=None,
            email=None,
            password=None,
        )
        self.matter_id = self._matter_id_from_env()
        self._revision: int | None = None

    @staticmethod
    def _matter_id_from_env() -> str:
        import os

        matter_id = os.environ.get("PACGATE_MATTER_ID")
        if not matter_id:
            # Fail fast and loud, exactly like the v2.0 adapter. Memory writes
            # with no matter must never silently land on a default matter.
            raise ValueError("PacgateMatterMemoryStorage requires PACGATE_MATTER_ID")
        return matter_id

    # ── internal helpers ──────────────────────────────────────────────────
    @property
    def _path(self) -> str:
        return f"/api/matters/{self.matter_id}/memory"

    def _get_raw(self) -> tuple[dict[str, Any], int]:
        resp = self.client.get(self._path)
        if resp.status_code != 200:
            raise MemoryStorageCorruption(
                f"matter memory GET failed: HTTP {resp.status_code}: {resp.text[:200]}"
            )
        try:
            data = resp.json()
        except ValueError as exc:
            raise MemoryStorageCorruption(f"matter memory GET returned non-JSON: {exc}") from exc
        if not isinstance(data, dict):
            raise MemoryStorageCorruption("matter memory GET returned a non-object body")
        return data, _doc_revision(data)

    def _put(self, memory: dict[str, Any], expected_revision: int | None) -> dict[str, Any]:
        headers: dict[str, str] = {}
        expected = self._revision if expected_revision is None else expected_revision
        if expected is not None:
            headers["If-Match"] = str(int(expected))
        resp = self.client.post(self._path, json=memory, headers=headers)
        if resp.status_code == 409:
            self._revision = None
            raise MemoryManifestRevisionConflict(
                f"matter memory was modified concurrently: {resp.text[:200]}"
            )
        if resp.status_code == 422:
            raise MatterMemoryOutOfScope(
                f"matter memory content refused by scope policy: {resp.text[:200]}"
            )
        if resp.status_code not in (200, 201):
            raise MemoryStorageCorruption(
                f"matter memory write failed: HTTP {resp.status_code}: {resp.text[:200]}"
            )
        try:
            body = resp.json()
        except ValueError:
            body = memory
        self._revision = _doc_revision(body) if isinstance(body, dict) else None
        return body if isinstance(body, dict) else memory

    # ── MemoryStorage ABC ─────────────────────────────────────────────────
    def load(self, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
        data, revision = self._get_raw()
        self._revision = revision
        return normalize_to_deerflow_shape(data)

    def reload(self, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
        return self.load(agent_name, user_id=user_id)

    def save(
        self,
        memory_data: dict[str, Any],
        agent_name: str | None = None,
        *,
        user_id: str | None = None,
        expected_revision: int | None = None,
    ) -> bool:
        if not isinstance(memory_data, dict):
            raise ValueError("memory_data must be an object")
        try:
            self._put(memory_data, expected_revision)
        except MemoryManifestRevisionConflict:
            # Same contract FileMemoryStorage exposes: revision conflicts are
            # re-raised so callers that retry-on-conflict can see them.
            raise
        except MemoryStorageCorruption as exc:
            logger.error("matter memory save failed: %s", exc)
            return False
        return True

    # ── Delta path used by DeerMem's updater ──────────────────────────────
    def apply_changes(
        self,
        change_set: dict[str, Any],
        agent_name: str | None = None,
        *,
        user_id: str | None = None,
        expected_manifest_revision: int | None = None,
    ) -> dict[str, Any]:
        raw, current_revision = self._get_raw()
        expected = expected_manifest_revision
        if expected is None:
            expected = current_revision
        if int(expected) != current_revision:
            self._revision = None
            raise MemoryManifestRevisionConflict(
                f"matter memory manifest at revision {current_revision}, caller expected {expected}"
            )

        change_set = change_set or {}
        if not (change_set.get("upserts") or change_set.get("deletes") or change_set.get("summaries")):
            # Nothing to commit. Writing anyway would bump the server-side
            # revision and invalidate every other writer's If-Match for no reason.
            self._revision = current_revision
            return normalize_to_deerflow_shape(raw)

        doc = normalize_to_deerflow_shape(raw)
        facts = doc.get("facts", [])
        by_id = {str(f.get("id")): f for f in facts if isinstance(f, dict) and f.get("id") is not None}

        upserts = change_set.get("upserts") or []
        upsert_revisions = change_set.get("upsertRevisions") or {}
        deletes = [str(x) for x in (change_set.get("deletes") or [])]
        delete_revisions = change_set.get("deleteRevisions") or {}

        # Per-fact revision check. Any mismatch => stale caller; treat as a
        # manifest-level conflict so the updater reloads and reapplies.
        for fact_id, expected_fact_rev in upsert_revisions.items():
            if expected_fact_rev is None:
                continue
            current = by_id.get(str(fact_id))
            if current is None:
                continue  # insert, not an update
            if int(current.get("revision") or 1) != int(expected_fact_rev):
                raise MemoryManifestRevisionConflict(
                    f"fact {fact_id} at revision {current.get('revision')}, caller expected {expected_fact_rev}"
                )
        for fact_id, expected_fact_rev in delete_revisions.items():
            current = by_id.get(str(fact_id))
            if current is None:
                continue  # already gone; delete is idempotent
            if expected_fact_rev is None:
                continue
            if int(current.get("revision") or 1) != int(expected_fact_rev):
                raise MemoryManifestRevisionConflict(
                    f"fact {fact_id} at revision {current.get('revision')}, caller expected {expected_fact_rev}"
                )

        new_revision = current_revision + 1
        for fact in upserts:
            if not isinstance(fact, dict):
                continue
            merged = dict(fact)
            merged["revision"] = new_revision
            fid = str(merged.get("id") or "")
            if not fid:
                merged["id"] = fid = f"fact_{new_revision}_{len(by_id)}"
            by_id[fid] = merged
        for fact_id in deletes:
            by_id.pop(fact_id, None)

        doc["facts"] = list(by_id.values())
        doc["revision"] = new_revision
        doc["lastUpdated"] = utc_now_iso_z()

        summaries = change_set.get("summaries")
        if isinstance(summaries, dict):
            if isinstance(summaries.get("user"), dict):
                doc["user"] = summaries["user"]
            if isinstance(summaries.get("history"), dict):
                doc["history"] = summaries["history"]

        saved = self._put(doc, current_revision)
        return normalize_to_deerflow_shape(saved)

    def clear_all(self, *, user_id: str | None = None) -> dict[str, Any]:
        _, current_revision = self._get_raw()
        empty = create_empty_memory()
        saved = self._put(empty, current_revision)
        return normalize_to_deerflow_shape(saved)

    # ── Optional fact accessors (fact CRUD tools) ────────────────────────
    def get_fact(self, fact_id: str, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any] | None:
        doc = self.load(agent_name, user_id=user_id)
        for fact in doc.get("facts", []):
            if str(fact.get("id")) == str(fact_id):
                return fact
        return None

    def list_facts(self, agent_name: str | None = None, *, user_id: str | None = None) -> list[dict[str, Any]]:
        return list(self.load(agent_name, user_id=user_id).get("facts", []))

    def close(self) -> None:
        try:
            self.client._client.close()
        except Exception:  # pragma: no cover - best effort
            pass
