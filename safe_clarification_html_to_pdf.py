from __future__ import annotations

import argparse
import html
import io
import logging
import re
from pathlib import Path

from bs4 import BeautifulSoup, NavigableString, Tag
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import HRFlowable, Image, Paragraph, Spacer
from svglib.svglib import svg2rlg

from safe_markdown_to_pdf import append_list, build_styles, build_table, flatten_children, plain_text, register_fonts


MAX_SVG_BYTES = 10 * 1024 * 1024


def add_paragraph(story: list, text: str, style) -> None:
    text = text.strip()
    if text:
        story.append(Paragraph(text, style))


def add_label(story: list, text: str, styles, style_name: str = "PgLabel") -> None:
    text = text.strip()
    if text:
        story.append(Paragraph(f"<b>{html.escape(text)}</b>", styles[style_name]))


def add_image(story: list, node: Tag, base_path: Path) -> None:
    src = node.get("src")
    if not isinstance(src, str) or not src.strip():
        return

    base_resolved = base_path.resolve()
    image_path = (base_path / src).resolve()
    try:
        image_path.relative_to(base_resolved)
    except ValueError:
        return

    if not image_path.exists() or not image_path.is_file():
        return

    # Prefer pre-rendered PNG siblings for Mermaid-exported SVGs in PDF mode;
    # this avoids foreignObject/font issues that can drop labels in vector parsing.
    if image_path.suffix.lower() == ".svg":
        png_fallback = image_path.with_suffix(".png")
        if png_fallback.exists() and png_fallback.is_file():
            image_path = png_fallback

    max_width_pt = 160 * 2.834645669
    max_height_pt = 95 * 2.834645669
    suffix = image_path.suffix.lower()

    image_flowable = None
    if suffix == ".svg":
        if image_path.stat().st_size > MAX_SVG_BYTES:
            logging.warning("Skipping oversized SVG in PDF export: %s", image_path)
            return
        svg_text = image_path.read_text(encoding="utf-8")
        svg_text = re.sub(r"stroke-dasharray\s*:\s*0(?:\.0+)?\s*;?", "stroke-dasharray:none;", svg_text)
        drawing = svg2rlg(io.StringIO(svg_text))
        if drawing is None:
            logging.warning("Failed to parse SVG for PDF export: %s", image_path)
            return
        width_scale = max_width_pt / drawing.width if drawing.width > 0 else 1.0
        height_scale = max_height_pt / drawing.height if drawing.height > 0 else 1.0
        scale = min(1.0, width_scale, height_scale)
        if scale < 1.0:
            drawing.width = drawing.width * scale
            drawing.height = drawing.height * scale
            drawing.scale(scale, scale)
        image_flowable = drawing
    else:
        image_flowable = Image(str(image_path))
        width_pt = image_flowable.drawWidth
        height_pt = image_flowable.drawHeight
        width_scale = max_width_pt / width_pt if width_pt > 0 else 1.0
        height_scale = max_height_pt / height_pt if height_pt > 0 else 1.0
        scale = min(1.0, width_scale, height_scale)
        if scale < 1.0:
            image_flowable.drawWidth = width_pt * scale
            image_flowable.drawHeight = height_pt * scale

    if image_flowable is not None:
        story.append(image_flowable)
        story.append(Spacer(1, 5))


def append_node(node: Tag | NavigableString, story: list, styles, base_path: Path) -> None:
    if isinstance(node, NavigableString):
        return

    classes = set(node.get("class", []))

    if node.name == "h1":
        add_paragraph(story, flatten_children(node), styles["PgH1"])
        return
    if node.name == "h2":
        add_paragraph(story, flatten_children(node), styles["PgH2"])
        return
    if node.name == "h3":
        add_paragraph(story, flatten_children(node), styles["PgH3"])
        return
    if node.name == "h4":
        add_paragraph(story, flatten_children(node), styles["PgH4"])
        return
    if node.name == "p":
        add_paragraph(story, flatten_children(node), styles["PgSmallNote"] if "small-note" in classes else styles["PgBody"])
        return
    if node.name == "ul":
        append_list(node, story, styles, ordered=False)
        return
    if node.name == "ol":
        append_list(node, story, styles, ordered=True)
        return
    if node.name == "table":
        story.append(build_table(node, styles))
        story.append(Spacer(1, 6))
        return
    if node.name == "img":
        add_image(story, node, base_path)
        return
    if node.name == "figure":
        image = node.find("img")
        if isinstance(image, Tag):
            add_image(story, image, base_path)
        caption = node.find("figcaption")
        if isinstance(caption, Tag):
            add_paragraph(story, flatten_children(caption), styles["PgSmallNote"])
        return
    if node.name == "hr":
        story.append(HRFlowable(width="100%", thickness=0.6, color=colors.HexColor("#BEBEBE"), spaceBefore=4, spaceAfter=8))
        return

    if node.name in {"span", "div"} and ("eyebrow" in classes or "label" in classes or "timeline-stage" in classes or "footer-mark" in classes):
        add_label(story, plain_text(node), styles, "PgEyebrow" if "eyebrow" in classes else "PgLabel")
        return

    if node.name == "div" and "chips" in classes:
        for chip in node.find_all(class_="chip", recursive=False):
            add_paragraph(story, html.escape(plain_text(chip)), styles["PgListChip"])
        story.append(Spacer(1, 4))
        return

    if node.name in {"div", "section", "article", "footer"}:
        start_len = len(story)
        for child in node.children:
            append_node(child, story, styles, base_path)
        if node.name in {"section", "article", "footer"} and len(story) > start_len:
            story.append(Spacer(1, 8))


