# Inspect GitHub Actions runs for a workflow on a public repo (no auth needed).
# Reports step-level conclusions so a failed build can be diagnosed.
param(
    [string]$Repo = 'pacgate-ai/pacgate-ai-pr',
    [string]$Workflow = 'build-ghcr.yml',
    [string]$BranchFilter,
    [int]$Limit = 3
)

$headers = @{ Accept = 'application/vnd.github+json' }
$base = "https://api.github.com/repos/$Repo/actions/workflows/$Workflow/runs?per_page=20"

$runs = (Invoke-RestMethod $base -Headers $headers).workflow_runs
if ($BranchFilter) { $runs = $runs | Where-Object { $_.head_branch -eq $BranchFilter } }
$runs = $runs | Select-Object -First $Limit

foreach ($run in $runs) {
    Write-Output ("=" * 78)
    Write-Output ("RUN  id={0}  ref={1}  event={2}  conclusion={3}" -f $run.id, $run.head_branch, $run.event, $run.conclusion)
    Write-Output ("     created={0}  sha={1}" -f $run.created_at, $run.head_sha.Substring(0, 12))
    Write-Output ("     url={0}" -f $run.html_url)
    Write-Output ("=" * 78)

    $jobs = (Invoke-RestMethod "https://api.github.com/repos/$Repo/actions/runs/$($run.id)/jobs" -Headers $headers).jobs
    foreach ($j in $jobs) {
        Write-Output ("JOB: {0}  ->  {1}" -f $j.name, $j.conclusion)
        foreach ($s in $j.steps) {
            $mark = if ($s.conclusion -eq 'success') { '  ok  ' } elseif ($s.conclusion -eq 'skipped') { ' skip ' } else { "  ** $($s.conclusion) **" }
            Write-Output ("   {0} {1}" -f $mark, $s.name)
        }
    }
    Write-Output ""
}
