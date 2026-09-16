# Bump the Pacgate release version across every pin file, in one shot.
#
# WHY: a release tags ALL FOUR images with a single tag, but the version is
# written in 6+ places across 5 files. Today those pins are split three ways
# (api/mcp 0.1.9, deer-flow 0.1.10, frontend 0.1.11), so a manual bump is easy
# to get half-right - and a missed pin silently points a client at an old image.
#
# This script rewrites them together and then PROVES the result by re-scanning
# for any surviving old version.
#
# Usage:
#   .\scripts\bump-release-version.ps1 -To 0.1.12 -Preview
#   .\scripts\bump-release-version.ps1 -To 0.1.12
param(
    [Parameter(Mandatory = $true)]
    [string]$To,

    # Report what would change without writing.
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    if ($To -notmatch '^\d+\.\d+\.\d+$') {
        throw "Version must look like 0.1.12 (got '$To')"
    }

    # The set of versions we are replacing. Split today, hence three entries.
    # Add to this list if another version shows up in the pins.
    $fromVersions = @('0.1.9', '0.1.10', '0.1.11')

    # file -> list of [regex-with-capture-of-old-version]
    $targets = [ordered]@{
        # Rust workspace version. Only the workspace-level `version =`, not deps.
        'pacgate-ai/Cargo.toml' = @(
            '(?m)^(version\s*=\s*")(?<v>\d+\.\d+\.\d+)(")'
        )

        # Compose pins: every ghcr.io/pacgate-ai/<image>:<version>
        'deploy/client-bundle/compose.prod.yaml' = @(
            '(ghcr\.io/pacgate-ai/[a-z0-9\-]+:)(?<v>\d+\.\d+\.\d+)'
        )
        'deploy/client-bundle/compose.bundle.yaml' = @(
            '(ghcr\.io/pacgate-ai/[a-z0-9\-]+:)(?<v>\d+\.\d+\.\d+)'
        )

        # NOTE: the following files are deliberately NOT bumped. They contain
        # 0.1.x strings, but as HISTORICAL FACTS, not pins:
        #
        #   deer-flow-extensions-config.template.json
        #       "OfficeCLI ... baked into deer-flow-pacgate 0.1.10+"
        #   patches/deer-flow-prompt.py
        #       "Fallback if officecli is unavailable (e.g. image is <0.1.10)"
        #
        # Rewriting these would claim a capability shipped in a release where it
        # did not, which is worse than a stale pin. Leave them alone.

        # Cargo.lock: only the pacgate workspace crates. Match the name line,
        # then the version line immediately after it.
        'pacgate-ai/Cargo.lock' = @(
            '(?ms)(^name = "pacgate[a-z0-9\-]*"\r?\nversion = ")(?<v>\d+\.\d+\.\d+)(")'
        )
    }

    $totalEdits = 0
    $report = @()

    foreach ($rel in $targets.Keys) {
        $path = Join-Path $repoRoot $rel
        if (-not (Test-Path -LiteralPath $path)) {
            $report += "  SKIP (missing): $rel"
            continue
        }

        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $script:count = 0

        foreach ($pattern in $targets[$rel]) {
            $text = [regex]::Replace($text, $pattern, {
                    param($m)
                    $old = $m.Groups['v'].Value
                    if ($script:fromVersions -notcontains $old) {
                        # Not one of the known old pins - leave it alone.
                        return $m.Value
                    }
                    $script:count++
                    $m.Value.Replace($old, $script:To)
                })
        }

        if ($script:count -gt 0) {
            if (-not $Preview) {
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
            }
            $report += ("  {0,-52} {1} edit(s)" -f $rel, $script:count)
            $totalEdits += $script:count
        }
        else {
            $report += ("  {0,-52} no change" -f $rel)
        }
    }

    Write-Output "Bump $($fromVersions -join ' / ')  ->  $To"
    Write-Output ''
    $report | ForEach-Object { Write-Output $_ }
    Write-Output ''
    Write-Output "Total edits: $totalEdits"

    if ($Preview) {
        Write-Output 'MODE: Preview (nothing written)'
        return
    }

    # ── Prove the result ────────────────────────────────────────────────────
    # Check NARROWLY, per file shape. A blanket "does the old version appear
    # anywhere?" test produces false alarms: Cargo.lock legitimately contains
    # unrelated third-party crates at 0.1.9 / 0.1.10 / 0.1.11.
    Write-Output ''
    Write-Output 'Verifying...'
    $stale = @()

    # 1. Cargo.toml - the workspace version line only.
    $toml = Get-Content (Join-Path $repoRoot 'pacgate-ai/Cargo.toml') -Raw
    $m = [regex]::Match($toml, '(?m)^version\s*=\s*"([^"]+)"')
    if ($m.Success -and $m.Groups[1].Value -ne $To) {
        $stale += "  Cargo.toml workspace version is $($m.Groups[1].Value), expected $To"
    }

    # 2. Compose - every ghcr.io/pacgate-ai/<img>:<ver> must equal $To.
    foreach ($cf in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/compose.bundle.yaml')) {
        $text = Get-Content (Join-Path $repoRoot $cf) -Raw
        foreach ($mm in [regex]::Matches($text, 'ghcr\.io/pacgate-ai/[a-z0-9\-]+:(?<v>\d+\.\d+\.\d+)')) {
            if ($mm.Groups['v'].Value -ne $To) {
                $stale += "  $cf has pin $($mm.Value), expected $To"
            }
        }
    }

    # 3. Cargo.lock - only the pacgate workspace crates.
    $lock = Get-Content (Join-Path $repoRoot 'pacgate-ai/Cargo.lock') -Raw
    foreach ($mm in [regex]::Matches($lock, '(?ms)^name = "(?<n>pacgate[a-z0-9\-]*)"\r?\nversion = "(?<v>[^"]+)"')) {
        if ($mm.Groups['v'].Value -ne $To) {
            $stale += "  Cargo.lock crate $($mm.Groups['n'].Value) is $($mm.Groups['v'].Value), expected $To"
        }
    }

    if ($stale.Count -gt 0) {
        Write-Output 'FAIL - pins did not all move:'
        $stale | ForEach-Object { Write-Output $_ }
        exit 1
    }

    Write-Output "  OK: all pins now read $To."
    Write-Output ''
    Write-Output 'Next:'
    Write-Output "  1. Build and publish $To (fork -> Actions -> build-ghcr, tag=$To)."
    Write-Output '  2. Flip any NEW package to public (UI-only for user accounts).'
    Write-Output "  3. .\scripts\check-ghcr-pull.ps1 -Targets 'pacgate-ai/pacgate-api:$To','pacgate-ai/pacgate-mcp:$To','pacgate-ai/deer-flow-pacgate:$To','pacgate-ai/deer-flow-frontend-pacgate:$To'"
}
finally {
    Pop-Location
}
