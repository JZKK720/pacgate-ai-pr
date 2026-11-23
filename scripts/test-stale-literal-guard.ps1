# Guard: no gate may hardcode the qm port, and none may hardcode a released image tag.
#
# WHY THIS EXISTS
#
# Plan 035 §7.2 named the class and said it was "worth adding when someone next
# touches the gate harness": a version literal in a script outlives the version.
# The 0.2.37 audit fixed three instances by deriving from the bundle pin. Then the
# qm 0.1.18 migration reproduced it on the port axis and nobody noticed, because
# both gates still produced a confident verdict:
#
#   benchmark-round-trips.ps1  ':8181'  -> "[FAIL] no-response"
#   smoke-full-stack.ps1       ':8181'  -> "[SKIP] qm not running (000)"
#
# The stack was healthy on :8182 the whole time. A gate that reports a deleted
# service as a broken product is worse than no gate: it spends the reader's
# attention on a fault that does not exist, which is how a suite loses authority.
#
# WHAT IS ASSERTED
#   A1 no script names a qm port literal (8180/8181/8182/8183) outside the resolver
#   A2 no script names a ghcr image tag literal outside an explicit negative fixture
#   A3 the resolver exists and answers a URL for this repo
#
# A2's allowlist is deliberately explicit rather than a pattern: test-upload-symlink-guard
# genuinely needs a fixed OLD tag to prove a migration, and test-stack-version-coherence
# needs two different tags. Everything else must derive.
#
# Exit 2 = CANNOT CHECK (scripts dir absent) and is never read as a failure.

[CmdletBinding()]
param([string]$RepoRoot = '')

$ErrorActionPreference = 'Continue'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$scripts = Join-Path $RepoRoot 'scripts'
if (-not (Test-Path -LiteralPath $scripts)) {
    Write-Host 'CANNOT CHECK - no scripts directory'
    exit 2
}

$script:pass = 0; $script:fail = 0
function Ok($m)  { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:fail++ }

Write-Host "=== stale-literal guard (scripts/) ===" -ForegroundColor Cyan

# ── A1: qm port literals ───────────────────────────────────────────────────────
# The resolver itself is the only legitimate home for a qm default port.
$qmAllow = @('lib\QmEndpoint.ps1')
$portRe = [regex]'\b(localhost|127\.0\.0\.1):818[0-3]\b'
$qmHits = @()
foreach ($f in (Get-ChildItem -LiteralPath $scripts -Recurse -Filter '*.ps1' -File)) {
    $rel = $f.FullName.Substring($scripts.Length).TrimStart('\')
    if ($qmAllow -contains $rel) { continue }
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
        $n++
        # A comment explaining the retired port is documentation, not a probe.
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($portRe.IsMatch($line)) { $qmHits += "$rel`:$n  $($line.Trim())" }
    }
}
if ($qmHits.Count -eq 0) { Ok 'no script hardcodes a qm port outside lib/QmEndpoint.ps1' }
else {
    Bad "a script hardcodes a qm port - use Get-QmEndpoint (lib/QmEndpoint.ps1):"
    $qmHits | Select-Object -First 8 | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
}

# ── A2: released image tag literals ───────────────────────────────────────────
$tagAllow = @(
    'test-upload-symlink-guard.ps1',      # needs a fixed OLD tag to prove a migration
    'test-stack-version-coherence.ps1',   # needs two tags; that is the assertion
    'test-release-provenance.ps1',        # compares pinned vs baked; both explicit
    'lib\Release-ImageState.ps1'
)
$tagRe = [regex]'ghcr\.io/jzkk720/[a-z0-9-]+:\d+\.\d+\.\d+'
$tagHits = @()
foreach ($f in (Get-ChildItem -LiteralPath $scripts -Recurse -Filter '*.ps1' -File)) {
    $rel = $f.FullName.Substring($scripts.Length).TrimStart('\')
    if ($tagAllow -contains $rel) { continue }
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
        $n++
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($tagRe.IsMatch($line)) { $tagHits += "$rel`:$n  $($line.Trim())" }
    }
}
if ($tagHits.Count -eq 0) { Ok 'no script hardcodes a released image tag outside an explicit fixture' }
else {
    Bad "a script hardcodes a released image tag - derive it from compose.bundle.yaml:"
    $tagHits | Select-Object -First 8 | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
}

# ── A3: the resolver answers ──────────────────────────────────────────────────
$lib = Join-Path $scripts 'lib/QmEndpoint.ps1'
if (Test-Path -LiteralPath $lib) {
    . $lib
    $u = Get-QmEndpoint -RepoRoot $RepoRoot
    if ($u -match '^https?://') { Ok "the qm endpoint resolver answers: $u" }
    else { Bad "the resolver returned a non-URL: '$u'" }
} else {
    Bad 'lib/QmEndpoint.ps1 is missing - every qm probe is back to a literal'
}

Write-Host ''
Write-Host "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
