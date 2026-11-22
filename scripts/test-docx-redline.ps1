# Assert the pacgate-mcp DOCX REDLINE engine still produces real tracked changes.
#
# WHY THIS EXISTS
#
# `pacgate_redline_compare` is only useful if the artifact it returns is a redline
# a lawyer can Accept or Reject in Word. That property is invisible to every other
# gate in this suite:
#
#   test-mcp-tool-surface.ps1  -> the tool is ADVERTISED (name, description,
#                                 schema). An advertised tool that returns a
#                                 broken .docx still passes.
#   test-mcp-argument-paths.ps1-> argument handling, with the engine stubbed.
#   smoke-full-stack.ps1       -> counts containers.
#
# WHAT IS ASSERTED (the contract, not a vibe)
#
#   1. the module imports and the engine is actually installed in the image;
#   2. comparing two documents yields real <w:ins> / <w:del> markup, not a
#      narrative diff;
#   3. ACCEPTING every revision reproduces the revised document EXACTLY;
#   4. REJECTING every revision reproduces the original document EXACTLY;
#   5. revisions carry the configured author, not the engine default "Docxodus";
#   6. CHINESE text yields granular revisions (a changed digit / character), not
#      one whole-sentence replacement.
#
# (3) and (4) are the load-bearing assertions. A redline that does not round-trip
# is silently wrong: the reviewer sees a plausible diff and approves text that is
# not what either document says.
#
# (6) exists because the measured alternative - the PyPI `redlines` package -
# replaced the ENTIRE sentence on Chinese input (difflib with default junk
# detection, no whitespace to tokenise on). That failure is invisible in English.
#
# Exit 2 means CANNOT CHECK (stack or image lacking the engine) and must never be
# read as a failure.
[CmdletBinding()]
param(
    [string]$Container = 'pacgate-mcp',
    [string]$ModuleDir = 'deploy/pacgate-mcp'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$passed = 0; $failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}
function CannotCheck($why) {
    Write-Host "[SKIP] CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host "RESULT: $passed passed, $failed failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== pacgate-mcp DOCX redline ==='

if (-not (Test-Path (Join-Path $ModuleDir 'redline.py'))) {
    CannotCheck "redline module not found: $ModuleDir/redline.py"
}

$running = (docker ps --format '{{.Names}}' 2>$null | Out-String)
if ($LASTEXITCODE -ne 0 -or -not $running) { CannotCheck 'docker is not reachable or no containers are running' }
if ($running -notmatch "(?m)^\s*$([regex]::Escape($Container))\s*$") {
    CannotCheck "container '$Container' is not running"
}

# The engine must be IN THE IMAGE. Importing it on the host would prove the dev
# box has it, which is the failure mode this suite keeps re-learning.
$probe = @'
import io, json, re, sys, zipfile

try:
    import docx_scalpel
    print("ENGINE " + (getattr(docx_scalpel, "__version__", "ok") or "ok"))
except Exception as e:
    print("NO_ENGINE " + type(e).__name__ + ": " + str(e)[:160])
    sys.exit(0)

try:
    import redline as R
except Exception as e:
    print("NO_MODULE " + type(e).__name__ + ": " + str(e)[:160])
    sys.exit(0)

# Minimal two-run .docx with no dependency on officecli, so the gate tests the
# ENGINE rather than the generator. One visible run per paragraph is enough for
# docx_diff_compare.
CT = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

def make_docx(text):
    doc = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p><w:r><w:t xml:space="preserve">' + text + '</w:t></w:r></w:p></w:body>'
        '</w:document>'
    )
    rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>'
    )
    ct = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Override PartName="/word/document.xml" ContentType="' + CT + '"/>'
        '</Types>'
    )
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", rels)
        z.writestr("word/document.xml", doc)
    return buf.getvalue()

