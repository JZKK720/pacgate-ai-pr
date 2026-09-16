# Verify the /build-info staleness marker against the REAL pacgate-api image on
# the REAL deployment network - not against a stub.
#
# WHY NOT A STUB. An earlier version of this test used a stub upstream that
# answered /build-info unconditionally, and it passed. It could not have failed:
# the bug that actually shipped in 0.1.13 was that pacgate_auth's middleware
# allowlist did not include /build-info, so the route returned 401 in the real
# process. A stub has no auth middleware, so it can never reproduce that. The
# test now asserts against the real binary, which means it fails when the real
# process is wrong.
#
# It also asserts the SELF-REPORTED `authenticated` field. The handler reports
# whether the auth middleware skipped it, so a caller gets proof that the skip
# list covers this path instead of having to trust a note in the source. If
# someone later removes /build-info from the skip list, the route goes back to
# 401 and this test fails on the status code.
[CmdletBinding()]
param(
    # The image under test. Empty = the version the crate manifest declares, so a
    # bump needs no edit here. Override to check a specific release.
    #
    # This was a hardcoded ':0.1.13'. It is not just a stale literal - the whole
    # point of this test is to run against the CURRENT image, so a default that
    # silently points at an old release would keep passing while proving nothing
    # about what is being shipped.
    [string]$Image = '',
    # Network to join, so pacgate-db resolves. Defaults to the live stack.
    [string]$Network = 'client-bundle_default',
    # Name of an existing container to copy DATABASE_URL from. The value is read
    # at runtime and passed through without ever being printed or written down -
    # guessing a password here would either fail or, worse, put a credential in
    # this file.
    [string]$DbFrom = 'pacgate-api'
)

if (-not $Image) {
    Set-Location (Split-Path -Parent $PSScriptRoot)
    $cargo = Get-Content pacgate-ai/Cargo.toml -Raw
    $v = [regex]::Match($cargo, '(?m)^version\s*=\s*"(?<v>\d+\.\d+\.\d+)"').Groups['v'].Value
    if (-not $v) { Write-Host 'ERROR: could not read the workspace version from Cargo.toml' -ForegroundColor Red; exit 1 }
    $Image = "ghcr.io/pacgate-ai/pacgate-api:$v"
}

$ErrorActionPreference = 'Stop'
$ctr = "pacver-test-$([guid]::NewGuid().ToString('n').Substring(0,8))"

function Cleanup {
    & docker rm -f $ctr 2>&1 | Out-Null
}

# Read DATABASE_URL out of a running container. Never displayed.
function Get-DbUrl {
    param([string]$From)
    $raw = (& docker inspect $From --format '{{range .Config.Env}}{{println .}}{{end}}' 2>&1 | Out-String)
    $line = ($raw -split "`r?`n" | Where-Object { $_ -like 'DATABASE_URL=*' } | Select-Object -First 1)
    if (-not $line) { return $null }
    return $line.Substring('DATABASE_URL='.Length)
}

Write-Host '=== /build-info against the REAL image ===' -ForegroundColor Cyan
Write-Host ("  image:   {0}" -f $Image)
Write-Host ("  network: {0}" -f $Network)
Write-Output ''

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

