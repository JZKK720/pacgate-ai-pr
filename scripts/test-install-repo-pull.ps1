# Test the repo-refresh behaviour in the REAL install.ps1 (plan 014 step 1).
#
# Builds a local bare "origin" plus a clone, then runs the actual shipped
# install.ps1 against four scenarios. Using real local git repos rather than a
# mocked git, because the whole risk here is git's actual behaviour:
#
#   1. behind          -> fast-forwards, and names the changed files
#   2. up to date      -> no-op, reports "already current"
#   3. dirty tree      -> REFUSES, changes nothing, does not discard work
#   4. diverged        -> REFUSES to merge, keeps the local commits
#
# Case 3 and 4 are the ones that matter: this runs on a client machine, and a
# careless update would destroy someone's edits or their commits.
$ErrorActionPreference = 'Stop'

$repoRoot = 'C:\Users\cubecloud-io\github-pr\pacgate-ai-pr'
# Use a real (non-8.3) temp path. $env:TEMP expands to C:\Users\CUBECL~1\...,
# and ProcessStartInfo.WorkingDirectory rejects short names.
$base = Join-Path ([System.IO.Path]::GetTempPath() -replace 'CUBECL~1', 'cubecloud-io') ('pg-pull-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$script:pass = 0
$script:fail = 0

function Check($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $name  $detail" -ForegroundColor Red; $script:fail++ }
}

function Git {
    # NOTE: the parameter is named $GitArgs, not $Args. `$Args` is a PowerShell
    # automatic variable and a parameter of that name silently receives nothing
    # in this context, which made every call run bare `git` with no subcommand.
    param([string]$Dir, [string[]]$GitArgs)
    # Guard: ProcessStartInfo throws an opaque "directory name is invalid" if
    # WorkingDirectory is absent, which hides the real problem. Fail clearly.
    if (-not (Test-Path -LiteralPath $Dir)) {
        throw "Git helper called with a non-existent working directory: '$Dir' (git $($GitArgs -join ' '))"
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ($GitArgs -join ' ')
    $psi.WorkingDirectory = $Dir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return $o
}

function Run-Installer {
    # Run install.ps1 -Update from <clone>\deploy\client-bundle, with stubbed
    # docker/ollama so only the git logic is exercised.
    param([string]$CloneDir, [switch]$SkipRepoPull)
    $cb = Join-Path $CloneDir 'deploy\client-bundle'
    $args = "-NoProfile -File `"$cb\install.ps1`" -Update"
    if ($SkipRepoPull) { $args += " -SkipRepoPull" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'
    $psi.Arguments = $args
    $psi.WorkingDirectory = $cb
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['PATH'] = "$base\_stubs;$env:PATH"
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return $o
}

function New-Clone {
    param([string]$Name)
    $upstream = "$base\upstream-$Name"
    $clone = "$base\clone-$Name"
    New-Item -ItemType Directory -Path $upstream -Force | Out-Null
    $null = Git $upstream @('init','--quiet','--initial-branch=main')
    $null = Git $upstream @('config','user.email','t@t.t')
    $null = Git $upstream @('config','user.name','T')

    # Minimal repo shape: deploy/client-bundle + a tracked file we can change.
    New-Item -ItemType Directory -Path "$upstream\deploy\client-bundle" -Force | Out-Null
    "v1" | Set-Content "$upstream\VERSION.txt"
    "services: {}" | Set-Content "$upstream\deploy\client-bundle\compose.prod.yaml"
    "m" | Set-Content "$upstream\deploy\client-bundle\ollama-models.txt"
    '{"mcpServers":{}}' | Set-Content "$upstream\deploy\client-bundle\deer-flow-extensions-config.template.json"
    New-Item -ItemType Directory -Path "$upstream\deploy\client-bundle\openviking" -Force | Out-Null
    "conf" | Set-Content "$upstream\deploy\client-bundle\openviking\ov.conf.template"
    "OPENVIKING_ROOT_API_KEY=0123456789abcdef0123456789abcdef" | Set-Content "$upstream\deploy\client-bundle\.env"

    # The real install.ps1 under test.
    Copy-Item "$repoRoot\deploy\client-bundle\install.ps1" "$upstream\deploy\client-bundle\"

    $null = Git $upstream @('add','-A')
    $null = Git $upstream @('commit','--quiet','-m','init')

    $null = Git $base @('clone','--quiet',$upstream,$clone)
    $null = Git $clone @('config','user.email','t@t.t')
    $null = Git $clone @('config','user.name','T')

    return @{ Upstream = $upstream; Clone = $clone }
}

function Publish-Change {
    param([string]$Upstream, [string]$Content = 'v2')
    $Content | Set-Content "$Upstream\VERSION.txt"
    $null = Git $Upstream @('add','-A')
    $null = Git $Upstream @('commit','--quiet','-m','bump')
}

try {
    Write-Host '=== install.ps1 repo-refresh test (plan 014 step 1) ===' -ForegroundColor Cyan
    Write-Host "  fixture: $base"
    Write-Host ''

    # Stub docker/ollama so only the git logic runs.
    New-Item -ItemType Directory -Path "$base\_stubs" -Force | Out-Null
    Set-Content -Path "$base\_stubs\docker.cmd" -Value '@echo off' -Encoding ASCII
    Set-Content -Path "$base\_stubs\ollama.cmd" -Value '@echo off' -Encoding ASCII

    # ── CASE 1: behind -> fast-forward ──────────────────────────────────────
    Write-Host 'CASE 1: machine is behind -> fast-forwards and names the change'
    $c1 = New-Clone 'behind'
    Publish-Change $c1.Upstream 'v2'
    $out1 = Run-Installer $c1.Clone
    $ver = Get-Content "$($c1.Clone)\VERSION.txt" -Raw
    Check 'worktree advanced to the new commit' ($ver.Trim() -eq 'v2') "VERSION=$($ver.Trim())"
    Check 'reported the fast-forward' ($out1 -match 'Repo updated')
    Check 'named the changed files' ($out1 -match 'Files changed in this update')
    Write-Host ''

    # ── CASE 2: up to date -> no-op ─────────────────────────────────────────
    Write-Host 'CASE 2: machine already current -> no-op'
    $out2 = Run-Installer $c1.Clone
    Check 'reports already current' ($out2 -match 'already current')
    Write-Host ''

    # ── CASE 3: dirty tree -> refuse, discard nothing ───────────────────────
    Write-Host 'CASE 3: local uncommitted edit -> REFUSES and preserves it'
    $c3 = New-Clone 'dirty'
    Publish-Change $c3.Upstream 'v2'
    'MY IMPORTANT LOCAL EDIT' | Set-Content "$($c3.Clone)\VERSION.txt"
    $out3 = Run-Installer $c3.Clone
    $ver3 = Get-Content "$($c3.Clone)\VERSION.txt" -Raw
    Check 'local edit PRESERVED' ($ver3 -match 'MY IMPORTANT LOCAL EDIT') "got '$($ver3.Trim())'"
    Check 'warned about local changes' ($out3 -match 'local changes')
    Check 'did NOT fast-forward over the edit' (-not ($out3 -match 'Repo updated'))
    Check 'named the dirty file' ($out3 -match 'VERSION.txt')
    Write-Host ''

    # ── CASE 4: diverged -> refuse to merge ─────────────────────────────────
    Write-Host 'CASE 4: local commit exists -> REFUSES to merge, keeps the commit'
    $c4 = New-Clone 'diverged'
    'LOCAL COMMIT' | Set-Content "$($c4.Clone)\LOCAL.txt"
    $null = Git $c4.Clone @('add','-A')
    $null = Git $c4.Clone @('commit','--quiet','-m','local work')
    $localHeadBefore = (Git $c4.Clone @('rev-parse','HEAD')).Trim()
    Publish-Change $c4.Upstream 'v2'
    $out4 = Run-Installer $c4.Clone
    $localHeadAfter = (Git $c4.Clone @('rev-parse','HEAD')).Trim()
    Check 'local commit still on HEAD' ($localHeadBefore -eq $localHeadAfter)
    Check 'LOCAL.txt survived' (Test-Path "$($c4.Clone)\LOCAL.txt")
    Check 'did NOT merge' (-not ($out4 -match 'Repo updated'))
    Write-Host ''

    # ── CASE 5: -SkipRepoPull leaves the repo alone ─────────────────────────
    Write-Host 'CASE 5: -SkipRepoPull leaves the repo untouched'
    $c5 = New-Clone 'skip'
    Publish-Change $c5.Upstream 'v2'
    $out5 = Run-Installer $c5.Clone -SkipRepoPull
    $ver5 = Get-Content "$($c5.Clone)\VERSION.txt" -Raw
    Check 'repo NOT advanced' ($ver5.Trim() -eq 'v1') "VERSION=$($ver5.Trim())"
    Check 'no repo-refresh message' (-not ($out5 -match 'Refreshing repo'))
    Write-Host ''

    Write-Host "RESULT: $script:pass passed, $script:fail failed" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
}
finally {
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { exit 1 }
