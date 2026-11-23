# Shared qm endpoint resolver.
#
# WHY THIS EXISTS
#
# Two gates hardcoded the qm *portal* port and kept calling it after the port
# stopped existing:
#
#   benchmark-round-trips.ps1  -QmUrl 'http://localhost:8181'   -> "[FAIL] no-response"
#   smoke-full-stack.ps1       'http://localhost:8181/healthz'  -> "[SKIP] qm not running (000)"
#
# The stack was up and healthy at the time. `qm-pacgate-core` was serving
# `{"ok":true}` on 8182. The gates were probing a service the qm 0.1.18 topology
# had deleted (portal/web-ui/admin are gone; core IS the front door), and they
# reported that deletion as "the lane is down" / "no-response".
#
# That is the exact defect class plan 035 §7.2 names: a version literal outlives
# the version. The 0.2.37 audit fixed three instances by deriving from the
# bundle pin; these two are the same failure on the port axis, and patching 8181
# -> 8182 would reproduce it at the next topology change. So this resolves from
# config, and the gates call the resolver.
#
# ORDER OF TRUTH
#   1. an explicit -QmUrl from the caller (operator override)
#   2. QM_PUBLIC_URL in the staged .env    (what the installer tells staff to type)
#   3. publicUrl in the tracked qm.config.jsonc (the shipped contract)
#   4. http://localhost:8182 - the 0.1.18 default, and the ONLY literal here
#
# Step 2 before step 3 deliberately: the staged .env is what this machine
# actually runs, and the two are allowed to differ (a client sets a hostname).

function Get-QmEndpoint {
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        [string]$QmUrl
    )

    if ($QmUrl) { return $QmUrl.TrimEnd('/') }

    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

    # 2. staged .env
    $envPath = Join-Path $RepoRoot 'deploy/client-bundle/qm-pacgate/.env'
    if (Test-Path -LiteralPath $envPath) {
        $m = [regex]::Match((Get-Content -LiteralPath $envPath -Raw), '(?m)^\s*QM_PUBLIC_URL\s*=\s*(\S+)')
        if ($m.Success) { return $m.Groups[1].Value.Trim().TrimEnd('/') }
    }

    # 3. tracked config
    $cfgPath = Join-Path $RepoRoot 'deploy/qm-pacgate/qm.config.jsonc'
    if (Test-Path -LiteralPath $cfgPath) {
        $m = [regex]::Match((Get-Content -LiteralPath $cfgPath -Raw), '"publicUrl"\s*:\s*"([^"]+)"')
        if ($m.Success) { return $m.Groups[1].Value.Trim().TrimEnd('/') }
    }

    # 4. the 0.1.18 default (basePort 8180 + 2)
    return 'http://localhost:8182'
}

# The health path is topology-dependent: the portal answered /healthz, the
# 0.1.18 core answers /readyz. Probe both so the resolver works across a
# topology change instead of silently reporting a healthy core as down.
function Get-QmHealthPath {
    [CmdletBinding()]
    param([string]$BaseUrl)

    $core = @('/readyz', '/healthz')
    foreach ($p in $core) {
        $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 8 "$BaseUrl$p" 2>&1
        if ("$code".Trim() -eq '200') { return $p }
    }
    return $null
}
