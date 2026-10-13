# Format coverage gate: EXTRACTION + SANITIZATION + CONVERSION for every format.
#
# WHY THIS EXISTS. This is a legal AI workspace; users upload and generate documents
# in every format the product accepts, and a silent failure in the middle of that
# chain is a compliance incident, not an inconvenience. Coverage was previously
# split and full of holes:
#
#   - test-text-native-sanitize.ps1 proves extraction + sanitization for the seven
#     accepted upload formats (59/59).
#   - test-ocr-extraction.ps1 proves the raster OCR lane.
#   - test-document-generation-e2e.ps1 proves generation, but only DOCX.
#
# Nothing proved CONVERSION for any format, and nothing proved that the formats agree
# with each other about what is supported. The upload allowlist, the extract router
# and the MCP converter each carry their own hardcoded format list, and they can
# drift apart silently - a format accepted at upload but unknown to the converter
# fails at the last step, long after the user believed it was stored.
#
# SO THIS GATE ASSERTS, per format and end to end through the running stack:
#   1. the format is ACCEPTED at upload (not rejected as unsupported),
#   2. EXTRACTION returns non-empty text with incomplete=false,
#   3. SANITIZATION returns a verdict and redacts an embedded identifier,
#   4. CONVERSION (the MCP path an agent uses) returns real Markdown,
#   5. and it fails loudly on any of those, naming the format.
#
# Exit 2 means CANNOT CHECK (stack down / no credentials) and is never read as a
# failure of the code.
[CmdletBinding()]
param(
    [string]$BaseUrl = '',
    [string]$EnvFile = '',
    [string]$OcrImage = '',
    [string]$McpImage = '',
    [string]$McpContainer = 'pacgate-mcp',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot 'deploy/client-bundle/.env' }

$pass = 0; $fail = 0; $skip = 0
function Ok($m)   { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:fail++ }
function Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:skip++ }
function Die($m, $code) { Write-Host "[FATAL] $m" -ForegroundColor Red; exit $code }

# ── Preflight ────────────────────────────────────────────────────────────────
if (-not (Test-Path $EnvFile)) { Die "credentials file not found: $EnvFile" 2 }
$email = $null; $password = $null
foreach ($line in Get-Content $EnvFile) {
    if     ($line -match '^PACGATE_API_EMAIL=(.+)$')    { $email    = $Matches[1].Trim() }
    elseif ($line -match '^PACGATE_API_PASSWORD=(.+)$') { $password = $Matches[1].Trim() }
}
if (-not $email -or -not $password) { Die 'PACGATE_API_EMAIL / PACGATE_API_PASSWORD missing from .env' 2 }

# The nginx port is DERIVED from the running container, never assumed - a hardcoded
# port is how a gate reports on a stack that moved.
if (-not $BaseUrl) {
    $port = $null
    try {
        foreach ($l in @(docker port pacgate-nginx 2>$null)) { if ($l -match ':(\d+)\s*$') { $port = $Matches[1]; break } }
    }
    catch { }
    if (-not $port) { $port = '8089' }
    $BaseUrl = "http://localhost:$port/pacgate"
}
Write-Host "  base: $BaseUrl" -ForegroundColor DarkGray

