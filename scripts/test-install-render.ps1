# Test the render-and-compare behaviour in the REAL install.ps1.
#
# WHY A HARNESS: install.ps1 requires Docker and Ollama. Rather than trust the
# logic by reading it, this runs the actual shipped file in a temp dir with
# stubbed `docker`/`ollama` on PATH, and asserts the three behaviours that
# matter:
#
#   1. first run        -> renders the file
#   2. unchanged run    -> NO rewrite, no backup  (idempotent)
#   3. changed template -> backs up the old file, writes the new one, and
#                          REPORTS what changed (the pacgate-mcp case)
#
# Case 3 is the regression this exists to prevent: a template change used to be
# dropped silently, which is how pacgate-mcp went missing on installed machines.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$work = Join-Path $env:TEMP ("pacgate-install-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$pass = 0
$fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $name  $detail" -ForegroundColor Red; $script:fail++ }
}

try {
    Write-Host "=== install.ps1 render-and-compare test ===" -ForegroundColor Cyan
    Write-Host "  temp dir: $work"
    Write-Host ""

    New-Item -ItemType Directory -Path $work -Force | Out-Null

    # ── Stub docker + ollama so the script can run without a daemon ─────────
    $stubDir = Join-Path $work '_stubs'
    New-Item -ItemType Directory -Path $stubDir -Force | Out-Null

    # docker stub: succeed, print nothing (so `ps -q` yields empty => "not running")
    Set-Content -Path (Join-Path $stubDir 'docker.cmd') -Value '@echo off`r`nexit /b 0' -Encoding ASCII
    Set-Content -Path (Join-Path $stubDir 'ollama.cmd') -Value '@echo off`r`nexit /b 0' -Encoding ASCII
    $env:PATH = "$stubDir;$env:PATH"

    # ── Fixtures ────────────────────────────────────────────────────────────
    Copy-Item (Join-Path $repoRoot 'deploy/client-bundle/install.ps1') $work
    Copy-Item (Join-Path $repoRoot 'deploy/client-bundle/deer-flow-extensions-config.template.json') $work
    'model-a' | Set-Content (Join-Path $work 'ollama-models.txt')
    # Minimal compose so `-f compose.prod.yaml` has a target; the stub ignores it.
    "services: {}" | Set-Content (Join-Path $work 'compose.prod.yaml')

    # .env with a usable key
    @(
        'OPENVIKING_ROOT_API_KEY=0123456789abcdef0123456789abcdef'
        'OPENVIKING_API_KEY=0123456789abcdef0123456789abcdef'
        'PACGATE_DB_PASSWORD=testpass'
        'PACGATE_JWT_SECRET=testsecret'
    ) | Set-Content (Join-Path $work '.env')

    $run = {
        param($dir)
        Push-Location $dir
        try {
            # Write-Host output goes to the Information stream, which plain
            # `2>&1` does NOT capture. Redirecting 6>&1 is required, otherwise
            # assertions on the script's messages silently see nothing and can
            # pass for the wrong reason.
            $out = & pwsh -NoProfile -File (Join-Path $dir 'install.ps1') -Update 6>&1 2>&1
            return $out
        }
        finally { Pop-Location }
    }

    $rendered = Join-Path $work 'deer-flow-extensions-config.json'

    # ── Case 1: first run renders ───────────────────────────────────────────
    Write-Host 'CASE 1: first run renders the config'
    $out1 = & $run $work
    Check 'rendered file created' (Test-Path $rendered)
    if (Test-Path $rendered) {
        $txt = Get-Content $rendered -Raw
        Check 'placeholder substituted (no literal ${...})' (-not ($txt -match '\$\{OPENVIKING'))
        Check 'no BOM written' (-not ((Get-Content $rendered -AsByteStream -TotalCount 3) -join ',' -eq '239,187,191'))
    }
    $mtime1 = if (Test-Path $rendered) { (Get-Item $rendered).LastWriteTimeUtc } else { $null }
    Write-Host ''

    # ── Case 2: unchanged run is a no-op ────────────────────────────────────
    Write-Host 'CASE 2: running again with no template change is a no-op'
    Start-Sleep -Milliseconds 1100   # ensure a rewrite would change mtime detectably
    $out2 = & $run $work
    $mtime2 = if (Test-Path $rendered) { (Get-Item $rendered).LastWriteTimeUtc } else { $null }
    Check 'file NOT rewritten (idempotent)' ($mtime1 -eq $mtime2) "mtime1=$mtime1 mtime2=$mtime2"
    Check 'no .bak created' (@(Get-ChildItem $work -Filter '*.bak.*').Count -eq 0)
    Check 'reports already-current' (($out2 -join "`n") -match 'already current')
    Write-Host ''

    # ── Case 3: template change is applied AND reported ─────────────────────
    Write-Host 'CASE 3: template change reaches an already-installed machine'
    # Inject a genuinely NEW server name. The real template already contains
    # `openviking` and `pacgate`, so adding either would not exercise the
    # gained-detection. The detection needles cover openviking/pacgate/firecrawl,
    # so inject `firecrawl` (absent from the template today) - which mirrors the
    # real 453646f scenario where `pacgate` was added to an already-rendered file.
    $tplPath = Join-Path $work 'deer-flow-extensions-config.template.json'
    $tpl = Get-Content $tplPath -Raw
    $marker = '"mcpServers": {'
    if ($tpl -notmatch [regex]::Escape($marker)) {
        Check 'template has mcpServers block' $false 'cannot inject test server'
    }
    else {
        $tpl = $tpl.Replace($marker, $marker + "`r`n    `"firecrawl`": { `"enabled`": true, `"type`": `"http`", `"url`": `"http://firecrawl:3002/mcp`" },")
        [System.IO.File]::WriteAllText($tplPath, $tpl, [System.Text.UTF8Encoding]::new($false))
    }

    $out3 = & $run $work
    $out3txt = $out3 -join "`n"
    Check 'rendered file was rewritten' ((Get-Item $rendered).LastWriteTimeUtc -ne $mtime2)
    Check 'old version backed up (.bak)' (@(Get-ChildItem $work -Filter '*.bak.*').Count -ge 1)
    Check 'CHANGE IS REPORTED (not silent)' ($out3txt -match 'MCP servers gained')
    Check 'named the gained server' ($out3txt -match 'firecrawl')
    $newTxt = Get-Content $rendered -Raw
    Check 'new content actually present in rendered file' ($newTxt -match 'firecrawl')
    Write-Host ''

    Write-Host "RESULT: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit 1 }
