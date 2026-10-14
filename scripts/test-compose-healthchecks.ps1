# Compose healthcheck and setup-token gate.
#
# WHY THIS GATE EXISTS
#
# AUDIT-2026-10-14-v0.1.29.md recorded two findings as "found and recorded, not
# fixed", and both shipped in that state for ten days:
#
#   1. No compose file declared a healthcheck, so `restart: unless-stopped` could
#      restart a STOPPED container but not a WEDGED one. `docker ps` could not
#      distinguish a working API from one that was up and answering nothing.
#   2. POST /api/v1/auth/initialize was publicly claimable on a fresh install,
#      because nothing in the bundle armed the setup-token gate that the
#      deer-flow patch already implemented.
#
# Both were fixed on 2026-10-14. This gate is what keeps them fixed: without it,
# a future compose edit that drops a healthcheck block or omits the token switch
# reintroduces the gap silently, exactly as the original omission did.
#
# ASCII ONLY, deliberately. Four scripts in this repo cannot be parsed by
# Windows PowerShell 5.1 because they hold non-ASCII literals and no UTF-8 BOM,
# and 5.1 decodes a BOM-less script using the ANSI code page. This gate must run
# on a client AIPC, which has only 5.1, so it stays 7-bit.
#
# Usage:
#   powershell -File scripts/test-compose-healthchecks.ps1
#   powershell -File scripts/test-compose-healthchecks.ps1 -Live
#
# -Live additionally runs each healthcheck VERBATIM from the rendered compose
# config against its running container. Without it, the gate is static and needs
# no stack.

param(
    # Run every rendered healthcheck against the live container as well.
    [switch]$Live
)

$ErrorActionPreference = 'Continue'
$script:fail = 0
$script:skip = 0

