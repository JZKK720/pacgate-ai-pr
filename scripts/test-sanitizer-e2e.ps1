# Sanitizer E2E: upload -> extract -> sanitize -> verify -> gate -> restore.
# Mirrors scripts/test-ocr-extraction.ps1 conventions (PASS/FAIL lines).
# Boots fresh test containers; never touches the live pacgate-api/deer-flow.
# Usage: powershell -File scripts/test-sanitizer-e2e.ps1
#        powershell -File scripts/test-sanitizer-e2e.ps1 -ApiImage pacgate-api:local
param(
    # Override the API image. Defaults to the PUBLISHED image at the version in
    # pacgate-ai/Cargo.toml, so this script tracks the release instead of
    # depending on a tag somebody built locally once.
    [string]$ApiImage = ''
)
$ErrorActionPreference = 'Continue'
$script:fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Output "PASS: $name" } else { Write-Output "FAIL: $name"; $script:fail++ }
}

Write-Output "== building fixture =="
# PDF fixture via the ocr container's PIL. ocr-service is a perception lane:
# it rasterises PDFs and reads images, but a born-digital .txt is v2 (Docling)
# per design phasing - a txt would land on PaddleOCR and fail to parse.
$fixture = Join-Path $env:TEMP 'pacgate-san-e2e.pdf'
# Regenerate every run so a stale fixture never masks a regression.
if (Test-Path $fixture) { Remove-Item $fixture -Force }
docker run --rm -v "${env:TEMP}:/fix" --entrypoint python3 ocr-service:local -c "from PIL import Image, ImageDraw, ImageFont
img = Image.new('RGB',(900,300),'white')
d = ImageDraw.Draw(img)
font = ImageFont.load_default()
# Bare identifiers on separate lines. A label glued to digits ('ID1101...') has
# no word boundary before the digits, and the Tier-1 rules are deliberately
# boundary-anchored - a glued label reads as part of a longer token, which is
# the correct strictness for real documents. Standalone values are the
# boundary-safe rendering OCR preserves reliably.
d.text((16,100),'11010519491231002X',fill='black',font=font)
d.text((16,150),'13812345678',fill='black',font=font)
img.save('/fix/pacgate-san-e2e.pdf','PDF',resolution=100)" 2>&1 | Out-Null
Check "fixture written" (Test-Path $fixture)

# Cleanup helper. SPACE-separated names, NOT comma-joined.
#
# This was `docker rm -f pacgate-ocr-e2e, pacgate-api-e2e`, which does NOT remove
# both: PowerShell passes the commas through as part of the argument, docker
# treats `a,` as one (invalid) name and `b` as another, so only the LAST
# container is removed and the others are left running. Verified directly:
# `docker rm -f c1, c2` removed c2 and left c1. That is why a `pacgate-ocr-e2e`
# container kept surviving runs - the symptom was visible as a stray container,
# and the bug is that the cleanup silently did half its job.
function Remove-E2EContainers {
    foreach ($n in @('pacgate-ocr-e2e', 'pacgate-api-e2e')) {
        docker rm -f $n 2>&1 | Out-Null
    }
}
Remove-E2EContainers

# 1. OCR service (no host port needed; API reaches it over the compose net).
docker run -d --name pacgate-ocr-e2e --network client-bundle_default ocr-service:local | Out-Null
# 2. API under test, wired to the live db + ocr + embeddings + NER weights.
$repoRoot = Split-Path -Parent $PSScriptRoot
$nerDir = Join-Path $repoRoot '.e2e-ner-model'
$nerMount = if (Test-Path $nerDir) { @("-e", "PACGATE_NER_MODEL_DIR=/models/ner", "-v", "${nerDir}:/models/ner") } else { @() }
$nerMount = docker run --rm -v pacgate-ner-models:/ner alpine:3.20 sh -c 'ls /ner | head -1' 2>$null
if (-not $nerMount) { $nerMount = @() } else { $nerMount = @('-v', 'pacgate-ner-models:/ner') }
Write-Output "ner weights mounted: $($nerMount.Count -gt 0)"

