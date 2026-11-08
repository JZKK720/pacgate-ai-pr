"""Render the local-first legal AI stack reference to DOCX, PDF and Markdown.

One content module (`legal_ai_reference_content.py`), three renderings, so the
English and Chinese blocks cannot drift apart: every renderer walks the same
ordered list and emits the English block followed by its Chinese twin.

Two gates run before anything is written:

  * table shape   - every row must have exactly as many cells as the header
  * redaction     - no product, vendor or upstream runtime name may appear in
                    any rendered string (see BANNED_PATTERNS in the content
                    module). The document describes the system by role so a
                    reader can follow it without a product glossary, and so the
                    file can be shared outside the delivery relationship.

Usage:
    python scripts/render_legal_ai_reference.py --format all
    python scripts/render_legal_ai_reference.py --format pdf
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import legal_ai_reference_content as C  # noqa: E402

OUT_DIR = REPO / "docs"
DIAGRAM_DIR = REPO / "docs" / "diagrams" / "svg"
STEM = "LOCAL-FIRST-LEGAL-AI-STACK-REFERENCE"

DOC_ID = "CC-REF-LFAI-01"
REVISION = "rev 1.0"
ISSUED = dt.date.today().isoformat()
CLASSIFICATION = (
    "Internal reference - role names redacted / 内部参考 - 角色名替代"
)


# ─────────────────────────────────────────────────────────────────────────────
# Gates
# ─────────────────────────────────────────────────────────────────────────────

def iter_strings() -> list[str]:
    out: list[str] = []
    # Cover strings and document metadata are rendered into every output, so
    # they are checked by the same gate as the body text.
    out.extend([
        C.TITLE_EN, C.TITLE_ZH, C.SUBTITLE_EN, C.SUBTITLE_ZH,
        C.DOC_KIND_EN, C.DOC_KIND_ZH, C.AUTHOR, C.SUBJECT_EN,
    ])
    for block in C.BLOCKS:
        kind = block[0]
        if kind in {"h1", "h2", "h3", "p", "quote"}:
            out.extend(x for x in block[1:] if x)
        elif kind == "bullets":
            for en, zh in block[1]:
                out.extend([en, zh])
        elif kind == "figure":
            out.extend([block[2], block[3]])
        elif kind == "table":
            spec = block[1]
            for pair in spec["headers"]:
                out.extend(pair)
            for row in spec["rows"]:
                for pair in row:
                    out.extend(pair)
            out.extend(spec.get("note") or ())
    return out


def validate_tables() -> None:
    problems: list[str] = []
    for index, block in enumerate(C.BLOCKS):
        if block[0] != "table":
            continue
        spec = block[1]
        expected = len(spec["headers"])
        for row_index, row in enumerate(spec["rows"], start=1):
            if len(row) != expected:
                problems.append(
                    f"table #{index}: row {row_index} has {len(row)} cells, header has {expected}"
                )
        if len(spec["widths"]) != expected:
            problems.append(
                f"table #{index}: {len(spec['widths'])} widths for {expected} columns"
            )
        total = sum(spec["widths"])
        if abs(total - 1.0) > 0.02:
            problems.append(f"table #{index}: widths sum to {total:.3f}, expected 1.0")
        for pair in spec["headers"]:
            if len(pair) != 2:
                problems.append(f"table #{index}: header cell is not an (en, zh) pair")
    if problems:
        raise SystemExit("content validation failed:\n  " + "\n  ".join(problems))


def validate_redaction() -> None:
    patterns = [re.compile(p, re.IGNORECASE) for p in C.BANNED_PATTERNS]
    hits: list[str] = []
    for text in iter_strings():
        for pattern in patterns:
            for match in pattern.finditer(text):
                hits.append(f"{pattern.pattern!r} matched {match.group(0)!r} in {text[:60]!r}")
    if hits:
        raise SystemExit("redaction gate failed:\n  " + "\n  ".join(hits))


# ─────────────────────────────────────────────────────────────────────────────
# DOCX
# ─────────────────────────────────────────────────────────────────────────────

def build_docx(target: Path) -> None:
    from docx import Document
    from docx.enum.section import WD_ORIENT, WD_SECTION
    from docx.enum.table import WD_TABLE_ALIGNMENT
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.shared import Cm, Emu, Pt, RGBColor
    from PIL import Image as PILImage

    LATIN = "Segoe UI"
    CJK = "Microsoft YaHei"
    INK = RGBColor(0x1F, 0x2D, 0x44)
    GOLD = RGBColor(0xA6, 0x82, 0x3A)
    MUTED = RGBColor(0x5A, 0x5A, 0x5A)

    def style_run(run, size: float, bold: bool = False, colour: RGBColor | None = None):
        run.font.name = LATIN
        run.font.size = Pt(size)
        run.bold = bold
        if colour is not None:
            run.font.color.rgb = colour
        rpr = run._element.get_or_add_rPr()
        fonts = rpr.find(qn("w:rFonts"))
        if fonts is None:
            fonts = OxmlElement("w:rFonts")
            rpr.append(fonts)
        fonts.set(qn("w:eastAsia"), CJK)
        fonts.set(qn("w:ascii"), LATIN)
        fonts.set(qn("w:hAnsi"), LATIN)

    def add_para(container, text, size=10.0, bold=False, colour=None,
                 align=None, space_before=0, space_after=6, italic=False, indent=None,
                 keep_with_next=False, right_indent=None):
        paragraph = container.add_paragraph()
        paragraph.paragraph_format.space_before = Pt(space_before)
        paragraph.paragraph_format.space_after = Pt(space_after)
        paragraph.paragraph_format.line_spacing = 1.18
        paragraph.paragraph_format.keep_with_next = keep_with_next
        if indent is not None:
            paragraph.paragraph_format.left_indent = Cm(indent)
        if right_indent is not None:
            paragraph.paragraph_format.right_indent = Cm(right_indent)
        if align is not None:
            paragraph.alignment = align
        run = paragraph.add_run(text)
        style_run(run, size, bold, colour)
        run.italic = italic
        return paragraph

    def shade(cell, fill: str):
        tc_pr = cell._tc.get_or_add_tcPr()
        shd = OxmlElement("w:shd")
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:color"), "auto")
        shd.set(qn("w:fill"), fill)
        tc_pr.append(shd)

    def cell_margins(table, top=60, bottom=60, left=100, right=100):
        tbl_pr = table._tbl.tblPr
        mar = OxmlElement("w:tblCellMar")
        for tag, value in (("top", top), ("left", left), ("bottom", bottom), ("right", right)):
            node = OxmlElement(f"w:{tag}")
            node.set(qn("w:w"), str(value))
            node.set(qn("w:type"), "dxa")
            mar.append(node)
        tbl_pr.append(mar)

    def page_field(paragraph):
        fld = OxmlElement("w:fldSimple")
        fld.set(qn("w:instr"), "PAGE")
        run = OxmlElement("w:r")
        text = OxmlElement("w:t")
        text.text = "1"
        run.append(text)
        fld.append(run)
        paragraph._p.append(fld)

    def add_table(doc, spec):
        headers = spec["headers"]
        rows = spec["rows"]
        # Row 0 holds the caption, spanned across the full width. Kept as a
        # paragraph above the table the caption can be stranded on the previous
        # page while the table starts on the next one; inside the table it
        # cannot detach, and it repeats with the header on continuation pages.
        table = doc.add_table(rows=2 + len(rows), cols=len(headers))
        table.style = "Table Grid"
        table.alignment = WD_TABLE_ALIGNMENT.CENTER
        table.autofit = False
        cell_margins(table)

        caption_en, caption_zh = spec["note"][0], spec["note"][1]

        section = doc.sections[-1]
        usable_emu = int(section.page_width) - int(section.left_margin) - int(section.right_margin)
        widths = [Emu(int(usable_emu * fraction)) for fraction in spec["widths"]]

        def fill(cell, en: str, zh: str, header: bool, caption: bool = False):
            cell.text = ""
            first = cell.paragraphs[0]
            first.paragraph_format.space_after = Pt(1)
            first.paragraph_format.line_spacing = 1.1
            run = first.add_run(en)
            style_run(run, 8.6 if caption else (8.8 if header else 8.3), bold=header,
                      colour=RGBColor(0x2F, 0x27, 0x1A) if header else MUTED)
            if zh:
                second = cell.add_paragraph()
                second.paragraph_format.space_after = Pt(1)
                second.paragraph_format.line_spacing = 1.16
                run = second.add_run(zh)
                style_run(run, 8.0 if caption else (8.2 if header else 7.9), bold=header,
                          colour=GOLD if header else RGBColor(0x4A, 0x4A, 0x4A))

        caption_row = table.rows[0]
        caption_cell = caption_row.cells[0]
        fill(caption_cell, caption_en, caption_zh, header=False, caption=True)
        caption_cell.merge(caption_row.cells[-1])
        for cell in caption_row.cells:
            shade(cell, "FFFFFF")
        caption_props = caption_row._tr.get_or_add_trPr()
        caption_props.append(OxmlElement("w:cantSplit"))
        # Word repeats a header only when the marked rows are the table's first
        # rows, so the caption row carries the flag too; the caption then labels
        # every continuation page instead of vanishing with the first page.
        caption_flag = OxmlElement("w:tblHeader")
        caption_flag.set(qn("w:val"), "true")
        caption_props.append(caption_flag)
        # Keep the caption and the column labels attached to the first data row,
        # so a table that starts near a page foot does not leave a caption alone.
        for cell in caption_row.cells:
            for paragraph in cell.paragraphs:
                paragraph.paragraph_format.keep_with_next = True

        header_row = table.rows[1]
        for col, pair in enumerate(headers):
            cell = header_row.cells[col]
            cell.width = widths[col]
            fill(cell, pair[0], pair[1], True)
            shade(cell, "F3E7C7")
            for paragraph in cell.paragraphs:
                paragraph.paragraph_format.keep_with_next = True
        # Without tblHeader a long table continues onto the next page with no
        # column labels, which is unreadable for the 8- to 9-row tables.
        row_props = header_row._tr.get_or_add_trPr()
        header_flag = OxmlElement("w:tblHeader")
        header_flag.set(qn("w:val"), "true")
        row_props.append(header_flag)

        for row_index, row in enumerate(rows, start=2):
            for col, pair in enumerate(row):
                cell = table.rows[row_index].cells[col]
                cell.width = widths[col]
                fill(cell, pair[0], pair[1], False)
                if row_index % 2 == 0:
                    shade(cell, "FAFAF8")
            # Keep each row whole: a row split across a page boundary separates
            # the English line from its Chinese counterpart.
            table.rows[row_index]._tr.get_or_add_trPr().append(OxmlElement("w:cantSplit"))
        return table

    def set_section(section, landscape: bool):
        if landscape:
            section.orientation = WD_ORIENT.LANDSCAPE
            section.page_width = Cm(29.7)
            section.page_height = Cm(21.0)
        else:
            section.orientation = WD_ORIENT.PORTRAIT
            section.page_width = Cm(21.0)
            section.page_height = Cm(29.7)
        section.left_margin = Cm(2.0)
        section.right_margin = Cm(2.0)
        section.top_margin = Cm(1.9)
        section.bottom_margin = Cm(1.7)

    def decorate_footer(section):
        footer = section.footer
        paragraph = footer.paragraphs[0]
        paragraph.text = ""
        paragraph.alignment = WD_ALIGN_PARAGRAPH.RIGHT
        run = paragraph.add_run(f"{DOC_ID}  |  {CLASSIFICATION}  |  ")
        style_run(run, 7.5, colour=MUTED)
        page_field(paragraph)

    document = Document()
    props = document.core_properties
    props.title = f"{C.TITLE_EN} / {C.TITLE_ZH}"
    props.author = C.AUTHOR
    props.subject = C.SUBJECT_EN
    props.comments = ""
    props.keywords = DOC_ID
    props.category = CLASSIFICATION
    props.last_modified_by = C.AUTHOR
    # python-docx inherits a 2013 template timestamp, which misreports the issue
    # date in every file property panel.
    stamped = dt.datetime.now().replace(microsecond=0)
    props.created = stamped
    props.modified = stamped
    normal = document.styles["Normal"]
    normal.font.name = LATIN
    normal.font.size = Pt(10)
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), CJK)

    set_section(document.sections[0], landscape=False)
    decorate_footer(document.sections[0])

    # ── cover ────────────────────────────────────────────────────────────────
    add_para(document, C.DOC_KIND_EN, 9.5, bold=True, colour=GOLD, space_before=54, space_after=2)
    add_para(document, C.DOC_KIND_ZH, 9.5, bold=True, colour=GOLD, space_after=26)
    add_para(document, C.TITLE_EN, 25.0, bold=True, colour=INK, space_after=2)
    add_para(document, C.TITLE_ZH, 21.0, bold=True, colour=INK, space_after=14)
    add_para(document, C.SUBTITLE_EN, 12.0, colour=MUTED, space_after=1)
    add_para(document, C.SUBTITLE_ZH, 11.0, colour=MUTED, space_after=30)

    meta_rows = [
        ("Document", "文档编号", f"{DOC_ID}   {REVISION}"),
        ("Issued", "签发日期", ISSUED),
        ("Audience", "读者对象", "Client reviewers, procurement, and technical due diligence / 客户审查、采购与技术尽职调查"),
        ("Basis", "编制依据", "Read from the shipped source tree and deployment definition / 取自交付源码树与部署定义"),
    ]
    meta = document.add_table(rows=len(meta_rows), cols=3)
    meta.autofit = False
    cell_margins(meta)
    meta_widths = [Cm(3.2), Cm(3.4), Cm(10.4)]
    for index, (key_en, key_zh, value) in enumerate(meta_rows):
        for col, (text, size, bold) in enumerate(
            ((key_en, 8.5, True), (key_zh, 8.5, False), (value, 8.5, False))
        ):
            cell = meta.rows[index].cells[col]
            cell.width = meta_widths[col]
            cell.text = ""
            run = cell.paragraphs[0].add_run(text)
            style_run(run, size, bold=bold, colour=INK if col < 2 else MUTED)

    add_para(
        document,
        "Role names replace every product, vendor and upstream runtime name; see Table 1. "
        "Counts, limits and states are read from the delivered code, not estimated.",
        8.5, colour=MUTED, space_before=16, space_after=0, italic=True,
    )
    add_para(
        document,
        "本文以角色名替代全部产品名、厂商名与上游运行时名，见表 1。数量、上限与状态均取自交付代码，未作估算。",
        8.5, colour=MUTED, space_after=0, italic=True,
    )

    # ── body ─────────────────────────────────────────────────────────────────
    # One landscape section for the whole body, as in the PDF renderer. Adding a
    # section per wide table produced 33 pages with a dozen near-empty ones:
    # each switch forces a page break, and a table that then does not fit
    # breaks again. A landscape column suits a reference document that is
    # mostly tables, and one section removes every forced break.
    body_section = document.add_section(WD_SECTION.NEW_PAGE)
    set_section(body_section, landscape=True)
    body_section.footer.is_linked_to_previous = False
    decorate_footer(body_section)
    usable_width = body_section.page_width - body_section.left_margin - body_section.right_margin
    # Prose is held to about the A4 portrait measure so a landscape line does not
    # run 25 cm wide; tables keep the full usable width.
    prose_right_cm = 7.0
    figure_width = min(usable_width, Cm(25.2))

    for block in C.BLOCKS:
        kind = block[0]

        if kind == "h1":
            add_para(document, block[1], 16.0, bold=True, colour=INK, space_before=10, space_after=1,
                     keep_with_next=True)
            add_para(document, block[2], 12.5, bold=True, colour=GOLD, space_after=10, keep_with_next=True)
        elif kind == "h2":
            add_para(document, block[1], 12.5, bold=True, colour=INK, space_before=8, space_after=1,
                     keep_with_next=True)
            add_para(document, block[2], 11.0, bold=True, colour=GOLD, space_after=6, keep_with_next=True)
        elif kind == "h3":
            add_para(document, block[1], 10.5, bold=True, colour=INK, space_before=6, space_after=1,
                     keep_with_next=True)
            add_para(document, block[2], 10.0, bold=True, colour=GOLD, space_after=4, keep_with_next=True)
        elif kind == "p":
            # The English line keeps with its Chinese counterpart: split across
            # a page break the pair reads as two unrelated paragraphs.
            add_para(document, block[1], 10.0, colour=INK, space_after=4,
                     right_indent=prose_right_cm, keep_with_next=True)
            add_para(document, block[2], 9.8, colour=INK, space_after=9,
                     right_indent=prose_right_cm)
        elif kind == "quote":
            for text, size in ((block[1], 10.2), (block[2], 10.0)):
                paragraph = add_para(
                    document, text, size, colour=RGBColor(0x4E, 0x46, 0x37),
                    space_after=4, indent=0.45, italic=False, right_indent=prose_right_cm,
                )
                paragraph.paragraph_format.right_indent = Cm(0.4)
            add_para(document, "", 4.0, space_after=4)
        elif kind == "bullets":
            for en, zh in block[1]:
                add_para(document, f"- {en}", 9.8, colour=INK, space_after=2, indent=0.5,
                         right_indent=prose_right_cm)
                add_para(document, f"- {zh}", 9.6, colour=INK, space_after=6, indent=0.5,
                         right_indent=prose_right_cm)
        elif kind == "figure":
            path = DIAGRAM_DIR / block[1]
            with PILImage.open(path) as im:
                native_w, native_h = im.size
            usable_height = (
                body_section.page_height - body_section.top_margin - body_section.bottom_margin
            )
            # A figure that fills most of the frame cannot share a page with the
            # section intro above it, so Word pushes it to the next page and
            # leaves a nearly empty one behind. Capping at 55 per cent of the
            # usable height lets the intro and the figure sit together.
            height_cap = int(int(usable_height) * 0.55)
            width_by_height = Emu(int(height_cap * native_w / native_h))
            draw_width = min(figure_width, width_by_height)
            document.add_picture(str(path), width=draw_width)
            picture_para = document.paragraphs[-1]
            picture_para.alignment = WD_ALIGN_PARAGRAPH.CENTER
            # The caption has to stay with the image it explains, so the
            # picture paragraph itself carries keep-with-next as well.
            picture_para.paragraph_format.keep_with_next = True
            picture_para.paragraph_format.space_after = Pt(0)
            add_para(document, block[2], 8.4, colour=MUTED, align=WD_ALIGN_PARAGRAPH.CENTER,
                     space_before=4, space_after=1, italic=True, keep_with_next=True)
            add_para(document, block[3], 8.4, colour=MUTED, align=WD_ALIGN_PARAGRAPH.CENTER,
                     space_before=0, space_after=10, italic=True)
        elif kind == "table":
            spec = block[1]
            add_table(document, spec)
            add_para(document, "", 4.0, space_after=10)
        elif kind == "pagebreak":
            document.add_page_break()

    document.save(str(target))


# ─────────────────────────────────────────────────────────────────────────────
# PDF
# ─────────────────────────────────────────────────────────────────────────────

def build_pdf(target: Path) -> None:
    from PIL import Image as PILImage
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT
    from reportlab.lib.pagesizes import A4, landscape as a4_landscape
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.lib.units import mm
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.cidfonts import UnicodeCIDFont
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.platypus import (
        BaseDocTemplate, CondPageBreak, Frame, Image, KeepTogether,
        NextPageTemplate, PageBreak, PageTemplate, Paragraph, Spacer, Table,
        TableStyle,
    )

    ink = colors.HexColor("#1F2D44")
    gold = colors.HexColor("#A6832A")
    muted = colors.HexColor("#5A5A5A")
    rule = colors.HexColor("#D8D8D8")
    header_fill = colors.HexColor("#F3E7C7")
    zebra = colors.HexColor("#FAFAF8")
    quote_ink = colors.HexColor("#4E4637")
    quote_fill = colors.HexColor("#FBF6EA")

    font_name = "STSong-Light"
    bold_name = font_name
    windows_font = Path("C:/Windows/Fonts/msyh.ttc")
    windows_bold = Path("C:/Windows/Fonts/msyhbd.ttc")
    try:
        if windows_font.exists():
            pdfmetrics.registerFont(TTFont("RefCJK", str(windows_font), subfontIndex=0))
            font_name = "RefCJK"
            bold_name = "RefCJK"
            if windows_bold.exists():
                pdfmetrics.registerFont(TTFont("RefCJKBold", str(windows_bold), subfontIndex=0))
                bold_name = "RefCJKBold"
    except Exception:  # noqa: BLE001 - fall back to the CID font, never fail the build
        pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
        font_name = "STSong-Light"
        bold_name = "STSong-Light"

    # Prose is indented on the right so a landscape line does not run 25 cm
    # wide: at 10 pt a full-width landscape line holds ~200 characters, which
    # is unreadable. The measure below is ~110 characters, close to the A4
    # portrait width this text was written for.
    prose_right_indent = 62 * mm

    styles = {
        "title": ParagraphStyle("title", fontName=bold_name, fontSize=25, leading=30, textColor=ink, spaceAfter=2),
        "title_zh": ParagraphStyle("title_zh", fontName=bold_name, fontSize=21, leading=26, textColor=ink, spaceAfter=12, wordWrap="CJK"),
        "kind": ParagraphStyle("kind", fontName=bold_name, fontSize=9.5, leading=13, textColor=gold, spaceAfter=2),
        "subtitle": ParagraphStyle("subtitle", fontName=font_name, fontSize=11.5, leading=16, textColor=muted, spaceAfter=2, wordWrap="CJK"),
        "meta": ParagraphStyle("meta", fontName=font_name, fontSize=8.5, leading=12, textColor=muted),
        "h1": ParagraphStyle("h1", fontName=bold_name, fontSize=16, leading=21, textColor=ink,
                             spaceBefore=8, spaceAfter=1, keepWithNext=1),
        "h1_zh": ParagraphStyle("h1_zh", fontName=bold_name, fontSize=12.5, leading=17, textColor=gold,
                                spaceAfter=9, keepWithNext=1, wordWrap="CJK"),
        "h2": ParagraphStyle("h2", fontName=bold_name, fontSize=12.5, leading=17, textColor=ink,
                             spaceBefore=6, spaceAfter=1, keepWithNext=1),
        "h2_zh": ParagraphStyle("h2_zh", fontName=bold_name, fontSize=11, leading=15, textColor=gold,
                                spaceAfter=5, keepWithNext=1, wordWrap="CJK"),
        "body": ParagraphStyle("body", fontName=font_name, fontSize=10.0, leading=15.4, textColor=ink,
                                alignment=TA_LEFT, spaceAfter=4,
                                leftIndent=0, rightIndent=prose_right_indent, wordWrap="CJK"),
        # Chinese body is set flush-left, not justified. Justification distributes
        # slack across the few spaces a CJK line contains, so a line with one space
        # (e.g. before a table number) opens a gap several characters wide.
        "body_zh": ParagraphStyle("body_zh", fontName=font_name, fontSize=9.7, leading=15.8, textColor=ink,
                                   alignment=TA_LEFT, spaceAfter=9, rightIndent=prose_right_indent,
                                   wordWrap="CJK"),
        "bullet": ParagraphStyle("bullet", fontName=font_name, fontSize=9.7, leading=14.8, textColor=ink,
                                  leftIndent=10, bulletIndent=2, spaceAfter=3,
                                  rightIndent=prose_right_indent, wordWrap="CJK"),
        "quote": ParagraphStyle("quote", fontName=font_name, fontSize=10, leading=15.8, textColor=quote_ink,
                                 leftIndent=10, rightIndent=prose_right_indent + 8,
                                 backColor=quote_fill, borderColor=colors.HexColor("#D7C38B"),
                                 borderWidth=0.6, borderPadding=7, spaceBefore=4, spaceAfter=10,
                                 wordWrap="CJK"),
        "caption": ParagraphStyle("caption", fontName=font_name, fontSize=8.2, leading=11.6, textColor=muted,
                                   alignment=TA_CENTER, spaceBefore=3, spaceAfter=1, wordWrap="CJK"),
        "table_note": ParagraphStyle("table_note", fontName=font_name, fontSize=8.2, leading=11.4,
                                     textColor=muted, alignment=TA_LEFT, wordWrap="CJK"),
        "cell_h": ParagraphStyle("cell_h", fontName=bold_name, fontSize=7.9, leading=10.4,
                                 textColor=colors.HexColor("#2F271A"), wordWrap="CJK"),
        "cell": ParagraphStyle("cell", fontName=font_name, fontSize=7.5, leading=10.1, textColor=ink, wordWrap="CJK"),
    }

    def esc(text: str) -> str:
        return html.escape(text, quote=False)

    def header_footer(canvas, doc):
        canvas.saveState()
        width, height = doc.pagesize
        canvas.setStrokeColor(rule)
        canvas.setLineWidth(0.55)
        canvas.line(doc.leftMargin, height - 12.5 * mm, width - doc.rightMargin, height - 12.5 * mm)
        canvas.setFillColor(muted)
        canvas.setFont(font_name, 7.4)
        canvas.drawString(doc.leftMargin, height - 10 * mm, f"{DOC_ID}  {REVISION}")
        canvas.drawRightString(width - doc.rightMargin, height - 10 * mm, CLASSIFICATION)
        canvas.line(doc.leftMargin, 12.5 * mm, width - doc.rightMargin, 12.5 * mm)
        canvas.drawString(doc.leftMargin, 8.6 * mm, C.TITLE_EN)
        canvas.setFont(font_name, 8.2)
        canvas.drawRightString(width - doc.rightMargin, 8.6 * mm, str(canvas.getPageNumber()))
        canvas.restoreState()

    def cover_page(canvas, doc):
        header_footer(canvas, doc)

    portrait_size = A4
    landscape_size = a4_landscape(A4)
    margin_x = 22 * mm

    doc = BaseDocTemplate(
        str(target), pagesize=portrait_size,
        leftMargin=margin_x, rightMargin=margin_x,
        topMargin=17 * mm, bottomMargin=17 * mm,
        title=f"{C.TITLE_EN} / {C.TITLE_ZH}", author=C.AUTHOR,
        subject=C.SUBJECT_EN, creator="scripts/render_legal_ai_reference.py",
    )

    portrait_frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="portrait")
    land = landscape_size
    landscape_frame = Frame(
        margin_x, 17 * mm, land[0] - 2 * margin_x, land[1] - 34 * mm, id="landscape",
    )
    doc.addPageTemplates([
        PageTemplate(id="portrait", frames=[portrait_frame], pagesize=portrait_size,
                     onPage=cover_page),
        PageTemplate(id="landscape", frames=[landscape_frame], pagesize=landscape_size,
                     onPage=header_footer),
    ])

    body_width = land[0] - 2 * margin_x
    frame_height = (land[1] - 34 * mm) - 26 * mm

    story: list = []

    # ── cover ────────────────────────────────────────────────────────────────
    story.append(Spacer(1, 52 * mm))
    story.append(Paragraph(esc(C.DOC_KIND_EN), styles["kind"]))
    story.append(Paragraph(esc(C.DOC_KIND_ZH), styles["kind"]))
    story.append(Spacer(1, 14))
    story.append(Paragraph(esc(C.TITLE_EN), styles["title"]))
    story.append(Paragraph(esc(C.TITLE_ZH), styles["title_zh"]))
    story.append(Paragraph(esc(C.SUBTITLE_EN), styles["subtitle"]))
    story.append(Paragraph(esc(C.SUBTITLE_ZH), styles["subtitle"]))
    story.append(Spacer(1, 26))

    meta_data = [
        [Paragraph(esc("Document / 文档编号"), styles["meta"]),
         Paragraph(esc(f"{DOC_ID}   {REVISION}"), styles["meta"])],
        [Paragraph(esc("Issued / 签发日期"), styles["meta"]), Paragraph(esc(ISSUED), styles["meta"])],
        [Paragraph(esc("Audience / 读者对象"), styles["meta"]),
         Paragraph(esc("Client reviewers, procurement, and technical due diligence / 客户审查、采购与技术尽职调查"), styles["meta"])],
        [Paragraph(esc("Basis / 编制依据"), styles["meta"]),
         Paragraph(esc("Read from the shipped source tree and deployment definition / 取自交付源码树与部署定义"), styles["meta"])],
    ]
    meta_table = Table(meta_data, colWidths=[42 * mm, doc.width - 42 * mm])
    meta_table.setStyle(TableStyle([
        ("LINEBELOW", (0, 0), (-1, -2), 0.4, rule),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]))
    story.append(meta_table)
    story.append(Spacer(1, 14))
    story.append(Paragraph(
        esc("Role names replace every product, vendor and upstream runtime name; see Table 1. "
            "Counts, limits and states are read from the delivered code, not estimated."),
        styles["caption"]))
    story.append(Paragraph(
        esc("本文以角色名替代全部产品名、厂商名与上游运行时名，见表 1。数量、上限与状态均取自交付代码，未作估算。"),
        styles["caption"]))
    story.append(NextPageTemplate("landscape"))
    story.append(PageBreak())

    # ── body ─────────────────────────────────────────────────────────────────
    # The body is one continuous landscape run. Mixing orientations mid-section
    # produced two defect classes that no amount of keep-together fixed: a
    # section intro stranded alone on a portrait page before its landscape
    # table, and table rows orphaned from their caption. A single orientation
    # removes both, and a landscape column is the right shape for a reference
    # document that is mostly tables.
    current = "landscape"

    def make_table(spec: dict) -> Table:
        def cell(pair, header: bool) -> Paragraph:
            en, zh = pair[0], pair[1]
            body = f'<b>{esc(en)}</b>'
            if zh:
                body += f'<br/><font size="6.9" color="#4A4A4A">{esc(zh)}</font>'
            return Paragraph(body, styles["cell_h"] if header else styles["cell"])

        headers = [cell(pair, True) for pair in spec["headers"]]
        rows = [[cell(pair, False) for pair in row] for row in spec["rows"]]
        widths = [body_width * fraction for fraction in spec["widths"]]

        # The caption is the table's first row, spanned across every column.
        # Kept as a separate flowable above the table it can be stranded alone
        # at a page foot when the table then breaks; inside the table it cannot
        # separate, and with repeatRows it also labels every continuation page.
        caption = (
            f'{esc(spec["note"][0])}<br/>'
            f'<font size="7.1" color="#6B6B6B">{esc(spec["note"][1])}</font>'
        )
        caption_row = [Paragraph(caption, styles["table_note"])] + [""] * (len(headers) - 1)
        table = Table([caption_row, headers] + rows, colWidths=widths, repeatRows=2)
        style = [
            ("SPAN", (0, 0), (-1, 0)),
            ("LEFTPADDING", (0, 0), (-1, 0), 0),
            ("RIGHTPADDING", (0, 0), (-1, 0), 0),
            ("TOPPADDING", (0, 0), (-1, 0), 0),
            ("BOTTOMPADDING", (0, 0), (-1, 0), 2),
            ("BACKGROUND", (0, 0), (-1, 0), colors.white),
            ("BACKGROUND", (0, 1), (-1, 1), header_fill),
            ("LINEBELOW", (0, 1), (-1, 1), 0.9, gold),
            ("GRID", (0, 1), (-1, -1), 0.35, colors.HexColor("#CFCFCF")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 1), (-1, -1), 4.2),
            ("RIGHTPADDING", (0, 1), (-1, -1), 4.2),
            ("TOPPADDING", (0, 1), (-1, -1), 3.2),
            ("BOTTOMPADDING", (0, 1), (-1, -1), 3.6),
        ]
        for index in range(2, len(rows) + 2):
            if index % 2 == 0:
                style.append(("BACKGROUND", (0, index), (-1, index), zebra))
        table.setStyle(TableStyle(style))
        return table

    for block in C.BLOCKS:
        kind = block[0]

        if kind == "pagebreak":
            story.append(PageBreak())
            continue

        if kind == "table":
            spec = block[1]
            story.append(make_table(spec))
            story.append(Spacer(1, 10))
            continue

        if kind == "figure":
            path = DIAGRAM_DIR / block[1]
            with PILImage.open(path) as im:
                native_w, native_h = im.size
            scale = min(0.5, body_width / native_w, frame_height / native_h)
            draw_w, draw_h = native_w * scale, native_h * scale
            image = Image(str(path), width=draw_w, height=draw_h)
            image.hAlign = "CENTER"
            # The caption is what makes the image mean anything, so the two
            # travel together; the conditional break moves the whole block to
            # the next page rather than leaving a figure with no legend.
            story.append(CondPageBreak(draw_h + 16 * mm))
            story.append(KeepTogether([
                image,
                Paragraph(esc(block[2]), styles["caption"]),
                Paragraph(esc(block[3]), styles["caption"]),
            ]))
            story.append(Spacer(1, 8))
            continue

        if kind == "h1":
            # A heading needs room for its own block plus the paragraph pair
            # that follows, otherwise keepWithNext chains break and the
            # heading is stranded at a page foot with nothing under it.
            story.append(CondPageBreak(52 * mm))
            story.append(Paragraph(esc(block[1]), styles["h1"]))
            story.append(Paragraph(esc(block[2]), styles["h1_zh"]))
        elif kind == "h2":
            story.append(CondPageBreak(42 * mm))
            story.append(Paragraph(esc(block[1]), styles["h2"]))
            story.append(Paragraph(esc(block[2]), styles["h2_zh"]))
        elif kind == "h3":
            story.append(CondPageBreak(38 * mm))
            story.append(Paragraph(esc(block[1]), styles["h2"]))
            story.append(Paragraph(esc(block[2]), styles["h2_zh"]))
        elif kind == "p":
            story.append(KeepTogether([
                Paragraph(esc(block[1]), styles["body"]),
                Paragraph(esc(block[2]), styles["body_zh"]),
            ]))
        elif kind == "quote":
            story.append(KeepTogether([
                Paragraph(esc(block[1]), styles["quote"]),
                Paragraph(esc(block[2]), styles["quote"]),
            ]))
        elif kind == "bullets":
            for en, zh in block[1]:
                story.append(KeepTogether([
                    Paragraph(esc(en), styles["bullet"], bulletText="\u2022"),
                    Paragraph(esc(zh), styles["bullet"], bulletText="\u2022"),
                ]))
            story.append(Spacer(1, 5))

    doc.build(story)


# ─────────────────────────────────────────────────────────────────────────────
# Markdown
# ─────────────────────────────────────────────────────────────────────────────

def build_markdown(target: Path) -> None:
    def md_cell(text: str) -> str:
        return text.replace("|", "\\|").replace("\n", " ")

    lines: list[str] = []
    lines.append(f"# {C.TITLE_EN}")
    lines.append("")
    lines.append(f"## {C.TITLE_ZH}")
    lines.append("")
    lines.append(f"*{C.SUBTITLE_EN}*")
    lines.append("")
    lines.append(f"*{C.SUBTITLE_ZH}*")
    lines.append("")
    lines.append(f"> {DOC_ID} - {REVISION} - {ISSUED} - {CLASSIFICATION}")
    lines.append(">")
    lines.append("> Role names replace every product, vendor and upstream runtime name; see Table 1.")
    lines.append("> 本文以角色名替代全部产品名、厂商名与上游运行时名，见表 1。")
    lines.append("")

    for block in C.BLOCKS:
        kind = block[0]
        if kind == "h1":
            lines.append(f"## {block[1]}")
            lines.append("")
            lines.append(f"### {block[2]}")
            lines.append("")
        elif kind == "h2":
            lines.append(f"### {block[1]}")
            lines.append("")
            lines.append(f"#### {block[2]}")
            lines.append("")
        elif kind == "h3":
            lines.append(f"#### {block[1]}")
            lines.append("")
            lines.append(f"##### {block[2]}")
            lines.append("")
        elif kind == "p":
            lines.append(block[1])
            lines.append("")
            lines.append(block[2])
            lines.append("")
        elif kind == "quote":
            lines.append(f"> {block[1]}")
            lines.append(">")
            lines.append(f"> {block[2]}")
            lines.append("")
        elif kind == "bullets":
            for en, zh in block[1]:
                lines.append(f"- {en}")
                lines.append(f"- {zh}")
            lines.append("")
        elif kind == "figure":
            lines.append(f"![{block[2]}](diagrams/svg/{block[1]})")
            lines.append("")
            lines.append(f"*{block[2]}*")
            lines.append("")
            lines.append(f"*{block[3]}*")
            lines.append("")
        elif kind == "table":
            spec = block[1]
            headers = [f"{pair[0]} / {pair[1]}" for pair in spec["headers"]]
            lines.append(f"**{spec['note'][0]}**")
            lines.append("")
            lines.append(f"*{spec['note'][1]}*")
            lines.append("")
            lines.append("| " + " | ".join(md_cell(h) for h in headers) + " |")
            lines.append("|" + "|".join([" --- "] * len(headers)) + "|")
            for row in spec["rows"]:
                cells = [md_cell(f"{pair[0]}<br/>{pair[1]}") for pair in row]
                lines.append("| " + " | ".join(cells) + " |")
            lines.append("")
        elif kind == "pagebreak":
            lines.append("---")
            lines.append("")

    target.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def safe_write(target: Path, writer) -> None:
    """Write via a temp file, then move into place.

    A viewer can hold the previous render open (WPS or Word do this on
    Windows). Writing the final path directly then fails with a permission
    error after minutes of work; writing beside it and moving lets the caller
    see a clearly named conflict instead.
    """
    tmp = target.with_suffix(target.suffix + ".tmp")
    if tmp.exists():
        tmp.unlink()
    writer(tmp)
    try:
        tmp.replace(target)
    except PermissionError as exc:  # pragma: no cover - depends on the desktop
        raise SystemExit(
            f"cannot replace {target.name}: it is open in another application.\n"
            f"Close it and re-run; the new render is at {tmp.name}.\n({exc})"
        ) from exc


def artifact_text(path: Path) -> str:
    """Extract the text a reader would actually receive from a rendered file.

    The input gate only proves that the source content is clean. This reads the
    finished artefact back, including the PDF metadata and the DOCX core
    properties, so a name that leaks through a metadata field or a rendering
    path is caught in the delivered file rather than in the intent.
    """
    if path.suffix == ".pdf":
        return _pdf_text(path)
    if path.suffix == ".docx":
        import zipfile

        with zipfile.ZipFile(path) as archive:
            parts = []
            for name in ("word/document.xml", "docProps/core.xml", "docProps/app.xml"):
                if name in archive.namelist():
                    parts.append(re.sub(r"<[^>]+>", " ", archive.read(name).decode("utf-8", "ignore")))
            return "\n".join(parts)
    return path.read_text(encoding="utf-8")


def _pdf_text(path: Path) -> str:
    """Text of a PDF, preferring an in-process extractor.

    Text drawn with a subset TrueType font is glyph-encoded, so scanning the
    raw bytes finds nothing: the readback needs a font-aware extractor. PyMuPDF
    may live in a different interpreter than the one rendering this document,
    so it is tried in-process first and then in whatever `python` is on PATH.
    """
    try:
        import fitz  # noqa: PLC0415 - optional dependency, absent in the venv

        document = fitz.open(path)
        parts = [" ".join(str(v) for v in (document.metadata or {}).values())]
        parts.extend(page.get_text() for page in document)
        return "\n".join(parts)
    except ImportError:
        pass

    script = (
        "import sys, fitz\n"
        "d = fitz.open(sys.argv[1])\n"
        "print(' '.join(str(v) for v in (d.metadata or {}).values()))\n"
        "print(''.join(p.get_text() for p in d))\n"
    )
    for candidate in ("python", "python3"):
        executable = shutil.which(candidate)
        if not executable:
            continue
        result = subprocess.run(
            [executable, "-c", script, str(path)],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout
    raise RuntimeError(
        "no PDF text extractor available: install PyMuPDF, or verify the PDF by opening it"
    )


def verify_artifacts(paths: list[Path]) -> None:
    patterns = [re.compile(p, re.IGNORECASE) for p in C.BANNED_PATTERNS]
    failures: list[str] = []
    for path in paths:
        try:
            text = artifact_text(path)
        except Exception as exc:  # noqa: BLE001 - report, never mask a clean run
            failures.append(f"{path.name}: could not be read back ({exc})")
            continue
        for pattern in patterns:
            for match in pattern.finditer(text):
                failures.append(f"{path.name}: {pattern.pattern!r} matched {match.group(0)!r}")
        missing = [f"Table {n}" for n in range(1, 15) if not re.search(rf"Table {n}\.", text)]
        missing += [f"Figure {n}" for n in range(1, 5) if not re.search(rf"Figure {n}\.", text)]
        if missing:
            failures.append(f"{path.name}: missing captions {', '.join(missing)}")
    if failures:
        raise SystemExit("artifact verification failed:\n  " + "\n  ".join(failures))
    print(f"verified {len(paths)} artefact(s): redaction clean, all 14 tables and 4 figures present")


def main() -> None:
    parser = argparse.ArgumentParser(description="Render the legal AI stack reference.")
    parser.add_argument("--format", choices=["all", "docx", "pdf", "md"], default="all")
    args = parser.parse_args()

    validate_tables()
    validate_redaction()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    produced: list[Path] = []

    if args.format in {"all", "docx"}:
        target = OUT_DIR / f"{STEM}.docx"
        safe_write(target, lambda tmp: build_docx(tmp))
        produced.append(target)
    if args.format in {"all", "pdf"}:
        target = OUT_DIR / f"{STEM}.pdf"
        safe_write(target, lambda tmp: build_pdf(tmp))
        produced.append(target)
    if args.format in {"all", "md"}:
        target = OUT_DIR / f"{STEM}.md"
        safe_write(target, lambda tmp: build_markdown(tmp))
        produced.append(target)

    for path in produced:
        print(f"wrote {path.relative_to(REPO)}  ({path.stat().st_size:,} bytes)")

    verify_artifacts(produced)


if __name__ == "__main__":
    main()
