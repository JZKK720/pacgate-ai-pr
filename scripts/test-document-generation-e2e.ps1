# Document generation gate: a workflow must actually PRODUCE a document.
#
# WHY THIS EXISTS. The reported symptom was "cloud and local models cannot
# generate prompt and documents". The generation path had no end-to-end test at
# all - the closest coverage was `test-workflow-library-served.ps1`, which only
# proves the API SERVES the 222-workflow library. Nothing proved that EXECUTING a
# workflow reaches the model, calls the docx tool, and lands a real file on disk.
#
# That gap is not academic. `POST /api/workflows/:id/execute` is the one route that
# joins every layer the 0.1.26-0.1.28 work touched: the workflow YAML loader, the
# persona/SOUL composer, the AgentLoop, the LLM gateway (`pacgate-llm`), the
# document tools (`generate_docx`), the matter store, and the tenant-scoped
# storage root. A break in ANY of them presents to a lawyer as "the AI cannot
# write me a document", and every one of those layers had a separate defect found
# this month (CJK byte-slicing, proxy timeouts, MCP timeouts).
#
# It asserts the whole chain, not the HTTP status:
#   1. execute returns 200 AND names the workflow it ran;
#   2. at least one step reports the docx tool in `tools_used` - a step that
#      generated nothing must not pass;
#   3. the run reports a created document id;
#   4. that id RESOLVES through GET /api/documents/:id, with a storage_path;
#   5. the file EXISTS on disk at DATA_DIR/storage_path;
#   6. it is a real OOXML zip carrying word/document.xml;
#   7. its text is non-empty - and if the workflow is a Chinese one, the CJK
#      actually round-tripped rather than being mangled on the way out.
#
# Steps 5-7 are why this is not just an API test. The 0.1.26 CJK defect was a panic
# in a byte-slicing search on Chinese text, so "the request returned 200" would
# have passed while the product was broken.
#
# Exit 2 means CANNOT CHECK (stack down / no credentials) and must never be read
# as a failure of the code.
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:8089/pacgate',
    # The workflow to execute. Default is a small Chinese overview-table workflow:
    # it is short, deterministic in shape, and exercises the CJK path end to end.
    [string]$WorkflowId = '00000000-0000-0000-0000-000000001002',
    [string]$EnvFile = '',
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot 'deploy/client-bundle/.env' }

