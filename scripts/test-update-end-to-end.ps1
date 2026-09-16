<#
    END-TO-END acceptance test for `install.ps1 -Update`.

    WHY THIS HAS TO EXIST. Every other test in this repo tests a piece: the repo
    refresh, the config render, the restart. Plan 014's acceptance criterion is
    different and larger:

        "A machine one release behind, updated with a single command, ends up
         with the new images AND the new compose pins, patches, workflows, and
         config"

    ... and critically:

        "Template changes reach an already-installed machine (test: change the
         template, update, confirm the rendered file changed and a .bak exists)"

    No test covered that whole path. Without it there is no evidence the pieces
    compose, and the failure it guards against is the proven silent lost update:
    commit 453646f added the `pacgate` MCP server and fixed an API key in the
    TEMPLATE, and any machine that had already rendered kept the old file. No
    error. This test reproduces exactly that scenario with a real git repo.

    It uses the REAL install.ps1 with stub docker/ollama, and a REAL local git
    origin, because the risk IS git's and docker's real behaviour.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'deploy/client-bundle/install.ps1'

if (-not (Test-Path -LiteralPath $installer)) { throw "installer not found: $installer" }

$passed = 0
$failed = 0

function Assert-True {
    param([bool]$Cond, [string]$Label, [string]$Detail = '')
    if ($Cond) {
        Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host ("  [FAIL] {0}" -f $Label) -ForegroundColor Red
        if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor Gray }
        $script:failed++
    }
}

# Run git without touching our own location or $LASTEXITCODE semantics.
# Param is $GitArgs, NOT $Args - PowerShell's automatic $Args silently shadowed
# it and made every call run bare `git` with no subcommand.
function Invoke-Git {
    param([string]$WorkDir, [string[]]$GitArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.WorkingDirectory = $WorkDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($a in $GitArgs) { $psi.ArgumentList.Add($a) }
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd()
    $e = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Out = $o.Trim(); Err = $e.Trim(); Code = $p.ExitCode }
}

# Real temp path: $env:TEMP can expand to the 8.3 short name CUBECL~1, which
# ProcessStartInfo rejects as a WorkingDirectory.
$base = Join-Path ([System.IO.Path]::GetTempPath() -replace 'CUBECL~1', 'cubecloud-io') ('e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$upstream = Join-Path $base 'upstream.git'      # bare "origin"
$author = Join-Path $base 'author'              # where new releases are written
$aipc = Join-Path $base 'aipc'                  # the client machine
$stubs = Join-Path $base '_stubs'

# The fixture, parameterised so we can publish a v1 and then a v2.
function Write-BundleFiles {
    param([string]$Root, [string]$TemplateJson, [string]$ComposePin)

    # A REAL .gitignore, copied from the live tree rather than approximated.
    #
    # This started as a hand-written "*.json" and that approximation produced a
    # FALSE PASS: the ignore covered deer-flow-extensions-config.json, but the
    # backup file written by the re-render (deer-flow-extensions-config.json.bak.*)
    # is matched by `*.json` only by luck of extension and was NOT covered by the
    # real rules. Copying the real file keeps the fixture honest - if .gitignore
    # ever stops covering a file the installer generates, this test fails.
    $rootIgnore = Join-Path $repoRoot '.gitignore'
    if (Test-Path -LiteralPath $rootIgnore) {
        Copy-Item -LiteralPath $rootIgnore -Destination (Join-Path $Root '.gitignore') -Force
    }

    $cb = Join-Path $Root 'deploy/client-bundle'
    New-Item -ItemType Directory -Force -Path $cb | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $cb 'openviking') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $cb 'workflows') | Out-Null

    Copy-Item -LiteralPath $installer -Destination (Join-Path $cb 'install.ps1') -Force

    # A real template with a real placeholder, like the shipped one.
    [System.IO.File]::WriteAllText((Join-Path $cb 'deer-flow-extensions-config.template.json'), $TemplateJson,
        [System.Text.UTF8Encoding]::new($false))

    # OpenViking template so the .env render path stays exercised.
    [System.IO.File]::WriteAllText((Join-Path $cb 'openviking/ov.conf.template'),
        "{ `"root_api_key`": `"${OPENVIKING_ROOT_API_KEY}`" }", [System.Text.UTF8Encoding]::new($false))

    # .env with a usable key. Note this is a FIXTURE value, not a credential.
    # NOTE: deliberately NOT written here. `.env` is gitignored in the real repo,
    # so it is absent from a clone; Write-OperatorEnv creates it on the machine.
    # Writing it here made the fixture pass while diverging from reality.
    'model-a' | Set-Content -LiteralPath (Join-Path $cb 'ollama-models.txt')
    # Minimal compose + nginx conf; the stubs ignore them. The PIN is what the
    # test reads back to prove compose content advanced with the update.
    "services: {}`n# pin: $ComposePin" | Set-Content -LiteralPath (Join-Path $cb 'compose.prod.yaml')
    New-Item -ItemType Directory -Force -Path (Join-Path $cb 'nginx') | Out-Null
    "server {}`n" | Set-Content -LiteralPath (Join-Path $cb 'nginx/default.conf')
}

