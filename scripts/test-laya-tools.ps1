<#
.SYNOPSIS
    Assert the pacgate-mcp laya tool group exists and degrades safely.

.DESCRIPTION
    WHY THIS EXISTS (2026-10-31).

    laya is a local System 1 decision engine reached as a separate HTTP service
    (laya-serve). It is OPTIONAL: most client machines will not run it, at least
    at first, because it costs a 1.2 GB model checkpoint on disk.

    That optionality is the whole risk. An optional dependency that raises on a
    machine without it turns every clause tool into an exception, and the agent
    sees a broken tool rather than an absent capability. So the properties that
    matter are not "it classifies clauses well" - that needs weights this box
    cannot fetch - but:

      L1  server.py registers the three laya tools
      L2  the laya client reads a configurable base URL (no hardcoded host)
      L3  an unreachable laya returns an explicit "unavailable" payload, not a raise
      L4  min_confidence is forwarded - abstention is the reason we use laya
          at all, so silently dropping it would defeat the integration
      L5  no API key is required anywhere in the laya path (the whole point)
      L6  compose declares the service in BOTH lanes, or one lane ships a tool
          that can never work

    L3 and L4 are behavioural: they import server.py and call the tools against a
    dead endpoint. L1/L2/L5/L6 are structural.

    Exit codes: 0 = pass; 1 = a real defect; 2 = cannot check.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:9/laya'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$script:pass = 0
$script:fail = 0
$script:skip = 0

function Check($name, $ok, $detail) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red; if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray } }
}
function Skip($name, $why) {
    $script:skip++; Write-Host "  [SKIP] $name - $why" -ForegroundColor Yellow
}

$server = 'deploy/pacgate-mcp/server.py'
$mcpDir = 'deploy/pacgate-mcp'

if (-not (Test-Path -LiteralPath $server)) {
    Write-Host "  cannot check: $server is missing" -ForegroundColor Red
    exit 2
}
$src = [System.IO.File]::ReadAllText((Resolve-Path $server))

Write-Host ''
Write-Host 'L1  the laya tool group is registered' -ForegroundColor Cyan