# The API image. This used to be the locally-built `pacgate-api:plan020-test`,
# which NOTHING builds - so the script could only ever run on the one checkout
# where that tag had been hand-made, and on any other machine it died at
# `docker run` with "pull access denied" and then reported eleven cascading
# FAILs that looked like sanitizer defects. It is not in `run-all-checks.ps1`,
# which is why the rot went unnoticed.
#
# Now derived from pacgate-ai/Cargo.toml (the same source
# preflight-release-tag.ps1 and smoke-full-stack.ps1 use), so it tracks the
# release and pulls the PUBLISHED image. Override with -ApiImage for a local build.
$ApiImage = if ($ApiImage) { $ApiImage } else {
    $toml = Join-Path $repoRoot 'pacgate-ai/Cargo.toml'
    $ver = if (Test-Path $toml) {
        (Select-String -Path $toml -Pattern '^version\s*=\s*"([0-9.]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
    } else { '' }
    if (-not $ver) { Write-Output 'SKIP: cannot derive the version from pacgate-ai/Cargo.toml'; exit 2 }
    "ghcr.io/jzkk720/pacgate-api:$ver"
}
Write-Output "api image: $ApiImage"

# The DB password. The script runs against the LIVE pacgate-db on the compose
# network, whose password comes from PACGATE_DB_PASSWORD in the bundle .env -
# install.ps1 (and the handbook) tell operators to REPLACE the
# change-me-to-a-strong-password placeholder, and the pilot machine did. With
# the old hardcoded literal, the e2e API container died on DB connection and
# reported 11 cascading FAILs that looked like sanitizer defects (verified
# 2026-10-05: same container + the .env password -> /health ok immediately).
# Read the real value from .env; fall back to the placeholder for machines
# that still run the stock default.
$DbPassword = 'change-me-to-a-strong-password'
$bundleEnv = Join-Path $repoRoot 'deploy\client-bundle\.env'
if (Test-Path $bundleEnv) {
    foreach ($line in (Get-Content $bundleEnv -ErrorAction SilentlyContinue)) {
        if ($line -match '^PACGATE_DB_PASSWORD=(.+)$') { $DbPassword = $Matches[1].Trim() }
    }
}

docker run -d --name pacgate-api-e2e --network client-bundle_default `
  -p 127.0.0.1:8097:8080 `
  -e "DATABASE_URL=postgres://pacgate:${DbPassword}@pacgate-db:5432/pacgate" `
  -e "DATA_DIR=/data/tenants" `
  -e "OCR_SERVICE_URL=http://pacgate-ocr-e2e:8100" `
  -e "OLLAMA_BASE_URL=http://host.docker.internal:11434" `
  @nerMount `
  -v "$(Join-Path $repoRoot 'deploy\client-bundle\data'):/data" `
  $ApiImage | Out-Null
Start-Sleep -Seconds 6
$health = Invoke-RestMethod -Uri "http://127.0.0.1:8097/health" -TimeoutSec 5
Check "api boots" ($health -eq 'ok')

# 3. Seed + login + matter.
cmd /c "docker exec pacgate-api-e2e pacgate-seed --db-url postgres://pacgate:${DbPassword}@pacgate-db:5432/pacgate 2>&1" | Out-Null
# The seed creates the seed account as a TENANT admin only (users.role=admin)
# but leaves the PLATFORM role (users.system_role) at 'user' - verified by
# decoding the seed JWT (claims: role=admin, system_role=user). The admin
# provisioning route this script now relies on (POST /api/auth/users) checks
# system_role, so without this step the provision call returns 403 and the
# restore-refusal assertion silently degrades to a missing-auth refusal.
# Idempotent: escalate the seed identity to platform admin before login.
cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -c `"UPDATE users SET system_role='admin' WHERE email='seed@pacgate.local'`"" 2>&1 | Out-Null
$login = Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/auth/login" -Method Post -Body '{"email":"seed@pacgate.local","password":"seed-password-123"}' -ContentType "application/json"
$hdr = @{ Authorization = "Bearer $($login.token)" }
$matter = Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/matters" -Method Post -Headers $hdr -Body '{"name":"Sanitizer E2E","description":"plan 020 proof"}' -ContentType "application/json"
Check "matter created" ($null -ne $matter.id)

# 4. Provision a non-admin user for the restore-refusal assertion.
#
# This used to POST /api/auth/register (open registration). Since 0.1.22 the
# register route is first-user-only (DEFECT-pacgate-api-open-registration.md):
# it refuses once any user exists, and seed@ already does. Registration is now
# refused and the REMEDY ships with the gate: POST /api/auth/users lets a
# verified admin create the account (commit ebac082). Creating the attorney
# through that route keeps the restore-refusal assertion honest - the refusal
# must be ROLE-based, not merely missing-auth.
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/auth/users" -Method Post -Headers $hdr -Body '{"email":"attorney-e2e@pacgate.local","password":"attorney-pass-123","role":"attorney"}' -ContentType "application/json" | Out-Null
} catch { Write-Output "  attorney provision note: $($_.Exception.Message)" }
$attorneyLogin = $null
try {
    $attorneyLogin = Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/auth/login" -Method Post -Body '{"email":"attorney-e2e@pacgate.local","password":"attorney-pass-123"}' -ContentType "application/json"
} catch { }
Check "attorney user usable" ($null -ne $attorneyLogin)

