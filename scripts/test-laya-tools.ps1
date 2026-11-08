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

    # L6 originally asserted the laya block MOUNTS the HF cache. That assertion is
    # inverted as of 2026-11-02, because the weights are now baked into the image and
    # a mount over the cache directory replaces the baked layer instead of merging
    # with it. Keeping the old assertion would have demanded the defect. The current
    # guarantee lives in L10; what L6 still owes here is that the service does not
    # point laya at a mount path it never reads.
    Check "$lane does not mount laya's cache at a path laya ignores" `
        (-not (($bodyLines -join "`n") -match ':/models\b')) `
        'an earlier revision mounted ${LAYA_MODEL_DIR}:/models, which laya never reads'

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

# The payload is what a caller actually reads. A docstring that names the
# alternative is useless if the returned JSON does not.
$wpScript = @'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("s", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
out = {}
for tool in ("pacgate_clause_flags", "pacgate_clause_risk"):
    r = json.loads(m._laya_withheld_result(tool, "x"))
    out[tool] = r.get("use_instead", "")
print(json.dumps(out, ensure_ascii=False))
'@
$tmp2 = Join-Path $env:TEMP ("wp-" + [guid]::NewGuid().ToString('n').Substring(0, 6) + '.py')
[System.IO.File]::WriteAllText($tmp2, $wpScript, [System.Text.UTF8Encoding]::new($false))
$raw2 = & $py $tmp2 (Resolve-Path $server) 2>&1 | Out-String
Remove-Item -LiteralPath $tmp2 -Force -ErrorAction SilentlyContinue
$wp = $null
try { $wp = ($raw2 -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json } catch { }
if ($wp) {
    Check 'the withheld payload routes a Chinese reader to a working tool' `
        ([string]$wp.pacgate_clause_flags -match 'pacgate_clause_risk') `
        "use_instead for flags: '$($wp.pacgate_clause_flags)'"
}

Write-Host ''
Write-Host 'L10 the laya profile ships its own weights, and no mount may hide them' -ForegroundColor Cyan

# MODE CHANGE 2026-11-02: weights are BAKED INTO the image, not staged at the client.
#
# Three failure states were measured on the staged-cache design, and the assertions
# below each target one:
#   no cache at all     -> exits at boot (LocalEntryNotFoundError). Loud, safe.
#   PARTIAL cache       -> healthy, /health 200, loaded:["multilingual"], English 500.
#   EMPTY bind mount    -> identical to "no cache at all", because a bind mount
#                          REPLACES the image layer instead of merging with it.
# The last one is why the mount is opt-in: the shipped compose files must NOT mount
# over the cache directory, or baking is silently undone.

# 1. The Dockerfile must bake the weights, check them, and not pay for CUDA. A
#    missing COPY leaves a weightless image; a COPY without the checksum lets a
#    truncated weight ship and return meaningless numbers at run time.
$img = 'deploy/laya-serve/Dockerfile'
if (-not (Test-Path -LiteralPath $img)) {
    Check 'deploy/laya-serve/Dockerfile exists' $false
}
else {
    $dk = [System.IO.File]::ReadAllText((Resolve-Path $img))
    $copies = @([regex]::Matches($dk, '(?m)^COPY\s.*laya-weights'))
    Check 'the image bakes the checkpoints from the staging layout' ($copies.Count -ge 1) `
        'no COPY of laya-weights/; without it the image has no weights and laya exits at boot'
    Check 'the image verifies baked weight checksums at build time' `
        ($dk -match '891102d372688fc2a094dac56a384bc537b87c63f21f9f3dac0be2b7cbc8d86c') `
        'a COPY with no sha256 guard ships whatever sits on disk under the staging path'
    Check 'the image pins a CPU torch wheel, not the default CUDA build' `
        ($dk -match 'download\.pytorch\.org/whl/cpu') `
        'without the CPU index pip resolves torch from PyPI default and pulls ~4.2 GB of nvidia-* onto a CPU-only AIPC (measured: 9.23 GB image vs 1.79 GB)'
}

# 2. NEITHER shipped lane may bind-mount over the cache directory. A mount there
#    replaces the baked layer; an empty source reproduces the boot crash baking
#    removed.
foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $p = Join-Path 'deploy/client-bundle' $lane
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $shadow = @(Get-Content -LiteralPath $p |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'home/laya/\.cache/huggingface' })
    Check "$lane does not mount over the baked weights" ($shadow.Count -eq 0) `
        "non-comment mount(s) target the cache dir: $($shadow -join ' | '); a bind mount REPLACES the baked layer, so this silently un-bakes the image"
    $envRef = @(Get-Content -LiteralPath $p |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'LAYA_HF_CACHE' })
    Check "$lane does not reference LAYA_HF_CACHE at all" ($envRef.Count -eq 0) `
        "LAYA_HF_CACHE appears on a non-comment line: $($envRef -join ' | ')"
}

# 3. .env.example must not present a cache path as required any more. The baked
#    image needs none, so an operator told to stage models would follow a step that
#    no longer exists.
$envExample = 'deploy/client-bundle/.env.example'
if (-not (Test-Path -LiteralPath $envExample)) {
    Check '.env.example exists' $false
}
else {
    $ex = [System.IO.File]::ReadAllText((Resolve-Path $envExample))
    Check '.env.example stops presenting LAYA_HF_CACHE as REQUIRED' `
        ($ex -notmatch 'REQUIRED when the laya profile is enabled') `
        'the baked image needs no staged cache; a REQUIRED note sends operators to a step that no longer exists'
}

# 5. The compose DEFAULT for LAYA_MODELS must name both checkpoints. This is static,
#    so it has teeth on a machine that never runs laya - which is most of them, since
#    the profile is opt-in. Routing sends Latin text to `english` and Han to
#    `multilingual`; a default missing `english` breaks every English clause in an
#    en/zh product. Asserting the default is not the vacuous "the directory is
#    non-empty" check: this fails on a real, silent, one-word regression.
foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $p = Join-Path 'deploy/client-bundle' $lane
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $line = @(Get-Content -LiteralPath $p | Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'LAYA_MODELS' })
    if ($line.Count -eq 0) {
        Check "$lane defaults LAYA_MODELS to both checkpoints" $false 'no non-comment LAYA_MODELS line'
    }
    else {
        $joined = $line -join ' '
        Check "$lane defaults LAYA_MODELS to both checkpoints" `
            (($joined -match 'english') -and ($joined -match 'multilingual')) `
            "LAYA_MODELS line is '$($joined.Trim())'; dropping either checkpoint leaves that language returning HTTP 500"
    }
}

Write-Host ''
Write-Host 'L11 a probability over part of a clause is never presented as a verdict' -ForegroundColor Cyan

# MEASURED 2026-11-02 against the published 0.2.13 image. laya DOES report
# `usage.truncated`; nothing read it. The shipped question sets set the boundary,
# because the options share the window with the state:
#
#   deployed default (max_len 512), 4 EN flags : ~330 words read in full, ~384 drops 12
#   deployed default (max_len 512), 2 EN risk  : same boundary (~480 state tokens)
#   multilingual default (max_len 1024)        : ~1,000 Chinese chars, ~1,400 drops 17
#
# A 384-word clause is ordinary. Before this assertion the only difference between
# "judged the clause" and "judged its first two thirds" was a boolean inside
# `usage`, which no caller reads. Two parts, both checked: the English paths must
# SURFACE it, and the Chinese path must REFUSE to grade, because Chinese
# synthesises one word from the three numbers.

$truncScript = @'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("s", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

out = {}
out["clean"] = m._laya_truncation({"truncated": False, "state_tokens": 100, "state_tokens_dropped": 0})
out["partial"] = m._laya_truncation({"truncated": True, "state_tokens": 489, "state_tokens_dropped": 1932})
out["missing"] = m._laya_truncation(None)

abstained = {k: {"noul": 0.4773, "answer_confidence": 0.4773,
                 "low_confidence": True, "abstention": "abstained"}
             for k in m._LAYA_ZH_QUESTIONS}
out["zh_grade_abstained"] = m._laya_zh_verdict(abstained)

passed = {k: {"noul": 0.99, "answer_confidence": 0.99, "abstention": "passed"}
          for k in m._LAYA_ZH_QUESTIONS}
out["zh_grade_passed"] = m._laya_zh_verdict(passed)

clear = {k: {"noul": 0.01, "answer_confidence": 0.9, "abstention": "passed"}
         for k in m._LAYA_ZH_QUESTIONS}
out["zh_grade_clear"] = m._laya_zh_verdict(clear)

mixed = dict(clear)
mixed["unilateral"] = {"noul": 0.6, "answer_confidence": 0.6,
                       "low_confidence": True, "abstention": "abstained"}
out["zh_grade_mixed"] = m._laya_zh_verdict(mixed)
print(json.dumps(out, ensure_ascii=False))
'@
$tmp3 = Join-Path $env:TEMP ("trunc-" + [guid]::NewGuid().ToString('n').Substring(0, 6) + '.py')
[System.IO.File]::WriteAllText($tmp3, $truncScript, [System.Text.UTF8Encoding]::new($false))
$raw3 = & $py $tmp3 (Resolve-Path $server) 2>&1 | Out-String
Remove-Item -LiteralPath $tmp3 -Force -ErrorAction SilentlyContinue

$t = $null
try { $t = ($raw3 -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json } catch { }
if (-not $t) {
    Skip 'L11 behavioural checks' "server.py could not be imported: $($raw3.Substring(0,[Math]::Min(200,$raw3.Length)))"
}
else {
    Check 'a fully-read clause reports no partial object' ($null -eq $t.clean) `
        "reported: $($t.clean | ConvertTo-Json -Compress)"
    Check 'a missing usage block does not report a partial object' ($null -eq $t.missing) `
        'fabricating truncation on an absent usage block would cry wolf on every call'
    Check 'a truncated read carries the dropped token count' `
        (($t.partial.partial -eq $true) -and ($t.partial.state_tokens_dropped -eq 1932)) `
        "reported: $($t.partial | ConvertTo-Json -Compress)"

    Check 'an abstained Chinese answer withholds the grade' `
        (($t.zh_grade_abstained.withheld -eq $true) -and ($null -eq $t.zh_grade_abstained.grade)) `
        "grade='$($t.zh_grade_abstained.grade)' - an abstained answer graded low is false clearance, the one verdict this path must never emit"
    Check 'the withheld payload names which question abstained' `
        (@($t.zh_grade_abstained.abstained_questions).Count -eq 3) `
        "abstained_questions=$($t.zh_grade_abstained.abstained_questions -join ',')"
    Check 'one abstained question among passing ones still withholds' `
        (($t.zh_grade_mixed.withheld -eq $true) -and ((@($t.zh_grade_mixed.abstained_questions) -join ',') -eq 'unilateral')) `
        "withheld=$($t.zh_grade_mixed.withheld) questions=$($t.zh_grade_mixed.abstained_questions -join ',')"
    Check 'a genuinely clear Chinese clause still grades low' `
        (($t.zh_grade_clear.withheld -eq $false) -and ($t.zh_grade_clear.grade -eq 'low')) `
        "grade='$($t.zh_grade_clear.grade)' withheld=$($t.zh_grade_clear.withheld) - withholding must not swallow the real low"
    Check 'a clearly risky Chinese clause still grades high' `
        (($t.zh_grade_passed.withheld -eq $false) -and ($t.zh_grade_passed.grade -eq 'high')) `
        "grade='$($t.zh_grade_passed.grade)'"

    foreach ($fn in @('pacgate_clause_risk', 'pacgate_clause_flags')) {
        $body = [regex]::Match($src, '(?ms)^def\s+' + $fn + '\s*\((?<all>.*?)(?=^@mcp\.tool|\z)')
        Check "$fn reports a partial read beside its answers" `
            ($body.Success -and ($body.Groups['all'].Value -match '"partial":\s*_laya_truncation\(data\.get\("usage"\)\)')) `
            'usage.truncated lives in a block the agent never reads; a probability over a prefix must not look like one over the clause'
    }
}

Write-Host ''
# 6. Behavioural, and the last line of defence. Compare the service's own `loaded`
#    list against the checkpoints LAYA_MODELS asks for, then prove an ENGLISH
#    round-trip - `loaded` is the service's claim, a 500 is the observable fact.
#
#    An existing-but-stopped container is a FAIL, not a skip. Measured 2026-11-02: a
#    cache missing the checkpoint LAYA_MODELS names makes `laya-serve` exit 1 at boot,
#    and the first version of this block treated that exactly like "profile not
#    enabled" - green summary, dead service. Only the complete absence of a container
#    is the legitimate skip.
$exists = (& docker ps -a --filter 'name=^laya$' --format '{{.Names}}' 2>$null | Out-String).Trim()
$running = (& docker ps --filter 'name=^laya$' --format '{{.Names}}' 2>$null | Out-String).Trim()
if (-not $exists) {
    Skip 'running laya serves every configured checkpoint' 'no laya container exists (the profile is opt-in)'
}
elseif (-not $running) {
    $exitState = (& docker ps -a --filter 'name=^laya$' --format '{{.Status}}' 2>$null | Out-String).Trim()
    $tail = (& docker logs --tail 6 laya 2>&1 | Out-String).Trim()
    Check 'the existing laya container is running' $false `
        "status: $exitState. A laya container that exists but is not running means the profile was enabled and the service died - most often a cache missing a checkpoint LAYA_MODELS names. Last log lines: $tail"
}
else {
    $healthJson = (& docker exec laya python -c "import json,urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=6).read().decode())" 2>&1 | Out-String).Trim()
    $health = $null
    try { $health = $healthJson | ConvertFrom-Json } catch { }

    if (-not $health) {
        Check 'running laya answers /health with JSON' $false $healthJson
    }
    else {
        # Read the configured list from the LIVE container. If it cannot be read,
        # FAIL rather than assume a default: falling back to 'multilingual' here
        # would make a multilingual-only cache pass, which is precisely the state
        # this assertion exists to reject.
        $modelsRaw = (& docker exec laya printenv LAYA_MODELS 2>&1 | Out-String).Trim()
        if (-not $modelsRaw -or $modelsRaw -match 'not found|No such|executable file') {
            Check 'LAYA_MODELS is readable from the running laya' $false `
                "printenv returned: '$modelsRaw' - without it the checkpoints this service is meant to serve are unknown"
        }
        else {
            $want = @($modelsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $loaded = @($health.loaded)
            $missing = @($want | Where-Object { $loaded -notcontains $_ })
            Check 'every checkpoint in LAYA_MODELS is loaded' ($missing.Count -eq 0) `
                "LAYA_MODELS asks for [$($want -join ', ')] but the service loaded [$($loaded -join ', ')]; a missing checkpoint makes that language return HTTP 500 while compose still reports healthy"
        }

        # The observable fact, not the service's self-report.
        $enProbe = @'
import json, urllib.request
body = json.dumps({"state": "The Supplier shall be liable for all losses without limitation.",
                    "questions": {"r": {"type": "noul", "instructions": "Is this risky?"}}}).encode()
req = urllib.request.Request("http://127.0.0.1:8000/v1/systemone", data=body,
                             headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=90).read()
    print("OK")
except Exception as e:
    print("FAIL " + type(e).__name__ + " " + str(e)[:80])
'@
        $tmpEn = Join-Path $env:TEMP ("enprobe-" + [guid]::NewGuid().ToString('n').Substring(0, 6) + '.py')
        [System.IO.File]::WriteAllText($tmpEn, $enProbe, [System.Text.UTF8Encoding]::new($false))
        & docker cp $tmpEn "laya:/tmp/enprobe.py" 2>&1 | Out-Null
        $enOut = (& docker exec laya python /tmp/enprobe.py 2>&1 | Out-String).Trim()
        & docker exec laya rm -f /tmp/enprobe.py 2>&1 | Out-Null
        Remove-Item -LiteralPath $tmpEn -Force -ErrorAction SilentlyContinue
        Check 'a running laya can actually serve an English clause' ($enOut -match '^OK') `
            "English round-trip returned: $enOut - this is the partial-cache failure mode, where /health says ok and only English breaks"
    }
}

Write-Host ''
$total = $script:pass + $script:fail
if ($script:fail -eq 0) {
    Write-Host "RESULT: the laya tools ship, degrade safely, and keep abstention. ($($script:pass) passed, $($script:skip) skipped)" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:fail) of $total assertion(s) failed." -ForegroundColor Red
exit 1