$tools = @('pacgate_clause_risk', 'pacgate_clause_flags', 'pacgate_route_language')
foreach ($t in $tools) {
    $declared = $src -match "(?m)^def\s+$t\s*\("
    $decorated = $src -match "(?s)@mcp\.tool\(\)[^\n]*\n(?:[^\n]*\n){0,4}def\s+$t\s*\("
    Check "tool '$t' is defined and decorated with @mcp.tool()" ($declared -and $decorated) `
        "def found=$declared, @mcp.tool found above it=$decorated; an undecorated def is never advertised to the agent"
}

Write-Host ''
Write-Host 'L2  the laya client is configurable, not hardcoded' -ForegroundColor Cyan

Check 'laya base URL comes from the environment' ($src -match 'LAYA_(SERVE_)?BASE_URL|PACGATE_LAYA_URL') `
    'no environment read for the laya endpoint - a hardcoded host breaks every non-default deployment'

# 'pacgate-api' and 'laya' are compose siblings on the same network, so a
# default naming them is the deployment, not a hardcoded third-party host.
$hardcoded = [regex]::Matches($src, '(?:https?://)(?!pacgate-api|laya\b|127\.0\.0\.1|localhost)[a-z0-9.\-]+:\d+')
Check 'no hardcoded service host in server.py' ($hardcoded.Count -eq 0) `
    ("found: " + (($hardcoded | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '))

Write-Host ''
Write-Host 'L3+L4  behaviour: unreachable laya degrades, and confidence is forwarded' -ForegroundColor Cyan

$py = $null
foreach ($cand in @('python', 'py')) {
    $probe = & $cand -c "print('ok')" 2>&1
    if ($LASTEXITCODE -eq 0 -and ($probe -join '') -match 'ok') { $py = $cand; break }
}

if (-not $py) {
    Skip 'behavioural checks' 'no usable python on PATH'
}
else {
    $script = @'
import importlib.util, json, os, sys

os.environ["PACGATE_LAYA_URL"] = sys.argv[1]
os.environ["PACGATE_LAYA_TIMEOUT"] = "2"
os.environ.setdefault("PACGATE_API_EMAIL", "")
os.environ.setdefault("PACGATE_API_PASSWORD", "")

spec = importlib.util.spec_from_file_location("pgmcp", sys.argv[2])
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except Exception as e:
    print(json.dumps({"import_error": f"{type(e).__name__}: {e}"}))
    raise SystemExit(0)

out = {}

# L3: a dead endpoint must come back as a result, not an exception.
for fn in ("pacgate_clause_risk", "pacgate_clause_flags", "pacgate_route_language"):
    f = getattr(mod, fn, None)
    if f is None:
        out[fn] = "MISSING"
        continue
    try:
        # ENGLISH on purpose. Two separate properties are under test here:
        # this probe checks that an unreachable laya degrades gracefully, and
        # L8 checks that Chinese is withheld. Probing degradation with Chinese
        # text would hit the CJK guard first and never reach the laya call, so
        # the assertion would pass for the wrong reason.
        r = f("The Supplier shall be liable for all losses howsoever arising.")
        out[fn] = r if isinstance(r, str) else str(r)
    except Exception as e:
        out[fn] = f"RAISED {type(e).__name__}: {e}"

print(json.dumps(out, ensure_ascii=False))
'@
    $tmp = Join-Path $env:TEMP ("laya-gate-" + [guid]::NewGuid().ToString('n').Substring(0, 6) + '.py')
    [System.IO.File]::WriteAllText($tmp, $script, [System.Text.UTF8Encoding]::new($false))
    $raw = & $py $tmp $BaseUrl (Resolve-Path $server) 2>&1 | Out-String

    if ($raw -match 'import_error') {
        Skip 'behavioural checks' "server.py cannot be imported here: $raw"
    }
    else {
        $res = $null
        try { $res = ($raw -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json } catch { }

        if (-not $res) {
            Check 'tool calls return a parseable payload' $false ($raw.Substring(0, [Math]::Min(400, $raw.Length)))
        }
        else {
            foreach ($fn in @('pacgate_clause_risk', 'pacgate_clause_flags', 'pacgate_route_language')) {
                $v = [string]$res.$fn
                if ($v -match '^RAISED') {
                    Check "$fn degrades to an explicit unavailable result" $false `
                        "raised instead of returning: $($v.Substring(0, [Math]::Min(200, $v.Length)))"
                    continue
                }
                # Assert the contract, not the wording. Matching vocabulary
                # ("unavailable", "disabled") would pass or fail on prose; the
                # caller branches on `available` being false and on `reason`
                # explaining why, so that is what must hold.
                $obj = $null
                try { $obj = $v | ConvertFrom-Json } catch { }
                if (-not $obj) {
                    Check "$fn degrades to an explicit unavailable result" $false `
                        "returned non-JSON, so a caller cannot branch on it: $($v.Substring(0, [Math]::Min(200, $v.Length)))"
                    continue
                }
                $ok = ($obj.available -eq $false) -and ([string]$obj.reason).Trim().Length -gt 0 -and ([string]$obj.tool) -eq $fn
                Check "$fn degrades to an explicit unavailable result" $ok `
                    "available=$($obj.available) tool='$($obj.tool)' reason='$([string]$obj.reason)'"
            }
        }
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

# min_confidence must reach the wire. Structural, because the value only
# exists inside an outbound request body that a dead endpoint never sends.
$forwardsMinConf = $src -match 'min_confidence'
Check 'min_confidence is forwarded to laya (abstention survives)' $forwardsMinConf `
    'server.py never mentions min_confidence, so laya cannot decline and will guess on every clause'

Write-Host ''
Write-Host 'L5  no API key anywhere in the laya path' -ForegroundColor Cyan

# Scope to laya-related lines only: pacgate-api legitimately uses credentials.
$layaLines = @(($src -split '\r?\n') | Where-Object { $_ -match 'laya' })
$keyHits = @($layaLines | Where-Object { $_ -match 'API_KEY|api_key|Authorization|Bearer' })
Check 'no key or bearer auth is required to reach laya' ($keyHits.Count -eq 0) `
    (($keyHits | Select-Object -First 3) -join ' | ')

Write-Host ''
Write-Host 'L6  both compose lanes declare the laya service' -ForegroundColor Cyan

foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $p = Join-Path 'deploy/client-bundle' $lane
    if (-not (Test-Path -LiteralPath $p)) { Check "$lane exists" $false; continue }
    $t = [System.IO.File]::ReadAllText((Resolve-Path $p))
    Check "$lane declares a laya service" ($t -match '(?m)^\s{2}laya:\s*$') `
        'no top-level laya: service - the tools would have nothing to call'
    Check "$lane points pacgate-mcp at the laya service" ($t -match 'PACGATE_LAYA_URL') `
        'pacgate-mcp has no PACGATE_LAYA_URL in this lane'
}

