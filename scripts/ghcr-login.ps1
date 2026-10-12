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

# Invoke an HTTP request and report Status / Body / Headers / Error as DATA rather
# than throwing, without relying on PowerShell 7-only parameters.
#
# WHY: `-SkipHttpErrorCheck` is PowerShell 7-only. Under the built-in Windows
# PowerShell 5.1 it raises ParameterBindingException BEFORE the request is sent, so
# on a client AIPC the scope probe below cannot run at all. Same class as the defect
# fixed in deploy/client-bundle/install.ps1 (see deploy/DEFECT-ps51-native-stderr.md).
#
# The body of a non-2xx reply is read from $_.ErrorDetails.Message. Measured on both
# shells: PS 5.1's HttpWebResponse stream reads EMPTY (PowerShell has already
# consumed it) and PS 7's HttpResponseMessage.Content is DISPOSED by the time the
# catch runs, so neither of the obvious routes works.
function Invoke-ApiRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = 'Get',
        [string]$Body,
        [hashtable]$Headers,
        [int]$TimeoutSec = 30
    )
    $result = [pscustomobject]@{ Status = $null; Body = ''; Headers = $null; Error = $null }
    try {
        $p = @{ Uri = $Uri; Method = $Method; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
        if ($Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
        if ($Headers) { $p.Headers = $Headers }
        $r = Invoke-WebRequest @p
        $result.Status = [int]$r.StatusCode
        $result.Body = [string]$r.Content
        $result.Headers = $r.Headers
    }
    catch {
        $wr = $_.Exception.Response
        if ($wr) { $result.Status = [int]$wr.StatusCode }
        $body = [string]$_.ErrorDetails.Message
        if ($body) { $result.Body = $body }
        if (-not $wr -and -not $body) { $result.Error = "$($_.Exception.Message)" }
    }
    return $result
}

$req   = "protocol=https`nhost=github.com`n`n"
$cred  = $req | git credential fill 2>$null
$token = ($cred | Select-String -Pattern '^password=(.*)$').Matches[0].Groups[1].Value
if (-not $token) { Write-Host 'ERROR: no GitHub token from the credential helper.' -ForegroundColor Red; exit 1 }

# Declared scopes: tells us whether `write:packages` is present BEFORE attempting a
# push that would fail opaquely. The response is parsed, never printed.
#
# Before this change the -SkipHttpErrorCheck parameter was rejected by the built-in
# 5.1 BEFORE the request was sent. The old catch reported it as "scope probe failed",
# but the scope line then never appeared at all, so on a client AIPC this script could
# not tell you whether the token could push. Invoke-ApiRequest replaces the try/catch.
$hdr  = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
$resp = Invoke-ApiRequest -Uri 'https://api.github.com/user' -Headers $hdr -TimeoutSec 20
if ($null -eq $resp.Status) {
    Write-Output "scope probe failed (no response): $($resp.Error)"
}
elseif ($resp.Status -ne 200) {
    Write-Output "scope probe failed: HTTP $($resp.Status) $($resp.Body)"
}
else {
    $scopes = $resp.Headers['X-OAuth-Scopes']
    Write-Output "token scopes: $scopes"
    if ($scopes -notmatch 'write:packages') {
        Write-Host '[WARN] no write:packages scope - a push to GHCR will be refused.' -ForegroundColor Yellow
    }
}

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
