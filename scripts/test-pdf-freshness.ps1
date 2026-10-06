# Asserts every rendered PDF is at least as new as its markdown source, and that
# the client-delivery copies have not drifted from their originals.
#
# WHY THIS GATE EXISTS
#
# These PDFs are CLIENT-FACING artifacts rendered by hand. Nothing regenerated
# them, and nothing checked them, so they silently went stale:
#
#   deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf        stale 12 days
#   docs/PACGATE-AI-FULL-STACK-REPORT-ZH.pdf      stale 1 day
#   scope-assets/generated/*-PHASE1-ZH.pdf        stale 8 days
#   scope-assets/generated/*-QUOTE-WORKSHEET*.pdf stale 8 days
#
# while the .md sources were edited. An operator reading the PDF gets
# instructions that were superseded - which is worse than a missing file,
# because a missing file is obviously missing.
#
# There is also a second copy of most of them under deploy/client-delivery/docs/,
# byte-identical by hand with no sync step. Editing the source PDF and forgetting
# the delivery copy ships a stale document to the client from a tree that looks
# correct. Both failure modes are checked here.
#
# A NOTE ON WHAT A TIMESTAMP CAN AND CANNOT TELL YOU
#
# This compares mtimes. That is a proxy: a PDF can be newer than its source and
# still be a stale render (touch it, or edit the md without re-rendering after).
# It cannot PROVE freshness, and this gate does not claim to. What it does catch
# is the actual observed failure: a source edited weeks after the render. A
# false pass requires someone to update a timestamp without re-rendering, which
# is not a thing that happens by accident; the false NEGATIVE (a stale PDF with
# an older md) is already covered by the git history of the pair.
#
# SCOPE: only PDFs that HAVE a tracked .md source are checked. The 75 PDFs under
# scope-assets/ with no source are third-party research and contracts - inputs,
# not renders - so requiring a source for them would fail on correct files.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. "Cannot check" is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== rendered PDFs vs their sources ===' -ForegroundColor Cyan

$tracked = @(git ls-files '*.pdf')
if ($tracked.Count -eq 0) {
    Write-Host '  exit 2 - git ls-files returned no PDFs; cannot check' -ForegroundColor Yellow
    exit 2
}

# ---------------------------------------------------------------------------
# 1. Every PDF with a tracked .md sibling must be at least as new as it.
# ---------------------------------------------------------------------------
$mdSet = @{}
foreach ($m in (git ls-files '*.md')) { $mdSet[$m.ToLower()] = $true }

$stale = @()
$checked = 0
foreach ($pdf in $tracked) {
    $src = ($pdf -replace '\.pdf$', '.md')
    if (-not $mdSet.ContainsKey($src.ToLower())) { continue }
    if (-not (Test-Path $pdf) -or -not (Test-Path $src)) { continue }
    $checked++

    $pdfTime = (Get-Item $pdf).LastWriteTime
    $mdTime = (Get-Item $src).LastWriteTime
    if ($mdTime -gt $pdfTime) {
        $days = [int]($mdTime - $pdfTime).TotalDays
        $stale += [pscustomobject]@{ Pdf = $pdf; Src = $src; Days = $days }
    }
}

