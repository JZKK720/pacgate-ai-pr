# Guard: the lead-agent prompt must tell the agent how to READ an uploaded
# document, and must warn it off `pip install` on an offline AIPC.
#
# WHY THIS EXISTS (measured 2026-10-24, live AIPC, thread eee62924)
#
# A user uploaded a 3.0 MB Chinese PDF and asked "提供一下这份文件的内容简要？".
# The run died with:
#
#     The agent graph stopped producing output and the run was aborted by the
#     idle watchdog. Please retry.
#
# The checkpoint shows exactly what the agent did. It had BOTH files available -
# the PDF and a pre-converted `.md` (11.9 KB, produced by markitdown, which is
# baked into the image) - and the `<uploaded_files>` block listed both. It read
# the `.md` successfully with `read_file`. Then it decided it needed a "real"
# PDF parser and spent four consecutive `bash` calls on:
#
#     pdfinfo            -> /bin/bash: pdfinfo: command not found   (exit 127)
#     python3 -c 'import pypdf'   -> ModuleNotFoundError: pypdf
#     python3 -c 'import fitz'    -> ModuleNotFoundError: fitz
#     python3 -m pip install pymupdf --quiet; python3 -c 'import fitz ...'
#
# The last one is the killer. `pip install` on a machine with no egress does not
# fail fast - it retries index URLs until the socket gives up. The bash tool's
# own subprocess timeout is 600s (local_sandbox.py:355,365) but the stream idle
# watchdog is 420s (worker.py:55). So the watchdog fires FIRST, the run is
# aborted, and the user sees "stopped producing output" with no answer - even
# though the answer was already sitting in the `.md` it had read.
#
# THE PROMPT GAP
#
# `deer-flow-prompt.py` documents PDF *output* thoroughly (pandoc, weasyprint,
# officecli, CJK fonts) but says nothing about PDF *input* beyond "converted
# Markdown versions (*.md) are available alongside originals". Measured:
#
#     'markitdown' mentions in the prompt : 0
#     'pip install' mentions in the prompt: 0
#
# So the agent has no way to know that (a) markitdown is the supported reader and
# is already installed, or (b) installing packages is not an option here. It
# guesses, and the guess costs the whole run.
#
# WHAT IS ASSERTED
#   P1  the prompt names `markitdown` as the way to read a document
#   P2  the prompt states the reader is already installed / needs no install
#   P3  the prompt warns that `pip install` does not work (offline)
#   P4  the prompt tells the agent to prefer the pre-converted `.md`
#   P5  the prompt does not merely say ".md is available" without naming a tool
#       (the exact wording that failed)
#
# Exit codes: 0 = all pass; 1 = a real failure; 2 = cannot check
#
# Usage:  pwsh -File scripts/test-prompt-document-reading.ps1

