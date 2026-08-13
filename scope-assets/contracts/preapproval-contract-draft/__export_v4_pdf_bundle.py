"""Export v4 contract bundle to PDF.

Uses LibreOffice headless for DOCX/XLSX (preserves all formatting: titles,
margins, headers, footers, fonts, sizes). Falls back to markdown converter
for .md and .txt files.
"""
from __future__ import annotations

import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from safe_markdown_to_pdf import convert_markdown_to_pdf


BASE = Path(__file__).resolve().parent / "out"
PDF_DIR = BASE / "pdf-bundle"

SOFFICE = r"C:\Program Files\LibreOffice\program\soffice.exe"

OFFICE_SOURCES = [
    "hardware_contract_zh_v4.docx",
    "hardware_contract_en_v4.docx",
    "service_contract_zh_v4.docx",
    "service_contract_en_v4.docx",
    "sku_worksheet_zh_v4.xlsx",
    "sku_worksheet_en_v4.xlsx",
]

MARKDOWN_SOURCES = [
    "v4-contract-dashboard-zh.md",
    "contract-diff-round4.md",
    "round4-review-and-recommendations.md",
]


def convert_office_to_pdf(src: Path, dst: Path) -> bool:
    """Convert DOCX/XLSX to PDF using LibreOffice headless.
    LibreOffice writes the PDF to the same directory as the source with the
    same basename, so we use a temp dir and then move the result."""
    with TemporaryDirectory(prefix="lo_pdf_") as tmp_dir:
        tmp = Path(tmp_dir)
        # Copy source to temp dir
        tmp_src = tmp / src.name
        tmp_src.write_bytes(src.read_bytes())

        cmd = [
            SOFFICE,
            "--headless",
            "--convert-to", "pdf",
            "--outdir", str(tmp),
            str(tmp_src),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            print(f"  [ERR] LibreOffice failed: {result.stderr[:200]}")
            return False

        # LibreOffice writes output as <basename>.pdf in outdir
        tmp_pdf = tmp / f"{src.stem}.pdf"
        if not tmp_pdf.exists():
            print(f"  [ERR] PDF not produced by LibreOffice")
            return False

        # Move to final destination
        dst.write_bytes(tmp_pdf.read_bytes())
        return True


def main() -> None:
    PDF_DIR.mkdir(parents=True, exist_ok=True)

    converted: list[str] = []

    # DOCX/XLSX via LibreOffice (formatting-preserving)
    for name in OFFICE_SOURCES:
        src = BASE / name
        if not src.exists():
            print(f"[WARN] missing source: {src}")
            continue
        dst = PDF_DIR / f"{src.stem}.pdf"
        ok = convert_office_to_pdf(src, dst)
        if ok:
            converted.append(dst.name)
            print(f"[OK] {src.name} -> {dst.name}")
        else:
            print(f"[FAIL] {src.name}")

    # MD/TXT via markdown converter
    for name in MARKDOWN_SOURCES:
        src = BASE / name
        if not src.exists():
            print(f"[WARN] missing source: {src}")
            continue
        dst = PDF_DIR / f"{src.stem}.pdf"
        convert_markdown_to_pdf(src, dst)
        converted.append(dst.name)
        print(f"[OK] {src.name} -> {dst.name}")

    print(f"\nPDF bundle ready ({len(converted)} files):")
    for c in converted:
        print(f" - {c}")


if __name__ == "__main__":
    main()
