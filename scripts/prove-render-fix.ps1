# Demonstrate the PRE-FIX silent-drop bug vs the FIXED render-and-compare.
#
# Runs both versions of install.ps1 in isolated temp dirs and shows the
# difference on the exact scenario that mattered: a template change arriving
# after a machine has already rendered its config.
#
# Self-contained: does not rely on the caller's working directory.
$ErrorActionPreference = 'Stop'

$repoRoot = 'C:\Users\cubecloud-io\github-pr\pacgate-ai-pr'
$base = Join-Path $env:TEMP ('pg-proof-' + [guid]::NewGuid().ToString('N').Substring(0, 6))

function New-Fixture {
    param([string]$Dir, [string]$ScriptBody)

    New-Item -ItemType Directory -Path "$Dir\_stubs", "$Dir\openviking" -Force | Out-Null
    Set-Content -Path "$Dir\_stubs\docker.cmd" -Value '@echo off' -Encoding ASCII
    Set-Content -Path "$Dir\_stubs\ollama.cmd" -Value '@echo off' -Encoding ASCII
    "model-a" | Set-Content "$Dir\ollama-models.txt"
    "services: {}" | Set-Content "$Dir\compose.prod.yaml"
    "OPENVIKING_ROOT_API_KEY=0123456789abcdef0123456789abcdef" | Set-Content "$Dir\.env"

    Copy-Item "$repoRoot\deploy\client-bundle\deer-flow-extensions-config.template.json" $Dir -Force
    Copy-Item "$repoRoot\deploy\client-bundle\openviking\ov.conf.template" "$Dir\openviking\" -Force
    [System.IO.File]::WriteAllText("$Dir\install.ps1", $ScriptBody, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Version {
    # Run install.ps1 with an explicit working directory, no Push-Location.
    param([string]$Dir)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'
    $psi.Arguments = "-NoProfile -File `"$Dir\install.ps1`" -Update"
    $psi.WorkingDirectory = $Dir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    # Put the stubs on PATH for the child process.
    $psi.EnvironmentVariables['PATH'] = "$Dir\_stubs;$env:PATH"
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return ($out + $err)
}

function Add-Server {
    param([string]$Dir)
    $tplPath = "$Dir\deer-flow-extensions-config.template.json"
    $tpl = Get-Content $tplPath -Raw
    $tpl = $tpl.Replace('"mcpServers": {', '"mcpServers": {' + "`r`n    `"firecrawl`": { `"url`": `"http://firecrawl:3002/mcp`" },")
    [System.IO.File]::WriteAllText($tplPath, $tpl, [System.Text.UTF8Encoding]::new($false))
}

try {
    $oldBody = (git -C $repoRoot show 'HEAD:deploy/client-bundle/install.ps1') -join "`r`n"
    $newBody = Get-Content "$repoRoot\deploy\client-bundle\install.ps1" -Raw

    foreach ($case in @(
            @{ Name = 'PRE-FIX  (render only if absent)'; Body = $oldBody; Dir = "$base\old" }
            @{ Name = 'FIXED    (render and compare)';    Body = $newBody; Dir = "$base\new" }
        )) {

        $dir = $case.Dir
        New-Fixture -Dir $dir -ScriptBody $case.Body

        # Run 1: machine renders its config.
        $null = Invoke-Version -Dir $dir
        $rendered = "$dir\deer-flow-extensions-config.json"
        $hadFirst = Test-Path $rendered

        # Template changes upstream (the 453646f scenario).
        Add-Server -Dir $dir

        # Run 2: the update.
        $out = Invoke-Version -Dir $dir
        $nowHas = (Test-Path $rendered) -and ((Get-Content $rendered -Raw) -match 'firecrawl')
        $backup = @(Get-ChildItem $dir -Filter '*.bak.*' -ErrorAction SilentlyContinue).Count
        $reported = $out -match 'MCP servers gained'

        Write-Host ("=== {0} ===" -f $case.Name) -ForegroundColor Cyan
        Write-Host ("  first run rendered config      : {0}" -f $hadFirst)
        Write-Host ("  new server reached the config  : {0}" -f $nowHas) -ForegroundColor $(if ($nowHas) { 'Green' } else { 'Red' })
        Write-Host ("  change was REPORTED            : {0}" -f $reported) -ForegroundColor $(if ($reported) { 'Green' } else { 'Red' })
        Write-Host ("  previous version backed up     : {0}" -f ($backup -gt 0))
        Write-Host ''
    }

    Write-Host 'Interpretation:' -ForegroundColor Cyan
    Write-Host '  PRE-FIX  : new server does NOT reach the config, silently.'
    Write-Host '  FIXED    : new server reaches the config, and the change is reported.'
}
finally {
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}
