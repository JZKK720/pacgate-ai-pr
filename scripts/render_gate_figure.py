"""Draw Figure 3, the document gate, as a four-phase band.

Mermaid was the source for Figures 1, 2 and 4, but a four-phase horizontal
band with stacked step text cannot hold a readable aspect ratio in a flowchart
engine: laying the phases out left to right produced a 15:1 strip where the
labels were unreadable, and stacking them produced a 1:2 column that wasted the
landscape page. This one figure is laid out directly so the text measure and
the aspect ratio are both chosen rather than inherited.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parents[1] / "docs" / "diagrams" / "svg" / "stack-03-document-gate.png"

SCALE = 2
INK = (31, 45, 68)
MUTED = (90, 90, 90)
RULE = (183, 196, 222)
ARROW = (75, 110, 167)

PHASES = [
    {
        "title": "1. Ingest",
        "body": ["Upload or scan", "Native text extract", "Raster OCR fallback",
                 "Text PDFs are never degraded"],
        "fill": (238, 243, 251),
        "border": (75, 110, 167),
    },
    {
        "title": "2. De-identify",
        "body": ["Detect by tier: 19 entity types", "Decide by data class: T1 to T4",
                 "Replace with job-scoped placeholders", "Verify by replaying the detector",
                 "Seal mapping and ledger"],
        "fill": (243, 231, 199),
        "border": (166, 146, 85),
    },
    {
        "title": "3. Human gate",
        "body": ["T1 and T2 clean: auto-pass", "T3, T4 or residue: reviewer",
                 "Release is the only path forward"],
        "fill": (234, 245, 249),
        "border": (61, 138, 167),
    },
    {
        "title": "4. Grounded use",
        "body": ["Chunk and embed on-device", "Retrieve filtered by class,",
                 "jurisdiction and matter", "Cite and draft"],
        "fill": (238, 243, 251),
        "border": (75, 110, 167),
    },
]

WIDTH, HEIGHT = 1660, 268
PAD = 26
GAP = 42


def load(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    name = "msyhbd.ttc" if bold else "msyh.ttc"
    return ImageFont.truetype(f"C:/Windows/Fonts/{name}", size)


def main() -> None:
    canvas = Image.new("RGB", (WIDTH * SCALE, HEIGHT * SCALE), (255, 255, 255))
    draw = ImageDraw.Draw(canvas)

    def px(value: float) -> int:
        return int(round(value * SCALE))

    title_font = load(px(19), bold=True)
    body_font = load(px(16))

    panel_w = (WIDTH - 2 * PAD - 3 * GAP) / 4
    top = 30
    bottom = HEIGHT - 26

    for index, phase in enumerate(PHASES):
        left = PAD + index * (panel_w + GAP)
        draw.rounded_rectangle(
            [px(left), px(top), px(left + panel_w), px(bottom)],
            radius=px(10), fill=phase["fill"], outline=phase["border"], width=px(1.6),
        )
        draw.text((px(left + 18), px(top + 16)), phase["title"], font=title_font, fill=INK)
        y = top + 54
        for line in phase["body"]:
            draw.text((px(left + 18), px(y)), line, font=body_font, fill=INK)
            y += 30

        if index < len(PHASES) - 1:
            x0 = left + panel_w + px(8) / SCALE
            x1 = left + panel_w + GAP - px(8) / SCALE
            mid = (top + bottom) / 2
            draw.line([px(x0), px(mid), px(x1), px(mid)], fill=ARROW, width=px(1.6))
            draw.polygon(
                [(px(x1), px(mid)), (px(x1 - 9), px(mid - 6)), (px(x1 - 9), px(mid + 6))],
                fill=ARROW,
            )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(OUT, optimize=True)
    print(f"wrote {OUT.relative_to(OUT.parents[3])}  {canvas.size[0]}x{canvas.size[1]}")


if __name__ == "__main__":
    main()
