# officecli gate: the Office tooling deer-flow hands to the agent must actually work.
#
# WHY THIS EXISTS. officecli is enabled in deer-flow's extension config
# (`mcpServers.officecli`, stdio, `command: officecli`) and the smoke gate counts it
# as one of "3 MCP servers enabled". That count was its ENTIRE coverage - nothing
# exercised the tool. It is also the richest document tool in the stack: its own
# description tells the model it must validate, check for leftover placeholders and
# screenshot before delivering, and a gate that only counts it cannot know whether any
# of that is reachable.
#
# So this drives the REAL MCP stdio protocol the way deer-flow does - initialize,
# tools/list, tools/call - and asserts on documents it creates and edits:
#
#   1. the MCP handshake succeeds and the server identifies itself;
#   2. exactly the officecli tool is exposed;
#   3. create -> add -> save produces a REAL file on disk whose bytes are OOXML;
#   4. `validate` runs and reports no errors (note: the tool's own text says validate
#      passing is NOT delivery, so this is necessary and deliberately not sufficient);
#   5. `view text` returns the text that was added - proving the edit landed in the
#      document rather than in a buffer;
#   6. `get`/`query` return structured JSON, which is what the agent reads.
#
# Container-only: officecli exists ONLY in deer-flow-pacgate. If that image is not
# available locally this exits 2 (CANNOT CHECK) rather than failing.
#
# Exit 2 means CANNOT CHECK and must never be read as a failure of the code.
[CmdletBinding()]
param(
    [string]$Image = '',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot

$pass = 0; $fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:fail++
    }
}
function CannotCheck($why) {
    Write-Host "[SKIP] CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host "RESULT: $pass passed, $fail failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== officecli gate (the Office tool deer-flow gives the agent) ===' -ForegroundColor Cyan

# The image that carries officecli. Derived from the running deer-flow container when
# one is up, so the gate tests the binary the stack actually uses.
if (-not $Image) {
    try { $Image = (docker inspect deer-flow --format '{{.Config.Image}}' 2>$null | Out-String).Trim() } catch { }
}
if (-not $Image) {
    . (Join-Path $PSScriptRoot 'lib/Release-ImageState.ps1')
    $ver = Get-ReleaseVersion -RepoRoot $repoRoot
    if ($ver) { $Image = "ghcr.io/jzkk720/deer-flow-pacgate:$ver" }
}
if (-not $Image) { CannotCheck 'could not determine the deer-flow image that carries officecli' }

# Only run against an image we actually have. A release window (the tag is not built
# yet) is not a failure of officecli.
$have = (docker image inspect $Image 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { CannotCheck "$Image is not present locally (release window, or not pulled)" }
Write-Host "  image: $Image" -ForegroundColor DarkGray

$work = Join-Path ([System.IO.Path]::GetDirectoryName($PSScriptRoot)) "deploy/officecli-gate-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Invoke-OfficeCliMcp {
    param([object[]]$Commands)
    # A real MCP stdio session: initialize, the initialized notification, then one
    # tools/call per command with rising ids, then EOF.
    #
    # The JSON is BUILT WITH ConvertTo-Json, not by string concatenation. The first
    # version hand-rolled the escaping and officecli answered every call with its help
    # text - a malformed `command` looks to the tool like no command at all. Hand-rolled
    # JSON in a probe produces failures that are entirely the probe's.
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"officecli-gate","version":"1"}}}')
    [void]$lines.Add('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    $id = 2
    foreach ($c in $Commands) {
        $argv = @($c)
        $msg = @{
            jsonrpc = '2.0'
            id      = $id
            method  = 'tools/call'
            params  = @{ name = 'officecli'; arguments = @{ command = $argv } }
        }
        [void]$lines.Add(($msg | ConvertTo-Json -Depth 10 -Compress))
        $id++
    }
    $payload = $lines -join "`n"
    # -i so stdin is the session; stderr dropped because this tool warns on startup and
    # mixing warnings into the JSON stream is a probe bug, not a tool failure.
    return ($payload | docker run --rm -i -v "${work}:/w" --entrypoint sh $Image -c "OFFICECLI_SKIP_UPDATE=1 officecli mcp 2>/dev/null") | Out-String
}

# ── 1-2. Handshake and tool list ──────────────────────────────────────────────
Write-Host ''
Write-Host 'MCP: handshake and tool list'
$session = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"g","version":"1"}}}',
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
) -join "`n"
$listOut = ($session | docker run --rm -i --entrypoint sh $Image -c "OFFICECLI_SKIP_UPDATE=1 officecli mcp 2>/dev/null") | Out-String