# The operator's .env. Written into the CLONE, never committed.
#
# `.env` is gitignored in the real repo (it holds client secrets), so a clone does
# NOT contain one - an operator creates it during setup. The first version of this
# fixture wrote .env in the author repo, which only worked because the fixture's
# hand-written .gitignore happened not to cover it. Once the real .gitignore was
# copied in, .env stopped being committed and the render failed for the right
# reason. Writing it into the clone is what actually happens on a machine.
function Write-OperatorEnv {
    param([string]$CloneRoot)
    $cb = Join-Path $CloneRoot 'deploy/client-bundle'
    @(
        'OPENVIKING_ROOT_API_KEY=0123456789abcdef0123456789abcdef'
        'OPENVIKING_API_KEY=0123456789abcdef0123456789abcdef'
        'PACGATE_DB_PASSWORD=fixture-not-a-real-password'
        'PACGATE_JWT_SECRET=fixture-not-a-real-secret'
    ) | Set-Content -LiteralPath (Join-Path $cb '.env')
}

function New-TemplateJson {
    param([string[]]$Servers)
    $entries = foreach ($s in $Servers) { "    { `"$s`": { `"url`": `"http://$s`" } }" }
    "{`n  `"mcpServers`": {`n" + ($entries -join ",`n") + "`n  }`n}`n"
}

function Invoke-Child {
    # Run install.ps1 in a CHILD pwsh with the stub dir prepended to the CHILD's
    # PATH only. Mutating our own PATH is how stub binaries leaked into the
    # persistent session earlier in this work and silently shadowed real docker.
    param([string]$Dir, [string[]]$InstallerArgs)

    # Build the argument list as RAW SWITCH TEXT, not as a PowerShell array.
    #
    # This was wrong and it silently invalidated most of this test. The generated
    # line was `& 'install.ps1' @('-Update')`, and `@(...)` is the ARRAY
    # SUBEXPRESSION operator, not splatting (splatting is `@variable`). So it
    # passed a one-element ARRAY as a single POSITIONAL argument, install.ps1's
    # `[switch]$Update` bound to nothing, and the script ran the FIRST-INSTALL
    # path instead of the update path.
    #
    # 12 assertions still passed, because a first install also renders the config
    # and exits 0. The test was green for the wrong reason - the exact failure
    # mode this whole session has been about. The guard assertion in STEP 2 now
    # makes "did the update path actually run" explicit so this cannot recur.
    $argText = ($InstallerArgs -join ' ')
    $inner = @"
Set-Location '$Dir'
`$env:PATH = '$stubs;' + `$env:PATH
# NOTE: `Get-Command docker -CommandType Application` returns EVERY match on
# PATH - here 3 (the stub .cmd, then the real .exe and its extensionless
# launcher). Without -First 1, `$d` is an ARRAY, and `$d.Source -notlike '*_stubs*'`
# yields an ARRAY of booleans, which is truthy regardless of contents - so the
# guard fired on a correctly-stubbed PATH and exited 98. Take the first match,
# which is the one that would actually execute.
`$d = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not `$d) { Write-Output 'HARNESS-ERROR: docker not found for child'; exit 99 }
if (`$d.Source -notlike '*_stubs*') {
    Write-Output "HARNESS-ERROR: child resolved docker to `$(`$d.Source), expected the stub"
    exit 98
}
`$out = & '$Dir\install.ps1' $argText 6>&1 2>&1
`$out | ForEach-Object { `$_ }
"@
    # The runner is written OUTSIDE the clone, not inside it.
    #
    # It was originally written to $Dir\_run.ps1 and deleted after the call - but
    # the child's dirty-tree guard runs DURING the call, while the helper still
    # exists. `git status --porcelain` lists untracked files, so the helper made
    # the tree dirty and suppressed the repo refresh this test exists to verify.
    # The failure output named it exactly: '?? deploy/client-bundle/_run.ps1'.
    #
    # Worth knowing beyond the test: ANY stray file in the repo directory (an
    # editor swap file, a log, a scratch note) blocks the repo half of -Update.
    # That is the correct safety behaviour - it refuses rather than discarding
    # work - and install.ps1 names the offending files so it is diagnosable.
    $tmp = Join-Path $base ('_run_' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.ps1')
    [System.IO.File]::WriteAllText($tmp, $inner, [System.Text.UTF8Encoding]::new($false))
    # 6>&1 is required: Write-Host goes to the Information stream and a plain
    # 2>&1 captures nothing, so assertions on the script's messages would pass
    # for the wrong reason.
    $out = & pwsh -NoProfile -File $tmp 6>&1 2>&1
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Output = ($out | Out-String); Exit = $LASTEXITCODE }
}

