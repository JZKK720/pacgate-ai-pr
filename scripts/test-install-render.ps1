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
    # NOTE: this used to be `$env:PATH = "$stubDir;$env:PATH"`. That mutated the
    # CALLER's environment, and because the terminal session is persistent the
    # stub dir stayed on PATH after the test finished - where it shadowed the
    # real docker.exe. A later `docker compose config --quiet` in this session
    # then returned exit 0 having run nothing at all, which is a false pass on a
    # real validation. The stub dir is now passed to the child process only.

    # ── Fixtures ────────────────────────────────────────────────────────────
    Copy-Item (Join-Path $repoRoot 'deploy/client-bundle/install.ps1') $work
    Copy-Item (Join-Path $repoRoot 'deploy/client-bundle/deer-flow-extensions-config.template.json') $work
    # The OpenViking template is the OTHER render-and-compare lane. It was left on
    # render-IF-ABSENT while the extensions lane was fixed, so it needs the same
    # coverage: a template change must reach a machine whose .env already has the key.
    New-Item -ItemType Directory -Path (Join-Path $work 'openviking') -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'deploy/client-bundle/openviking/ov.conf.template') (Join-Path $work 'openviking')
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

    $workEnv = Join-Path $work '.env'
    function Get-WorkEnvKey([string]$key) {
        $m = Select-String -Path $workEnv -Pattern ("^\s*" + [regex]::Escape($key) + "\s*=(.*)$") | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
        return $null
    }
    function Get-WorkEnvKeyCount([string]$key) {
        return @(Select-String -Path $workEnv -Pattern ("^\s*" + [regex]::Escape($key) + "\s*=")).Count
    }

    $run = {
        param($dir)
        # Run the child with the stub directory PREPENDED to ITS OWN PATH.
        # Doing this explicitly (rather than mutating ours) keeps the caller's
        # environment clean and makes the stub visible in one place.
        #
        # The -Command fallback matters: if PATH prepending ever fails the child
        # would find the REAL docker and start touching real containers. Failing
        # loudly is the only safe behaviour for a test harness.
        $inner = @"
Set-Location '$dir'
`$env:PATH = '$stubDir;' + `$env:PATH
if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Output 'HARNESS-ERROR: no docker on PATH for the child process'
    exit 99
}
`$d = (Get-Command docker).Source
if (`$d -notlike '*_stubs*') {
    Write-Output "HARNESS-ERROR: child resolved docker to `$d, expected the stub"
    exit 98
}
`$out = & (Join-Path '$dir' 'install.ps1') -Update 6>&1 2>&1
`$out | ForEach-Object { `$_ }
"@
        $tmp = Join-Path $dir '_run.ps1'
        [System.IO.File]::WriteAllText($tmp, $inner)
        # Write-Host output goes to the Information stream, which plain `2>&1`
        # does NOT capture. Redirecting 6>&1 is required, otherwise assertions
        # on the script's messages silently see nothing and can pass for the
        # wrong reason.
        $out = & pwsh -NoProfile -File $tmp 6>&1 2>&1
        return $out
    }

    $rendered = Join-Path $work 'deer-flow-extensions-config.json'

    # ── Case 1: first run renders ───────────────────────────────────────────
    Write-Host 'CASE 1: first run renders the config'
    $out1 = & $run $work
    Check 'rendered file created' (Test-Path $rendered)
    if (Test-Path $rendered) {
        $txt = Get-Content $rendered -Raw
        Check 'placeholder substituted (no literal ${...})' (-not ($txt -match '\$\{OPENVIKING'))
        # -AsByteStream is PowerShell 7-only and throws ParameterBindingException on
        # the built-in 5.1, so this check silently did not run on a client AIPC.
        # [System.IO.File]::ReadAllBytes works on both shells.
        $head = [System.IO.File]::ReadAllBytes($rendered)
        $first3 = if ($head.Length -ge 3) { ($head[0..2] -join ',') } else { '' }
        Check 'no BOM written' (-not ($first3 -eq '239,187,191'))
    }
    Check 'first run rendered OPENVIKING_CONF_CONTENT into .env' ((Get-WorkEnvKeyCount 'OPENVIKING_CONF_CONTENT') -eq 1)
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

    # ── Case 4: the OpenViking lane reaches an already-installed machine ────
    #
    # This is the regression the extensions lane was fixed for and this lane was
    # NOT. Before the fix the guard was `-not ($envVars.ContainsKey(
    # 'OPENVIKING_CONF_CONTENT') -and $envVars[...])`, so once .env carried the key
    # the template was never read again. The concrete consequence: commit e180fc8
    # changed the VLM from gemma4:12b-it-q8_0 (13 GB) to gemma4:12b-it-qat (7.2 GB)
    # on 2026-09-21, and every machine that had already rendered kept q8_0 -
    # silently, across every later -Update.
    #
    # Case 4 pins the KEY property: a template change is applied to a .env that
    # ALREADY has the key. Using a model-tag change makes the failure mode concrete
    # (that is the real historical drift) rather than a synthetic marker.
    Write-Host 'CASE 4: OpenViking template change reaches an already-installed machine'
    $ovBefore = Get-WorkEnvKey 'OPENVIKING_CONF_CONTENT'
    Check 'OPENVIKING_CONF_CONTENT present before the change' ($null -ne $ovBefore)
    Check '...and is a single line (not appended twice)' ((Get-WorkEnvKeyCount 'OPENVIKING_CONF_CONTENT') -eq 1)

    # Rewrite the template's VLM tag, exactly as e180fc8 did.
    $ovTplPath = Join-Path $work 'openviking/ov.conf.template'
    $ovTpl = Get-Content $ovTplPath -Raw -Encoding UTF8
    $ovTpl = $ovTpl.Replace('gemma4:12b-it-qat', 'gemma4:12b-it-q8_0')
    [System.IO.File]::WriteAllText($ovTplPath, $ovTpl, [System.Text.UTF8Encoding]::new($false))

    $out4 = & $run $work
    $out4txt = $out4 -join "`n"
    $ovAfter = Get-WorkEnvKey 'OPENVIKING_CONF_CONTENT'
    Check 'template change WAS applied to .env (the defect was that it was not)' ($ovAfter -match 'q8_0')
    Check 'stale value is GONE (no duplicate line left above)' ((Get-WorkEnvKeyCount 'OPENVIKING_CONF_CONTENT') -eq 1)
    Check 'CHANGE IS REPORTED (not silent)' ($out4txt -match 'from template')
    Check 'named the VLM model' ($out4txt -match 'OpenViking VLM now')

    # Idempotency: an unchanged template must not rewrite .env.
    $envMtime = (Get-Item $workEnv).LastWriteTimeUtc
    Start-Sleep -Milliseconds 1100
    $out5 = & $run $work
    Check 'unchanged run does NOT rewrite .env (idempotent)' ((Get-Item $workEnv).LastWriteTimeUtc -eq $envMtime) `
        'a rewrite on every run would churn the file and could re-order/fuse lines'
    Check 'reports the OpenViking config already current' (($out5 -join "`n") -match 'OPENVIKING_CONF_CONTENT already current')

    # The unrelated keys must survive the in-place rewrite.
    Check 'unrelated .env keys preserved' (
        ($null -ne (Get-WorkEnvKey 'PACGATE_JWT_SECRET')) -and
        ($null -ne (Get-WorkEnvKey 'OPENVIKING_API_KEY')) -and
        ($null -ne (Get-WorkEnvKey 'OPENVIKING_ROOT_API_KEY'))
    )
    Write-Host ''

    Write-Host "RESULT: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit 1 }
