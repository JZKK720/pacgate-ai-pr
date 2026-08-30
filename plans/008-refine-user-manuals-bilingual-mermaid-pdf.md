# Plan 008: Refine the bilingual user manuals with design-skill discipline, add rendered Mermaid diagrams, and make the PDF pipeline actually carry those diagrams

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 231f451..HEAD -- deploy/USER-MANUAL.md deploy/USER-MANUAL-ZH.md docs/PACGATE-LAW-STAFF-HANDBOOK.md docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.md safe_markdown_to_pdf.py docs/diagrams/mermaid/`
> If any in-scope file changed since this plan was written (2026-08-30), compare
> the "Current state" excerpts against the live files before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (touches the shared PDF converter used by every doc export)
- **Depends on**: none (but read `plans/007-aipc-full-installation-handoff.md` for context on why the manuals exist)
- **Category**: docs (+ dx for the converter change)
- **Planned at**: commit `231f451`, 2026-08-30

## Why this matters

The two user manuals (`deploy/USER-MANUAL*.md`, `docs/PACGATE-LAW-STAFF-HANDBOOK*.md`)
are the staff-facing on-ramp for the Pacgate Law pilot. Right now they are
wall-to-wall prose and tables with **no diagrams**, and they carry redundancy
(the privacy "what stays / what is sent" split is stated three different ways
across the two documents). The user wants them refined with the discipline of
three design skills and illustrated with Mermaid, then re-exported to PDF.

The load-bearing catch: **the PDF converter silently drops images.**
`safe_markdown_to_pdf.py::build_story` (the function that turns markdown into a
reportlab story) has branches for headings, paragraphs, lists, tables, code, and
rules — but **no branch for `<img>`**. A Mermaid diagram embedded as `![](x.png)`
renders fine on GitHub/VS Code but vanishes from the PDF, and a
```` ```mermaid ```` fence renders as literal code text. So this plan is **two
jobs, not one**: (A) extend the converter to place raster images, and (B) refine
the docs + add diagrams. Doing B without A produces PDFs with the diagrams
missing — the exact failure the user would notice first.

## Design-skill discipline to apply (read before editing the docs)

These are the operative rules from the three skills the user named, translated
to a **markdown document** (they are written for web UIs; the document analog is
below). Do not paste web/CSS ideas into a `.md`.

- **taste-skill — design read, then set the dials.** State one line before
  editing: *"Reading this as: a trust-first, regulated, non-technical law-firm
  staff handbook → low variance, low motion, readable density."* Concretely for
  prose: calm, consistent heading rhythm, generous whitespace between sections,
  no decorative flourish. This audience overrides any "make it pop" instinct.
- **hallmark — honest copy, no invented metrics, no italic headers.** Do not add
  fabricated numbers ("saves 10 hours/week", "trusted by 50 firms") to sell the
  docs. Do not italicize any heading word. Structural variety: the sections
  should not all be the same `## text ## table` shape — intersperse the diagrams
  and callouts where they earn their place.
- **impeccable-distill — one primary goal per section, remove redundancy.** The
  privacy split currently appears in the handbook (§6), the manual
  (Privacy section), and the FAQ. Consolidate to **one authoritative statement
  per document** and cross-reference instead of repeating. Cut decorative
  restatement; every paragraph must justify its existence.

**Hard content invariants (must survive the refinement):** the honest privacy
wording added at commit `e22d783` (documents/matters/memory stay on-device;
*conversation text* is processed by the enabled model service) must stay — do
**not** reintroduce the old "no cloud / never leaves the building" claim, which
the accepted cloud-chat decision made false. Keep EN↔ZH parity: every change to
an EN file gets its ZH twin edited in the same step.

## Current state

Files and their roles:

- `deploy/USER-MANUAL.md` — fuller per-mode manual (EN), v0.2.0, 325 lines.
- `deploy/USER-MANUAL-ZH.md` — Chinese parity twin (created at `e22d783`).
- `docs/PACGATE-LAW-STAFF-HANDBOOK.md` — non-technical staff guide (EN), v1.0.
- `docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.md` — Chinese twin.
- `safe_markdown_to_pdf.py` — the shared, viewer-safe md→PDF converter.
- `docs/diagrams/mermaid/*.mmd` — 6 existing diagram sources (technical:
  `fullstack-01/02/03`, `setup-01/02/03`). Bilingual labels already used.