function Check($name, $cond) {
    if ($cond) { Write-Output "PASS: $name" }
    else { Write-Output "FAIL: $name"; $script:fail++ }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$bundle = Join-Path $repoRoot 'deploy\client-bundle'
$composeFiles = @('compose.prod.yaml', 'compose.bundle.yaml')

# The 7 first-party services that must each carry a healthcheck. `openviking` is
# deliberately absent: its image declares its own HEALTHCHECK via
# `CMD openviking-entrypoint --healthcheck`, so compose does not need to.
$mustHaveHealthcheck = @(
    'pacgate-db', 'pacgate-api', 'pacgate-mcp', 'ocr-service',
    'deer-flow', 'deer-flow-frontend', 'nginx'
)

foreach ($cf in $composeFiles) {
    $path = Join-Path $bundle $cf
    Write-Output ""
    Write-Output "== $cf =="

    if (-not (Test-Path $path)) { Write-Output "FAIL: $path not found"; $script:fail++; continue }

    # (1) It must still parse. A mis-indented insertion breaks the whole file, and
    # `docker compose config` is the only authority on that.
    $cfgJson = $null
    Push-Location $bundle
    try {
        $cfgJson = & docker compose -f $cf config --format json 2>$null
        $cfgExit = $LASTEXITCODE
    } finally { Pop-Location }

    # docker compose writes some notices to stderr; only a non-zero exit matters.
    Check "$cf parses" ($cfgExit -eq 0 -and $cfgJson)
    if ($cfgExit -ne 0 -or -not $cfgJson) { continue }

    try { $cfg = $cfgJson | ConvertFrom-Json } catch {
        Write-Output "FAIL: $cf rendered config is not JSON: $($_.Exception.Message)"
        $script:fail++; continue
    }

    $services = $cfg.services.PSObject.Properties.Name

    # (2) Every first-party service must be present AND have a healthcheck.
    foreach ($svc in $mustHaveHealthcheck) {
        if ($services -notcontains $svc) {
            Check "$cf has service $svc" $false
            continue
        }
        $hc = $cfg.services.$svc.healthcheck
        Check "$cf gives $svc a healthcheck" ($null -ne $hc)
    }

    # (3) A healthcheck that never passes marks a healthy container unhealthy
    # forever, which is worse than having none. Each probe must carry timing and a
    # retry budget - not just a test command.
    foreach ($svc in $mustHaveHealthcheck) {
        if ($services -notcontains $svc) { continue }
        $hc = $cfg.services.$svc.healthcheck
        if ($null -eq $hc) { continue }
        Check "$cf $svc healthcheck declares interval/timeout/retries" (
            $null -ne $hc.interval -and $null -ne $hc.timeout -and $null -ne $hc.retries
        )
    }

    # (4) The setup-token gate must be ARMED BY DEFAULT.
    #
    # This is the load-bearing assertion. The gate is armed when
    # PACGATE_GENERATE_SETUP_TOKEN is truthy OR PACGATE_SETUP_TOKEN is non-empty.
    # The patch treats an UNSET switch as "do not arm", so a bare passthrough of a
    # blank .env line leaves a fresh install publicly claimable - which is exactly
    # how this shipped. Asserting on the rendered default catches that directly.
    if ($services -contains 'deer-flow') {
        $dfEnv = $cfg.services.'deer-flow'.environment
        $gen = "$($dfEnv.PACGATE_GENERATE_SETUP_TOKEN)"
        $pin = "$($dfEnv.PACGATE_SETUP_TOKEN)"
        $armed = ($gen -match '^(1|true|yes)$') -or ($pin.Trim() -ne '' -and $pin -ne 'null')
        Check "$cf arms the /initialize setup-token gate by default" $armed
        if (-not $armed) {
            Write-Output "      PACGATE_GENERATE_SETUP_TOKEN='$gen'  PACGATE_SETUP_TOKEN='$pin'"
            Write-Output "      an unset switch is treated as DISABLED by the deer-flow patch,"
            Write-Output "      so a fresh install would be claimable by the first caller."
        }
    }
}

# (5) -Live: run each rendered healthcheck against its container, VERBATIM.
#
# Verbatim matters. Running a retyped copy would test the copy, not the artifact
# clients receive - and the probe commands differ per image (the API has no curl,
# the frontend has no bash) so a retyped copy is exactly where a mistake hides.
if ($Live) {
    Write-Output ""
    Write-Output "== live healthcheck execution (verbatim from the rendered config) =="

    $map = [ordered]@{
        'pacgate-db'         = 'pacgate-db'
        'pacgate-api'        = 'pacgate-api'
        'pacgate-mcp'        = 'pacgate-mcp'
        'ocr-service'        = 'ocr-service'
        'deer-flow'          = 'deer-flow'
        'deer-flow-frontend' = 'deer-flow-frontend'
        'nginx'              = 'pacgate-nginx'
    }

    Push-Location $bundle
    try { $liveCfg = (& docker compose -f compose.prod.yaml config --format json 2>$null) | ConvertFrom-Json } finally { Pop-Location }

    if (-not $liveCfg) { Write-Output 'SKIP: rendered config unavailable'; $script:skip++ }
    else {
        foreach ($svc in $map.Keys) {
            $cname = $map[$svc]
            $running = (& docker ps --filter "name=^/$cname$" --format '{{.Names}}' 2>$null)
            if (-not $running) {
                Write-Output "SKIP: $svc ($cname) is not running"
                $script:skip++
                continue
            }
            $hc = $liveCfg.services.$svc.healthcheck
            if ($null -eq $hc) { Write-Output "FAIL: $svc has no rendered healthcheck"; $script:fail++; continue }

            $test = $hc.test
            # Normalise both the string and the CMD-SHELL array forms to a shell line.
            if ($test -is [string]) { $cmd = $test }
            elseif ($test[0] -eq 'CMD-SHELL') { $cmd = $test[1] }
            else { $cmd = ($test[1..($test.Count - 1)] -join ' ') }

            # Feed the command through STDIN, NOT as an argument.
            #
            # MEASURED 2026-10-14, same script, same stack: passing $cmd as an
            # argument gives 7/7 PASS under pwsh 7 but 5 of 7 FAIL under Windows
            # PowerShell 5.1. The five failures are exactly the probes whose command
            # contains embedded double quotes - python3 -c and node -e - because 5.1
            # re-quotes them on the way to docker.exe and the inner quotes are lost.
            #
            # That is the same launcher-dependent class as DEFECT-ps51-native-stderr.md
            # and DEFECT-ps51-argumentlist-null.md: correct on the dev box's pwsh 7,
            # wrong on the client's 5.1. This gate exists to protect the client path,
            # so it must be exercised under both shells. STDIN removes the quoting
            # layer entirely and behaves identically on each.
            $cmd | & docker exec -i $cname sh 2>&1 | Out-Null
            Check "$svc healthcheck exits 0 against $cname" ($LASTEXITCODE -eq 0)
        }
    }
}

# (6) The .env.example must document the switch, or an operator cannot find it.
$envExample = Join-Path $bundle '.env.example'
if (Test-Path $envExample) {
    $txt = [System.IO.File]::ReadAllText($envExample, [System.Text.Encoding]::UTF8)
    Check ".env.example documents PACGATE_SETUP_TOKEN" ($txt -match '(?m)^\s*PACGATE_SETUP_TOKEN\s*=')
} else {
    Check ".env.example exists" $false
}

Write-Output ""
Write-Output "== RESULT: $($script:fail) failure(s), $($script:skip) skipped =="
if ($script:fail -gt 0) { exit 1 }
if ($script:skip -gt 0 -and $Live) { exit 2 }
exit 0