$pass = 0
$fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:fail++
    }
}
function Skip-CannotCheck($why) {
    Write-Host "[SKIP] CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host "RESULT: $pass passed, $fail failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== document generation gate (workflow execute -> docx on disk) ===' -ForegroundColor Cyan

# ── 0. Credentials ────────────────────────────────────────────────────────────
if (-not (Test-Path $EnvFile)) { Skip-CannotCheck "credentials file not found: $EnvFile" }
$email = $null; $password = $null
foreach ($line in Get-Content $EnvFile) {
    if     ($line -match '^PACGATE_API_EMAIL=(.+)$')    { $email    = $Matches[1].Trim() }
    elseif ($line -match '^PACGATE_API_PASSWORD=(.+)$') { $password = $Matches[1].Trim() }
}
if (-not $email -or -not $password) { Skip-CannotCheck 'PACGATE_API_EMAIL / PACGATE_API_PASSWORD missing from .env' }

# Never echo a secret - only that it was read.
Write-Host '  credentials readable (values not printed)' -ForegroundColor DarkGray

# ── 1. Authenticate ───────────────────────────────────────────────────────────
$token = $null
foreach ($p in @("$BaseUrl/api/auth/login", "$BaseUrl/auth/login")) {
    try {
        $body = @{ email = $email; password = $password } | ConvertTo-Json -Compress
        $login = Invoke-RestMethod -Uri $p -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20
        if ($login.token) { $token = $login.token; break }
    }
    catch { }
}
if (-not $token) { Skip-CannotCheck "login failed at $BaseUrl - is the stack up?" }
$H = @{ Authorization = "Bearer $token" }
Check 'authenticated against the running API' ($true)

# ── 2. A matter to generate INTO ───────────────────────────────────────────────
# `execute` refuses an unknown matter, so this is also the gate's own precondition
# check rather than a convenience.
$runId = Get-Random
$matterId = $null
try {
    $matter = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Method Post -Headers $H -TimeoutSec 20 `
        -ContentType 'application/json' `
        -Body (@{ name = "docgen-$runId"; description = "document-generation gate $runId" } | ConvertTo-Json -Compress)
    $matterId = $matter.id
}
catch { }
Check 'a matter was created to generate into' ([bool]$matterId) 'POST /api/matters failed'
if (-not $matterId) {
    Write-Host 'RESULT: FAILED - cannot exercise generation without a matter' -ForegroundColor Red
    exit 1
}
Write-Host "         matter: $matterId" -ForegroundColor DarkGray

# ── 2b. Locate the storage root BEFORE generating ────────────────────────────
# Deliberately hoisted out of the try block below. These two lookups do not depend
# on the generated document, and reading them afterwards meant a "cannot check"
# exit could fire from INSIDE the try - after a matter had been created and a
# 40-second generation had run - and leak both. Anything that can end the script
# early belongs before the part that has side effects.
#
# Derive the paths instead of assuming a shape: this repo has already shipped one
# gate that hardcoded a compose network name and reported eleven false failures.
$dataRoot = $null
try {
    $mounts = docker inspect pacgate-api --format '{{json .Mounts}}' 2>$null | ConvertFrom-Json
    $dataRoot = ($mounts | Where-Object { $_.Destination -eq '/data' } | Select-Object -First 1).Source
}
catch { }
if (-not $dataRoot) { Skip-CannotCheck 'could not read the pacgate-api /data mount to locate generated files' }
Check 'the running API exposes its /data storage root' ([bool]$dataRoot) 'no /data bind mount on pacgate-api'

$dataDir = $null
try {
    $envs = docker inspect pacgate-api --format '{{range .Config.Env}}{{println .}}{{end}}' 2>$null
    $dataDir = ([regex]::Match(($envs -join "`n"), '(?m)^DATA_DIR=(?<p>.+)$')).Groups['p'].Value.Trim()
}
catch { }
if (-not $dataDir) { Skip-CannotCheck 'DATA_DIR is not configured on the running API - the storage root cannot be located' }
Check 'DATA_DIR is configured on the running API' ([bool]$dataDir) 'no DATA_DIR'
Write-Host "         storage root: $dataRoot ($dataDir)" -ForegroundColor DarkGray

$createdDocId = $null
try {
    # ── 3. EXECUTE the workflow ────────────────────────────────────────────────
    Write-Host ''
    Write-Host 'LIVE: executing a workflow through the real generation path'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri "$BaseUrl/api/workflows/$WorkflowId/execute" -Method Post -Headers $H `
        -ContentType 'application/json' -Body (@{ matter_id = $matterId } | ConvertTo-Json -Compress) `
        -TimeoutSec $TimeoutSec
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    Check 'POST /api/workflows/:id/execute returns a result' ($null -ne $r) 'no response object'
    Check 'the response names the workflow that ran' ([bool]$r.workflow_name) "workflow_name was '$($r.workflow_name)'"
    $steps = @($r.steps)
    Check 'the workflow reported at least one step' ($steps.Count -gt 0) 'steps was empty - nothing executed'
    Write-Host ("         '{0}' ran {1} step(s) in {2}s" -f $r.workflow_name, $steps.Count, $secs) -ForegroundColor DarkGray

    # A step that ran the docx tool is the difference between "the workflow
    # completed" and "a document was produced". Do not accept the former.
    $docSteps = @($steps | Where-Object { ($_.tools_used -join ',') -match 'generate_docx|create_document|generate_document' })
    $toolList = ($steps | ForEach-Object { $_.tools_used } | Select-Object -Unique) -join ', '
    Check 'a step actually invoked the document-generated tool' ($docSteps.Count -gt 0) `
        "tools_used across steps: '$toolList'"
    Write-Host "         tools_used: $toolList" -ForegroundColor DarkGray

    # ── 4. The run must NAME the document it created ─────────────────────────────
    $blob = (@($r.final_content) + @($docSteps | ForEach-Object { $_.content })) -join "`n"
    $m = [regex]::Match($blob, '(?m)^\s*[-*]?\s*\**(?:文档\s*ID|document\s*id)\**\s*[:：]\s*`?(?<id>[0-9a-fA-F-]{36})')
    if ($m.Success) { $createdDocId = $m.Groups['id'].Value }
    Check 'the run reports the id of the document it created' ([bool]$createdDocId) `
        'no "document id" found in the step content - the tool may have silently failed'
    Write-Host "         document id: $createdDocId" -ForegroundColor DarkGray

    # ── 5. The id must RESOLVE through the API ───────────────────────────────────
    $doc = $null
    if ($createdDocId) {
        try { $doc = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$createdDocId" -Method Get -Headers $H -TimeoutSec 30 } catch { }
        Check 'the created document id resolves through GET /api/documents/:id' ([bool]$doc) `
            "GET /api/documents/$createdDocId did not return a document"
    }
    if ($doc) {
        Check 'the document belongs to the matter it was generated into' ($doc.matter_id -eq $matterId) `
            "document.matter_id=$($doc.matter_id) but the run used $matterId"
        Check 'the document records a storage_path' ([bool]$doc.storage_path) 'storage_path was empty'
        Check 'the document format is docx' ($doc.format -eq 'docx') "format was '$($doc.format)'"

        # ── 6. The file must EXIST on disk ───────────────────────────────────────
        # $dataRoot/$dataDir were derived before the generation ran (step 2b).
        $rel = if ($dataDir.StartsWith('/data')) { $dataDir.Substring('/data'.Length).TrimStart('/') } else { $dataDir.TrimStart('/') }
        $onDisk = Join-Path (Join-Path $dataRoot $rel) ($doc.storage_path -replace '/', '\')
        $exists = Test-Path $onDisk
        Check 'the generated file EXISTS on disk' $exists "looked for $onDisk"
        if ($exists) {
            $item = Get-Item $onDisk
            Check 'the generated file is not empty' ($item.Length -gt 0) "size was $($item.Length) bytes"
            Write-Host ("         {0} bytes at {1}" -f $item.Length, $item.Name) -ForegroundColor DarkGray

            # ── 7. It must be a REAL docx, with real text ────────────────────────
            # A .docx is a zip. Checking the magic bytes and the part name is what
            # separates "a file was written" from "a Word document was produced";
            # the OCR defect was exactly this distinction - a file that existed but
            # carried nothing readable.
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                $zip = [IO.Compression.ZipFile]::OpenRead($onDisk)
                $names = @($zip.Entries | ForEach-Object { $_.FullName })
                $entry = $zip.Entries | Where-Object { $_.FullName -eq 'word/document.xml' } | Select-Object -First 1
                $text = ''
                if ($entry) {
                    $sr = New-Object IO.StreamReader($entry.Open())
                    $text = $sr.ReadToEnd(); $sr.Close()
                    $text = [regex]::Replace($text, '<[^>]+>', ' ')
                }
                $zip.Dispose()
                Check 'the file is a real OOXML package (has word/document.xml)' ([bool]$entry) `
                    "zip entries: $($names -join ', ')"
                Check 'the document body is non-empty' ($text.Trim().Length -gt 0) `
                    'word/document.xml had no text after stripping tags'

                # The CJK round trip. This workflow is Chinese, so a byte-level
                # mangle (the 0.1.26 class of defect) shows up here as mojibake or
                # an empty body even though every HTTP call returned 200.
                $cjk = [regex]::IsMatch($text, '[\u4e00-\u9fff]')
                Check 'Chinese text survived the round trip into the .docx' $cjk `
                    'no CJK characters in the generated document - the text was mangled or lost'
                if ($cjk) {
                    $sample = ([regex]::Match($text, '[\u4e00-\u9fff]{2,}')).Value
                    Write-Host "         CJK sample: '$sample'" -ForegroundColor DarkGray
                }
            }
            catch {
                Check 'the generated file could be opened as a zip' $false $_.Exception.Message
            }
        }
    }

    # ── 8. Cleanup, so repeated runs do not accumulate debris ───────────────────
    if ($matterId) {
        try { $null = Invoke-RestMethod -Uri "$BaseUrl/api/matters/$matterId" -Method Delete -Headers $H -TimeoutSec 30 }
        catch { }
    }
}
catch {
    # A thrown call must become a clean FAIL, not an unhandled crash. Without this
    # the script aborts before printing RESULT and never exits non-zero, so a
    # client-side timeout or a 404 on the workflow id would read as a passing run
    # to anything that only inspects the exit code. The failure text names the
    # three things this gate is most likely to be reporting.
    $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'no-response' }
    $body = ''
    try {
        $rs = $_.Exception.Response.GetResponseStream()
        if ($rs) { $sr = New-Object IO.StreamReader($rs); $body = $sr.ReadToEnd(); $sr.Close() }
    }
    catch { }
    Check 'POST /api/workflows/:id/execute returns a result' $false `
        "HTTP $code. 404 = the workflow id does not exist in the served library; " +
        "500 = the generation path itself failed (model gateway, tools, or workflow YAML); " +
        "timeout = the run exceeded ${TimeoutSec}s. body: $($body.Substring(0, [Math]::Min(300, $body.Length)))"
}
finally {
    # The gate must not leave a matter behind even when it throws partway - the
    # data-plane counts in the benchmark report are read by a human.
    if ($matterId) {
        try { $null = Invoke-RestMethod -Uri "$BaseUrl/api/matters/$matterId" -Method Delete -Headers $H -TimeoutSec 30 } catch { }
    }
}

Write-Host ''
Write-Host "RESULT: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
exit 0