if ($checked -eq 0) {
    Fail 'no PDF had a tracked .md source - either the sources were deleted or this scan is broken'
}
elseif ($stale.Count -eq 0) {
    Pass "all $checked rendered PDFs are at least as new as their sources"
}
else {
    foreach ($s in ($stale | Sort-Object Days -Descending)) {
        Fail "$($s.Pdf) is STALE by $($s.Days)d - $($s.Src) was edited after it was rendered"
    }
    Write-Host '        Re-render:  .venv\Scripts\python.exe safe_markdown_to_pdf.py <src.md> <out.pdf>' -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# 2. Client-delivery copies must not drift from their originals.
#
# Checked by CONTENT, not timestamp. Most are byte-identical by hand and there
# is no sync step, so a regenerated source PDF that was not copied across ships
# a stale document to the client from a correct-looking tree.
#
# MATCHING BY FILENAME ALONE IS NOT ENOUGH, and the first version of this check
# was wrong because it did exactly that. deploy/client-delivery/docs/
# AIPC-DEPLOYMENT-HANDBOOK.pdf and deploy/handbooks/pdf/AIPC-DEPLOYMENT-HANDBOOK.pdf
# share a name but are DIFFERENT DOCUMENTS (9 pages / 34 KB vs 13 pages / 400 KB)
# produced by different pipelines, so comparing them reported drift that was not
# drift. Copying one over the other "to fix it" would have shipped the wrong
# document to the client - a worse outcome than the staleness this gate exists
# to catch.
#
# Instead of guessing which pairs are meant to be identical, this asks GIT. A
# pair that is byte-identical at HEAD is meant to be identical, so any change is
# drift. A pair that differs at HEAD is a different document on purpose, and is
# reported as skipped rather than failed. Blob SHAs come from `git ls-tree`, so
# no file content is piped through PowerShell (which mangles binary streams).
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== client-delivery copies ===' -ForegroundColor Cyan

$deliveryDir = 'deploy/client-delivery/docs'
if (-not (Test-Path $deliveryDir)) {
    Fail "$deliveryDir not found - the client delivery package is missing, which is itself a release blocker"
}
else {
    # Blob SHAs at HEAD, parsed from ls-tree output: "<mode> blob <sha>\t<path>".
    # Multiple tracked paths can share ONE filename (deploy root, handbooks/pdf,
    # ...) with DIFFERENT blob SHAs on purpose - the handbooks copy is a
    # different revision of the same document. A single name->path map chose one
    # nondeterministically (last wins), which made the real copy-pair
    # (deploy root <-> client-delivery) "differ at HEAD" and get skipped - the
    # check asserted nothing and the truncation mutation passed unnoticed. The
    # index therefore holds EVERY origin per filename.
    $headBlobs = @{}
    foreach ($line in (git ls-tree -r HEAD)) {
        if ($line -match '^\d+\s+blob\s+([0-9a-f]+)\t(.+)$') {
            $headBlobs[$Matches[2]] = $Matches[1]
        }
    }

    $nameIndex = @{}
    foreach ($p in $tracked) {
        if ($p -match 'client-delivery') { continue }
        $name = [IO.Path]::GetFileName($p)
        if (-not $nameIndex.ContainsKey($name)) { $nameIndex[$name] = @() }
        $nameIndex[$name] += $p
    }

    $drift = @(); $skipped = @(); $compared = 0
    foreach ($copy in (Get-ChildItem $deliveryDir -Filter '*.pdf')) {
        $candidates = $nameIndex[$copy.Name]
        if (-not $candidates) { continue }

        $copyRel = ('deploy/client-delivery/docs/' + $copy.Name)
        # The copy was MEANT to match whichever origin it is byte-identical to
        # AT HEAD. With several candidates of differing revisions, a pair is a
        # real copy-pair only when the copy's HEAD blob equals THAT origin's.
        $origin = $null
        $copyHead = if ($headBlobs.ContainsKey($copyRel)) { $headBlobs[$copyRel] } else { $null }
        if ($copyHead) {
            $identical = @($candidates | Where-Object { $headBlobs.ContainsKey($_) -and $headBlobs[$_] -eq $copyHead })
            if ($identical.Count -eq 1) { $origin = $identical[0] }
            elseif ($identical.Count -gt 1) { $origin = $identical[0] }
        }
        if (-not $origin) {
            $skipped += $copy.Name
            continue
        }

        $compared++
        $a = (Get-FileHash $copy.FullName -Algorithm SHA256).Hash
        $b = (Get-FileHash $origin -Algorithm SHA256).Hash
        if ($a -ne $b) {
            $drift += [pscustomobject]@{ Copy = $copy.FullName; Origin = $origin }
        }
    }

    if ($compared -eq 0) {
        Fail "no client-delivery PDF was identical to its namesake at HEAD, so this check asserted nothing"
    }
    elseif ($drift.Count -eq 0) {
        Pass "all $compared client-delivery copies are still byte-identical to their originals"
    }
    else {
        foreach ($d in $drift) {
            Fail "$($d.Copy) DIFFERS from $($d.Origin) - a regenerated PDF was not copied into the delivery package"
        }
    }
    if ($skipped.Count -gt 0) {
        Write-Host "  NOTE  $($skipped.Count) copy/copies differ from their namesake AT HEAD and are treated as separate documents:" -ForegroundColor Gray
        foreach ($s in $skipped) { Write-Host "          $s" -ForegroundColor Gray }
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) PDF freshness check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: rendered PDFs are current and the client-delivery copies are in sync' -ForegroundColor Green
exit 0
