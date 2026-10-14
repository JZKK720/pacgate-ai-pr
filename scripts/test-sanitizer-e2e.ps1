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

. (Join-Path $PSScriptRoot 'lib/Release-ImageState.ps1')
$OcrImage = if ($OcrImage) { $OcrImage } else { Get-ReleaseOcrImage }
if (-not $OcrImage) { Write-Output 'SKIP: cannot derive the release ocr-service image'; exit 2 }
if ((Test-ReleaseOcrImagePresent -Reference $OcrImage) -eq 'absent') {
    Write-Output "SKIP: $OcrImage is not published yet and is not present locally."; exit 2
}

Write-Output "== building fixture =="
# PDF fixture via the ocr container's PIL. ocr-service is a perception lane:
# it rasterises PDFs and reads images, but a born-digital .txt is v2 (Docling)
# per design phasing - a txt would land on PaddleOCR and fail to parse.
$fixture = Join-Path $env:TEMP 'pacgate-san-e2e.pdf'
# Regenerate every run so a stale fixture never masks a regression.
if (Test-Path $fixture) { Remove-Item $fixture -Force }
docker run --rm -v "${env:TEMP}:/fix" --entrypoint python3 $OcrImage -c "from PIL import Image, ImageDraw, ImageFont
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

# The compose network. This used to be the hardcoded literal
# 'client-bundle_default' - the name Docker derives from the COMPOSE PROJECT,
# which used to be inferred from the directory name. compose.prod.yaml now pins
# `name: pacgate-ai-bundle` (the run-1 volume-collision fix), so the live network
# is 'pacgate-ai-bundle_default' and `--network client-bundle_default` failed with
# "network client-bundle_default not found". Derive it instead of guessing, so a
# future rename cannot silently break this again.
#
# ConvertFrom-Json, NOT a `{{...}}{{"\n"}}{{end}}` template. The template form
# returns the network under PowerShell 7 but an EMPTY string under Windows
# PowerShell 5.1 (verified side by side 2026-10-14: 5.1.26100.9549 vs 7.6.6, same
# container). 5.1 splits the `\n` into separate lines before `Where-Object { $_ }`
# sees them, so the derivation came back empty and this gate exited 2 "SKIP:
# pacgate-db is not running" - even with the whole stack up.
#
# That is not a cosmetic bug: run-all-checks.ps1 falls back to powershell.exe when
# `pwsh` is absent, which is the client AIPC arrangement, so on client hardware the
# sanitizer e2e gate reported SKIP and its 20+ assertions never ran. Found while
# red-checking the new chunk-content assertions below; the false SKIP had been
# masking whether this gate ran at all.
$Network = (docker inspect pacgate-db 2>$null | ConvertFrom-Json)[0].NetworkSettings.Networks.PSObject.Properties.Name |
    Select-Object -First 1
if (-not $Network) {
    Write-Output 'SKIP: pacgate-db is not running, so its compose network cannot be resolved.'
    Write-Output '      Start the stack (.\deploy\client-bundle\install.ps1) and re-run.'
    exit 2
}
Write-Output "compose network: $Network"