def build_story_from_html(source: Path, lang: str) -> tuple[list, str]:
    soup = BeautifulSoup(source.read_text(encoding="utf-8"), "html.parser")
    styles = build_styles()
    styles.add(
        ParagraphStyle(
            name="PgLabel",
            parent=styles["PgBody"],
            textColor=colors.HexColor("#6E5928"),
            fontSize=9.2,
            leading=12,
            spaceAfter=2,
        )
    )
    styles.add(
        ParagraphStyle(
            name="PgEyebrow",
            parent=styles["PgLabel"],
            fontSize=10,
            leading=13,
            spaceAfter=4,
        )
    )
    styles.add(
        ParagraphStyle(
            name="PgListChip",
            parent=styles["PgList"],
            leftIndent=0,
            spaceAfter=1,
        )
    )
    styles.add(
        ParagraphStyle(
            name="PgSmallNote",
            parent=styles["PgBody"],
            fontSize=9.4,
            leading=12,
            textColor=colors.HexColor("#666666"),
            spaceAfter=4,
        )
    )

    story: list = []
    bar = soup.select_one(f".bar .{lang}")
    if isinstance(bar, Tag):
        add_paragraph(story, flatten_children(bar), styles["PgBody"])
        story.append(Spacer(1, 6))

    wrapper = soup.select_one(f".lang-wrap.{lang}")
    if not isinstance(wrapper, Tag):
        body = soup.body
        if not isinstance(body, Tag):
            raise ValueError("Page body not found")
        wrapper = body

    for child in wrapper.find_all(recursive=False):
        append_node(child, story, styles, source.parent)

    footer = soup.find("footer")
    if isinstance(footer, Tag):
        footer_nodes = footer.select(f".{lang}")
        footer_mark = footer.select_one(".footer-mark")
        if footer_mark or footer_nodes:
            story.append(HRFlowable(width="100%", thickness=0.5, color=colors.HexColor("#BEBEBE"), spaceBefore=2, spaceAfter=6))
        if isinstance(footer_mark, Tag):
            add_label(story, plain_text(footer_mark), styles)
        for node in footer_nodes:
            add_paragraph(story, flatten_children(node), styles["PgBody"])

    title = source.stem
    body = soup.body
    if isinstance(body, Tag):
        attr = body.get(f"data-title-{lang}")
        if isinstance(attr, str) and attr.strip():
            title = attr.strip()

    return story, title


def convert_html_to_pdf(source: Path, target: Path, lang: str) -> None:
    from reportlab.platypus import SimpleDocTemplate
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.units import mm

    register_fonts()
    story, title = build_story_from_html(source, lang)
    doc = SimpleDocTemplate(
        str(target),
        pagesize=A4,
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        topMargin=16 * mm,
        bottomMargin=16 * mm,
        title=title,
        author="Cubecloud Limited",
        creator="safe_clarification_html_to_pdf.py",
    )
    doc.build(story)


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert a clarification HTML page to a viewer-safe PDF.")
    parser.add_argument("source", help="Source HTML file")
    parser.add_argument("target", nargs="?", help="Output PDF file")
    parser.add_argument("--lang", choices=["en", "zh"], default="en", help="Language block to export")
    args = parser.parse_args()

    source = Path(args.source)
    target = Path(args.target) if args.target else source.with_name(source.stem + f"-{args.lang}.pdf")
    convert_html_to_pdf(source, target, args.lang)


if __name__ == "__main__":
    main()