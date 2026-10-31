# Guard: every connector's key variable is named consistently, and a connector
# that ships must be registered.
#
# WHY THIS EXISTS (measured 2026-10-31)
#
# `pacgate-search` reads COURTLISTENER_API_KEY. Both compose files and plans/013
# told operators to set COURT_LISTENER_API_KEY instead. Nothing reads that name, so
# the connector reported available=false forever and the only symptom was "this
# source never returns results" - no error, no log line, nothing to search for.
# Measured baseline: 4 of 11 connectors available.
#
# A key name is a contract between the code and the operator's .env. This gate
# asserts the contract in both directions: every key the code reads is documented,
# and no documented connector key is one the code ignores.
#
# WHAT IS ASSERTED
#   K1 every `std::env::var("<X>_API_KEY")` in pacgate-search is documented
#   K2 no connector key documented for the operator is absent from the code
#   K3 every connector struct is registered in default_router()
#   K4 a keyed connector is inert without a key, so a missing key cannot break a
#      machine - and `search` never propagates an error
#   K5 every source_level is a variant the SourceLevel enum actually derives
#
# Exit 2 means CANNOT CHECK.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$lib = 'pacgate-ai/crates/pacgate-search/src/lib.rs'
$composes = @('deploy/client-bundle/compose.prod.yaml',
              'deploy/client-bundle/compose.bundle.yaml')
$envExample = 'deploy/client-bundle/.env.example'
$core = 'pacgate-ai/crates/pacgate-core/src/lib.rs'

$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== connector registry ===' -ForegroundColor Cyan
Check 'the search crate exists' (Test-Path $lib) $lib
if (-not (Test-Path $lib)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$src = Get-Content $lib -Raw

# ── K1: the key names the code reads must be documented ──────────────────────
$codeKeys = @()
foreach ($m in [regex]::Matches($src, 'std::env::var\("([A-Z0-9_]*_API_KEY)"\)')) {
    $codeKeys += $m.Groups[1].Value
}
$codeKeys = @($codeKeys | Sort-Object -Unique)
Write-Host ("         code reads: {0}" -f ($codeKeys -join ', ')) -ForegroundColor DarkGray
Check 'K1 the crate reads at least one API key' ($codeKeys.Count -gt 0)

$docText = ''
foreach ($f in @($composes + $envExample)) {
    if (Test-Path $f) { $docText += (Get-Content $f -Raw) }
}

foreach ($k in $codeKeys) {
    # A documented key may be commented out (`#FIRECRAWL_API_KEY=`), which is the
    # intended shape: the operator uncomments it. Match the name anywhere.
    Check "K1 $k is documented for the operator" ($docText -match [regex]::Escape($k)) `
          "nothing in the compose comments or .env.example names $k"
}

# ── K2: the typo direction ────────────────────────────────────────────────────
# SCOPE, or this assertion is a false-failure machine: the same files document
# OPENVIKING_API_KEY and OPENVIKING_ROOT_API_KEY, which deer-flow and the OpenViking
# container read and pacgate-search legitimately does not. Verified: an unscoped scan
# yields four "phantoms", two of which are correct-by-design. So the scan is limited
# to the lines that list connector keys, which is the only place the contract holds.
$connectorBlock = ''
foreach ($f in $composes) {
    if (-not (Test-Path $f)) { continue }
    $inBlock = $false
    foreach ($line in (Get-Content $f)) {
        if ($line -match 'connector API keys') { $inBlock = $true; $connectorBlock += "$line`n"; continue }
        if ($inBlock) {
            if ($line -match '^\s*#') { $connectorBlock += "$line`n" }
            else { $inBlock = $false }
        }
    }
}

$docKeyTokens = @()
foreach ($m in [regex]::Matches($connectorBlock, '\b([A-Z][A-Z0-9_]*_API_KEY)\b')) {
    $docKeyTokens += $m.Groups[1].Value
}
$docKeyTokens = @($docKeyTokens | Sort-Object -Unique)
Check 'K2 the connector-key comment block was found' ($docKeyTokens.Count -ge 5) `
      "scanned $($docKeyTokens.Count) key(s); the 'connector API keys' comment may have been reworded"

$phantom = @($docKeyTokens | Where-Object { $codeKeys -notcontains $_ })
Check 'K2 no documented connector key is absent from the code' `
      ($phantom.Count -eq 0) `
      ("documented but never read: {0} - an operator following this gets a connector that is silently unavailable" -f ($phantom -join ', '))

# ── K3: registration ─────────────────────────────────────────────────────────
Check 'K3 FirecrawlConnector is defined' ($src -match 'pub struct FirecrawlConnector')

# The router FUNCTION BODY only. Two false passes were caught here by red-checking:
# `FirecrawlConnector::new(` also appears in the test module, so a whole-file match
# passed even with the registration deleted; and `Substring(routerStart)` still ran to
# EOF, so the test module matched there too. Both showed PASS on a broken router.
# Bounding on the first column-0 closing brace is what makes this an assertion.
$routerStart = $src.IndexOf('pub fn default_router')
Check 'K3 default_router was located' ($routerStart -ge 0)
$routerBody = ''
if ($routerStart -ge 0) {
    $routerEnd = $src.IndexOf("`n}", $routerStart)
    $routerBody = if ($routerEnd -gt $routerStart) { $src.Substring($routerStart, $routerEnd - $routerStart) } else { $src.Substring($routerStart) }
}
Check 'K3 FirecrawlConnector is registered in default_router' `
      ($routerBody -match 'FirecrawlConnector::new\(') `
      'the connector is defined but never added to the router, so /api/search can never reach it'

