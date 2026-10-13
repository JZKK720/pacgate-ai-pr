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


# Chrome discovery.
#
# WHY THIS IS NOT A LITERAL. Both renderers used to hardcode
#     r"C:\Users\pacga\.cache\puppeteer\chrome\win64-1108766\chrome-win\chrome.exe"
# which is a SPECIFIC USER'S puppeteer cache. On any other machine - including
# every fresh clone, and every AIPC - that path does not exist, so rendering died
# with "Chrome not found" and nobody could re-render. Meanwhile
# scripts/test-pdf-freshness.ps1 requires the rendered PDFs to be newer than their
# sources. The combination is why the handbook PDFs kept going stale: the check
# demanded a re-render that the tooling could not perform for anyone but its
# author (a real instance of the staleness this repo's own audit recorded on
# 2026-10-01: the ZH PDF advertised 0.1.19 while its source said otherwise).
#
# Searched in order, most specific first. CHROME_EXE still overrides everything.
def find_chrome() -> str | None:
    override = os.environ.get("CHROME_EXE")
    if override:
        return override if Path(override).exists() else None

    candidates: list[Path] = []

    # Any user's puppeteer cache, so a machine that only has the downloaded
    # browser still works. Globbed rather than pinned: the build revision changes
    # every time puppeteer updates, and a pinned revision is the same mistake in a
    # new place.
    for base in (
        Path(os.environ.get("USERPROFILE", "")) / ".cache" / "puppeteer" / "chrome",
        Path.home() / ".cache" / "puppeteer" / "chrome",
        Path(os.environ.get("LOCALAPPDATA", "")) / "puppeteer" / "chrome",
        Path.home() / "Library" / "Caches" / "puppeteer" / "chrome",
        Path.home() / ".cache" / "puppeteer" / "chrome-headless-shell",
    ):
        if base.is_dir():
            candidates.extend(sorted(base.glob("*/chrome-win64/chrome.exe")))
            candidates.extend(sorted(base.glob("*/chrome-win/chrome.exe")))
            candidates.extend(sorted(base.glob("*/chrome-linux64/chrome")))
            candidates.extend(sorted(base.glob("*/chrome-headless-shell-*/chrome-headless-shell*")))

    # A real installed Chrome, which is the most common case on a dev box.
    for p in (
        Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Google/Chrome/Application/chrome.exe",
        Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Google/Chrome/Application/chrome.exe",
        Path(os.environ.get("LOCALAPPDATA", "")) / "Google/Chrome/Application/chrome.exe",
        Path("/usr/bin/google-chrome"),
        Path("/usr/bin/chromium"),
        Path("/usr/bin/chromium-browser"),
        Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    ):
        candidates.append(p)

    for c in candidates:
        if c.exists():
            return str(c)
    return None


def render_md(md_path: Path, chrome_exe: str, html_dir: Path | None = None) -> tuple[Path, Path]:
    text = md_path.read_text(encoding="utf-8")
    title = md_path.stem
    body = md_to_html(text)
    # The HTML is a regenerable intermediate and is gitignored under handbooks/.
    # Callers rendering a file from elsewhere (the AIPC handbook lives at the
    # deploy root) point it here anyway, so the intermediate cannot land beside
    # the source as a stray committable file: `*.html` is only ignored inside
    # handbooks/.
    html_path = (html_dir or md_path.parent) / f"{md_path.stem}.html"
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
        choices=["all", "deer-flow", "qm", "aipc"],
        default="all",
        help="Which handbook to render (default: all)",
    )
    args = parser.parse_args()

    chrome_exe = find_chrome()
    if not chrome_exe:
        print("Chrome not found. Set CHROME_EXE to a Chrome/Chromium binary, or install Chrome.")
        print("Searched: CHROME_EXE, every user's puppeteer cache, and installed Chrome/Chromium.")
        sys.exit(1)
    print(f"Chrome: {chrome_exe}")

    aipc_md = ROOT.parent / "AIPC-DEPLOYMENT-HANDBOOK.md"
    targets = {
        "deer-flow": ROOT / "deer-flow-openviking-pacgate-handbook.zh.md",
        "qm": ROOT / "qm-openviking-pacgate-handbook.zh.md",
        # NOTE: the AIPC handbook is handled by the dedicated loop below, not as a
        # table entry, because it has FOUR tracked copies per language (deploy
        # root, handbooks/pdf, client-delivery/docs) and needs the copies kept in
        # step. It was previously not rendered at all - this renderer only ever
        # handled deer-flow and qm - so its PDFs had no committed way to be
        # regenerated, went stale on every version bump, and
        # test-pdf-freshness.ps1 went red with no tool to fix it.
    }
    names = list(targets) if args.name == "all" else [args.name]
    rendered: list[tuple[str, Path]] = []
    for name in names:
        md_path = targets[name]
        if not md_path.exists():
            print(f"[{name}] source not found: {md_path}")
            continue
        # Keep intermediates in handbooks/ (gitignored) even when the source lives
        # at the deploy root.
        rendered.append((name, render_md(md_path, chrome_exe, html_dir=ROOT)[1]))

    # The AIPC handbook keeps its English and Chinese PDFs at the deploy root, and
    # the client-delivery copies must not drift from the originals (a delivery
    # copy that lags ships a stale document from a tree that looks green).
    if args.name in ("all", "aipc") and aipc_md.exists():
        for lang_md, suffix in ((aipc_md, ""), (ROOT.parent / "AIPC-DEPLOYMENT-HANDBOOK-ZH.md", "-ZH")):
            if not lang_md.exists():
                print(f"[aipc] source not found: {lang_md}")
                continue
            pdf = render_md(lang_md, chrome_exe, html_dir=ROOT)[1]
            root_pdf = ROOT.parent / f"AIPC-DEPLOYMENT-HANDBOOK{suffix}.pdf"
            if pdf != root_pdf:
                root_pdf.write_bytes(pdf.read_bytes())
                print(f"Copied -> {root_pdf}")
            delivery = ROOT.parent / "client-delivery" / "docs" / root_pdf.name
            if delivery.parent.is_dir():
                delivery.write_bytes(root_pdf.read_bytes())
                print(f"Copied -> {delivery}")


if __name__ == "__main__":
    main()
