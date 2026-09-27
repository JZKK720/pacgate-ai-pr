"""Revision handling in PacgateMemoryStorage.

pytest is not installed in this repo's venv, so this file is written to be
runnable with plain unittest:

    python -m unittest discover -s pacgate-adapters/python/tests -v
"""

import sys
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# The adapter imports deerflow, which is a dependency of the deer-flow runtime,
# not of this repo's venv. Stub it before import so the storage class's
# inheritance resolves. This is a test-only shim: production runs inside the
# deer-flow image where the real module exists.
_stubs: dict[str, types.ModuleType] = {}


def _ensure_stub(name: str) -> types.ModuleType:
    if name in sys.modules:
        return sys.modules[name]
    mod = types.ModuleType(name)
    mod.__path__: list[str] = []
    sys.modules[name] = mod
    _stubs.setdefault(name, mod)
    return mod


_memory_storage = _ensure_stub("deerflow.agents.memory.storage")


class _MemoryStorage:  # pragma: no cover - structural stub
    pass


_memory_storage.MemoryStorage = _MemoryStorage

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pacgate_deerflow_adapter.storage import (  # noqa: E402
    MatterMemoryConflict,
    MatterMemoryOutOfScope,
    PacgateMemoryStorage,
)


class RevisionTrackingTests(unittest.TestCase):
    def _storage(self):
        with patch.dict(
            "os.environ",
            {"PACGATE_MATTER_ID": "11111111-1111-1111-1111-111111111111"},
        ):
            storage = PacgateMemoryStorage.__new__(PacgateMemoryStorage)
            storage.client = MagicMock()
            storage.matter_id = "11111111-1111-1111-1111-111111111111"
            storage._revision = None
            return storage

    def test_load_records_the_revision_it_read(self):
        storage = self._storage()
        response = MagicMock()
        response.json.return_value = {"revision": 4, "facts": []}
        storage.client.get.return_value = response

        storage.load()

        self.assertEqual(storage._revision, 4)

    def test_load_treats_a_missing_revision_as_zero(self):
        storage = self._storage()
        response = MagicMock()
        response.json.return_value = {"facts": []}
        storage.client.get.return_value = response

        storage.load()

        self.assertEqual(storage._revision, 0)

    def test_save_sends_if_match_when_a_revision_is_known(self):
        storage = self._storage()
        storage._revision = 4
        response = MagicMock()
        response.status_code = 200
        storage.client.post.return_value = response

        storage.save({"facts": []})

        _, kwargs = storage.client.post.call_args
        self.assertEqual(kwargs["headers"]["If-Match"], "4")

    def test_save_without_a_known_revision_sends_no_if_match(self):
        storage = self._storage()
        response = MagicMock()
        response.status_code = 200
        storage.client.post.return_value = response

        storage.save({"facts": []})

        _, kwargs = storage.client.post.call_args
        self.assertNotIn("If-Match", kwargs["headers"])

    def test_a_409_raises_matter_memory_conflict_and_is_not_swallowed(self):
        storage = self._storage()
        storage._revision = 4
        response = MagicMock()
        response.status_code = 409
        response.text = "revision mismatch"
        storage.client.post.return_value = response

        with self.assertRaises(MatterMemoryConflict):
            storage.save({"facts": []})

    def test_a_conflict_clears_the_remembered_revision(self):
        # After a conflict the local view is known-stale, so the next save
        # must not replay the bad revision.
        storage = self._storage()
        storage._revision = 4
        response = MagicMock()
        response.status_code = 409
        response.text = "revision mismatch"
        storage.client.post.return_value = response

        with self.assertRaises(MatterMemoryConflict):
            storage.save({"facts": []})

        self.assertIsNone(storage._revision)

    def test_a_422_raises_out_of_scope_and_is_distinct_from_a_conflict(self):
        # The two must NOT be collapsed: a 409 means "reload and retry", a 422
        # means "this content can never be accepted". A caller that treated them
        # alike would spin retrying a payload the server will always refuse.
        storage = self._storage()
        response = MagicMock()
        response.status_code = 422
        response.text = "memory may hold process, not matter facts"
        storage.client.post.return_value = response

        with self.assertRaises(MatterMemoryOutOfScope):
            storage.save({"facts": [{"content": "Client ID 11010519491231002X"}]})

    def test_an_out_of_scope_write_does_not_clear_the_revision(self):
        # Unlike a conflict, the revision is still valid - the refusal was about
        # CONTENT. Clearing it would force a pointless reload on the next write.
        storage = self._storage()
        storage._revision = 4
        response = MagicMock()
        response.status_code = 422
        response.text = "out of scope"
        storage.client.post.return_value = response

        with self.assertRaises(MatterMemoryOutOfScope):
            storage.save({"facts": []})

        self.assertEqual(storage._revision, 4)


if __name__ == "__main__":
    unittest.main()