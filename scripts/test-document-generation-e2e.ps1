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
    [int]$TimeoutSec = 900,
    # Opt-in failure-rate soak. 0 = skip (default, keeps the sweep fast). Each run
    # costs a real generation, so this belongs in a release soak, not every sweep.
    [int]$FailureRateRuns = 0,
    [int]$MaxFailures = 0
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

# ── Failure-rate measurement ──────────────────────────────────────────────────
#
# WHY THIS IS A SEPARATE PASS. The 0.1.28 defect answered
# `POST /api/workflows/:id/execute` with HTTP 500 on **1 run in 3**, while the
# document was written anyway. Every gate in this repo, including the ones in this
# file, runs a route ONCE and asserts on that single result - so a 1-in-3 defect had
# a ~67% chance of passing the suite on any given run. The suite was not weak
# because it asserted too little; it was weak because it asserted once.
#
# A single-run gate cannot be fixed by adding assertions. This measures the thing
# that was actually wrong: the FAILURE RATE of the generation path under repetition.
#
# It is opt-in (`-FailureRateRuns N`) for a deliberate reason: each run costs a real
# generation, so it belongs in a release soak and not in the default sweep. The
# number to beat is not zero - it is "the rate is not statistically distinguishable
# from zero at this sample size", which is why the threshold is stated as a count
# (`-MaxFailures`, default 0) rather than a percentage that would round a 1-in-3 bug
# down to something that looks acceptable.
function Measure-GenerationFailureRate {
    param(
        [string]$BaseUrl, [hashtable]$Headers, [string]$WorkflowId, [int]$Runs, [int]$MaxFailures, [int]$TimeoutSec
    )
    Write-Host ''
    Write-Host ("MEASURE: generation failure rate over {0} consecutive runs" -f $Runs) -ForegroundColor Cyan
    $codes = @()
    $capped = 0
    $matterIds = @()
    try {
        for ($i = 1; $i -le $Runs; $i++) {
            $mid = $null
            try {
                $mm = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Method Post -Headers $Headers -TimeoutSec 30 `
                    -ContentType 'application/json' `
                    -Body (@{ name = "soak-$i-$(Get-Random)"; description = "failure-rate soak run $i" } | ConvertTo-Json -Compress)
                $mid = $mm.id; $matterIds += $mid
            }
            catch { }

            $code = 'no-matter'
            $flag = ''
            if ($mid) {
                # The body goes in from a FILE, via `--data-binary @path`.
                #
                # MEASURED 2026-10-14: the inline form
                #   --data-binary "{`"matter_id`":`"$mid`"}"
                # produced HTTP 400 on 8 of 8 runs, and the server saw
                #   "EOF while parsing an object at line 1 column 1"
                # - the JSON never arrived. Reproduced on BOTH pwsh 7 and Windows
                # PowerShell 5.1, so it is not a shell-compatibility quirk: the
                # backtick-quoted braces are consumed before curl sees them.
                #
                # That mattered more than a noisy gate. This measurement exists to
                # catch a 1-in-3 generation defect, and a harness that fails 8 of 8
                # for an unrelated reason cannot distinguish "the product is broken"
                # from "the harness is broken" - which is the same false-red shape
                # that hid the sanitizer defect for two releases.
                #
                # Writing the body to a file removes every quoting layer.
                $bodyFile = "$env:TEMP\soak-$i-body.json"
                [System.IO.File]::WriteAllText(
                    $bodyFile,
                    (@{ matter_id = $mid } | ConvertTo-Json -Compress),
                    (New-Object System.Text.UTF8Encoding($false))
                )
                $code = (curl.exe -s -o "$env:TEMP\soak-$i.json" -w '%{http_code}' `
                        -X POST "$BaseUrl/api/workflows/$WorkflowId/execute" `
                        -H "Authorization: $($Headers['Authorization'])" -H 'Content-Type: application/json' `
                        --data-binary "@$bodyFile" --max-time $TimeoutSec 2>&1)
                if ($code -eq '200') {
                    try {
                        $flag = ((Get-Content "$env:TEMP\soak-$i.json" -Raw | ConvertFrom-Json).steps[0].max_rounds_reached)
                        if ($flag -eq $true) { $capped++ }
                    }
                    catch { }
                }
            }
            $codes += $code
            Write-Host ("  run {0,2}/{1}: HTTP {2} {3}" -f $i, $Runs, $code, $(if ($flag -eq $true) { '(round cap reached - delivered anyway)' } else { '' })) -ForegroundColor DarkGray
        }
    }
    finally {
        foreach ($mid in $matterIds) {
            try { $null = Invoke-RestMethod -Uri "$BaseUrl/api/matters/$mid" -Method Delete -Headers $Headers -TimeoutSec 30 } catch { }
        }
    }

    $failures = @($codes | Where-Object { $_ -ne '200' }).Count
    Write-Host ("  failures: {0} of {1}  (codes: {2})" -f $failures, $Runs, ($codes -join ' ')) -ForegroundColor DarkGray
    if ($capped -gt 0) {
        Write-Host ("  the round cap fired on {0} run(s) and every one was still delivered" -f $capped) -ForegroundColor Yellow
    }
    Check "generation path has no failures in $Runs consecutive runs" ($failures -le $MaxFailures) `
        "$failures of $Runs failed (allowed $MaxFailures). THIS is the shape of the 0.1.28 defect: it failed on demand and succeeded on retry, so one run proves nothing."
    return $failures
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

    # The run must REPORT the tool-round cap rather than turn it into a failure.
    #
    # This is the contract that replaced a 500. Measured 2026-10-13, before the fix:
    # the loop returned `Err(LlmError("agent loop exceeded max_rounds=10"))` on 1 run
    # in 3 and the API answered
    #   {"error":{"code":"internal_error","message":"LLM error: agent loop exceeded max_rounds=10"}}
    # while the log for that same request said `has_output=true` and the .docx was
    # already on disk - generation ran, the caller never got the result.
    #
    # After the fix: 8 consecutive runs all returned 200, and run 6 of those 8
    # reported `max_rounds_reached=true` - i.e. the cap really did fire during the
    # proof and was reported instead of discarding the work.
    #
    # Assert the field is PRESENT on every step: a response that simply dropped it
    # would make the state unobservable, which is how this hid for a whole release.
    $missingFlag = @($steps | Where-Object { $_.PSObject.Properties.Name -notcontains 'max_rounds_reached' })
    Check 'every step reports whether it hit the tool-round cap' ($missingFlag.Count -eq 0) `
        "steps without max_rounds_reached: $(($missingFlag | ForEach-Object { $_.step_name }) -join ', ')"
    $capped = @($steps | Where-Object { $_.max_rounds_reached })
    if ($capped.Count -gt 0) {
        # Not a failure: the cap firing is legitimate, and the tools did run. It is
        # worth printing because it is the state that used to be a 500.
        Write-Host ("         NOTE: {0} step(s) hit the round cap and the run still succeeded (tools ran; the closing summary did not)." -f $capped.Count) -ForegroundColor Yellow
        Write-Host '         This is the fixed behaviour - before it, this run would have returned HTTP 500.' -ForegroundColor DarkGray
    }

    # A step that ran the docx tool is the difference between "the workflow
    # completed" and "a document was produced". Do not accept the former.
    $docSteps = @($steps | Where-Object { ($_.tools_used -join ',') -match 'generate_docx|create_document|generate_document' })
    $toolList = ($steps | ForEach-Object { $_.tools_used } | Select-Object -Unique) -join ', '
    Check 'a step actually invoked the document-generated tool' ($docSteps.Count -gt 0) `
        "tools_used across steps: '$toolList'"
    Write-Host "         tools_used: $toolList" -ForegroundColor DarkGray

    # ── 4. The generated DOCUMENT must be findable, and the id must RESOLVE ──────
    #
    # The authoritative source is the DATABASE, not the model's prose, and the
    # difference is not academic. The first version of this gate scraped a
    # document id out of the step content and was FLAKY: the model writes its
    # summary in English or Chinese depending on the run, and it called
    # `generate_docx` THREE times in one observed run (tools_used showed
    # generate_docx x3), so which - if any - id appears in the prose varies run to
    # run. A gate that fails on correct code is worse than no gate, because the
    # reflex is to re-run it until it passes.
    #
    # So: query the documents table for what this run created. The prose is still
    # read, but only as a FALLBACK and only to pick among rows the database already
    # confirmed.
    $doc = $null
    $docSource = 'none'
    $dbErr = ''
    try {
        $rows = docker exec pacgate-db psql -U pacgate -d pacgate -t -A -F'|' -c `
            "SELECT id, name, format, version, storage_path FROM documents WHERE matter_id = '$matterId' ORDER BY created_at DESC;" 2>&1
        $dbErr = ($rows | Out-String).Trim()
        $parsed = @($rows | Where-Object { $_ -match '^\s*[0-9a-fA-F-]{36}\|' } | ForEach-Object {
            $p = $_ -split '\|', 5
            [pscustomobject]@{ id = $p[0].Trim(); name = $p[1]; format = $p[2]; version = $p[3]; storage_path = $p[4] }
        })
        # Fall back to the prose id only to choose WHICH confirmed row was meant.
        $blob = (@($r.final_content) + @($steps | ForEach-Object { $_.content })) -join "`n"
        #
        # The CJK alternation is written as \u escapes, NOT as literal 文档 / ：.
        #
        # MEASURED 2026-10-14: this script has no UTF-8 BOM, and Windows PowerShell
        # 5.1 decodes a BOM-less script using the ANSI code page. The literals arrived
        # as mojibake, which included a stray ')' - so the regex died with
        #   "parsing ... Too many )'s."
        # and the gate reported "no documents row" on a run that HAD created
        # 项目概况表.docx. A false red is not a harmless noise: it is indistinguishable
        # from the real defect this gate exists to catch.
        #
        # \u escapes are pure ASCII in the source, so no decoding step can alter them.
        # '文档' = U+6587 U+6863; '：' = U+FF1A (full-width colon).
        $m = [regex]::Match($blob, '(?im)^\s*[-*]*\s*\**(?:\u6587\u6863\s*ID|document\s*id)\**\s*[:\uFF1A]\s*`?(?<id>[0-9a-fA-F-]{36})')
        if ($m.Success) {
            $doc = $parsed | Where-Object { $_.id -eq $m.Groups['id'].Value } | Select-Object -First 1
            if ($doc) { $docSource = 'db row named in the run summary' }
        }
        if (-not $doc -and $parsed.Count -eq 1) { $doc = $parsed[0]; $docSource = 'the single row the matter holds' }
        if (-not $doc -and $parsed.Count -gt 1) { $doc = $parsed[0]; $docSource = "the newest of $($parsed.Count) rows" }
    }
    catch { $dbErr = $_.Exception.Message }

    Check 'the run CREATED a document row in the matter' ([bool]$doc) `
        "no documents row for matter $matterId. psql: $($dbErr.Substring(0, [Math]::Min(200, $dbErr.Length)))"
    if ($doc) {
        Write-Host "         document: $($doc.name) (chose $docSource)" -ForegroundColor DarkGray

        $apiDoc = $null
        try { $apiDoc = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$($doc.id)" -Method Get -Headers $H -TimeoutSec 30 } catch { }
        Check 'the created document id resolves through GET /api/documents/:id' ([bool]$apiDoc) `
            "GET /api/documents/$($doc.id) did not return a document"
        if ($apiDoc) {
            Check 'the document belongs to the matter it was generated into' ($apiDoc.matter_id -eq $matterId) `
                "document.matter_id=$($apiDoc.matter_id) but the run used $matterId"
            Check 'the document records a storage_path' ([bool]$apiDoc.storage_path) 'storage_path was empty'
            Check 'the document format is docx' ($apiDoc.format -eq 'docx') "format was '$($apiDoc.format)'"
            $doc = $apiDoc     # prefer the API's view for the on-disk checks below
        }

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

# ── 9. Optional failure-rate soak ──────────────────────────────────────────────
# Placed AFTER the single-run proof and outside its try, so a soak failure cannot
# mask whether the ordinary path works, and vice versa.
if ($FailureRateRuns -gt 0) {
    $null = Measure-GenerationFailureRate -BaseUrl $BaseUrl -Headers $H -WorkflowId $WorkflowId `
        -Runs $FailureRateRuns -MaxFailures $MaxFailures -TimeoutSec $TimeoutSec
}
else {
    Write-Host ''
    Write-Host 'NOTE: the failure-rate soak was NOT run. This gate has now asserted on ONE' -ForegroundColor Yellow
    Write-Host '      generation. The 0.1.28 defect failed on 1 run in 3, so a single run' -ForegroundColor Yellow
    Write-Host '      passes a broken build about two times in three. For a release, run:' -ForegroundColor Yellow
    Write-Host "        pwsh -File $($MyInvocation.MyCommand.Path) -FailureRateRuns 8" -ForegroundColor Gray
}

Write-Host ''
Write-Host "RESULT: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
exit 0
