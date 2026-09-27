# Asserts deer-flow's memory lane is actually the SANITIZED one, and that the
# configuration cannot silently degrade to the unsanitized disk lane.
#
# WHY THIS GATE EXISTS
#
# deer-flow selects its memory storage by class PATH, at runtime:
#
#     storage_class: pacgate_deerflow_adapter.storage.PacgateMemoryStorage
#
# and get_memory_storage() wraps the whole instantiation in a bare
# `except Exception` that logs one line and substitutes FileMemoryStorage():
#
#     except Exception as e:
#         logger.error("Failed to load memory storage %s, falling back to
#                       FileMemoryStorage: %s", storage_class_path, e)
#         _storage_instance = FileMemoryStorage()
#
# That fallback is invisible from outside. A misconfigured install answers every
# health check, serves every request, and writes UNSANITIZED memory-prose to
# disk - bypassing all three matter-memory guards (the 422 scope rule, the
# 64 KiB cap, and the If-Match revision guard), because none of them live in
# FileMemoryStorage. This is not hypothetical: it already happened on this
# machine. Two native files under users/<uid>/agents/*/memory.json carry real
# matter prose ("sanitizing documents (e.g. <uuid>) at data level T3") written
# in the native v1.0 schema the adapter never emits.
#
# The adapter raises on a missing PACGATE_MATTER_ID (storage.py:62), which is
# exactly the condition that trips the fallback - and .env.example shipped it
# BLANK. So the default fresh-install path was the silent-degradation path.
#
# SCOPE DISCIPLINE: this asserts the CONFIGURATION, not the behaviour. A pass
# means "the shipped config selects the adapter, feeds it the env it requires,
# and is mounted where the server reads it" - not "the adapter sanitized
# correctly". That is tests/test-memory-scope.ps1's subject (the 422 rule) and
# the adapter's own 8 pytest rows.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. "Cannot check" is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== deer-flow memory lane ===' -ForegroundColor Cyan

$bundle = 'deploy/client-bundle'

# ---------------------------------------------------------------------------
# 1. The config still names the adapter.
# ---------------------------------------------------------------------------
$cfgPath = Join-Path $bundle 'deer-flow-config.yaml'
if (-not (Test-Path $cfgPath)) {
    Write-Host "  exit 2 - $cfgPath not found; cannot verify which storage class ships" -ForegroundColor Yellow
    exit 2
}

$cfg = Get-Content $cfgPath -Raw
# Anchored to the END OF LINE and to the `storage_class:` KEY, so a bare class
# name inside a comment cannot satisfy it. Indentation is deliberately NOT
# pinned: the first version of this check hardcoded 4 spaces, failed against
# correct code, and reported the right value as wrong. What matters is the key,
# not the column it sits in.
if ($cfg -match '(?m)^\s*storage_class:\s*pacgate_deerflow_adapter\.storage\.PacgateMemoryStorage\s*$') {
    Pass 'memory.storage_class selects PacgateMemoryStorage'
}
else {
    $actual = ([regex]::Match($cfg, '(?m)^\s*storage_class:\s*(\S+)')).Groups[1].Value
    if (-not $actual) { $actual = '<no storage_class key found>' }
    Fail "memory.storage_class is '$actual', not the Pacgate adapter - deer-flow will write memory with its own storage class, outside every matter-memory guard"
}

