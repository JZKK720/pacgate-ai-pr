#!/usr/bin/env python3
"""PROBE (not a gate): which input formats can actually pass the sanitization gate?

WHY THIS EXISTS
---------------
A prior report claimed the sanitizer lane is "PDF only" and that .docx/.txt fail
through a "text path in extract.rs". That claim has a *mechanism* attached, and a
mechanism is falsifiable. This probe measures the real lanes instead of inferring
them, because the two plausible mechanisms lead to different fixes:

  hypothesis A - a TEXT PATH defect in extract.rs (what the report asserted)
  hypothesis B - a FILE-TYPE defect in ocr-service (pdf2image only handles PDF;
                 images pass through; everything else is rasterised as an image
                 and PaddleOCR fails -> incomplete=True -> sanitize refuses)

The discriminator: ocr-service is hit with the same bytes under different filename
suffixes. If an image passes and a .docx/.txt fails, the defect is the suffix/file
type, not a text path. If an image ALSO fails, the OCR dependency is broken.

Lanes measured, all through the REAL ingress (nginx -> pacgate-api):
  1. upload + extract + sanitize   (per format: .pdf, .png, .docx, .txt, .md)
  2. pacgate_sanitize_text         (the MCP tool, in the MCP container)

This probe is READ-ONLY on the repo and CLEANS UP every artifact it creates.
It is NOT wired into run-all-checks.ps1: it needs a live stack + OCR weights and
costs ~10-20s on a cold OCR cache, so it is a diagnostic you run on demand.

Usage:
  python scripts/probe-format-lanes.py
  python scripts/probe-format-lanes.py --base-url http://localhost:8089/pacgate
  python scripts/probe-format-lanes.py --keep-artifacts

Exit: 0 = probe completed (whatever the findings), 2 = could not check.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import uuid
from pathlib import Path
from typing import Any

try:
    import requests
except ImportError:  # pragma: no cover
    print("FATAL: `requests` is required. pip install requests", file=sys.stderr)
    sys.exit(2)

REPO = Path(__file__).resolve().parent.parent
DEFAULT_ENV = REPO / "deploy" / "client-bundle" / ".env"

# A born-digital PDF fixture is built with PIL the same way test-legal-journey.ps1
# does it. The identifiers are the point: a sanitize that "passes" with zero
# redactions would be a false green.
ID_NUMBER = "11010519491231002X"
PHONE = "13812345678"


def log(msg: str) -> None:
    print(msg, flush=True)


def die(msg: str) -> None:
    print(f"\nCANNOT CHECK: {msg}", file=sys.stderr, flush=True)
    sys.exit(2)


def read_env(path: Path) -> dict[str, str]:
    if not path.exists():
        die(f"credentials file not found: {path}")
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip()
    return out


# ── fixture builders ────────────────────────────────────────────────────────


def make_pdf() -> bytes:
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", (900, 300), "white")
    d = ImageDraw.Draw(img)
    font = ImageFont.load_default()
    d.text((16, 100), ID_NUMBER, fill="black", font=font)
    d.text((16, 150), PHONE, fill="black", font=font)
    buf = io.BytesIO()
    img.save(buf, "PDF", resolution=100)
    return buf.getvalue()


def make_png() -> bytes:
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", (900, 300), "white")
    d = ImageDraw.Draw(img)
    font = ImageFont.load_default()
    d.text((16, 100), ID_NUMBER, fill="black", font=font)
    d.text((16, 150), PHONE, fill="black", font=font)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def make_docx() -> bytes:
    """A real .docx, not a renamed zip: this is what a client actually sends."""
    from docx import Document

    doc = Document()
    doc.add_paragraph(f"Client ID number: {ID_NUMBER}")
    doc.add_paragraph(f"Contact phone: {PHONE}")
    buf = io.BytesIO()
    doc.save(buf)
    return buf.getvalue()


def make_txt() -> bytes:
    return f"Client ID number: {ID_NUMBER}\nContact phone: {PHONE}\n".encode("utf-8")


def make_md() -> bytes:
    return (
        f"# Intake note\n\n- ID number: {ID_NUMBER}\n- Phone: {PHONE}\n"
    ).encode("utf-8")


FORMATS: list[tuple[str, str, Any]] = [
    ("pdf", "case.pdf", make_pdf),
    ("png", "case.png", make_png),
    ("docx", "case.docx", make_docx),
    ("txt", "case.txt", make_txt),
    ("md", "case.md", make_md),
]


# ── API helpers ─────────────────────────────────────────────────────────────


class Api:
    def __init__(self, base: str, token: str):
        self.base = base.rstrip("/")
        self.s = requests.Session()
        self.s.headers["Authorization"] = f"Bearer {token}"

    def post_json(self, path: str, body: dict | None = None, timeout: int = 300) -> requests.Response:
        return self.s.post(f"{self.base}{path}", json=body or {}, timeout=timeout)

    def upload(self, matter_id: str, filename: str, blob: bytes, timeout: int = 120) -> requests.Response:
        return self.s.post(
            f"{self.base}/api/documents",
            data={"matter_id": matter_id},
            files={"file": (filename, blob)},
            timeout=timeout,
        )

    def delete(self, path: str, timeout: int = 60) -> requests.Response:
        return self.s.delete(f"{self.base}{path}", timeout=timeout)


def authenticate(base: str, email: str, password: str) -> str:
    for path in ("/api/auth/login", "/auth/login"):
        try:
            r = requests.post(
                f"{base}{path}",
                json={"email": email, "password": password},
                timeout=20,
            )
            if r.status_code == 200 and r.json().get("token"):
                return r.json()["token"]
        except requests.RequestException:
            continue
    die("login failed on both route shapes - check credentials / LAN origin allowlist.")


def sanitize_text_via_api(api: Api, matter_id: str, text: str) -> requests.Response:
    """Exactly what pacgate_sanitize_text does over the wire.

    The MCP tool uploads the blob as `sanitize-ephemeral.txt` and then sanitizes.
    Reproducing it here isolates the DEFECT from the MCP transport: if this
    fails, MCP is a red herring; if this succeeds, the tool itself is broken.
    """
    r = api.upload(matter_id, "sanitize-ephemeral.txt", text.encode("utf-8"))
    if r.status_code not in (200, 201):
        return r
    doc_id = r.json().get("id")
    out = api.post_json(f"/api/documents/{doc_id}/sanitize", {"data_level": "T3"})
    # best-effort cleanup, mirroring the tool
    try:
        api.delete(f"/api/documents/{doc_id}")
    except requests.RequestException:
        pass
    return out


# ── main ────────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://localhost:8089/pacgate")
    ap.add_argument("--env-file", default=str(DEFAULT_ENV))
    ap.add_argument("--keep-artifacts", action="store_true")
    ap.add_argument("--mcp-container", default="pacgate-mcp")
    args = ap.parse_args()

    env = read_env(Path(args.env_file))
    email = env.get("PACGATE_API_EMAIL")
    password = env.get("PACGATE_API_PASSWORD")
    if not email or not password:
        die("PACGATE_API_EMAIL / PACGATE_API_PASSWORD missing from .env")

    base = args.base_url.rstrip("/")
    log("=== FORMAT-LANE PROBE ===")
    log(f"  base: {base}")

    # Preflight: version at the NGINX ROOT, not under the /pacgate prefix.
    root = re.sub(r"/pacgate/?$", "", base)
    ver = None
    for url in (f"{root}/version", f"{base}/version"):
        try:
            r = requests.get(url, timeout=10)
            if r.status_code == 200 and r.json().get("version"):
                ver = r.json()
                break
        except (requests.RequestException, ValueError):
            continue
    if not ver:
        die(f"stack not reachable: no version answered at {root}/version")
    log(f"  version={ver.get('version')} revision={str(ver.get('revision'))[:7]}")

    token = authenticate(base, email, password)
    api = Api(base, token)
    log("  authenticated")

    run_id = uuid.uuid4().hex[:8]
    r = api.post_json("/api/matters", {"name": f"probe-{run_id}", "description": "format-lane probe"})
    if r.status_code not in (200, 201) or not r.json().get("id"):
        die(f"matter create failed: {r.status_code} {r.text[:200]}")
    matter_id = r.json()["id"]
    log(f"  matter={matter_id}")

    results: list[dict[str, Any]] = []

    for fmt, filename, builder in FORMATS:
        log("")
        log(f"--- {fmt} ({filename}) ---")
        row: dict[str, Any] = {"format": fmt, "filename": filename}
        try:
            blob = builder()
        except Exception as e:  # a fixture builder failing is a probe problem
            row["error"] = f"fixture build failed: {e}"
            results.append(row)
            log(f"  fixture FAILED: {e}")
            continue
        row["bytes"] = len(blob)

        up = api.upload(matter_id, filename, blob)
        row["upload"] = up.status_code
        if up.status_code not in (200, 201):
            row["error"] = f"upload {up.status_code}: {up.text[:200]}"
            results.append(row)
            log(f"  upload={up.status_code} FAILED {up.text[:200]}")
            continue
        doc = up.json()
        doc_id = doc["id"]
        row["document_id"] = doc_id
        row["stored_format"] = doc.get("format")
        row["stored_name"] = doc.get("name")
        log(f"  upload={up.status_code} format={doc.get('format')} name={doc.get('name')}")

        ex = api.post_json(f"/api/documents/{doc_id}/extract", {}, timeout=300)
        row["extract"] = ex.status_code
        if ex.status_code == 200:
            exj = ex.json()
            row["incomplete"] = exj.get("incomplete")
            row["extract_chars"] = len(exj.get("text") or "")
            row["extract_spans"] = len(exj.get("spans") or [])
            row["pages"] = exj.get("pages")
            log(
                f"  extract={ex.status_code} incomplete={row['incomplete']} "
                f"chars={row['extract_chars']} spans={row['extract_spans']}"
            )
        else:
            row["extract_body"] = ex.text[:300]
            log(f"  extract={ex.status_code} {ex.text[:200]}")

        san = api.post_json(f"/api/documents/{doc_id}/sanitize", {"data_level": "T3"}, timeout=300)
        row["sanitize"] = san.status_code
        if san.status_code == 200:
            sj = san.json()
            row["verdict"] = sj.get("verdict")
            row["redaction_count"] = sj.get("redaction_count")
            row["mapping_count"] = sj.get("mapping_count")
            sani_text = sj.get("sanitized_text") or ""
            row["id_survived"] = ID_NUMBER in sani_text
            row["phone_survived"] = PHONE in sani_text
            log(
                f"  sanitize={san.status_code} verdict={row['verdict']} "
                f"redactions={row['redaction_count']} mappings={row['mapping_count']}"
            )
        else:
            row["sanitize_body"] = san.text[:300]
            log(f"  sanitize={san.status_code} {san.text[:200]}")

        if not args.keep_artifacts:
            d = api.delete(f"/api/documents/{doc_id}")
            row["cleanup"] = d.status_code
            log(f"  cleanup={d.status_code}")
        results.append(row)

    # ── pacgate_sanitize_text lane (over the wire, no MCP transport) ────────
    log("")
    log("--- pacgate_sanitize_text wire path (upload sanitize-ephemeral.txt + sanitize) ---")
    st = sanitize_text_via_api(api, matter_id, f"Client ID: {ID_NUMBER}\nPhone: {PHONE}\n")
    st_row: dict[str, Any] = {"lane": "sanitize_text_wire", "status": st.status_code}
    if st.status_code == 200:
        stj = st.json()
        st_row["verdict"] = stj.get("verdict")
        st_row["redaction_count"] = stj.get("redaction_count")
        log(f"  result={st.status_code} verdict={st_row.get('verdict')} redactions={st_row.get('redaction_count')}")
    else:
        st_row["body"] = st.text[:300]
        log(f"  result={st.status_code} {st.text[:250]}")
    results.append(st_row)

    # ── Summary ────────────────────────────────────────────────────────────
    log("")
    log("=== SUMMARY (measured) ===")
    hdr = f"{'format':<8} {'upload':>7} {'extract':>8} {'incompl':>8} {'chars':>7} {'sanit':>6} {'verdict':>9} {'redact':>7}"
    log(hdr)
    log("-" * len(hdr))
    for row in results:
        if "lane" in row:
            continue
        log(
            f"{row['format']:<8} {str(row.get('upload','-')):>7} "
            f"{str(row.get('extract','-')):>8} {str(row.get('incomplete','-')):>8} "
            f"{str(row.get('extract_chars','-')):>7} {str(row.get('sanitize','-')):>6} "
            f"{str(row.get('verdict','-')):>9} {str(row.get('redaction_count','-')):>7}"
        )
    log("")
    log(f"sanitize_text wire path: {st_row['status']} verdict={st_row.get('verdict','-')}")

    # Machine-readable block so a later run can diff findings.
    log("")
    log("=== JSON ===")
    log(json.dumps({"version": ver, "results": results}, ensure_ascii=False, indent=2))

    if not args.keep_artifacts:
        d = api.delete(f"/api/matters/{matter_id}")
        log(f"\nmatter cleanup: {d.status_code}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
