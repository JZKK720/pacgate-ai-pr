# Drive every `pending` document through extract -> sanitize, so the knowledge base
# is actually queryable.
#
# WHY THIS EXISTS
#
# Measured 2026-11-03: 39 of 76 documents sat in `pending`, and 35 of those had NO
# extraction record at all - they had never been processed, on any build. Only 4 had
# text that had not been sanitised.
#
# The user-visible consequence was not "search is bad". It was that the chat agent
# asked to read `pending` documents, the read was refused BY DESIGN (returning the
# original would hand raw client identifiers to the model), the model retried the
# refusal, and the turn burned every one of its 10 rounds and closed with an empty
# answer. From the outside that is "36 steps and no response from the LLM". The
# corpus was never ready; nothing in the UI said so.
#
# ORDER OF OPERATIONS, and why it matters:
#   1. EXTRACT first. A document with no extraction has no text, so sanitize has
#      nothing to redact and refuses. Running sanitize first is a no-op that looks
#      like progress.
#   2. EXTRACT can legitimately report `incomplete`. That is a scan-quality fact, not
#      a failure - the text that WAS read still gets sanitised, and the document is
#      still marked incomplete so the UI can warn. Do not skip those.
#   3. SANITIZE second, and only promote what the gate promotes. A `block` verdict
#      leaves the document unqueryable on purpose.
#
# WHY THIS IS SAFE TO RUN REPEATEDLY
#
#   - It only ever selects `pending` documents. A document that already reached
#     `sanitized` is never re-processed, so this cannot rewrite an existing token
#     value. (Re-sanitising an already-sanitized document has been shown to REPLACE
#     the token payload, not just re-wrap it - 0.2.18 audit. That is why this script
#     is deliberately not a "re-sanitize everything" tool.)
#   - It sends one document at a time and never parallelises, because the sanitize
#     job is CPU-bound BERT NER and concurrency just makes every document slower.
#
# USAGE
#   powershell -File scripts/process-pending-documents.ps1 -WhatIf
#   powershell -File scripts/process-pending-documents.ps1
#   powershell -File scripts/process-pending-documents.ps1 -Limit 5

param(
    [string]$ApiBase = 'http://localhost:8089/pacgate',
    [string]$Email   = $env:PACGATE_API_EMAIL,
    [string]$Password = $env:PACGATE_API_PASSWORD,
    [string]$DataLevel = 'T3',
    # 0 = no cap. A cap is for a cautious first run on a large corpus.
    [int]$Limit = 0,
    # Per-request ceiling. A 144-chunk document measured ~655s server-side at
    # T3 on 2026-10-08, so the transport timeout must exceed the job, not the
    # other way round. nginx's /pacgate/ read timeout is 720s.
    [int]$TimeoutSec = 900,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# The proxy variables on this box point at a local proxy that is not always
# listening; a stale HTTP_PROXY makes every Invoke-RestMethod fail with a
# connection error that reads like an API outage.
foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy') {
    Remove-Item "env:$v" -ErrorAction SilentlyContinue
}