- `docs/diagrams/mermaid/pacgate-report-theme.json` — the house Mermaid theme
  (cream/navy/gold, CJK-safe font stack). **Reuse it; do not invent a new theme.**
- `docs/diagrams/svg/*.{svg,png}` — where rendered diagram images live.

The converter's element dispatch, verbatim (`safe_markdown_to_pdf.py`, the
`build_story` loop — note there is no `img` case):

```python
# safe_markdown_to_pdf.py ~line 236 (build_story)
    for element in soup.children:
        if not isinstance(element, Tag):
            continue
        if element.name == "h1":
            story.append(Paragraph(flatten_children(element), styles["PgH1"]))
        elif element.name == "h2":
            story.append(Paragraph(flatten_children(element), styles["PgH2"]))
        # ... h3, h4, p, blockquote, pre, ul, ol, table, hr ...
        elif element.name == "hr":
            story.append(HRFlowable(...))
    return story
```

The `p` branch today (images inside a paragraph are flattened to text and lost):

```python
        elif element.name == "p":
            story.append(Paragraph(flatten_children(element), styles["PgBody"]))
```

Image resolution note: from `docs/PACGATE-LAW-STAFF-HANDBOOK.md` the diagram path
is `diagrams/svg/<name>.png`; from `deploy/USER-MANUAL.md` it is
`../docs/diagrams/svg/<name>.png`. The converter must resolve a relative `src`
against the **markdown file's own directory** (this is the bug to avoid: resolving
against CWD breaks whichever document is not at the repo root).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Render one diagram | `npx --yes @mermaid-js/mermaid-cli@11.15.0 -i <in.mmd> -o <out.png> -b white -s 2 -c docs/diagrams/mermaid/pacgate-report-theme.json` | writes a PNG > 10 KB, exit 0 |
| Generate a PDF | `.venv\Scripts\python.exe safe_markdown_to_pdf.py <src.md> <out.pdf>` | exit 0, no output |
| Validate viewer-safe | see Step 8 PowerShell check | `Type3=False  Pattern=0  Images>=<N>` |
| Full re-export set | the four `convert` calls in Step 7 | four PDFs regenerated |

The render command was **verified working** at plan time (produced a 67 KB PNG).
Chrome for Puppeteer (`chrome-headless-shell`) is already installed at
`~/.cache/puppeteer` — if `mmdc` fails with "Could not find Chrome", run
`npx puppeteer browsers install chrome-headless-shell@148.0.7778.97` (known
revision for this workspace) then retry.

## Suggested executor toolkit

- If the `hallmark`, `design-taste-frontend`, or `impeccable-distill` skills are
  loadable in your environment, invoke `hallmark audit` on each EN manual first
  to get a ranked punch list, then apply. If they are not available, apply the
  three bullet rules in the "Design-skill discipline" section above directly —
  they are the distilled essence and are sufficient.
- Reference to read before Step 1: `docs/diagrams/mermaid/fullstack-03-runtime-topology.mmd`
  (copy its `classDef` palette + bilingual-label style into the new diagrams).

## Scope

**In scope** (the only files you may modify or create):
- `safe_markdown_to_pdf.py` (add an image branch + helper — Step 1)
- `deploy/USER-MANUAL.md`, `deploy/USER-MANUAL-ZH.md`
- `docs/PACGATE-LAW-STAFF-HANDBOOK.md`, `docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.md`
- `docs/diagrams/mermaid/user-*.mmd` (new diagram sources — create)
- `docs/diagrams/svg/user-*.{svg,png}` (rendered output — create)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though related):
- `docs/index.html` and any `*.html` page — those diagrams are wired for HTML,
  not this PDF path; changing them is a separate task.
- The existing `fullstack-*.mmd` / `setup-*.mmd` sources — reuse as-is; do not
  edit their content.
- Any commercial/pricing doc (`PACGATE-AI-QUOTE-SUMMARY` etc.) — different
  surface, different rules.
- The `.gitattributes` / PDF binary handling — already correct at `231f451`.

## Git workflow

- Branch: `advisor/008-refine-user-manuals` (the repo runs on `main`; the
  operator may squash — do not merge or push unless instructed).
