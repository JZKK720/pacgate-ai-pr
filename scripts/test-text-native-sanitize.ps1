# PROVES that every text-native document type the client uploads reaches the
# sanitizer WITH ITS TEXT ACTUALLY READ. This is the RED gate for Plan B
# (docs/superpowers/plans/2026-09-24-text-native-document-coverage.md, Task 1).
#
# WHY THIS EXISTS
#
# `extract_document` hands every format to `ocr-service`, which rasterises only
# `.pdf` (deploy/ocr-service/app.py::_prepare_pages). Anything else is passed to
# PaddleOCR as raw bytes, raises, and reports `incomplete=true` -> sanitize 500.
# So a `.docx`, `.txt` or `.md` the client uploads can never be sanitized, and
# `.xlsx`/`.pptx` are rejected at upload before they even get that far.
#
# The plan's safety case is T4. Every converter we currently ship -- mammoth 1.11
# (markitdown's engine), markitdown 0.1.7 (deployed) and pacgate-docx -- reads
# only `word/document.xml` and MISSES `word/header1.xml`. A client ID that lives
# in a header therefore reaches the redactor as nothing, the document reports
# `sanitized`, and it egresses with the identifier intact. That fails OPEN, which
# is why T4 asserts an identifier that exists ONLY in a header.
#
# CASES
#
#   T1  .txt   ID + phone              extract fails today
#   T2  .md    ID + phone              extract fails today
#   T3  .docx  ID + phone in the body  extract fails today
#   T4  .docx  ID ONLY in a header     extract fails today -- THE SAFETY CASE
#   T5  .xlsx  ID + phone in cells     upload REJECTED today
#   T6  .pptx  ID + phone in a slide   upload REJECTED today
#   CONTROL .pdf ID + phone, readable  passes today -- must NOT regress
#
# Per case, in order:
#   1. fixture on disk is non-empty   (the false-pass guard, see below)
#   2. upload returns 2xx
#   3. extract returns 200 with incomplete=false
#   4. the extracted text CONTAINS both identifiers
#   5. sanitize returns 200 with verdict=pass and redaction_count >= 2
#   6. the sanitized text is non-empty and carries NEITHER identifier
#
# THE FALSE-PASS GUARD
#
# An earlier gate in this repo "passed" two assertions because a broken fixture
# path made PowerShell pass an empty string to ReadAllBytes, a ZERO-BYTE file was
# uploaded, and OCR reported incomplete for the wrong reason. Two consequences,
# both implemented here:
#
#   * every fixture is asserted `> 1000` bytes on disk BEFORE it is uploaded;
#   * assertion 4 asserts the text CONTAINS the identifiers rather than merely
#     being non-empty;
#   * assertion 6 is gated on sanitize having actually succeeded and produced
#     non-empty text. `-not ''.Contains('x')` is TRUE, so an absence check that
#     runs after a failed sanitize passes vacuously -- the same class of false
#     pass, one layer further down.
#
# Exit: 0 = all pass, 1 = a real failure, 2 = cannot check (stack unreachable).
#
# Invoke: pwsh -File scripts/test-text-native-sanitize.ps1

[CmdletBinding()]
param(
    [string]$BaseUrl = '',
    [string]$EnvFile = '',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repo 'deploy/client-bundle/.env' }

# The two identifiers every fixture carries. Bare (or space-separated) tokens
# only: the Tier-1 redaction rules are boundary-anchored, so a label GLUED to the
# digits ("ID1101...") reads as one longer token and is correctly not matched.
# That strictness is intended; the fixtures must not fight it.
$ID_CARD = '11010519491231002X'
$PHONE   = '13812345678'

$script:failures = 0
$script:checks = 0

function Check($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) {
        Write-Host "  [PASS] $label" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $label" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:failures++
    }
}

function Die($msg) {
    Write-Host "`nCANNOT CHECK: $msg" -ForegroundColor Yellow
    exit 2
}

# Pull status + body off a non-2xx response. Invoke-RestMethod throws on 4xx/5xx
# and the body is the only place the API explains itself ("unsupported file type;
# expected ..."), so losing it would make T5/T6 unreadable.
function Get-HttpError {
    param($ErrorRecord)
    $status = $null
    $body = ''
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode.value__ } catch { }
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $body = $ErrorRecord.ErrorDetails.Message
        }
    } catch { }
    if (-not $body) {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                $reader.Dispose()
            }
        } catch { }
    }
    $body = ($body -replace '\s+', ' ').Trim()
    if ($body.Length -gt 400) { $body = $body.Substring(0, 400) }
    return @{ status = $status; body = $body }
}

Write-Host '=== text-native document coverage gate ===' -ForegroundColor Cyan

