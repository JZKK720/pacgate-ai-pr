from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("pacgate_qm.py")
SPEC = importlib.util.spec_from_file_location("pacgate_qm", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load module spec for {MODULE_PATH}")

pacgate_qm = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pacgate_qm
SPEC.loader.exec_module(pacgate_qm)


class PacgateQmToolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = pacgate_qm.RuntimeConfig(
            api_url="http://pacgate-api:8080", token="test-token"
        )

    def test_ensure_matter_reuses_existing_channel_binding(self) -> None:
        calls: list[tuple[str, str, object | None]] = []

        def requestor(config, method, path, token, payload=None):
            calls.append((method, path, payload))
            self.assertEqual(config.api_url, "http://pacgate-api:8080")
            self.assertEqual(token, "test-token")
            if method == "GET" and path == "/api/matters":
                return [
                    {
                        "id": "matter-1",
                        "name": "Channel Alpha",
                        "description": "Linked QM scope",
                        "external_key": "chan-123",
                    }
                ]
            raise AssertionError(f"Unexpected request: {method} {path}")

        scope = pacgate_qm.ScopeContext(
            org_id="pacgate",
            channel_id="chan-123",
            channel_name="Channel Alpha",
        )

        matter = pacgate_qm.ensure_matter_for_scope(
            self.config, scope, requestor=requestor
        )

        self.assertEqual("matter-1", matter["id"])
        self.assertEqual([("GET", "/api/matters", None)], calls)

    def test_ensure_matter_creates_when_binding_is_missing(self) -> None:
        calls: list[tuple[str, str, object | None]] = []

        def requestor(config, method, path, token, payload=None):
            calls.append((method, path, payload))
            if method == "GET" and path == "/api/matters":
                return []
            if method == "POST" and path == "/api/matters":
                return {
                    "id": "matter-2",
                    "name": payload["name"],
                    "description": payload["description"],
                    "external_key": payload.get("external_key"),
                    "persona_id": payload.get("persona_id"),
                }
            raise AssertionError(f"Unexpected request: {method} {path}")

        scope = pacgate_qm.ScopeContext(
            org_id="pacgate",
            channel_id="chan-456",
            channel_name="Private Equity - Diligence",
            team_id="team-9",
            personal_user_id="user-7",
            personal_email="lawyer@example.com",
        )

        matter = pacgate_qm.ensure_matter_for_scope(
            self.config,
            scope,
            persona_id="persona-22",
            description="Use this matter for QM collaboration.",
            requestor=requestor,
        )

        self.assertEqual("matter-2", matter["id"])
        self.assertEqual(
            [
                ("GET", "/api/matters", None),
                (
                    "POST",
                    "/api/matters",
                    {
                        "name": "Private Equity - Diligence",
                        "description": (
                            "Linked QM scope\n"
                            "qm.orgId=pacgate\n"
                            "qm.channelId=chan-456\n"
                            "qm.teamId=team-9\n"
                            "qm.personalUserId=user-7\n"
                            "qm.personalEmail=lawyer@example.com\n\n"
                            "Use this matter for QM collaboration."
                        ),
                        "external_key": "chan-456",
                        "persona_id": "persona-22",
                    },
                ),
            ],
            calls,
        )

    def test_execute_workflow_uses_resolved_matter_id(self) -> None:
        calls: list[tuple[str, str, object | None]] = []

        def requestor(config, method, path, token, payload=None):
            calls.append((method, path, payload))
            if method == "GET" and path == "/api/matters":
                return [
                    {
                        "id": "matter-9",
                        "name": "QM Channel chan-999",
                        "description": "Linked QM scope",
                        "external_key": "chan-999",
                    }
                ]
            if method == "POST" and path == "/api/workflows/workflow-77/execute":
                return {
                    "workflow_name": "Contract Review",
                    "steps": [],
                    "final_content": "done",
                }
            raise AssertionError(f"Unexpected request: {method} {path}")

        scope = pacgate_qm.ScopeContext(org_id="pacgate", channel_id="chan-999")
        response = pacgate_qm.execute_workflow_for_scope(
            self.config,
            scope,
            workflow_id="workflow-77",
            persona_id="persona-99",
            requestor=requestor,
        )

        self.assertEqual("Contract Review", response["workflow_name"])
        self.assertEqual(
            [
                ("GET", "/api/matters", None),
                (
                    "POST",
                    "/api/workflows/workflow-77/execute",
                    {"matter_id": "matter-9", "persona_id": "persona-99"},
                ),
            ],
            calls,
        )


if __name__ == "__main__":
    unittest.main()