# 5. Upload the PDF carrying the identifiers.
$fileBytes = [System.IO.File]::ReadAllBytes($fixture)
$ms = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($ms)
$boundary = "----psb$([System.Guid]::NewGuid().ToString('N'))"
$bw.Write([System.Text.Encoding]::ASCII.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"matter_id`"`r`n`r`n$($matter.id)`r`n--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"case.pdf`"`r`nContent-Type: application/pdf`r`n`r`n"))
$bw.Write($fileBytes); $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary--`r`n")); $bw.Flush()
$up = Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/documents" -Method Post -Headers $hdr -ContentType "multipart/form-data; boundary=$boundary" -Body $ms.ToArray()
Check "upload ok" ($null -ne $up.id)
$docId = $up.id

# 6. Extract (cache-warm step for the sanitize job).
$ex = Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/documents/$docId/extract" -Method Post -Headers $hdr -ContentType "application/json" -Body '{}'
Check "extract returned text" ($ex.text.Length -gt 0)

# 7. Sanitize (the plan-020 route).
$job = Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/documents/$docId/sanitize" -Method Post -Headers $hdr -ContentType "application/json" -Body '{"data_level":"T3"}'
Check "sanitize verdict pass" ($job.verdict -eq 'pass')
Check "id card redacted" (-not $job.sanitized_text.Contains('11010519491231002X'))
Check "phone gone" (-not $job.sanitized_text.Contains('13812345678'))
Check "mapping sealed server-side" ($job.mapping_count -ge 2)
Write-Output "  sanitized: $($job.sanitized_text)"
Write-Output "  verdict=$($job.verdict) redactions=$($job.redaction_count) promoted=$($job.chunks_promoted)"

# 8. Status + gate behaviour.
$status = Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/documents/$docId/sanitize-status" -Headers $hdr
Check "document state sanitized" ($status.document_state -eq 'sanitized')
Check "chunks sanitized" (($status.chunk_states -join ',').Trim() -eq 'sanitized')

# 9. Download gate: BEFORE sanitize the doc was pending; now sanitized, so
#    download must be ALLOWED. Refusal path is asserted by the status above.
$dl = Invoke-WebRequest -Uri "http://127.0.0.1:8097/api/documents/$docId/download" -Headers $hdr -UseBasicParsing
Check "download allowed post-sanitize" ($dl.StatusCode -eq 200)

# 10. Restore: role gate. Attorney token must be refused.
$restoreBody = @{ job_id = $job.job_id; text = $job.sanitized_text } | ConvertTo-Json -Compress
$attHdr = @{ Authorization = "Bearer $($attorneyLogin.token)" }
$refused = $false
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/documents/$docId/restore" -Method Post -Headers $attHdr -ContentType "application/json" -Body $restoreBody | Out-Null
} catch {
    $refused = $true
}
Check "restore refused for attorney role" $refused

# 11. Admin path: seed is admin, restore must succeed.
$adminRestored = $false
try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:8097/api/documents/$docId/restore" -Method Post -Headers $hdr -ContentType "application/json" -Body $restoreBody
    $adminRestored = $r.restored.Contains('11010519491231002X')
} catch {
    Write-Output "  admin restore error: $($_.Exception.Message)"
}
Check "admin restore returns originals" $adminRestored

# 12. DB evidence rows exist.
$dbLedger = cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c ""SELECT count(*) FROM redaction_ledger_rows WHERE document_id = '$docId'"" 2>&1"
Check "ledger row written" ([int]($dbLedger | Select-Object -First 1) -ge 1)
$dbAudit = cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c ""SELECT count(*) FROM audit_log WHERE action = 'document.sanitize'"" 2>&1"
Check "audit row written" ([int]($dbAudit | Select-Object -First 1) -ge 1)

# Cleanup on BOTH paths. The final line here used to be the only cleanup, so any
# early exit - a failed assertion, an exception, or Ctrl-C - left the containers
# running. Reuses the same helper as the pre-clean, so a fix to one applies to
# both.
Remove-E2EContainers
if ($script:fail -eq 0) { Write-Output '== RESULT: PASS ==' } else { Write-Output "== RESULT: FAIL ($($script:fail)) =="; exit 1 }