# ── Resolve the ingress port from the RUNNING container, never from a constant ──
# `docker port` reads the live container; `docker compose port` reads the compose
# project, which answers the DECLARED mapping and can differ from what is actually
# published (that mismatch is exactly how a stale 8081/8089 assumption hides).
if (-not $BaseUrl) {
    $derived = ''
    try {
        $published = docker port pacgate-nginx 80 2>$null
        if ($published -match ':(\d+)\s*$') { $derived = $Matches[1] }
    } catch { }
    if (-not $derived) {
        try {
            $published = docker compose -f (Join-Path $repo 'deploy/client-bundle/compose.prod.yaml') port nginx 80 2>$null
            if ($published -match ':(\d+)\s*$') { $derived = $Matches[1] }
        } catch { }
    }
    if (-not $derived) { $derived = '8089' }
    $BaseUrl = "http://localhost:$derived/pacgate"
}
Write-Host "  base: $BaseUrl"

if (-not (Test-Path $EnvFile)) { Die "credentials file not found: $EnvFile" }

# Presence check ONLY -- a boolean from -Quiet, never a printed line, never
# $Matches. A non-Quiet grep over this file leaked a password earlier in this work.
$hasEmail    = [bool](Select-String -Path $EnvFile -Pattern 'PACGATE_API_EMAIL='    -Quiet)
$hasPassword = [bool](Select-String -Path $EnvFile -Pattern 'PACGATE_API_PASSWORD=' -Quiet)
if (-not $hasEmail -or -not $hasPassword) {
    Die 'PACGATE_API_EMAIL / PACGATE_API_PASSWORD not present in .env'
}

# Read them for the login below. Values are held in variables and never echoed;
# this is the same parse every gate in this repo uses.
$email = $null; $password = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^PACGATE_API_EMAIL=(.+)$')    { $email    = $Matches[1].Trim() }
    if ($line -match '^PACGATE_API_PASSWORD=(.+)$') { $password = $Matches[1].Trim() }
}
if (-not $email -or -not $password) { Die 'PACGATE_API_EMAIL / PACGATE_API_PASSWORD are empty in .env' }

# ── Reachability: /version is at the nginx ROOT, not under /pacgate ──
# Probing <base>/version returns 401 and reads as an auth failure, which sends you
# chasing the wrong defect.
$rootUrl = ($BaseUrl -replace '/pacgate/?$', '')
$version = $null
foreach ($candidate in @("$rootUrl/version", "$BaseUrl/version")) {
    try {
        $v = Invoke-RestMethod -Uri $candidate -TimeoutSec 10
        if ($v.version) { $version = $v; break }
    } catch { }
}
if (-not $version) { Die "no version answered at $rootUrl/version or $BaseUrl/version" }
Write-Host "  version=$($version.version) revision=$($version.revision)"

# ── Auth ──
$token = $null
foreach ($path in @("$BaseUrl/api/auth/login", "$BaseUrl/auth/login")) {
    try {
        $body = @{ email = $email; password = $password } | ConvertTo-Json -Compress
        $login = Invoke-RestMethod -Uri $path -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 20
        if ($login.token) { $token = $login.token; break }
    } catch { }
}
if (-not $token) { Die 'login failed on both route shapes' }
$AuthHeaders = @{ Authorization = "Bearer $token" }

# ── Fixture builders ─────────────────────────────────────────────────────────
#
# All fixture construction runs through `docker run ... -c @"..."@` here-strings,
# the form every fixture builder in this repo uses (test-empty-extraction-gate.ps1,
# test-legal-journey.ps1:161, test-sanitizer-e2e.ps1:18). A draft of this gate
# piped the script to `python3 -` over stdin; no gate here uses that form and it
# was replaced.
#
# LIBRARY AVAILABILITY, MEASURED (this differs from the plan -- see the report):
#   ocr-service:local   PIL OK   python-docx OK   openpyxl MISSING   python-pptx MISSING
#   deer-flow-pacgate   none of the OOXML libraries present
# So `.docx` is built with python-docx, and `.xlsx`/`.pptx` are built with the
# STDLIB `zipfile` writer. That is also what Task 3's Rust unit tests do, since a
# hand-built package is the only way to control exactly which parts carry text.

function New-TextFixture {
    <# A plain `.txt`/`.md` fixture. No container needed -- this is a file write. #>
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$Kind   # txt | md
    )
    $body = if ($Kind -eq 'md') {
        "# Client intake record`n`n$ID_CARD`n`n$PHONE`n"
    } else {
        "Client intake record`n`n$ID_CARD`n$PHONE`n"
    }
    # UTF8 without BOM: a BOM would ride at the head of the extracted text and is
    # not representative of what a client sends.
    [System.IO.File]::WriteAllText($OutPath, $body, (New-Object System.Text.UTF8Encoding($false)))
    return (Test-Path $OutPath)
}

function New-HtmlFixture {
    <#
      A real .html file. Added after the final review found that .html was on the
      upload allowlist and in the routing match, yet had NO end-to-end case -- its
      only coverage was a Rust unit test on the extractor in isolation, so the
      ROUTING and the sanitize pipeline were never exercised for it.

      The identifier is in visible body text; a <script> block carries a decoy so a
      tag-strip that leaked script content as text would be visible.
    #>
    param([Parameter(Mandatory)][string]$OutPath)
    $html = @"
<!DOCTYPE html>
<html><head><title>Intake</title>
<script>var decoy = 'SCRIPTLEAK';</script>
<style>body { color: red; }</style>
</head>
<body><h1>Client intake record</h1><p>ID $ID_CARD</p><p>Phone $PHONE</p></body></html>
"@
    [System.IO.File]::WriteAllText($OutPath, $html, (New-Object System.Text.UTF8Encoding($false)))
    return (Test-Path $OutPath)
}

