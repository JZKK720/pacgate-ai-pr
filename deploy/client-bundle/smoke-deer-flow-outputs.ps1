# ============================================================================
# deer-flow outputs smoke test
#
# Verifies the unified outputs listing (GET /api/threads/{id}/outputs) and the
# artifact download route (GET /api/threads/{id}/artifacts/mnt/user-data/outputs/<file>)
# are reachable AND downloadable for a logged-in admin user, through the SAME
# frontend proxy path the browser uses.
#
# Usage (from deploy/client-bundle/, or anywhere):
#   .\smoke-deer-flow-outputs.ps1
#
# Env overrides (all optional, sensible defaults for the AIPC stack):
#   DEER_FLOW_BASE_URL  default http://localhost:8090   (frontend proxy / nginx)
#   DEER_FLOW_EMAIL     default from .env PACGATE_API_EMAIL
#   DEER_FLOW_PASSWORD  default from .env PACGATE_API_PASSWORD
#   DEER_FLOW_THREAD    optional specific thread id (otherwise auto-discovered)
#
# Exit codes: 0 = pass, 1 = fail.
# ============================================================================

[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:8090",
    [string]$Email,
    [string]$Password,
    [string]$ThreadId,
    [switch]$KeepTestFile
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Resolve credentials from the bundle .env if not passed explicitly.
# ---------------------------------------------------------------------------
# The .env file lives in the same directory as this script (deploy/client-bundle/).
$bundleDir = $PSScriptRoot
$envFile = Join-Path $bundleDir ".env"

if (-not $Email -or -not $Password) {
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match "^PACGATE_API_EMAIL=(.*)$") { $Email = $Matches[1] }
            if ($line -match "^PACGATE_API_PASSWORD=(.*)$") { $Password = $Matches[1] }
        }
    }
    if (-not $Email) { $Email = "admin@pacgate-law.com" }
    if (-not $Password) { throw "No deer-flow password provided. Set -Password or PACGATE_API_PASSWORD in .env." }
}

$base = $BaseUrl.TrimEnd("/")
$results = @()
$pass = $true

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:pass = $false }
function Add-Result($name, $ok, $detail) {
    $script:results += [pscustomobject]@{ Check = $name; Pass = $ok; Detail = $detail }
}

