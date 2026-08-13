from __future__ import annotations

import argparse
import html
import json
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import HRFlowable, PageBreak, Paragraph, Spacer

from safe_markdown_to_pdf import build_styles, register_fonts


PRIORITY_LABELS = {
    "high": {"en": "High", "zh": "高"},
    "medium": {"en": "Medium", "zh": "中"},
    "low": {"en": "Low", "zh": "低"},
}

CATEGORY_LABELS = {
    "Valid": {"en": "Valid", "zh": "有效"},
    "Error": {"en": "Error", "zh": "误解"},
    "Needs Clarification": {"en": "Needs Clarification", "zh": "需进一步确认"},
    "Irrelevant": {"en": "Out of Scope", "zh": "超出当前范围"},
}

OWNER_LABELS = {
    "Joint": {"en": "Joint", "zh": "双方"},
    "Cubecloud": {"en": "Cubecloud", "zh": "Cubecloud"},
    "Pacgate": {"en": "Pacgate", "zh": "Pacgate"},
    "Commercial": {"en": "Commercial", "zh": "商务"},
    "Legal review": {"en": "Legal review", "zh": "法律审查"},
}


def localized_value(item: dict, key: str, lang: str, fallback: str = "") -> str:
    suffix = "Zh" if lang == "zh" else "En"
    return item.get(f"{key}{suffix}") or item.get(key) or fallback


def localized_label(en: str, zh: str, lang: str) -> str:
    return zh if lang == "zh" else en


def mapped_label(mapping: dict[str, dict[str, str]], key: str, lang: str) -> str:
    return mapping.get(key, {}).get(lang, key)