function New-Utf16Fixture {
    <#
      A BOM-LESS UTF-16LE .txt. Both halves matter:

      * No BOM -- a BOM raises a decode error and fails closed, so a fixture WITH
        one would pass while the real hole stayed open.
      * UTF-16 -- every byte of ASCII text in UTF-16LE is below 0x80, so
        String::from_utf8 ACCEPTS it and returns NUL-interleaved text. The file
        contains the identifier byte-for-byte; the extracted string does not, as a
        contiguous substring. Without the NUL check the document reports complete and
        the redactor finds nothing.

      The expected outcome is a REFUSAL, not a redaction, so this case asserts
      incompleteness rather than the usual pass/redact chain.
    #>
    param([Parameter(Mandatory)][string]$OutPath)
    $text = "Client intake record`n`n$ID_CARD`n$PHONE`n"
    [System.IO.File]::WriteAllBytes($OutPath, [System.Text.Encoding]::Unicode.GetBytes($text))
    return (Test-Path $OutPath)
}

function New-DocxFixture {
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$Kind   # body | header | carriers
    )
    if ($Kind -ne 'body' -and $Kind -ne 'header' -and $Kind -ne 'carriers') {
        throw "New-DocxFixture: unsupported Kind '$Kind' (use body, header or carriers)"
    }
    $dir = Split-Path $OutPath -Parent
    $leaf = Split-Path $OutPath -Leaf
    docker run --rm -v "${dir}:/fix" --entrypoint python3 ocr-service:local -c @"
from docx import Document
d = Document()
if '$Kind' == 'body':
    d.add_paragraph('Client intake record')
    d.add_paragraph('$ID_CARD')
    d.add_paragraph('$PHONE')
    d.save('/fix/$leaf')
elif '$Kind' == 'header':
    # THE SAFETY CASE. The identifier exists ONLY in the header, and the phone
    # only in the footer, so a converter that reads word/document.xml alone
    # extracts a document that looks complete and carries neither identifier.
    d.add_paragraph('Agreement between the parties.')
    d.sections[0].header.paragraphs[0].text = 'Client ID $ID_CARD'
    d.sections[0].footer.paragraphs[0].text = 'Contact $PHONE'
    d.save('/fix/$leaf')
else:
    # THE CARRIER CASE: hand-built, never through python-docx.
    #
    # Each branch saves INSIDE itself. An earlier version had one save after the
    # whole if/elif/else, which meant the python-docx save OVERWROTE the hand-built
    # carrier package with an empty python-docx document -- T8 then extracted only
    # 'creator: python-docx'. The fixture was the bug, not the extractor: a test
    # fixture that silently produces a DIFFERENT document than intended is the same
    # false-pass class this suite keeps finding.
    import zipfile
    ct = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
          '<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">'
          '<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>'
          '<Default Extension=\"xml\" ContentType=\"application/xml\"/>'
          '<Override PartName=\"/word/document.xml\" '
          'ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>'
          '</Types>')
    rel = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
           '<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">'
           '<Relationship Id=\"rId1\" '
           'Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" '
           'Target=\"word/document.xml\"/></Relationships>')
    doc = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
           '<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>'
           '<w:p><w:r><w:t>Agreement between the parties.</w:t></w:r></w:p>'
           '<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>'
           '<w:r><w:instrText xml:space=\"preserve\"> REF _Ref1 \\h \"' + '$ID_CARD' + '\"</w:instrText></w:r>'
           '<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>'
           '<w:r><w:t>see above</w:t></w:r>'
           '<w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>'
           '<w:p><w:r><w:t>Client </w:t></w:r>'
           '<w:del w:id=\"1\" w:author=\"A\" w:date=\"2026-01-01T00:00:00Z\">'
           '<w:r><w:delText>' + '$PHONE' + '</w:delText></w:r></w:del>'
           '<w:r><w:t> retained</w:t></w:r></w:p>'
           '</w:body></w:document>')
    with zipfile.ZipFile('/fix/$leaf', 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', ct)
        z.writestr('_rels/.rels', rel)
        z.writestr('word/document.xml', doc)
"@ 2>&1 | Out-Null
    return (Test-Path $OutPath)
}

function New-OoxmlFixture {
    <#
      Hand-built .xlsx / .pptx packages, written with the stdlib zipfile writer
      because neither openpyxl nor python-pptx is present in any image on this box.

      Both are structurally real: correct [Content_Types].xml, relationship parts,
      and the actual text elements the plan's extractor scans for
      (`xl/*.xml` <t>, `ppt/*.xml` <a:t>). .xlsx cells are SHARED STRINGS on
      purpose -- F3 in the plan records that numeric cells live in <v> and are not
      read as text, so a cell the extractor is supposed to see must be a string.
    #>
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$Kind   # xlsx | pptx
    )
    if ($Kind -ne 'xlsx' -and $Kind -ne 'pptx') {
        throw "New-OoxmlFixture: unsupported Kind '$Kind' (use xlsx or pptx)"
    }
    $dir = Split-Path $OutPath -Parent
    $leaf = Split-Path $OutPath -Leaf
    docker run --rm -v "${dir}:/fix" --entrypoint python3 ocr-service:local -c @"
