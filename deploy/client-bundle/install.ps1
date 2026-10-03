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
#   - NEVER proceed with local changes to TRACKED files. Refuse and name them.
#     No auto-stash, no reset, no checkout -- all would discard someone's work.
#   - Untracked files are NOT a reason to block the refresh: git fast-forwards
#     over them. The ONE exception is a name collision, where the incoming
#     commit adds a path that is untracked here - git refuses that itself, and
#     this script pre-checks it so the operator gets an actionable message.
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
            # A dirty tree means someone edited TRACKED files. Do NOT touch it.
            #
            # TRACKED AND UNTRACKED ARE DIFFERENT RISKS, and treating them the
            # same was a real defect in the update path:
            #
            #   tracked changes   - the pull would have to merge over someone's
            #                       edits. Refuse. Never auto-stash.
            #   untracked files   - git will fast-forward happily UNLESS the
            #                       incoming commit adds a path of the same name,
            #                       in which case git refuses by itself (see
            #                       below). A scratch file is not a reason to
            #                       block the whole repo refresh.
            #
            # The old guard was a bare `git status --porcelain`, so ONE leftover
            # scratch file made every update print "skipping the repo update" and
            # move only the images. That is a silent lost update: image tags
            # advance, workflows/patches/nginx.conf silently stay old, and
            # nothing surfaces the gap. The dev box for this project hit exactly
            # that state (2 untracked files, repo refresh skipped), which is how
            # this was found.
            #
            # `--untracked-files=no` is what narrows the check to tracked state.
            $dirty = @(git status --porcelain --untracked-files=no)
            if ($dirty.Count -gt 0) {
                Write-Host "[WARN] Repo has local changes to tracked files - skipping the repo update." -ForegroundColor Yellow
                Write-Host "  Not modifying anything, because that could discard work. Changed files:" -ForegroundColor Yellow
                $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
                if ($dirty.Count -gt 10) {
                    Write-Host "    ... and $($dirty.Count - 10) more" -ForegroundColor DarkYellow
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
                        # ── Untracked-file collision pre-check ──────────────────
                        # Do not let git abort mid-pull. Detect the one untracked
                        # case that genuinely cannot proceed, name those files,
                        # and skip the repo refresh - so the operator gets an
                        # actionable message instead of a git error.
                        #
                        # ONLY a genuine collision blocks. An untracked file that
                        # the incoming commit does NOT touch is left alone: git
                        # fast-forwards over it, and refusing would re-create the
                        # silent-lost-update defect described above.
                        #
                        # Detection is by PATH COMPARISON, not by matching git's
                        # error text. The message ("would be overwritten by
                        # merge") is localized and unstable across git versions,
                        # so parsing it is a trap; the file lists are not.
                        #
                        # -c core.quotepath=false is required: without it git
                        # C-quotes non-ASCII paths ("\346\263\225...") and the
                        # comparison against the real name silently fails. This
                        # repo contains Chinese-named files, so that is not
                        # hypothetical. ls-files is used instead of status
                        # because status COLLAPSES whole untracked directories to
                        # "dir/" and the names would never match.
                        $untracked = @(git -c core.quotepath=false ls-files --others --exclude-standard 2>$null | Where-Object { $_ })
                        $collisions = @()
                        if ($untracked.Count -gt 0) {
                            $incoming = @(git -c core.quotepath=false diff --name-only --diff-filter=A "$before" "$remoteRef" 2>$null | Where-Object { $_ })
                            $collisions = @($untracked | Where-Object { $incoming -contains $_ })
                        }

                        if ($collisions.Count -gt 0) {
                            Write-Host "[WARN] Cannot refresh the repo: $($collisions.Count) untracked file(s) would be overwritten." -ForegroundColor Yellow
                            Write-Host "  The incoming update adds files with the same names. Git will not" -ForegroundColor Yellow
                            Write-Host "  destroy untracked work, and neither will this installer. Files:" -ForegroundColor Yellow
                            $collisions | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
                            if ($collisions.Count -gt 10) {
                                Write-Host "    ... and $($collisions.Count - 10) more" -ForegroundColor DarkYellow
                            }
                            Write-Host "  Move, rename, or commit them, then re-run to pick up repo updates." -ForegroundColor Yellow
                            Write-Host "  Only Docker images are being updated in the meantime." -ForegroundColor Yellow
                        }
                        else {
                            # Report the untracked files that are being KEPT, so
                            # proceeding is never silent - the same principle as
                            # naming the changed files below.
                            if ($untracked.Count -gt 0) {
                                Write-Host "[OK] $($untracked.Count) untracked file(s) present; none are touched by this update." -ForegroundColor Green
                            }

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

# 4c. Derive GATEWAY_CORS_ORIGINS (browser sign-in/register gate).
#
# The gateway rejects auth POSTs whose Origin header is not in this list
# (csrf_middleware is_allowed_auth_origin). Browsers ALWAYS send Origin on
# POST, so a user browsing http://<machine-host>:8089 gets 403 "Cross-site
# auth request denied." on EVERY sign-in and registration attempt when the
# list is localhost-only - the compose default. Verified 2026-09-20:
#   POST /api/v1/auth/login/local with Origin http://192.168.8.88:8089 -> 403
#   same POST with Origin http://localhost:8089 -> 401 (gate passed)
# The same-origin escape does NOT work behind our ingress chain (nginx ->
# Next.js rewrite -> gateway): Next.js rewrites Host to the gateway's
# authority, so the gateway can never see the browser's LAN host.
#
# This step auto-derives the machine's own browser origins and appends them
# to .env when the operator has not set GATEWAY_CORS_ORIGINS. Existing
# values are NEVER overwritten - a machine whose operator deliberately set
# the list keeps it; a localhost-only value earns a loud warning instead.
$gwCors = if ($envVars.ContainsKey('GATEWAY_CORS_ORIGINS')) { $envVars['GATEWAY_CORS_ORIGINS'] } else { $null }
if ([string]::IsNullOrWhiteSpace($gwCors)) {
    # Derive this machine's browser origins. The browser may reach the
    # ingress via ANY of: hostname, every non-loopback IPv4, or localhost.
    # Each is http://<host>:<nginx-host-port>. The port must be DERIVED
    # (docker compose port nginx 80), not hardcoded - this dev box publishes
    # 8081 while compose declares 8089, and an AIPC may have either.
    $corsPort = $null
    try {
        $corsPortOut = (docker compose -f compose.prod.yaml port nginx 80 2>$null | Out-String).Trim()
        if ($corsPortOut -match ':(\d+)\s*$') { $corsPort = $Matches[1] }
    } catch { $corsPort = $null }
    if (-not $corsPort) { $corsPort = '8089' }

    $corsHosts = New-Object System.Collections.Generic.List[string]
    $corsHosts.Add('localhost')
    try { $corsHosts.Add(([System.Net.Dns]::GetHostName()).ToLower()) } catch { }
    try {
        $lanIps = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
            ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
            Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            ForEach-Object { $_.Address.ToString() } |
            Where-Object { $_ -notmatch '^(127\.|169\.254\.)' }
        foreach ($ip in $lanIps) { if (-not $corsHosts.Contains($ip)) { $corsHosts.Add($ip) } }
    } catch { }

    $derivedOrigins = ($corsHosts | ForEach-Object { "http://$_`:$corsPort" }) -join ','
    # Compose reads ${GATEWAY_CORS_ORIGINS:-...} - the value must be SET in
    # .env so it overrides the compose default, which is localhost-only.
    $rawEnv = [System.IO.File]::ReadAllText((Resolve-Path $envPath))
    $prefix = if ($rawEnv.Length -eq 0 -or $rawEnv.EndsWith("`n")) { '' } else { "`r`n" }
    [System.IO.File]::AppendAllText(
        (Resolve-Path $envPath),
        "$prefix" + "GATEWAY_CORS_ORIGINS=$derivedOrigins`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    $envVars['GATEWAY_CORS_ORIGINS'] = $derivedOrigins
    Write-Host "[OK] Derived GATEWAY_CORS_ORIGINS for this machine: $derivedOrigins" -ForegroundColor Green
    Write-Host "     Browser sign-in/register now accepts this machine's hostname and LAN IP." -ForegroundColor Gray
    if ($corsPort -ne '8089') {
        Write-Host "     NOTE: the ingress port is $corsPort (not the default 8089); origins use it." -ForegroundColor Gray
    }
}
else {
    $corsSet = $gwCors.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $onlyLocal = ($corsSet.Count -gt 0) -and -not ($corsSet | Where-Object { $_ -notmatch '^http://(localhost|127\.0\.0\.1)' })
    if ($onlyLocal) {
        # Loud, specific, actionable: this exact value produces the 403 that
        # looks like a broken auth service. The check cannot auto-fix it -
        # an operator who SET the value may be deliberately restricting access.
        Write-Host "[WARN] GATEWAY_CORS_ORIGINS is localhost-only ($gwCors)." -ForegroundColor Yellow
        Write-Host "       Users browsing http://<machine-host>:8089 will get 403 on sign-in" -ForegroundColor Yellow
        Write-Host "       and registration ('Cross-site auth request denied.')." -ForegroundColor Yellow
        Write-Host "       Fix: add this machine's browser origin to .env, e.g." -ForegroundColor Yellow
        $fixHost = try { [System.Net.Dns]::GetHostName().ToLower() } catch { '<machine-host>' }
        Write-Host "         GATEWAY_CORS_ORIGINS=http://${fixHost}:8089,$gwCors" -ForegroundColor Gray
        Write-Host "       then re-run this script." -ForegroundColor Yellow
    }
    else {
        Write-Host "[OK] GATEWAY_CORS_ORIGINS set: $gwCors" -ForegroundColor Green
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

# 6b. Provision the matter that deer-flow's memory adapter is scoped to.
#
# WHY THIS EXISTS, and why it runs BEFORE the stack starts.
#
# deer-flow selects its memory storage by class path and wraps the instantiation
# in a bare `except Exception` that substitutes its own FileMemoryStorage. The
# trip-wire is a missing PACGATE_MATTER_ID: the adapter raises on it, and that
# exact raise is what the fallback catches. FileMemoryStorage never calls
# pacgate-api, so it bypasses all three matter-memory guards (the 422 scope rule,
# the 64 KiB cap, and the If-Match revision guard) - each enforced server-side.
#
# So a blank matter id does NOT mean "no memory". It means UNSANITIZED memory,
# written to disk, with nothing reporting it as wrong. That happened here on
# 2026-09-19/20 and was only found by reading the files.
#
# Ordering matters as much as the value. Running this before `up -d` means
# deer-flow never starts without a real matter, so the fallback window is zero
# rather than "briefly, on first boot".
function Invoke-MatterProvision {
    param([string]$BaseUrl)

    # Read from $envVars, NOT $env:.
    #
    # install.ps1 parses .env into a local $envVars HASHTABLE (step 4b) and never
    # populates the process environment. The first version of this function read
    # $env:PACGATE_API_EMAIL, which is therefore ALWAYS empty inside the
    # installer - so the credential guard below was false, login was never even
    # attempted, and it reported "Could not authenticate" while the credentials
    # were sitting in .env and worked perfectly by hand. The failure looked like
    # a server fault; it was a wrong variable scope.
    $apiEmail    = if ($envVars.ContainsKey('PACGATE_API_EMAIL'))    { $envVars['PACGATE_API_EMAIL'] }    else { '' }
    $apiPassword = if ($envVars.ContainsKey('PACGATE_API_PASSWORD')) { $envVars['PACGATE_API_PASSWORD'] } else { '' }
    $existing    = if ($envVars.ContainsKey('PACGATE_MATTER_ID'))    { $envVars['PACGATE_MATTER_ID'] }    else { '' }

    # PACGATE_MATTER_ID may already name a real matter (a re-run, or an operator
    # who set it deliberately). Verify before creating a duplicate.
    $H = $null
    if ($apiEmail -and $apiPassword) {
        # RETRY, because /version answering is not the same as being ready to
        # authenticate. The first version polled /version for readiness and then
        # tried login exactly ONCE, which failed on the first real E2E run: the
        # container had just been recreated, nginx answered, and the API was
        # still applying migrations (they are applied at startup and logged
        # AFTER the listener binds). A single attempt turned a transient race
        # into a permanent "could not authenticate", and provisioning was
        # skipped - leaving the placeholder in place, which is the exact state
        # this whole step exists to prevent.
        #
        # 30 attempts x 4s = 120s, comfortably past the observed startup, and it
        # exits the moment one succeeds rather than always sleeping.
        $attempts = 30
        for ($i = 1; $i -le $attempts; $i++) {
            foreach ($p in @("$BaseUrl/api/auth/login", "$BaseUrl/auth/login")) {
                try {
                    $body = @{ email = $apiEmail; password = $apiPassword } | ConvertTo-Json -Compress
                    $login = Invoke-RestMethod -Uri $p -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20
                    if ($login.token) { $H = @{ Authorization = "Bearer $($login.token)" }; break }
                } catch { }
            }
            if ($H) { break }
            if ($i -lt $attempts) { Start-Sleep -Seconds 4 }
        }
    }

    if (-not $H) {
        # Do not silently continue: an unauthenticated run cannot provision, and
        # continuing would leave the blank value in place - the exact state this
        # step exists to prevent.
        Write-Host "  [WARN] Could not authenticate to the API, so no matter could be provisioned." -ForegroundColor Yellow
        Write-Host "         deer-flow will refuse to start its memory adapter and fall back to" -ForegroundColor Yellow
        Write-Host "         writing UNSANITIZED memory to disk. Set PACGATE_MATTER_ID in .env to" -ForegroundColor Yellow
        Write-Host "         a real matter id, or fix the API credentials, then re-run." -ForegroundColor Yellow
        return $false
    }

    if ($existing -and $existing.Trim().Length -gt 0) {
        try {
            $null = Invoke-RestMethod -Uri "$BaseUrl/api/matters/$existing" -Headers $H -TimeoutSec 20
            Write-Host "  [OK] PACGATE_MATTER_ID already names a real matter ($existing)" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "  [WARN] PACGATE_MATTER_ID=$existing does not resolve to a matter the API knows." -ForegroundColor Yellow
            Write-Host "         Provisioning a real one instead." -ForegroundColor Yellow
        }
    }

    try {
        $matter = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Method Post -Headers $H -TimeoutSec 20 `
            -ContentType 'application/json' `
            -Body (@{ name = 'default'; description = 'Default matter for this deployment (created by install.ps1)' } | ConvertTo-Json -Compress)
    } catch {
        Write-Host "  [WARN] matter create failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    if (-not $matter.id) {
        Write-Host "  [WARN] matter create returned no id" -ForegroundColor Yellow
        return $false
    }

    # Write it into .env so every subsequent compose run resolves the real id.
    # Rewrite in place: preserve every other line, including comments and secrets.
    $envPath = Join-Path (Get-Location) '.env'
    $lines = Get-Content $envPath
    $found = $false
    $out = foreach ($line in $lines) {
        if ($line -match '^\s*PACGATE_MATTER_ID\s*=') {
            $found = $true
            "PACGATE_MATTER_ID=$($matter.id)"
        } else { $line }
    }
    if (-not $found) { $out += "PACGATE_MATTER_ID=$($matter.id)" }
    # No BOM: docker compose chokes on a BOM in .env, and Set-Content adds one by
    # default on Windows PowerShell.
    [System.IO.File]::WriteAllLines($envPath, $out, [System.Text.UTF8Encoding]::new($false))

    # Update BOTH the local map and the process env. The map is what the rest of
    # this script reads from (step 4b parses .env once); the process env is what
    # docker compose inherits for its `${PACGATE_MATTER_ID}` substitution in this
    # same run, so the deer-flow container starts with the value rather than
    # needing a recreate afterwards.
    $envVars['PACGATE_MATTER_ID'] = $matter.id
    $env:PACGATE_MATTER_ID = $matter.id
    Write-Host "  [OK] Provisioned matter $($matter.id) and wrote it to .env" -ForegroundColor Green

    # Prove it. A write that is merely attempted is not a write that works, and
    # this whole file exists because "looks configured" hid a broken lane.
    try {
        $probe = Invoke-RestMethod -Uri "$BaseUrl/api/matters/$($matter.id)/memory" -Headers $H -TimeoutSec 20
        Write-Host "  [OK] memory endpoint reachable (revision $($probe.revision))" -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] the matter exists but its memory endpoint did not answer: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $true
}

# 6a. Bootstrap the default tenant and the admin user.
#
# WHY THIS IS HERE, and why it runs BEFORE provisioning.
#
# Nothing used to do this. A fresh install finished with ZERO users, so:
#   * login returned 401
#   * matter provisioning could not authenticate and was skipped
#   * deer-flow then started with a BLANK PACGATE_MATTER_ID, its adapter raised,
#     and get_memory_storage() silently substituted FileMemoryStorage
#   * ...which writes UNSANITIZED matter prose to disk, outside all three
#     matter-memory guards
#
# So "no admin" was not a cosmetic gap - it was the first link in the chain that
# ends with unredacted client text on disk. Found by the clean-clone proof,
# because the dev box already had an admin and could never show it.
#
# Two details are load-bearing and both were wrong in the handbook:
#
#  1. The tenant slug MUST equal PACGATE_DEFAULT_TENANT (default "default-firm").
#     The handbook inserts slug='pacgate-law', which does not match the lookup in
#     auth.rs (`get_by_slug(&state.config.default_tenant)`), so registration fails
#     with "default tenant not found: matter not found: row not found" - an error
#     that reads like a database fault and is really a naming mismatch.
#
#  2. Registration is a POST to /api/auth/register and returns 200 on success.
#     It is idempotent-safe to attempt: an existing user yields a non-2xx error
#     which this step treats as "already bootstrapped", not as a failure.
function Invoke-Bootstrap {
    param([string]$BaseUrl)

    $tenantSlug = if ($envVars.ContainsKey('PACGATE_TENANT_ID') -and $envVars['PACGATE_TENANT_ID']) {
        $envVars['PACGATE_TENANT_ID']
    } else { 'default-firm' }
    $tenantName = if ($envVars.ContainsKey('PACGATE_TENANT_NAME') -and $envVars['PACGATE_TENANT_NAME']) {
        $envVars['PACGATE_TENANT_NAME']
    } else { 'Default Firm' }
    $apiEmail    = if ($envVars.ContainsKey('PACGATE_API_EMAIL'))    { $envVars['PACGATE_API_EMAIL'] }    else { '' }
    $apiPassword = if ($envVars.ContainsKey('PACGATE_API_PASSWORD')) { $envVars['PACGATE_API_PASSWORD'] } else { '' }

    if (-not $apiEmail -or -not $apiPassword) {
        Write-Host "  [WARN] PACGATE_API_EMAIL / PACGATE_API_PASSWORD are not set in .env." -ForegroundColor Yellow
        Write-Host "         Cannot bootstrap the admin user. Set both and re-run." -ForegroundColor Yellow
        return $false
    }

    # (1) The tenant. Created via the API when possible so the row matches what
    # the API expects; falls back to the documented psql path because the tenant
    # lookup is what registration needs, and a first-run API may not expose a
    # tenant-create route at all.
    #
    # Match on SLUG, and use the same slug the lookup will use.
    $sql = "INSERT INTO tenants (name, slug) SELECT '$($tenantName -replace "'","''")', '$($tenantSlug -replace "'","''")' WHERE NOT EXISTS (SELECT 1 FROM tenants WHERE slug = '$($tenantSlug -replace "'","''")');"
    $seedOut = docker exec pacgate-db psql -U pacgate -d pacgate -t -c $sql 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] tenant '$tenantSlug' present (created if absent)" -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] could not ensure the tenant: $($seedOut -join ' ')" -ForegroundColor Yellow
        return $false
    }

    # (2) The admin. Retry, because the API may still be applying migrations.
    $registered = $false
    $alreadyThere = $false
    for ($i = 1; $i -le 15; $i++) {
        $resp = $null
        try {
            $resp = Invoke-WebRequest -Uri "$BaseUrl/api/auth/register" -Method Post `
                -Body (@{ email = $apiEmail; password = $apiPassword } | ConvertTo-Json -Compress) `
                -ContentType 'application/json' -TimeoutSec 20 -SkipHttpErrorCheck
        } catch { }
        if ($resp) {
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { $registered = $true; break }
            # A duplicate is success for our purpose: the admin exists.
            if ($resp.StatusCode -eq 409 -or "$($resp.Content)" -match 'already|exists|duplicate') {
                $alreadyThere = $true; break
            }
        }
        if ($i -lt 15) { Start-Sleep -Seconds 4 }
    }

    if ($registered) {
        Write-Host "  [OK] admin '$apiEmail' registered" -ForegroundColor Green
        return $true
    }
    if ($alreadyThere) {
        Write-Host "  [OK] admin '$apiEmail' already exists" -ForegroundColor Green
        return $true
    }
    Write-Host "  [WARN] could not register the admin '$apiEmail'." -ForegroundColor Yellow
    Write-Host "         Matter provisioning will fail without a login. Check the API logs." -ForegroundColor Yellow
    return $false
}

Write-Host "`nBootstrapping the default tenant and admin user..." -ForegroundColor Cyan
# Same nginx-fronted path as provisioning: the API publishes no host port.
$bootstrapped = $false
docker compose -f compose.prod.yaml up -d pacgate-api pacgate-db nginx 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
$apiUp = $false
foreach ($attempt in 1..30) {
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:8089/version" -TimeoutSec 5
        $apiUp = $true; break
    } catch { Start-Sleep -Seconds 2 }
}
if ($apiUp) {
    $bootstrapped = Invoke-Bootstrap -BaseUrl 'http://localhost:8089/pacgate'
}
else {
    Write-Host "  [WARN] the API did not become reachable in 60s; skipping bootstrap." -ForegroundColor Yellow
}

# 6b. Provision the matter deer-flow's memory adapter is scoped to.
#
# Runs AFTER 6a by necessity: provisioning authenticates, and before the bootstrap
# there is no admin to authenticate as. The ordering is the point - see the note
# at the top of 6a for the chain that a missing admin sets off.
Write-Host "`nProvisioning the matter for deer-flow memory..." -ForegroundColor Cyan
$provisioned = $false
if ($apiUp) {
    $provisioned = Invoke-MatterProvision -BaseUrl 'http://localhost:8089/pacgate'
}
else {
    Write-Host "  [WARN] the API is not reachable, so no matter could be provisioned." -ForegroundColor Yellow
    Write-Host "         Re-run .\install.ps1 -Update once the stack is healthy." -ForegroundColor Yellow
}

# 7. Start stack
Write-Host "`nStarting Pacgate-ai..." -ForegroundColor Cyan
docker compose -f compose.prod.yaml up -d
Write-Host "[OK] Stack running" -ForegroundColor Green

# 7a. Prove deer-flow is on the SANITIZED lane, not the fallback. This is the
# only check that observes the running container rather than the configuration.
if ($provisioned) {
    $lane = docker exec deer-flow sh -c 'echo $PACGATE_MATTER_ID' 2>$null
    if ($lane -and $lane.Trim().Length -gt 0) {
        Write-Host "[OK] deer-flow has PACGATE_MATTER_ID=$($lane.Trim())" -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] deer-flow is running with a BLANK PACGATE_MATTER_ID." -ForegroundColor Yellow
        Write-Host "       Its adapter raises on that, and deer-flow silently falls back to" -ForegroundColor Yellow
        Write-Host "       FileMemoryStorage - UNSANITIZED memory on disk. Check that .env" -ForegroundColor Yellow
        Write-Host "       has the value and that the container was recreated, not just restarted." -ForegroundColor Yellow
    }
}

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

# 7e. Staleness marker: report what is ACTUALLY running, not what was pulled.
#
# The failure this guards against has no other symptom. `compose pull` fetches
# new images, but the running containers keep executing the OLD ones until they
# are recreated - and on a machine where someone has been debugging, the gap can
# be days wide. Nothing errors; the app simply behaves like the old release. A
# "what am I running" answer is the difference between diagnosing that in
# seconds and a dev logging in to poke at it.
#
# The URL is <nginx-host-port>/version - NOT /build-info. nginx maps the clean
# `/version` location onto pacgate-api's /build-info, and pacgate-api itself
# publishes NO host port (`docker compose port pacgate-api` is empty), so nginx
# is the only way in from the host. Probing /build-info at the nginx port would
# hit the deer-flow frontend instead and return HTML, so the path matters.
#
# The host port is DERIVED, not assumed. compose.prod.yaml maps 8089:80, but a
# machine can legitimately remap it (the dev box for this project runs 8081),
# and a hardcoded 8089 would silently probe nothing and report "unreachable" on
# a perfectly healthy install - a false alarm that trains people to ignore the
# check. `docker compose port` answers with whatever is actually published.
#
# The response reports the version COMPILED INTO THE RUNNING BINARY, not the
# image tag. Those record what was deployed, and the failure worth catching is
# the deployed artifact disagreeing with the process actually serving traffic.
#
# Reports and never fails the install: an unreachable API during a restart is
# normal, and blocking an update on a health probe would be the wrong trade.
if ($Update) {
    Write-Host "`nChecking the running runtime version..." -ForegroundColor Cyan

    # Resolve the nginx host port. Try compose first; fall back to reading the
    # running container, which is authoritative when an override file was used.
    $frontPort = $null
    try {
        $portOut = (docker compose -f compose.prod.yaml port nginx 80 2>$null | Out-String).Trim()
        if ($portOut -match ':(\d+)\s*$') { $frontPort = $Matches[1] }
    }
    catch { }
    if (-not $frontPort) {
        try {
            $insp = docker port pacgate-nginx 2>$null
            foreach ($l in @($insp)) { if ($l -match ':(\d+)\s*$') { $frontPort = $Matches[1]; break } }
        }
        catch { }
    }
    if (-not $frontPort) { $frontPort = '8089' }  # documented default

    $versionUrl = "http://localhost:$frontPort/version"

    # Read the version compose pins, so the reported value is compared against
    # something rather than printed with nothing to check it against.
    $pinned = $null
    try {
        $composeTxt = Get-Content compose.prod.yaml -Raw
        $m = [regex]::Match($composeTxt, '(?m)^\s*image:\s*ghcr\.io/[a-z0-9\-]+/pacgate-api:(?<v>\d+\.\d+\.\d+)\s*$')
        if ($m.Success) { $pinned = $m.Groups['v'].Value }
    }
    catch { }

    $reported = $null
    $revision = $null
    foreach ($attempt in 1..3) {
        try {
            $resp = Invoke-RestMethod -Uri $versionUrl -Method Get -TimeoutSec 5
            if ($resp.version) { $reported = $resp.version; $revision = $resp.revision; break }
        }
        catch { Start-Sleep -Seconds 3 }
    }

    if ($reported) {
        $rev = if ($revision -and $revision -ne 'unknown') { $revision.Substring(0, [Math]::Min(12, $revision.Length)) } else { 'unknown' }

        # REPORT THE REVISION EVEN WHEN THE VERSION MATCHES.
        #
        # This is the one case the version comparison CANNOT catch, and it is not
        # hypothetical - it is how the current release was cut. The version is
        # baked from CARGO_PKG_VERSION, which comes from the crate manifest, while
        # the revision comes from PAC_SOURCE_REVISION, which is the commit. If a
        # release ships without bumping Cargo.toml, a machine running the PREVIOUS
        # release and one running the new one both answer the same version, and
        # that comparison says OK. The revision is the only field that differs, so
        # it is printed here rather than buried.
        #
        # The install cannot resolve this on its own: knowing whether the tag
        # implies a rebuild is a decision about the workflow (whether it bumps the
        # manifest), and that is a repo property, not a machine property.
        if ($pinned -and $reported -ne $pinned) {
            # Pulled X, running Y. Not necessarily an error - the recreate may
            # still be in flight - but it is the exact condition that presents as
            # "the update did nothing".
            Write-Host "[WARN] Running pacgate-api is $reported but compose pins $pinned." -ForegroundColor Yellow
            Write-Host "       The container has not been recreated yet. If this persists:" -ForegroundColor Yellow
            Write-Host "         docker compose -f compose.prod.yaml up -d --force-recreate pacgate-api" -ForegroundColor Gray
        }
        else {
            Write-Host "[OK] pacgate-api reports $reported (source revision $rev)" -ForegroundColor Green
            if ($rev -eq 'unknown') {
                # A missing revision means the build arg was not passed, so this
                # machine cannot state which commit it runs. Report it as the gap
                # it is rather than letting 'unknown' read as a value.
                Write-Host "       NOTE: the revision is 'unknown', so this machine cannot confirm" -ForegroundColor Yellow
                Write-Host "             WHICH commit it is running - only which version string." -ForegroundColor Yellow
                Write-Host "             A rebuild of old source at a new tag is invisible here." -ForegroundColor Yellow
            }
        }
    }
    else {
        # TWO distinct causes, and conflating them sends people down the wrong
        # path. An old image predates /build-info entirely, in which case the
        # answer is "this install is behind", not "wait for startup".
        $img = (docker inspect pacgate-api --format '{{.Config.Image}}' 2>$null | Out-String).Trim()
        Write-Host "[WARN] Could not read $versionUrl; skipping the staleness check." -ForegroundColor Yellow
        if ($img -match 'jzkk720|:0\.1\.[0-9]$') {
            Write-Host "       The running image is $img" -ForegroundColor Yellow
            Write-Host "       This image predates /version, so it cannot report its build." -ForegroundColor Yellow
        }
        else {
            Write-Host "       Expected while the stack is still starting." -ForegroundColor Yellow
        }
        Write-Host "       Check manually:  curl $versionUrl" -ForegroundColor Gray
    }
}

# 7f. Re-stage the qm runtime config from the tracked source.
#
# R2 in deploy/qm-pacgate/INTEGRATION-MAP.md, the largest remaining gap in the
# unattended-update goal. `setup-qm.ps1` stages deploy/qm-pacgate/ into this
# directory, and step 1 above refreshes the TRACKED copy on every -Update. But
# the RUNTIME copy is a different directory that nothing re-staged, so a qm
# config change reaching a deployed machine required re-running setup-qm.ps1 by
# hand - and that script prompts for admin email and bridge credentials, so it is
# not something to run unattended.
#
# There is a second, quieter consequence. `qm-sandbox-fingerprint.ps1` reads and
# writes the TRACKED qm.config.jsonc (its $qmDir is deploy/qm-pacgate), while qm
# actually RUNS the runtime copy. So the drift detector can report CURRENT while
# the config being executed is an older revision - the check inspects a different
# file than the one in play. Re-staging converges them, which is what makes the
# detector's answer meaningful.
#
# SAFE BY CONSTRUCTION:
#   - .env is EXCLUDED, so generated secrets are never overwritten.
#   - node_modules and .generated are excluded (machine-local, bulky, rebuildable).
#   - *.bak.* is excluded, so backups are not copied onto themselves.
#   - It copies FILES ONLY. No container is restarted and `qm up` is never run,
#     so the R4 contention between `qm up` and compose.qm.yaml cannot be triggered.
#
# A config change needs qm restarted to take effect, and that is deliberately
# left to the operator with the exact command printed - the same reasoning as
# step 7d's sandbox report. An unattended restart of a client's co-working stack
# is a worse failure than a precise instruction.
if ($Update) {
    $qmRuntime = Join-Path $PSScriptRoot 'qm-pacgate'
    $qmSource = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'deploy/qm-pacgate'

    if ((Test-Path $qmRuntime) -and (Test-Path $qmSource)) {
        Write-Host "`nRe-staging the qm runtime config from the tracked source..." -ForegroundColor Cyan

        $qmExclude = @('.env', 'node_modules', '.generated')
        $changed = @()
        $added = @()

        $tracked = Get-ChildItem -LiteralPath $qmSource -Recurse -File -Force | Where-Object {
            $rel = $_.FullName.Substring($qmSource.Length).TrimStart('\', '/')
            $top = ($rel -split '[\\/]')[0]
            ($qmExclude -notcontains $top) -and ($_.Name -notmatch '\.bak\.')
        }

        foreach ($f in $tracked) {
            $rel = $f.FullName.Substring($qmSource.Length).TrimStart('\', '/')
            $dest = Join-Path $qmRuntime $rel

            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

            if (Test-Path $dest) {
                # Compare CONTENT, not timestamps: a git checkout rewrites mtimes
                # on files whose bytes are identical, which would report every
                # file as changed on every update and bury the real change.
                $srcHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                $dstHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
                if ($srcHash -ne $dstHash) {
                    Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                    $changed += $rel
                }
            }
            else {
                Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                $added += $rel
            }
        }

        if ($changed.Count -eq 0 -and $added.Count -eq 0) {
            Write-Host "[OK] qm config already matches the tracked source" -ForegroundColor Green
        }
        else {
            if ($added.Count -gt 0) {
                Write-Host "  NEW tracked files staged: $($added -join ', ')" -ForegroundColor Yellow
            }
            if ($changed.Count -gt 0) {
                Write-Host "  UPDATED (were stale on this machine): $($changed -join ', ')" -ForegroundColor Yellow
            }
            Write-Host "  [ACTION] qm must be restarted to pick these up. It is NOT restarted" -ForegroundColor Yellow
            Write-Host "           automatically: an unattended restart of the co-working" -ForegroundColor Yellow
            Write-Host "           stack is not something to do blind. To apply now:" -ForegroundColor Yellow
            Write-Host "             cd qm-pacgate" -ForegroundColor Gray
            Write-Host "             docker compose -f compose.qm.yaml restart" -ForegroundColor Gray
            Write-Host "           Do NOT also run 'qm up' in the same directory - both paths" -ForegroundColor Yellow
            Write-Host "           contend for the same volumes and network (R4)." -ForegroundColor Yellow
        }

        # Secrets are preserved by design; say so, because "re-staged" could
        # otherwise read as "rese t".
        if (Test-Path (Join-Path $qmRuntime '.env')) {
            Write-Host "  (.env preserved - generated qm secrets are left untouched)" -ForegroundColor Gray
        }
    }
    elseif ((Test-Path $qmRuntime) -and -not (Test-Path $qmSource)) {
        Write-Host "`n[WARN] qm is deployed but the tracked source is missing:" -ForegroundColor Yellow
        Write-Host "       $qmSource" -ForegroundColor Yellow
        Write-Host "       Refusing to re-stage; the runtime config is left as it is." -ForegroundColor Yellow
    }
}

# 7g. Bring up qm (Runtime 3) on a FIRST install.
#
# WHY THIS IS NEW. Until 2026-10-03 the installer deliberately never started qm -
# every qm step only re-staged config and printed an instruction, because qm was
# an optional side-lane. The deployment model is now "every AIPC runs all three
# runtimes", so leaving qm down means the installer ships a stack that is missing
# a third of its product.
#
# WHY ONLY ON FIRST INSTALL, NOT -Update. A restart of the co-working stack is
# user-visible (qm is where staff work), and the R4 contention between `qm up` and
# compose.qm.yaml means an automated path has to pick one and be right. On a FIRST
# install nobody is mid-session, so there is nothing to interrupt; on -Update the
# operator may be in it. -Update therefore keeps the existing print-the-command
# behaviour, and this block only runs when the stack is not already up.
#
# It calls setup-qm.ps1 in NON-INTERACTIVE form. That script used to prompt for a
# separate bridge identity, which was wrong twice over: it required a second
# pacgate-api registration (now refused by the first-user-only gate), and qm's
# sandbox already consumes PACGATE_API_EMAIL/PASSWORD - the same service account
# deer-flow and pacgate-mcp use. setup-qm.ps1 now defaults the bridge to that
# account, so no prompt is needed and no second user is created.
if (-not $Update) {
    $qmDir  = Join-Path $PSScriptRoot 'qm-pacgate'
    $qmSetup = Join-Path $PSScriptRoot 'setup-qm.ps1'

    Write-Host "`nBringing up qm (Runtime 3 - co-working workspace)..." -ForegroundColor Cyan

    $qmAlreadyUp = @(docker ps --format '{{.Names}}' 2>$null | Select-String -SimpleMatch 'qm-').Count -gt 0
    if ($qmAlreadyUp) {
        Write-Host "[OK] qm is already running - left untouched" -ForegroundColor Green
    }
    elseif (-not (Test-Path $qmSetup)) {
        Write-Host "[WARN] setup-qm.ps1 not found; skipping Runtime 3." -ForegroundColor Yellow
    }
    else {
        if (-not (Test-Path $qmDir)) {
            # First install: bootstrap.
            #
            # The bridge is a SEPARATE, least-privilege service account, per the
            # deployment handbooks ("Pacgate bridge - a service account in
            # pacgate-api, used by the sandbox tool"). The sandbox runs
            # model-directed tool calls, so it gets its own attorney-scoped
            # credential instead of the deployment's own identity.
            #
            # Provisioning it needs an administrator, so this block:
            #   1. logs in as the admin the installer just bootstrapped,
            #   2. creates the bridge account via POST /api/auth/users (the route
            #      that exists precisely because self-registration is
            #      first-user-only),
            #   3. hands setup-qm.ps1 the bridge identity non-interactively.
            # If any step fails it falls back to running setup-qm.ps1 by hand
            # rather than guessing a credential, because a wrong bridge password
            # surfaces much later as a 401 inside a sandbox tool call.
            $qmAdmin      = if ($envVars.ContainsKey('PACGATE_API_EMAIL'))    { $envVars['PACGATE_API_EMAIL'] }    else { '' }
            $qmAdminPass  = if ($envVars.ContainsKey('PACGATE_API_PASSWORD')) { $envVars['PACGATE_API_PASSWORD'] } else { '' }
            $bridgeEmail  = 'qm-bridge@pacgate.local'
            $bridgePass   = ''
            $bridgeReady  = $false

            if (-not $qmAdmin -or -not $qmAdminPass) {
                Write-Host "[WARN] PACGATE_API_EMAIL / PACGATE_API_PASSWORD are not set in .env -" -ForegroundColor Yellow
                Write-Host "       cannot bootstrap qm non-interactively. Run .\setup-qm.ps1 by hand." -ForegroundColor Yellow
            }
            else {
                Write-Host "  provisioning the qm bridge account ('$bridgeEmail')..." -ForegroundColor Gray
                $BaseUrl = 'http://localhost:8089/pacgate'
                try {
                    $loginBody = @{ email = $qmAdmin; password = $qmAdminPass } | ConvertTo-Json -Compress
                    $login = Invoke-RestMethod -Uri "$BaseUrl/api/auth/login" -Method Post `
                        -Body $loginBody -ContentType 'application/json' -TimeoutSec 20
                    $tok = $login.token
                    if (-not $tok) { throw "login returned no token" }

                    # 32 bytes of CSPRNG hex, byte-for-byte the same construction as
                    # setup-qm.ps1's New-SecretHex.
                    #
                    # NOT inlined as a clever one-liner. The first attempt here was
                    # `-join ((New-Object byte[] 32) | ForEach-Object { RNG.GetBytes($_); $_ } |
                    # ForEach-Object { $_.ToString('x2') })`, which looked reasonable
                    # and produced SIXTY-FOUR ZEROS - the pipeline bound the byte
                    # array as a single item, so it was never filled element-wise and
                    # `.ToString('x2')` on the array yielded "0" repeated. That would
                    # have silently set a fixed all-zero bridge password. Verified by
                    # running it, not by reading it.
                    $rngBytes = New-Object byte[] 32
                    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rngBytes)
                    $bridgePass = -join ($rngBytes | ForEach-Object { $_.ToString('x2') })
                    if ($bridgePass.Length -ne 64 -or $bridgePass -match '^0+$') {
                        # Refuse to ship a credential that failed to generate. An
                        # all-zero or short password is indistinguishable from a
                        # working one until an authentication fails elsewhere.
                        throw "bridge password generation produced an invalid value (length $($bridgePass.Length))"
                    }

                    $hdr = @{ Authorization = "Bearer $tok" }
                    $createBody = @{ email = $bridgeEmail; password = $bridgePass; role = 'attorney' } | ConvertTo-Json -Compress
                    try {
                        Invoke-RestMethod -Uri "$BaseUrl/api/auth/users" -Method Post -Headers $hdr `
                            -Body $createBody -ContentType 'application/json' -TimeoutSec 20 | Out-Null
                        Write-Host "  [OK] bridge account created" -ForegroundColor Green
                        $bridgeReady = $true
                    }
                    catch {
                        # 409 = it already exists. Re-running the installer is
                        # expected, so this is not an error - but the stored
                        # password is unknown, so it must NOT be silently reused
                        # with a new one written to .env, which would leave the
                        # account and the config disagreeing.
                        $code = $_.Exception.Response.StatusCode.value__
                        if ($code -eq 409) {
                            Write-Host "  [OK] bridge account already exists" -ForegroundColor Green
                            if (Test-Path (Join-Path $qmDir '.env')) {
                                Write-Host "       (its password is whatever was set when it was created;" -ForegroundColor Gray
                                Write-Host "        qm's .env was preserved, so the two still agree)" -ForegroundColor Gray
                                $bridgeReady = $true
                            }
                            else {
                                # The account exists but there is no qm .env to read
                                # its password from, so the credential is unknown and
                                # unrecoverable: there is no reset-password route, and
                                # re-running create_user would only 409 again. Say so
                                # plainly instead of skipping bootstrapping silently,
                                # which would leave Runtime 3 down with no explanation.
                                Write-Host "[WARN] the bridge account exists but qm's .env does not, so its" -ForegroundColor Yellow
                                Write-Host "       password cannot be recovered. Runtime 3 cannot be bootstrapped" -ForegroundColor Yellow
                                Write-Host "       automatically. Either run '.\setup-qm.ps1' and enter that" -ForegroundColor Yellow
                                Write-Host "       account's existing password, or delete the account and re-run" -ForegroundColor Yellow
                                Write-Host "       this installer:" -ForegroundColor Yellow
                                Write-Host "         docker exec pacgate-db psql -U pacgate -d pacgate -c \`"DELETE FROM users WHERE email='$bridgeEmail';\`"" -ForegroundColor Gray
                            }
                        }
                        else {
                            throw "create_user returned HTTP $code"
                        }
                    }
                }
                catch {
                    Write-Host "[WARN] could not provision the bridge account: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host "       Runtime 3 will need '.\setup-qm.ps1' run by hand." -ForegroundColor Yellow
                }
            }

            if ($bridgeReady) {
                try {
                    Write-Host "  bootstrapping qm (admin=$qmAdmin, bridge=$bridgeEmail)..." -ForegroundColor Gray
                    $setupArgs = @('-NoProfile', '-File', $qmSetup, '-AdminEmail', $qmAdmin, '-BridgeEmail', $bridgeEmail)
                    if ($bridgePass) { $setupArgs += @('-BridgePassword', $bridgePass) }
                    & pwsh @setupArgs
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "[WARN] setup-qm.ps1 exited $LASTEXITCODE - Runtime 3 may not be up." -ForegroundColor Yellow
                        Write-Host "       Re-run it by hand to see the error in full." -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "[WARN] setup-qm.ps1 failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

        # Start it. `docker compose` and NOT `qm up`: the CLI's which() shells out
        # to POSIX /bin/sh, which does not exist on native Windows, so `qm up`
        # cannot run on an AIPC at all. compose bypasses that entirely and is the
        # path the project already uses (plans/010 migrated to it for this reason).
        # R4 is respected by picking exactly ONE path - compose - and never mixing.
        if (Test-Path (Join-Path $qmDir 'compose.qm.yaml')) {
            # External network/volumes are declared `external: true`, so they must
            # exist before compose will start; compose does not create them.
            docker network create qm-pacgate *>$null
            docker volume create qm-pacgate-coredata *>$null
            docker volume create qm-pacgate-pgdata *>$null

            Push-Location $qmDir
            try {
                docker compose -f compose.qm.yaml up -d
                if ($LASTEXITCODE -eq 0) {
                    Start-Sleep -Seconds 15
                    $qmUp = @(docker ps --filter 'name=qm-' --format '{{.Names}}' 2>$null).Count
                    if ($qmUp -ge 7) {
                        Write-Host "[OK] qm running ($qmUp containers)" -ForegroundColor Green
                    }
                    else {
                        Write-Host "[WARN] only $qmUp qm container(s) up (expected 7)." -ForegroundColor Yellow
                        Write-Host "       A crash-looping container is usually a config value:" -ForegroundColor Yellow
                        Write-Host "         docker logs qm-pacgate-auth --tail 30" -ForegroundColor Gray
                    }
                }
                else {
                    Write-Host "[WARN] 'docker compose -f compose.qm.yaml up -d' exited $LASTEXITCODE." -ForegroundColor Yellow
                }
            }
            finally { Pop-Location }
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