def build_story(board_path: Path, lang: str) -> tuple[list, str]:
    board = json.loads(board_path.read_text(encoding="utf-8"))
    styles = build_styles()
    styles.add(
        ParagraphStyle(
            name="PgMeta",
            parent=styles["PgBody"],
            fontSize=9,
            leading=12,
            textColor=colors.HexColor("#666666"),
            spaceAfter=4,
        )
    )
    styles.add(
        ParagraphStyle(
            name="PgLabel",
            parent=styles["PgBody"],
            fontSize=9.2,
            leading=12,
            textColor=colors.HexColor("#6E5928"),
            spaceAfter=2,
        )
    )
    styles.add(
        ParagraphStyle(
            name="PgCardTitle",
            parent=styles["PgH3"],
            fontSize=13,
            leading=16,
            spaceBefore=0,
            spaceAfter=3,
        )
    )

    title = localized_value(board, "boardTitle", lang, "Clarification Workboard")
    subtitle = localized_value(board, "subtitle", lang, "")
    generated_at = board.get("generatedAt", "")
    lanes = board.get("lanes", [])
    cards = board.get("cards", [])

    story: list = [Paragraph(html.escape(title), styles["PgH1"])]
    if subtitle:
        story.append(Paragraph(html.escape(subtitle), styles["PgBody"]))
    if generated_at:
        generated_label = localized_label("Generated", "生成日期", lang)
        story.append(Paragraph(f"<b>{generated_label}:</b> {html.escape(generated_at)}", styles["PgMeta"]))

    summary_intro = localized_label(
        "This print version keeps the short answer first, followed by the reason, evidence, and next action for each card.",
        "本打印版默认先给出简明结论，然后按卡片列出原因、依据和下一步。",
        lang,
    )
    story.append(Paragraph(html.escape(summary_intro), styles["PgBody"]))
    story.append(Spacer(1, 4))

    for lane in lanes:
        lane_cards = [card for card in cards if card.get("lane") == lane.get("id")]
        lane_title = localized_value(lane, "label", lang, lane.get("id", "Lane"))
        count_label = localized_label("cards", "张卡片", lang)
        story.append(Paragraph(f"{html.escape(lane_title)} ({len(lane_cards)} {html.escape(count_label)})", styles["PgH2"]))

        if not lane_cards:
            empty_label = localized_label("No cards in this lane.", "该泳道目前没有卡片。", lang)
            story.append(Paragraph(html.escape(empty_label), styles["PgBody"]))
        for index, card in enumerate(lane_cards):
            header_parts = [html.escape(card.get("id", "CARD"))]
            if card.get("section"):
                section_label = localized_label("Section", "问题组", lang)
                header_parts.append(f"{html.escape(section_label)} {html.escape(str(card['section']))}")
            story.append(Paragraph("<b>" + " · ".join(header_parts) + "</b>", styles["PgLabel"]))

            title_text = localized_value(card, "title", lang, card.get("id", "Card"))
            story.append(Paragraph(html.escape(title_text), styles["PgCardTitle"]))

            meta_parts = []
            priority = mapped_label(PRIORITY_LABELS, card.get("priority", "medium"), lang)
            category = mapped_label(CATEGORY_LABELS, card.get("category", ""), lang)
            meta_parts.append(f"{localized_label('Priority', '优先级', lang)}: {html.escape(priority)}")
            meta_parts.append(f"{localized_label('Category', '类别', lang)}: {html.escape(category)}")
            if card.get("owner"):
                owner = mapped_label(OWNER_LABELS, str(card["owner"]), lang)
                meta_parts.append(f"{localized_label('Owner', '负责人', lang)}: {html.escape(owner)}")
            if card.get("delivery"):
                meta_parts.append(f"{localized_label('Handling', '处理代码', lang)}: {html.escape(str(card['delivery']))}")
            if card.get("pack"):
                meta_parts.append(f"{localized_label('Pack', '附件', lang)}: {html.escape(str(card['pack']))}")
            story.append(Paragraph(" | ".join(meta_parts), styles["PgMeta"]))

            if card.get("questionRefs"):
                refs_label = localized_label("Question refs", "问题编号", lang)
                refs = ", ".join(card.get("questionRefs", []))
                story.append(Paragraph(f"<b>{html.escape(refs_label)}:</b> {html.escape(refs)}", styles["PgMeta"]))

            details = [
                (localized_label("Plain answer", "简明回复", lang), localized_value(card, "response", lang, "")),
                (localized_label("Why it matters", "为什么重要", lang), localized_value(card, "why", lang, "")),
                (localized_label("Evidence", "依据", lang), localized_value(card, "evidence", lang, "")),
                (localized_label("Next step", "下一步", lang), localized_value(card, "next", lang, "")),
            ]
            for label, text in details:
                if text:
                    story.append(Paragraph(f"<b>{html.escape(label)}</b>", styles["PgLabel"]))
                    story.append(Paragraph(html.escape(text), styles["PgBody"]))

            if index < len(lane_cards) - 1:
                story.append(HRFlowable(width="100%", thickness=0.4, color=colors.HexColor("#C9C9C9"), spaceBefore=4, spaceAfter=8))

        story.append(Spacer(1, 6))
        if lane != lanes[-1]:
            story.append(PageBreak())

    return story, title


def convert_board_to_pdf(source: Path, target: Path, lang: str) -> None:
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.units import mm
    from reportlab.platypus import SimpleDocTemplate

    register_fonts()
    story, title = build_story(source, lang)
    doc = SimpleDocTemplate(
        str(target),
        pagesize=A4,
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        topMargin=16 * mm,
        bottomMargin=16 * mm,
        title=title,
        author="Cubecloud Limited",
        creator="safe_clarification_board_to_pdf.py",
    )
    doc.build(story)


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert a clarification workboard JSON file to a viewer-safe PDF.")
    parser.add_argument("source", help="Source workboard JSON file")
    parser.add_argument("target", nargs="?", help="Output PDF file")
    parser.add_argument("--lang", choices=["en", "zh"], default="en", help="Language to export")
    args = parser.parse_args()

    source = Path(args.source)
    target = Path(args.target) if args.target else source.with_name(source.stem + f"-{args.lang}.pdf")
    convert_board_to_pdf(source, target, args.lang)


if __name__ == "__main__":
    main()