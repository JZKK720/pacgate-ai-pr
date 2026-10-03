# Watch the most recent build-ghcr run for a tag until it finishes.
#
# Prints only status and step names - never the token, and never the job logs,
# which can contain build-arg echoes.
#
# Usage: pwsh -File scripts/watch-release-build.ps1 -Tag 0.1.22
param(
    [string]$Tag = '',
    [string]$Owner = 'JZKK720',
    [string]$Repo  = 'pacgate-ai-pr',
    [int]$TimeoutMinutes = 45
)

$ErrorActionPreference = 'Stop'

$req   = "protocol=https`nhost=github.com`n`n"
$cred  = $req | git credential fill 2>$null
$token = ($cred | Select-String -Pattern '^password=(.*)$').Matches[0].Groups[1].Value
if (-not $token) { Write-Host 'ERROR: no GitHub token from the credential helper.' -ForegroundColor Red; exit 1 }
$H = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }

function Get-Runs {
    $u = "https://api.github.com/repos/$Owner/$Repo/actions/workflows/build-ghcr.yml/runs?per_page=10"
    $r = Invoke-RestMethod -Uri $u -Headers $H -TimeoutSec 30
    if ($Tag) {
        # workflow_dispatch sets display_title to the inputs summary; match on it.
        return @($r.workflow_runs | Where-Object { $_.display_title -match [regex]::Escape($Tag) -or $_.head_branch -eq 'main' })
    }
    return @($r.workflow_runs)
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$runId    = $null
Write-Host "=== watching build-ghcr for $Tag ===" -ForegroundColor Cyan

while ((Get-Date) -lt $deadline) {
    $runs = Get-Runs
    if (-not $runs) { Write-Host '  no runs yet...'; Start-Sleep -Seconds 10; continue }
    $run = $runs[0]
    $runId = $run.id

    if ($run.status -eq 'completed') {
        Write-Host "`nrun #$($run.run_number) $($run.status) -> $($run.conclusion)" -ForegroundColor $(if ($run.conclusion -eq 'success') { 'Green' } else { 'Red' })
        Write-Host "  $($run.html_url)"
        $jobs = Invoke-RestMethod -Uri "$($run.jobs_url)" -Headers $H -TimeoutSec 30
        foreach ($j in $jobs.jobs) {
            Write-Host "  job: $($j.name) -> $($j.conclusion)" -ForegroundColor $(if ($j.conclusion -eq 'success') { 'Green' } else { 'Red' })
            foreach ($s in $j.steps) {
                $mark = if ($s.conclusion -eq 'success') { 'ok  ' } elseif ($s.conclusion -eq 'skipped') { 'skip' } else { 'FAIL' }
                Write-Host "      [$mark] $($s.name)"
            }
        }
        if ($run.conclusion -eq 'success') { exit 0 } else { exit 1 }
    }

    Write-Host "  run #$($run.run_number) $($run.status) (started $($run.created_at))"
    Start-Sleep -Seconds 30
}

Write-Host "TIMEOUT after $TimeoutMinutes minutes (run id $runId may still be going)" -ForegroundColor Yellow
exit 2
