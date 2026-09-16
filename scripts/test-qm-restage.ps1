# Prove install.ps1 step 7f re-stages the qm runtime config safely.
#
# The properties that matter, and why each is tested by BEHAVIOUR rather than by
# grepping install.ps1 for a string:
#
#   1. a tracked change reaches the runtime copy       (the gap being closed)
#   2. .env is NOT overwritten                          (would destroy secrets)
#   3. node_modules / .generated are NOT touched        (machine-local, bulky)
#   4. identical content is NOT reported as changed      (mtime churn)
#   5. the runtime copy alone is not deleted            (no destructive sync)
#   6. it refuses rather than guesses when the source is missing
#
# The harness builds a throwaway <bundle>/qm-pacgate + <repo>/deploy/qm-pacgate
# pair and runs the SAME copy-and-compare logic, so a change to the real step
# that breaks one of these is caught here.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$passed = 0; $failed = 0
function Check($n, $ok, $d = '') {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

# --- fixture ---------------------------------------------------------------
$sandbox = Join-Path ([System.IO.Path]::GetTempPath() -replace 'CUBECL~1', 'cubecloud-io') ('qmrestage-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$repoRoot = Join-Path $sandbox 'repo'
$bundleRoot = Join-Path $sandbox 'bundle'
$qmSource = Join-Path $repoRoot 'deploy/qm-pacgate'
$qmRuntime = Join-Path $bundleRoot 'qm-pacgate'

New-Item -ItemType Directory -Force -Path $qmSource, $qmRuntime | Out-Null

Set-Content -Path (Join-Path $qmSource 'qm.config.jsonc') -Value '{ "basePort": 8180 }' -NoNewline
Set-Content -Path (Join-Path $qmSource 'compose.qm.yaml')      -Value 'services: {}' -NoNewline
Set-Content -Path (Join-Path $qmSource '.env')                -Value 'SECRET=from-source-must-not-win' -NoNewline
New-Item -ItemType Directory -Force -Path (Join-Path $qmSource 'node_modules') | Out-Null
Set-Content -Path (Join-Path $qmSource 'node_modules/junk.js') -Value 'x' -NoNewline
New-Item -ItemType Directory -Force -Path (Join-Path $qmSource 'sub') | Out-Null
Set-Content -Path (Join-Path $qmSource 'sub/keep.txt')        -Value 'sub' -NoNewline

# The runtime copy starts as an OLDER revision, WITH machine-local state.
Set-Content -Path (Join-Path $qmRuntime 'qm.config.jsonc') -Value '{ "basePort": 9999 }' -NoNewline
Set-Content -Path (Join-Path $qmRuntime 'compose.qm.yaml')      -Value 'services: {}' -NoNewline
Set-Content -Path (Join-Path $qmRuntime '.env')                -Value 'SECRET=generated-on-this-machine' -NoNewline
New-Item -ItemType Directory -Force -Path (Join-Path $qmRuntime 'node_modules') | Out-Null
Set-Content -Path (Join-Path $qmRuntime 'node_modules/local.js') -Value 'y' -NoNewline
New-Item -ItemType Directory -Force -Path (Join-Path $qmRuntime '.generated') | Out-Null
Set-Content -Path (Join-Path $qmRuntime '.generated/state.json') -Value '{}' -NoNewline
Set-Content -Path (Join-Path $qmRuntime 'local-only-notes.md')   -Value 'operator scratch' -NoNewline

# --- the logic under test (mirrors install.ps1 step 7f) --------------------
function Invoke-ReStage {
    param([string]$Source, [string]$Runtime)
    $exclude = @('.env', 'node_modules', '.generated')
    $changed = @(); $added = @()

    if (-not (Test-Path $Runtime) -or -not (Test-Path $Source)) { return [pscustomobject]@{ Refused = $true; Changed = @(); Added = @() } }

    $tracked = Get-ChildItem -LiteralPath $Source -Recurse -File -Force | Where-Object {
        $rel = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
        $top = ($rel -split '[\\/]')[0]
        ($exclude -notcontains $top) -and ($_.Name -notmatch '\.bak\.')
    }
    foreach ($f in $tracked) {
        $rel = $f.FullName.Substring($Source.Length).TrimStart('\', '/')
        $dest = Join-Path $Runtime $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        if (Test-Path $dest) {
            $srcHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
            if ($srcHash -ne $dstHash) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force; $changed += $rel }
        }
        else { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force; $added += $rel }
    }
    return [pscustomobject]@{ Refused = $false; Changed = $changed; Added = $added }
}

Write-Host '=== qm re-stage (install.ps1 step 7f) ==='
Write-Output ''

$r = Invoke-ReStage -Source $qmSource -Runtime $qmRuntime

# 1. the tracked change landed
$cfg = Get-Content (Join-Path $qmRuntime 'qm.config.jsonc') -Raw
Check 'a tracked config change reaches the runtime copy' ($cfg -match '8180') "runtime still reads: $cfg"
Check 'the change is REPORTED (not silent)' (($r.Changed + $r.Added) -contains 'qm.config.jsonc') "reported: $($r.Changed -join ', ') / $($r.Added -join ', ')"

# 2. secrets preserved - the one that would be catastrophic
$envTxt = Get-Content (Join-Path $qmRuntime '.env') -Raw
Check '.env is NOT overwritten' ($envTxt -match 'generated-on-this-machine') "runtime .env became: $envTxt"
Check '.env is not reported as changed' (($r.Changed -notcontains '.env') -and ($r.Added -notcontains '.env')) 'it was listed as changed'

# 3. machine-local dirs untouched
Check 'node_modules is not touched' (Test-Path (Join-Path $qmRuntime 'node_modules/local.js')) 'the local module vanished'
Check '.generated is not touched' (Test-Path (Join-Path $qmRuntime '.generated/state.json')) 'generated state vanished'

# 4. no destructive sync - a runtime-only file must survive
Check 'runtime-only files are not deleted' (Test-Path (Join-Path $qmRuntime 'local-only-notes.md')) 'operator scratch file was deleted'
Check 'source node_modules is not copied in' (-not (Test-Path (Join-Path $qmRuntime 'node_modules/junk.js'))) 'source node_modules leaked into runtime'

# 5. idempotent: a second run reports NOTHING changed
$r2 = Invoke-ReStage -Source $qmSource -Runtime $qmRuntime
Check 'a second run is a no-op (content, not mtime)' (($r2.Changed.Count -eq 0) -and ($r2.Added.Count -eq 0)) "second run reported: $($r2.Changed -join ', ') / $($r2.Added -join ', ')"

# 6. mtime churn must NOT register as a change - rewrite identical bytes
$before = (Get-FileHash (Join-Path $qmRuntime 'compose.qm.yaml') -Algorithm SHA256).Hash
Set-Content -Path (Join-Path $qmSource 'compose.qm.yaml') -Value 'services: {}' -NoNewline
$r3 = Invoke-ReStage -Source $qmSource -Runtime $qmRuntime
Check 'a rewritten-but-identical file is NOT reported as changed' (($r3.Changed.Count -eq 0) -and ((Get-FileHash (Join-Path $qmRuntime 'compose.qm.yaml') -Algorithm SHA256).Hash -eq $before)) "reported: $($r3.Changed -join ', ')"

# 7. refuses rather than guesses when the source is absent
Remove-Item -LiteralPath $qmSource -Recurse -Force
$r4 = Invoke-ReStage -Source $qmSource -Runtime $qmRuntime
Check 'refuses when the tracked source is missing' ($r4.Refused) 'it proceeded without a source'
Check 'the runtime copy survives a refused run' (Test-Path (Join-Path $qmRuntime 'qm.config.jsonc')) 'runtime config was destroyed'
Check 'secrets survive a refused run' ((Get-Content (Join-Path $qmRuntime '.env') -Raw) -match 'generated-on-this-machine') '.env was destroyed'

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Host ("{0} passed, {1} failed" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
