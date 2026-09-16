<#
.SYNOPSIS
    Detect whether the pinned qm sandbox image still matches its source.

.DESCRIPTION
    The qm agent executes inside a sandbox image recorded in
    `deploy/qm-pacgate/qm.config.jsonc` as a DIGEST
    (`localhost:5000/pacgate-sandboxes@sha256:...`). Digest pinning is correct -
    the isolation boundary should be immutable. But it creates a silent failure
    on update:

        a repo update changes sandbox/ (skills, tools, Dockerfile)
          -> the config still pins the OLD digest
            -> the sandbox is never rebuilt
              -> the agent keeps running the OLD skills and tools
                 with no error anywhere

    `qm sandbox build` alone does not fix it either: it produces a new image
    whose digest is not the one in qm.config.jsonc. The digest must be repinned
    too. This script makes that divergence VISIBLE, which is the minimum needed
    to stop it being silent.

    It does not build or repin anything by itself (see -Write).

.PARAMETER Write
    Record the current sandbox fingerprint into qm.config.jsonc. Run this AFTER
    a `qm sandbox build` + digest repin, when source and digest are known to
    agree. This is the only mode that modifies a file.

.PARAMETER Check
    Compare and report. Exit 0 = current, 1 = drift or not recorded. This is the
    default when no mode is given.

.PARAMETER Json
    Emit JSON instead of prose, for machine consumption.

.EXAMPLE
    ./scripts/qm-sandbox-fingerprint.ps1
    Reports whether sandbox source has changed since the digest was pinned.

.EXAMPLE
    ./scripts/qm-sandbox-fingerprint.ps1 -Write
    After rebuilding the sandbox and repinning the digest in qm.config.jsonc.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Write,
    [switch]$Check,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$qmDir = Join-Path $RepoRoot 'deploy/qm-pacgate'
$config = Join-Path $qmDir 'qm.config.jsonc'

if (-not (Test-Path -LiteralPath $config)) {
    throw "Cannot fingerprint: qm.config.jsonc not found at $config"
}

# --- Hash one file in a way that is identical across machines ---------------
#
# Line endings are the trap here. The same commit checked out with
# core.autocrlf=true (Windows default) and false (Linux) has different BYTES but
# the same content. Hashing raw bytes would report phantom drift on every
# cross-machine comparison - and a drift check that cries wolf gets ignored,
# which is how the real drift gets missed. So text files are normalised to LF
# before hashing, and a BOM is stripped.
function Get-NormalizedHash {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    # Binary files are hashed as-is; normalising them would corrupt the input.
    $isBinary = $false
    foreach ($b in $bytes) { if ($b -eq 0) { $isBinary = $true; break } }

    if ($isBinary) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
        return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $text = $text.TrimStart([char]0xFEFF)          # strip UTF-8 BOM
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")

    $enc = New-Object System.Text.UTF8Encoding($false)
    $norm = $enc.GetBytes($text)
    $sha2 = [System.Security.Cryptography.SHA256]::Create()
    try { $digest2 = $sha2.ComputeHash($norm) } finally { $sha2.Dispose() }
    return (($digest2 | ForEach-Object { $_.ToString('x2') }) -join '')
}

# --- Enumerate the sandbox source -------------------------------------------
#
# Only TRACKED files count. An untracked scratch file in sandbox/ is not part of
# the built image's provenance and must not report drift.
function Get-SandboxFiles {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { throw 'git not found; cannot enumerate tracked sandbox files.' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $git.Source
    $psi.WorkingDirectory = $qmDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    # Capture paths as-is; git quotes unusual names, which these are not.
    $psi.ArgumentList.Add('ls-files')
    $psi.ArgumentList.Add('--')
    $psi.ArgumentList.Add('sandbox')

    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        throw "git ls-files failed (exit $($p.ExitCode)) in $qmDir : $err"
    }

    $paths = @($out -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($paths.Count -eq 0) {
        throw "No tracked files under 'sandbox/' in $qmDir - the fingerprint would be of nothing."
    }
    return $paths
}

function Get-SandboxFingerprint {
    $rel = Get-SandboxFiles

    $lines = foreach ($r in $rel) {
        $abs = Join-Path $qmDir ($r -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $abs)) {
            throw "Tracked file missing from the working tree: $r"
        }
        '{0}  {1}' -f $r, (Get-NormalizedHash -Path $abs)
    }

    # Ordinal sort: culture-sensitive sorting could order paths differently on a
    # different locale, which would change the fingerprint for identical content.
    $arr = [string[]]@($lines)
    [array]::Sort($arr, [System.StringComparer]::Ordinal)

    $payload = ($arr -join "`n") + "`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($enc.GetBytes($payload)) } finally { $sha.Dispose() }
    $fp = (($digest | ForEach-Object { $_.ToString('x2') }) -join '')

    return [pscustomobject]@{
        Fingerprint = $fp
        FileCount   = $arr.Count
        Files       = $arr
    }
}

# Reads the recorded value out of the jsonc. `ConvertFrom-Json` cannot read this
# file (it has `//` comments and a trailing comma), and hand-parsing the whole
# document would be fragile - so this matches the single key it needs.
function Get-RecordedFingerprint {
    $text = [System.IO.File]::ReadAllText($config)
    $m = [regex]::Match($text, '"sourceFingerprint"\s*:\s*"([0-9a-fA-F]{64})"')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return $null
}