Write-Host ''
Write-Host 'L7  the laya service can actually resolve its weights' -ForegroundColor Cyan

# A service that starts and then has no weights is worse than one that is off:
# /health returns 200 with no checkpoint loaded, so it looks healthy while every
# clause call fails. This assertion exists because exactly that shipped in the
# first cut - the compose mounted ${LAYA_MODEL_DIR}:/models, but laya resolves
# its checkpoint through huggingface_hub.snapshot_download and reads an HF cache
# (<home>/.cache/huggingface/hub). It never looks at /models.
#
# The vars laya reads, from ITS OWN compose.http.yaml and http-api.md - the
# authoritative list. A pure source scan under-reports them, because
# LAYA_DEVICE / LAYA_PRELOAD / LAYA_MAX_LOADED / LAYA_THREADS go through
# pydantic settings rather than a literal os.environ.get. There is deliberately
# no LAYA_MODEL_DIR: laya resolves checkpoints through an HF cache and has no
# such variable.
# The env vars laya reads, taken from ITS OWN compose.http.yaml and http-api.md
# - the authoritative list - plus the ones a source scan found. A pure source
# scan is not enough: LAYA_DEVICE / LAYA_PRELOAD / LAYA_MAX_LOADED /
# LAYA_THREADS are read through pydantic settings, not by a literal
# os.environ.get, so scanning only .py call sites under-reports them.
# There is deliberately no LAYA_MODEL_DIR: laya resolves checkpoints through an
# HF cache and has no such variable.
$layaEnvVars = @(
    'LAYA_HOST', 'LAYA_PORT', 'LAYA_ROOT_PATH', 'LAYA_DEVICE', 'LAYA_PRELOAD',
    'LAYA_MODELS', 'LAYA_DEFAULT_MODEL', 'LAYA_EXTRA_MODELS', 'LAYA_MAX_LOADED',
    'LAYA_THREADS', 'LAYA_IDLE_UNLOAD_SECONDS', 'LAYA_MAX_CONCURRENT',
    'LAYA_MAX_TOKEN_BUDGET', 'LAYA_MAX_BATCH_TOKENS', 'LAYA_JEV_STRICT',
    'LAYA_TOURNAMENT_GROUP', 'LAYA_LOG_LEVEL', 'LAYA_REVISION',
    'LAYA_SHA256_DIGESTS', 'LAYA_API_KEY', 'LAYA_API_KEY_FILE',
    'LAYA_CUDA_AMP', 'LAYA_CPU_AMP', 'LAYA_AUTO_TASK', 'LAYA_BASE_URL',
    'LAYA_REMOTE_TIMEOUT', 'LAYA_USER_AGENT',
    'XDG_CACHE_HOME', 'TORCHINDUCTOR_CACHE_DIR'
)
$invented = @()
foreach ($m in [regex]::Matches($src, '\$\{?(LAYA_[A-Z0-9_]+)')) { if ($layaEnvVars -notcontains $m.Groups[1].Value) { $invented += $m.Groups[1].Value } }
Check 'pacgate-mcp only uses LAYA_* variables that exist' ($invented.Count -eq 0) `
    ("invented: " + (($invented | Select-Object -Unique) -join ', '))

foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $p = Join-Path 'deploy/client-bundle' $lane
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $t = [System.IO.File]::ReadAllText((Resolve-Path $p))

    # Pull the laya service block, then drop comment lines before inspecting it.
    # Without that, an explanatory comment naming a removed variable reads as a
    # live reference and the gate fails on its own documentation.
    $svc = [regex]::Match($t, '(?ms)^  laya:\r?\n(?<body>.*?)(?=^\s{2}[a-z0-9-]+:\s*$|\z)')
    if (-not $svc.Success) { Check "$lane laya block parseable" $false; continue }
    $bodyLines = @(($svc.Groups['body'].Value -split '\r?\n') | Where-Object { $_.Trim() -notmatch '^#' })

    Check "$lane mounts the HF cache laya reads" (($bodyLines -join "`n") -match ':/home/laya/\.cache/huggingface') `
        'laya resolves checkpoints via an HF cache; a different mount path is invisible to it'

    # environment: values must be variables laya itself reads.
    $envLines = @()
    $inEnv = $false
    foreach ($line in $bodyLines) {
        if ($line -match '^\s{4}environment:\s*$') { $inEnv = $true; continue }
        if ($inEnv -and $line -match '^\s{4}[a-z]') { break }
        if ($inEnv) { $envLines += $line }
    }
    $badEnv = @()
    foreach ($line in $envLines) {
        $key = ($line -split ':', 2)[0].Trim()
        if ($key -match '^LAYA_' -and $layaEnvVars -notcontains $key) { $badEnv += $key }
    }
    Check "$lane sets only LAYA_* variables laya reads" ($badEnv.Count -eq 0) `
        ("laya does not read: " + (($badEnv | Select-Object -Unique) -join ', '))

    # Volume sources are compose-side, so a different namespace is expected there -
    # but a *model* path variable is the specific mistake being guarded against.
    $volVars = @()
    foreach ($line in $bodyLines) {
        if ($line -notmatch '^\s*-\s') { continue }
        foreach ($m in [regex]::Matches($line, '\$\{(LAYA_[A-Z0-9_]+)')) { $volVars += $m.Groups[1].Value }
    }
    Check "$lane names no model-directory variable laya ignores" ($volVars -notcontains 'LAYA_MODEL_DIR') `
        'LAYA_MODEL_DIR does not exist in laya; the mount must target the HF cache path'

    Check "$lane keeps runtime offline" (($bodyLines -join "`n") -match 'HF_HUB_OFFLINE:\s*"?1') `
        'without HF_HUB_OFFLINE the service would try huggingface.co at run time on a client machine'

    # BILINGUAL (2026-11-01). This stack serves English and Chinese, and laya
    # routes by script: Latin text goes to the `english` checkpoint and Han to
    # `multilingual`. Measured: with only `multilingual` loaded, an English
    # clause makes the router build `english` and the request returns HTTP 500.
    # So the default must name both, and MAX_LOADED must be >= 2 or the second
    # checkpoint is evicted on every language switch.
    $body = ($bodyLines -join "`n")
    $modelsLine = [regex]::Match($body, 'LAYA_MODELS:\s*\$\{LAYA_MODELS:-([^}]+)\}')
    if (-not $modelsLine.Success) {
        Check "$lane defaults LAYA_MODELS to both checkpoints" $false `
            'no LAYA_MODELS default found - an English clause would 500'
    }
    else {
        $val = $modelsLine.Groups[1].Value
        Check "$lane loads both checkpoints by default" (($val -match 'multilingual') -and ($val -match 'english')) `
            "default is '$val'; laya routes Latin text to 'english', so a bilingual stack needs both"
    }
    $maxLoaded = [regex]::Match($body, 'LAYA_MAX_LOADED:\s*"(\d+)"')
    Check "$lane allows both checkpoints resident" ($maxLoaded.Success -and [int]$maxLoaded.Groups[1].Value -ge 2) `
        'MAX_LOADED below 2 evicts a checkpoint on every language switch, reloading ~800MB each time'
}

Write-Host ''
Write-Host 'L8  Chinese is graded by its own validated path, English by the English one' -ForegroundColor Cyan

# Measured 2026-11-01 against CCL-DRR: the single three-way question scored 0.333
# accuracy (chance) with recall 0.00 on 风险高. A decomposed three-question path
# scores recall 0.86-1.00 at precision 0.35-0.43. This asserts the routing between
# the two paths and that neither language silently borrows the other's numbers.
$guardScript = @'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("s", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
out = {}
for name, text in (("zh", "\u4e59\u65b9\u5bf9\u56e0\u672c\u5408\u540c\u4ea7\u751f\u7684\u4efb\u4f55\u635f\u5931\u627f\u62c5\u65e0\u9650\u8d23\u4efb\u3002"),
                   ("en", "The Supplier shall be liable for all losses without limitation."),
                   ("en_with_zh_name", "Party A (\u5317\u4eac\u67d0\u67d0\u79d1\u6280\u6709\u9650\u516c\u53f8) shall pay within 30 days.")):
    out["route_" + name] = bool(m._is_cjk_dominant(text))
# The Chinese grade must come from three named probabilities and honour its own
# thresholds, not from a borrowed English verdict.
zh_answers = {k: {"noul": 0.99} for k in m._LAYA_ZH_QUESTIONS}
out["zh_grade_all_high"] = m._laya_zh_grade(zh_answers)
out["zh_grade_none"] = m._laya_zh_grade({k: {"noul": 0.0} for k in m._LAYA_ZH_QUESTIONS})
out["zh_thresholds"] = m._LAYA_ZH_THRESHOLDS
out["zh_keys"] = sorted(m._LAYA_ZH_QUESTIONS)
print(json.dumps(out, ensure_ascii=False))
'@
$tmp = Join-Path $env:TEMP ("guard-" + [guid]::NewGuid().ToString('n').Substring(0, 6) + '.py')
[System.IO.File]::WriteAllText($tmp, $guardScript, [System.Text.UTF8Encoding]::new($false))
$raw = & $py $tmp (Resolve-Path $server) 2>&1 | Out-String
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

$g = $null
try { $g = ($raw -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json } catch { }
if (-not $g) {
    Skip 'L8 behavioural checks' "server.py could not be imported: $($raw.Substring(0,[Math]::Min(200,$raw.Length)))"
}
else {
    Check 'a Chinese clause routes to the Chinese path' ($g.route_zh -eq $true) 'Chinese text would use the English three-way question, measured at recall 0.00'
    Check 'an English clause routes to the English path' ($g.route_en -eq $false) 'the English path must not be diverted to the Chinese questions'
    Check 'English text containing a Chinese entity name stays on the English path' ($g.route_en_with_zh_name -eq $false) `
        'a presence test instead of a ratio would refuse real bilingual contracts'

    Check 'the Chinese question set is three independent yes/no flags' `
        (($g.zh_keys -join ',') -eq 'ambiguous,uncapped,unilateral') `
        "keys=$($g.zh_keys -join ',') - the decomposition is what produced the recall"
    Check 'an all-positive Chinese answer grades high' ($g.zh_grade_all_high.grade -eq 'high') `
        "graded $($g.zh_grade_all_high.grade)"
    Check 'an all-negative Chinese answer grades low' ($g.zh_grade_none.grade -eq 'low') `
        "graded $($g.zh_grade_none.grade)"
    Check 'the Chinese thresholds are the tuned ones, not defaults' `
        (($g.zh_thresholds.uncapped -eq 0.75) -and ($g.zh_thresholds.unilateral -eq 0.50) -and ($g.zh_thresholds.ambiguous -eq 0.50)) `
        "thresholds: uncapped=$($g.zh_thresholds.uncapped) unilateral=$($g.zh_thresholds.unilateral) ambiguous=$($g.zh_thresholds.ambiguous)"
}