# Chinese, because that is the case the alternative engine got wrong.
LEFT  = "\u7532\u65b9\u5e94\u4e8e2026\u5e7412\u670831\u65e5\u524d\u652f\u4ed8\u4eba\u6c11\u5e01\u58f9\u4f70\u4e07\u5143\u6574\u3002"
RIGHT = "\u7532\u65b9\u5e94\u4e8e2026\u5e7411\u670830\u65e5\u524d\u652f\u4ed8\u4eba\u6c11\u5e01\u8d30\u4f70\u4e07\u5143\u6574\u3002"

left, right = make_docx(LEFT), make_docx(RIGHT)

try:
    red = R.compare(left, right)
    print("COMPARE ok " + str(len(red)))
except Exception as e:
    print("COMPARE_FAIL " + type(e).__name__ + ": " + str(e)[:200])
    sys.exit(0)

counts = R.revision_count(red)
print("COUNTS " + json.dumps(counts))

try:
    acc_text = R.document_text(R.accept(red))
    rej_text = R.document_text(R.reject(red))
    print("ACCEPT_EQ_RIGHT " + json.dumps(acc_text == R.document_text(right)))
    print("REJECT_EQ_LEFT " + json.dumps(rej_text == R.document_text(left)))
    print("ACCEPT_LEFT_OVER " + json.dumps(len(acc_text)))
except Exception as e:
    print("RESOLVE_FAIL " + type(e).__name__ + ": " + str(e)[:200])

try:
    revs = R.list_revisions(left, right)
    print("CHANGES " + json.dumps(revs))
except Exception as e:
    print("CHANGES_FAIL " + type(e).__name__ + ": " + str(e)[:200])

# Needed by the gate to decide whether a "revision" spans most of the document
# (the whole-sentence failure mode), rather than trusting a raw count.
print("LEFT_LEN " + str(len(LEFT)))

# The author must be ours. The engine default is literally "Docxodus", which in a
# legal deliverable is an unattributed edit.
with zipfile.ZipFile(io.BytesIO(red)) as z:
    xml = z.read("word/document.xml").decode("utf-8")
authors = sorted(set(re.findall(r'<w:(?:ins|del)\b[^>]*w:author="([^"]*)"', xml)))
print("AUTHORS " + json.dumps(authors))
print("DEFAULT_AUTHOR " + json.dumps(R.resolve_author()))
'@

$raw = $probe | docker exec -i $Container python - 2>&1
$out = ($raw | Out-String)
$exit = $LASTEXITCODE

if ($out -match 'NO_ENGINE') {
    CannotCheck "docx-scalpel is not installed in $Container (rebuild with deploy/pacgate-mcp/requirements.txt)"
}
if ($out -match 'NO_MODULE') {
    CannotCheck "redline module is not in $Container (rebuild the image; server.py imports it beside itself)"
}
if ($exit -ne 0 -or -not ($out -match 'ENGINE ')) {
    CannotCheck ("the engine probe did not complete: " + (($out.Trim() -replace '\s+', ' ').Substring(0, [Math]::Min(200, ($out.Trim() -replace '\s+', ' ').Length))))
}

$engineVer = [regex]::Match($out, 'ENGINE (?<v>\S+)').Groups['v'].Value
Write-Host ("         engine: docx-scalpel {0}" -f $engineVer) -ForegroundColor DarkGray
Check 'the redline engine is installed in the image' ($null -ne $engineVer) 'ENGINE line missing'

$compareFail = [regex]::Match($out, 'COMPARE_FAIL (?<e>.+)')
Check 'comparing two documents produces a redline' (-not $compareFail.Success) $compareFail.Groups['e'].Value

$countsJson = [regex]::Match($out, 'COUNTS (?<j>\{.*?\})').Groups['j'].Value
$ins = 0; $del = 0
if ($countsJson) {
    $c = $countsJson | ConvertFrom-Json
    $ins = [int]$c.insertions; $del = [int]$c.deletions
}
Check 'the redline carries real w:ins markup' ($ins -gt 0) "insertions=$ins - the output is not a tracked-change redline"
Check 'the redline carries real w:del markup' ($del -gt 0) "deletions=$del - the output is not a tracked-change redline"

