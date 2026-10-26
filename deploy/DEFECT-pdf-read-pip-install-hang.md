# DEFECT (HIGH): "stopped producing output" on a PDF the agent could already read

**Found:** 2026-10-24, from a live user report. A 3.0 MB Chinese PDF was uploaded
with "提供一下这份文件的内容简要？" and the run died with:

```
The agent graph stopped producing output and the run was aborted by the idle
watchdog. Please retry.
```

**Status:** FIXED in `deploy/client-bundle/patches/deer-flow-prompt.py`. Gated by
`scripts/test-prompt-document-reading.ps1`.

## The observation

Thread `eee62924`, run `c7d9c88b`: 11 messages, 137,968 input / 824 output
tokens, 4 LLM calls, then dead. A retry (`5b7a7e92`) died at 1 message with the
same error.

The checkpoint shows the agent had **everything it needed**:

- the PDF, at `/mnt/user-data/uploads/信息化知识前沿和未来发展趋势V3.0——1114.pdf`
- a pre-converted `.md` (11.9 KB) sitting next to it, produced by `markitdown`
- both listed in the `<uploaded_files>` block it was given

It read the `.md` successfully with `read_file`. Then it decided it needed a
"real" PDF parser and spent four consecutive `bash` calls:

| # | command | result |
|---|---|---|
| 1 | `pdfinfo` | `/bin/bash: pdfinfo: command not found` (exit 127) |
| 2 | `python3 -c 'import pypdf'` | `ModuleNotFoundError: pypdf` |
| 3 | `python3 -c 'import fitz'` | `ModuleNotFoundError: fitz` |
| 4 | `python3 -m pip install pymupdf --quiet; python3 -c 'import fitz ...'` | **never returned** |

## Root cause

Two independent faults, both required for the hang.

### 1. The prompt never said how to read a document

`deer-flow-prompt.py` documents PDF **output** thoroughly - `pandoc`,
`weasyprint`, `officecli`, CJK fonts, "the CLI tools are pre-installed". For PDF
**input** it said exactly one thing:

```
- For PDF, PPT, Excel, and Word files, converted Markdown versions (*.md) are
  available alongside originals
```

That is a fact with no tool and no instruction. Measured on the pre-fix file:

```
'markitdown' mentions in the prompt : 0
'pip install' mentions in the prompt: 0
```

So the agent had no way to know that `markitdown` is the supported reader, that
it is already installed, or that installing packages is not an option here. It
guessed, and the guess cost the run.

### 2. `pip install` outlives the watchdog

This is why the guess was fatal rather than merely wasteful:

| bound | value | source |
|---|---|---|
| bash subprocess timeout | **600 s** | `local_sandbox.py:355,365` (hardcoded upstream) |
| stream idle watchdog | **420 s** | `worker.py:55`, `DEERFLOW_STREAM_IDLE_TIMEOUT_S` |

The bash timeout is *larger* than the watchdog. On a machine with no egress,
`pip install` does not fail fast - it retries index URLs until the socket gives
up. That silence exceeds 420 s, the watchdog fires first, and the run is aborted
with "stopped producing output" while bash is still waiting.

`DEERFLOW_STREAM_IDLE_TIMEOUT_S` is never set in any compose file, so the 420 s
default always applies.

## Why the obvious fixes are wrong

- **Raise the watchdog.** Already considered and **rejected** in
  `AIPC-PERF-ANALYSIS-2026-10-17.md` (item 4, and again in the rejected list:
  "masks the real cause and degrades UX further"). It would turn a 7-minute
  failure into a 10-minute one and still fail.
- **Lower the bash timeout below 420 s.** The 600 s value is hardcoded upstream
  and `local_sandbox.py` is not among the patched files. Patching it would add a
  new fork surface to fix a symptom - the agent should not be running a
  network install at all.
- **Install `pypdf`/`pymupdf` into the image.** This is the wrong direction. The
  user's question was already answerable from the `.md` that existed. Adding
  parsers would make the agent's incorrect instinct *work*, and would grow the
  image to serve a path that should never be taken.

## The fix

`deploy/client-bundle/patches/deer-flow-prompt.py`, replacing the tool-less
sentence with an explicit instruction block:

- read the pre-converted `.md` **first** - same content, one `read_file`
- `markitdown` is already installed and is the supported reader, with the exact
  invocation
- `pdfinfo`, `pdftotext`, `pypdf`, `fitz`/`pymupdf` are **not** on the agent PATH,
  and `python3` there is the system interpreter, not the backend venv
- **never run `pip install`** - no egress, it stalls past the 420 s watchdog and
  aborts the run; if the baked tools cannot do the job, say so in the answer

Every factual claim in the new text was verified against the live container:

```
markitdown on PATH     -> /usr/local/bin/markitdown
pdfinfo missing        -> MISSING
pdftotext missing      -> MISSING
python3 is system      -> /usr/local
import pypdf fails     -> ModuleNotFoundError: No module named 'pypdf'
import fitz fails      -> ModuleNotFoundError: No module named 'fitz'
```

## Verification

- `scripts/test-prompt-document-reading.ps1`: **4 of 5 checks fail** on the
  pre-fix prompt, **5 of 5 pass** after.
- The patched file parses (`ast.parse` OK) and the live container's mount is
  byte-identical to the repo copy (MD5 `22292509...`).
- `SYSTEM_PROMPT_TEMPLATE` in the running process contains the new text.
- Sibling gates unaffected: `test-tool-search-deferral.ps1` 25/25,
  `test-deferred-tool-runtime.ps1` 17/17.

## Residual risk

- The prompt is **advice, not enforcement**. A model that ignores it can still
  run `pip install`. The structural fix - making the bash timeout shorter than
  the watchdog, or blocking network commands in the sandbox - lives upstream and
  is not available without forking `local_sandbox.py`.
- `audit-deer-flow-patches.ps1` could not run here (it needs a
  `deploy/deer-flow-src` git checkout that this box does not have). The prompt
  patch is a full-file override, so the audit's delta report will show this edit
  as a larger diff against upstream - expected, and it should be reviewed there
  before release.
- The `kb_search` empty-result behaviour observed in the same thread is a
  **separate** issue, not part of this defect: the run searched matter
  `a0409504` ("Firm Knowledge Base"), which has **0 documents**. `kb_search`
  itself works - it returns hits on matters that have content.
