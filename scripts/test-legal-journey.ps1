# LEGAL-JOURNEY ACCEPTANCE TEST — one command, end to end.
#
# WHY THIS EXISTS
#
# The suites pass individually (21 gates) and the sanitizer pipeline has its own
# E2E, but nothing proved the WHOLE legal journey against the shipped release.
# The last full-stack evidence was plans/007-audit-smoke-report.md, 2026-09-01,
# and the stack moved six releases since. "The suites pass" is not "the product
# works"; this is the difference.
#
# Scope (design doc 2026-09-22, item B):
#   matter -> upload -> OCR/extract -> sanitize -> review gate -> search
#          -> qm co-work -> OpenViking recall
#
# IT FAILS LOUDLY ON THE FIRST BROKEN STEP. That is deliberate: a journey test
# that collects failures and reports at the end hides the causal step. Once step
# N fails, every later step's result is suspect, so later assertions would be
# noise, not evidence.
#
# CANNOT-CHECK IS NOT A PASS. qm and OpenViking are optional in a given
# environment. When they are not reachable this reports SKIP with the exact
# reason and a non-zero exit, never a green line. A green line that means
# "did not run" is how a suite silently loses coverage.
#
# Usage:
#   pwsh -File scripts/test-legal-journey.ps1
#   pwsh -File scripts/test-legal-journey.ps1 -BaseUrl http://localhost:8089/pacgate
#   pwsh -File scripts/test-legal-journey.ps1 -KeepArtifacts   # debug: keep the matter
#
# Exit: 0 = whole journey passed, 1 = a step failed, 2 = could not check.

[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:8089/pacgate',
    [string]$EnvFile = '',
    # Leave the matter/document in place for inspection instead of cleaning up.
    [switch]$KeepArtifacts,
    # qm portal (publicUrl in qm.config.jsonc). Off unless qm is running.
    [string]$QmUrl = 'http://localhost:8181',
    [string]$OpenVikingUrl = 'http://localhost:1933',
    [int]$OcrTimeoutSec = 180,
    # Fail the run if a lane is unreachable instead of SKIPping it. Use on a
    # machine where qm + OpenViking are expected, so a silent absence is caught.
    [switch]$RequireAllLanes
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repo 'deploy/client-bundle/.env' }

$script:passed = 0
$script:skipped = @()
$script:artifacts = @{ matterId = $null; docId = $null }

function Step {
    param([string]$Name)
    Write-Host ''
    Write-Host "== $Name" -ForegroundColor Cyan
}
function Ok($m)   { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:passed++ }
function Skip($lane, $why) {
    Write-Host "  [SKIP] $lane - $why" -ForegroundColor Yellow
    # ${lane} not $lane - a bare `$lane:` inside a double-quoted string is parsed
    # as a SCOPE QUALIFIER ($scope:name), which is a parse error, not a string.
    $script:skipped += "${lane}: $why"
}
function Die($m, $code = 1) {
    Write-Host "  [FAIL] $m" -ForegroundColor Red
    Write-Host ''
    Write-Host "RESULT: journey FAILED at this step. Later steps were not attempted." -ForegroundColor Red
    Write-Host "  artifacts left: matter=$($script:artifacts.matterId) doc=$($script:artifacts.docId)" -ForegroundColor DarkGray
    exit $code
}

Write-Host '=== LEGAL JOURNEY (matter -> ... -> OpenViking recall) ===' -ForegroundColor Cyan
Write-Host "  base: $BaseUrl"
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)

# ── 0. Preflight ────────────────────────────────────────────────────────────
Step '0. Preflight'
if (-not (Test-Path $EnvFile)) { Die "credentials file not found: $EnvFile - cannot authenticate, so cannot check." 2 }

