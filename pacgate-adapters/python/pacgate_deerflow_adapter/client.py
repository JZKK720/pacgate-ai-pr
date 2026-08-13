"""HTTP client for pacgate-api — thin wrapper around httpx."""

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
    ):
        self.base_url = (base_url or os.environ.get("PACGATE_API_URL", "http://pacgate-api:8080")).rstrip("/")
        self.jwt_token = jwt_token or os.environ.get("PACGATE_JWT_TOKEN", "")
        self.tenant_id = tenant_id or os.environ.get("PACGATE_TENANT_ID", "default-firm")
        self._client = httpx.Client(timeout=30.0)

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.jwt_token:
            headers["Authorization"] = f"Bearer {self.jwt_token}"
        return headers

    def get(self, path: str) -> httpx.Response:
        return self._client.get(f"{self.base_url}{path}", headers=self._headers())

    def post(self, path: str, json: dict[str, Any] | None = None) -> httpx.Response:
        return self._client.post(f"{self.base_url}{path}", json=json, headers=self._headers())

    def put(self, path: str, json: dict[str, Any] | None = None) -> httpx.Response:
        return self._client.put(f"{self.base_url}{path}", json=json, headers=self._headers())

    def delete(self, path: str) -> httpx.Response:
        return self._client.delete(f"{self.base_url}{path}", headers=self._headers())

    def upload(self, path: str, file_path: str, matter_id: str) -> httpx.Response:
        """Upload a file to pacgate-api."""
        with open(file_path, "rb") as f:
            files = {"file": (file_path, f)}
            headers = {"Authorization": f"Bearer {self.jwt_token}"} if self.jwt_token else {}
            return self._client.post(
                f"{self.base_url}{path}",
                files=files,
                data={"matter_id": matter_id},
                headers=headers,
            )