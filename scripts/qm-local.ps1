[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$QmArgs
)

$ErrorActionPreference = "Stop"

if (-not $QmArgs -or $QmArgs.Count -eq 0) {
    $QmArgs = @("status")
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$deploymentDir = Join-Path $repoRoot "deploy\qm-pacgate"
$cliPath = Join-Path $deploymentDir "node_modules\@yc-software\qm\dist\bin\qm.js"
$utilPath = Join-Path $deploymentDir "node_modules\@yc-software\qm\dist\src\util.js"

if (-not (Test-Path $deploymentDir)) {
    throw "QM deployment directory not found: $deploymentDir"
}

if (-not (Test-Path $cliPath)) {
    throw "QM CLI not found at $cliPath. Install deploy/qm-pacgate dependencies first."
}

$dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCommand) {
    throw "docker.exe not found on PATH. Install Docker Desktop first."
}

$dockerDir = Split-Path -Parent $dockerCommand.Source
if (($env:PATH -split ';') -notcontains $dockerDir) {
    $env:PATH = "$dockerDir;$env:PATH"
}

$utilText = Get-Content -Path $utilPath -Raw
$patchedMarker = 'execFileSync("where", [bin], { stdio: "ignore" });'

if ($IsWindows -and -not $utilText.Contains($patchedMarker)) {
    $oldSnippet = @'
export function which(bin) {
    try {
        execFileSync("/bin/sh", ["-c", `command -v ${bin}`], { stdio: "ignore" });
        return true;
    }
    catch {
        return false;
    }
}
'@

    $newSnippet = @'
export function which(bin) {
    if (process.platform === "win32") {
        try {
            execFileSync("where", [bin], { stdio: "ignore" });
            return true;
        }
        catch {
            return false;
        }
    }
    try {
        execFileSync("/bin/sh", ["-c", `command -v ${bin}`], { stdio: "ignore" });
        return true;
    }
    catch {
        return false;
    }
}
'@

    if (-not $utilText.Contains($oldSnippet)) {
        throw "QM util.js does not match the expected upstream which() implementation."
    }

    $patchedText = $utilText.Replace($oldSnippet, $newSnippet)
    Set-Content -Path $utilPath -Value $patchedText -Encoding UTF8
}

Push-Location $deploymentDir
try {
    & node $cliPath @QmArgs
}
finally {
    Pop-Location
}