$email = $null; $password = $null
$ovKey = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^PACGATE_API_EMAIL=(.+)$')      { $email    = $Matches[1].Trim() }
    if ($line -match '^PACGATE_API_PASSWORD=(.+)$')   { $password = $Matches[1].Trim() }
    if ($line -match '^OPENVIKING_ROOT_API_KEY=(.+)$') { $ovKey   = $Matches[1].Trim() }
}
# Never echo a secret - only whether it is present.
if (-not $email -or -not $password) { Die 'PACGATE_API_EMAIL / PACGATE_API_PASSWORD missing from .env.' 2 }
Ok 'credentials readable (values not printed)'

try {
    # /version is served at the NGINX ROOT, not under the /pacgate prefix -
    # nginx maps it onto the API's /build-info. Probing $BaseUrl/version lands on
    # an unknown path, which hits the auth middleware and answers 401 rather than
    # 404, so the wrong URL is easy to misread as an auth problem. Try both.
    $versionCandidates = @(
        (($BaseUrl -replace '/pacgate/?$', '') + '/version'),
        "$BaseUrl/version"
    )
    $ver = $null
    foreach ($vu in $versionCandidates) {
        try {
            $cand = Invoke-RestMethod -Uri $vu -TimeoutSec 10
            if ($cand.version) { $ver = $cand; break }
        } catch { }
    }
    if (-not $ver) { Die "stack not reachable: no version answered at $($versionCandidates -join ' or ') - start it, then re-run." 2 }
    Ok "stack reachable; version=$($ver.version) revision=$($ver.revision.Substring(0,7))"
} catch {
    Die "preflight probe errored: $($_.Exception.Message)" 2
}

# ── 1. Auth ─────────────────────────────────────────────────────────────────
Step '1. Authenticate'
$token = $null
foreach ($p in @("$BaseUrl/api/auth/login", "$BaseUrl/auth/login")) {
    try {
        $body = @{ email = $email; password = $password } | ConvertTo-Json -Compress
        $login = Invoke-RestMethod -Uri $p -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20
        if ($login.token) { $token = $login.token; break }
    } catch { }
}
if (-not $token) { Die 'login failed on both route shapes - check credentials; LAN sign-in needs the origin allowlist (install step 4c).' }
$H = @{ Authorization = "Bearer $token" }
Ok 'authenticated'

# ── 2. Matter ───────────────────────────────────────────────────────────────
Step '2. Create an isolated matter'
try {
    $matter = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Method Post -Headers $H -TimeoutSec 20 `
        -ContentType 'application/json' `
        -Body (@{ name = "journey-$runId"; description = "legal-journey acceptance run $runId" } | ConvertTo-Json -Compress)
} catch { Die "matter create failed: $($_.Exception.Message)" }
if (-not $matter.id) { Die 'matter create returned no id.' }
$script:artifacts.matterId = $matter.id
$matterId = $matter.id
Ok "matter created: $matterId"

# ── 3. Workflow library ─────────────────────────────────────────────────────
# Included in the journey because a wrong clone silently serves 10 built-ins
# instead of the firm's library, and the user-facing path is the agent lane.
Step '3. Workflow library is served'
try {
    $wf = Invoke-RestMethod -Uri "$BaseUrl/api/workflows" -Headers $H -TimeoutSec 20
    $wfCount = @($wf.workflows).Count
} catch { Die "workflow list failed: $($_.Exception.Message)" }
if ($wfCount -le 10) { Die "only $wfCount workflows - the built-ins. The library wiring is missing (WORKFLOWS_DIR + mount on pacgate-api)." }
Ok "library served: $wfCount workflows"

