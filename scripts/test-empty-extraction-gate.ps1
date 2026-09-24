# PROVES an extraction that read nothing cannot pass the sanitization gate.
#
# WHY THIS EXISTS
#
# A blank page reported `incomplete=False`, so sanitize ran on empty text, got a
# pass verdict, marked the document 'sanitized', and the download gate opened.
# A document nobody could read was released.
#
# Three assertions, and the CONTROL is as important as the other two: a fix that
# marks EVERYTHING incomplete would pass A1/A2 while breaking the product, so the
# control must stay green throughout.
#
#   A1  a blank page          -> extract incomplete=true  -> sanitize REFUSED
#   A2  text on p1 + blank p2 -> extract incomplete=true  -> sanitize REFUSED
#   CONTROL  normal text page -> extract incomplete=false -> sanitize PASSES
#
# Exit: 0 = all pass, 1 = a real failure, 2 = cannot check (stack unreachable).

[CmdletBinding()]
param(
    [string]$BaseUrl = '',
    [string]$EnvFile = '',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repo 'deploy/client-bundle/.env' }

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

Write-Host '=== empty-extraction gate ===' -ForegroundColor Cyan

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

$email = $null; $password = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^PACGATE_API_EMAIL=(.+)$')    { $email    = $Matches[1].Trim() }
    if ($line -match '^PACGATE_API_PASSWORD=(.+)$') { $password = $Matches[1].Trim() }
}
if (-not $email -or -not $password) { Die 'PACGATE_API_EMAIL / PACGATE_API_PASSWORD missing from .env' }

# ── Reachability: /version is at the nginx ROOT, not under /pacgate ──
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

# ── Fixture builder: runs inside the ocr-service image, which has PIL ──
# Only 'blank' and 'control' come from here. The partial case needs page 1 to
# carry text and page 2 to be blank, so it has its own builder below - an earlier
# draft tried to fold it in here and produced two blank pages, which would have
# made A2 assert the wrong thing.
function New-FixturePdf {
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$Kind   # blank | control
    )
    if ($Kind -ne 'blank' -and $Kind -ne 'control') {
        throw "New-FixturePdf: unsupported Kind '$Kind' (use blank or control)"
    }
    $dir = Split-Path $OutPath -Parent
    $leaf = Split-Path $OutPath -Leaf
    # `-c` with a PowerShell here-string, matching the two existing fixture
    # builders in this repo (test-legal-journey.ps1:161, test-sanitizer-e2e.ps1:18).
    # An earlier draft piped the script to `python3 -` over stdin; NO gate in this
    # repo uses that form, so it was replaced with the pattern proven on this box.
    docker run --rm -v "${dir}:/fix" --entrypoint python3 ocr-service:local -c @"
from PIL import Image, ImageDraw, ImageFont
W, H = 1400, 500
try:
    font = ImageFont.truetype('DejaVuSans-Bold.ttf', 56)
except OSError:
    font = ImageFont.load_default()

if '$Kind' == 'blank':
    Image.new('RGB', (W, H), 'white').save('/fix/$leaf', 'PDF', resolution=150)
else:
    img = Image.new('RGB', (W, H), 'white')
    d = ImageDraw.Draw(img)
    d.text((40, 150), '11010519491231002X', fill='black', font=font)
    d.text((40, 280), '13812345678', fill='black', font=font)
    img.save('/fix/$leaf', 'PDF', resolution=150)
"@ 2>&1 | Out-Null
    return (Test-Path $OutPath)
}

function New-PartialFixturePdf {
    param([Parameter(Mandatory)][string]$OutPath)
    $dir = Split-Path $OutPath -Parent
    $leaf = Split-Path $OutPath -Leaf
    $pyScript = @"
from PIL import Image, ImageDraw, ImageFont
W, H = 1400, 500
try:
    font = ImageFont.truetype('DejaVuSans-Bold.ttf', 56)
except OSError:
    font = ImageFont.load_default()
p1 = Image.new('RGB', (W, H), 'white')
d = ImageDraw.Draw(p1)
d.text((40, 150), '11010519491231002X', fill='black', font=font)
p2 = Image.new('RGB', (W, H), 'white')
p1.save('/fix/$leaf', 'PDF', resolution=150, save_all=True, append_images=[p2])
"@
    docker run --rm -v "${dir}:/fix" --entrypoint python3 ocr-service:local -c $pyScript 2>&1 | Out-Null
    return (Test-Path $OutPath)
}