import zipfile

KIND = '$Kind'
ID = '$ID_CARD'
PHONE = '$PHONE'

W = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
PKG = 'http://schemas.openxmlformats.org/package/2006/relationships/'
CORE_CT = 'application/vnd.openxmlformats-package.core-properties+xml'

def content_types(overrides):
    s = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
         '<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">'
         '<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>'
         '<Default Extension=\"xml\" ContentType=\"application/xml\"/>')
    for part, typ in overrides:
        s += '<Override PartName=\"%s\" ContentType=\"%s\"/>' % (part, typ)
    return s + '</Types>'

def rels(items):
    s = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
         '<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">')
    for rid, typ, tgt in items:
        s += '<Relationship Id=\"%s\" Type=\"%s\" Target=\"%s\"/>' % (rid, typ, tgt)
    return s + '</Relationships>'

CORE = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
        '<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" '
        'xmlns:dc=\"http://purl.org/dc/elements/1.1/\">'
        '<dc:creator>Intake Clerk</dc:creator>'
        '<cp:lastModifiedBy>Intake Clerk</cp:lastModifiedBy>'
        '<dc:title>Client intake record</dc:title>'
        '</cp:coreProperties>')

DRAWINGML = 'http://schemas.openxmlformats.org/drawingml/2006/main'
PRESML = 'http://schemas.openxmlformats.org/presentationml/2006/main'

parts = {}
parts['docProps/core.xml'] = CORE

if KIND == 'xlsx':
    parts['[Content_Types].xml'] = content_types([
        ('/xl/workbook.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml'),
        ('/xl/worksheets/sheet1.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'),
        ('/xl/sharedStrings.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml'),
        ('/docProps/core.xml', CORE_CT),
    ])
    parts['_rels/.rels'] = rels([
        ('rId1', W + 'officeDocument', 'xl/workbook.xml'),
        ('rId2', PKG + 'metadata/core-properties', 'docProps/core.xml'),
    ])
    parts['xl/workbook.xml'] = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
        '<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" '
        'xmlns:r=\"' + W + '\">'
        '<sheets><sheet name=\"Intake\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>')
    parts['xl/_rels/workbook.xml.rels'] = rels([
        ('rId1', W + 'worksheet', 'worksheets/sheet1.xml'),
        ('rId2', W + 'sharedStrings', 'sharedStrings.xml'),
    ])
    parts['xl/sharedStrings.xml'] = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
        '<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"2\" uniqueCount=\"2\">'
        '<si><t>%s</t></si><si><t>%s</t></si></sst>' % (ID, PHONE))
    parts['xl/worksheets/sheet1.xml'] = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
        '<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">'
        '<sheetData>'
        '<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row>'
        '<row r=\"2\"><c r=\"A2\" t=\"s\"><v>1</v></c></row>'
        '</sheetData></worksheet>')
else:
    parts['[Content_Types].xml'] = content_types([
        ('/ppt/presentation.xml', 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml'),
        ('/ppt/slides/slide1.xml', 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml'),
        ('/ppt/slideLayouts/slideLayout1.xml', 'application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml'),
        ('/ppt/slideMasters/slideMaster1.xml', 'application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml'),
        ('/docProps/core.xml', CORE_CT),
    ])
    parts['_rels/.rels'] = rels([
        ('rId1', W + 'officeDocument', 'ppt/presentation.xml'),
        ('rId2', PKG + 'metadata/core-properties', 'docProps/core.xml'),
    ])
    parts['ppt/presentation.xml'] = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
        '<p:presentation xmlns:p=\"' + PRESML + '\" xmlns:r=\"' + W + '\">'
        '<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId2\"/></p:sldMasterIdLst>'
        '<p:sldIdLst><p:sldId id=\"256\" r:id=\"rId1\"/></p:sldIdLst>'
        '<p:sldSz cx=\"9144000\" cy=\"6858000\"/></p:presentation>')
    parts['ppt/_rels/presentation.xml.rels'] = rels([
        ('rId1', W + 'slide', 'slides/slide1.xml'),
        ('rId2', W + 'slideMaster', 'slideMasters/slideMaster1.xml'),
    ])
    shaped = ('<p:sp><p:nvSpPr><p:cNvPr id=\"%d\" name=\"Text %d\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
              '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>%s</a:t></a:r></a:p></p:txBody></p:sp>')
    parts['ppt/slides/slide1.xml'] = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
        '<p:sld xmlns:p=\"' + PRESML + '\" xmlns:a=\"' + DRAWINGML + '\" xmlns:r=\"' + W + '\">'
        '<p:cSld><p:spTree>'
        '<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
        '<p:grpSpPr/>'
        + (shaped % (2, 2, ID)) + (shaped % (3, 3, PHONE)) +
        '</p:spTree></p:cSld></p:sld>')
    parts['ppt/slides/_rels/slide1.xml.rels'] = rels([
        ('rId1', W + 'slideLayout', '../slideLayouts/slideLayout1.xml'),
    ])
    parts['ppt/slideLayouts/slideLayout1.xml'] = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
        '<p:sldLayout xmlns:p=\"' + PRESML + '\" xmlns:a=\"' + DRAWINGML + '\" type=\"blank\">'
        '<p:cSld name=\"Blank\"><p:spTree>'
        '<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
        '</p:spTree></p:cSld></p:sldLayout>')
    parts['ppt/slideLayouts/_rels/slideLayout1.xml.rels'] = rels([
        ('rId1', W + 'slideMaster', '../slideMasters/slideMaster1.xml'),
    ])
    parts['ppt/slideMasters/slideMaster1.xml'] = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>'
        '<p:sldMaster xmlns:p=\"' + PRESML + '\" xmlns:a=\"' + DRAWINGML + '\" xmlns:r=\"' + W + '\">'
        '<p:cSld name=\"Master\"><p:spTree>'
        '<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
        '</p:spTree></p:cSld>'
        '<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>'
        '</p:sldMaster>')
    parts['ppt/slideMasters/_rels/slideMaster1.xml.rels'] = rels([
        ('rId1', W + 'slideLayout', '../slideLayouts/slideLayout1.xml'),
    ])

