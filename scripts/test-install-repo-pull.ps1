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
#   5. -SkipRepoPull   -> leaves the repo alone
#   6. untracked, unrelated -> PROCEEDS (was: silently skipped the whole refresh)
#   7. untracked, colliding -> REFUSES and names the files, preserves them
#   8. untracked, colliding, NON-ASCII name -> same, and proves core.quotepath
#
# Case 3, 4, 7 and 8 are the ones that matter: this runs on a client machine, and
# a careless update would destroy someone's edits or their commits.
#
# CASE 4 WAS VACUOUS UNTIL 2026-09-17. The fixture ran
#     Git $c4.Clone @('commit','--quiet','-m','local work')
# and the Git helper joined args with ' ', so git received '-m local work' as
# '-m local' + pathspec 'work'. The commit FAILED ('pathspec work did not match'),
# no local commit was ever made, and the three assertions below passed by
# re-testing the dirty-tree path - divergence was never exercised. Fixed by
# passing each argument as its own argv entry, and the fixture now ASSERTS that
# the local commit exists, so this cannot silently become vacuous again.
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
    # EACH ARGUMENT IS ITS OWN ARGV ENTRY.
    #
    # The first version did `$psi.Arguments = ($GitArgs -join ' ')`, which split
    # any argument CONTAINING A SPACE. `-m 'local work'` became '-m local' plus a
    # pathspec 'work', the commit failed, and CASE 4's fixture silently stopped
    # creating the divergence it claimed to test. Adding the argument to the
    # ArgumentList collection passes it as one entry, so spaces are preserved.
    foreach ($a in $GitArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $Dir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    # Decode git output as UTF-8. Without this it uses the console codepage and
    # non-ASCII paths (this repo has Chinese-named files) come back mangled, so
    # any comparison against them fails invisibly.
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
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
    # ASSERT THE FIXTURE IS REAL. Without this the case can go vacuous again and
    # still report PASS - which is exactly what happened before.
    $c4log = (Git $c4.Clone @('rev-list','--count','HEAD')).Trim()
    Check 'fixture: a local commit was actually created' ([int]$c4log -ge 2) "HEAD has $c4log commit(s)"
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
    # ── CASE 6: untracked but UNRELATED -> proceed ─────────────────
    #
    # The defect this guards: the old guard used a bare 'git status --porcelain',
    # so ANY untracked file made it print 'skipping the repo update' and move
    # only images. Workflows, patches and nginx.conf silently stayed old while
    # the image tags advanced - a lost update with no error. Found on this dev
    # box, which had 2 untracked files and was skipping the refresh.
    Write-Host 'CASE 6: untracked scratch files -> refresh PROCEEDS (regression guard)'
    $c6 = New-Clone 'untracked-ok'
    Publish-Change $c6.Upstream 'v2'
    'scratch notes' | Set-Content "$($c6.Clone)\scratch-notes.txt"
    New-Item -ItemType Directory "$($c6.Clone)\scratchdir" -Force | Out-Null
    'more' | Set-Content "$($c6.Clone)\scratchdir\note.txt"
    # A Chinese-named untracked file too: non-ASCII paths are C-quoted by git
    # unless core.quotepath=false, so this is the case that would break a
    # name-comparison written without it.
    'non-ascii' | Set-Content "$($c6.Clone)\法律素材测试.md"
    $out6 = Run-Installer $c6.Clone
    $ver6 = Get-Content "$($c6.Clone)\VERSION.txt" -Raw
    Check 'repo WAS refreshed despite untracked files' ($ver6.Trim() -eq 'v2') "VERSION=$($ver6.Trim())"
    Check 'reported the fast-forward' ($out6 -match 'Repo updated')
    Check 'did NOT skip the repo update' (-not ($out6 -match 'skipping the repo update'))
    Check 'announced the untracked files were kept' ($out6 -match 'untracked file\(s\) present')
    Check 'scratch file PRESERVED' (Test-Path "$($c6.Clone)\scratch-notes.txt")
    Check 'scratch dir PRESERVED' (Test-Path "$($c6.Clone)\scratchdir\note.txt")
    Check 'non-ASCII untracked file PRESERVED' (Test-Path "$($c6.Clone)\法律素材测试.md")
    Write-Host ''

    # ── CASE 7: untracked COLLISION -> refuse, name, preserve ──────
    #
    # Only a genuine collision blocks: the incoming commit adds a path that is
    # untracked here. Git would refuse this itself, but mid-pull and with a raw
    # error; pre-checking gives an actionable message and skips cleanly.
    Write-Host 'CASE 7: untracked file the update would overwrite -> REFUSES, preserves it'
    $c7 = New-Clone 'collide'
    # Upstream adds NEWFILE.txt; the clone already has an untracked NEWFILE.txt.
    'upstream version' | Set-Content "$($c7.Upstream)\NEWFILE.txt"
    $null = Git $c7.Upstream @('add','-A')
    $null = Git $c7.Upstream @('commit','--quiet','-m','add newfile')
    'MY UNTRACKED WORK' | Set-Content "$($c7.Clone)\NEWFILE.txt"
    $out7 = Run-Installer $c7.Clone
    $kept = Get-Content "$($c7.Clone)\NEWFILE.txt" -Raw
    Check 'untracked work PRESERVED' ($kept -match 'MY UNTRACKED WORK') "got '$($kept.Trim())'"
    # INSTALLER-SPECIFIC wording. An earlier version asserted 'would be
    # overwritten', which ALSO matches git's own abort text ("would be
    # overwritten by merge") - so mutating the installer's message away was
    # invisible and the mutation went undetected. Assert on a string only the
    # installer emits.
    Check 'refused with the installer''s own message' ($out7 -match 'Cannot refresh the repo')
    Check 'named the colliding file' ($out7 -match 'NEWFILE.txt')
    Check 'did NOT fast-forward' (-not ($out7 -match 'Repo updated'))
    Check 'told the operator what to do' ($out7 -match 'Move, rename, or commit')
    Write-Host ''

    # ── CASE 8: NON-ASCII untracked collision -> still detected ────
    #
    # core.quotepath is load-bearing here. Without `-c core.quotepath=false` git
    # C-quotes the name ("\346\263\225...") and the comparison against the real
    # path SILENTLY fails, so a Chinese-named collision would slip past the
    # pre-check and reach git's own abort. This repo contains Chinese-named
    # files, so it is a real case, not a curiosity.
    #
    # A SEPARATE case with ONLY a non-ASCII collision, because an ASCII collision
    # alongside it would still trigger the block and mask the quotepath bug.
    Write-Host 'CASE 8: non-ASCII untracked collision -> REFUSES, preserves it'
    $c8 = New-Clone 'collide-nonascii'
    $cn = '法律素材脱敏范围.md'
    "upstream $cn" | Set-Content "$($c8.Upstream)\$cn"
    $null = Git $c8.Upstream @('add','-A')
    $null = Git $c8.Upstream @('commit','--quiet','-m','add non-ascii file')
    'MY NON-ASCII LOCAL WORK' | Set-Content "$($c8.Clone)\$cn"
    $out8 = Run-Installer $c8.Clone
    $keptNonAscii = Get-Content "$($c8.Clone)\$cn" -Raw
    Check 'non-ASCII untracked work PRESERVED' ($keptNonAscii -match 'MY NON-ASCII LOCAL WORK') "got '$($keptNonAscii.Trim())'"
    Check 'non-ASCII collision WAS detected' ($out8 -match 'Cannot refresh the repo')
    Check 'did NOT fast-forward' (-not ($out8 -match 'Repo updated'))
    Write-Host ''
    Write-Host "RESULT: $script:pass passed, $script:fail failed" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
}
finally {
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { exit 1 }
# EXPLICIT exit 0. Without it the script's exit code is inherited from
# $LASTEXITCODE, i.e. the last NATIVE command that ran - and CASE 7 deliberately
# makes `git pull` fail (the installer refuses the collision on purpose). So a
# fully passing suite reported exit=1 and run-all-checks marked the gate FAILED.
# Found by reading the exit code instead of the "26 passed, 0 failed" line.
exit 0
