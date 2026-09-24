#!/usr/bin/env python3
"""PROBE (not a gate): isolate WHERE the non-PDF extraction failure happens.

THE DISCRIMINATION THIS MAKES
-----------------------------
Two mechanisms produce the same symptom (extract returns incomplete=true, 0 chars,
and sanitize then refuses with 500):

  A. a TEXT-PATH defect in pacgate-api/src/extract.rs
  B. a FILE-TYPE defect in ocr-service: `_prepare_pages` rasterises ONLY .pdf.
     Any other suffix returns (1, tmp_path) - the RAW file bytes - which
     PaddleOCR then tries to open as an image. A .docx/.txt is not an image, so
     `ocr.ocr()` raises, the page is marked failed, and incomplete=True.

The discriminator: hold the BYTES constant and vary ONLY the filename suffix sent
to ocr-service. ocr-service is the last hop, so it has no auth and no document
record - this probe hits it directly on the compose network.

  * If a real .png succeeds -> ocr-service's OCR engine works; the defect is that
    nothing ever hands it an image for non-PDF input. Mechanism B.
  * If a real .png ALSO fails -> the OCR dependency itself is broken, which is a
    third mechanism and would change the fix again.

Run inside the compose network (or from the host against the published port):
  docker run --rm --network client-bundle_default -v "$PWD/scripts:/s:ro" \\
      python:3.12-slim sh -c "pip -q install requests pillow && python /s/probe-ocr-suffix.py"
  python scripts/probe-ocr-suffix.py --ocr-url http://localhost:8100

Exit: 0 = probe completed, 2 = ocr-service unreachable (cannot check).
"""

from __future__ import annotations

import argparse
import io
import sys

try:
    import requests
except ImportError:
    print("FATAL: requests required", file=sys.stderr)
    sys.exit(2)


def make_pdf() -> bytes:
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", (900, 300), "white")
    d = ImageDraw.Draw(img)
    f = ImageFont.load_default()
    d.text((16, 100), "ID 11010519491231002X", fill="black", font=f)
    buf = io.BytesIO()
    img.save(buf, "PDF", resolution=100)
    return buf.getvalue()


def make_png() -> bytes:
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", (900, 300), "white")
    d = ImageDraw.Draw(img)
    f = ImageFont.load_default()
    d.text((16, 100), "ID 11010519491231002X", fill="black", font=f)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def make_docx() -> bytes:
    from docx import Document

    doc = Document()
    doc.add_paragraph("ID 11010519491231002X")
    buf = io.BytesIO()
    doc.save(buf)
    return buf.getvalue()


def make_txt() -> bytes:
    return b"ID 11010519491231002X\nphone 13812345678\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ocr-url", default="http://localhost:8100")
    args = ap.parse_args()
    url = args.ocr_url.rstrip("/")

    try:
        h = requests.get(f"{url}/health", timeout=10)
        if h.status_code != 200:
            print(f"CANNOT CHECK: /health returned {h.status_code}", file=sys.stderr)
            return 2
    except requests.RequestException as e:
        print(f"CANNOT CHECK: ocr-service unreachable at {url}: {e}", file=sys.stderr)
        return 2

    print(f"=== ocr-service suffix discrimination ({url}) ===")
    print("holding BYTES constant, varying only the filename suffix\n")

    # (label, builder, filename) - the filename is the ONLY variable that matters
    # for the `.pdf` branch in _prepare_pages.
    cases = [
        ("CONTROL real pdf as .pdf", make_pdf, "control.pdf"),
        ("real png as .png", make_png, "image.png"),
        ("real pdf misnamed .txt", make_pdf, "misnamed.txt"),
        ("txt bytes as .txt", make_txt, "note.txt"),
        ("txt bytes renamed .pdf", make_txt, "renamed.pdf"),
        ("real docx as .docx", make_docx, "memo.docx"),
    ]

    rows = []
    for label, builder, filename in cases:
        blob = builder()
        try:
            r = requests.post(
                f"{url}/extract",
                files={"file": (filename, blob)},
                timeout=300,
            )
        except requests.RequestException as e:
            rows.append((label, filename, "ERR", "-", "-", str(e)[:60]))
            print(f"{label:<28} {filename:<16} ERR  {e}")
            continue
        if r.status_code != 200:
            rows.append((label, filename, str(r.status_code), "-", "-", r.text[:60]))
            print(f"{label:<28} {filename:<16} {r.status_code}  {r.text[:80]}")
            continue
        j = r.json()
        text = j.get("text") or ""
        rows.append(
            (
                label,
                filename,
                "200",
                str(j.get("incomplete")),
                str(len(text)),
                text.replace("\n", " ")[:50],
            )
        )
        print(
            f"{label:<28} {filename:<16} 200  incomplete={str(j.get('incomplete')):<5} "
            f"chars={len(text):<5} spans={len(j.get('spans') or []):<3} :: {text.replace(chr(10),' ')[:60]}"
        )

    print("\n=== reading ===")
    png_row = next((r for r in rows if r[1] == "image.png"), None)
    if png_row and png_row[3] == "False" and int(png_row[4]) > 0:
        print("A real image SUCCEEDS -> ocr-service's engine works.")
        print("Therefore the defect is NOT the OCR engine and NOT a text path in")
        print("extract.rs: non-PDF input is handed to PaddleOCR as RAW FILE BYTES")
        print("(ocr-service `_prepare_pages` rasterises only .pdf).")
    elif png_row:
        print("A real image ALSO FAILED -> the OCR dependency itself is broken;")
        print("that is a different mechanism and a different fix.")
    else:
        print("png case did not run.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
