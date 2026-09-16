# For each pacgate-ai fork, determine whether it carries commits beyond upstream.
# A fork with custom commits is a potential patch source for our stack
# (we consume markitdown via pacgate-mcp and deer-flow as our base image).
$H = @{ Accept = 'application/vnd.github+json' }

function Get-Json($url) {
    try { return Invoke-RestMethod $url -Headers $H -ErrorAction Stop }
    catch { Write-Output "    HTTP $($_.Exception.Response.StatusCode.value__)"; return $null }
}

$forks = @('deer-flow', 'markitdown', 'odysseus', 'ironclaw', 'hermes-agent', 'dockhand-dash')
$forkOwner = 'pacgate-ai'

foreach ($f in $forks) {
    Write-Output ("=" * 76)
    Write-Output ("FORK: $forkOwner/$f")
    Write-Output ("=" * 76)

    $meta = Get-Json "https://api.github.com/repos/$forkOwner/$f"
    if (-not $meta) { continue }

    $parentFull = $meta.parent.full_name
    $parentBranch = $meta.parent.default_branch
    Write-Output ("  parent      : $parentFull (branch $parentBranch)")
    Write-Output ("  fork branch : $($meta.default_branch)")
    Write-Output ("  pushed      : $($meta.pushed_at)")

    # Compare fork default branch against parent default branch.
    $cmp = Get-Json "https://api.github.com/repos/$forkOwner/$f/compare/$parentBranch...$($meta.default_branch)"
    if ($cmp) {
        Write-Output ("  status      : {0}  (ahead_by={1} behind_by={2})" -f $cmp.status, $cmp.ahead_by, $cmp.behind_by)
        if ($cmp.ahead_by -gt 0) {
            Write-Output "  *** CUSTOM COMMITS BEYOND UPSTREAM ***"
            $cmp.commits | Select-Object -Last 15 | ForEach-Object {
                Write-Output ("      {0}  {1}  {2}" -f $_.sha.Substring(0, 8), $_.commit.author.date, ($_.commit.message -split "`n")[0])
            }
        }
        else {
            Write-Output "  (no commits beyond upstream)"
        }
    }
    Write-Output ''
}