- Commit style: conventional commits, matching `git log` (e.g.
  `feat(pdf): render <img> in safe_markdown_to_pdf`, `docs: refine staff handbook IA + diagrams`).
- Commit the converter change **before** the doc changes (Step order enforces this).

## Steps

### Step 1: Add an image branch to the converter (do this first — nothing else works without it)

Edit `safe_markdown_to_pdf.py`:

1. Add `Image` to the existing reportlab import line:
   `from reportlab.platypus import ..., Image` (it already imports `Table`,
   `Paragraph`, etc.).
2. Add a module-level helper (place it near `build_table`):

```python
def build_image(tag: Tag, styles: StyleSheet1, base_dir: Path):
    src = tag.get("src", "")
    if not src or src.startswith(("http://", "https://", "data:")):
        return None  # only local raster images are supported
    img_path = (base_dir / src).resolve()
    if not img_path.exists() or img_path.suffix.lower() not in {".png", ".jpg", ".jpeg", ".gif"}:
        return None
    from PIL import Image as PILImage
    with PILImage.open(img_path) as im:
        native_w, native_h = im.size
    usable_width = A4[0] - (18 * mm * 2)
    # diagrams render at -s 2, so divide native px by 2 for the 72dpi display size
    display_w = min(native_w / 2.0, usable_width)
    display_h = display_w * (native_h / native_w)
    flowable = Image(str(img_path), width=display_w, height=display_h)
    caption = (tag.get("alt") or "").strip()
    parts = [flowable, Spacer(1, 2)]
    if caption:
        parts.append(Paragraph(html.escape(caption), styles["PgCaption"]))
    parts.append(Spacer(1, 6))
    return parts
```

3. Add a `PgCaption` style in `build_styles()` (small, grey, centered):
   `ParagraphStyle(name="PgCaption", parent=stylesheet["PgBody"], fontSize=8.4, leading=11, alignment=TA_CENTER, textColor=colors.HexColor("#6B6B6B"))`
   (`TA_CENTER` is importable from `reportlab.lib.enums`; `TA_LEFT` already is.)
4. In `build_story`, change the signature to `build_story(markdown_text, styles, base_dir)`
   and update its single caller in `convert_markdown_to_pdf` to pass
   `base_dir=source.parent`.
5. In the `p` branch, detect an image and route it:

```python
        elif element.name == "p":
            img = element.find("img")
            if img is not None and element.get_text(strip="") == "":
                built = build_image(img, styles, base_dir)
                if built:
                    story.extend(built)
                    continue
            story.append(Paragraph(flatten_children(element), styles["PgBody"]))
```

**Verify**: `.venv\Scripts\python.exe -c "import safe_markdown_to_pdf as m; print('PgCaption' in [s.name for s in m.build_styles().byName.values()])"` → `True`.
Also: `.venv\Scripts\python.exe -c "import ast; ast.parse(open('safe_markdown_to_pdf.py').read()); print('syntax ok')"` → `syntax ok`.

### Step 2: Prove the converter change in isolation (before touching any doc)

Create a throwaway markdown in OS temp (NOT in the repo):
`$t = Join-Path $env:TEMP "imgtest.md"` containing:
`![test caption](../Users)` is wrong — instead copy an existing rendered PNG into
temp and reference it relatively. Simplest: point at an existing diagram with an
absolute file path is not supported by the helper, so copy:
`Copy-Item docs\diagrams\svg\fullstack-03-runtime-topology.png $env:TEMP\d.png`
then write `![topology](d.png)` to `$t`, and run
`.venv\Scripts\python.exe safe_markdown_to_pdf.py $t $env:TEMP\imgtest.pdf`.

**Verify**: the output PDF exists and
`.venv\Scripts\python.exe -c "b=open(r'$env:TEMP\imgtest.pdf','rb').read(); print('/Image' in b.decode('latin-1'))"` → `True`.
(Confirms the image is embedded, not dropped.) Delete the temp files after.

### Step 3: Author the new user-facing diagrams (`.mmd`)

Create three new Mermaid sources under `docs/diagrams/mermaid/`, each reusing the
theme's palette via the same `classDef` lines as `fullstack-03-runtime-topology.mmd`,
and bilingual node labels (Chinese primary for the staff handbook audience, since
that doc is read by firm staff):

