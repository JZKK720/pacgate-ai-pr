# Remove the three credential-bearing files from git HISTORY, then verify.
#
# WHY: redacting HEAD stopped new clones from seeing them, but the values are
# still in every commit since 01a4644 and in every existing clone. This purges
# them. See plans/013-credential-rotation.md.
#
# ⚠️ DESTRUCTIVE. A filter-repo rewrite changes EVERY commit hash from 01a4644
# onward. It also removes the `origin` remote (filter-repo does this by design,
# to stop you force-pushing by accident). Coordinate with anyone holding a clone
# - both AIPCs have one - and tell them to RE-CLONE, not pull.
#
# Run -DryRun first (the default). It reports the blast radius and changes
# nothing.
#
# Usage:
#   .\scripts\purge-credentials-from-history.ps1                # dry run
#   .\scripts\purge-credentials-from-history.ps1 -Apply         # rewrite for real
#   .\scripts\purge-credentials-from-history.ps1 -Apply -Push   # rewrite then force-push
param(
    [switch]$Apply,
    [switch]$Push,

    # Remote to force-push to when -Push is given.
    [string]$Remote = 'origin'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    if (-not (Test-Path '.git')) { throw "Not a git repo: $repoRoot" }

    $paths = @(
        'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/pacgate-ai-remote-handbook/OPERATOR.md'
        'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/智库资料收集/智库资料收集/MCP授权/法律数据库MCP.md'
        'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/智库资料收集/智库资料收集/MCP授权/境外法律数据库和网站.md'
    )

    Write-Output '=== Blast radius ================================================='
    $head = git rev-parse --short HEAD
    Write-Output "  current HEAD : $head"
    Write-Output ''

    foreach ($p in $paths) {
        $n = (git log --all --oneline -- $p | Measure-Object).Count
        Write-Output ("  {0,-30} {1} commit(s) touch it" -f (Split-Path $p -Leaf), $n)
    }
    Write-Output ''

    $first = git log --all --oneline --diff-filter=A -- $paths[0] | Select-Object -Last 1
    Write-Output "  earliest introducing commit: $first"
    Write-Output '  => every commit from here onward will get a NEW hash'
    Write-Output ''

    # filter-repo rewrites TRACKED history. Untracked files are not in history
    # and are left untouched, so they must not block a purge - but staged or
    # unstaged changes to tracked files must, because the rewrite would either
    # fail or silently drop them.
    $trackedChanges = git status --porcelain --untracked-files=no
    $untracked = git status --porcelain --untracked-files=all | Where-Object { $_ -match '^\?\?' }

    if ($trackedChanges) {
        Write-Output 'REFUSING: tracked files have uncommitted changes. Commit or stash first:'
        $trackedChanges | ForEach-Object { Write-Output "    $_" }
        exit 1
    }
    Write-Output '  tracked files : clean'

    if ($untracked) {
        Write-Output ("  untracked     : {0} file(s) - not in history, left alone" -f @($untracked).Count)
    }

    # Confirm the redaction is committed, so the rewrite does not resurrect it.
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            $txt = Get-Content -LiteralPath $p -Raw
            $ok = $txt -match 'REDACTED'
            Write-Output ("  {0,-30} redacted at HEAD: {1}" -f (Split-Path $p -Leaf), $ok)
            if (-not $ok) {
                Write-Output 'REFUSING: a file still holds a live credential at HEAD.'
                Write-Output 'Redact and commit it first (scripts/redact-exposed-credentials.ps1).'
                exit 1
            }
        }
    }
    Write-Output ''

    if (-not $Apply) {
        Write-Output 'MODE: DRY RUN - nothing changed.'
        Write-Output ''
        Write-Output 'To rewrite history (DESTRUCTIVE, changes all hashes from the'
        Write-Output 'introducing commit onward):'
        Write-Output '    .\scripts\purge-credentials-from-history.ps1 -Apply'
        Write-Output ''
        Write-Output 'Then force-push BOTH remotes and tell clone-holders to re-clone:'
        Write-Output "    .\scripts\purge-credentials-from-history.ps1 -Apply -Push -Remote origin"
        return
    }

    # ── Apply ───────────────────────────────────────────────────────────────
    Write-Output '=== Rewriting history ============================================'

    # Safety tag so the pre-rewrite state is recoverable locally.
    $backupTag = "pre-purge-$head"
    if (-not (git tag --list $backupTag)) {
        git tag $backupTag
        Write-Output "  safety tag created: $backupTag"
    }
    else {
        Write-Output "  safety tag exists: $backupTag"
    }
    Write-Output ''

    # Prefer the git-filter-repo binary; fall back to the Python module.
    $args = @(
        '--invert-paths'
        '--force'   # filter-repo refuses to run on a repo with a fresh clone otherwise
    )
    foreach ($p in $paths) { $args += @('--path', $p) }

    $fr = Get-Command git-filter-repo -ErrorAction SilentlyContinue
    if ($fr) {
        Write-Output "  using: git-filter-repo ($($fr.Source))"
        & git-filter-repo @args
        if ($LASTEXITCODE -ne 0) { throw "git-filter-repo failed ($LASTEXITCODE)" }
    }
    else {
        $py = Get-Command python -ErrorAction SilentlyContinue
        if (-not $py) { throw 'Neither git-filter-repo nor python is available.' }
        Write-Output '  using: python -m git_filter_repo'
        & python -m git_filter_repo @args
        if ($LASTEXITCODE -ne 0) { throw "git_filter_repo failed ($LASTEXITCODE)" }
    }

    Write-Output ''
    Write-Output '=== Verifying removal ============================================'
    $found = @()
    foreach ($p in $paths) {
        $hits = git log --all --oneline -- $p
        if ($hits) { $found += $hits }
    }
    if ($found) {
        Write-Output 'STILL PRESENT in history (investigate):'
        $found | ForEach-Object { Write-Output "    $_" }
        exit 1
    }
    Write-Output '  OK: none of the three paths exist anywhere in history.'

    # filter-repo removes remotes by design.
    Write-Output ''
    Write-Output '  note: git-filter-repo removed the remote(s) by design.'
    Write-Output "        re-add before pushing:  git remote add origin <url>"

    if (-not $Push) {
        Write-Output ''
        Write-Output 'MODE: rewritten locally, NOT pushed.'
        Write-Output 'Re-add the remote, then force-push deliberately:'
        Write-Output '    git remote add origin https://github.com/JZKK720/pacgate-ai-pr.git'
        Write-Output '    git push --force-with-lease origin main --tags'
        Write-Output '    git push --force-with-lease <fork-url> main --tags'
        return
    }

    Write-Output ''
    Write-Output "=== Force-pushing to $Remote ====================================="
    git push --force-with-lease $Remote main --tags
    if ($LASTEXITCODE -ne 0) { throw "push failed ($LASTEXITCODE)" }

    Write-Output ''
    Write-Output 'Done. Now:'
    Write-Output '  1. Force-push the OTHER remote too (the fork).'
    Write-Output '  2. Tell everyone with a clone to RE-CLONE, not pull.'
    Write-Output '  3. Re-verify images still pull:'
    Write-Output '       .\scripts\check-ghcr-pull.ps1 -Targets "pacgate-ai/pacgate-api:0.1.9"'
}
finally {
    Pop-Location
}
