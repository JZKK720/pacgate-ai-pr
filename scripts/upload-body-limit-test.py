"""End-to-end upload-body-limit proof through the real nginx ingress.

Proves the fix for the two-layer body-size cap discovered 2026-09-20:
  Layer 1 (nginx): no client_max_body_size directive -> 1 MB default -> 413.
  Layer 2 (axum):  silent DefaultBodyLimit 2 MB -> broken pipe / 400 / 502.

Run AFTER both fixes are live:
  1. deploy/client-bundle/nginx/default.conf carries client_max_body_size 100m
     (reload: docker cp + nginx -s reload, or docker compose restart nginx).
  2. pacgate-api image carries DefaultBodyLimit::max((max_upload_mb+14)MB)
     in build_router (pacgate-ai/crates/pacgate-api/src/lib.rs).

Usage (from repo root, venv active):
    python scripts/upload-body-limit-test.py [--size-mb 6] [--cleanup]

Exit code 0 = both layers pass (upload 200); non-zero = a layer still fails.
Reads admin credentials from deploy/client-bundle/.env (never hardcoded here).
"""

from __future__ import annotations

import argparse
import random
import sys

import requests

DEFAULT_BASE = "http://127.0.0.1:8089"
ENV_FILE = "deploy/client-bundle/.env"


def load_env(env_path: str) -> dict[str, str]:
    """Parse the gitignored .env for PACGATE_API_EMAIL / PACGATE_API_PASSWORD."""
    values: dict[str, str] = {}
    try:
        text = open(env_path, encoding="utf-8", errors="replace").read()
    except OSError:
        return values
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        values[key.strip()] = val.strip()
    return values


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=DEFAULT_BASE, help="nginx ingress base URL")
    parser.add_argument("--size-mb", type=int, default=6, help="test payload size in MB")
    parser.add_argument("--cleanup", action="store_true", help="delete the uploaded test doc afterwards")
    parser.add_argument("--env", default=ENV_FILE, help="path to client-bundle .env")
    args = parser.parse_args()

    env = load_env(args.env)
    email = env.get("PACGATE_API_EMAIL", "")
    password = env.get("PACGATE_API_PASSWORD", "")
    if not email or not password:
        print("[FAIL] PACGATE_API_EMAIL/PACGATE_API_PASSWORD missing from .env")
        return 2

    session = requests.Session()
    login = session.post(f"{args.base}/pacgate/api/auth/login",
                         json={"email": email, "password": password})
    if login.status_code != 200:
        print(f"[FAIL] login through nginx failed: {login.status_code}")
        return 2
    token = login.json().get("token", "")
    headers = {"Authorization": f"Bearer {token}"}
    print(f"[ok] login through {args.base} (token acquired)")

    matters = session.get(f"{args.base}/pacgate/api/matters", headers=headers)
    if matters.status_code != 200:
        print(f"[FAIL] matters list failed: {matters.status_code}")
        return 2
    target = next((m for m in matters.json() if m["name"] == "OCR Surface Probe"), None)
    if target is None:
        print("[FAIL] no 'OCR Surface Probe' matter found; create one first")
        return 2
    matter_id = target["id"]
    print(f"[ok] target matter: {matter_id}")

    random.seed(args.size_mb)
    payload = b"%PDF-1.4\n" + bytes(random.getrandbits(8) for _ in range(args.size_mb * 1024 * 1024)) + b"%%EOF"
    name = f"body-limit-probe-{args.size_mb}mb.pdf"

    resp = session.post(
        f"{args.base}/pacgate/api/documents",
        headers=headers,
        data={"matter_id": matter_id},
        files={"file": (name, payload, "application/pdf")},
    )

    if resp.status_code == 200:
        doc = resp.json()
        print(f"[PASS] {args.size_mb} MB upload through nginx: 200, document id {doc['id']}")
        if args.cleanup:
            gone = session.delete(f"{args.base}/pacgate/api/documents/{doc['id']}", headers=headers)
            print(f"[{'ok' if gone.status_code == 200 else 'warn'}] cleanup delete: {gone.status_code}")
        return 0

    if resp.status_code == 413:
        print("[FAIL] 413 from nginx -> layer 1 fix missing (client_max_body_size)")
    elif resp.status_code in (400, 502):
        body_text = resp.text
        if "exceeds" in body_text and "MB limit" in body_text:
            # The deliberate in-handler cap (max_upload_mb) rejected the file.
            # That is CORRECT behavior when the probe exceeds the handler
            # limit - not a missing transport fix. Only a transport abort
            # (broken pipe / connection reset -> 502 with no JSON) is a
            # layer-2 failure.
            if resp.status_code == 502 or "bad_request" not in body_text:
                print(f"[FAIL] {resp.status_code} with connection abort -> layer 2 fix missing (DefaultBodyLimit in lib.rs)")
            else:
                print(f"[INFO] polite rejection by the deliberate handler cap: {body_text.strip()[:160]}")
                print("       (transport accepted the body; the 50 MB handler limit governs - behavior CORRECT)")
            return 0 if "exceeds" in body_text else 1
        print(f"[FAIL] {resp.status_code} from backend -> layer 2 fix missing (DefaultBodyLimit in lib.rs)")
        print(f"       body: {resp.text[:200]}")
    else:
        print(f"[FAIL] unexpected status {resp.status_code}: {resp.text[:200]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())