- `user-01-two-doors.mmd` — flowchart: 律师浏览器 → {检索工作区, 协作工作区} → 同一案件/文件库. Conveys "two doors, one filing system."
- `user-02-answer-flow.mmd` — flowchart LR: 提问 → 拆解步骤 → 检索贵所文件 → 生成回答 → [1]引用可点击. A horizontal pipeline.
- `user-03-privacy-split.mmd` — flowchart with two subgraphs: 「留在所内」(文件/案件/记忆/知识库) vs 「发送至模型服务」(对话文字). This is the single most valuable diagram given the residency question.

Do **not** duplicate the technical `fullstack-03` topology in the *staff* handbook
(wrong audience) — that one belongs in the fuller `USER-MANUAL`.

**Verify**: for each, run the render command from "Commands you will need" → three
PNGs written to `docs/diagrams/svg/user-0*.{svg,png}`, each > 10 KB.

### Step 4: Embed diagrams + refine the STAFF handbook (EN then ZH, same commit)

Edit `docs/PACGATE-LAW-STAFF-HANDBOOK.md`:
- After the §1 two-workspace table, insert `![两个入口，同一套档案](diagrams/svg/user-01-two-doors.png)`.
- In §4.2 (citations), insert `![回答如何生成](diagrams/svg/user-02-answer-flow.png)`.
- In §6 (privacy), replace the duplicated prose with `![什么留在所内，什么会发送](diagrams/svg/user-03-privacy-split.png)` plus ONE concise authoritative paragraph (impeccable-distill: cut the restatement).
- Apply the design discipline: no invented metrics, roman headings, consistent callout style, remove any paragraph that repeats another.

Then mirror every structural change into `docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.md`
(same image paths, Chinese captions).

**Verify**: `Select-String -Path docs\PACGATE-LAW-STAFF-HANDBOOK*.md -Pattern 'diagrams/svg/user-' -SimpleMatch | Measure-Object | Select-Object Count` → count ≥ 6 (3 per language).

### Step 5: Embed diagrams + refine the USER MANUAL (EN then ZH)

Edit `deploy/USER-MANUAL.md`:
- In the architecture/mode intro, embed the existing `../docs/diagrams/svg/fullstack-03-runtime-topology.png` (this doc is technical enough to carry the port-level diagram).
- Add `../docs/diagrams/svg/user-02-answer-flow.png` in the Research section.
- Add `../docs/diagrams/svg/user-03-privacy-split.png` in the Privacy section; consolidate the FAQ privacy duplicate to a cross-reference.
- Distill: the "Mode 1 / Mode 2" sections repeat the landing-page steps — trim to one canonical "how to access" and reference it.

Mirror into `deploy/USER-MANUAL-ZH.md`.

**Verify**: `Select-String -Path deploy\USER-MANUAL*.md -Pattern 'diagrams/svg/' -SimpleMatch | Measure-Object | Select-Object Count` → count ≥ 6.

### Step 6: Regenerate all four PDFs

```
.venv\Scripts\python.exe safe_markdown_to_pdf.py docs\PACGATE-LAW-STAFF-HANDBOOK.md docs\PACGATE-LAW-STAFF-HANDBOOK.pdf
.venv\Scripts\python.exe safe_markdown_to_pdf.py docs\PACGATE-LAW-STAFF-HANDBOOK-ZH.md docs\PACGATE-LAW-STAFF-HANDBOOK-ZH.pdf
.venv\Scripts\python.exe safe_markdown_to_pdf.py deploy\USER-MANUAL.md deploy\USER-MANUAL.pdf
.venv\Scripts\python.exe safe_markdown_to_pdf.py deploy\USER-MANUAL-ZH.md deploy\USER-MANUAL-ZH.pdf
```

**Verify**: four PDFs, each newer than its source md (`Get-ChildItem docs\*.pdf,deploy\*.pdf | Sort LastWriteTime`).

### Step 7: Validate every PDF is viewer-safe AND carries its images

Run:
```powershell
foreach ($f in @("docs\PACGATE-LAW-STAFF-HANDBOOK.pdf","docs\PACGATE-LAW-STAFF-HANDBOOK-ZH.pdf","deploy\USER-MANUAL.pdf","deploy\USER-MANUAL-ZH.pdf")) {
  $txt = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($f))
  $img = ([regex]::Matches($txt,'/Subtype\s*/Image')).Count
  "{0}  Type3={1}  Pattern={2}  Images={3}" -f $f, $txt.Contains('/Subtype /Type3'), ([regex]::Matches($txt,'/Pattern\b').Count), $img
}
```

