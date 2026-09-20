"""Anonymous GHCR manifest check for the 0.1.17 release images.

200 = public, 401 = private, 404 = missing. No credentials used.
Usage: python scripts/check-ghcr-anon.py 0.1.17 [image ...]
"""

from __future__ import annotations

import json
import sys
import urllib.request

ACCEPT = (
    "application/vnd.oci.image.index.v1+json, "
    "application/vnd.oci.image.manifest.v1+json, "
    "application/vnd.docker.distribution.manifest.v2+json"
)
DEFAULT_IMAGES = [
    "pacgate-api",
    "pacgate-mcp",
    "ocr-service",
    "deer-flow-pacgate",
    "deer-flow-frontend-pacgate",
]


def main() -> int:
    tag = sys.argv[1] if len(sys.argv) > 1 else "0.1.17"
    images = sys.argv[2:] or DEFAULT_IMAGES
    failures = 0
    for img in images:
        repo = f"jzkk720/{img}"
        try:
            token = json.load(urllib.request.urlopen(
                f"https://ghcr.io/token?scope=repository:{repo}:pull", timeout=15
            ))["token"]
            req = urllib.request.Request(
                f"https://ghcr.io/v2/{repo}/manifests/{tag}", method="GET"
            )
            req.add_header("Authorization", f"Bearer {token}")
            req.add_header("Accept", ACCEPT)
            resp = urllib.request.urlopen(req, timeout=15)
            size = len(resp.read())
            print(f"{img:32s} -> {resp.status} PUBLIC (manifest {size} bytes)")
        except Exception as e:  # noqa: BLE001
            code = getattr(e, "code", "?")
            print(f"{img:32s} -> {code} FAIL")
            failures += 1
    print("ALL PUBLIC" if failures == 0 else f"{failures} image(s) NOT public")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())