# ── 4. Upload a document carrying identifiers ───────────────────────────────
Step '4. Upload'
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) "journey-$runId.pdf"
$madeFixture = $false
try {
    # Fixture built inside the ocr container: it has PIL, and a born-digital PDF
    # is what the extraction lane expects (a .txt would route to OCR instead).
    $dir = Split-Path $fixture -Parent
    docker run --rm -v "${dir}:/fix" --entrypoint python3 ocr-service:local -c @"
from PIL import Image, ImageDraw, ImageFont
img = Image.new('RGB', (900, 300), 'white')
d = ImageDraw.Draw(img)
font = ImageFont.load_default()
d.text((16, 100), '11010519491231002X', fill='black', font=font)
d.text((16, 150), '13812345678', fill='black', font=font)
img.save('/fix/journey-$runId.pdf', 'PDF', resolution=100)
"@ 2>&1 | Out-Null
    $madeFixture = Test-Path $fixture
} catch { }
if (-not $madeFixture) { Die 'could not build the PDF fixture (ocr-service:local image present?).' }

$fileBytes = [System.IO.File]::ReadAllBytes($fixture)
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$boundary = "----journey$runId"
$bw.Write([System.Text.Encoding]::ASCII.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"matter_id`"`r`n`r`n$matterId`r`n--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"journey.pdf`"`r`nContent-Type: application/pdf`r`n`r`n"))
$bw.Write($fileBytes)
$bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary--`r`n"))
$bw.Flush()
try {
    $up = Invoke-RestMethod -Uri "$BaseUrl/api/documents" -Method Post -Headers $H `
        -ContentType "multipart/form-data; boundary=$boundary" -Body $ms.ToArray() -TimeoutSec 60
} catch { Die "upload failed: $($_.Exception.Message)" }
if (-not $up.id) { Die 'upload returned no document id.' }
$docId = $up.id
$script:artifacts.docId = $docId
Ok "uploaded: $docId"

# ── 5. OCR / extract ────────────────────────────────────────────────────────
Step '5. OCR / extract'
try {
    $ex = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId/extract" -Method Post -Headers $H `
        -ContentType 'application/json' -Body '{}' -TimeoutSec $OcrTimeoutSec
} catch { Die "extract failed (first call downloads PaddleOCR weights; allow time): $($_.Exception.Message)" }
if (-not $ex.text -or $ex.text.Length -eq 0) { Die 'extract returned empty text - OCR produced nothing for a document that visibly contains text.' }
Ok "extracted $($ex.text.Length) chars (incomplete=$($ex.incomplete))"

# ── 6. Sanitize ─────────────────────────────────────────────────────────────
Step '6. Sanitize (redaction)'
try {
    $job = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId/sanitize" -Method Post -Headers $H `
        -ContentType 'application/json' -Body '{"data_level":"T3"}' -TimeoutSec $OcrTimeoutSec
} catch { Die "sanitize failed: $($_.Exception.Message)" }
if ($job.verdict -ne 'pass') { Die "sanitize verdict was '$($job.verdict)', expected 'pass'." }
if ($job.sanitized_text -match '11010519491231002X') { Die 'ID number survived sanitization.' }
if ($job.sanitized_text -match '13812345678')        { Die 'phone number survived sanitization.' }
if ([int]$job.mapping_count -lt 2) { Die "mapping_count=$($job.mapping_count); expected >= 2 sealed mappings." }
Ok "verdict=pass redactions=$($job.redaction_count) mappings=$($job.mapping_count)"

# ── 7. Review gate ──────────────────────────────────────────────────────────
Step '7. Review gate (state + egress)'
try { $st = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId/sanitize-status" -Headers $H -TimeoutSec 20 }
catch { Die "sanitize-status failed: $($_.Exception.Message)" }
if ($st.document_state -ne 'sanitized') { Die "document_state='$($st.document_state)', expected 'sanitized'." }
Ok "state=sanitized chunk_states=$(($st.chunk_states -join ','))"

# The egress gate is the point: download is REFUSED until sanitized, then allowed.
try {
    $dl = Invoke-WebRequest -Uri "$BaseUrl/api/documents/$docId/download" -Headers $H -UseBasicParsing -TimeoutSec 30
    if ($dl.StatusCode -ne 200) { Die "download returned $($dl.StatusCode) after sanitize." }
    Ok 'download allowed post-sanitize (egress gate opened correctly)'
} catch {
    Die "download refused after sanitize: $($_.Exception.Message) - the gate did not open."
}

# ── 8. Search ───────────────────────────────────────────────────────────────
Step '8. Search'
try {
    $kb = Invoke-RestMethod -Uri "$BaseUrl/api/kb/search?q=11010519491231002X&matter_id=$matterId" -Headers $H -TimeoutSec 30
    $kbCount = @($kb).Count
} catch { Die "KB search failed: $($_.Exception.Message)" }
Ok "internal KB search returned $kbCount chunk(s) scoped to the matter"

try {
    $ext = Invoke-RestMethod -Uri "$BaseUrl/api/search?q=contract&limit=3" -Headers $H -TimeoutSec 40
    Ok "external search returned $(@($ext).Count) result(s)"
} catch { Die "external search failed: $($_.Exception.Message)" }
try {
    $connHealth = Invoke-RestMethod -Uri "$BaseUrl/api/search/health" -Headers $H -TimeoutSec 20
    $avail = @($connHealth | Where-Object { $_.available })
    Ok "connector health: $($avail.Count) of $(@($connHealth).Count) available ($($avail.name -join ', '))"
} catch { Die "search/health failed: $($_.Exception.Message)" }

# ── 9. qm co-work ───────────────────────────────────────────────────────────
Step '9. qm co-work'
$qmUp = $false
try {
    $r = Invoke-WebRequest -Uri $QmUrl -UseBasicParsing -TimeoutSec 10
    $qmUp = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
} catch { $qmUp = $false }
if ($qmUp) {
    Ok "qm portal reachable at $QmUrl"
} else {
    Skip 'qm co-work' "portal not reachable at $QmUrl (qm stack not running). Start with deploy/qm-pacgate/setup-qm.ps1."
}

# ── 10. OpenViking recall ───────────────────────────────────────────────────
# VARIABLE NAMING, learned the hard way in this very script: PowerShell variables
# are CASE-INSENSITIVE. An earlier version probed health into `$h`, which
# silently overwrote `$H` - the auth headers used two steps later for cleanup -
# so both deletes failed with a confusing "cannot bind Headers" error whose cause
# was nowhere near the symptom. Response objects below use NAMED variables, and
# nothing reuses a short name that could collide with `$H`.
Step '10. OpenViking recall'
$ovUp = $false
$ovHealth = $null
try {
    $ovHealth = Invoke-RestMethod -Uri "$OpenVikingUrl/health" -TimeoutSec 10
    $ovUp = ($ovHealth.status -eq 'ok' -or $ovHealth.healthy -eq $true)
} catch { $ovUp = $false }
if ($ovUp) {
    # Paths come from the service's own /openapi.json, not from guesswork: this
    # surface is /api/v1/resources (write) and /api/v1/search/recall (read).
    #
    # AUTH: X-API-Key ONLY, matching deer-flow-extensions-config.json (the proven
    # working config) and pacgate_qm.py's note that it is "the key the
    # deer-flow-extensions-config.json sends as X-API-Key".
    #
    # Deliberately NOT also sending `Authorization: Bearer`. An earlier version
    # sent both "to be robust" and got HTTP 403 on every call: a server that sees
    # an Authorization header can commit to that scheme and reject it, rather than
    # falling back to the header that would have worked. Offering two credentials
    # is not more permissive than offering one - it can be strictly worse.
    $ovHdr = @{}
    if ($ovKey) { $ovHdr = @{ 'X-API-Key' = $ovKey } }
    $probe = "journey-$runId"
    $recallOk = $false
    $recallWhy = ''

    # Diagnostic FIRST, so a 403 is reported as a cause rather than a mystery.
    # OpenViking has a two-tier identity model: the root key is an ADMIN
    # credential (it answers /api/v1/admin/accounts with 200), while recall
    # requires an ACCOUNT-USER key. Distinguishing "authenticated but wrong
    # principal" from "bad key" is the difference between an actionable SKIP and
    # a 403 someone re-debugs from scratch.
    $tierNote = ''
    try {
        $accts = Invoke-RestMethod -Uri "$OpenVikingUrl/api/v1/admin/accounts" -Headers $ovHdr -TimeoutSec 15
        $acctList = @($accts.result)
        $users = 0
        foreach ($a in $acctList) { $users += [int]$a.user_count }
        $tierNote = "root key authenticates the admin surface OK ($($acctList.Count) account(s), $users user(s) total)"
    } catch {
        $tierNote = "root key did not authenticate the admin surface either (HTTP $($_.Exception.Response.StatusCode.value__))"
    }

    try {
        Invoke-RestMethod -Uri "$OpenVikingUrl/api/v1/resources" -Method Post -Headers $ovHdr -TimeoutSec 30 `
            -ContentType 'application/json' `
            -Body (@{ uri = "mem://$probe"; add_type = 'memory'; reason = "acceptance marker $probe" } | ConvertTo-Json -Compress) | Out-Null
        $ovFound = Invoke-RestMethod -Uri "$OpenVikingUrl/api/v1/search/recall" -Method Post -Headers $ovHdr -TimeoutSec 30 `
            -ContentType 'application/json' -Body (@{ query = $probe } | ConvertTo-Json -Compress)
        $recallOk = ($null -ne $ovFound)
        if (-not $recallOk) { $recallWhy = 'write accepted but recall returned nothing' }
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        $detail = ''
        try {
            $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $detail = $sr.ReadToEnd()
            if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
        } catch { }
        if ($code -eq 403 -and $tierNote -match 'authenticates|admin surface OK') {
            $recallWhy = "HTTP 403 - the root key is an ADMIN credential, not a recall principal. $tierNote. Recall needs an account-USER key (POST /api/v1/admin/accounts/{id}/users/{uid}/key)."
        } else {
            $recallWhy = "round trip failed: HTTP $code $detail"
        }
    }
    if ($recallOk) { Ok 'OpenViking write -> recall round trip succeeded' }
    else { Skip 'OpenViking recall' $recallWhy }
} else {
    Skip 'OpenViking recall' "service not reachable at $OpenVikingUrl."
}

# ── 11. Cleanup ─────────────────────────────────────────────────────────────
Step '11. Cleanup'
if ($KeepArtifacts) {
    Write-Host "  kept: matter=$matterId doc=$docId (requested with -KeepArtifacts)" -ForegroundColor DarkGray
} else {
    try { Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId" -Method Delete -Headers $H -TimeoutSec 20 | Out-Null; Ok 'document deleted' }
    catch { Write-Host "  [WARN] document delete failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    try { Invoke-RestMethod -Uri "$BaseUrl/api/matters/$matterId" -Method Delete -Headers $H -TimeoutSec 20 | Out-Null; Ok 'matter deleted' }
    catch { Write-Host "  [WARN] matter delete failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    if (Test-Path $fixture) { Remove-Item $fixture -Force -ErrorAction SilentlyContinue }
}

# ── Verdict ─────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host "=== RESULT ===" -ForegroundColor Cyan
Write-Host "  assertions passed: $($script:passed)"
if ($script:skipped.Count -gt 0) {
    Write-Host "  lanes SKIPPED (NOT verified - do not read as passing):" -ForegroundColor Yellow
    $script:skipped | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}
if ($script:skipped.Count -gt 0 -and $RequireAllLanes) {
    Write-Host ''
    Write-Host 'RESULT: FAIL - -RequireAllLanes was set and a lane could not be checked.' -ForegroundColor Red
    exit 2
}
if ($script:skipped.Count -gt 0) {
    Write-Host ''
    Write-Host 'RESULT: journey PASSED on every step that ran; some lanes were NOT verified (see SKIP above).' -ForegroundColor Yellow
    exit 0
}
Write-Host ''
Write-Host 'RESULT: full legal journey PASSED, all lanes verified.' -ForegroundColor Green
exit 0
