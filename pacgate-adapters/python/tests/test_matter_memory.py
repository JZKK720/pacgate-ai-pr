"""Contract tests for PacgateMatterMemoryStorage (deer-flow v2.2.0 contract).

pytest is not assumed; run with:

    python -m unittest discover -s pacgate-adapters/python/tests -v
"""

import copy
import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

def _httpx_missing():
    try:
        return importlib.util.find_spec("httpx") is None
    except (ImportError, ValueError):
        return True

if _httpx_missing():
    _httpx_stub = types.ModuleType("httpx")
    _httpx_stub.HTTPError = type("HTTPError", (Exception,), {})
    _httpx_stub.Response = type("Response", (), {})
    _httpx_stub.Client = type(
        "Client",
        (),
        {
            "__init__": lambda self, *a, **k: None,
            "get": lambda self, *a, **k: MagicMock(),
            "post": lambda self, *a, **k: MagicMock(),
            "put": lambda self, *a, **k: MagicMock(),
            "delete": lambda self, *a, **k: MagicMock(),
        },
    )
    sys.modules.setdefault("httpx", _httpx_stub)

# Stub the deer-flow v2.2.0 memory storage module the adapter imports from.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _deerflow_stubs  # noqa: E402

_deerflow_stubs.install()

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pacgate_deerflow_adapter import matter_memory  # noqa: E402
from pacgate_deerflow_adapter.matter_memory import (  # noqa: E402
    MatterMemoryOutOfScope,
    PacgateMatterMemoryStorage,
)


def _response(status: int, body):
    resp = MagicMock()
    resp.status_code = status
    resp.text = body if isinstance(body, str) else __import__("json").dumps(body)
    resp.json.return_value = body
    if status >= 400:
        resp.raise_for_status.side_effect = Exception(f"HTTP {status}")
    else:
        resp.raise_for_status.return_value = None
    return resp


def _make_storage(get_body, get_status=200, post_body=None, post_status=200):
    with patch.dict("os.environ", {"PACGATE_MATTER_ID": "matter-123"}, clear=False):
        storage = PacgateMatterMemoryStorage()
    storage.client = MagicMock()
    storage.client.get.return_value = _response(get_status, get_body)
    if post_body is not None or post_status != 200:
        storage.client.post.return_value = _response(post_status, post_body if post_body is not None else {})
    return storage


LEGACY_DOC = {
    "version": "2.0",
    "revision": 3,
    "lastUpdated": "2026-11-20T00:00:00Z",
    "content": "Client prefers email updates on Fridays.",
    "tags": ["process"],
}

FULL_DOC = {
    "version": "1.0",
    "revision": 7,
    "lastUpdated": "2026-11-20T00:00:00Z",
    "user": {
        "workContext": {"summary": "M&A practice", "updatedAt": "2026-11-20T00:00:00Z"},
        "personalContext": {"summary": "", "updatedAt": ""},
        "topOfMind": {"summary": "closing docs", "updatedAt": "2026-11-20T00:00:00Z"},
        "cognitiveStyle": {"summary": "", "updatedAt": ""},
    },
    "history": {
        "recentMonths": {"summary": "", "updatedAt": ""},
        "earlierContext": {"summary": "", "updatedAt": ""},
        "longTermBackground": {"summary": "", "updatedAt": ""},
    },
    "facts": [
        {"id": "fact_a", "content": "Prefers email", "category": "preference",
         "confidence": 0.9, "revision": 7, "source": "conversation"},
    ],
}


class NormalizeTests(unittest.TestCase):
    def test_legacy_document_maps_content_to_top_of_mind(self):
        doc = matter_memory.normalize_to_deerflow_shape(LEGACY_DOC)
        self.assertEqual(doc["user"]["topOfMind"]["summary"], LEGACY_DOC["content"])
        self.assertEqual(doc["revision"], 3)
        self.assertEqual(doc["facts"], [])
        self.assertTrue(doc["lastUpdated"])

    def test_full_document_is_preserved(self):
        doc = matter_memory.normalize_to_deerflow_shape(FULL_DOC)
        self.assertEqual(doc["user"]["workContext"]["summary"], "M&A practice")
        self.assertEqual(doc["revision"], 7)
        self.assertEqual(doc["facts"][0]["id"], "fact_a")

    def test_empty_last_updated_is_never_emitted(self):
        doc = matter_memory.normalize_to_deerflow_shape({"user": {}, "lastUpdated": ""})
        self.assertNotEqual(doc["lastUpdated"], "")

    def test_non_dict_input_yields_empty_document(self):
        doc = matter_memory.normalize_to_deerflow_shape("not a dict")
        self.assertEqual(doc["facts"], [])
        self.assertTrue(doc["lastUpdated"])


class LoadTests(unittest.TestCase):
    def test_load_returns_normalized_document_and_records_revision(self):
        storage = _make_storage(LEGACY_DOC)
        doc = storage.load()
        self.assertEqual(storage._revision, 3)
        self.assertEqual(doc["user"]["topOfMind"]["summary"], LEGACY_DOC["content"])

    def test_load_raises_corruption_on_http_error(self):
        storage = _make_storage({}, get_status=500)
        with self.assertRaises(_deerflow_stubs.MemoryStorageCorruption):
            storage.load()

    def test_missing_matter_id_fails_fast(self):
        env = {k: v for k, v in __import__("os").environ.items() if k != "PACGATE_MATTER_ID"}
        with patch.dict("os.environ", env, clear=True):
            with self.assertRaises(ValueError):
                PacgateMatterMemoryStorage()


