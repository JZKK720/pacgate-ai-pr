# Pacgate-ai client installer
# Usage: .\install.ps1                (first install)
#        .\install.ps1 -Update         (refresh repo, pull new images, restart)
#        .\install.ps1 -Update -SkipRepoPull
#                                      (update images only; leave the repo alone)
#
# -Update refreshes the repo working tree first (fast-forward only), because
# much of the runtime is bind-mounted from the repo. See deploy/AIPC-UPDATE-GAP-ANALYSIS.md.

param(
    [switch]$Update,
    [switch]$SkipRepoPull
)

$ErrorActionPreference = "Stop"
$DataDir = ".\data"

Write-Host "=== Pacgate-ai Installer ===" -ForegroundColor Cyan

# 1. Check Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Docker Desktop not found. Install from https://docs.docker.com/desktop/" -ForegroundColor Red
    exit 1
}
docker info *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Docker daemon not running. Start Docker Desktop." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Docker detected" -ForegroundColor Green

# 2. Check Ollama
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Ollama not found. Install from https://ollama.com" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Ollama detected" -ForegroundColor Green

# 3. Check .env
if (-not (Test-Path .env)) {
    if (Test-Path .env.example) {
        Write-Host "ERROR: .env not found. Copy .env.example to .env and fill in passwords." -ForegroundColor Red
        Write-Host "  copy .env.example .env" -ForegroundColor Yellow
        Write-Host "  # then edit .env with your values" -ForegroundColor Yellow
        exit 1
    }
}

# 3b. Refresh the repo working tree (updates only).
#
# WHY THIS EXISTS
#   This script lives at <repo>\deploy\client-bundle, and much of the runtime is
#   bind-mounted straight from the repo: compose image pins, workflows/*.yaml,
#   patches/*.py, nginx/default.conf, and the config templates. Pulling images
#   alone does NOT deliver any of those. Previously the operator had to
#   remember a separate `git pull` first - the single most easily forgotten step
#   in the update path, and when forgotten the machine silently keeps running old
#   config against new images. See deploy/AIPC-UPDATE-GAP-ANALYSIS.md.
#
# SAFETY RULES (this touches a client machine):
#   - NEVER proceed with a dirty tree. Refuse and name the files. No auto-stash,
#     no reset, no checkout -- all would discard someone's work.
#   - Fast-forward only. Never create a merge commit on a client machine.
#   - Missing git, or a non-git checkout (tarball install), is a WARNING not a
#     failure - the rest of the update still works.
#
# Runs BEFORE the config renders below, so they render from the newly pulled
# templates rather than the stale ones.
if ($Update -and -not $SkipRepoPull) {
    Write-Host "`nRefreshing repo working tree..." -ForegroundColor Cyan

    # $PSScriptRoot = <repo>\deploy\client-bundle  ->  repo root is two levels up
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "[WARN] git not found - cannot refresh the repo." -ForegroundColor Yellow
        Write-Host "  Only Docker images will be updated. If this machine needs config," -ForegroundColor Yellow
        Write-Host "  workflow, or patch changes, install Git and re-run." -ForegroundColor Yellow
    }
    elseif (-not (Test-Path (Join-Path $repoRoot '.git'))) {
        Write-Host "[WARN] $repoRoot is not a git checkout - cannot refresh." -ForegroundColor Yellow
        Write-Host "  Only Docker images will be updated." -ForegroundColor Yellow
    }
    else {
        Push-Location $repoRoot
        try {
            # A dirty tree means someone edited files here. Do NOT touch it.
            $dirty = git status --porcelain
            if ($dirty) {
                Write-Host "[WARN] Repo has local changes - skipping the repo update." -ForegroundColor Yellow
                Write-Host "  Not modifying anything, because that could discard work. Changed files:" -ForegroundColor Yellow
                $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
                if (@($dirty).Count -gt 10) {
                    Write-Host "    ... and $((@($dirty).Count) - 10) more" -ForegroundColor DarkYellow
                }
                Write-Host "  Resolve them (commit, or restore) and re-run to pick up repo updates." -ForegroundColor Yellow
            }
            else {
                $before = (git rev-parse HEAD).Trim()

                # Fetch first so we can decide without merging.
                git fetch --quiet origin 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[WARN] git fetch failed (offline?) - continuing with the current checkout." -ForegroundColor Yellow
                }
                else {
                    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
                    $remoteRef = "origin/$branch"

                    $behind = 0
                    $counts = git rev-list --left-right --count "$remoteRef...$branch" 2>$null
                    if ($LASTEXITCODE -eq 0 -and $counts) {
                        $behind = [int](($counts -split '\s+')[0])
                    }

                    if ($behind -eq 0) {
                        Write-Host "[OK] Repo already current at $($before.Substring(0,7))" -ForegroundColor Green
                    }
                    else {
                        # --ff-only: refuse rather than create a merge commit. If
                        # the local branch has diverged (commits made on the
                        # machine), this fails loudly instead of quietly
                        # rewriting history under the operator.
                        git pull --ff-only --quiet origin $branch
                        if ($LASTEXITCODE -ne 0) {
                            Write-Host "[WARN] Repo has diverged from $remoteRef - not fast-forwardable." -ForegroundColor Yellow
                            Write-Host "  Local commits exist that the remote does not have. Not merging." -ForegroundColor Yellow
                            Write-Host "  The rest of the update continues; repo content stays as-is." -ForegroundColor Yellow
                        }
                        else {
                            $after = (git rev-parse HEAD).Trim()
                            Write-Host "[OK] Repo updated $($before.Substring(0,7)) -> $($after.Substring(0,7)) ($behind commit(s))" -ForegroundColor Green

                            # Name what changed, so an update is never silent. This
                            # is the same principle as the config render below.
                            $changed = git diff --name-only "$before" "$after" 2>$null
                            if ($changed) {
                                Write-Host "     Files changed in this update:" -ForegroundColor DarkGray
                                $changed | Select-Object -First 12 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
                                if (@($changed).Count -gt 12) {
                                    Write-Host "       ... and $((@($changed).Count) - 12) more" -ForegroundColor DarkGray
                                }
                            }
                        }
                    }
                }
            }
        }
        finally {
            Pop-Location
        }
    }
}

