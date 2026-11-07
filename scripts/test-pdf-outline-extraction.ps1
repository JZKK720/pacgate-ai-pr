# Guard: a structured PDF upload must yield a document outline the agent can use.
#
# WHY THIS EXISTS (measured 2026-11-06, thread b315a961)
#
# The user uploaded a 65-page CJK tutorial PDF and asked the agent to "learn from
# it and create a tutorial". The run could not finish it, three times in a row:
#
#   run         bash calls   same-file re-touches   tokens     outcome
#   bb23453e    104           103                  3.51M      GraphRecursionError
#   4128a740     96            42 (tutorial.md)    3.36M      GraphRecursionError
#   22785db5     87            52 (test.pdf)       3.24M      GraphRecursionError
#
# Root cause was NOT the model, the prompt, or a loop-detection threshold. It was
# an uninstalled dependency:
#
#   deerflow/utils/file_conversion.py already prefers pymupdf4llm and falls back
#   to MarkItDown only when pymupdf4llm is missing or its output looks image-based.
#   pymupdf4llm was NOT in the image, so every upload silently took MarkItDown -
#   and MarkItDown does not reproduce the source PDF's typographic hierarchy.
#
# Same file, same convert_file_to_markdown() call, MEASURED both ways. These are
# the numbers from the ACTUAL PDF in that thread, re-run on 2026-11-06:
#
#   MarkItDown (what the image shipped) : 64,602 chars,   0 heading lines,  0 outline entries
#   pymupdf4llm (the code's first choice): 71,530 chars, 241 heading lines, 51 outline entries
#
# The PDF has a clean four-level hierarchy (body 10.4pt; headings at 11.2 / 13.0 /
# 19.0 / 33.0pt). With the outline empty, UploadsMiddleware emits
# "No structural headings detected" and no section map, so the agent was handed a
# 141 KB document with no navigable structure and re-read it from scratch on every
# turn. A prompt cannot fix a task whose structure the model was never shown.
#
# WHAT IS ASSERTED
#   O0 the deployed config resolves to a converter that can reach pymupdf4llm
#   O1 the image's venv can import pymupdf4llm (the PREFERRED converter is present)
#   O2 a real structured PDF converts through the same code path the uploads
#      middleware uses, and the result has heading lines
#   O3 extract_outline() on that markdown returns outline entries (the exact
#      signal UploadsMiddleware keys on)
#   O4 CONTROL: the outline must be substantive (>= 10 entries), so a near-empty
#      outline - or a converter regression that emits one accidental heading -
#      cannot pass. Proven to fail: with the package removed it reports
#      2 passed / 4 failed, exit 1.
#   O5 the converted text is not truncated, so a partial conversion cannot pass
#   O6 no raw HTML markup survives into outline titles (pymupdf4llm emits <mark>
#      for highlighted headings; tags in a title are prompt tokens and noise)
#
# O2/O3 run INSIDE the deer-flow container because the fix is a container-side
# dependency; checking the host would prove nothing.
#
# Exit codes: 0 = all pass, 1 = a real failure, 2 = cannot check (no container).
#
# Usage:  pwsh -File scripts/test-pdf-outline-extraction.ps1
#         pwsh -File scripts/test-pdf-outline-extraction.ps1 -PdfPath <path-in-container>

[CmdletBinding()]
param(
    [string]$Container = 'deer-flow',
    # A tracked, structured, multi-level PDF already in the repo's scope assets.
    # Overridable so the gate can be pointed at whatever the client last uploaded.
    [string]$PdfPath = '/tmp/outline-gate/input.pdf',
    # WHY A DIRECTORY AND A LENGTH FILTER, NOT A FILE NAME.
    #   This was a hardcoded literal: 'scope-assets/Harvey 2026??4??????????.pdf'.
    #   The script is UTF-8 with NO BOM (true of every script in this repo), so
    #   Windows PowerShell 5.1 decodes it as ANSI and mangles the Chinese
    #   characters. Test-Path then fails, staging fails, and the script exits 2.
    #   Exit 2 means "CANNOT CHECK", which run-all-checks.ps1 correctly reports as
    #   SKIP - so on a 5.1 machine this gate never actually ran; it passed only
    #   when a stale /tmp/outline-gate/input.pdf happened to survive in the
    #   container. Measured 2026-11-06 after recreating deer-flow: pwsh 7 -> 7/7
    #   PASS, powershell 5.1 -> SKIP. Selecting by directory + size keeps the
    #   gate ASCII-only, so it behaves identically under both hosts.
    [string]$RepoPdfDir = 'scope-assets',
    # Any of the scope PDFs is structured enough (>=10 outline entries) to prove
    # the converter works; the largest is used for a stable, deterministic pick.
    [int]$MinRepoPdfBytes = 500000
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$script:passed = 0
$script:failed = 0

function Assert-That {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        $script:failed++
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    }
}

