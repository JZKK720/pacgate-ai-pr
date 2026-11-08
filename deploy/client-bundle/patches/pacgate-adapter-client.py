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
        """Legacy helper, kept for callers outside this class.

        Prefer :meth:`_request`, which bounds the retry. This method on its own
        performs a login and returns None to mean "retry", and a caller that
        recurses on None can loop forever - that was the 2026-11-05 defect.
        """
        if resp.status_code != 401 or not (self.email and self.password):
            return resp
        self.jwt_token = self.login(self.email, self.password)
        return None

    def _request(
        self,
        method: str,
        path: str,
        *,
        json: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
        files: dict[str, Any] | None = None,
        data: dict[str, Any] | None = None,
    ) -> httpx.Response:
        """Send a request, re-authenticating AT MOST ONCE on 401.

        MEASURED 2026-11-05: the per-method retry used to be unbounded recursion -

            if self._relogin_if_401(resp) is None:
                return self.get(path, headers=headers)

        and every recursive call got a FRESH login+retry, so the docstring's
        "once" held only if the retried request happened to return non-401. A
        stub answering 401 while login keeps succeeding ran 997 logins and 998
        GETs before RecursionError. That is reachable, not hypothetical: an
        account that can authenticate but not authorise (login 200, every matter
        call 401) turns the first memory update into a login storm.

        `retried` is local to ONE call: one login, one retry, then the 401 is
        returned for the caller to surface. `login()` raises on bad credentials,
        so a genuinely-bad login fails immediately and never reaches the retry.
        """
        for attempt in range(2):
            merged = {**self._headers(), **(headers or {})}
            resp = self._client.request(
                method,
                f"{self.base_url}{path}",
                json=json,
                headers=merged,
                files=files,
                data=data,
            )
            if attempt:
                return resp
            if resp.status_code != 401 or not (self.email and self.password):
                return resp
            self.jwt_token = self.login(self.email, self.password)

        return resp

    def get(self, path: str, headers: dict[str, str] | None = None) -> httpx.Response:
        return self._request("GET", path, headers=headers)

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
        return self._request("POST", path, json=json, headers=headers)

    def put(
        self,
        path: str,
        json: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> httpx.Response:
        return self._request("PUT", path, json=json, headers=headers)

    def delete(self, path: str) -> httpx.Response:
        return self._request("DELETE", path)

    def upload(self, path: str, file_path: str, matter_id: str) -> httpx.Response:
        """Upload a file to pacgate-api.

        The file is re-opened per attempt on purpose: re-sending an already
        consumed handle uploads zero bytes, which reads as a silent data loss.
        """
        with open(file_path, "rb") as f:
            return self._request(
                "POST", path, files={"file": (file_path, f)}, data={"matter_id": matter_id}
            )
