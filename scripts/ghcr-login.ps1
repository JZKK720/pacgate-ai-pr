# Log in to GHCR using the token in the git credential helper.
#
# WHY A SCRIPT. The token must never reach the console or a log. It is read into
# a variable, piped to `docker login --password-stdin`, and never echoed. This
# repo has three recorded incidents of credentials reaching a transcript, so the
# discipline is encoded rather than left to whoever types the next command.
#
# Prints ONLY the token's declared scopes (from the API) and the login result.
#
# Usage: pwsh -File scripts/ghcr-login.ps1 [-User JZKK720]
param(
    [string]$User = 'JZKK720',
    [string]$Registry = 'ghcr.io'
)

$ErrorActionPreference = 'Stop'

$req   = "protocol=https`nhost=github.com`n`n"
$cred  = $req | git credential fill 2>$null
$token = ($cred | Select-String -Pattern '^password=(.*)$').Matches[0].Groups[1].Value
if (-not $token) { Write-Host 'ERROR: no GitHub token from the credential helper.' -ForegroundColor Red; exit 1 }

# Declared scopes: tells us whether `write:packages` is present BEFORE attempting a
# push that would fail opaquely. The response is parsed, never printed.
try {
    $hdr  = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $resp = Invoke-WebRequest -Uri 'https://api.github.com/user' -Headers $hdr -TimeoutSec 20 -SkipHttpErrorCheck
    $scopes = $resp.Headers['X-OAuth-Scopes']
    Write-Output "token scopes: $scopes"
    if ($scopes -notmatch 'write:packages') {
        Write-Host '[WARN] no write:packages scope - a push to GHCR will be refused.' -ForegroundColor Yellow
    }
}
catch { Write-Output "scope probe failed: $($_.Exception.Message)" }

# docker login via stdin. The token is never an argument, so it cannot appear in a
# process listing or an error message.
$token | docker login $Registry -u $User --password-stdin 2>&1 | ForEach-Object {
    # docker echoes 'Login Succeeded' on success; anything containing the token would
    # be a bug here, so filter defensively rather than trusting the output.
    if ($_ -notmatch [regex]::Escape($token)) { Write-Output $_ }
}
$code = $LASTEXITCODE
$token = $null; $cred = $null
Write-Output "docker login exit: $code"
exit $code