Write-Host '=== PDF outline extraction ===' -ForegroundColor Cyan

# ── prerequisites ───────────────────────────────────────────────────────────
$running = (& docker ps --filter "name=^/$Container$" --format '{{.Names}}' 2>$null | Out-String).Trim()
if ($running -ne $Container) {
    Write-Host "SKIP: container '$Container' is not running." -ForegroundColor Yellow
    Write-Host 'CANNOT CHECK - this gate needs a live deer-flow container.' -ForegroundColor Yellow
    exit 2
}

$venvPython = '/app/backend/.venv/bin/python'

# ── O0: the deployed config has not disabled the preferred converter ────────
# The Dockerfile layer is necessary but not sufficient: `uploads.pdf_converter:
# markitdown` in config.yaml would route around pymupdf4llm entirely and restore
# the flat-Markdown behaviour while every other assertion here still looked
# plausible. Assert the RESOLVED value, not the file text, so a typo that falls
# back to the default is caught too.
Write-Host '0. converter selection' -ForegroundColor White
$convOut = (& docker exec $Container $venvPython -c "import sys; sys.path.insert(0,'/app/backend/packages/harness'); from deerflow.utils.file_conversion import _get_pdf_converter; print('CONVERTER=' + _get_pdf_converter())" 2>&1 | Out-String)
$converter = if ($convOut -match 'CONVERTER=(\S+)') { $Matches[1] } else { '' }
Assert-That ($converter -eq 'auto' -or $converter -eq 'pymupdf4llm') `
    "O0 uploads.pdf_converter resolves to a value that reaches pymupdf4llm (got '$converter')" `
    "markitdown selects the flat fallback directly; '' means the module was not importable from the config's point of view."
Write-Host "         resolved converter = $converter" -ForegroundColor DarkGray