**Verify**: every line shows `Type3=False  Pattern=0` and `Images >= 3` (the three
new diagrams; the manuals with the extra topology diagram show 4). If `Images=0`,
the Step 1 base_dir resolution is wrong — re-check Step 1.4.

### Step 8: Final bilingual-parity + no-regression sweep

- `git diff --stat` — only in-scope files changed.
- Confirm the honest privacy wording is present in all four md
  (`Select-String -Path <each> -Pattern 'conversation|对话文字'` → hit in each).
- Confirm no invented metric was added:
  `Select-String -Path docs\PACGATE-LAW-STAFF-HANDBOOK*.md,deploy\USER-MANUAL*.md -Pattern '\d+\s*(hours|小时|weeks|%|倍)'` → no marketing-number hits (the only numbers allowed are real ones like port `8081`, "2 to 10 minutes" response time that already existed).

## Test plan

This repo has no test framework for the PDF converter; the tests are the
verification gates above. The critical regression to guard is that **existing
markdown→PDF behavior is unchanged for docs without images**:

- Re-run the converter on an image-free doc
  (`.venv\Scripts\python.exe safe_markdown_to_pdf.py README.md $env:TEMP\readme.pdf`)
  and confirm it exits 0 and produces a PDF with `Images=0`. This proves the new
  `p`-branch guard did not break ordinary paragraphs.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `safe_markdown_to_pdf.py` parses (Step 1 verify) and `PgCaption` exists.
- [ ] Isolation test embeds an image (Step 2 → `/Image` present).
- [ ] Three new `user-0*.png` exist in `docs/diagrams/svg/`, each > 10 KB.
- [ ] All four PDFs show `Type3=False  Pattern=0  Images>=3` (Step 7).
- [ ] Image-free regression PDF still builds (Test plan).
- [ ] EN↔ZH parity: each diagram appears in both language files (Step 4/5 verifies).
- [ ] Honest privacy wording present in all four md; no invented metrics.
- [ ] `git status` shows only in-scope files.
- [ ] `plans/README.md` status row for 008 updated to DONE.

## STOP conditions

Stop and report (do not improvise) if:

- The `build_story` excerpt above no longer matches the live file (drift).
- `mmdc` cannot render even after the puppeteer-chrome install step (chrome
  unavailable → the diagrams can't be produced; report, don't hand-draw SVGs).
- A refined section would require re-introducing the "no cloud / never leaves
  the building" claim to make the diagram fit — that claim is out of policy;
  redesign the diagram instead, and if you can't, STOP.
- The image-free regression PDF fails to build after the Step 1 edit — the
  converter change broke base behavior; revert Step 1 and report.

## Maintenance notes

**Execution notes (2026-08-30 run):** two corrections vs. the snippets above —
(1) the `p`-branch guard uses `get_text(strip=True)`, not `strip=""` (empty string
is falsy in BeautifulSoup and silently disables stripping); (2) `build_image` must
fit BOTH axes — width-only capping crashed the portrait privacy diagram with
reportlab `LayoutError`, so a `usable_height` term + `scale = min(1/2, w_fit, h_fit)`
is required. All done criteria passed: 4 PDFs with Images=3, viewer-safe, EN/ZH
parity, image-free regression (README) still builds clean.

- **The converter is shared by every doc export in this repo.** The new `p`-branch
  guard only diverts a paragraph to image handling when the paragraph's *only*
  content is an `<img>` (text is empty). Inline images mixed with text still fall
  through to the text path and drop the image — that is acceptable for now; if
  someone later needs inline images, extend `inline_markup`, don't loosen this guard.
- **PNG not SVG**: the manuals reference `.png` deliberately — reportlab cannot
  embed SVG without extra deps. If a diagram is edited, re-render the PNG (Step 3
  command) before re-exporting PDFs, or the PDF shows a stale picture.
- **base_dir resolution**: images resolve against the markdown file's directory,
  not CWD. A future doc moved to a new location must fix its relative image paths.
- Deferred out of scope: wiring the same diagrams into `docs/index.html` and the
  HTML report pages (different render path, different rules).
