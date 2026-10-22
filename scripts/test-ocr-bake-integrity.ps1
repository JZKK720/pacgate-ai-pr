# test-ocr-bake-integrity.ps1 - the baked PaddleOCR weights must stay reachable.
#
# WHY THIS EXISTS. 0.1.28 bakes the PP-OCRv4 det/rec/cls weights into the
# ocr-service image so extraction needs no external host. But the compose files
# went on mounting a `paddleocr-models` named volume over /root/.paddleocr, and a
# mount point SHADOWS the image's directory: anything the volume lacks, PaddleOCR
# fetches from paddleocr.bj.bcebos.com again. That reintroduces the exact CDN
# dependency the bake exists to remove, and a cold path measured 269.9s against
# the 300s client timeout in crates/pacgate-api/src/extract.rs - so it fails
# intermittently, and it fails worst on a fresh AIPC, which is the worst place.
#
# The volume was defended as "harmless: a fresh volume is seeded from the image".
# That is only true for a volume Docker has just created. This gate exists
# because the reasoning, not the code, was the defect - so it asserts the
# PROPERTY (nothing shadows the baked path) rather than the current file content.
#
# It is STATIC: it reads the Dockerfile and every compose in the tree, so it
# needs no containers and is safe in the gate list. The LIVE counterpart is
# `smoke-full-stack.ps1` lane 6, which asserts on the running container that
# nothing is mounted over /root/.paddleocr and that det+rec+cls are present.
#
# Usage: powershell -File scripts/test-ocr-bake-integrity.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$failed = $false
function Assert-True($cond, $name) {
    if ($cond) { Write-Output "PASS: $name" }
    else { Write-Output "FAIL: $name"; $script:failed = $true }
}

$bakePath = '/root/.paddleocr'

# ── 1. The Dockerfile actually bakes, and proves its own work ────────────────
$dfPath = 'deploy/ocr-service/Dockerfile'
Assert-True (Test-Path $dfPath) "Dockerfile exists ($dfPath)"
if (Test-Path $dfPath) {
    $df = Get-Content $dfPath -Raw

    Assert-True ($df -match 'COPY\s+warm_up\.py') 'Dockerfile COPYs warm_up.py'
    Assert-True ($df -match 'RUN[^\r\n]*python\s+warm_up\.py') 'Dockerfile RUNs warm_up.py at build time'

    # The build must refuse to produce an image whose bake silently did nothing.
    foreach ($part in @('det', 'rec', 'cls')) {
        Assert-True ($df -match "test -d\s+$([regex]::Escape($bakePath))/whl/$part") `
            "Dockerfile asserts baked $part weights exist at build time"
    }

    # `lang`/`angle_cls` are what decide WHICH weights get fetched, and warm_up.py
    # is only faithful while it resolves to the same values app.py constructs with.
    # If app.py ever changes construction and warm_up.py does not, the image
    # silently bakes a different set - so compare RESOLVED values, not raw text.
    # (The naive version of this check compared the first `lang=` match in each
    # file and read warm_up's own log format string, "lang=%s". A check that
    # cannot resolve an indirection is a check that reports a false failure AND
    # would report a false pass the moment the log line changed.)
    $appPath = 'deploy/ocr-service/app.py'
    $warmPath = 'deploy/ocr-service/warm_up.py'
    Assert-True ((Test-Path $appPath) -and (Test-Path $warmPath)) 'app.py and warm_up.py both exist'
    if ((Test-Path $appPath) -and (Test-Path $warmPath)) {
        $app = Get-Content $appPath -Raw
        $warm = Get-Content $warmPath -Raw

        # The arguments of the CONSTRUCTION call in each file.
        #
        # Not the first `PaddleOCR(` in the text: app.py logs
        # `logger.info("initialising PaddleOCR (use_gpu=%s)", use_gpu)`, and a
        # naive first-match scan reads that LOG STRING as the call and then
        # "resolves" its format placeholder. That is how this check first
        # reported a false failure on correct code. Discriminate on the content:
        # a real call has no %-format placeholder and does set use_angle_cls,
        # which is also the flag that decides whether cls weights are fetched.
        function Get-PaddleOcrArgs([string]$fileText) {
            foreach ($m in [regex]::Matches($fileText, 'PaddleOCR\s*\((?<a>[^)]*)')) {
                $a = $m.Groups['a'].Value
                if ($a -match '%') { continue }
                if ($a -notmatch 'use_angle_cls\s*=') { continue }
                return $a
            }
            return ''
        }
        $appArgs = Get-PaddleOcrArgs $app
        $warmArgs = Get-PaddleOcrArgs $warm
        Assert-True ($appArgs -and $warmArgs) 'located the PaddleOCR construction call in both files'

        function Resolve-OcrValue([string]$fileText, [string]$expr) {
            $e = $expr.Trim()
            if ($e -match '^"([^"]*)"$') { return $Matches[1] }               # literal
            if ($e -match '^[Tt]rue$') { return 'True' }
            if ($e -match '^[Ff]alse$') { return 'False' }
            # os.environ.get("VAR", "default") -> the default the image bakes with
            $env_ = [regex]::Match($e, 'environ\.get\(\s*[^,]+,\s*"(?<d>[^"]*)"')
            if ($env_.Success) { return $env_.Groups['d'].Value }
            # a module-level constant -> follow its right-hand side
            $c = [regex]::Match($fileText, "(?m)^\s*$([regex]::Escape($e))\s*=\s*(?<rhs>.+?)\s*$")
            if ($c.Success) { return Resolve-OcrValue $fileText $c.Groups['rhs'].Value }
            return $e
        }

        foreach ($key in @('use_angle_cls', 'lang')) {
            $appRaw = [regex]::Match($appArgs, "$key\s*=\s*(?<v>[^,]+)").Groups['v'].Value
            $warmRaw = [regex]::Match($warmArgs, "$key\s*=\s*(?<v>[^,]+)").Groups['v'].Value
            $appVal = Resolve-OcrValue $app $appRaw
            $warmVal = Resolve-OcrValue $warm $warmRaw
            Assert-True ($appVal -and ($appVal -eq $warmVal)) `
                "warm_up.py and app.py resolve $key identically ('$appVal' vs '$warmVal')"
        }
    }
}