$init = ($listOut -split "`n" | Where-Object { $_ -match '"id":1' } | Select-Object -First 1)
Check 'MCP initialize succeeds' ($init -match '"result"') "no initialize result; got: $($init.Substring(0, [Math]::Min(160, $init.Length)))"
Check 'the server identifies itself' ($init -match '"serverInfo"') "serverInfo missing from the initialize result"

$tl = ($listOut -split "`n" | Where-Object { $_ -match '"id":2' } | Select-Object -First 1)
Check 'tools/list returns the officecli tool' ($tl -match '"name":\s*"officecli"') 'the officecli tool is not advertised'
# The tool's description is the agent's instruction sheet; if it is gone the model
# loses the delivery gate (validate -> issues -> screenshot -> save).
Check 'the tool still carries its delivery-gate instructions' `
    ($tl -match 'validate' -and $tl -match 'screenshot' -and $tl -match 'save') `
    'the tool description no longer mentions validate/screenshot/save, so the agent loses the delivery gate'

# ── 3-6. A real create -> edit -> validate -> read cycle ───────────────────────
Write-Host ''
Write-Host 'MCP: create -> edit -> save -> validate -> read'
$name = 'gate.docx'
$out = Invoke-OfficeCliMcp -Commands @(
    ,@('create', "/w/$name")
    ,@('add', "/w/$name", '/body', '--type', 'paragraph', '--prop', 'text=GATEMARKER 11010519491231002X')
    ,@('save', "/w/$name")
    ,@('validate', "/w/$name", '--json')
    ,@('view', "/w/$name", 'text')
    ,@('query', "/w/$name", 'p', '--json')
)

function Get-Claim($id) {
    return (($out -split "`n") | Where-Object { $_ -match "`"id`":$id\b" } | Select-Object -First 1)
}

# officecli returns its --json payload as a STRING inside the MCP text field, so the
# quotes arrive escaped (`\u0022success\u0022`). Matching the raw line for `"success":`
# therefore fails against a perfectly good response - which is exactly how this gate
# first reported two FAILs on correct behaviour. Parse the envelope, then parse the
# text it carries; a probe that cannot read its own transport reports product failures
# it never observed.
function Get-ToolPayload($claim) {
    if (-not $claim) { return $null }
    try {
        $env = $claim | ConvertFrom-Json
        $text = [string]$env.result.content[0].text
        if (-not $text) { return $null }
        return ($text | ConvertFrom-Json)
    }
    catch { return $null }
}

$createR   = Get-Claim 2
$addR      = Get-Claim 3
$saveR     = Get-Claim 4
$validateP = Get-ToolPayload (Get-Claim 5)
$viewR     = Get-Claim 6
$queryP    = Get-ToolPayload (Get-Claim 7)

Check 'create succeeds' ($createR -match '"isError":false') "create failed: $($createR.Substring(0,[Math]::Min(200,$createR.Length)))"
Check 'add succeeds'    ($addR -match '"isError":false')    "add failed: $($addR.Substring(0,[Math]::Min(200,$addR.Length)))"
Check 'save succeeds'   ($saveR -match '"isError":false')   "save failed: $($saveR.Substring(0,[Math]::Min(200,$saveR.Length)))"

$file = Join-Path $work $name
$exists = Test-Path $file
Check 'the document EXISTS on disk after save' $exists "looked for $file"
if ($exists) {
    $item = Get-Item $file
    Check 'the document is not empty' ($item.Length -gt 0) "size was $($item.Length) bytes"
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [IO.Compression.ZipFile]::OpenRead($file)
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        $zip.Dispose()
        Check 'the file is a real OOXML package' ($names -contains 'word/document.xml') "zip entries: $($names -join ', ')"
    }
    catch { Check 'the file is a real OOXML package' $false $_.Exception.Message }
    Write-Host ("         {0} bytes at {1}" -f $item.Length, $item.Name) -ForegroundColor DarkGray
}

# validate is necessary and explicitly NOT sufficient - the tool's own text says so.
Check 'validate reports no errors' ($validateP -and $validateP.success -eq $true -and [int]$validateP.data.count -eq 0) `
    "validate did not report a clean result (errors present or unparseable)"

# The edit must be readable back out, or "save succeeded" only means a file was written.
Check 'the added text is READ BACK from the document' ($viewR -match 'GATEMARKER') `
    "view text did not return the marker; the edit may not have landed: $($viewR.Substring(0,[Math]::Min(220,$viewR.Length)))"
Check 'query returns structured JSON the agent can use' ($queryP -and $queryP.success -eq $true -and @($queryP.data.results).Count -ge 1) `
    "query did not return structured results the agent can read"

# ── Cleanup ────────────────────────────────────────────────────────────────────
if (-not $KeepArtifacts) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "  artifacts kept: $work" -ForegroundColor DarkGray }

Write-Host ''
Write-Host "RESULT: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
exit 0