# Every connector struct must appear in the router body, or it is dead code.
$connectors = @([regex]::Matches($src, 'pub struct ([A-Za-z0-9]+Connector)') | ForEach-Object { $_.Groups[1].Value })
$unregistered = @()
foreach ($c in $connectors) {
    if ($routerBody -notmatch [regex]::Escape($c)) { $unregistered += $c }
}
Check 'K3 every connector struct is registered in default_router' `
      ($unregistered.Count -eq 0) `
      ("defined but never registered: {0}" -f ($unregistered -join ', '))

# ── K4: a missing key cannot break a machine ────────────────────────────────
$firecrawlImpl = [regex]::Match($src, 'impl DataSourceConnector for FirecrawlConnector\s*\{(?s)(.*?)\n\}')
Check 'K4 the Firecrawl impl was found' $firecrawlImpl.Success
if ($firecrawlImpl.Success) {
    Check 'K4 Firecrawl is_available is api_key.is_some()' `
          ($firecrawlImpl.Groups[1].Value -match 'fn is_available\(&self\) -> bool \{ self\.api_key\.is_some\(\) \}')
    Check 'K4 Firecrawl search returns empty without a key' `
          ($firecrawlImpl.Groups[1].Value -match 'None => return Vec::new\(\)')

    # Only `search` must never propagate an error - the router aggregates and one
    # dead source must not fail the whole call. `health_check` is the opposite: it
    # MUST be able to report Auth/RateLimited/Unavailable, which is its whole job.
    # Verified against the proposed impl: an unscoped `notmatch 'return Err'` fails
    # on health_check's own (correct) error returns.
    $searchFn = [regex]::Match($firecrawlImpl.Groups[1].Value, 'async fn search\(&self, query: &SearchQuery\) -> Vec<SearchResult> \{(?s)(.*?)\n    \}')
    Check 'K4 the search function was isolated' $searchFn.Success
    if ($searchFn.Success) {
        Check 'K4 search never propagates an error' `
              ($searchFn.Groups[1].Value -notmatch 'return Err\(') `
              'search must log and return an empty Vec; only health_check reports errors'
    }
}

# An empty-but-set env var must not count as a key, or an operator who uncomments
# `#FIRECRAWL_API_KEY=` without pasting a value gets a 401 on every search.
Check 'K4 the router filters an empty key value' `
      ($src -match 'filter\(\|k\| !k\.trim\(\)\.is_empty\(\)\)') `
      'std::env::var returns Ok("") for a set-but-empty variable; .ok() alone is not enough'

# ── K5: source_level discipline ──────────────────────────────────────────────
$levels = @()
if (Test-Path $core) {
    $coreSrc = Get-Content $core -Raw
    $enumBody = [regex]::Match($coreSrc, 'pub enum SourceLevel\s*\{(?s)(.*?)\n\}')
    if ($enumBody.Success) {
        foreach ($v in [regex]::Matches($enumBody.Groups[1].Value, '^\s*([A-Z][A-Za-z0-9]+),', 'Multiline')) {
            # AuthorityVerified -> authority_verified, AuxiliaryDB -> auxiliary_db.
            #
            # The naive `(?<!^)([A-Z]) -> _$1` is WRONG here: it splits the trailing
            # acronym in AuxiliaryDB into `auxiliary_d_b`, which then never matches
            # the code's `auxiliary_db` and produces a false failure. Verified:
            #   naive      AuxiliaryDB -> auxiliary_d_b   (wrong)
            #   corrected  AuxiliaryDB -> auxiliary_db    (right)
            # Rust's serde rename_all = "snake_case" does the same two-step split.
            $snake = $v.Groups[1].Value -creplace '([a-z0-9])([A-Z])', '$1_$2' -creplace '([A-Z])([A-Z][a-z])', '$1_$2'
            $levels += $snake.ToLower()
        }
    }
}
Check 'K5 the SourceLevel variants were parsed' ($levels.Count -ge 3) "parsed: $($levels -join ', ')"

$usedLevels = @([regex]::Matches($src, 'source_level:\s*"([a-z_]+)"\.to_string\(\)') | ForEach-Object { $_.Groups[1].Value })
$usedLevels = @($usedLevels | Sort-Object -Unique)
$badLevels = @($usedLevels | Where-Object { $levels -notcontains $_ })
Check 'K5 every source_level is a real SourceLevel variant' `
      ($badLevels.Count -eq 0) `
      "not in the enum: $($badLevels -join ', ') (enum: $($levels -join ', '))"

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