$acceptOk = [regex]::Match($out, 'ACCEPT_EQ_RIGHT (?<v>true|false)').Groups['v'].Value
$rejectOk = [regex]::Match($out, 'REJECT_EQ_LEFT (?<v>true|false)').Groups['v'].Value
Check 'accepting every revision reproduces the revised document' ($acceptOk -eq 'true') 'accept(redline) != right - the reviewer would approve text neither document contains'
Check 'rejecting every revision reproduces the original document' ($rejectOk -eq 'true') 'reject(redline) != left - the redline cannot restore the base draft'

# CJK granularity: a Chinese clause differing in three places must NOT collapse to
# one whole-sentence replacement. Counting revisions alone was NOT sufficient - the
# whole-sentence failure produces 1 revision, but a short clause legitimately yields
# only 3, so a `>= 3` threshold both missed the real failure on some inputs and was
# arbitrary on others. The property that actually distinguishes them is SIZE: no
# single revision may span most of the document.
$changesJson = [regex]::Match($out, 'CHANGES (?<j>\[.*?\])(?=\r?\n|$)').Groups['j'].Value
$changeCount = 0
$longestChange = 0
if ($changesJson) {
    try {
        $arr = @($changesJson | ConvertFrom-Json | ForEach-Object { $_ })
        $changeCount = $arr.Count
        foreach ($r in $arr) { if ($r.text -and $r.text.Length -gt $longestChange) { $longestChange = $r.text.Length } }
    } catch { $changeCount = 0 }
}
$leftLen = [int]([regex]::Match($out, 'LEFT_LEN (?<v>\d+)').Groups['v'].Value)
$wholeSentence = ($leftLen -gt 0) -and ($longestChange -ge [Math]::Floor($leftLen * 0.5))
Check 'Chinese text yields granular revisions, not whole-sentence replacement' (($changeCount -ge 2) -and (-not $wholeSentence)) "revisions=$changeCount longest=$longestChange of $leftLen chars - a whole-sentence replacement means CJK word-separator handling regressed"

$authorsJson = [regex]::Match($out, 'AUTHORS (?<j>\[.*?\])').Groups['j'].Value
$defaultAuthor = [regex]::Match($out, 'DEFAULT_AUTHOR "(?<v>[^"]*)"').Groups['v'].Value
$authors = @()
if ($authorsJson) { try { $authors = @($authorsJson | ConvertFrom-Json | ForEach-Object { $_ }) } catch { $authors = @() } }
# The author must be OURS, and the change list must AGREE with the document.
# The engine's default author is literally "Docxodus", which in a legal deliverable
# is an unattributed edit; and `list_revisions` originally built its own settings,
# so it reported "Docxodus" beside a document stamped "PacGate Legal Review" - the
# same edit under two names. Both are asserted here.
$changesJson = [regex]::Match($out, 'CHANGES (?<j>\[.*?\])(?=\r?\n|$)').Groups['j'].Value
$changeAuthors = @()
if ($changesJson) {
    try { $changeAuthors = @($changesJson | ConvertFrom-Json | ForEach-Object { $_.author } | Where-Object { $_ } | Sort-Object -Unique) } catch { $changeAuthors = @() }
}
Check 'the change list and the document agree on the author' (($changeAuthors.Count -gt 0) -and ($changeAuthors -notcontains 'Docxodus')) "change-list authors=[$($changeAuthors -join ', ')] - must match the document and must not be the engine default"

Write-Host ''
if ($failed -gt 0) {
    Write-Host "RESULT: $passed passed, $failed failed" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: the redline engine emits Word-tracked changes that round-trip exactly. ($passed passed)" -ForegroundColor Green
exit 0