function Get-PsqlPath {
    $cmd = Get-Command psql -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Psql([string]$Sql, [string]$Database = 'pacgate') {
    $container = (docker ps --filter 'name=pacgate-db' --format '{{.Names}}' | Select-Object -First 1)
    if (-not $container) { throw 'pacgate-db container is not running' }
    $out = docker exec $container psql -U pacgate -d $Database -t -A -F "`t" -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $out" }
    return $out
}

if (-not $Email -or -not $Password) {
    Write-Output 'ERROR: set PACGATE_API_EMAIL and PACGATE_API_PASSWORD (or pass -Email/-Password).'
    Write-Output '       The script logs in as the admin to run extract/sanitize jobs.'
    exit 2
}

Write-Output '== pending-document processing =='
Write-Output "api base   : $ApiBase"
Write-Output "data level : $DataLevel"

$login = Invoke-RestMethod -Uri "$ApiBase/api/auth/login" -Method Post `
    -ContentType 'application/json' `
    -Body (@{ email = $Email; password = $Password } | ConvertTo-Json) `
    -TimeoutSec 25
$token = $login.token
if (-not $token) { throw 'login returned no token' }
$auth = @{ Authorization = "Bearer $token" }

# Only `pending`. Selecting `sanitized` here would rewrite token values - see the
# header comment.
$sql = @'
SELECT d.id::text, left(replace(d.name, E'\t', ' '), 48), d.format
FROM documents d
WHERE d.sanitization_state = 'pending'
ORDER BY d.created_at, d.id
'@
if ($Limit -gt 0) { $sql += " LIMIT $Limit" }

$rows = @(Invoke-Psql $sql | Where-Object { $_.Trim() })
Write-Output "documents  : $($rows.Count) pending"

if ($rows.Count -eq 0) {
    Write-Output ''
    Write-Output '== RESULT: nothing pending - every document is through the pipeline =='
    exit 0
}

if ($WhatIf) {
    Write-Output ''
    foreach ($row in $rows) {
        $f = $row -split "`t"
        Write-Output "  would process $($f[0])  [$($f[2])]  $($f[1])"
    }
    Write-Output ''
    Write-Output '== RESULT: -WhatIf - nothing was changed =='
    exit 0
}

$extracted = 0; $sanitized = 0; $incomplete = 0; $blocked = 0; $failed = 0
$index = 0
foreach ($row in $rows) {
    $index++
    $f = $row -split "`t"
    $id = $f[0]; $name = $f[1]; $format = $f[2]
    $prefix = "[$index/$($rows.Count)] $id [$format] $name"

    # 1. EXTRACT -------------------------------------------------------------
    try {
        $ex = Invoke-RestMethod -Uri "$ApiBase/api/documents/$id/extract" -Method Post `
            -Headers $auth -ContentType 'application/json' -Body '{}' -TimeoutSec $TimeoutSec
        if ($ex.incomplete) {
            $incomplete++
            Write-Output "$prefix  extract: incomplete (pages=$($ex.pages)) - text still usable"
        } else {
            Write-Output "$prefix  extract: ok (chars=$($ex.chars))"
        }
        $extracted++
    } catch {
        $failed++
        Write-Output "$prefix  EXTRACT FAILED: $($_.Exception.Message)"
        continue
    }

    # 2. SANITIZE ------------------------------------------------------------
    try {
        $sa = Invoke-RestMethod -Uri "$ApiBase/api/documents/$id/sanitize" -Method Post `
            -Headers $auth -ContentType 'application/json' `
            -Body (@{ data_level = $DataLevel } | ConvertTo-Json) -TimeoutSec $TimeoutSec
        if ($sa.verdict -eq 'pass') {
            Write-Output "$prefix  sanitize: pass (redactions=$($sa.redaction_count))"
            $sanitized++
        } else {
            $blocked++
            Write-Output "$prefix  sanitize: $($sa.verdict) - stays unqueryable until reviewed"
        }
    } catch {
        $failed++
        Write-Output "$prefix  SANITIZE FAILED: $($_.Exception.Message)"
    }
}

# Read the outcome from the database rather than from the replies: a sanitize call
# can succeed while the document still sits at `block` or `pending`.
$after = @(Invoke-Psql "SELECT sanitization_state, count(*) FROM documents GROUP BY 1 ORDER BY 1")
Write-Output ''
Write-Output '== document states now =='
foreach ($line in $after) { if ($line.Trim()) { Write-Output "  $line" } }

Write-Output ''
Write-Output "extracted=$extracted sanitized=$sanitized blocked=$blocked incomplete=$incomplete failed=$failed"
$left = @(Invoke-Psql "SELECT count(*) FROM documents WHERE sanitization_state = 'pending'")
Write-Output "still pending: $($left -join '')"

if ($failed -gt 0) {
    Write-Output ''
    Write-Output "== RESULT: $failed document(s) failed - see the lines above =="
    exit 1
}
Write-Output ''
Write-Output '== RESULT: every selectable document went through extract -> sanitize =='