function Get-PinnedDigest {
    $text = [System.IO.File]::ReadAllText($config)
    $m = [regex]::Match($text, '"image"\s*:\s*"[^"]*@(sha256:[0-9a-fA-F]{64})"')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return $null
}

$result = Get-SandboxFingerprint
$recorded = Get-RecordedFingerprint
$digest = Get-PinnedDigest

$state = if (-not $recorded) { 'NOT_RECORDED' }
         elseif ($recorded -eq $result.Fingerprint) { 'CURRENT' }
         else { 'DRIFT' }

# --- -Write -----------------------------------------------------------------
if ($Write) {
    if ($state -eq 'CURRENT') {
        Write-Host "[OK] Fingerprint already current - nothing written." -ForegroundColor Green
        exit 0
    }

    $text = [System.IO.File]::ReadAllText($config)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $config -Destination "$config.bak.$stamp" -Force

    if ($recorded) {
        $text = [regex]::Replace($text,
            '"sourceFingerprint"\s*:\s*"[0-9a-fA-F]{64}"',
            '"sourceFingerprint": "' + $result.Fingerprint + '"')
    }
    else {
        # Insert as the first key of the sandbox object so the pin and its
        # provenance read together.
        #
        # MatchEvaluator rather than a replacement string: in .NET regex, '$' in
        # a replacement string is a substitution token, so a fingerprint (or any
        # future value) containing '$' would be silently mangled.
        $replacement = '"sandbox": { "sourceFingerprint": "' + $result.Fingerprint + '",'
        $found = $false
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $script:found = $true
            return $replacement
        }
        $newText = [regex]::Replace($text, '"sandbox"\s*:\s*\{', $evaluator)

        if (-not $found) {
            # Restore and fail rather than write a config missing the field.
            Copy-Item -LiteralPath "$config.bak.$stamp" -Destination $config -Force
            throw 'Could not locate the "sandbox" object in qm.config.jsonc; refusing to write.'
        }
        $text = $newText
    }

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($config, $text, $enc)

    Write-Host "[OK] Recorded sandbox fingerprint $($result.Fingerprint.Substring(0,16))... in qm.config.jsonc" -ForegroundColor Green
    Write-Host "     (previous file backed up to $config.bak.$stamp)" -ForegroundColor Gray
    exit 0
}

# --- Default: report --------------------------------------------------------
if ($Json) {
    [pscustomobject]@{
        state      = $state
        fingerprint = $result.Fingerprint
        recorded    = $recorded
        pinnedDigest = $digest
        fileCount   = $result.FileCount
    } | ConvertTo-Json -Compress
    exit ([int]($state -ne 'CURRENT'))
}

Write-Host '=== qm sandbox provenance ===' -ForegroundColor Cyan
Write-Host ("  source files      : {0}" -f $result.FileCount)
Write-Host ("  source fingerprint: {0}" -f $result.Fingerprint.Substring(0, 16))
if ($digest) {
    Write-Host ("  pinned digest     : {0}" -f $digest.Substring(0, 23))
}
Write-Host ''

switch ($state) {
    'CURRENT' {
        Write-Host '[OK] Sandbox source matches the recorded fingerprint.' -ForegroundColor Green
        Write-Host '     The pinned image was built from this source.' -ForegroundColor Gray
    }
    'NOT_RECORDED' {
        Write-Host '[WARN] No fingerprint recorded for the pinned sandbox image.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  The image is digest-pinned, so it cannot be checked against its' -ForegroundColor Gray
        Write-Host '  source. If sandbox/ has changed since the image was built, the' -ForegroundColor Gray
        Write-Host '  agent is running OLD skills and tools with no error.' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  To close this: rebuild and repin the sandbox, then record it.' -ForegroundColor White
        Write-Host '    cd deploy/qm-pacgate' -ForegroundColor Gray
        Write-Host '    npm exec qm -- sandbox build' -ForegroundColor Gray
        Write-Host '    # repin the printed digest into qm.config.jsonc' -ForegroundColor Gray
        Write-Host '    pwsh -File ../../scripts/qm-sandbox-fingerprint.ps1 -Write' -ForegroundColor Gray
    }
    'DRIFT' {
        Write-Host '[DRIFT] Sandbox source has CHANGED since the image was pinned.' -ForegroundColor Red
        Write-Host ''
        Write-Host '  sandbox/ differs from what the pinned digest was built from,' -ForegroundColor Gray
        Write-Host '  so the agent is running the OLD skills and tools. Nothing has' -ForegroundColor Gray
        Write-Host '  errored - this is silent by construction.' -ForegroundColor Gray
        Write-Host ''
        Write-Host ('  recorded: {0}' -f $recorded.Substring(0, 16)) -ForegroundColor Gray
        Write-Host ('  current : {0}' -f $result.Fingerprint.Substring(0, 16)) -ForegroundColor Gray
        Write-Host ''
        Write-Host '  To close this: rebuild, repin, then record.' -ForegroundColor White
        Write-Host '    cd deploy/qm-pacgate' -ForegroundColor Gray
        Write-Host '    npm exec qm -- sandbox build' -ForegroundColor Gray
        Write-Host '    # repin the printed digest into qm.config.jsonc' -ForegroundColor Gray
        Write-Host '    pwsh -File ../../scripts/qm-sandbox-fingerprint.ps1 -Write' -ForegroundColor Gray
    }
}

exit ([int]($state -ne 'CURRENT'))