[CmdletBinding()]
param(
    [string]$PromptFile = 'deploy/client-bundle/patches/deer-flow-prompt.py'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$passed = 0; $failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== lead-agent prompt must explain how to READ a document ===' -ForegroundColor Cyan

if (-not (Test-Path $PromptFile)) {
    Write-Host "`nCANNOT CHECK: missing prompt file: $PromptFile" -ForegroundColor Yellow
    exit 2
}

$text = Get-Content -Path $PromptFile -Raw -Encoding UTF8
Write-Host ("  prompt: {0} ({1} chars)" -f $PromptFile, $text.Length) -ForegroundColor DarkGray

# ── P1: markitdown must be named as the reader ───────────────────────────────
$hasMarkitdown = $text -match 'markitdown'
Check 'P1 prompt names markitdown as the document reader' $hasMarkitdown `
    "the prompt never mentions markitdown, so the agent has no supported way to read a PDF and guesses (measured: it tried pdfinfo, pypdf, fitz, then pip install)"

# ── P2: it must say the reader is already there ──────────────────────────────
$saysInstalled = $text -match '(?i)markitdown[^\n]{0,200}(already|pre-?installed|baked|no install|without install)' `
    -or $text -match '(?i)(already|pre-?installed|baked)[^\n]{0,200}markitdown'
Check 'P2 prompt states the reader is already installed' $saysInstalled `
    "without this the agent treats a missing import as a setup problem and tries to install"

# ── P3: pip install must be called out as not working ────────────────────────
$warnsPip = $text -match '(?i)(do not|don''t|never|avoid)[^\n]{0,80}pip install' `
    -or $text -match '(?i)pip install[^\n]{0,120}(offline|no (network|egress)|will (hang|fail|stall)|not available|unavailable)'
Check 'P3 prompt warns that pip install does not work offline' $warnsPip `
    "pip install on an offline AIPC stalls until the 420s idle watchdog aborts the run; the agent must be told, because it reaches for pip by default"

# ── P4: prefer the pre-converted .md ──────────────────────────────────────────
$prefersMd = $text -match '(?i)(prefer|use|read)[^\n]{0,120}\.md' `
    -or $text -match '(?i)\.md[^\n]{0,120}(prefer|instead|first)'
Check 'P4 prompt tells the agent to prefer the pre-converted .md' $prefersMd `
    "the .md is produced automatically and is the cheapest correct path; the agent should not re-parse the original"

# ── P5: the exact wording that failed must be gone ───────────────────────────
#
# The old line was:
#   "- For PDF, PPT, Excel, and Word files, converted Markdown versions (*.md)
#      are available alongside originals"
# It states a fact but names no tool and gives no instruction, which is how the
# agent ended up inventing a PDF pipeline.
$oldWording = $text -match 'converted Markdown versions \(\*\.md\) are available alongside originals'
Check 'P5 the tool-less ".md is available" wording is replaced' (-not $oldWording) `
    "this sentence names no tool and gives no instruction; it is the exact line the failing run read before inventing a PDF pipeline"

# ── P6-P9: convergence discipline on a deliverable ────────────────────────────
#
# WHY (measured 2026-10-28, six runs killed by `Recursion limit of 1000`):
#
# Every one of those runs was assembling a PDF and got stuck in a verify-fix-verify
# loop on layout. Reconstructed from langgraph's checkpoint writes for run
# e7526a00: 259 bash calls, all 259 command strings DISTINCT, 67 distinct
# write_file paths - p18art.py, dashlen.py, dashw2.py, final_pages.py,
# final_pages2.py, fontscan.py, dashfinal.py - each one re-measuring the same
# document with pypdfium2/PIL instead of re-rendering it.
#
# No threshold can catch that: measured per-run bash density, successes are at
# least as dense as the kills at every window from 60 to 150 calls (success max
# 74, kill min 74 at window 150), because the kills were doing legitimate diverse
# work rather than repeating. See the KNOWN LIMIT block in deer-flow-config.yaml.
#
# So the prompt is the only lever that reaches this. These checks pin it.
$boundedIteration = $text -match '(?i)(at most|no more than|maximum of)\s+(three|3|two|2)\s+(times|attempts|iterations)' `
    -or $text -match '(?i)iterat\w*[^\n]{0,80}(at most|no more than|three|3)\s*(times|attempts)?'
Check 'P6 prompt bounds layout iteration and requires delivering anyway' $boundedIteration `
    "without a bound the agent keeps re-measuring; the observed runs made 67-130 write_file calls on one document"

$noRemeasure = $text -match '(?i)(do not|don''t|never)[^\n]{0,120}(re-?measure|measure (it |the same )?again|new script[^\n]{0,60}same)' `
    -or $text -match '(?i)(have already measured|already measured|measured before)'
Check 'P7 prompt forbids re-measuring a property already measured' $noRemeasure `
    "uniquely named probe scripts (p18art.py, dashlen.py, fontscan.py) are repeats the hash guard cannot see, because every name differs"

$deliverOverProbe = $text -match '(?i)prefer one robust render'
Check 'P8 prompt prefers one robust render over many probes' $deliverOverProbe `
    "hand-rolled pypdfium2 measurement loops chase problems pandoc/weasyprint already solve"

$neverEmpty = $text -match '(?i)never end a run having produced nothing' `
    -or $text -match '(?i)(ship|deliver)[^\n]{0,80}(best|current)[^\n]{0,80}(artifact|version|file)'
Check 'P9 prompt requires shipping the best artifact rather than nothing' $neverEmpty `
    "a run killed at the recursion ceiling loses everything; an imperfect delivered file is still a success"

Write-Host ''
if ($failed -eq 0) {
    Write-Host "RESULT: $passed of $passed checks passed" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $failed of $($passed + $failed) checks FAILED" -ForegroundColor Red
exit 1
