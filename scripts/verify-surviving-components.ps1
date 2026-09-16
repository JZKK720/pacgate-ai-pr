# Verify the named components survived the upstream merge into this tree.
# Read-only. Checks PRESENCE at HEAD plus the merge history that could have
# dropped them. Presence is not the same as working - see the runtime section.
#
# NOTE ON THRESHOLDS: an earlier version of this script GUESSED "16 crates" and
# "11 patches" and reported two false failures. The counts are now DERIVED from
# Cargo.toml's member list and the compose mounts, so the check cannot disagree
# with the tree it is checking. Guessing a threshold is how a verification tool
# starts lying.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$fail = 0
function Check {
    param([string]$Label, [scriptblock]$Test, [string]$Note = '')
    try {
        $r = & $Test
        if ($r) {
            Write-Host ("  OK   {0}" -f $Label) -ForegroundColor Green
            if ($Note) { Write-Host ("       {0}" -f $Note) -ForegroundColor DarkGray }
        }
        else {
            Write-Host ("  MISS {0}" -f $Label) -ForegroundColor Red
            $script:fail++
        }
    }
    catch {
        Write-Host ("  ERR  {0} - {1}" -f $Label, $_.Exception.Message) -ForegroundColor Red
        $script:fail++
    }
}

# ── derived facts ────────────────────────────────────────────────────
$cargoRaw = Get-Content 'pacgate-ai/Cargo.toml' -Raw
$memberBlock = [regex]::Match($cargoRaw, '(?s)members\s*=\s*\[(.*?)\]').Groups[1].Value
$members = @([regex]::Matches($memberBlock, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
$membersPresent = @($members | Where-Object { Test-Path (Join-Path 'pacgate-ai' $_) })
$cratesMembers = @($members | Where-Object { $_ -like 'crates/*' })
$wasmMembers = @($members | Where-Object { $_ -like 'wasm-crates/*' })

$composeRaw = Get-Content 'deploy/client-bundle/compose.prod.yaml' -Raw
$patchFiles = @(Get-ChildItem 'deploy/client-bundle/patches' -File -Filter '*.py' -ErrorAction SilentlyContinue)
$patchMounts = @([regex]::Matches($composeRaw, '\./patches/(?<f>[^\s:]+\.py):') | ForEach-Object { $_.Groups['f'].Value } | Select-Object -Unique)

Write-Host '=== 1. pacgate-ai API (Rust gateway) ===' -ForegroundColor Cyan
Check 'crate pacgate-api exists' { Test-Path 'pacgate-ai/crates/pacgate-api/src/lib.rs' }
Check 'health route present' { (Select-String -Path 'pacgate-ai/crates/pacgate-api/src/lib.rs' -Pattern '"/health"' -Quiet) }
Check 'build-info route (0.1.13 addition)' { (Select-String -Path 'pacgate-ai/crates/pacgate-api/src/lib.rs' -Pattern '"/build-info"' -Quiet) }
Check 'auth middleware wired' { (Select-String -Path 'pacgate-ai/crates/pacgate-api/src/lib.rs' -Pattern 'auth_middleware' -Quiet) }
Check 'soul resolver middleware' { (Select-String -Path 'pacgate-ai/crates/pacgate-api/src/lib.rs' -Pattern 'soul_resolver_middleware' -Quiet) }
Check 'every Cargo workspace member exists on disk' {
    $membersPresent.Count -eq $members.Count
} ("       {0} of {1} members present ({2} in crates/, {3} in wasm-crates/)" -f $membersPresent.Count, $members.Count, $cratesMembers.Count, $wasmMembers.Count)

Write-Output ''
Write-Host '=== 2. MCP bridge ===' -ForegroundColor Cyan
Check 'pacgate-mcp package dir' { Test-Path 'deploy/pacgate-mcp' }
Check 'pacgate-mcp Dockerfile' { Test-Path 'deploy/pacgate-mcp/Dockerfile' }
Check 'markitdown extras fix present (0.1.12)' {
    $c = Get-ChildItem 'deploy/pacgate-mcp' -Recurse -File -Include '*.txt','*.toml','Dockerfile' -ErrorAction SilentlyContinue |
         ForEach-Object { Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue } | Out-String
    $c -match 'markitdown\['
}
Check 'mcp pinned in compose.prod.yaml' { (Select-String -Path 'deploy/client-bundle/compose.prod.yaml' -Pattern 'pacgate-mcp:' -Quiet) }
Check 'mcp named in extensions template' { (Select-String -Path 'deploy/client-bundle/deer-flow-extensions-config.template.json' -Pattern 'pacgate' -Quiet) }

Write-Output ''
Write-Host '=== 3. OpenViking persistent memory ===' -ForegroundColor Cyan
Check 'openviking pinned in compose' { (Select-String -Path 'deploy/client-bundle/compose.prod.yaml' -Pattern 'openviking' -Quiet) }
Check 'openviking data mount' { (Select-String -Path 'deploy/client-bundle/compose.prod.yaml' -Pattern '\./openviking' -Quiet) }
Check 'OPENVIKING_CONF_CONTENT rendered' { (Select-String -Path 'deploy/client-bundle/install.ps1' -Pattern 'OPENVIKING_CONF_CONTENT' -Quiet) }
Check 'openviking config template' { Test-Path 'deploy/client-bundle/openviking' }
Check 'OPENVIKING_API_KEY wired to sandbox' { (Select-String -Path 'deploy/qm-pacgate/qm.config.jsonc' -Pattern 'OPENVIKING_API_KEY' -Quiet) }

Write-Output ''
Write-Host '=== 4. Documentation pipeline ===' -ForegroundColor Cyan
Check 'docs/index.html' { Test-Path 'docs/index.html' }
Check 'docs/assets present' { Test-Path 'docs/assets' }
Check 'docs/diagrams present' { Test-Path 'docs/diagrams' }
Check 'markdown->pdf script' { Test-Path 'safe_markdown_to_pdf.py' }
Check 'clarification board->pdf' { Test-Path 'safe_clarification_board_to_pdf.py' }
Check 'clarification html->pdf' { Test-Path 'safe_clarification_html_to_pdf.py' }
Check 'extract_pdfs.py' { Test-Path 'extract_pdfs.py' }
Check 'deploy/handbooks present' { Test-Path 'deploy/handbooks' }
Check 'AIPC handbook EN' { Test-Path 'deploy/AIPC-DEPLOYMENT-HANDBOOK.md' }
Check 'AIPC handbook ZH' { Test-Path 'deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.md' }
Check 'qm handbook ZH' { Test-Path 'deploy/handbooks/qm-openviking-pacgate-handbook.zh.md' }
Check 'proposal surfaces in docs/' { @(Get-ChildItem 'docs' -Filter 'PACGATE-*.html').Count -ge 3 } ("       " + @(Get-ChildItem 'docs' -Filter 'PACGATE-*.html').Count + ' proposal pages')

Write-Output ''
Write-Host '=== 5. The deer-flow <-> QM <-> OpenViking loop ===' -ForegroundColor Cyan
Check 'deer-flow pinned' { (Select-String -Path 'deploy/client-bundle/compose.prod.yaml' -Pattern 'deer-flow-pacgate:' -Quiet) }
Check 'extensions config mount' { (Select-String -Path 'deploy/client-bundle/compose.prod.yaml' -Pattern 'deer-flow-extensions-config.json' -Quiet) }
Check 'qm config pins OPENVIKING_URL' { (Select-String -Path 'deploy/qm-pacgate/qm.config.jsonc' -Pattern 'OPENVIKING_URL' -Quiet) }
Check 'qm config pins PACGATE_API_URL' { (Select-String -Path 'deploy/qm-pacgate/qm.config.jsonc' -Pattern 'PACGATE_API_URL' -Quiet) }
Check 'every patch file is mounted and every mount has a file' {
    $unmounted = @($patchFiles | Where-Object { $patchMounts -notcontains $_.Name })
    $dangling = @($patchMounts | Where-Object { $patchFiles.Name -notcontains $_ })
    $unmounted.Count -eq 0 -and $dangling.Count -eq 0
} ("       {0} files, {1} mounts, no gaps" -f $patchFiles.Count, $patchMounts.Count)
Check 'workflows dir mounted' { (Select-String -Path 'deploy/client-bundle/compose.prod.yaml' -Pattern './workflows:' -Quiet) }
Check 'personas dir present' { Test-Path 'deploy/client-bundle/personas' }

Write-Output ''
Write-Host '=== 6. Merge integrity: did upstream delete or revert anything? ===' -ForegroundColor Cyan
# The merge range is the one that brought upstream into this tree. A merge that
# silently reverted a local customisation is the failure mode worth testing for,
# and it looks nothing like a missing file.
$mergeBase = 'c2b54f9'
$mergeTip = '832d84e'

$deleted = @(git diff --diff-filter=D --name-only $mergeBase $mergeTip 2>&1 | Where-Object { $_ -and $_ -notmatch '^fatal|^error' })
Check 'merge deleted no files' { $deleted.Count -eq 0 } ("       {0} deletions" -f $deleted.Count)

# The client-facing pins and installer are the customisations most at risk.
foreach ($f in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/install.ps1', 'deploy/client-bundle/nginx/default.conf')) {
    Check "$f survives the merge" { (git ls-tree -r --name-only $mergeTip -- $f 2>&1 | Measure-Object).Count -gt 0 }
}

# Did the merge REVERT the namespace pins back to the deprecated jzkk720 prefix?
$jzkk = @(Select-String -Path 'deploy/client-bundle/compose.prod.yaml' -Pattern 'ghcr\.io/jzkk720/' -Quiet)
Check 'no deprecated ghcr.io/jzkk720 pins reintroduced' { -not $jzkk }
Check 'all compose pins use ghcr.io/pacgate-ai' {
    $ai = @([regex]::Matches($composeRaw, 'ghcr\.io/pacgate-ai/[a-z0-9\-]+:')).Count
    $total = @([regex]::Matches($composeRaw, 'ghcr\.io/[a-z0-9\-]+/[a-z0-9\-]+:')).Count
    $ai -eq $total
} ("       {0} pacgate-ai pins, 0 other" -f (@([regex]::Matches($composeRaw, 'ghcr\.io/pacgate-ai/[a-z0-9\-]+:')).Count))

Write-Output ''
if ($fail -eq 0) {
    Write-Host 'ALL PRESENCE CHECKS PASSED' -ForegroundColor Green
    exit 0
}
Write-Host ("{0} CHECK(S) FAILED" -f $fail) -ForegroundColor Red
exit 1
