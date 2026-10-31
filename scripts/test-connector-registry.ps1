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

# ── K6: the registry must not claim an implementation that does not exist ────
# Measured 2026-10-31 before the fix: 11 entries claimed `implemented: true` while only
# 10 had a `DataSourceConnector` impl - `ansvar` was the difference. Both endpoints are
# user-visible and they disagreed: /api/search/registry listed it as implemented while
# /api/search/connectors omitted the name. An operator reads the first and concludes the
# connector works.
$implNames = @()
foreach ($m in [regex]::Matches($src, 'impl DataSourceConnector for ([A-Za-z0-9]+)Connector')) {
    $implNames += $m.Groups[1].Value
}

# ConnectorMetadata struct name -> registry key, for the ones that have an impl.
$implToKey = @{
    'YuanDian'        = 'yuandian'
    'PkuLaw'          = 'pkulaw'
    'Qcc'             = 'qcc'
    'FyOpen'          = 'fyopen'
    'CourtListener'   = 'courtlistener'
    'SecEdgar'        = 'sec_edgar'
    'Gleif'           = 'gleif'
    'Vaquill'         = 'vaquill'
    'EurLex'          = 'eur_lex'
    'OpenCorporates'  = 'opencorporates'
    'Firecrawl'       = 'firecrawl'
}

$implKeys = @()
foreach ($impl in $implNames) {
    if ($implToKey.ContainsKey($impl)) { $implKeys += $implToKey[$impl] }
}
$implKeys = @($implKeys | Sort-Object -Unique)

# Split STRUCTURALLY on the entry constructor rather than scanning backwards a fixed
# number of characters. A 1400-char window was measured too small: the ansvar entry's
# `implemented:` line sits 1654 chars after its `name:`, so the window never reached it
# and the assertion passed on the broken state - a vacuous gate. Splitting on
# `.with_entry(ConnectorMetadata` makes the boundary the entry itself, which cannot go
# stale when a comment grows.
$implementedKeys = @()
$entryBlocks = $src -split '\.with_entry\(ConnectorMetadata\s*\{'
foreach ($block in $entryBlocks) {
    # Each block runs to the closing of that entry; the first name in it is its own.
    $nameMatch = [regex]::Match($block, 'name:\s*"([a-z_\-]+)"\.into\(\)')
    if (-not $nameMatch.Success) { continue }
    # Trim at the next entry boundary is implicit (we already split), but a block can
    # still contain the NEXT struct's tail; the `implemented:` flag for THIS entry is
    # the first one in the block.
    $implMatch = [regex]::Match($block, 'implemented:\s*(true|false)')
    if ($implMatch.Success -and $implMatch.Groups[1].Value -eq 'true') {
        $implementedKeys += $nameMatch.Groups[1].Value
    }
}
$implementedKeys = @($implementedKeys | Sort-Object -Unique)

$claimsWithoutImpl = @()
foreach ($k in $implementedKeys) {
    if ($implKeys -notcontains $k) { $claimsWithoutImpl += $k }
}
Check 'K6 no registry entry claims an implementation that does not exist' `
      ($claimsWithoutImpl.Count -eq 0) `
      ("claimed implemented with no DataSourceConnector: {0} - /api/search/registry and /api/search/connectors disagree about these" -f ($claimsWithoutImpl -join ', '))

Write-Host ("         implemented claims ({0}): {1}" -f $implementedKeys.Count, ($implementedKeys -join ', ')) -ForegroundColor DarkGray
Write-Host ("         connectors with an impl ({0}): {1}" -f $implKeys.Count, ($implKeys -join ', ')) -ForegroundColor DarkGray

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
