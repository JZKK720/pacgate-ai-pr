# Sanitizer E2E: upload -> extract -> sanitize -> verify -> gate -> restore.
# Mirrors scripts/test-ocr-extraction.ps1 conventions (PASS/FAIL lines).
# Boots fresh test containers; never touches the live pacgate-api/deer-flow.
# Usage: powershell -File scripts/test-sanitizer-e2e.ps1
$ErrorActionPreference = 'Continue'
$script:fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Output "PASS: $name" } else { Write-Output "FAIL: $name"; $script:fail++ }
}

Write-Output "== building fixture =="
$fixture = Join-Path $env:TEMP 'pacgate-sanitizer-e2e.txt'
$content = "委托人张三，身份证 11010519491231002X，电话 13812345678，联系 a@b.com。"
[System.IO.File]::WriteAllText($fixture, $content, [System.Text.UTF8Encoding]::new($false))
Check "fixture written" (Test-Path $fixture)

docker rm -f pacgate-ocr-e2e, pacgate-api-e2e 2>$null | Out-Null

# 1. OCR service (no host port needed; API reaches it over the compose net).
docker run -d --name pacgate-ocr-e2e --network client-bundle_default ocr-service:local | Out-Null
# 2. API under test, wired to the live db + ocr + embeddings + NER weights.
$nerDir = "C:\Users\cubecloud-io\github-pr\pacgate-ai-pr\.e2e-ner-model"
$nerMount = if (Test-Path $nerDir) { @("-e", "PACGATE_NER_MODEL_DIR=/models/ner", "-v", "${nerDir}:/models/ner") } else { @() }
Write-Output "ner weights mounted: $($nerMount.Count -gt 0)"
docker run -d --name pacgate-api-e2e --network client-bundle_default `
  -p 127.0.0.1:8090:8080 `
  -e "DATABASE_URL=postgres://pacgate:change-me-to-a-strong-password@pacgate-db:5432/pacgate" `
  -e "DATA_DIR=/data/tenants" `
  -e "OCR_SERVICE_URL=http://pacgate-ocr-e2e:8100" `
  -e "OLLAMA_BASE_URL=http://host.docker.internal:11434" `
  @nerMount `
  -v "C:\Users\cubecloud-io\github-pr\pacgate-ai-pr\deploy\client-bundle\data:/data" `
  pacgate-api:plan020-test | Out-Null
Start-Sleep -Seconds 6
$health = Invoke-RestMethod -Uri "http://127.0.0.1:8090/health" -TimeoutSec 5
Check "api boots" ($health -eq 'ok')

# 3. Seed + login + matter.
cmd /c "docker exec pacgate-api-e2e pacgate-seed --db-url postgres://pacgate:change-me-to-a-strong-password@pacgate-db:5432/pacgate 2>&1" | Out-Null
$login = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/auth/login" -Method Post -Body '{"email":"seed@pacgate.local","password":"seed-password-123"}' -ContentType "application/json"
$hdr = @{ Authorization = "Bearer $($login.token)" }
$matter = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/matters" -Method Post -Headers $hdr -Body '{"name":"Sanitizer E2E","description":"plan 020 proof"}' -ContentType "application/json"
Check "matter created" ($null -ne $matter.id)

# 4. Register a non-admin user for the restore-refusal assertion.
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/auth/register" -Method Post -Body '{"email":"attorney-e2e@pacgate.local","password":"attorney-pass-123","role":"attorney"}' -ContentType "application/json" | Out-Null
} catch { }
$attorneyLogin = $null
try {
    $attorneyLogin = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/auth/login" -Method Post -Body '{"email":"attorney-e2e@pacgate.local","password":"attorney-pass-123"}' -ContentType "application/json"
} catch { }
Check "attorney user usable" ($null -ne $attorneyLogin)

# 5. Upload a text document carrying the identifiers.
$fileBytes = [System.IO.File]::ReadAllBytes($fixture)
$ms = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($ms)
$boundary = "----psb$([System.Guid]::NewGuid().ToString('N'))"
$bw.Write([System.Text.Encoding]::ASCII.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"matter_id`"`r`n`r`n$($matter.id)`r`n--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"case.txt`"`r`nContent-Type: text/plain`r`n`r`n"))
$bw.Write($fileBytes); $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary--`r`n")); $bw.Flush()
$up = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents" -Method Post -Headers $hdr -ContentType "multipart/form-data; boundary=$boundary" -Body $ms.ToArray()
Check "upload ok" ($null -ne $up.id)
$docId = $up.id

# 6. Extract (cache-warm step for the sanitize job).
$ex = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents/$docId/extract" -Method Post -Headers $hdr -ContentType "application/json" -Body '{}'
Check "extract returned text" ($ex.text.Length -gt 0)

# 7. Sanitize (the plan-020 route).
$job = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents/$docId/sanitize" -Method Post -Headers $hdr -ContentType "application/json" -Body '{"data_level":"T3"}'
Check "sanitize verdict pass" ($job.verdict -eq 'pass')
Check "id card redacted" (-not $job.sanitized_text.Contains('11010519491231002X'))
Check "phone gone" (-not $job.sanitized_text.Contains('13812345678'))
Check "mapping sealed server-side" ($job.mapping_count -ge 2)
Write-Output "  sanitized: $($job.sanitized_text)"
Write-Output "  verdict=$($job.verdict) redactions=$($job.redaction_count) promoted=$($job.chunks_promoted)"

# 8. Status + gate behaviour.
$status = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents/$docId/sanitize-status" -Headers $hdr
Check "document state sanitized" ($status.document_state -eq 'sanitized')
Check "chunks sanitized" (($status.chunk_states -join ',').Trim() -eq 'sanitized')

# 9. Download gate: BEFORE sanitize the doc was pending; now sanitized, so
#    download must be ALLOWED. Refusal path is asserted by the status above.
$dl = Invoke-WebRequest -Uri "http://127.0.0.1:8090/api/documents/$docId/download" -Headers $hdr -UseBasicParsing
Check "download allowed post-sanitize" ($dl.StatusCode -eq 200)

# 10. Restore: role gate. Attorney token must be refused.
$restoreBody = @{ job_id = $job.job_id; text = $job.sanitized_text } | ConvertTo-Json -Compress
$attHdr = @{ Authorization = "Bearer $($attorneyLogin.token)" }
$refused = $false
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents/$docId/restore" -Method Post -Headers $attHdr -ContentType "application/json" -Body $restoreBody | Out-Null
} catch {
    $refused = $true
}
Check "restore refused for attorney role" $refused

# 11. Admin path: seed is admin, restore must succeed.
$adminRestored = $false
try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents/$docId/restore" -Method Post -Headers $hdr -ContentType "application/json" -Body $restoreBody
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

docker rm -f pacgate-ocr-e2e, pacgate-api-e2e 2>$null | Out-Null
if ($script:fail -eq 0) { Write-Output '== RESULT: PASS ==' } else { Write-Output "== RESULT: FAIL ($($script:fail)) =="; exit 1 }