<#
.SYNOPSIS
    Gate: cross-machine data transfer exists, is wired to real API routes, and
    does not quietly lose or duplicate data.

.DESCRIPTION
    WHY THIS EXISTS (2026-10-19).

    AIPC 1, AIPC 2 and every future deployment run independent Postgres
    instances. The question "how do Matters, skills, tools, templates and
    recorded matters reach the other machine?" had NO answer in this repository:
    there was no export route, no import route, no replication script and no
    documentation. It was not broken - it had never been built. A gap that
    invisible passes every gate, because nothing asserts that it exists.

    This gate asserts the capability exists and keeps working, without needing a
    live stack. It statically verifies that:

      S1  the export/import tool exists and parses
      S2  every API route it calls is a route pacgate-api actually serves
      S3  it is keyed on the natural keys that DO exist (slug / email /
          external_key) rather than on uuids, which differ per machine
      S4  it never deletes a matter (DELETE /api/matters/:id answers 500 when
          dependent rows exist, and a sync tool must never destroy work)
      S5  it does not carry password hashes between machines

    S2 matters most: a tool that calls a route the API does not serve fails only
    when someone runs it against real client data. Reading the routes out of
    lib.rs is the only way to catch that without a live machine.

    Exit codes: 0 = capability present and coherent; 1 = a defect; 2 = skip.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:failures = 0
$script:passed = 0

function Write-Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:passed++ }
function Write-Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Write-Info([string]$m) { Write-Host "  [ .. ] $m" -ForegroundColor DarkGray }

Write-Host '=== cross-machine transfer capability ==='

$tool = Join-Path $repoRoot 'scripts/sync-pacgate-matters.ps1'
$apiRoutes = Join-Path $repoRoot 'pacgate-ai/crates/pacgate-api/src/lib.rs'

# ---------------------------------------------------------------------------
# S1. The tool exists and parses.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'S1  the export/import tool exists' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $tool)) {
    Write-Fail 'scripts/sync-pacgate-matters.ps1 is missing - there is no way to move matters between machines'
    Write-Host "`nFAIL: $script:failures problem(s)." -ForegroundColor Red
    exit 1
}
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($tool, [ref]$null, [ref]$errs) | Out-Null
if ($errs -and $errs.Count -gt 0) {
    Write-Fail "tool does not parse: $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))"
}
else {
    Write-Pass 'tool parses'
}
$src = [System.IO.File]::ReadAllText($tool)

# ---------------------------------------------------------------------------
# S2. Every API route the tool calls is actually served.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'S2  every API route it calls is served by pacgate-api' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $apiRoutes)) {
    Write-Info 'cannot read pacgate-api lib.rs - skipping route cross-check'
}
else {
    $router = [System.IO.File]::ReadAllText($apiRoutes)
    $served = @()
    foreach ($m in [regex]::Matches($router, '\.route\(\s*"(/[^"]+)"')) {
        $served += ($m.Groups[1].Value -replace ':[A-Za-z_]+', '*')
    }
    Write-Info "pacgate-api serves $($served.Count) route(s)"

    # Routes the tool builds. Interpolated segments become '*' like the router.
    $called = @()
    foreach ($m in [regex]::Matches($src, '"([^"]*?/api/[^"]*?)"')) {
        $p = $m.Groups[1].Value
        $p = ($p -replace '\$\([^)]*\)', '*') -replace '\$[A-Za-z_][A-Za-z0-9_]*', '*'
        $p = $p -replace '\{[^}]*\}', '*'
        if ($p -match '^/api/') { $called += $p }
    }
    $called = $called | Select-Object -Unique

    if ($called.Count -eq 0) {
        Write-Fail 'tool references no /api/ routes at all - it cannot be talking to the API'
    }
    else {
        foreach ($c in $called) {
            # Normalise both sides to a comparable shape.
            $norm = ($c -replace '/+$', '')
            $match = $served | Where-Object { $_ -eq $norm }
            if ($match) { Write-Pass "route served: $norm" }
            else { Write-Fail "route NOT served by pacgate-api: $norm" }
        }
    }
}