with zipfile.ZipFile('/fix/$leaf', 'w', zipfile.ZIP_DEFLATED) as z:
    for name in sorted(parts):
        z.writestr(name, parts[name])
"@ 2>&1 | Out-Null
    return (Test-Path $OutPath)
}

function New-PdfFixture {
    <# The CONTROL. A readable page the current pipeline already handles, drawn with
       a LARGE font -- 56pt is what makes OCR read the identifiers verbatim rather
       than misreading a tiny glyph run. #>
    param([Parameter(Mandatory)][string]$OutPath)
    $dir = Split-Path $OutPath -Parent
    $leaf = Split-Path $OutPath -Leaf
    docker run --rm -v "${dir}:/fix" --entrypoint python3 ocr-service:local -c @"
from PIL import Image, ImageDraw, ImageFont
W, H = 1400, 500
try:
    font = ImageFont.truetype('DejaVuSans-Bold.ttf', 56)
except OSError:
    font = ImageFont.load_default()
img = Image.new('RGB', (W, H), 'white')
d = ImageDraw.Draw(img)
d.text((40, 150), '$ID_CARD', fill='black', font=font)
d.text((40, 280), '$PHONE', fill='black', font=font)
img.save('/fix/$leaf', 'PDF', resolution=150)
"@ 2>&1 | Out-Null
    return (Test-Path $OutPath)
}

# ── Upload helper ──
function Send-Upload {
    param(
        [string]$MatterId,
        [string]$FilePath,
        [string]$Filename,
        [string]$ContentType
    )
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $boundary = "----txtnative$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $prefix = "--$boundary`r`nContent-Disposition: form-data; name=`"matter_id`"`r`n`r`n$MatterId`r`n" +
              "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$Filename`"`r`n" +
              "Content-Type: $ContentType`r`n`r`n"
    $suffix = "`r`n--$boundary--`r`n"
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes($prefix))
    $bw.Write($bytes)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes($suffix))
    $bw.Flush()
    return Invoke-RestMethod -Uri "$BaseUrl/api/documents" -Method Post `
        -Headers $AuthHeaders -ContentType "multipart/form-data; boundary=$boundary" `
        -Body $ms.ToArray() -TimeoutSec 120
}

# ── Matter ──
$matter = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Method Post -Headers $AuthHeaders `
    -TimeoutSec 20 -ContentType 'application/json' `
    -Body (@{ name = "txtnative-$([guid]::NewGuid().ToString('N').Substring(0,8))";
               description = 'text-native coverage gate' } | ConvertTo-Json -Compress)
$script:matterId = $matter.id
if (-not $script:matterId) { Die 'matter create returned no id' }
Write-Host "  matter=$($script:matterId)"
$script:createdDocs = @()

$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "txtnative-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