# ── O1: the preferred converter is actually installed ───────────────────────
Write-Host '1. preferred converter present' -ForegroundColor White
$importOut = (& docker exec $Container $venvPython -c "import pymupdf4llm, pymupdf; print('OK', pymupdf.__version__)" 2>&1 | Out-String).Trim()
$importOk = $importOut -match '^OK\s'
Assert-That $importOk 'O1 the image venv can import pymupdf4llm' `
    "got: $importOut"
if ($importOk) {
    Write-Host "         pymupdf $(($importOut -split '\s+')[1]) via pymupdf4llm" -ForegroundColor DarkGray
}

# ── stage a real structured PDF inside the container ────────────────────────
# Precedence matters and got this wrong on the first draft: if -PdfPath was
# supplied EXPLICITLY, it wins. The earlier version always copied the repo PDF
# over it whenever that PDF existed, so `-PdfPath /tmp/incident.pdf` silently
# tested a different document and reported green. A gate that ignores its own
# parameter is worse than no parameter.
# Resolve the repo test PDF without embedding any non-ASCII literal - see the
# -RepoPdfDir param comment for the 5.1/ANSI failure this replaces.
$RepoPdf = $null
if (Test-Path $RepoPdfDir) {
    $RepoPdf = Get-ChildItem -Path $RepoPdfDir -Filter *.pdf -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge $MinRepoPdfBytes } |
        Sort-Object Length -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

$pathExplicit = $PSBoundParameters.ContainsKey('PdfPath')
$staged = $false

if ($pathExplicit -and $PdfPath -ne '/tmp/outline-gate/input.pdf') {
    # Caller named a file already inside the container: use it as-is.
    $exists = (& docker exec $Container sh -c "test -f '$PdfPath' && echo yes" 2>&1 | Out-String).Trim()
    $staged = ($exists -eq 'yes')
    if (-not $staged -and (Test-Path $PdfPath)) {
        # Named file is a HOST path instead - copy it in and keep the basename.
        $destPath = "/tmp/outline-gate/" + (Split-Path $PdfPath -Leaf)
        (& docker exec $Container sh -c "mkdir -p '/tmp/outline-gate'" 2>$null) | Out-Null
        (& docker cp $PdfPath "${Container}:$destPath" 2>&1) | Out-Null
        if ($LASTEXITCODE -eq 0) { $PdfPath = $destPath; $staged = $true }
    }
} elseif ($RepoPdf) {
    $probeDir = ($PdfPath -replace '/[^/]+$', '')
    (& docker exec $Container sh -c "mkdir -p '$probeDir'" 2>$null) | Out-Null
    (& docker cp $RepoPdf "${Container}:$PdfPath" 2>&1) | Out-Null
    $staged = ($LASTEXITCODE -eq 0)
} else {
    $exists = (& docker exec $Container sh -c "test -f '$PdfPath' && echo yes" 2>&1 | Out-String).Trim()
    $staged = ($exists -eq 'yes')
}

if (-not $staged) {
    Write-Host "SKIP: could not stage a test PDF (looked for a >=${MinRepoPdfBytes}-byte PDF under '$RepoPdfDir' and '$PdfPath')." -ForegroundColor Yellow
    if ($script:failed -gt 0) { exit 1 } else { exit 2 }
}

# ── O2/O3: convert the way the uploads middleware does, then read the outline ─
Write-Host '2. conversion + outline' -ForegroundColor White
$probe = @'
import asyncio, sys
sys.path.insert(0, "/app/backend/packages/harness")
from pathlib import Path
from deerflow.utils.file_conversion import convert_file_to_markdown, extract_outline

src = Path(sys.argv[1])
md = Path(asyncio.run(convert_file_to_markdown(src)))
text = md.read_text(encoding="utf-8")
headings = [l for l in text.splitlines() if l.lstrip().startswith("#")]
outline = extract_outline(md)
print(f"MARKDOWN={md}")
print(f"CHARS={len(text)}")
print(f"HEADINGS={len(headings)}")
print(f"OUTLINE={len(outline)}")
# Titles are rendered into the agent's prompt as the "Document outline" section,
# so raw markup in a title is prompt tokens spent on tags plus text the agent has
# to look past. pymupdf4llm emits <mark> for highlighted headings and <br> inside
# headings; measured 59 of 241 headings affected on the CJK tutorial PDF.
tagged = sum(1 for e in outline if "title" in e and ("<" in e["title"] or ">" in e["title"]))
print(f"TAGGED={tagged}")
print(f"ENTRIES={sum(1 for e in outline if 'title' in e)}")
for e in outline[:3]:
    if "title" in e:
        print("ENTRY=" + e["title"][:60])
'@

$probeOut = ($probe | & docker exec -i $Container $venvPython - $PdfPath 2>&1 | Out-String)
function Get-ProbeValue($key) {
    $m = [regex]::Match($probeOut, "(?m)^$key=(\S+)\s*$")
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

$chars = Get-ProbeValue 'CHARS'
$headingCount = Get-ProbeValue 'HEADINGS'
$outlineCount = Get-ProbeValue 'OUTLINE'

if ($null -eq $outlineCount) {
    Write-Host '  [FAIL] the conversion probe produced no parseable result' -ForegroundColor Red
    Write-Host $probeOut -ForegroundColor DarkGray
    $script:failed++
} else {
    $outlineN = [int]$outlineCount
    $headingN = [int]$headingCount

    Write-Host "         chars=$chars headings=$headingN outline=$outlineN" -ForegroundColor DarkGray

    # O2: the markdown must carry real headings, not a flat text dump.
    Assert-That ($headingN -gt 0) 'O2 converted markdown contains "# " headings' `
        "got $headingN heading lines. 0 means MarkItDown's flat fallback ran - the shape that caused thread b315a961 to re-read the same file 103 times."

    # O3: the exact signal UploadsMiddleware keys on to emit a section map.
    Assert-That ($outlineN -gt 0) 'O3 extract_outline() returns entries (agent gets a section map)' `
        "got $outlineN outline entries. 0 is the shipped defect: UploadsMiddleware then prints 'No structural headings detected' and the agent has no navigable view."

    # O4 CONTROL: a structured PDF of this size must produce a meaningful map, not
    # a token one-entry outline. Without this, a converter regression that emits a
    # single accidental heading would pass O2/O3 while remaining useless.
    Assert-That ($outlineN -ge 10) 'O4 CONTROL: outline is substantive (>= 10 entries)' `
        "got $outlineN. A structured multi-section document yielding fewer than 10 means the hierarchy is still being flattened."

    # The converted text must not be truncated relative to the source: a converter
    # that fails partway produces a short file that still has a few headings.
    Assert-That ([int]$chars -gt 1000) 'O5 converted text is not truncated' `
        "got $chars chars"

    # O6: no raw markup survives into the title text.
    #
    # The first version of the pymupdf4llm fix produced 51 outline entries while 59
    # of the 241 source headings carried <mark>, so "outline non-empty" was GREEN
    # and a third of the section map shown to the agent was tag soup. The gate must
    # catch that.
    #
    # Asserted as UNIT CONTROLS rather than by scanning the test PDF, because
    # whether a given PDF triggers <mark> depends on whether its author highlighted
    # text: measured across the repo's five scope PDFs, only the incident document
    # does (Harvey/Moritz/Crosby all yield 0). A gate that depends on which file
    # happens to be staged would silently stop testing this the moment the default
    # fixture changed - which is the "coverage that quietly disappears" failure.
    # These inputs are the exact shapes measured from the incident PDF.
    $taggedCount = Get-ProbeValue 'TAGGED'
    if ($null -ne $taggedCount -and [int]$taggedCount -gt 0) {
        Assert-That $false 'O6 no raw HTML markup leaks into outline titles' `
            "$taggedCount titles in the staged PDF still contain '<' or '>'."
    }

    $cleanProbe = @'