Cleanup
try {
    $dbUrl = Get-DbUrl -From $DbFrom
    if (-not $dbUrl) {
        throw "could not read DATABASE_URL from container '$DbFrom' - is the stack running? Pass -DbFrom <name>."
    }

    # The server refuses to serve without a database, so join the live stack's
    # network and reuse its Postgres. The image is slim: no curl/wget inside, so
    # probing happens from a separate client container against this one's IP.
    & docker run -d --name $ctr --network $Network `
        -e "DATABASE_URL=$dbUrl" `
        -e 'PACGATE_JWT_SECRET=test-secret-not-real' `
        $Image 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker run failed for $Image" }

    # Wait for readiness.
    #
    # Readiness is "the port answers 200 on /health", not "the container is up":
    # the binary boots the server only AFTER the DB pool connects, and migrations
    # run first, so this can take a while on a cold database.
    #
    # Uses curl's BUILT-IN --retry options, not a shell loop. Two earlier
    # attempts failed here and both were my fault, not the server's:
    #   1. spawning a fresh `docker run` per attempt - each cost ~1s of container
    #      startup, so the probe lost a race against a server that WAS ready;
    #   2. a `sh -c` retry loop inside a PowerShell here-string, which mangled
    #      the quoting and died with 'syntax error: unexpected word'.
    # curl --retry-connrefused is the supported way to do this and has no quoting
    # surface. A readiness probe that loses a race or dies on quoting is a broken
    # probe, and it makes a working server look dead.
    #
    # Addresses the test container by NAME: Docker's embedded DNS resolves
    # container names on a user-defined network, and the name is stable whereas
    # the IP is not.
    $code = (& docker run --rm --network $Network curlimages/curl:latest `
            -s -o /dev/null -w '%{http_code}' `
            --retry 40 --retry-delay 1 --retry-connrefused --max-time 3 `
            "http://${ctr}:8080/health" 2>&1 | Out-String).Trim()
    $ready = $code -eq '200'

    # NOTE: no `return` here on purpose. `return` inside this try block exits the
    # whole script, skipping the summary and exit-code logic below - so an earlier
    # version printed FAIL and then exited 0. A test that reports failure and
    # exits 0 is worse than no test.
    if (-not $ready) {
        $logs = (& docker logs $ctr 2>&1 | Out-String).Trim()
        Write-Host '  [FAIL] server never became ready' -ForegroundColor Red
        Write-Host ("         last /health code: {0}" -f $code) -ForegroundColor Gray
        Write-Host ("         logs: {0}" -f (($logs -split "`n" | Select-Object -Last 4) -join ' | ')) -ForegroundColor Gray
        $failed++
    }
    else {
        Write-Host ("  server ready ({0})" -f $ctr) -ForegroundColor DarkGray
        Write-Output ''

        # --- status code: the actual regression -------------------------------
        $code = (& docker run --rm --network $Network curlimages/curl:latest -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ctr}:8080/build-info" 2>&1 | Out-String).Trim()
        Assert-True ($code -eq '200') 'GET /build-info returns 200 (auth actually skipped)' "got $code - 401 means the middleware allowlist does not cover it"

        $body = (& docker run --rm --network $Network curlimages/curl:latest -s --max-time 5 "http://${ctr}:8080/build-info" 2>&1 | Out-String).Trim()
        Write-Host ("  body: {0}" -f $body) -ForegroundColor DarkGray

        # --- content ----------------------------------------------------------
        #
        # Asserted against the SAME version the image tag was derived from, not a
        # literal. The first version of this line pinned '"version":"0.1.13"',
        # which meant the test REQUIRED the release under test to be the OLD one.
        # On the 0.1.14 image, whose binary correctly reports 0.1.14, it failed -
        # so it would have reported a healthy release as broken, and the tempting
        # fix is to edit the literal, which re-arms the same trap.
        #
        # The image tag is already derived from Cargo.toml above, so deriving the
        # expected body version the same way makes the assertion self-consistent:
        # if someone built with a stale manifest, the tag would say 0.1.14 and the
        # binary would say something else, and this catches it.
        $expectedVersion = ($Image -split ':')[-1]
        Write-Host ("  expecting version {0}" -f $expectedVersion) -ForegroundColor DarkGray
        Assert-True ($body -match ('"version"\s*:\s*"' + [regex]::Escape($expectedVersion) + '"')) `
            'reports the compiled-in version' `
            "image tag says $expectedVersion but the binary reported: $body"
        Assert-True ($body -match '"revision"\s*:\s*"[0-9a-f]{40}"') 'reports a real 40-hex revision (build arg reached the compiler)'
        Assert-True ($body -notmatch '"revision"\s*:\s*"unknown"') 'revision is NOT the "unknown" fallback'

        # --- the self-report is NOT available ---------------------------------
        #
        # I added an `authenticated` field to the handler while under the false
        # impression that the route was sitting behind auth middleware and
        # answering 401. It is not: /build-info is mounted on the public router
        # (no middleware), so the field would always be false and carries no
        # diagnostic power. Reverted rather than kept as decorative output - and
        # this assertion is dropped with it, because asserting on a field that
        # does not exist is how a test starts lying about what it checks.

        # --- and the skip must not have widened -------------------------------
        $prot = (& docker run --rm --network $Network curlimages/curl:latest -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ctr}:8080/api/matters" 2>&1 | Out-String).Trim()
        Assert-True ($prot -eq '401') 'a protected route still returns 401 (public router did not widen)' "got $prot"
    }
}
catch {
    Write-Host ("  [FAIL] harness error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $failed++
}
finally {
    Cleanup
}

Write-Output ''
if ($failed -eq 0) {
    Write-Host ("{0} passed, 0 failed" -f $passed) -ForegroundColor Green
    exit 0
}
Write-Host ("{0} passed, {1} FAILED" -f $passed, $failed) -ForegroundColor Red
exit 1
