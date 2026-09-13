"""
Render Pacgate handbooks from markdown to combined HTML and PDF.

Usage:
    python render_handbooks.py            # render both handbooks
    python render_handbooks.py --name all # all
    python render_handbooks.py --name deer-flow
    python render_handbooks.py --name qm

Each handbook is a single .md file rendered to HTML then printed to PDF with
headless Chrome (legacy --headless; --headless=new crashes on this box).
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent
PDF_DIR = ROOT / "pdf"
PDF_DIR.mkdir(exist_ok=True)

STYLESHEET = """
@page {
    size: A4;
    margin: 18mm 16mm 18mm 16mm;
    @bottom-center {
        content: "Pacgate-ai 手册  |  " counter(page) " / " counter(pages);
        font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
        font-size: 9pt;
        color: #888;
    }
}
html { font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; font-size: 11pt; line-height: 1.6; color: #1f2328; }
body { max-width: 100%; margin: 0; }
h1 { font-size: 24pt; color: #1a3a6c; border-bottom: 2px solid #1a3a6c; padding-bottom: 8pt; margin: 0 0 16pt; }
h2 { font-size: 18pt; color: #1a3a6c; margin: 24pt 0 10pt; border-left: 4px solid #1a3a6c; padding-left: 8pt; }
h3 { font-size: 14pt; color: #2b4a80; margin: 18pt 0 8pt; }
h4 { font-size: 12pt; color: #2b4a80; margin: 14pt 0 6pt; }
p { margin: 8pt 0; }
table { border-collapse: collapse; width: 100%; margin: 12pt 0; page-break-inside: avoid; }
th, td { border: 1px solid #ccc; padding: 6pt 8pt; text-align: left; font-size: 10pt; }
th { background: #f0f4fa; color: #1a3a6c; }
code { font-family: "Cascadia Code", "Consolas", monospace; font-size: 9pt; background: #f4f4f4; padding: 1pt 4pt; border-radius: 2pt; }
pre { background: #f6f8fa; border: 1px solid #ddd; padding: 10pt 12pt; font-size: 9pt; overflow-x: auto; page-break-inside: avoid; }
pre code { background: none; padding: 0; }
blockquote { border-left: 3px solid #1a3a6c; margin: 10pt 0; padding: 4pt 12pt; color: #444; background: #f7f9fc; font-size: 10pt; }
img { max-width: 100%; height: auto; display: block; margin: 16pt auto; border: 1px solid #ccc; page-break-inside: avoid; }
ul, ol { margin: 8pt 0; padding-left: 24pt; }
li { margin: 4pt 0; }
hr { border: 0; border-top: 1px solid #ddd; margin: 16pt 0; }
strong { color: #1a3a6c; }
"""

HTML_SHELL = """<!DOCTYPE html>
<html lang="zh">
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
        extensions=["tables", "fenced_code", "sane_lists", "attr_list", "toc"],
    )


def render_md(md_path: Path, chrome_exe: str) -> tuple[Path, Path]:
    text = md_path.read_text(encoding="utf-8")
    title = md_path.stem
    body = md_to_html(text)
    html_path = md_path.with_suffix(".html")
    full = HTML_SHELL.format(title=title, css=STYLESHEET, body=body)
    html_path.write_text(full, encoding="utf-8")
    print(f"Wrote {html_path}  ({html_path.stat().st_size:,} bytes)")

    pdf_path = PDF_DIR / f"{md_path.stem}.pdf"
    file_url = "file:///" + str(html_path).replace("\\", "/").lstrip("/")
    cmd = [
        chrome_exe, "--headless", "--no-sandbox", "--disable-gpu",
        "--no-pdf-header-footer",
        f"--print-to-pdf={pdf_path}", file_url,
    ]
    print("Running:", " ".join(cmd))
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if res.returncode != 0:
        print("STDOUT:", res.stdout[-1500:])
        print("STDERR:", res.stderr[-1500:])
        sys.exit(f"Chrome failed with exit {res.returncode}")
    print(f"Wrote {pdf_path}  ({pdf_path.stat().st_size:,} bytes)")
    return html_path, pdf_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--name",
        choices=["all", "deer-flow", "qm"],
        default="all",
        help="Which handbook to render (default: all)",
    )
    args = parser.parse_args()

    chrome_exe = os.environ.get(
        "CHROME_EXE",
        r"C:\Users\pacga\.cache\puppeteer\chrome\win64-1108766\chrome-win\chrome.exe",
    )
    if not Path(chrome_exe).exists():
        print("Chrome not found at", chrome_exe)
        sys.exit(1)

    targets = {
        "deer-flow": ROOT / "deer-flow-openviking-pacgate-handbook.zh.md",
        "qm": ROOT / "qm-openviking-pacgate-handbook.zh.md",
    }
    names = list(targets) if args.name == "all" else [args.name]
    for name in names:
        md_path = targets[name]
        if not md_path.exists():
            print(f"[{name}] source not found: {md_path}")
            continue
        render_md(md_path, chrome_exe)


if __name__ == "__main__":
    main()
