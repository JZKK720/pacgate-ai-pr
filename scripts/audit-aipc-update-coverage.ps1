# Measure the AIPC update gap: what actually updates unattended today?
#
# Read-only. Reports, for each component, whether `install.ps1 -Update`
# (pull images -> up -d -> nginx reload) is sufficient, or whether a human must
# intervene. The end-goal is unattended updates, so every "HUMAN" row is a gap.
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    Write-Output '=== AIPC update coverage: what reaches a running machine? ==='
    Write-Output ''

    # Bind mounts come from the repo working tree, so they only change on git pull.
    $compose = 'deploy/client-bundle/compose.prod.yaml'
    $binds = Select-String -Path $compose -Pattern '^\s+- (\./[^:]+):([^:]+)(:ro)?' -AllMatches
    $rows = @()
    foreach ($m in $binds) {
        $src = $m.Matches[0].Groups[1].Value
        $dest = $m.Matches[0].Groups[2].Value
        # Classify by what kind of content it is.
        $kind = 'repo content'
        if ($src -match '^\./data') { $kind = 'client data (must NOT be overwritten)' }
        elseif ($src -match 'patches/') { $kind = 'python patch (needs restart)' }
        elseif ($src -match 'nginx/default\.conf') { $kind = 'nginx conf (has explicit reload)' }
        elseif ($src -match 'extensions-config\.json') { $kind = 'RENDERED (only created if absent)' }
        elseif ($src -match 'openviking') { $kind = 'runtime state' }
        $rows += [pscustomobject]@{ Source = $src; Dest = $dest; Kind = $kind }
    }

    $rows | Sort-Object Kind, Source | Format-Table -AutoSize | Out-String -Width 140

    Write-Output '=== Verdict per component ==='
    Write-Output ''
    Write-Output '  GHCR images (4)                 : OK   - `pull` + `up -d` recreates on image change'
    Write-Output '  nginx/default.conf              : OK   - install.ps1 has an explicit `nginx -s reload`'
    Write-Output '  workflows/*.yaml (15)           : OK   - bind-mounted :ro, new file is read per request'
    Write-Output '  personas/, patches/*.py         : GAP  - bind-mounted, but a swapped .py needs a RESTART'
    Write-Output '  deer-flow-config.yaml           : GAP  - bind-mounted; needs `restart deer-flow`'
    Write-Output '  extensions-config.json          : GAP  - RENDERED ONLY IF ABSENT, so template updates never land'
    Write-Output '  qm stack (7 containers)         : GAP  - not touched by install.ps1 at all'
    Write-Output '  qm sandbox image                : GAP  - localhost:5000, machine-local, cannot be pulled'
    Write-Output '  repo itself (compose, scripts)  : GAP  - install.ps1 never runs `git pull`'
    Write-Output ''
    Write-Output '=== Staleness detection ==='
    Write-Output '  No version endpoint or build marker is exposed, so a machine cannot'
    Write-Output '  tell whether it is current. Nothing to poll, nothing to alert on.'
    Write-Output ''
    Write-Output '=== Count ==='
    $gaps = ($rows | Where-Object { $_.Kind -match 'patch|RENDERED' }).Count
    Write-Output ("  bind mounts requiring human action: {0} of {1}" -f $gaps, $rows.Count)
}
finally {
    Pop-Location
}
