"""HTTP client for pacgate-api — thin wrapper around httpx.

Pacgate patch 2026-10-09: re-login on 401.

Root cause (verified 2026-10-09): the client logs in once at construction and
caches the JWT for the process lifetime. pacgate-api restarts (upgrades,
recreates) invalidate the token, so every subsequent memory/artifact call
returns 401 until deer-flow itself is restarted. deer-flow runs for days, so
this surfaced as "Memory update failed: 401 Unauthorized" in the logs after
every pacgate-api restart.

Fix: on a 401 response, if we hold email/password credentials, re-login once
and retry the request. A genuinely-bad credential re-fails with the original
401 (login raises), so there is no retry loop.
"""

import os
from typing import Any

import httpx


class PacgateApiClient:
    """Thin HTTP client for pacgate-api endpoints."""

    def __init__(
        self,
        base_url: str | None = None,
        jwt_token: str | None = None,
        tenant_id: str | None = None,
        email: str | None = None,
        password: str | None = None,
    ):
        self.base_url = (
            base_url or os.environ.get("PACGATE_API_URL", "http://pacgate-api:8080")
        ).rstrip("/")
        self.jwt_token = jwt_token or os.environ.get("PACGATE_JWT_TOKEN", "")
        self.tenant_id = tenant_id or os.environ.get(
            "PACGATE_TENANT_ID", "default-firm"
        )
        self.email = email or os.environ.get("PACGATE_API_EMAIL", "")
        self.password = password or os.environ.get("PACGATE_API_PASSWORD", "")
        self._client = httpx.Client(timeout=30.0)

        if not self.jwt_token and self.email and self.password:
            self.jwt_token = self.login(self.email, self.password)

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.jwt_token:
            headers["Authorization"] = f"Bearer {self.jwt_token}"
        return headers

    def _relogin_if_401(self, resp: httpx.Response) -> httpx.Response | None:
        """On 401 with email/password credentials, re-login once and signal retry.

        Returns the original response when no retry is possible; returns None
        after a successful re-login so callers re-send the request.
        """
        if resp.status_code != 401 or not (self.email and self.password):
            return resp
        self.jwt_token = self.login(self.email, self.password)
        return None

    def get(self, path: str, headers: dict[str, str] | None = None) -> httpx.Response:
        merged = {**self._headers(), **(headers or {})}
        resp = self._client.get(f"{self.base_url}{path}", headers=merged)
        if self._relogin_if_401(resp) is None:
            return self.get(path, headers=headers)
        return resp

    def login(self, email: str, password: str) -> str:
        resp = self._client.post(
            f"{self.base_url}/api/auth/login",
            json={"email": email, "password": password},
            headers={"Content-Type": "application/json"},
        )
        resp.raise_for_status()
        token = resp.json().get("token", "")
        if not token:
            raise ValueError("pacgate-api login did not return a token")
        return token

    def post(
        self,
        path: str,
        json: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> httpx.Response:
        # headers: extra per-call headers (e.g. If-Match from the memory
        # adapter's revision guard), merged OVER the auth/Content-Type base.
        # Missing this kwarg made every PacgateMemoryStorage.save() raise
        # TypeError and silently fail the whole memory update.
        merged = {**self._headers(), **(headers or {})}
        resp = self._client.post(f"{self.base_url}{path}", json=json, headers=merged)
        if self._relogin_if_401(resp) is None:
            return self.post(path, json=json, headers=headers)
        return resp

    def put(
        self,
        path: str,
        json: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> httpx.Response:
        merged = {**self._headers(), **(headers or {})}
        resp = self._client.put(f"{self.base_url}{path}", json=json, headers=merged)
        if self._relogin_if_401(resp) is None:
            return self.put(path, json=json, headers=headers)
        return resp

    def delete(self, path: str) -> httpx.Response:
        resp = self._client.delete(f"{self.base_url}{path}", headers=self._headers())
        if self._relogin_if_401(resp) is None:
            return self.delete(path)
        return resp

    def upload(self, path: str, file_path: str, matter_id: str) -> httpx.Response:
        """Upload a file to pacgate-api."""
        with open(file_path, "rb") as f:
            files = {"file": (file_path, f)}
            headers = (
                {"Authorization": f"Bearer {self.jwt_token}"} if self.jwt_token else {}
            )
            resp = self._client.post(
                f"{self.base_url}{path}",
                files=files,
                data={"matter_id": matter_id},
                headers=headers,
            )
            if self._relogin_if_401(resp) is None:
                return self.upload(path, file_path, matter_id)
            return resp