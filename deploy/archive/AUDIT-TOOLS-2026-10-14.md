# Tooling audit — conversion and Office CLIs, 0.1.29

**Date:** 2026-10-14
**Method:** every cell below was produced by running the tool inside the published
0.1.29 image in this session. Where a tool was found, it was also exercised on a real
file rather than only located on `PATH`.

---

## 1. What is installed where

| tool | pacgate-mcp | ocr-service | deer-flow-pacgate | deer-flow-frontend |
| --- | --- | --- | --- | --- |
| `pandoc` | missing | missing | **FOUND** `/usr/bin/pandoc` | missing |
| `officecli` | missing | missing | **FOUND** `/usr/local/bin/officecli` | missing |
| `markitdown` (CLI) | **FOUND** | missing | **FOUND** | missing |
| `libreoffice` / `soffice` | missing | missing | missing | missing |
| `tesseract` | missing | missing | missing | missing |
| `antiword` / `catdoc` | missing | missing | missing | missing |
| python `markitdown` | OK | MISS | MISS | — |
| python `docx` (python-docx) | **MISS** | **OK** | MISS | — |
| python `openpyxl` | **OK** | MISS | MISS | — |
| python `pptx` | **OK** | MISS | MISS | — |
| python `pdfminer` | **OK** (20260107) | MISS | MISS | — |
| python `pdfplumber` | OK (0.11.10) | MISS | MISS | — |
| python `pypdf` / `PyPDF2` | **MISS** | MISS | MISS | — |
| python `PIL` | OK | OK | MISS | — |
| python3 at all | yes | yes | yes | **no** |

Two consequences worth stating plainly:

- **No single image can build every fixture.** `python-docx` lives only in
  ocr-service; `openpyxl` and `python-pptx` live only in pacgate-mcp. A fixture builder
  that assumes one image produces a false "could not be built", which reads like a
  product failure. `test-format-coverage-e2e.ps1` now selects the image per library and
  says which it used.
- **`pypdf`/`PyPDF2` are absent** while `pdfminer` and `pdfplumber` are present.
  markitdown's PDF converter imports `pdfminer` + `pdfplumber`, so it has what it
  needs; nothing here is broken by the gap. Recorded because a future converter that
  reaches for `pypdf` would fail with an import error that looks like a document fault.

## 2. Each tool actually exercised

| tool | exercised how | result |
| --- | --- | --- |
| **pandoc** | `pandoc -f docx -t markdown c.docx` inside deer-flow | **PASS** — `# Contract / ID 11010519491231002X` |
| **markitdown CLI** | `markitdown c.docx` inside deer-flow | **PASS** — same markdown (emits a harmless `ffmpeg` RuntimeWarning) |
| **markitdown module** | `pacgate_convert_document` through pacgate-mcp, 7 formats | **PASS for 6** — see §3 for PDF |
| **officecli CLI** | `get`/`query`/`validate` inside deer-flow | **PASS** — structured JSON, e.g. `query c.docx 'p'` returned `/body/p[1] text="Contract"` |
| **officecli MCP** | full stdio handshake: `initialize` → `tools/list` → `tools/call` | **PASS** — see §4 |

## 3. PDF conversion: an honest gap, not a bug

`pacgate_convert_document` on a PDF depends entirely on whether the PDF has a text
layer, and the two cases are indistinguishable from the result:

| PDF kind | extract_text | markitdown result | verdict |
| --- | --- | --- | --- |
| **text layer** | `ID CARD 11010519491231002X` | `chars: 28`, correct markdown | correct |
| **image-only (scan)** | `'\x0c'` (one form-feed) | `{"ok": true, "chars": 0, "markdown": ""}` | **silent empty** |

markitdown is a text extractor, not OCR, so **empty is the correct output** — the
scan's text lives in pixels and belongs to the OCR lane. What is wrong is the
*boundary*: `ok: true` with `chars: 0` and no reason is indistinguishable from a tool
failure, and a scanned PDF is the normal case in legal work. An agent calling
`pacgate_convert_document` on a scan is told nothing about needing
`pacgate_ocr_document` instead.

The format gate now asserts this distinction explicitly: an empty conversion is
accepted **only** for the image-only PDF case, and reported as a WARN naming the
missing signal; for every other format an empty conversion is a hard FAIL.

**Not fixed here** — it needs a decision about what the tool should return (a
`needs_ocr: true` field, or an error). Making the behaviour observable was the
unambiguous part.

## 4. officecli: the richest tool in the stack, and the least covered

`officecli mcp` answers with **one** tool that takes a command line, and its own
description carries a four-step delivery gate:

1. `validate <file>` → clean, no errors
2. `view <file> issues` → no overflow/format/structure problems; scan for leftover
   placeholders (`xxxx`, `lorem`, `<TODO>`, `{{...}}`, `$VAR$`, empty `()`/`[]`)
3. `view <file> screenshot --page N` → **visual** audit, judged adversarially
4. `save <file>` → flush

Exercised end to end through MCP:

```
create /w/mcp-made.docx                                    -> "Created: /w/mcp-made.docx"
add    /w/mcp-made.docx /body --type paragraph --prop text=Created via MCP
                                                          -> "Added paragraph at /body/p[@paraId=00100000]"
save   /w/mcp-made.docx                                   -> flushed
validate /w/mcp-made.docx --json                          -> {"success":true,"data":{"count":0,"errors":[]}}
                                                          file on disk: 5184 bytes
```

So the whole create → edit → validate → save cycle works through MCP.

### The gap

**Nothing in the repo tests officecli at all.** It is enabled in the deer-flow
extension config (`mcpServers.officecli`, `type: stdio`, `command: officecli`), the
smoke gate counts it as one of "3 MCP servers enabled (openviking + pacgate +
officecli)", and that is the entire coverage — a count, not a behaviour. The agent's
own tool description tells the model it must validate, check issues, and screenshot
before delivering, and no gate verifies that any of it is reachable.

Two further facts worth recording:

- **`validate` passing is explicitly NOT delivery**, per the tool's own text. Any gate
  written for this must not treat "validate clean" as sufficient, or it inherits the
  same false confidence this audit keeps finding.
- **officecli exists only in deer-flow**, not in pacgate-mcp or ocr-service. An agent
  running outside deer-flow has no Office tooling beyond markitdown and pandoc.

### Residual

- The `screenshot` mode returns an image for visual judgement; whether it renders in
  this headless environment was **not tested**. A deck that cannot be screenshotted
  should be reported as "not visually verified" rather than passing silently, and
  nothing enforces that today.
- The per-format `load_skill word|excel|pptx` guides are the tool's own source of
  truth for what "done" requires; they were not read or exercised here.