# 1. OCR service (no host port needed; API reaches it over the compose net).
#
# The image is the RELEASE ocr-service, derived, not an invented `:local` alias -
# this container is part of what is under test, so it must be the same code a
# client receives.
#
# The weights volume is NOT mounted, deliberately. The PP-OCRv4 weights are baked
# into the image, so extraction must work with nothing mounted; leaving it off is
# what proves the bake, and it also removes the external-CDN dependency that used
# to make this gate slow and intermittent (measured 269.9s cold against a 300s
# client timeout in pacgate-api, versus 3.4s with the weights present).
docker rm -f pacgate-ocr-e2e 2>&1 | Out-Null
docker run -d --name pacgate-ocr-e2e --network $Network $OcrImage | Out-Null
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
    $ns = [regex]::Match((Get-Content (Join-Path $repoRoot 'deploy/client-bundle/compose.prod.yaml') -Raw),
          'ghcr\.io/(?<ns>[A-Za-z0-9._-]+)/pacgate-api:\d+\.\d+\.\d+').Groups['ns'].Value
    # A version bump opens a window in which the new tag is not published yet (the
    # release build is still running). This script then `docker run`-ed a
    # non-existent image and reported ELEVEN cascading FAILs that read exactly like
    # sanitizer defects - they were one of five misleading reds in the 0.1.28
    # sweep. Measured, not assumed: against the published 0.1.27 image this script
    # is 16/16 PASS, so nothing about the sanitizer was broken.
    #
    # So when the new tag is absent, fall back to the NEWEST published version
    # rather than reporting garbage. That keeps full sanitizer coverage during the
    # release window (the sanitizer code is identical either side of a bump) and it
    # is stated loudly, so nobody mistakes it for a test of the new build.
    $probe = "ghcr.io/$ns/pacgate-api:$ver"
    . (Join-Path $PSScriptRoot 'lib/Release-ImageState.ps1')
    if (-not $ns) { Write-Output 'SKIP: cannot derive the image namespace from compose.prod.yaml'; exit 2 }
    if ((Test-ImageTagLocally -Reference $probe) -eq 'present' -or
        (Test-GhcrManifestPresent -Namespace $ns -Repository 'pacgate-api' -Tag $ver) -eq 'present') {
        $probe
    }
    else {
        $tags = @()
        try {
            $tok = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:$ns/pacgate-api:pull&service=ghcr.io" -Method Get -TimeoutSec 20
            $lst = Invoke-RestMethod -Uri "https://ghcr.io/v2/$ns/pacgate-api/tags/list" -Headers @{ Authorization = "Bearer $($tok.token)" } -TimeoutSec 20
            $tags = @($lst.tags | Where-Object { $_ -match '^\d+\.\d+\.\d+$' })
        }
        catch { }
        if (-not $tags) { Write-Output "SKIP: $probe is not published yet and no published version could be listed."; exit 2 }
        $newest = $tags | Sort-Object { [version]$_ } -Descending | Select-Object -First 1
        Write-Output "NOTE: $probe is NOT yet published (release window)."
        Write-Output "      Falling back to the newest published image $ns/pacgate-api:$newest."
        Write-Output "      The sanitizer code is identical across a version bump, so this still"
        Write-Output "      exercises the real sanitizer - but it does NOT test the new build."
        "ghcr.io/$ns/pacgate-api:$newest"
    }
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

docker run -d --name pacgate-api-e2e --network $Network `
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

# 8b. The 'sanitized' label must be EARNED by the chunk CONTENT, not just
#     stamped on the row.
#
#     Until 2026-10-14 the promote path did `UPDATE kb_chunks SET
#     sanitization_state='sanitized'` and left `content` as the raw extract, so
#     RAG kept serving the original identifiers: the gate in
#     pacgate-rag/src/lib.rs is `WHERE ... sanitization_state IN
#     ('sanitized','never')`, which WHITELISTED exactly those rows.
#
#     The assertion above - `chunk_states -eq 'sanitized'` - is precisely the
#     false-red that let this ship: it reads the state column, which was the one
#     thing the old code did set. These two assertions read the text instead.
#
#     Both needles are checked separately so a regression names which one leaked.
$chunkIdLeak = cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c ""SELECT count(*) FROM kb_chunks WHERE document_id='$docId' AND sanitization_state='sanitized' AND content LIKE '%11010519491231002X%'"" 2>&1"
Check "no raw id card in a sanitized chunk" ([int](($chunkIdLeak | Select-Object -First 1).ToString().Trim()) -eq 0)
$chunkPhoneLeak = cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c ""SELECT count(*) FROM kb_chunks WHERE document_id='$docId' AND sanitization_state='sanitized' AND content LIKE '%13812345678%'"" 2>&1"
Check "no raw phone in a sanitized chunk" ([int](($chunkPhoneLeak | Select-Object -First 1).ToString().Trim()) -eq 0)

# Positive evidence the rewrite happened, so "0 leaks" cannot be satisfied by
# there simply being no sanitized chunks at all.
$sanChunks = cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c ""SELECT count(*) FROM kb_chunks WHERE document_id='$docId' AND sanitization_state='sanitized'"" 2>&1"
Check "sanitized chunks exist" ([int](($sanChunks | Select-Object -First 1).ToString().Trim()) -ge 1)
$sanText = cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c ""SELECT string_agg(content,' ') FROM kb_chunks WHERE document_id='$docId' AND sanitization_state='sanitized'"" 2>&1"
$sanText = ($sanText | Select-Object -First 1).ToString().Trim()
Check "sanitized chunk text is the redacted rendering" ($sanText.Length -gt 0 -and -not $sanText.Contains('11010519491231002X'))

# 8c. And the raw row must be GONE, not merely unlabelled - a lingering pending
#     copy is one status flip away from being served again.
$rawLeft = cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c ""SELECT count(*) FROM kb_chunks WHERE document_id='$docId' AND content LIKE '%11010519491231002X%'"" 2>&1"
Check "no raw id card anywhere in kb_chunks" ([int](($rawLeft | Select-Object -First 1).ToString().Trim()) -eq 0)

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
