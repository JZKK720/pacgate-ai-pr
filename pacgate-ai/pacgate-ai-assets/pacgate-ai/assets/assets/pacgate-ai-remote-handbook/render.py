"""
Render the PacGate remote-access handbook from markdown to combined HTML and PDF.

Usage:
    python render.py --lang en        # English only  -> handbook.html / pdf/handbook.pdf
    python render.py --lang zh        # Chinese only  -> handbook.zh.html / pdf/handbook.zh.pdf
    python render.py --lang both      # both languages (default)

Pipeline per language:
  1. Pick the matching step_*.md or step_*.zh.md files in order.
  2. Render to a single combined HTML (one page per step, image large).
  3. Print to PDF using headless Chrome.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent
PDF_DIR = ROOT / "pdf"
PDF_DIR.mkdir(exist_ok=True)

# File pattern: NN_name.md for EN, NN_name.zh.md for ZH.
EN_RE = re.compile(r"^[0-9][0-9]_[^.]+\.md$")
ZH_RE = re.compile(r"^[0-9][0-9]_[^.]+\.zh\.md$")


def order_for_lang(lang: str) -> list[str]:
    if lang == "en":
        return sorted(p.name for p in ROOT.iterdir() if EN_RE.match(p.name))
    if lang == "zh":
        return sorted(p.name for p in ROOT.iterdir() if ZH_RE.match(p.name))
    raise ValueError(lang)


STYLESHEET = """
@page {
    size: A4;
    margin: 15mm;
    @bottom-center {
        content: "PacGate Remote-Access Handbook  |  Step " counter(page) " of " counter(pages);
        font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
        font-size: 9pt;
        color: #888;
    }
}
html { font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; font-size: 12pt; line-height: 1.5; color: #222; }
body { max-width: 100%; margin: 0; }
h1 { font-size: 22pt; color: #1a3a6c; border-bottom: 2px solid #1a3a6c; padding-bottom: 6pt; margin: 0 0 12pt; page-break-after: avoid; }
p { margin: 8pt 0; }
img { max-width: 100%; height: auto; display: block; margin: 16pt auto; border: 1px solid #ccc; page-break-inside: avoid; }
blockquote { border-left: 3px solid #1a3a6c; margin: 10pt 0; padding: 4pt 12pt; color: #444; background: #f7f9fc; font-size: 11pt; }
code { font-family: "Cascadia Code", "Consolas", monospace; font-size: 10pt; background: #f4f4f4; padding: 1pt 4pt; border-radius: 2pt; }
hr { border: 0; border-top: 1px solid #ddd; margin: 0; }
section { page-break-after: always; }
section:last-of-type { page-break-after: avoid; }
"""

HTML_SHELL = """<!DOCTYPE html>
<html lang="{html_lang}">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>{css}</style>
</head>
<body>
{body}
</body>
</html>
"""


def md_to_html(md_text: str) -> str:
    return markdown.markdown(
        md_text,
        extensions=["tables", "fenced_code", "sane_lists", "attr_list"],
    )


def collect_steps(file_order: list[str]) -> str:
    parts: list[str] = []
    for name in file_order:
        text = (ROOT / name).read_text(encoding="utf-8")
        parts.append(f'<section>\n{md_to_html(text)}\n</section>')
    return "\n".join(parts)


def render_lang(lang: str, chrome_exe: str) -> tuple[Path, Path]:
    file_order = order_for_lang(lang)
    if not file_order:
        print(f"[{lang}] no source files found, skipping")
        return (ROOT / f"handbook.{lang}.html", PDF_DIR / f"handbook.{lang}.pdf")

    title = {
        "en": "PacGate Remote-Access Setup Handbook",
        "zh": "PacGate 远程访问配置手册",
    }[lang]

    body = collect_steps(file_order)
    html_path = ROOT / ("handbook.html" if lang == "en" else f"handbook.{lang}.html")
    full = HTML_SHELL.format(html_lang=lang, title=title, css=STYLESHEET, body=body)
    html_path.write_text(full, encoding="utf-8")
    print(f"[{lang}] Wrote {html_path}  ({html_path.stat().st_size:,} bytes)")

    pdf_path = PDF_DIR / ("handbook.pdf" if lang == "en" else f"handbook.{lang}.pdf")
    file_url = "file:///" + str(html_path).replace("\\", "/").lstrip("/")
    cmd = [
        chrome_exe, "--headless", "--no-sandbox", "--disable-gpu",
        f"--print-to-pdf={pdf_path}", file_url,
    ]
    print(f"[{lang}] Running:", " ".join(cmd))
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if res.returncode != 0:
        print(f"[{lang}] STDOUT:", res.stdout[-1500:])
        print(f"[{lang}] STDERR:", res.stderr[-1500:])
        sys.exit(f"[{lang}] Chrome failed with exit {res.returncode}")
    print(f"[{lang}] Wrote {pdf_path}  ({pdf_path.stat().st_size:,} bytes)")
    return html_path, pdf_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--lang",
        choices=["en", "zh", "both"],
        default="both",
        help="Output language (default: both)",
    )
    args = parser.parse_args()

    chrome_exe = os.environ.get(
        "CHROME_EXE",
        r"C:\Users\pacga\.cache\puppeteer\chrome\win64-1108766\chrome-win\chrome.exe",
    )
    if not Path(chrome_exe).exists():
        print("Chrome not found at", chrome_exe)
        sys.exit(1)

    langs = ["en", "zh"] if args.lang == "both" else [args.lang]
    for lang in langs:
        render_lang(lang, chrome_exe)


if __name__ == "__main__":
    main()
