# Gates the Rust layer, which nothing previously did.
#
# Measured 2026-09-26: run-all-checks.ps1 is 21 PowerShell gates, and neither it
# nor CI (build-ghcr.yml) runs any cargo command. So every Rust assertion in this
# repo - checksum validators, the recall harness, the pipeline tests - ran only
# when a human typed the command. That is why a silent recall miss sat in four
# shipped detectors: there was no mechanism whose job was to notice.
#
# Scoped to -p pacgate-redact deliberately. The workspace has pre-existing clippy
# warnings (pacgate-core 1, pacgate-search 2, pacgate-agent 1, pacgate-api 3,
# measured 2026-09-26), so a --workspace -D warnings gate would be red on arrival
# and be disabled within a week. pacgate-redact alone is clean, so this is a
# ratchet and not a new burden. Widening it is a separate cleanup task.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. A "cannot check" is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
if (-not (Test-Path $cargo)) {
    Write-Host '  exit 2 - cargo not found at the expected path; cannot check' -ForegroundColor Yellow
    exit 2
}

# The workspace root is pacgate-ai/, which is where Cargo.toml lives.
$workspace = Join-Path (Get-Location) 'pacgate-ai'
if (-not (Test-Path (Join-Path $workspace 'Cargo.toml'))) {
    Write-Host "  exit 2 - no Cargo.toml at $workspace; cannot check" -ForegroundColor Yellow
    exit 2
}

# Run a cargo subcommand and report whether it really passed.
#
# Two PowerShell bugs this shim exists to avoid, both measured on 2026-09-26:
#
#  1. `& $cargo ... 2>&1 | Out-String` then reading $LASTEXITCODE does NOT work.
#     After a pipeline, $LASTEXITCODE belongs to the pipeline's last command
#     (Out-String), not to cargo, so a failing cargo can read as success.
#  2. Under Windows PowerShell 5.1, $ErrorActionPreference = 'Stop' turns
#     cargo's stderr - merged by `2>&1` - into a terminating
#     NativeCommandError. The gate then died part-way through its own output.
#
# Symptom before the fix: exit 1 on a CLEAN tree under 5.1, exit 0 under pwsh 7.
# A gate that goes red on clean code is worse than no gate: it gets disabled.
#
# NOTE ON MEASUREMENT: do not diagnose this by piping the gate itself through
# Select-String or Out-String - that clobbers $LASTEXITCODE with the *pipeline's*
# code and makes a working gate look broken and a broken gate look fine. Run it
# with `*> $null` and read $LASTEXITCODE, or run it bare and read the console.
function Invoke-Cargo {
    param([string[]] $Arguments, [string] $Label)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $cargo @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    # Print what cargo said regardless of outcome, so a failure is diagnosable
    # from the gate's own output rather than only from re-running cargo by hand.
    $output | Out-String | Write-Host

    if ($code -ne 0) {
        Write-Host "  FAIL $Label (cargo exit $code)" -ForegroundColor Red
        return $false
    }
    return $true
}

Push-Location $workspace
try {
    Write-Host '=== Rust gate: pacgate-redact tests ===' -ForegroundColor Cyan
    if (-not (Invoke-Cargo @('test', '-p', 'pacgate-redact', '--all-targets') `
                          'cargo test -p pacgate-redact')) {
        exit 1
    }

    Write-Host '=== Rust gate: pacgate-redact clippy -D warnings ===' -ForegroundColor Cyan
    if (-not (Invoke-Cargo @('clippy', '-p', 'pacgate-redact', '--all-targets', '--', '-D', 'warnings') `
                          'cargo clippy -D warnings -p pacgate-redact')) {
        exit 1
    }

    Write-Host '  PASS pacgate-redact: tests + clippy clean' -ForegroundColor Green
    exit 0
}
finally {
    Pop-Location
}
