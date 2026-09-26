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

Push-Location $workspace
try {
    Write-Host '=== Rust gate: pacgate-redact tests ===' -ForegroundColor Cyan
    & $cargo test -p pacgate-redact --all-targets 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  FAIL cargo test -p pacgate-redact' -ForegroundColor Red
        exit 1
    }

    Write-Host '=== Rust gate: pacgate-redact clippy -D warnings ===' -ForegroundColor Cyan
    & $cargo clippy -p pacgate-redact --all-targets -- -D warnings 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  FAIL cargo clippy -D warnings -p pacgate-redact' -ForegroundColor Red
        exit 1
    }

    Write-Host '  PASS pacgate-redact: tests + clippy clean' -ForegroundColor Green
    exit 0
}
finally {
    Pop-Location
}
