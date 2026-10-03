"""Anonymous GHCR manifest check for release images.

Status meanings, and why the old docstring was WRONG
----------------------------------------------------
This file used to claim "200 = public, 401 = private, 404 = missing". That mapping
is unreachable and it misled a real investigation: for a PRIVATE repo the failure
happens at the TOKEN step, which returns 403 DENIED — execution never reaches the
manifest request, so the script printed "403 FAIL" and never "401 private".

That matters because of a second conflation on the registry side: an
unauthenticated manifest GET returns 401 for a MISSING TAG as well as for a
missing permission. So "no such tag" and "no permission" look identical unless you
read the error CODE. On 2026-10-03 exactly that produced a false "the qm images are
private" finding that survived several turns, from a probe of a tag (`latest`) that
simply did not exist.

The real discriminators, in order of reliability:

  1. ACTUAL PULL      - `docker pull` with an empty DOCKER_CONFIG. Decisive.
  2. TAGS LIST        - `GET /v2/<repo>/tags/list`. You CANNOT list tags on a
                        private package, so a readable list proves public.
  3. TOKEN + ERROR    - a granted token + `MANIFEST_UNKNOWN` means public-but-
                        missing; `DENIED` means private.

This script implements 2 and 3 and reports the registry's error CODE rather than
guessing from a bare status. It is a quick check, not a substitute for an actual
pull when the answer matters.

Usage:
  python scripts/check-ghcr-anon.py <tag> [image ...]
  python scripts/check-ghcr-anon.py --repo <owner/name> --tag <tag> [--digest <sha256:...>]
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
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


def _get(url: str, token: str | None = None, accept: str | None = None):
    """GET returning (status, parsed_json_or_None, raw_text)."""
    req = urllib.request.Request(url, method="GET")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if accept:
        req.add_header("Accept", accept)
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        raw = resp.read().decode("utf-8", "replace")
        try:
            return resp.status, json.loads(raw), raw
        except json.JSONDecodeError:
            return resp.status, None, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw), raw
        except json.JSONDecodeError:
            return e.code, None, raw


def classify(repo: str, tag: str | None, digest: str | None) -> tuple[str, str]:
    """Return (verdict, evidence). Never guesses from a bare status code."""
    # 1. Anonymous token. 403 DENIED here is the signature of a private package.
    status, body, raw = _get(f"https://ghcr.io/token?scope=repository:{repo}:pull&service=ghcr.io")
    token = (body or {}).get("token")
    if not token:
        code = ((body or {}).get("errors") or [{}])[0].get("code", "?")
        if status == 403 or code == "DENIED":
            return "PRIVATE", f"token DENIED (http {status}); cannot pull anonymously"
        return "UNKNOWN", f"no token (http {status}) {raw[:120]}"

    # 2. Tags list. A readable tags list is itself proof the package is public:
    #    you cannot enumerate tags on a private one.
    tstatus, tbody, _ = _get(f"https://ghcr.io/v2/{repo}/tags/list", token)
    tag_count = len((tbody or {}).get("tags") or []) if tbody else None

    # 3. The reference itself, by digest when given (that is what compose pins).
    ref = digest or tag
    if ref is None:
        return "PUBLIC", f"token granted; tags list readable ({tag_count} tags)"
    mstatus, mbody, mraw = _get(f"https://ghcr.io/v2/{repo}/manifests/{ref}", token, ACCEPT)
    if mstatus == 200:
        return "PUBLIC", f"token granted; manifest {ref} fetched"
    err = ((mbody or {}).get("errors") or [{}])[0].get("code", "?")
    if err == "MANIFEST_UNKNOWN":
        # Public repo, but this reference does not exist. NOT a permission problem.
        return "PUBLIC(missing ref)", f"token granted, tags readable ({tag_count} tags), but {ref} is MANIFEST_UNKNOWN"
    if err == "DENIED" or mstatus in (401, 403):
        return "PRIVATE", f"token granted but {ref} DENIED (http {mstatus})"
    return "UNKNOWN", f"http {mstatus} {mraw[:120]}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("tag_pos", nargs="?", help="tag (positional form)")
    ap.add_argument("images", nargs="*", help="image names under jzkk720")
    ap.add_argument("--repo", help="explicit owner/name, for images not in jzkk720")
    ap.add_argument("--tag", help="tag to check")
    ap.add_argument("--digest", help="sha256:... reference (what compose pins)")
    args = ap.parse_args()

    tag = args.tag or args.tag_pos or "0.1.17"
    targets: list[tuple[str, str | None, str | None]] = []
    if args.repo:
        targets.append((args.repo, None if args.digest else tag, args.digest))
    else:
        for img in (args.images or DEFAULT_IMAGES):
            targets.append((f"jzkk720/{img}", tag, None))

    failures = 0
    for repo, t, d in targets:
        verdict, evidence = classify(repo, t, d)
        mark = "OK  " if verdict.startswith("PUBLIC") else "FAIL"
        print(f"{repo:44s} {mark} {verdict:18s} {evidence}")
        if not verdict.startswith("PUBLIC"):
            failures += 1
    print("ALL PUBLIC" if failures == 0 else f"{failures} not public")
    if failures:
        print("NOTE: 'PRIVATE' means a token was DENIED. A bare 401/404 from a "
              "manifest GET is NOT evidence of privacy - see this file's docstring.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())