# 4. Create data directories
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    Write-Host "[OK] Created $DataDir" -ForegroundColor Green
}
$OvDir = ".\openviking"
if (-not (Test-Path $OvDir)) {
    New-Item -ItemType Directory -Path $OvDir -Force | Out-Null
    Write-Host "[OK] Created $OvDir" -ForegroundColor Green
}

# 4b. Load .env values.
#
# Parsed ONCE here, outside the per-template guards below. It previously lived
# inside the OpenViking guard, which meant a missing `openviking/ov.conf.template`
# also silently skipped the UNRELATED deer-flow extensions render. Two renders,
# two guards.
$envPath = ".\.env"
$envVars = @{}
if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $envVars[$Matches[1]] = $Matches[2]
        }
    }
}

# 4b-i. Render OpenViking config (OPENVIKING_CONF_CONTENT) from template + secrets
$ovTemplate = ".\openviking\ov.conf.template"
if ((Test-Path $envPath) -and (Test-Path $ovTemplate)) {
    $needsRender = -not (Test-Path env:OPENVIKING_CONF_CONTENT) -and
        (-not ($envVars.ContainsKey('OPENVIKING_CONF_CONTENT') -and $envVars['OPENVIKING_CONF_CONTENT']))
    if ($needsRender -and $envVars.ContainsKey('OPENVIKING_ROOT_API_KEY') -and
        $envVars['OPENVIKING_ROOT_API_KEY'] -notmatch '^change-me') {
        $conf = Get-Content $ovTemplate -Raw
        $conf = $conf.Replace('${OPENVIKING_ROOT_API_KEY}', $envVars['OPENVIKING_ROOT_API_KEY'])
        $minified = ($conf -replace '(?m)^\s*//.*$', '' -replace '\r?\n', '' -replace '\s{2,}', ' ')
        # Append with an explicit leading newline: PowerShell 5.1's Add-Content
        # glues the new line onto the last line when .env has no trailing
        # newline, fusing e.g. OPENVIKING_API_KEY=<val> with
        # OPENVIKING_CONF_CONTENT=<json> on one line (corrupting both).
        $rawEnv = [System.IO.File]::ReadAllText((Resolve-Path $envPath))
        $prefix = if ($rawEnv.Length -eq 0 -or $rawEnv.EndsWith("`n")) { '' } else { "`r`n" }
        [System.IO.File]::AppendAllText(
            (Resolve-Path $envPath),
            "$prefix" + "OPENVIKING_CONF_CONTENT=$minified`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host "[OK] Rendered OPENVIKING_CONF_CONTENT into .env" -ForegroundColor Green
    }
}

# 4b-ii. Render deer-flow MCP extensions config (gitignored; compose mounts it :ro).
#
# Guarded by ITS OWN template, not OpenViking's - the two are unrelated.
# Without this, a fresh clone gets a Docker-created directory at the mount
# path and deer-flow's OpenViking recall (OV-2a) silently fails.
#
# RENDER-AND-COMPARE, not render-if-absent.
#
# This block previously rendered ONLY when the file was missing
# (`-not (Test-Path $dfRendered)`), which silently dropped every later
# template change. Commit 453646f added the `pacgate` MCP server (so the
# agent can query legal databases) and fixed the OpenViking X-API-Key in the
# TEMPLATE - but any machine that had already rendered kept the old file,
# retaining the broken key and never gaining pacgate. No error, no warning.
# The template changed three more times afterwards with the same outcome.
# See deploy/AIPC-UPDATE-GAP-ANALYSIS.md.
#
# Now the file is regenerated every run and compared. Identical content is a
# no-op; changed content is backed up before replacement, and the change is
# reported so an update is never silent.
$dfTemplate = ".\deer-flow-extensions-config.template.json"
$dfRendered = ".\deer-flow-extensions-config.json"
if (Test-Path $dfTemplate) {
        $dfKey = $envVars['OPENVIKING_ROOT_API_KEY']
        if (-not $dfKey -or $dfKey -match '^change-me') {
            # No usable key: we cannot render. A missing file is fatal (compose
            # mounts it :ro, so deer-flow memory recall breaks); an existing file
            # is left alone rather than failing an otherwise-good update.
            if (Test-Path $dfRendered) {
                Write-Host "[WARN] OPENVIKING_ROOT_API_KEY is unset or still 'change-me'." -ForegroundColor Yellow
                Write-Host "  Keeping the existing $dfRendered unchanged (cannot re-render without the key)." -ForegroundColor Yellow
            } else {
                Write-Host "ERROR: $dfRendered missing and OPENVIKING_ROOT_API_KEY is unset or still 'change-me'." -ForegroundColor Red
                Write-Host "  Set OPENVIKING_ROOT_API_KEY in .env, then re-run. compose.prod.yaml mounts this" -ForegroundColor Yellow
                Write-Host "  file :ro, so a missing file breaks deer-flow memory recall (OV-2a)." -ForegroundColor Yellow
                exit 1
            }
        } else {
            # The template's openviking entry uses ${OPENVIKING_ROOT_API_KEY} (the
            # server's root key), NOT ${OPENVIKING_API_KEY}. Replacing the wrong
            # placeholder is a no-op and leaves a literal ${...} in the rendered
            # file, which makes openviking return 401 and rolls back the entire MCP
            # tool load (deer-flow uses asyncio.gather). See handbook finding #2.
            $df = (Get-Content $dfTemplate -Raw).Replace('${OPENVIKING_ROOT_API_KEY}', $dfKey)

            $dfExisting = if (Test-Path $dfRendered) {
                [System.IO.File]::ReadAllText((Join-Path $PWD $dfRendered))
            } else { $null }

            # Compare with line endings normalised, so a CRLF/LF difference alone
            # does not look like a change and churn backups on every run.
            function Get-NormText([string]$s) {
                if ($null -eq $s) { return $null }
                return ($s -replace "`r`n", "`n").TrimEnd()
            }
            $dfUnchanged = ($null -ne $dfExisting) -and ((Get-NormText $dfExisting) -eq (Get-NormText $df))

            if ($dfUnchanged) {
                Write-Host "[OK] $dfRendered already current" -ForegroundColor Green
            } else {
                if ($null -ne $dfExisting) {
                    $dfStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $dfBackup = "$dfRendered.bak.$dfStamp"
                    Copy-Item -LiteralPath $dfRendered -Destination $dfBackup -Force
                    Write-Host "[OK] Previous $dfRendered backed up to $dfBackup" -ForegroundColor Green
                }

                # Write BOM-free UTF-8. PowerShell 5.1's `Set-Content -Encoding UTF8`
                # prepends a UTF-8 BOM, which deer-flow's JSON parser rejects
                # ("Unexpected UTF-8 BOM"). Use .NET WriteAllText with a no-BOM
                # UTF8Encoding so the rendered config is valid JSON.
                [System.IO.File]::WriteAllText(
                    (Join-Path $PWD $dfRendered),
                    $df,
                    [System.Text.UTF8Encoding]::new($false)
                )
                Write-Host "[OK] Rendered $dfRendered from template" -ForegroundColor Green

                # Name what changed. This is the whole point: the previous silent
                # behaviour is what let pacgate-mcp go missing unnoticed.
                $knownServers = @('openviking', 'pacgate', 'firecrawl')
                $gained = @()
                $lost = @()
                foreach ($srv in $knownServers) {
                    $needle = '"' + $srv + '"'
                    $inOld = ($null -ne $dfExisting) -and ($dfExisting -match $needle)
                    $inNew = ($df -match $needle)
                    if ($inNew -and -not $inOld) { $gained += $srv }
                    if ($inOld -and -not $inNew) { $lost += $srv }
                }
                if ($gained.Count -gt 0) {
                    Write-Host "     MCP servers gained: $($gained -join ', ')" -ForegroundColor Yellow
                }
                if ($lost.Count -gt 0) {
                    Write-Host "     MCP servers REMOVED: $($lost -join ', ') - check the template" -ForegroundColor Red
                }
            }
        }
    }

# 5. Pull models (first install only)
if (-not $Update) {
    Write-Host "`nPulling Ollama models (this takes a while on first run)..." -ForegroundColor Cyan
    foreach ($model in Get-Content ollama-models.txt) {
        if ($model -and -not $model.StartsWith("#")) {
            Write-Host "  Pulling $model..." -ForegroundColor Yellow
            ollama pull $model
        }
    }
    Write-Host "[OK] Models pulled" -ForegroundColor Green
}

# 6. Pull Docker images
Write-Host "`nPulling Docker images..." -ForegroundColor Cyan
docker compose -f compose.prod.yaml pull
Write-Host "[OK] Images pulled" -ForegroundColor Green

# 7. Start stack
Write-Host "`nStarting Pacgate-ai..." -ForegroundColor Cyan
docker compose -f compose.prod.yaml up -d
Write-Host "[OK] Stack running" -ForegroundColor Green

# 7b. Reload nginx config if it changed. The nginx service uses the stock
# nginx:1.27-alpine image with a BIND-MOUNTED ./nginx/default.conf, so `git
# pull` brings in a new config but `up -d` does NOT recreate the container or
# reload the file. Reloading makes AIPC2 pick up ingress/proxy changes (e.g.
# the resolver + variable proxy_pass fix) without a full recreate.
Write-Host "`nReloading nginx config..." -ForegroundColor Cyan
docker exec pacgate-nginx nginx -t *>$null
if ($LASTEXITCODE -eq 0) {
    docker exec pacgate-nginx nginx -s reload
    Write-Host "[OK] nginx config reloaded" -ForegroundColor Green
} else {
    Write-Host "[WARN] nginx config test failed; leaving running config unchanged" -ForegroundColor Yellow
}

# 7c. Restart services whose CODE is bind-mounted.
#
# A changed bind-mounted FILE does not alter compose config, so `up -d` does NOT
# recreate the container - and Python imports its modules at process start with
# no hot reload. Without this restart, patched code (patches/*.py) and
# deer-flow-config.yaml sit on disk doing nothing. See
# deploy/AIPC-UPDATE-GAP-ANALYSIS.md defect 3b.
#
# Only needed on -Update: a first install mounts the files before the container
# starts, so they are already in effect.
if ($Update) {
    Write-Host "`nRestarting services with bind-mounted code..." -ForegroundColor Cyan
    $dfRunning = docker compose -f compose.prod.yaml ps -q deer-flow
    if ($dfRunning) {
        docker compose -f compose.prod.yaml restart deer-flow
        Write-Host "[OK] deer-flow restarted (patches/*.py and config.yaml now in effect)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] deer-flow is not running; skipped restart" -ForegroundColor Yellow
    }
}

# 7d. Report qm sandbox drift.
#
# qm's agent executes inside a sandbox image PINNED BY DIGEST in
# deploy/qm-pacgate/qm.config.jsonc. Digest pinning is right - the isolation
# boundary should be immutable - but it means a repo update can change
# deploy/qm-pacgate/sandbox/ and the pinned image stays exactly as it was:
# the agent keeps running the OLD skills and tools, with no error. See
# plans/014 step 4.
#
# This REPORTS rather than rebuilds, deliberately:
#   - the rebuild needs Node 24 + npm + docker buildx and takes minutes;
#   - the digest must be repinned afterwards, which is a config change we should
#     not make unattended on a client machine;
#   - qm may not even be deployed on this machine.
# A wrong automatic rebuild would be a worse failure than a visible warning, so
# this makes the drift loud and leaves the decision to the operator.
if ($Update) {
    $qmScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts/qm-sandbox-fingerprint.ps1'
    # Only meaningful if this machine actually runs qm.
    if ((Test-Path $qmScript) -and (docker ps --format '{{.Names}}' 2>$null | Select-String -SimpleMatch 'qm-')) {
        Write-Host "`nChecking qm sandbox provenance..." -ForegroundColor Cyan
        $fpOut = & pwsh -NoProfile -File $qmScript -Json 2>&1
        $fp = $null
        try { $fp = ($fpOut | Out-String).Trim() | ConvertFrom-Json } catch { }
        if ($fp) {
            switch ($fp.state) {
                'CURRENT' {
                    Write-Host "[OK] qm sandbox matches its source ($($fp.fingerprint.Substring(0,12))...)" -ForegroundColor Green
                }
                'NOT_RECORDED' {
                    Write-Host "[WARN] qm sandbox image is digest-pinned with no recorded source fingerprint." -ForegroundColor Yellow
                    Write-Host "       Cannot tell whether it matches deploy/qm-pacgate/sandbox/." -ForegroundColor Yellow
                    Write-Host "       See plans/014 step 4 for the rebuild + repin procedure." -ForegroundColor Yellow
                }
                'DRIFT' {
                    Write-Host "[WARN] qm sandbox source has CHANGED since the image was pinned." -ForegroundColor Yellow
                    Write-Host "       qm is running OLD skills and tools. Rebuild + repin:" -ForegroundColor Yellow
                    Write-Host "         cd deploy\qm-pacgate" -ForegroundColor Gray
                    Write-Host "         npm exec qm -- sandbox build   # then repin the printed digest" -ForegroundColor Gray
                    Write-Host "         pwsh -File ..\..\scripts\qm-sandbox-fingerprint.ps1 -Write" -ForegroundColor Gray
                }
            }
        }
        else {
            Write-Host "[WARN] qm sandbox check produced no parseable result; skipped." -ForegroundColor Yellow
        }
    }
}

# 8. Wait for health
Write-Host "`nWaiting for services to start..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

# 9. Show status
Write-Host "`n=== Status ===" -ForegroundColor Cyan
docker compose -f compose.prod.yaml ps

Write-Host "`n=== Pacgate-ai is running ===" -ForegroundColor Green
Write-Host "Open browser to: http://localhost:8089" -ForegroundColor White
Write-Host "  /          - Landing page" -ForegroundColor Gray
Write-Host "  /api/      - Metadata API (internal)" -ForegroundColor Gray
Write-Host "  /research/  - Legal research (deer-flow)" -ForegroundColor Gray
Write-Host ""
Write-Host "QM (co-working workspace) runs separately:" -ForegroundColor Cyan
Write-Host "  1. Run .\setup-qm.ps1 to bootstrap qm" -ForegroundColor Gray
Write-Host "  2. Then: cd qm-pacgate && npm exec qm -- up" -ForegroundColor Gray
Write-Host "  3. Access: http://localhost:8182" -ForegroundColor Gray
Write-Host ""
Write-Host "Manage:" -ForegroundColor Cyan
Write-Host "  docker compose -f compose.prod.yaml logs -f    (view logs)" -ForegroundColor Gray
Write-Host "  docker compose -f compose.prod.yaml down       (stop)" -ForegroundColor Gray
Write-Host "  .\install.ps1 -Update                            (update to new version)" -ForegroundColor Gray