class SaveTests(unittest.TestCase):
    def test_save_sends_if_match_with_known_revision(self):
        storage = _make_storage(FULL_DOC, post_body={**FULL_DOC, "revision": 8})
        storage.load()
        self.assertTrue(storage.save(FULL_DOC))
        _, kwargs = storage.client.post.call_args
        self.assertEqual(kwargs["headers"]["If-Match"], "7")
        self.assertEqual(storage._revision, 8)

    def test_save_without_prior_load_omits_if_match(self):
        storage = _make_storage(FULL_DOC, post_body={**FULL_DOC, "revision": 1})
        self.assertTrue(storage.save(FULL_DOC))
        _, kwargs = storage.client.post.call_args
        self.assertNotIn("If-Match", kwargs["headers"])

    def test_409_raises_manifest_conflict_and_clears_revision(self):
        storage = _make_storage(FULL_DOC, post_status=409, post_body={"error": "mismatch"})
        storage.load()
        with self.assertRaises(_deerflow_stubs.MemoryManifestRevisionConflict):
            storage.save(FULL_DOC)
        self.assertIsNone(storage._revision)

    def test_422_raises_out_of_scope_not_conflict(self):
        storage = _make_storage(FULL_DOC, post_status=422, post_body={"error": "identifier"})
        storage.load()
        with self.assertRaises(MatterMemoryOutOfScope):
            storage.save(FULL_DOC)

    def test_5xx_returns_false_instead_of_raising(self):
        storage = _make_storage(FULL_DOC, post_status=500, post_body="boom")
        storage.load()
        self.assertFalse(storage.save(FULL_DOC))


class ApplyChangesTests(unittest.TestCase):
    def _storage_with_fact(self):
        body = copy.deepcopy(FULL_DOC)
        return _make_storage(body, post_body={**body, "revision": 8})

    def test_upsert_inserts_new_fact(self):
        storage = self._storage_with_fact()
        result = storage.apply_changes(
            {"upserts": [{"id": "fact_b", "content": "new fact", "category": "context"}],
             "upsertRevisions": {"fact_b": None}},
            agent_name="lead",
        )
        posted = storage.client.post.call_args.kwargs["json"]
        ids = [f["id"] for f in posted["facts"]]
        self.assertIn("fact_b", ids)
        self.assertIn("fact_a", ids)
        self.assertEqual(posted["revision"], 8)
        self.assertEqual(result["revision"], 8)

    def test_upsert_with_stale_fact_revision_conflicts(self):
        storage = self._storage_with_fact()
        with self.assertRaises(_deerflow_stubs.MemoryManifestRevisionConflict):
            storage.apply_changes(
                {"upserts": [{"id": "fact_a", "content": "changed"}],
                 "upsertRevisions": {"fact_a": 999}},
                agent_name="lead",
            )

    def test_expected_manifest_revision_mismatch_conflicts(self):
        storage = self._storage_with_fact()
        with self.assertRaises(_deerflow_stubs.MemoryManifestRevisionConflict):
            storage.apply_changes({"upserts": []}, agent_name="lead",
                                  expected_manifest_revision=1)

    def test_delete_removes_fact_and_is_idempotent_when_absent(self):
        storage = self._storage_with_fact()
        storage.apply_changes({"deletes": ["fact_a", "fact_missing"],
                               "deleteRevisions": {"fact_a": 7}},
                              agent_name="lead")
        posted = storage.client.post.call_args.kwargs["json"]
        self.assertEqual([f["id"] for f in posted["facts"]], [])

    def test_stale_delete_revision_conflicts(self):
        storage = self._storage_with_fact()
        with self.assertRaises(_deerflow_stubs.MemoryManifestRevisionConflict):
            storage.apply_changes({"deletes": ["fact_a"], "deleteRevisions": {"fact_a": 6}},
                                  agent_name="lead")

    def test_summaries_are_replaced(self):
        storage = self._storage_with_fact()
        storage.apply_changes(
            {"summaries": {"user": {"topOfMind": {"summary": "x", "updatedAt": "t"}}}},
            agent_name="lead",
        )
        posted = storage.client.post.call_args.kwargs["json"]
        self.assertEqual(posted["user"]["topOfMind"]["summary"], "x")

    def test_if_match_header_sent(self):
        storage = self._storage_with_fact()
        storage.apply_changes(
            {"upserts": [{"id": "fact_b", "content": "new fact", "category": "context"}],
             "upsertRevisions": {"fact_b": None}},
            agent_name="lead",
        )
        self.assertEqual(storage.client.post.call_args.kwargs["headers"]["If-Match"], "7")

    def test_empty_change_set_writes_nothing(self):
        storage = self._storage_with_fact()
        storage.client.post.reset_mock()
        result = storage.apply_changes({"upserts": []}, agent_name="lead")
        storage.client.post.assert_not_called()
        self.assertEqual(result["revision"], 7)


class ClearAllTests(unittest.TestCase):
    def test_clear_all_writes_empty_document(self):
        storage = _make_storage(FULL_DOC, post_body={"revision": 9, "facts": []})
        storage.clear_all()
        posted = storage.client.post.call_args.kwargs["json"]
        self.assertEqual(posted["facts"], [])
        self.assertEqual(posted["user"]["topOfMind"]["summary"], "")


if __name__ == "__main__":
    unittest.main()