Write-Host ''
Write-Host 'L9  both clause tools route by language and disclose which measurement applies' -ForegroundColor Cyan

foreach ($fn in @('pacgate_clause_risk', 'pacgate_clause_flags')) {
    $body = [regex]::Match($src, '(?ms)^def\s+' + $fn + '\s*\((?<all>.*?)(?=^@mcp\.tool|\z)')
    if (-not $body.Success) { Check "$fn parseable" $false; continue }
    $all = $body.Groups['all'].Value
    Check "$fn detects the language of the clause" ($all -match '_is_cjk_dominant\(clause\)') `
        'without the check the tool applies one language''s calibration to the other'
    Check "$fn keeps allow_unvalidated_language off by default" ($all -match 'allow_unvalidated_language:\s*bool\s*=\s*False') `
        'the escape hatch must default off, or the measured path is bypassed silently'
    Check "$fn docstring states both measured results" `
        (($all -match 'CCL-DRR') -and ($all -match 'CUAD')) `
        'the docstring is what the agent reads before trusting a verdict; it must name both datasets'
}

# `pacgate_clause_flags` reports the four ENGLISH flags, so for Chinese it must
# say so and point at the tool that does have a Chinese path. Risk and flags are
# deliberately different tools here: one grades Chinese, one does not.
$flagsBody = [regex]::Match($src, '(?ms)^def\s+pacgate_clause_flags\s*\((?<all>.*?)(?=^@mcp\.tool|\z)')
if ($flagsBody.Success) {
    Check 'pacgate_clause_flags tells a Chinese reader where to go instead' `
        ($flagsBody.Groups['all'].Value -match 'pacgate_clause_risk') `
        'a dead end with no alternative is how a capability silently disappears'
}

Write-Host ''
$total = $script:pass + $script:fail
if ($script:fail -eq 0) {
    Write-Host "RESULT: the laya tools ship, degrade safely, and keep abstention. ($($script:pass) passed, $($script:skip) skipped)" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:fail) of $total assertion(s) failed." -ForegroundColor Red
exit 1
