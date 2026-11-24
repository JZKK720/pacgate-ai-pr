"""Shared deer-flow module stubs for the adapter unit tests.

Both adapter test modules import the adapter, which imports ``deerflow.*``.
deer-flow is not pip-installable here, so the tests install in-memory stub
modules. Everything needed by either the v2.0 layout (``deerflow.agents.memory.storage``)
or the v2.2.0 layout (``deerflow.agents.memory.backends.deermem.deermem.core.storage``)
is installed here so the two test modules cannot fight over partially-configured
stubs.
"""

from __future__ import annotations

import sys
import types
from datetime import UTC, datetime


def _pkg(name: str) -> types.ModuleType:
    mod = types.ModuleType(name)
    mod.__path__ = []  # type: ignore[attr-defined]
    mod.__package__ = name
    return mod


def utc_now_iso_z() -> str:
    return datetime.now(UTC).isoformat().removesuffix("+00:00") + "Z"


def create_empty_memory() -> dict:
    return {
        "version": "1.0",
        "revision": 0,
        "lastUpdated": utc_now_iso_z(),
        "user": {
            "workContext": {"summary": "", "updatedAt": ""},
            "personalContext": {"summary": "", "updatedAt": ""},
            "topOfMind": {"summary": "", "updatedAt": ""},
            "cognitiveStyle": {"summary": "", "updatedAt": ""},
        },
        "history": {
            "recentMonths": {"summary": "", "updatedAt": ""},
            "earlierContext": {"summary": "", "updatedAt": ""},
            "longTermBackground": {"summary": "", "updatedAt": ""},
        },
        "facts": [],
    }


class MemoryStorageError(RuntimeError):
    pass


class MemoryStorageCorruption(MemoryStorageError):
    pass


class MemoryRevisionConflict(MemoryStorageError):
    pass


class MemoryManifestRevisionConflict(MemoryRevisionConflict):
    pass


class MemoryFactRevisionConflict(MemoryRevisionConflict):
    pass


class MemoryStorage:
    pass


class V2MemoryStorage:
    """Stand-in for the v2.0 `MemoryStorage` base class."""


def install() -> None:
    if "deerflow" in sys.modules:
        return

    deerflow = _pkg("deerflow")
    agents = _pkg("deerflow.agents")
    memory = _pkg("deerflow.agents.memory")

    # ── v2.0 layout: deerflow.agents.memory.storage ───────────────────────
    v2_storage = types.ModuleType("deerflow.agents.memory.storage")
    v2_storage.MemoryStorage = V2MemoryStorage
    v2_storage.utc_now_iso_z = utc_now_iso_z

    # ── v2.2.0 layout: ...backends.deermem.deermem.core.storage ───────────
    backends = _pkg("deerflow.agents.memory.backends")
    deermem_pkg = _pkg("deerflow.agents.memory.backends.deermem")
    inner = _pkg("deerflow.agents.memory.backends.deermem.deermem")
    core = _pkg("deerflow.agents.memory.backends.deermem.deermem.core")
    v22_storage = types.ModuleType("deerflow.agents.memory.backends.deermem.deermem.core.storage")
    v22_storage.MemoryStorage = MemoryStorage
    v22_storage.MemoryStorageError = MemoryStorageError
    v22_storage.MemoryStorageCorruption = MemoryStorageCorruption
    v22_storage.MemoryRevisionConflict = MemoryRevisionConflict
    v22_storage.MemoryManifestRevisionConflict = MemoryManifestRevisionConflict
    v22_storage.MemoryFactRevisionConflict = MemoryFactRevisionConflict
    v22_storage.create_empty_memory = create_empty_memory
    v22_storage.utc_now_iso_z = utc_now_iso_z
    core.storage = v22_storage

    memory.storage = v2_storage
    memory.backends = backends
    backends.deermem = deermem_pkg
    deermem_pkg.deermem = inner
    inner.core = core
    agents.memory = memory
    deerflow.agents = agents

    for name, mod in [
        ("deerflow", deerflow),
        ("deerflow.agents", agents),
        ("deerflow.agents.memory", memory),
        ("deerflow.agents.memory.storage", v2_storage),
        ("deerflow.agents.memory.backends", backends),
        ("deerflow.agents.memory.backends.deermem", deermem_pkg),
        ("deerflow.agents.memory.backends.deermem.deermem", inner),
        ("deerflow.agents.memory.backends.deermem.deermem.core", core),
        ("deerflow.agents.memory.backends.deermem.deermem.core.storage", v22_storage),
    ]:
        sys.modules[name] = mod