# ── Upload helper ──
function Send-Upload {
    param([string]$MatterId, [string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $boundary = "----emptygate$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $prefix = "--$boundary`r`nContent-Disposition: form-data; name=`"matter_id`"`r`n`r`n$MatterId`r`n" +
              "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"case.pdf`"`r`n" +
              "Content-Type: application/pdf`r`n`r`n"
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
    -Body (@{ name = "emptygate-$([guid]::NewGuid().ToString('N').Substring(0,8))";
               description = 'empty-extraction gate' } | ConvertTo-Json -Compress)
$matterId = $matter.id
if (-not $matterId) { Die 'matter create returned no id' }
Write-Host "  matter=$matterId"
$script:createdDocs = @()

$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "emptygate-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

function Invoke-Case {
    param([string]$Label, [string]$FilePath, [string]$ExpectIncomplete)
    Write-Host ''
    Write-Host "== $Label" -ForegroundColor Cyan

    $doc = Send-Upload -MatterId $matterId -FilePath $FilePath
    if (-not $doc.id) { Check "$Label - upload" $false 'upload returned no id'; return }
    $script:createdDocs += $doc.id

    $extract = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$($doc.id)/extract" -Method Post `
        -Headers $AuthHeaders -ContentType 'application/json' -Body '{}' -TimeoutSec 300
    Write-Host "     extract incomplete=$($extract.incomplete) chars=$(($extract.text | Measure-Object -Character).Characters)"
    Check "$Label - extract reports incomplete=$ExpectIncomplete" `
        ("$($extract.incomplete)" -eq $ExpectIncomplete) `
        "got incomplete=$($extract.incomplete), expected $ExpectIncomplete"

    $sanitizeStatus = $null
    try {
        $sanitizeStatus = (Invoke-WebRequest -Uri "$BaseUrl/api/documents/$($doc.id)/sanitize" -Method Post `
            -Headers $AuthHeaders -ContentType 'application/json' -Body '{"data_level":"T3"}' `
            -TimeoutSec 300 -UseBasicParsing).StatusCode
    } catch {
        $sanitizeStatus = [int]$_.Exception.Response.StatusCode.value__
    }

    $downloadStatus = $null
    try {
        $downloadStatus = (Invoke-WebRequest -Uri "$BaseUrl/api/documents/$($doc.id)/download" `
            -Headers $AuthHeaders -TimeoutSec 60 -UseBasicParsing).StatusCode
    } catch {
        $downloadStatus = [int]$_.Exception.Response.StatusCode.value__
    }

    if ($ExpectIncomplete -eq 'true') {
        Check "$Label - sanitize is REFUSED (not 200)" ($sanitizeStatus -ne 200) `
            "sanitize returned $sanitizeStatus; an unread document must not be sanitized"
        Check "$Label - download is REFUSED (not 200)" ($downloadStatus -ne 200) `
            "download returned $downloadStatus; the egress gate must stay shut"
    } else {
        Check "$Label - sanitize PASSES (200)" ($sanitizeStatus -eq 200) `
            "sanitize returned $sanitizeStatus; a readable document must still sanitize"
        Check "$Label - download ALLOWED (200)" ($downloadStatus -eq 200) `
            "download returned $downloadStatus; the egress gate must open"
    }
}

function Invoke-CacheCase {
    <#
      Proves the extraction CACHE can represent an incomplete extraction.

      A partial read is recorded on the first /extract call. The second call takes
      the cache branch. If that branch returns a hardcoded `incomplete: false`,
      the cached answer contradicts the live one - and because
      pacgate_ocr_batch exists to PRE-WARM this cache, a sanitize that runs later
      would inherit "complete" for a document that was only half read.
    #>
    param([string]$Label, [string]$FilePath)

    Write-Host ''
    Write-Host "== $Label" -ForegroundColor Cyan

    $doc = Send-Upload -MatterId $matterId -FilePath $FilePath
    if (-not $doc.id) { Check "$Label - upload" $false 'upload returned no id'; return }
    $script:createdDocs += $doc.id

    $first = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$($doc.id)/extract" -Method Post `
        -Headers $AuthHeaders -ContentType 'application/json' -Body '{}' -TimeoutSec 300
    Check "$Label - first extract incomplete=true" ("$($first.incomplete)" -eq 'true') `
        "got incomplete=$($first.incomplete)"

    $second = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$($doc.id)/extract" -Method Post `
        -Headers $AuthHeaders -ContentType 'application/json' -Body '{}' -TimeoutSec 300
    Write-Host "     cached read: incomplete=$($second.incomplete) chars=$(($second.text | Measure-Object -Character).Characters)"
    Check "$Label - CACHED extract still reports incomplete=true" `
        ("$($second.incomplete)" -eq 'true') `
        "the cache branch reported incomplete=$($second.incomplete); the stored completeness was lost"
}

# A1 - blank page. THE assertion this plan exists for.
$blankPdf = Join-Path $fixtureDir 'blank.pdf'
if (-not (New-FixturePdf -OutPath $blankPdf -Kind 'blank')) {
    Die 'could not build the blank fixture (is ocr-service:local present?)'
}
Invoke-Case -Label 'A1 blank page' -FilePath $blankPdf -ExpectIncomplete 'true'

# A2 - text on page 1, blank page 2. A half-read document must not be complete.
$partialPdf = Join-Path $fixtureDir 'partial.pdf'
if (-not (New-PartialFixturePdf -OutPath $partialPdf)) {
    Die 'could not build the partial fixture'
}
Invoke-Case -Label 'A2 partial read' -FilePath $partialPdf -ExpectIncomplete 'true'

# A2-cache - the SAME partial document read twice. The cache must not upgrade a
# partial extraction to complete.
Invoke-CacheCase -Label 'A2c cached partial read' -FilePath $partialPdf

# CONTROL - a normal readable page must still sanitize. This is what stops a
# lazy fix (mark everything incomplete) from looking green.
$controlPdf = Join-Path $fixtureDir 'control.pdf'
if (-not (New-FixturePdf -OutPath $controlPdf -Kind 'control')) {
    Die 'could not build the control fixture'
}
Invoke-Case -Label 'CONTROL readable page' -FilePath $controlPdf -ExpectIncomplete 'false'

# ── Cleanup ──
if (-not $KeepArtifacts) {
    foreach ($docId in $script:createdDocs) {
        try { Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId" -Method Delete -Headers $AuthHeaders -TimeoutSec 60 | Out-Null } catch { }
    }
    try { Invoke-RestMethod -Uri "$BaseUrl/api/matters/$matterId" -Method Delete -Headers $AuthHeaders -TimeoutSec 60 | Out-Null } catch { }
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