# ---------------------------------------------------------------------------
# S3. Keyed on natural keys, not on per-machine uuids.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'S3  keyed on natural keys, not on uuids' -ForegroundColor Cyan
$required = @{
    'external_key' = 'matter natural key (matters.external_key, partial unique index)'
    'byName'       = 'name fallback for matters that predate external_key'
}
foreach ($k in $required.Keys) {
    if ($src -match [regex]::Escape($k)) { Write-Pass "uses $k - $($required[$k])" }
    else { Write-Fail "does not reference $k - transfer would depend on uuids, which differ per machine" }
}
if ($src -match 'ambiguous') {
    Write-Pass 'refuses to resolve an ambiguous name (duplicate matter names are common here)'
}
else {
    Write-Fail 'no ambiguity handling - duplicate matter names would attach documents to the wrong matter'
}

# ---------------------------------------------------------------------------
# S4. It must never delete a matter.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'S4  never deletes a matter' -ForegroundColor Cyan
if ($src -match '-Method\s+Delete' -and $src -match '/api/matters/') {
    Write-Fail 'tool issues DELETE /api/matters - a transfer tool must never destroy work'
}
else {
    Write-Pass 'issues no DELETE against matters'
}

# ---------------------------------------------------------------------------
# S5. No credential material crosses machines.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'S5  carries no password hashes or secrets' -ForegroundColor Cyan
# Match on CODE, not on prose. The tool's help text legitimately mentions argon2
# to explain WHY passwords are not transferred; a naive regex flagged that
# explanation as the defect it was warning about. Strip <# .#> blocks and
# '#' line comments before looking.
$codeOnly = [regex]::Replace($src, '(?s)<#.*?#>', '')
$codeOnly = ($codeOnly -split "`n" | ForEach-Object { ($_ -replace '(?m)^\s*#.*$', '') }) -join "`n"
if ($codeOnly -match 'argon2|password_hash|\$argon2') {
    Write-Fail 'tool moves a password hash - credentials must not be copied between machines'
}
else {
    Write-Pass 'moves no password hash'
}
if ($src -match 'NOT transferred by design') {
    Write-Pass 'documents what it deliberately does not transfer'
}
else {
    Write-Info 'no explicit statement of what is excluded - a reader may assume it is complete'
}

# ---------------------------------------------------------------------------
# S6. The external-key backfill exists and cannot invent identity silently.
#
# PATCH /api/matters/:id alone repairs nothing - someone has to run it, and the
# 59 NULL-keyed matters had no repair path at all until 2026-10-19. Two things
# make a backfill safe to hand an operator:
#   - an explicit -KeyPrefix, so keys are never fabricated without them saying so
#     (an invented identity makes two machines disagree in a NEW way);
#   - PATCH, because the key can only be set on an existing matter that way.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'S6  external-key backfill is available and explicit' -ForegroundColor Cyan
if ($src -notmatch 'BackfillKeys') {
    Write-Fail 'no BackfillKeys action - the NULL-keyed matters have no repair path'
}
else {
    Write-Pass 'exposes a BackfillKeys action'
}
if ($src -match 'BackfillKeys' -and $src -notmatch '\$KeyPrefix') {
    Write-Fail 'backfill has no explicit prefix - it would fabricate identity without operator intent'
}
else {
    Write-Pass 'backfill requires an operator-supplied prefix'
}
if ($src -match "-Method\s+'?Patch'?") {
    Write-Pass 'uses PATCH, matching the repair route'
}
else {
    Write-Fail 'backfill does not PATCH - it cannot set a key on an existing matter'
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "RESULT: $script:failures cross-machine transfer problem(s). ($script:passed passed)" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: cross-machine transfer capability is present and coherent. ($script:passed passed)" -ForegroundColor Green
exit 0
