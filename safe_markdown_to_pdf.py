from __future__ import annotations

import argparse
import html
from pathlib import Path

import markdown
from bs4 import BeautifulSoup, NavigableString, Tag
from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, StyleSheet1, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.platypus import HRFlowable, Paragraph, Preformatted, SimpleDocTemplate, Spacer, Table, TableStyle


FONT_NAME = "STSong-Light"


def register_fonts() -> None:
    pdfmetrics.registerFont(UnicodeCIDFont(FONT_NAME))


def build_styles() -> StyleSheet1:
    stylesheet = getSampleStyleSheet()

    stylesheet.add(
        ParagraphStyle(
            name="PgBody",
            parent=stylesheet["BodyText"],
            fontName=FONT_NAME,
            fontSize=10.5,
            leading=15,
            alignment=TA_LEFT,
            spaceAfter=4,
        )
    )
    stylesheet.add(
        ParagraphStyle(
            name="PgQuote",
            parent=stylesheet["PgBody"],
            leftIndent=10 * mm,
            borderPadding=0,
            textColor=colors.HexColor("#444444"),
        )
    )
    stylesheet.add(
        ParagraphStyle(
            name="PgH1",
            parent=stylesheet["Heading1"],
            fontName=FONT_NAME,
            fontSize=20,
            leading=24,
            spaceBefore=6,
            spaceAfter=8,
        )
    )
    stylesheet.add(
        ParagraphStyle(
            name="PgH2",
            parent=stylesheet["Heading2"],
            fontName=FONT_NAME,
            fontSize=15,
            leading=20,
            spaceBefore=10,
            spaceAfter=6,
        )
    )
    stylesheet.add(
        ParagraphStyle(
            name="PgH3",
            parent=stylesheet["Heading3"],
            fontName=FONT_NAME,
            fontSize=12.5,
            leading=16,
            spaceBefore=8,
            spaceAfter=4,
        )
    )
    stylesheet.add(
        ParagraphStyle(
            name="PgH4",
            parent=stylesheet["Heading4"],
            fontName=FONT_NAME,
            fontSize=11.5,
            leading=14,
            spaceBefore=6,
            spaceAfter=3,
        )
    )
    stylesheet.add(
        ParagraphStyle(
            name="PgTable",
            parent=stylesheet["PgBody"],
            fontSize=8.8,
            leading=11,
            spaceAfter=0,
        )
    )
    stylesheet.add(
        ParagraphStyle(
            name="PgList",
            parent=stylesheet["PgBody"],
            leftIndent=6 * mm,
            firstLineIndent=0,
        )
    )
    return stylesheet


def inline_markup(node: Tag | NavigableString) -> str:
    if isinstance(node, NavigableString):
        return html.escape(str(node))

    if node.name == "br":
        return "<br/>"

    children = "".join(inline_markup(child) for child in node.children)

    if node.name in {"strong", "b"}:
        return f"<b>{children}</b>"
    if node.name in {"em", "i"}:
        return f"<i>{children}</i>"
    if node.name == "code":
        return f'<font name="Courier">{children}</font>'
    if node.name == "a":
        return f'<u><font color="#1f5fa8">{children}</font></u>'

    return children


def flatten_children(tag: Tag) -> str:
    return "".join(inline_markup(child) for child in tag.children).strip()


def plain_text(tag: Tag) -> str:
    text = tag.get_text("\n", strip=True)
    return text.replace("\xa0", " ")


def build_table(tag: Tag, styles: StyleSheet1) -> Table:
    rows = []
    for row in tag.find_all("tr"):
        cells = row.find_all(["th", "td"])
        rendered = []
        for cell in cells:
            cell_text = plain_text(cell)
            markup = html.escape(cell_text).replace("\n", "<br/>")
            rendered.append(Paragraph(markup, styles["PgTable"]))
        rows.append(rendered)

    col_count = max((len(row) for row in rows), default=1)
    usable_width = A4[0] - (18 * mm * 2)
    col_widths = [usable_width / col_count] * col_count

    table = Table(rows, colWidths=col_widths, repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("FONTNAME", (0, 0), (-1, -1), FONT_NAME),
                ("FONTSIZE", (0, 0), (-1, -1), 8.8),
                ("LEADING", (0, 0), (-1, -1), 11),
                ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#CFCFCF")),
                ("LINEBELOW", (0, 0), (-1, 0), 0.75, colors.HexColor("#9A9A9A")),
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#F2F2F2")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    return table


def append_list(tag: Tag, story: list, styles: StyleSheet1, ordered: bool) -> None:
    index = 1
    for item in tag.find_all("li", recursive=False):
        bullet = f"{index}." if ordered else "•"
        story.append(Paragraph(flatten_children(item), styles["PgList"], bulletText=bullet))
        index += 1
    story.append(Spacer(1, 2))


def build_story(markdown_text: str, styles: StyleSheet1) -> list:
    html_text = markdown.markdown(
        markdown_text,
        extensions=["tables", "fenced_code", "sane_lists"],
        output_format="html5",
    )
    soup = BeautifulSoup(html_text, "html.parser")

    story = []
    for element in soup.children:
        if not isinstance(element, Tag):
            continue

        if element.name == "h1":
            story.append(Paragraph(flatten_children(element), styles["PgH1"]))
        elif element.name == "h2":
            story.append(Paragraph(flatten_children(element), styles["PgH2"]))
        elif element.name == "h3":
            story.append(Paragraph(flatten_children(element), styles["PgH3"]))
        elif element.name == "h4":
            story.append(Paragraph(flatten_children(element), styles["PgH4"]))
        elif element.name == "p":
            story.append(Paragraph(flatten_children(element), styles["PgBody"]))
        elif element.name == "blockquote":
            for child in element.find_all("p", recursive=False):
                story.append(Paragraph(flatten_children(child), styles["PgQuote"]))
            story.append(Spacer(1, 2))
        elif element.name == "pre":
            code = plain_text(element)
            story.append(Preformatted(code, ParagraphStyle(name="PgCode", fontName="Courier", fontSize=8, leading=10)))
            story.append(Spacer(1, 4))
        elif element.name == "ul":
            append_list(element, story, styles, ordered=False)
        elif element.name == "ol":
            append_list(element, story, styles, ordered=True)
        elif element.name == "table":
            story.append(build_table(element, styles))
            story.append(Spacer(1, 6))
        elif element.name == "hr":
            story.append(HRFlowable(width="100%", thickness=0.6, color=colors.HexColor("#BEBEBE"), spaceBefore=4, spaceAfter=8))

    return story


def convert_markdown_to_pdf(source: Path, target: Path) -> None:
    register_fonts()
    styles = build_styles()
    markdown_text = source.read_text(encoding="utf-8")
    story = build_story(markdown_text, styles)

    doc = SimpleDocTemplate(
        str(target),
        pagesize=A4,
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        topMargin=16 * mm,
        bottomMargin=16 * mm,
        title=source.stem,
        author="Cubecloud Limited",
        creator="safe_markdown_to_pdf.py",
    )
    doc.build(story)


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert markdown to a viewer-safe PDF.")
    parser.add_argument("source", help="Source markdown file")
    parser.add_argument("target", nargs="?", help="Output PDF file")
    args = parser.parse_args()

    source = Path(args.source)
    target = Path(args.target) if args.target else source.with_suffix(".pdf")
    convert_markdown_to_pdf(source, target)


if __name__ == "__main__":
    main()