# ── 2. Nothing in the tree mounts anything over the baked path ───────────────
# Scanned by LINE rather than per-service: a mount over the baked path is wrong
# wherever it appears, including in a service that is not named ocr-service and
# in an override file added later. This is the check that would have caught the
# 0.1.21 volume when 0.1.28 baked.
#
# SCOPE: compose files only. A recursive scan of all of `deploy/` walks
# `client-bundle/data/`, which is the GITIGNORED deer-flow runtime tree - it
# contains per-thread symlinks and a `.venv` whose lib64 entry cannot be read on
# Windows. Measured 2026-10-22: the unfiltered -Recurse threw
# "The file cannot be accessed by the system" and aborted this gate before it
# asserted anything. Runtime data can never contain a compose file anyway, so
# excluding it removes no coverage.
$skipDirs = @('\\data\\', '\\node_modules\\', '\\__pycache__\\', '\\.venv\\')
$composes = @(Get-ChildItem -Recurse -Path deploy -Include *.yaml, *.yml -File -ErrorAction SilentlyContinue |
    Where-Object { $f = $_.FullName; -not ($skipDirs | Where-Object { $f -match $_ }) })
Assert-True ($composes.Count -ge 2) "found compose files to scan ($($composes.Count))"

$shadowHits = @()
foreach ($c in $composes) {
    $lines = Get-Content $c.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*#') { continue }
        # A volume/short-syntax mount naming the baked path, or a long-syntax
        # `target:` pointing at it.
        if ($line -match [regex]::Escape($bakePath) -and $line -match ':\s*' ) {
            $shadowHits += ("{0}:{1}: {2}" -f $c.Name, ($i + 1), $line.Trim())
        }
    }
}
Assert-True ($shadowHits.Count -eq 0) "no compose mounts anything over $bakePath"
foreach ($h in $shadowHits) { Write-Output "    SHADOW: $h" }

# ── 3. No compose still DECLARES the now-unused volume ───────────────────────
# Declaring it is not itself a shadow, but a leftover declaration invites someone
# to re-add the mount, and the mount is what defeats the bake. Removing both is
# how the defect is closed rather than merely suspended.
$declHits = @()
foreach ($c in $composes) {
    $lines = Get-Content $c.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*#') { continue }
        if ($lines[$i] -match '^\s*paddleocr-models:\s*$') {
            $declHits += ("{0}:{1}" -f $c.Name, ($i + 1))
        }
    }
}
Assert-True ($declHits.Count -eq 0) 'no compose still declares the paddleocr-models volume'
foreach ($h in $declHits) { Write-Output "    DECLARED: $h" }

# ── 4. The live smoke lane asserts the right thing ───────────────────────────
# Lane 6 used to report Bad when the volume was ABSENT ("recreate would
# re-download"), i.e. it demanded the shadowing configuration. If that string
# comes back, the guard has been re-inverted behind the bake.
$smokePath = 'scripts/smoke-full-stack.ps1'
Assert-True (Test-Path $smokePath) 'smoke-full-stack.ps1 exists'
if (Test-Path $smokePath) {
    $smoke = Get-Content $smokePath -Raw
    Assert-True ($smoke -notmatch 'weights volume IS mounted') `
        'smoke lane no longer REQUIRES the volumes mount (pre-0.1.28 expectation gone)'
    Assert-True ($smoke -match 'no volume shadows') `
        'smoke lane asserts nothing shadows the baked weights'
    Assert-True ($smoke -match 'baked weights present') `
        'smoke lane asserts the baked det/rec/cls weights are present'
}

if ($failed) { Write-Output '== RESULT: FAIL =='; exit 1 }
Write-Output '== RESULT: PASS =='
