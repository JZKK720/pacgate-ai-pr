<#
.SYNOPSIS
    Count or remove test-fixture matters that accumulated on a machine.

.DESCRIPTION
    WHY THIS EXISTS (2026-10-19).

    Several e2e scripts create a matter to exercise a pipeline against real HTTP.
    `test-sanitizer-e2e.ps1` used a hard-coded name, "Sanitizer E2E", and cleaned
    up only its CONTAINERS - never the row. Measured consequence on the dev box:
    50 separate matters of that name between 2026-10-12 and 2026-10-19, one per
    run, each holding a single "case" document. (The e2e script now removes its
    own matter; this tool cleans up what already leaked.)

    These are NOT caches. A cache can be deleted and rebuilt transparently; these
    are durable database rows with documents attached. So they are removed by an
    explicit, named rule and never silently.

    WHAT IT MATCHES
    Only matters whose name looks like a test fixture: the known fixture names
    below, plus any name matching a test-ish pattern (contains "e2e", "test",
    "fixture", or a "fmtcoverage-<hex>" suffix). Real client matters are named by
    the firm and do not match.

    WHAT IT WILL NOT DO
    - It never deletes a matter that has a non-empty external_key (that is a
      deliberately-identified matter).
    - It refuses to run without -Delete unless -WhatIf is used, so a bare
      invocation only reports.
    - It never touches documents, tenants, users or audit rows directly; the
      matter API cascade handles children, and anything it cannot delete safely it
      reports.

    SAFETY: run with -WhatIf first. It prints every match with its document count
    before changing anything.

.PARAMETER BaseUrl
    Pacgate API root including /pacgate when going through nginx.

.EXAMPLE
    # Report only - the default when -Delete is absent.
    .\scripts\clean-test-fixtures.ps1 -BaseUrl http://localhost:8089/pacgate `
        -Email admin@pacgate-law.com -Password '...'

.EXAMPLE
    # Actually delete the recognized fixtures.
    .\scripts\clean-test-fixtures.ps1 -BaseUrl http://localhost:8089/pacgate `
        -Email admin@pacgate-law.com -Password '...' -Delete

.NOTES
    Exit codes: 0 = ok (or nothing to do); 1 = something failed; 2 = cannot run.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BaseUrl = 'http://localhost:8089/pacgate',
    [Parameter(Mandatory = $true)][string]$Email,
    [Parameter(Mandatory = $true)][string]$Password,

    # Delete the matches. Without this the script only reports.
    [switch]$Delete
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$script:failures = 0

# Fixture names seen in this repo, plus patterns that cannot be a client matter.
$exactNames = @('Sanitizer E2E', 'Patch Target A', 'Patch Target B')
$pattern = '(?i)(e2e|fixture|^test[ -]|^fmtcoverage-|^xl\d+$|^piitest$|^leaktest$|^xlsxloop$|^txtnative-)'

function Write-Ok([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Bad([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Write-Note([string]$m) { Write-Host "  [ .. ] $m" -ForegroundColor DarkGray }

$body = @{ email = $Email; password = $Password } | ConvertTo-Json -Compress
try {
    $login = Invoke-RestMethod -Uri "$BaseUrl/api/auth/login" -Method Post `
        -ContentType 'application/json' -Body $body -TimeoutSec 30
}
catch {
    $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
    if ($code -eq 401) { Write-Bad "login rejected for $Email"; exit 1 }
    Write-Bad "cannot reach $BaseUrl ($($_.Exception.Message))"; exit 2
}
$h = @{ Authorization = "Bearer $($login.token)" }

Write-Host '=== test-fixture matters ==='

$all = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Headers $h -Method Get -TimeoutSec 60
if ($null -eq $all) { $all = @() }

$matches = @($all | Where-Object {
    $n = "$($_.name)"
    ($exactNames -contains $n) -or ($n -match $pattern)
})

if ($matches.Count -eq 0) {
    Write-Ok 'no test-fixture matters found'
    exit 0
}

# Group so the report is readable: 50 identical names collapse to one line.
$grouped = $matches | Group-Object name | Sort-Object Count -Descending
Write-Host ''
foreach ($g in $grouped) {
    Write-Host ("  {0,4} x  {1}" -f $g.Count, $g.Name) -ForegroundColor Yellow
}
Write-Host ''
Write-Ok "$($matches.Count) fixture matter(s) in $($grouped.Count) name group(s)"

# Anything with an external_key is deliberately identified - never a fixture.
$protected = @($matches | Where-Object { $_.external_key })
if ($protected.Count -gt 0) {
    Write-Warn "$($protected.Count) match(es) have an external_key and will NOT be touched"
    $matches = @($matches | Where-Object { -not $_.external_key })
}

# Count child documents per matter so the operator sees what leaves with them.
$docTotal = 0
foreach ($m in $matches) {
    try {
        $docs = @(Invoke-RestMethod -Uri "$BaseUrl/api/matters/$($m.id)/documents" -Headers $h -Method Get -TimeoutSec 30)
        $docTotal += $docs.Count
    }
    catch { }
}
Write-Note "they hold $docTotal document(s) in total"

if (-not $Delete) {
    Write-Host ''
    Write-Host "  REPORT ONLY. Re-run with -Delete to delete these $($matches.Count) matter(s)." -ForegroundColor Cyan
    Write-Note 'These are database rows, not a cache: they do not come back on rebuild.'
    exit 0
}

Write-Host ''
$deleted = 0
foreach ($m in $matches) {
    if (-not $PSCmdlet.ShouldProcess("matter '$($m.name)' ($($m.id))", 'delete')) { continue }
    try {
        Invoke-RestMethod -Uri "$BaseUrl/api/matters/$($m.id)" -Method Delete -Headers $h -TimeoutSec 30 | Out-Null
        $deleted++
    }
    catch {
        # DELETE answers 500 when dependent rows survive (e.g. a redaction ledger
        # row still referencing the document). Report it rather than forcing a
        # raw SQL cascade that could orphan audit data.
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        Write-Warn "could not delete '$($m.name)' ($($m.id)) HTTP $code - it may have ledger/audit rows"
    }
}

Write-Host ''
Write-Ok "deleted $deleted of $($matches.Count) fixture matter(s)"
if ($script:failures -gt 0) { exit 1 }
exit 0
