from __future__ import annotations

import argparse
import html
from pathlib import Path

from bs4 import BeautifulSoup, NavigableString, Tag
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import HRFlowable, Paragraph, Spacer

from safe_markdown_to_pdf import append_list, build_styles, build_table, flatten_children, plain_text, register_fonts


def add_paragraph(story: list, text: str, style) -> None:
    text = text.strip()
    if text:
        story.append(Paragraph(text, style))


def add_label(story: list, text: str, styles, style_name: str = "PgLabel") -> None:
    text = text.strip()
    if text:
        story.append(Paragraph(f"<b>{html.escape(text)}</b>", styles[style_name]))


def append_node(node: Tag | NavigableString, story: list, styles) -> None:
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
            append_node(child, story, styles)
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
        raise ValueError(f"Language block not found: {lang}")

    for child in wrapper.find_all(recursive=False):
        append_node(child, story, styles)

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