function Invoke-RefusalCase {
    <#
      The inverse of Invoke-Case: the CORRECT outcome is a refusal.

      A format can be readable in general and still hold input we must not treat as
      text. The .txt/.md path is the case: `.txt` is UTF-8 by definition, and a
      BOM-less UTF-16 file is ALSO valid UTF-8 (every byte below 0x80), so
      `String::from_utf8` accepts it and returns NUL-interleaved text. The file then
      carries the identifier byte-for-byte while the extracted string does not, as a
      contiguous substring -- so a redaction-proving assertion would pass vacuously
      and the document would be certified clean.

      Assertions, in order:
        1. fixture on disk is non-empty
        2. upload returns 2xx (the format IS supported)
        3. extract returns incomplete=true   <- the whole point
        4. sanitize is REFUSED (not 200)
        5. download is REFUSED (not 200)
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][string]$ContentType,
        [int]$MinBytes = 8
    )

    Write-Host ''
    Write-Host "== $Label" -ForegroundColor Cyan

    if (-not (Test-Path $FixturePath)) {
        Check "$Label - fixture exists" $false "no fixture at '$FixturePath'"; return
    }
    $size = (Get-Item $FixturePath).Length
    Check "$Label - fixture on disk is non-empty" ($size -ge $MinBytes) "size=$size bytes"

    $doc = Send-Upload -MatterId $script:matterId -FilePath $FixturePath -Filename $Filename -ContentType $ContentType
    if (-not $doc.id) { Check "$Label - upload returns 2xx" $false 'upload returned no id'; return }
    Check "$Label - upload returns 2xx" $true ''
    $script:createdDocs += $doc.id

    $extract = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$($doc.id)/extract" -Method Post `
        -Headers $AuthHeaders -ContentType 'application/json' -Body '{}' -TimeoutSec 300
    Write-Host "     extract incomplete=$($extract.incomplete)"
    Check "$Label - extract reports incomplete=true (REFUSED, not silently read)" `
        ("$($extract.incomplete)" -eq 'true') `
        "incomplete=$($extract.incomplete); NUL-interleaved text must never be treated as a complete read"

    $sanitizeStatus = $null
    try {
        $sanitizeStatus = (Invoke-WebRequest -Uri "$BaseUrl/api/documents/$($doc.id)/sanitize" -Method Post `
            -Headers $AuthHeaders -ContentType 'application/json' -Body '{"data_level":"T3"}' `
            -TimeoutSec 300 -UseBasicParsing).StatusCode
    } catch {
        $sanitizeStatus = [int]$_.Exception.Response.StatusCode.value__
    }
    Check "$Label - sanitize is REFUSED (not 200)" ($sanitizeStatus -ne 200) `
        "sanitize returned $sanitizeStatus; unreadable encoding must not reach a verdict"

    $downloadStatus = $null
    try {
        $downloadStatus = (Invoke-WebRequest -Uri "$BaseUrl/api/documents/$($doc.id)/download" `
            -Headers $AuthHeaders -TimeoutSec 60 -UseBasicParsing).StatusCode
    } catch {
        $downloadStatus = [int]$_.Exception.Response.StatusCode.value__
    }
    Check "$Label - download is REFUSED (not 200)" ($downloadStatus -ne 200) `
        "download returned $downloadStatus; the egress gate must stay shut"
}

function Invoke-Case {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][string]$ContentType,
        # The minimum plausible size for THIS format. See the note below.
        [Parameter(Mandatory)][int]$MinBytes
    )

    Write-Host ''
    Write-Host "== $Label" -ForegroundColor Cyan

    # 1. The false-pass guard. A zero-byte fixture once made later assertions pass
    #    for the wrong reason, so the file is asserted on disk BEFORE the upload.
    #
    #    The threshold is per-format, and this DEVIATES from the plan's blanket
    #    `-gt 1000`. The failure mode being guarded is a broken path making
    #    ReadAllBytes hand an EMPTY payload to the uploader, so the real threshold
    #    is "not zero". 1000 is a sensible floor for a container format -- no
    #    `.docx`/`.xlsx`/`.pptx`/`.pdf` is ever legitimately under 1 KB -- but it
    #    is WRONG for `.txt`/`.md`, where a file carrying exactly the two
    #    identifiers is ~55 bytes. Applying 1000 there forces filler prose into the
    #    fixture, and the weaker "is it big enough" signal would replace the strong
    #    one the case already has: assertion 4 proves the identifiers were READ.
    if (-not $FixturePath -or -not (Test-Path $FixturePath)) {
        Check "$Label - fixture on disk is non-empty" $false "no fixture at '$FixturePath'"
    } else {
        $size = (Get-Item $FixturePath).Length
        Check "$Label - fixture on disk is non-empty" ($size -gt $MinBytes) `
            "fixture size=$size bytes (minimum for this format: $($MinBytes + 1))"
    }
    if (-not $FixturePath -or -not (Test-Path $FixturePath)) {
        foreach ($suffix in @('upload returns 2xx',
                              'extract 200 with incomplete=false',
                              'extracted text CONTAINS both identifiers',
                              'sanitize 200 verdict=pass redaction_count>=2',
                              'sanitized text is non-empty and carries NEITHER identifier')) {
            Check "$Label - $suffix" $false 'not reached - no fixture on disk'
        }
        return
    }

    # T4 carries the identifier in the HEADER and the phone in the FOOTER, so a
    # passing extract assertion proves the reader went beyond word/document.xml.
    # Stated in the output because an operator reading a red gate needs to know
    # which failure is the safety one, and this assertion is why the gate exists.
    if ($Label -match 'T4') {
        Write-Host '     (identifier is in the HEADER, phone in the FOOTER, and the body carries neither)' -ForegroundColor DarkGray
    }

    # 2. Upload. T5/T6 fail HERE today with "unsupported file type".
    $uploadStatus = $null
    $doc = $null
    $uploadDetail = ''
    try {
        $doc = Send-Upload -MatterId $script:matterId -FilePath $FixturePath `
            -Filename $Filename -ContentType $ContentType
        $uploadStatus = 200
    } catch {
        $err = Get-HttpError $_
        $uploadStatus = $err.status
        $uploadDetail = $err.body
        if (-not $uploadDetail) { $uploadDetail = $_.Exception.Message }
    }
    $uploadOk = ($uploadStatus -ge 200 -and $uploadStatus -lt 300) -and $doc -and $doc.id
    Check "$Label - upload returns 2xx" $uploadOk "status returned=$uploadStatus $uploadDetail"
    if (-not $uploadOk) {
        foreach ($suffix in @('extract 200 with incomplete=false',
                              'extracted text CONTAINS both identifiers',
                              'sanitize 200 verdict=pass redaction_count>=2',
                              'sanitized text is non-empty and carries NEITHER identifier')) {
            Check "$Label - $suffix" $false 'not reached - the upload was rejected'
        }
        return
    }
    $docId = $doc.id
    $script:createdDocs += $docId

    # 3. Extract.
    $extractStatus = $null
    $extract = $null
    $extractErr = ''
    try {
        $extract = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId/extract" -Method Post `
            -Headers $AuthHeaders -ContentType 'application/json' -Body '{}' -TimeoutSec 300
        $extractStatus = 200
    } catch {
        $err = Get-HttpError $_
        $extractStatus = $err.status
        $extractErr = $err.body
        if (-not $extractErr) { $extractErr = $_.Exception.Message }
    }
    $extractedText = if ($extract) { [string]$extract.text } else { '' }
    $extractChars = $extractedText.Length
    $incomplete = if ($extract) { "$($extract.incomplete)" } else { '(no body)' }
    Write-Host "     extract status=$extractStatus incomplete=$incomplete chars=$extractChars"
    Check "$Label - extract 200 with incomplete=false" `
        (($extractStatus -eq 200) -and ($incomplete -eq 'false')) `
        "status=$extractStatus incomplete=$incomplete chars=$extractChars $extractErr"

    # 4. The text is not merely non-empty -- it CONTAINS what the fixture wrote.
    #    An emptiness check passes on a document nobody read; a content check does
    #    not. This is the assertion that catches a converter skipping a part.
    $hasId = $extractedText.Contains($ID_CARD)
    $hasPhone = $extractedText.Contains($PHONE)
    Check "$Label - extracted text CONTAINS both identifiers" ($hasId -and $hasPhone) `
        "id_present=$hasId phone_present=$hasPhone chars=$extractChars"

    # 5. Sanitize.
    $sanStatus = $null
    $san = $null
    $sanErr = ''
    try {
        $san = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId/sanitize" -Method Post `
            -Headers $AuthHeaders -ContentType 'application/json' -Body '{"data_level":"T3"}' `
            -TimeoutSec 300
        $sanStatus = 200
    } catch {
        $err = Get-HttpError $_
        $sanStatus = $err.status
        $sanErr = $err.body
        if (-not $sanErr) { $sanErr = $_.Exception.Message }
    }
    $redactions = if ($san) { [int]$san.redaction_count } else { 0 }
    $verdict = if ($san) { "$($san.verdict)" } else { '(no body)' }
    Write-Host "     sanitize status=$sanStatus verdict=$verdict redactions=$redactions"
    Check "$Label - sanitize 200 verdict=pass redaction_count>=2" `
        (($sanStatus -eq 200) -and ($verdict -eq 'pass') -and ($redactions -ge 2)) `
        "status=$sanStatus verdict=$verdict redaction_count=$redactions $sanErr"

    # 6. Egress check -- and it must NOT be vacuous.
    #    `-not ''.Contains('x')` is TRUE, so a bare absence check passes when the
    #    sanitize call failed and produced no text at all. Require a successful
    #    sanitize AND non-empty output before the absence means anything.
    $sanText = if ($san) { [string]$san.sanitized_text } else { '' }
    $sanLen = $sanText.Length
    $leaksId = $sanText.Contains($ID_CARD)
    $leaksPhone = $sanText.Contains($PHONE)
    Check "$Label - sanitized text is non-empty and carries NEITHER identifier" `
        (($sanStatus -eq 200) -and ($sanLen -gt 0) -and (-not $leaksId) -and (-not $leaksPhone)) `
        "sanitized_chars=$sanLen id_present=$leaksId phone_present=$leaksPhone (a failed sanitize has no text, so absence alone proves nothing)"
}

# ── Build every fixture up front, then assert each one is real ───────────────
# Building all fixtures before any case runs means a broken builder surfaces as a
# fixture complaint, not as a mysterious product failure three cases later.
$fixtures = [ordered]@{
    T1 = @{ Path = Join-Path $fixtureDir 't1.txt';  Builder = { New-TextFixture  -OutPath $args[0] -Kind 'txt' } }
    T2 = @{ Path = Join-Path $fixtureDir 't2.md';   Builder = { New-TextFixture  -OutPath $args[0] -Kind 'md' } }
    T3 = @{ Path = Join-Path $fixtureDir 't3.docx'; Builder = { New-DocxFixture  -OutPath $args[0] -Kind 'body' } }
    T4 = @{ Path = Join-Path $fixtureDir 't4.docx'; Builder = { New-DocxFixture  -OutPath $args[0] -Kind 'header' } }
    T5 = @{ Path = Join-Path $fixtureDir 't5.xlsx'; Builder = { New-OoxmlFixture -OutPath $args[0] -Kind 'xlsx' } }
    T6 = @{ Path = Join-Path $fixtureDir 't6.pptx'; Builder = { New-OoxmlFixture -OutPath $args[0] -Kind 'pptx' } }
    T7 = @{ Path = Join-Path $fixtureDir 't7.html'; Builder = { New-HtmlFixture  -OutPath $args[0] } }
    T8 = @{ Path = Join-Path $fixtureDir 't8.docx'; Builder = { New-DocxFixture  -OutPath $args[0] -Kind 'carriers' } }
    T9 = @{ Path = Join-Path $fixtureDir 't9.txt';  Builder = { New-Utf16Fixture -OutPath $args[0] } }
    CONTROL = @{ Path = Join-Path $fixtureDir 'control.pdf'; Builder = { New-PdfFixture -OutPath $args[0] } }
}

Write-Host ''
Write-Host '-- building fixtures --' -ForegroundColor DarkCyan
$buildFailures = @()
foreach ($key in $fixtures.Keys) {
    $path = $fixtures[$key].Path
    $ok = $false
    try { $ok = & $fixtures[$key].Builder $path } catch { $ok = $false }
    if ($ok -and (Test-Path $path)) {
        Write-Host ("  {0,-8} {1} ({2} bytes)" -f $key, (Split-Path $path -Leaf), (Get-Item $path).Length)
    } else {
        Write-Host ("  {0,-8} BUILD FAILED" -f $key) -ForegroundColor Red
        $buildFailures += $key
    }
}
if ($buildFailures.Count -gt 0) {
    Die "fixture builder(s) failed: $($buildFailures -join ', ') - is ocr-service:local present?"
}

# ── Cases ──
$CT_TXT   = 'text/plain'
$CT_MD    = 'text/markdown'
$CT_DOCX  = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
$CT_XLSX  = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
$CT_PPTX  = 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
$CT_PDF   = 'application/pdf'
$CT_HTML  = 'text/html'

Invoke-Case -Label 'T1 plain text (.txt)'      -FixturePath $fixtures.T1.Path      -Filename 't1.txt'      -ContentType $CT_TXT    -MinBytes 8
Invoke-Case -Label 'T2 markdown (.md)'         -FixturePath $fixtures.T2.Path      -Filename 't2.md'       -ContentType $CT_MD     -MinBytes 8
Invoke-Case -Label 'T3 docx body (.docx)'      -FixturePath $fixtures.T3.Path      -Filename 't3.docx'     -ContentType $CT_DOCX   -MinBytes 1000
Invoke-Case -Label 'T4 docx HEADER ONLY (.docx)' -FixturePath $fixtures.T4.Path    -Filename 't4.docx'     -ContentType $CT_DOCX   -MinBytes 1000
Invoke-Case -Label 'T5 spreadsheet (.xlsx)'    -FixturePath $fixtures.T5.Path      -Filename 't5.xlsx'     -ContentType $CT_XLSX   -MinBytes 1000
Invoke-Case -Label 'T6 presentation (.pptx)'   -FixturePath $fixtures.T6.Path      -Filename 't6.pptx'     -ContentType $CT_PPTX   -MinBytes 1000
Invoke-Case -Label 'T7 html (.html)'           -FixturePath $fixtures.T7.Path      -Filename 't7.html'     -ContentType $CT_HTML   -MinBytes 8
Invoke-Case -Label 'T8 docx field codes + tracked deletion (.docx)' -FixturePath $fixtures.T8.Path -Filename 't8.docx' -ContentType $CT_DOCX -MinBytes 1000

# T9 is the one case whose correct outcome is a REFUSAL, not a redaction. A
# BOM-less UTF-16 .txt is valid UTF-8 (every byte < 0x80), so from_utf8 accepts it
# and returns NUL-interleaved text: the file holds the identifier byte-for-byte
# while the extracted string does not, as a contiguous substring. Expecting
# incomplete=true rather than pass/redact is the whole point.
Invoke-RefusalCase -Label 'T9 BOM-less UTF-16 text (.txt)' -FixturePath $fixtures.T9.Path -Filename 't9.txt' -ContentType $CT_TXT -MinBytes 8

Invoke-Case -Label 'CONTROL readable pdf (.pdf)' -FixturePath $fixtures.CONTROL.Path -Filename 'control.pdf' -ContentType $CT_PDF  -MinBytes 1000

# ── Cleanup ──
if (-not $KeepArtifacts) {
    foreach ($docId in $script:createdDocs) {
        try { Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId" -Method Delete -Headers $AuthHeaders -TimeoutSec 60 | Out-Null } catch { }
    }
    try { Invoke-RestMethod -Uri "$BaseUrl/api/matters/$($script:matterId)" -Method Delete -Headers $AuthHeaders -TimeoutSec 60 | Out-Null } catch { }
    Remove-Item -Recurse -Force $fixtureDir -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  cleanup done' -ForegroundColor DarkGray
}

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host "RESULT: $($script:checks) of $($script:checks) checks passed" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:failures) of $($script:checks) checks FAILED" -ForegroundColor Red
exit 1