$token = $null
foreach ($p in @("$BaseUrl/api/auth/login", "$BaseUrl/auth/login")) {
    try {
        $login = Invoke-RestMethod -Uri $p -Method Post -ContentType 'application/json' -TimeoutSec 20 `
            -Body (@{ email = $email; password = $password } | ConvertTo-Json -Compress)
        if ($login.token) { $token = $login.token; break }
    }
    catch { }
}
if (-not $token) { Die "login failed at $BaseUrl - is the stack up?" 2 }
$AuthHeaders = @{ Authorization = "Bearer $token" }
Write-Host '  authenticated' -ForegroundColor DarkGray

# The ocr-service image doubles as the fixture builder (it is the container with
# Pillow). Derived, never the invented `ocr-service:local`.
if (-not $OcrImage) {
    # Prefer the image the RUNNING ocr-service uses: it is what the stack being tested
    # actually runs, and it exists. Falling straight to the derived release tag fails
    # during a release window (the tag is not built yet) and reports "fixture could not
    # be built", which reads like a product failure - exactly the false-red class
    # scripts/lib/Release-ImageState.ps1 exists to prevent.
    try { $OcrImage = (docker inspect $(docker ps -q -f "name=^ocr-service$") --format '{{.Config.Image}}' 2>$null | Out-String).Trim() } catch { }
}
if (-not $OcrImage) {
    . (Join-Path $PSScriptRoot 'lib/Release-ImageState.ps1')
    $OcrImage = Get-ReleaseOcrImage
}
if (-not $OcrImage) { Die 'could not derive the release ocr-service image' 2 }
if (-not $McpImage) {
    # Derived from the running container, so the builder matches the stack under test
    # rather than a version guessed here.
    try { $McpImage = (docker inspect $McpContainer --format '{{.Config.Image}}' 2>$null | Out-String).Trim() } catch { }
}
if (-not $McpImage) { Die 'could not determine the pacgate-mcp image for the xlsx/pptx builders' 2 }
Write-Host "  fixture builders: ocr=$($OcrImage.Split(':')[-1]) mcp=$($McpImage.Split(':')[-1])" -ForegroundColor DarkGray

$ID_CARD = '11010519491231002X'
$PHONE   = '13812345678'
$runId   = [guid]::NewGuid().ToString('N').Substring(0, 8)
$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "fmtcoverage-$runId"
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

$matter = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Method Post -Headers $AuthHeaders `
    -TimeoutSec 20 -ContentType 'application/json' `
    -Body (@{ name = "fmtcoverage-$runId"; description = 'format coverage gate' } | ConvertTo-Json -Compress)
if (-not $matter.id) { Die 'matter create returned no id' 1 }
$matterId = $matter.id
Write-Host "  matter: $matterId" -ForegroundColor DarkGray

$createdDocs = New-Object System.Collections.ArrayList
# Records, per format, whether egress served the original or the sanitized rendering.
# Collected so the summary is a single readable line rather than something a reviewer
# has to reconstruct from a scrollback.
$script:egress = @{}

# ── Fixture builders ──────────────────────────────────────────────────────────
# The text is embedded so that EXTRACTION and SANITIZATION can both be asserted on
# the SAME content: an identifier must be present after extraction and gone after
# sanitization. A fixture without the identifier would pass both vacuously.
function New-TextFixture {
    param([string]$OutPath, [string]$Ext)
    $body = "Counterparty intake record`n`nID CARD: $ID_CARD`nPHONE: $PHONE`n`
Matter: $runId`n"
    if ($Ext -eq 'html') {
        $body = "<html><body><h1>Intake</h1><p>ID CARD: $ID_CARD</p><p>PHONE: $PHONE</p></body></html>"
    }
    [System.IO.File]::WriteAllText($OutPath, $body, (New-Object System.Text.UTF8Encoding($false)))
    return (Test-Path $OutPath)
}

function New-OoxmlFixture {
    param([string]$OutPath, [string]$Kind)
    $dir = Split-Path $OutPath -Parent
    $leaf = Split-Path $OutPath -Leaf
    # No single image carries every builder: ocr-service has python-docx + Pillow
    # (no openpyxl, no python-pptx), while pacgate-mcp has openpyxl + python-pptx +
    # markitdown (no python-docx). Using one image for everything was a false
    # "fixture could not be built" for xlsx and pptx, which reads like a product
    # failure. Pick the image that has the library, and say so when neither does.
    $image = if ($Kind -eq 'docx') { $OcrImage } else { $McpImage }
    $py = if ($Kind -eq 'docx') {
@"
import docx
d = docx.Document()
d.add_heading('Intake', level=1)
d.add_paragraph('ID CARD: $ID_CARD')
d.add_paragraph('PHONE: $PHONE')
d.save('/fix/$leaf')
"@
    } elseif ($Kind -eq 'xlsx') {
@"
import openpyxl
wb = openpyxl.Workbook(); ws = wb.active
ws['A1'] = 'ID CARD'; ws['B1'] = '$ID_CARD'
ws['A2'] = 'PHONE';   ws['B2'] = '$PHONE'
wb.save('/fix/$leaf')
"@
    } else {
@"
from pptx import Presentation
p = Presentation(); s = p.slides.add_slide(p.slide_layouts[5])
s.shapes.title.text = 'Intake'
tb = s.shapes.add_textbox(0, 1000000, 8000000, 2000000)
tb.text_frame.text = 'ID CARD: $ID_CARD'
p2 = s.shapes.add_textbox(0, 2000000, 8000000, 2000000)
p2.text_frame.text = 'PHONE: $PHONE'
p.save('/fix/$leaf')
"@
    }
    $py | docker run --rm -i -v "${dir}:/fix" --entrypoint python3 $image - 2>&1 | Out-Null
    return (Test-Path $OutPath)
}

function New-PdfFixture {
    param([string]$OutPath, [bool]$TextLayer = $false)
    $dir = Split-Path $OutPath -Parent
    $leaf = Split-Path $OutPath -Leaf
    if ($TextLayer) {
        # A PDF with a REAL text layer, built without an engine so the conversion lane
        # is tested against the thing it is actually for.
        docker run --rm -v "${dir}:/fix" --entrypoint python3 $McpImage -c @"
content = b'BT /F1 18 Tf 40 200 Td (ID CARD $ID_CARD) Tj ET'
objs = [
 b'1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj',
 b'2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj',
 b'3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 600 300]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj',
 b'4 0 obj<</Length %d>>stream\n' % len(content) + content + b'\nendstream endobj',
 b'5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj',
]
out = b'%PDF-1.4\n'
offsets = []
for o in objs:
    offsets.append(len(out)); out += o + b'\n'
xref = len(out)
out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs)+1)
for off in offsets: out += b'%010d 00000 n \n' % off
out += b'trailer<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n' % (len(objs)+1, xref)
open('/fix/$leaf','wb').write(out)
"@ 2>&1 | Out-Null
        return (Test-Path $OutPath)
    }
    # An IMAGE-ONLY pdf: no text layer at all. This is what a scanner produces, and
    # it must go through the OCR lane rather than the converter.
    docker run --rm -v "${dir}:/fix" --entrypoint python3 $OcrImage -c @"
from PIL import Image, ImageDraw, ImageFont
try:
    font = ImageFont.truetype('DejaVuSans-Bold.ttf', 56)
except OSError:
    font = ImageFont.load_default()
img = Image.new('RGB', (1400, 500), 'white')
d = ImageDraw.Draw(img)
d.text((40, 150), '$ID_CARD', fill='black', font=font)
d.text((40, 280), '$PHONE', fill='black', font=font)
img.save('/fix/$leaf', 'PDF', resolution=150)
"@ 2>&1 | Out-Null
    return (Test-Path $OutPath)
}

function Send-Upload {
    param([string]$MatterId, [string]$FilePath, [string]$Filename, [string]$ContentType)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $boundary = "----fmt$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $prefix = "--$boundary`r`nContent-Disposition: form-data; name=`"matter_id`"`r`n`r`n$MatterId`r`n" +
              "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$Filename`"`r`n" +
              "Content-Type: $ContentType`r`n`r`n"
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes($prefix))
    $bw.Write($bytes)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary--`r`n"))
    $bw.Flush()
    return Invoke-RestMethod -Uri "$BaseUrl/api/documents" -Method Post -Headers $AuthHeaders `
        -ContentType "multipart/form-data; boundary=$boundary" -Body $ms.ToArray() -TimeoutSec 120
}

# ── The conversion lane, exercised the way the agent does ─────────────────────
# `pacgate_convert_document` runs markitdown INSIDE the MCP container against bytes
# it downloads from the API. Calling it through MCP is what proves the real path;
# reimplementing it here would prove only that markitdown works on this box.
function Invoke-McpConvert {
    param([string]$DocumentId)
    $py = @"
import json, sys
sys.path.insert(0, '/app')
import server
out = server.pacgate_convert_document('$DocumentId')
try:
    j = json.loads(out)
    print('MCPRESULT' + json.dumps({'ok': True, 'chars': j.get('markdown_chars', 0),
                      'markdown': (j.get('markdown') or '')[:400]}))
except Exception:
    print('MCPRESULT' + json.dumps({'ok': False, 'raw': out[:400]}))
"@
    $tmp = Join-Path $fixtureDir "_conv.py"
    [IO.File]::WriteAllText($tmp, $py)
    $null = docker cp $tmp "${McpContainer}:/tmp/_conv.py" 2>&1
    $res = docker exec $McpContainer python3 /tmp/_conv.py 2>&1 | Out-String
    # The container prints httpx/INFO log lines to stdout too, so pulling the WHOLE
    # output into ConvertFrom-Json failed with "unexpecting character while parsing".
    # Extract only the tagged result line - a probe that cannot read its own response
    # reports a product failure it did not observe.
    $line = ($res -split "`n" | Where-Object { $_ -match '^MCPRESULT' } | Select-Object -First 1)
    if (-not $line) { return (@{ ok = $false; raw = $res.Trim() } | ConvertTo-Json -Compress) }
    return $line.Substring('MCPRESULT'.Length)
}