# ---------------------------------------------------------------------------
# 2. Every BASE compose that wires the adapter also feeds it its required env.
#
# DISCOVERED, not hardcoded. A base file is one that defines the deer-flow
# service AND wires the adapter's env (PACGATE_API_URL). Override files
# (compose.e2e-override, compose.ocr-override) patch a base and legitimately do
# not repeat it, so requiring the key there would fail on correct files.
# ---------------------------------------------------------------------------
$composes = Get-ChildItem $bundle -Filter 'compose*.yaml' | Sort-Object Name
$wired = 0
foreach ($c in $composes) {
    $text = Get-Content $c.FullName -Raw
    $definesDeerFlow = $text -match '(?m)^\s{2}deer-flow:\s*$'
    $wiresAdapter = $text -match 'PACGATE_API_URL'
    if (-not ($definesDeerFlow -and $wiresAdapter)) { continue }
    $wired++

    if ($text -match '(?m)^\s+PACGATE_MATTER_ID:\s*\S') {
        Pass "$($c.Name) passes PACGATE_MATTER_ID to deer-flow"
    }
    else {
        Fail "$($c.Name) defines the pacgate-wired deer-flow service but does NOT pass PACGATE_MATTER_ID - the adapter raises on a missing matter id, which trips the silent FileMemoryStorage fallback"
    }

    # The adapter reads the config from DEER_FLOW_CONFIG_PATH, which this image
    # defaults to /app/backend/config.yaml. If the bind mount moves, the server
    # reads a DEFAULT config whose storage_class is FileMemoryStorage - again
    # without any error at runtime.
    if ($text -match '\./deer-flow-config\.yaml:/app/backend/config\.yaml') {
        Pass "$($c.Name) mounts the config at the path the server reads"
    }
    else {
        Fail "$($c.Name) does not mount ./deer-flow-config.yaml to /app/backend/config.yaml - the server would read a default config selecting FileMemoryStorage"
    }
}
if ($wired -eq 0) {
    Fail 'no base compose wires PACGATE_API_URL to deer-flow - discovery found nothing, so the loop above asserted nothing'
}

# ---------------------------------------------------------------------------
# 3. The env TEMPLATE must not ship the silent-degradation value.
#
# This is the check that would have caught the real incident. PACGATE_JWT_TOKEN
# is legitimately blank (email/password auth is the alternative), so only the
# matter id is asserted. A blank here is not "unset" - compose substitutes an
# empty string, the adapter's `if not self.matter_id` fires, and the lane
# degrades silently.
# ---------------------------------------------------------------------------
$envExample = Join-Path $bundle '.env.example'
if (Test-Path $envExample) {
    $m = [regex]::Match((Get-Content $envExample -Raw), '(?m)^PACGATE_MATTER_ID=(.*)$')
    if ($m.Success -and $m.Groups[1].Value.Trim().Length -gt 0) {
        Pass '.env.example provides a non-empty PACGATE_MATTER_ID'
    }
    else {
        Fail '.env.example ships PACGATE_MATTER_ID blank - a fresh install copying it gets an empty value, the adapter raises, and deer-flow silently writes UNSANITIZED memory to disk'
    }
}
else {
    Write-Host "  exit 2 - $envExample not found; cannot check the template a fresh install copies" -ForegroundColor Yellow
    $script:failures++
}

# ---------------------------------------------------------------------------
# 4. The adapter still refuses to run without a matter id.
#
# This is the trip-wire the fallback catches. If someone "fixes" the raise to
# default to a placeholder, the silent-degradation path reopens - so the guard
# is asserted in the direction that KEEPS it strict.
# ---------------------------------------------------------------------------
$adapter = 'pacgate-adapters/python/pacgate_deerflow_adapter/storage.py'
if (Test-Path $adapter) {
    $a = Get-Content $adapter -Raw
    if ($a -match 'raise ValueError\("PacgateMemoryStorage requires PACGATE_MATTER_ID"\)') {
        Pass 'the adapter still raises on a missing PACGATE_MATTER_ID'
    }
    else {
        Fail 'the adapter no longer raises on a missing PACGATE_MATTER_ID - if it now defaults the id, deer-flow proceeds with a bogus matter and the silent-degradation path reopens'
    }

    # The adapter must stay API-backed. Any local write reintroduces a disk lane
    # that the 422 scope rule cannot see, because the rule is enforced server-side.
    $writes = @('json.dump', 'write_text', '_get_memory_file_path')
    $found = $writes | Where-Object { $a -match [regex]::Escape($_) }
    if ($found.Count -eq 0) {
        Pass 'the adapter writes only through pacgate-api (no local file lane)'
    }
    else {
        Fail "the adapter gained a local write path ($($found -join ', ')) - a disk lane cannot be reached by the server-side 422 scope rule"
    }
}
else {
    Write-Host "  exit 2 - adapter not found at $adapter; cannot check the trip-wire" -ForegroundColor Yellow
    $script:failures++
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) memory-lane check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: deer-flow memory lane is configured as the sanitized adapter, and cannot degrade silently' -ForegroundColor Green
exit 0