New-Item -ItemType Directory -Force -Path $base, $stubs | Out-Null
Set-Content -LiteralPath (Join-Path $stubs 'docker.cmd') -Value '@echo off' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $stubs 'ollama.cmd') -Value '@echo off' -Encoding ASCII

Write-Host '=== install.ps1 -Update end-to-end (real git origin) ===' -ForegroundColor Cyan
Write-Host ("  work dir: {0}" -f $base)
Write-Output ''

try {
    # ── build the origin ────────────────────────────────────────────────────
    Invoke-Git $base @('init', '--bare', '-q', '--initial-branch=main', 'upstream.git') | Out-Null
    Invoke-Git $base @('clone', '-q', 'upstream.git', 'author') | Out-Null
    Invoke-Git $author @('config', 'user.email', 'test@example.invalid') | Out-Null
    Invoke-Git $author @('config', 'user.name', 'Test Author') | Out-Null

    # v1: the template does NOT contain pacgate - this is the state a machine
    # installed BEFORE commit 453646f would have rendered.
    Write-BundleFiles -Root $author -TemplateJson (New-TemplateJson @('openviking', 'firecrawl')) -ComposePin '0.1.12'
    Invoke-Git $author @('add', '-A') | Out-Null
    Invoke-Git $author @('commit', '-q', '-m', 'v1: template without pacgate') | Out-Null
    Invoke-Git $author @('push', '-q', 'origin', 'main') | Out-Null

    # The AIPC clones v1 and the operator creates .env, as on a real machine.
    Invoke-Git $base @('clone', '-q', 'upstream.git', 'aipc') | Out-Null
    Invoke-Git $aipc @('config', 'user.email', 'aipc@example.invalid') | Out-Null
    Invoke-Git $aipc @('config', 'user.name', 'AIPC') | Out-Null
    Write-OperatorEnv -CloneRoot $aipc

    $cb = Join-Path $aipc 'deploy/client-bundle'
    $rendered = Join-Path $cb 'deer-flow-extensions-config.json'
    $composeFile = Join-Path $cb 'compose.prod.yaml'

    Write-Host 'STEP 1: machine installs at v1' -ForegroundColor White
    $r = Invoke-Child -Dir $cb -InstallerArgs @()
    Assert-True (Test-Path $rendered) 'config rendered on first install'
    if (Test-Path $rendered) {
        $v1 = [System.IO.File]::ReadAllText($rendered)
        Assert-True ($v1 -match '"openviking"') 'v1 config has openviking'
        Assert-True ($v1 -notmatch '"pacgate"') 'v1 config does NOT have pacgate (as expected for this starting state)'
    }
    Write-Output ''

    # ── publish v2: template gains pacgate + a compose pin bump ─────────────
    # This is commit 453646f replayed: a TEMPLATE change that a machine which had
    # already rendered would previously never receive.
    Write-BundleFiles -Root $author -TemplateJson (New-TemplateJson @('openviking', 'pacgate', 'firecrawl')) -ComposePin '0.1.13'
    Invoke-Git $author @('add', '-A') | Out-Null
    Invoke-Git $author @('commit', '-q', '-m', 'v2: template gains pacgate; compose pin 0.1.13') | Out-Null
    Invoke-Git $author @('push', '-q', 'origin', 'main') | Out-Null

    $headBefore = (Invoke-Git $aipc @('rev-parse', 'HEAD')).Out

    Write-Host 'STEP 2: one command - .\install.ps1 -Update' -ForegroundColor White
    $r = Invoke-Child -Dir $cb -InstallerArgs @('-Update')
    $out = $r.Output

    # Dump the child's relevant output. Without this a failure here is silent -
    # the assertions below say "did not happen" but not WHY, and the cause is
    # inside install.ps1's own messages. Diagnosing this the first time required
    # re-running by hand.
    $dbg = ($out -split "`r?`n" | Where-Object { $_ -match 'Repo|fetch|diverged|WARN|ERROR|Refresh|^\s+\?\?|^\s+\sM|^\s+M ' })
    if ($dbg) {
        Write-Host '  --- child output (repo-related) ---' -ForegroundColor DarkGray
        $dbg | Select-Object -First 18 | ForEach-Object { Write-Host ("      {0}" -f $_.TrimEnd()) -ForegroundColor DarkGray }
    }

    Assert-True ($r.Exit -eq 0) 'exit code 0' "got $($r.Exit)"

    # GUARD: prove the UPDATE path ran, not the first-install path.
    #
    # This assertion is the one that would have caught the @() mistake above. A
    # first install ALSO renders the config and exits 0, so every content
    # assertion below can pass while the thing under test was never exercised.
    # Asserting on the marker that only -Update produces is what makes the rest
    # of this test mean anything.
    Assert-True ($out -match 'Refreshing repo working tree') 'the -Update path actually ran (not a first install)'

    Assert-True ($out -match 'Repo updated') 'repo refresh reported the fast-forward'
    Assert-True ($out -match 'MCP servers gained: .*pacgate') 'the gained server is NAMED (not a silent change)'

    $headAfter = (Invoke-Git $aipc @('rev-parse', 'HEAD')).Out
    Assert-True ($headBefore -ne $headAfter) 'HEAD actually advanced'
    # Level with origin? Use rev-list --left-right --count, the same primitive
    # install.ps1 uses. The first version called
    # `git rev-parse --abbrev-ref origin/main...main`, which is not a meaningful
    # form for a three-dot range and can never match - a broken assertion, not a
    # broken implementation. Output is "<behind> <ahead>", so "0 0" is level.
    $counts = (Invoke-Git $aipc @('rev-list', '--left-right', '--count', 'origin/main...main')).Out
    Assert-True ($counts -match '^0\s+0$') 'now level with origin/main (0 behind, 0 ahead)' "rev-list said '$counts'"

    # THE CORE ACCEPTANCE ASSERTION: the template change reached the machine.
    $v2 = [System.IO.File]::ReadAllText($rendered)
    Assert-True ($v2 -match '"pacgate"') 'RENDERED CONFIG GAINED pacgate - the lost update is fixed'
    Assert-True ($v2 -match '"openviking"') 'existing servers preserved'
    Assert-True ((Get-ChildItem $cb -Filter 'deer-flow-extensions-config.json.bak.*').Count -ge 1) 'previous config backed up'

    # compose pins advanced with the same command
    $composeNow = [System.IO.File]::ReadAllText($composeFile)
    Assert-True ($composeNow -match '0\.1\.13') 'compose pin advanced to 0.1.13 in the same update'
    Write-Output ''

    # ── STEP 3: THE SEQUENTIAL CASE ─────────────────────────────────────────
    #
    # A SECOND release, arriving after the update above already wrote a backup of
    # the rendered config. This is the assertion that makes the backup-gitignore
    # rule load-bearing, and it took two attempts to get right.
    #
    # The first version re-ran -Update with nothing new to pull and asserted only
    # that the config was "already current". That passed even with the gitignore
    # rule removed, because a SUPPRESSED repo refresh is invisible when there is
    # nothing to fetch. Removing the rule is exactly what the earlier mutation
    # test did, and the suite still went green - a test that cannot fail.
    #
    # The real hazard is one step later: the backup written in STEP 2 is untracked,
    # so it makes the tree dirty, so the NEXT repo refresh is skipped - and at that
    # point there IS something to fetch. The machine silently stays a release
    # behind on all repo content. That is what this step now checks.
    Write-Host 'STEP 3: a LATER release still lands (backup must not block the refresh)' -ForegroundColor White
    $baksAfterStep2 = @(Get-ChildItem $cb -Filter 'deer-flow-extensions-config.json.bak.*').Count
    Assert-True ($baksAfterStep2 -ge 1) 'a backup exists from STEP 2 (the condition under test)' "found $baksAfterStep2"

    Write-BundleFiles -Root $author -TemplateJson (New-TemplateJson @('openviking', 'pacgate', 'firecrawl', 'courtlistener')) -ComposePin '0.1.14'
    Invoke-Git $author @('add', '-A') | Out-Null
    Invoke-Git $author @('commit', '-q', '-m', 'v3: template gains courtlistener; pin 0.1.14') | Out-Null
    Invoke-Git $author @('push', '-q', 'origin', 'main') | Out-Null

    $r3 = Invoke-Child -Dir $cb -InstallerArgs @('-Update')

    # Dump the repo lines: if the refresh was suppressed, this says so explicitly.
    $dbg3 = ($r3.Output -split "`r?`n" | Where-Object { $_ -match 'Repo|WARN|gained' })
    if ($dbg3) {
        Write-Host '  --- child output (repo-related) ---' -ForegroundColor DarkGray
        $dbg3 | Select-Object -First 8 | ForEach-Object { Write-Host ("      {0}" -f $_.TrimEnd()) -ForegroundColor DarkGray }
    }

    Assert-True ($r3.Exit -eq 0) 'third -Update exits 0'
    Assert-True ($r3.Output -match 'Repo updated') 'repo refresh STILL runs with a backup present (not blocked)'

    $headAfter3 = (Invoke-Git $aipc @('rev-parse', 'HEAD')).Out
    Assert-True ($headAfter3 -ne $headAfter) 'HEAD advanced to the later release'

    $v4 = [System.IO.File]::ReadAllText($rendered)
    Assert-True ($v4 -match '"courtlistener"') 'the later template change reached the machine'
    Assert-True ($v4 -match '"pacgate"') 'earlier change still present (not regressed)'
    Assert-True (@(Get-ChildItem $cb -Filter 'deer-flow-extensions-config.json.bak.*').Count -gt $baksAfterStep2) 'a SECOND backup was written for the second change'
    Assert-True ([System.IO.File]::ReadAllText($composeFile) -match '0\.1\.14') 'compose pin advanced again, in the same command'
    Write-Output ''

    # ── STEP 4: idempotence, with nothing new available ─────────────────────
    Write-Host 'STEP 4: run -Update with nothing new (must be safe to repeat)' -ForegroundColor White
    $baksBefore = @(Get-ChildItem $cb -Filter 'deer-flow-extensions-config.json.bak.*').Count
    $r4 = Invoke-Child -Dir $cb -InstallerArgs @('-Update')
    Assert-True ($r4.Exit -eq 0) 'repeat -Update exits 0'
    Assert-True ($r4.Output -match 'already current') 'config reports already current (no churn)'
    Assert-True (@(Get-ChildItem $cb -Filter 'deer-flow-extensions-config.json.bak.*').Count -eq $baksBefore) 'no redundant backup on a no-op run'
    Assert-True ((Invoke-Git $aipc @('rev-parse', 'HEAD')).Out -eq $headAfter3) 'HEAD unchanged on the repeat run'

    # the rendered config must not have been corrupted by the repeat pass
    Assert-True ([System.IO.File]::ReadAllText($rendered) -eq $v4) 'rendered config byte-identical after a no-op update'
    Write-Output ''

    # ── STEP 5: -SkipRepoPull must leave the repo alone ────────────────────
    Write-Host 'STEP 5: -SkipRepoPull leaves the repo alone' -ForegroundColor White
    Write-BundleFiles -Root $author -TemplateJson (New-TemplateJson @('openviking', 'pacgate', 'firecrawl', 'courtlistener')) -ComposePin '0.1.15'
    Invoke-Git $author @('add', '-A') | Out-Null
    Invoke-Git $author @('commit', '-q', '-m', 'v4: compose pin 0.1.15') | Out-Null
    Invoke-Git $author @('push', '-q', 'origin', 'main') | Out-Null

    $r5 = Invoke-Child -Dir $cb -InstallerArgs @('-Update', '-SkipRepoPull')
    Assert-True ($r5.Exit -eq 0) '-SkipRepoPull exits 0'
    Assert-True ((Invoke-Git $aipc @('rev-parse', 'HEAD')).Out -eq $headAfter3) 'repo NOT advanced (as instructed)'
}
catch {
    Write-Host ("  [FAIL] harness error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("         {0}" -f $_.ScriptStackTrace) -ForegroundColor DarkGray
    $failed++
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($failed -eq 0) {
    Write-Host ("{0} passed, 0 failed" -f $passed) -ForegroundColor Green
    exit 0
}
Write-Host ("{0} passed, {1} FAILED" -f $passed, $failed) -ForegroundColor Red
exit 1