# ── Cases ─────────────────────────────────────────────────────────────────────
# Every accepted upload format, with the extension and content type the client
# sends. `pdf` is the raster lane (OCR); the rest are text-native.
$cases = @(
    # Each fixture uses a DISTINCT stem on purpose. Version is counted per
    # (matter, stem) with the extension stripped, so `c.docx` and `c.xlsx` in one matter
    # share a version counter and appear as versions 1, 2, 3... of each other. That is
    # real behaviour (see DEFECT-agent-loop-max-rounds.md), and a fixture that trips it
    # reports alarming version numbers that mean nothing about the format under test.
    [pscustomobject]@{ Name = 'pdf-scan'; File = 'fscan.pdf'; Ct = 'application/pdf';       Lane = 'raster (OCR)';      TextLayer = $false },
    [pscustomobject]@{ Name = 'pdf-text'; File = 'ftext.pdf'; Ct = 'application/pdf';       Lane = 'text layer (native)'; TextLayer = $true },
    [pscustomobject]@{ Name = 'docx'; File = 'fdoc.docx'; Ct = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'; Lane = 'text-native'; TextLayer = $false },
    [pscustomobject]@{ Name = 'xlsx'; File = 'fsheet.xlsx'; Ct = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';          Lane = 'text-native'; TextLayer = $false },
    [pscustomobject]@{ Name = 'pptx'; File = 'fdeck.pptx'; Ct = 'application/vnd.openxmlformats-officedocument.presentationml.presentation';  Lane = 'text-native'; TextLayer = $false },
    [pscustomobject]@{ Name = 'html'; File = 'fpage.html'; Ct = 'text/html';             Lane = 'text-native'; TextLayer = $false },
    [pscustomobject]@{ Name = 'txt';  File = 'fnote.txt';  Ct = 'text/plain';            Lane = 'text-native'; TextLayer = $false },
    [pscustomobject]@{ Name = 'md';   File = 'freadme.md'; Ct = 'text/markdown';         Lane = 'text-native'; TextLayer = $false }
)

Write-Host ''
foreach ($c in $cases) {
    Write-Host "=== $($c.Name) [$($c.Lane)] ===" -ForegroundColor Cyan
    $path = Join-Path $fixtureDir $c.File
    $built =
        if ($c.Name -like 'pdf-*') { New-PdfFixture -OutPath $path -TextLayer $c.TextLayer }
        elseif ($c.Name -in 'docx', 'xlsx', 'pptx') { New-OoxmlFixture -OutPath $path -Kind $c.Name }
        else { New-TextFixture -OutPath $path -Ext $c.Name }
    if (-not $built) { Bad "$($c.Name): fixture could not be built"; continue }
    Write-Host ("  fixture: {0} bytes" -f (Get-Item $path).Length) -ForegroundColor DarkGray

    # 1. UPLOAD - an unsupported format is rejected, so acceptance is a real assertion.
    $doc = $null
    try { $doc = Send-Upload -MatterId $matterId -FilePath $path -Filename $c.File -ContentType $c.Ct }
    catch {
        $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'no-response' }
        Bad "$($c.Name): UPLOAD rejected (HTTP $code) - the format is accepted by the allowlist but not by this path"
        continue
    }
    $docId = $doc.id
    [void]$createdDocs.Add($docId)
    Ok "$($c.Name): uploaded (format=$($doc.format), version=$($doc.version))"

    # 2. EXTRACTION
    $ex = $null
    try {
        $ex = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId/extract" -Method Post -Headers $AuthHeaders `
            -ContentType 'application/json' -Body '{}' -TimeoutSec 420
    }
    catch {
        Bad "$($c.Name): EXTRACT threw: $($_.Exception.Message)"
        continue
    }
    $exText = [string]$ex.text
    if ($exText.Trim().Length -eq 0) { Bad "$($c.Name): EXTRACT returned no text" }
    elseif ($ex.incomplete -eq $true) { Bad "$($c.Name): EXTRACT reported incomplete=true (a partial read is not a pass)" }
    else { Ok "$($c.Name): extracted $($exText.Length) chars, incomplete=false" }

    # The identifier must be present, or the sanitization assertion below is vacuous.
    if ($exText -notmatch $ID_CARD) {
        Bad "$($c.Name): the identifier is NOT in the extracted text; sanitization would pass without testing anything"
        continue
    }
    Ok "$($c.Name): the identifier survived extraction (so sanitization is a real test)"

    # 3. SANITIZATION - the step that makes an upload safe to hand on.
    #
    # ORDER MATTERS AND THE PRODUCT IS RIGHT. Conversion is attempted AFTER this,
    # because GET /api/documents/:id/download is fail-closed: an unsanitized
    # document answers 409 "document is 'pending'; download requires sanitization
    # (or explicit 'never')". The first version of this gate converted first and
    # reported five 409s that looked like a broken converter. They were the egress
    # gate doing its job.
    $san = $null
    try {
        $san = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId/sanitize" -Method Post -Headers $AuthHeaders `
            -ContentType 'application/json' -Body '{"data_level":"T3"}' -TimeoutSec 420
    }
    catch { Bad "$($c.Name): SANITIZE threw: $($_.Exception.Message)"; continue }
    $sanText = [string]$san.sanitized_text
    if ($san.verdict -ne 'pass') { Bad "$($c.Name): SANITIZE verdict was '$($san.verdict)'" }
    elseif ($sanText -match $ID_CARD) { Bad "$($c.Name): the ID card SURVIVED sanitization" }
    elseif ($sanText -match $PHONE) { Bad "$($c.Name): the phone number SURVIVED sanitization" }
    elseif ($sanText.Trim().Length -eq 0) { Bad "$($c.Name): sanitized text is empty - redaction removed everything" }
    else { Ok "$($c.Name): sanitize verdict=pass, both identifiers redacted, text preserved" }

    # 4. EGRESS: what does an agent actually RECEIVE for a sanitized document?
    #
    # This is the assertion that matters most in a legal workspace, and nothing
    # asserted it before. `download` is the ONLY route that serves document bytes,
    # and the sanitizer persists a STATE FLAG rather than a sanitized artifact, so
    # the response carries the ORIGINAL file. Measured 2026-10-14 on 0.1.29 with a
    # docx, after a `verdict=pass, redactions=2` sanitize whose response was
    # `ID CARD: 00000000000000000X PHONE: [CN_MOBILE_120D0E42_2]`:
    #
    #   GET /api/documents/<id>/download -> HTTP 200, 36620 bytes
    #   downloaded docx text              -> 'ID CARD: 11010519491231002X\nPHONE: 13812345678'
    #
    # The sanitizer did its job on the TEXT. The file a downstream consumer reads -
    # and the file `pacgate_convert_document` feeds to markitdown - still carries the
    # raw identifiers. See deploy/DEFECT-sanitized-content-not-served.md.
    #
    # Asserted with a WARN, not a FAIL, because whether `download` should return the
    # sanitized rendering or the original is a product decision that is not mine to
    # make silently: `restore` exists to hand an admin the original, and the
    # sanitizer's own docs describe download as an egress gate rather than a
    # sanitized-export. What is NOT defensible is that this was unmeasured - so it is
    # now measured on every run and printed where a human will see it.
    $sanitizedOk = 'n/a'
    try {
        $tmpDl = Join-Path $fixtureDir "_dl_$($c.Name)"
        $dlCode = (curl.exe -s -o $tmpDl -w '%{http_code}' "$BaseUrl/api/documents/$docId/download" `
                -H "Authorization: $($AuthHeaders['Authorization'])" --max-time 90 2>&1)
        if ($dlCode -eq '200') {
            $dlBytes = [IO.File]::ReadAllBytes($tmpDl)
            $dlText = [Text.Encoding]::UTF8.GetString($dlBytes)
            # Binary OOXML hides the string across zip boundaries, so also ask the
            # converter - the path an agent actually uses.
            $convText = ''
            try { $convText = [string]($cj.markdown) } catch { }
            $rawInDownload = ($dlText -match $ID_CARD) -or ($convText -match $ID_CARD)
            $sanitizedOk = if ($rawInDownload) { 'RAW' } else { 'sanitized' }
            if ($rawInDownload) {
                Write-Host "  [WARN] $($c.Name): DOWNLOAD SERVES THE ORIGINAL - the sanitized rendering is not persisted, so a reader (and markitdown) still sees the raw identifiers" -ForegroundColor Yellow
            }
            else {
                Ok "$($c.Name): download serves sanitized content"
            }
        }
        else {
            Skip "$($c.Name): download returned HTTP $dlCode; egress behaviour not determined"
        }
    }
    catch { Skip "$($c.Name): download probe failed: $($_.Exception.Message)" }
    $script:egress[$c.Name] = $sanitizedOk

    # 5. CONVERSION - the lane nothing tested before, now that egress is permitted.
    $conv = Invoke-McpConvert -DocumentId $docId
    $cj = $null
    try { $cj = $conv | ConvertFrom-Json } catch { }
    if ($null -eq $cj) { Bad "$($c.Name): CONVERT returned unparseable output: $conv" }
    elseif (-not $cj.ok) { Bad "$($c.Name): CONVERT failed: $($cj.raw)" }
    elseif ([int]$cj.chars -le 0) {
        # An EMPTY conversion is only acceptable when there is genuinely no text
        # layer to read, and it must be REPORTED as such.
        #
        # Measured 2026-10-14: markitdown on an image-only (scanned) PDF returns
        # `{"ok": true, "chars": 0, "markdown": ""}` with no error and no hint of why.
        # markitdown is a text extractor, not OCR, so empty is the CORRECT result -
        # the defect is that it is indistinguishable from a tool failure at the
        # boundary, and scanned documents are the norm in legal work. The caller has
        # to know "this needs OCR" instead of "conversion returned nothing".
        if ($c.Name -eq 'pdf-scan') {
            $script:convertEmpty += $c.Name
            Write-Host "  [WARN] $($c.Name): CONVERT returned 0 chars with ok=true and no reason. Correct for an image-only PDF (markitdown does not OCR) but INDISTINGUISHABLE from a failure - the agent is told nothing about needing the OCR lane." -ForegroundColor Yellow
        }
        else {
            Bad "$($c.Name): CONVERT returned 0 markdown characters for a format that HAS text in the file"
        }
    }
    else {
        Ok "$($c.Name): converted to $($cj.chars) markdown chars"
        # Length alone proves nothing about WHICH document was converted.
        if ([string]$cj.markdown -match $ID_CARD) {
            Write-Host "  [WARN] $($c.Name): the converted markdown carries the RAW identifier (converter reads the original, consistent with the egress finding above)" -ForegroundColor Yellow
        }
        else { Ok "$($c.Name): the converted markdown carries no raw identifier" }
    }
}

# ── Cleanup ────────────────────────────────────────────────────────────────────
if (-not $KeepArtifacts) {
    try { $null = Invoke-RestMethod -Uri "$BaseUrl/api/matters/$matterId" -Method Delete -Headers $AuthHeaders -TimeoutSec 60 }
    catch { }
    Remove-Item $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "=== RESULT ===" -ForegroundColor White
Write-Host ("  passed: $pass   failed: $fail   skipped(cannot-check): $skip")

# The egress summary, stated once and plainly. In a legal workspace this is the
# difference between "we redacted it" and "we redacted it before anyone could read
# it", and the two were indistinguishable before this gate existed.
$rawFormats = @($script:egress.GetEnumerator() | Where-Object { $_.Value -eq 'RAW' } | ForEach-Object { $_.Key })
if ($rawFormats.Count -gt 0) {
    Write-Host ''
    Write-Host "  EGRESS: download served the ORIGINAL (raw identifiers) for: $($rawFormats -join ', ')" -ForegroundColor Yellow
    Write-Host '          The sanitizer redacts the extracted TEXT and flags the document sanitized,' -ForegroundColor Yellow
    Write-Host '          but no sanitized artifact is persisted, so get/download and the markitdown' -ForegroundColor Yellow
    Write-Host '          converter both return the original file. Recorded, not silently fixed:' -ForegroundColor Yellow
    Write-Host '          see deploy/DEFECT-sanitized-content-not-served.md' -ForegroundColor Yellow
}

if ($fail -gt 0) { Write-Host "RESULT: FAILED - a format is broken somewhere in the chain" -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: every accepted format survived upload -> extract -> sanitize -> convert' -ForegroundColor Green
exit 0