import sys
sys.path.insert(0, "/app/backend/packages/harness")
from deerflow.utils.file_conversion import _clean_bold_title
cases = [
    ("**<mark>1.1 Something</mark>**", "1.1 Something"),
    ("**<mark>一句话说明</mark>**", "一句话说明"),
    ("<mark>x</mark>", "x"),
    ("A<br>B", "A B"),
    ("A<br/>B", "A B"),
    ("<b>bold</b> and <i>it</i>", "bold and it"),
    ("**Overview**", "Overview"),
    ("**UNITED STATES** **SECURITIES**", "UNITED STATES SECURITIES"),
    ("plain text", "plain text"),
    ("  spaced   out  ", "spaced out"),
]
fails = []
for raw, want in cases:
    got = _clean_bold_title(raw)
    if got != want:
        fails.append("CLEANFAIL=%r->%r expected %r" % (raw, got, want))
print("CLEANFAILS=%d" % len(fails))
for f in fails:
    print(f)
'@
    $cleanProbe | Out-File -Encoding ascii (Join-Path $env:TEMP 'clean_titles_probe.py') -NoNewline
    (& docker cp (Join-Path $env:TEMP 'clean_titles_probe.py') "${Container}:/tmp/clean_titles_probe.py") | Out-Null
    $cleanOut = (& docker exec $Container $venvPython /tmp/clean_titles_probe.py 2>&1 | Out-String)
    (& docker exec $Container rm -f /tmp/clean_titles_probe.py) | Out-Null
    Remove-Item (Join-Path $env:TEMP 'clean_titles_probe.py') -ErrorAction SilentlyContinue

    $cleanFails = if ($cleanOut -match 'CLEANFAILS=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert-That ($cleanFails -eq 0) 'O6 no raw HTML markup leaks into outline titles (unit controls)' `
        "$cleanFails control case(s) failed.$(($cleanOut -split "`n" | Where-Object { $_ -match 'CLEANFAIL=' }) -join '; ')"
}

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: $($script:passed) passed, all green" -ForegroundColor Green
exit 0