Write-Host "===== deer-flow outputs smoke test =====" -ForegroundColor White
Write-Host "Base URL: $base"
Write-Host "Email:    $Email"
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Login and capture session cookies
# ---------------------------------------------------------------------------
Write-Host "[1/5] Authenticate as admin" -ForegroundColor Magenta
$loginBody = "username=$([uri]::EscapeDataString($Email))&password=$([uri]::EscapeDataString($Password))"
try {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $loginResp = Invoke-WebRequest -Uri "$base/api/v1/auth/login/local" `
        -Method POST -Body $loginBody -ContentType "application/x-www-form-urlencoded" `
        -WebSession $session -UseBasicParsing
    if ($loginResp.StatusCode -eq 200) {
        Write-Ok "login returned 200 (expires_in + needs_setup)"
        Add-Result "login" $true "HTTP $($loginResp.StatusCode)"
    } else {
        Write-Fail "login returned $($loginResp.StatusCode)"
        Add-Result "login" $false "HTTP $($loginResp.StatusCode)"
    }
} catch {
    Write-Fail "login failed: $($_.Exception.Message)"
    Add-Result "login" $false $_.Exception.Message
    Write-Host "`nRESULT: FAIL (could not authenticate)" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Discover or create a thread with a real output file
# ---------------------------------------------------------------------------
Write-Host "[2/5] Prepare a thread with a generated output file" -ForegroundColor Magenta

# Resolve the admin user id from the DB (used to locate the sandbox outputs dir).
$adminUserId = $null
$threadsFound = @()

# Discover the admin user id and a thread id using the deer-flow container's
# sqlite DB. We write a small python helper, copy it into the container, and run
# it there. (The deer-flow container owns /app/backend/.deer-flow.)
$adminPy = @'
import sqlite3, json
db = "/app/backend/.deer-flow/data/deerflow.db"
conn = sqlite3.connect(db)
cur = conn.cursor()
cur.execute("SELECT id, email FROM users")
rows = cur.fetchall()
admin = None
for uid, email in rows:
    if email and "@" in email:
        admin = uid
        break
threads = []
if admin:
    cur.execute("SELECT thread_id FROM threads_meta WHERE user_id = ?", (admin,))
    for (tid,) in cur.fetchall():
        threads.append(tid)
conn.close()
print(json.dumps({"admin": admin, "threads": threads}))
'@
$adminPy | Set-Content -Path (Join-Path $env:TEMP "df-admin.py") -Encoding UTF8
try {
    docker cp (Join-Path $env:TEMP "df-admin.py") deer-flow:/tmp/df-admin.py 2>$null | Out-Null
    # -w /app/backend so runtime_home() resolves to the same .deer-flow the server uses
    $adminJson = docker exec -w /app/backend deer-flow /app/backend/.venv/bin/python /tmp/df-admin.py 2>$null | Select-Object -First 1
    $adminData = $adminJson | ConvertFrom-Json
    $adminUserId = $adminData.admin
    $threadsFound = @($adminData.threads)
    Write-Step "admin user id: $adminUserId"
    Write-Step "threads found: $($threadsFound.Count)"
} catch {
    Write-Step "admin discovery via container: $($_.Exception.Message)"
}

$usedThreadId = $ThreadId
if (-not $usedThreadId -and $threadsFound.Count -gt 0) {
    $usedThreadId = $threadsFound[0]
}

if (-not $usedThreadId) {
    Write-Fail "No thread id found. Pass -ThreadId or ensure a thread exists."
    Add-Result "thread" $false "no thread discovered"
    Write-Host "`nRESULT: FAIL" -ForegroundColor Red
    exit 1
}

Write-Ok "using thread: $usedThreadId"

# Create a real output file in the thread's outputs dir so the listing has
# something to return. Do this via the deer-flow container (it owns the data).
try {
    $mkFile = @'
import sys, os
sys.path.insert(0, "/app/backend")
from app.gateway.routers.artifacts import get_paths
tid = sys.argv[1]
uid = sys.argv[2]
outdir = get_paths().sandbox_outputs_dir(tid, user_id=uid)
os.makedirs(outdir, exist_ok=True)
f = os.path.join(outdir, "smoke-test-output.md")
with open(f, "w") as fh:
    fh.write("# Smoke test output\n\nGenerated by smoke-deer-flow-outputs.ps1\n")
print("created:", f)
'@
    $mkFile | Set-Content -Path (Join-Path $env:TEMP "df-mk.py") -Encoding UTF8
    $createdFile = "smoke-test-output.md"
    # Copy into container
    docker cp (Join-Path $env:TEMP "df-mk.py") deer-flow:/tmp/df-mk.py 2>$null | Out-Null
    # Use the venv python (system python3 lacks the app deps) and -w /app/backend so
    # runtime_home() matches the server's .deer-flow location.
    # NOTE: relax $ErrorActionPreference so the venv python's stderr deprecation
    # warning (LangChain) doesn't trigger the catch below.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker exec -w /app/backend deer-flow /app/backend/.venv/bin/python /tmp/df-mk.py $usedThreadId $adminUserId 2>$null | Out-Null
    $ErrorActionPreference = $savedEap
    Write-Step "created smoke output file: $createdFile"
} catch {
    Write-Step "could not create output file (may already exist): $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 3. Call the outputs listing endpoint through the proxy
# ---------------------------------------------------------------------------
Write-Host "[3/5] GET /api/threads/{id}/outputs (list)" -ForegroundColor Magenta
try {
    $listResp = Invoke-WebRequest -Uri "$base/api/threads/$usedThreadId/outputs" -WebSession $session -UseBasicParsing
    $list = $listResp.Content | ConvertFrom-Json
    $fileCount = $list.count
    Write-Ok "listing returned 200 with $fileCount file(s)"
    Add-Result "list-outputs" $true "HTTP $($listResp.StatusCode), count=$fileCount"

    # Show the files
    foreach ($f in $list.files) {
        Write-Step "  - $($f.filename)  (virtual_path=$($f.virtual_path))"
    }

    # Verify enrichment fields are present
    $enriched = @($list.files | Where-Object { $_.virtual_path -and $_.artifact_url })
    if ($enriched.Count -gt 0) {
        Write-Ok "enrichment (virtual_path + artifact_url) present"
        Add-Result "enrichment" $true "$($enriched.Count) files enriched"
    } else {
        Write-Fail "no enriched files found in listing"
        Add-Result "enrichment" $false "virtual_path/artifact_url missing"
    }
} catch {
    Write-Fail "listing failed: $($_.Exception.Message)"
    Add-Result "list-outputs" $false $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 4. Download an artifact through the proxy
# ---------------------------------------------------------------------------
Write-Host "[4/5] GET /api/threads/{id}/artifacts/mnt/user-data/outputs/<file> (download)" -ForegroundColor Magenta
if ($createdFile -or $list.files.Count -gt 0) {
    $dlName = $createdFile
    if (-not $dlName) { $dlName = $list.files[0].filename }
    $dlUrl = "$base/api/threads/$usedThreadId/artifacts/mnt/user-data/outputs/$dlName"
    try {
        $dlResp = Invoke-WebRequest -Uri $dlUrl -WebSession $session -UseBasicParsing
        if ($dlResp.StatusCode -eq 200 -and $dlResp.Content) {
            Write-Ok "download returned 200 ($($dlResp.Content.Length) bytes)"
            Add-Result "download" $true "HTTP $($dlResp.StatusCode), $($dlResp.Content.Length) bytes"
        } else {
            Write-Fail "download returned $($dlResp.StatusCode)"
            Add-Result "download" $false "HTTP $($dlResp.StatusCode)"
        }
    } catch {
        Write-Fail "download failed: $($_.Exception.Message)"
        Add-Result "download" $false $_.Exception.Message
    }
} else {
    Write-Fail "no file to download (listing empty)"
    Add-Result "download" $false "listing was empty"
}

# ---------------------------------------------------------------------------
# 5. Clean up the smoke test output file
# ---------------------------------------------------------------------------
Write-Host "[5/5] Clean up smoke test file" -ForegroundColor Magenta
if (-not $KeepTestFile -and $createdFile) {
    try {
        $rmFile = @'
import sys, os
sys.path.insert(0, "/app/backend")
from app.gateway.routers.artifacts import get_paths
tid = sys.argv[1]
uid = sys.argv[2]
outdir = get_paths().sandbox_outputs_dir(tid, user_id=uid)
f = os.path.join(outdir, "smoke-test-output.md")
if os.path.exists(f):
    os.remove(f)
    print("removed")
'@
        $rmFile | Set-Content -Path (Join-Path $env:TEMP "df-rm.py") -Encoding UTF8
        docker cp (Join-Path $env:TEMP "df-rm.py") deer-flow:/tmp/df-rm.py 2>$null | Out-Null
        $savedEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        docker exec -w /app/backend deer-flow /app/backend/.venv/bin/python /tmp/df-rm.py $usedThreadId $adminUserId 2>$null | Out-Null
        $ErrorActionPreference = $savedEap
        Write-Ok "removed smoke test output file"
    } catch {
        Write-Step "cleanup skipped: $($_.Exception.Message)"
    }
} else {
    Write-Step "keeping test file (or none created)"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===== SUMMARY =====" -ForegroundColor White
foreach ($r in $results) {
    $icon = if ($r.Pass) { "[OK]" } else { "[FAIL]" }
    $color = if ($r.Pass) { "Green" } else { "Red" }
    Write-Host "  $icon $($r.Check) - $($r.Detail)" -ForegroundColor $color
}
Write-Host ""
if ($pass) {
    Write-Host "RESULT: PASS" -ForegroundColor Green
    exit 0
} else {
    Write-Host "RESULT: FAIL" -ForegroundColor Red
    exit 1
}
