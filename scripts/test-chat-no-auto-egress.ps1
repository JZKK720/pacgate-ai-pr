# PROVES the deer-flow auto-escalation target does not egress client material.
#
# WHY THIS EXISTS
#
# `model_routing` in deer-flow-config.yaml routes a run to the escalation target when
# the CONVERSATION HISTORY crosses a token threshold, and only when the user did not
# pick a model. That history grows with uploaded-document text and tool results, so
# the escalation path is exactly the path a client's document travels.
#
# It shipped pointing at `glm-5.3-flash-cloud` with a 20,000-token threshold --
# roughly a 30-page contract. So an attorney who uploaded an ordinary document and
# left the model picker alone had that document sent to ollama.com with no
# sanitizer, no consent and no banner. That is the firm's core promise violated by a
# default, and it needs a gate rather than a comment: a config value with no test is
# a value that regresses the next time someone edits the file.
#
# ASSERTS:
#   A1 the escalation target in deer-flow-config.yaml is NOT a cloud tag
#   A2 it resolves to a model actually DEFINED in `models:` (a typo would fall back
#      to the default at runtime and silently disable escalation entirely)
#   A3 `local_model` also resolves
#   A4 the threshold is high enough that one document does not cross it
#   A5 every model still offered to the picker is either installed or a known cloud
#      tag -- a picker entry that 404s on select is a defect this repo has shipped
#      before (see the disabled qwen3.5/gemma4-26b entries)
#   A6 the agent PATCH reports the target kind rather than always saying "cloud"
#
# Exit: 0 = all pass, 1 = a real failure, 2 = cannot check.
#
# Usage: pwsh -File scripts/test-chat-no-auto-egress.ps1

[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$PatchPath = '',
    [string]$OllamaBase = 'http://localhost:11434',
    # Fail if ollama is unreachable instead of skipping A5's installed check.
    [switch]$RequireOllama
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $repo 'deploy/client-bundle/deer-flow-config.yaml' }
if (-not $PatchPath)  { $PatchPath  = Join-Path $repo 'deploy/client-bundle/patches/deer-flow-agent.py' }

$script:failures = 0
$script:checks = 0

function Check($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) {
        Write-Host "  [PASS] $label" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $label" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:failures++
    }
}

function Die($msg) {
    Write-Host "`nCANNOT CHECK: $msg" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== chat lane: no automatic egress ===' -ForegroundColor Cyan

if (-not (Test-Path $ConfigPath)) { Die "config not found: $ConfigPath" }
if (-not (Test-Path $PatchPath))  { Die "patch not found: $PatchPath" }

# ── Parse the config with Python's yaml: the same parser deer-flow uses ────────
$py = @'
import json, sys
try:
    import yaml
except ImportError:
    print(json.dumps({"error": "pyyaml missing"})); sys.exit(2)
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print(json.dumps({"error": "yaml parse failed: %s" % e})); sys.exit(2)
models = d.get("models") or []
mr = d.get("model_routing") or {}
out = {
    "names": [m.get("name") for m in models],
    "tags":  {m.get("name"): m.get("model") for m in models},
    "routing": {
        "enabled": mr.get("enabled"),
        "local_model": mr.get("local_model"),
        "cloud_model": mr.get("cloud_model"),
        "message_token_threshold": mr.get("message_token_threshold"),
        "tool_count_threshold": mr.get("tool_count_threshold"),
    },
}
print(json.dumps(out))
'@

$tmpPy = Join-Path ([System.IO.Path]::GetTempPath()) "cfgparse-$([guid]::NewGuid().ToString('N').Substring(0,8)).py"
Set-Content -Path $tmpPy -Value $py -Encoding UTF8
try {
    $raw = & python $tmpPy $ConfigPath 2>&1
} finally {
    Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
}
$cfg = $null
try { $cfg = $raw | ConvertFrom-Json } catch { }
if (-not $cfg -or $cfg.error) { Die "could not read the config: $raw" }

$names = @($cfg.names)
$routing = $cfg.routing
Write-Host "  models defined : $($names -join ', ')"
Write-Host "  routing        : enabled=$($routing.enabled) local=$($routing.local_model) escalate=$($routing.cloud_model) threshold=$($routing.message_token_threshold)"

# ── A1: the escalation target must not be a cloud tag ─────────────────────────
# Check BOTH the model name and its ollama tag, against BOTH cloud spellings.
#
# This repo uses both forms in the SAME config:
#   name deepseek-v4-flash-0731-cloud  tag deepseek-v4-flash:0731-cloud   (hyphen)
#   name deepseek-v4-pro-cloud         tag deepseek-v4-pro:cloud          (colon)
# A check for only one form passes on the other. An earlier version of this file
# tested `-not $tag.EndsWith('-cloud')` alone and therefore PASSED when the defect
# was deliberately reintroduced as `glm-5.3-flash:cloud` -- a gate that cannot fail
# on its own defect is worse than no gate, because it reports safety it never
# verified.
$targetName = $routing.cloud_model
$targetTag  = $cfg.tags.$targetName
function Test-IsCloud([string]$s) {
    if (-not $s) { return $false }
    $l = $s.ToLower()
    return $l.EndsWith('-cloud') -or $l.EndsWith(':cloud')
}
$nameIsCloud = Test-IsCloud $targetName
$tagIsCloud  = Test-IsCloud $targetTag
Check "A1 escalation target is NOT a cloud model" `
    (-not $nameIsCloud -and -not $tagIsCloud) `
    "name='$targetName' (cloud=$nameIsCloud) tag='$targetTag' (cloud=$tagIsCloud) - an escalation target on a cloud tag sends uploaded document text to a third party with no sanitizer, no consent and no banner"
Write-Host "     escalation name: $targetName"
Write-Host "     escalation tag : $targetTag"
Check "A1b the escalation target resolves to a tag at all" ([bool]$targetTag) `
    "no tag found for '$targetName' - the check above cannot prove anything without one"

# ── A2/A3: both routing names must resolve to a defined model ────────────────
Check "A2 escalation target is a defined model" ($names -contains $routing.cloud_model) `
    "'$($routing.cloud_model)' is not in models: - a typo makes deer-flow fall back to the default and silently disables escalation"
Check "A3 local_model is a defined model" ($names -contains $routing.local_model) `
    "'$($routing.local_model)' is not in models:"

# ── A4: the threshold must not be crossed by one ordinary document ────────────
# A 30-page contract at ~800 tokens/page is ~24,000 tokens. It arrives with the
# user's question, the system prompt (~41K per the patch docstring) and tool
# results on top, so the conversation reaches the threshold well before the user
# has done anything unusual.
#
# The defect value was 20,000 -- which the config's own comment described as
# "roughly a 30-page document". An earlier version of this check used an 18,000
# baseline, so 20,000 PASSED: the baseline was set below the defect, and the gate
# rubber-stamped exactly the number it was written to reject. The baseline has to
# come from the claim being tested, not from a number that happens to pass.
$oneDocumentTokens = 24000
$threshold = [int]$routing.message_token_threshold
Check "A4 threshold ($threshold) exceeds one ordinary document (~$oneDocumentTokens tokens)" `
    ($threshold -gt $oneDocumentTokens) `
    "a ~30-page contract plus tool results crosses $threshold, so an attorney uploading one ordinary document would trigger escalation without ever choosing a model"

# ── A5: picker entries must not 404 on select ────────────────────────────────
$installed = @()
$ollamaUp = $false
try {
    $tagsRaw = & ollama list 2>&1
    if ($LASTEXITCODE -eq 0) {
        $ollamaUp = $true
        $installed = @($tagsRaw | Select-Object -Skip 1 | ForEach-Object {
            ($_ -split '\s+')[0]
        } | Where-Object { $_ })
    }
} catch { }

if ($ollamaUp) {
    Write-Host "  ollama reachable; installed tags: $($installed.Count)"
    $unavailable = @()
    foreach ($n in $names) {
        $tag = $cfg.tags.$n
        if (-not $tag) { continue }
        # Cloud models carry no local weight layers; `ollama list` shows them with
        # size "-" and normalises `x:cloud` to `x:cloud:latest`.
        #
        # The cloud marker appears in BOTH forms in this repo's own config:
        #   name deepseek-v4-flash-0731-cloud  tag deepseek-v4-flash:0731-cloud
        #   name deepseek-v4-pro-cloud         tag deepseek-v4-pro:cloud
        # Checking only one form silently skips the other, which is how this check
        # first reported a false failure.
        $lower = $tag.ToLower()
        if ($lower.EndsWith('-cloud') -or $lower.EndsWith(':cloud')) { continue }
        # A local tag must be present under one of its ollama spellings.
        $candidates = if ($tag -match ':') { @($tag, "$tag`:latest") } else { @("$tag`:latest", $tag) }
        if (-not ($candidates | Where-Object { $installed -contains $_ })) {
            $unavailable += "$n ($tag)"
        }
    }
    Check "A5 every non-cloud picker model is installed locally" ($unavailable.Count -eq 0) `
        "these would 404 when selected: $($unavailable -join '; ')"
} elseif ($RequireOllama) {
    Die 'ollama is unreachable and -RequireOllama was set'
} else {
    Write-Host "  [SKIP] A5 - ollama unreachable, cannot verify installed tags" -ForegroundColor Yellow
}

# ── A6: the patch must report the target KIND ────────────────────────────────
$patchSrc = Get-Content $PatchPath -Raw
Check "A6 the routing log reports target kind, not a hardcoded 'cloud'" `
    ($patchSrc -match 'target_kind') `
    "the log said 'cloud model' unconditionally, so a LOCAL escalation would be misreported as egress and a later audit would reach the wrong conclusion"
Check "A6b the log carries the egress/on-device distinction" `
    ($patchSrc -match 'CLOUD \(egress\)' -and $patchSrc -match 'LOCAL \(on-device\)') `
    "expected both labels so the log is unambiguous"

# ── A7/A8: the config must not assert egress is impossible ───────────────────
# The header used to read "on-board local models (ollama.com blocked)". NOTHING in
# this repo blocks ollama.com -- no hosts entry, no firewall rule, no proxy -- so
# that line asserted a control that does not exist. It is the reason this defect
# stayed invisible: an operator (and a reviewer) reading "blocked" concludes a
# cloud tag is inert, and stops looking. A false negative in the documentation is
# what let a real egress path ship, so it gets its own check.
$cfgSrc = Get-Content $ConfigPath -Raw
Check "A7 the config does not claim ollama.com is blocked" `
    ($cfgSrc -notmatch 'on-board local models \(ollama\.com blocked\)') `
    "the old header asserted an enforcement that does not exist; cloud tags are reachable unless the client's own network blocks them"
Check "A8 the config states cloud tags are reachable and explicit-only" `
    ($cfgSrc -match 'send prompt text to ollama\.com' -or $cfgSrc -match 'REACHABLE') `
    "the header should warn that :cloud tags egress wherever the network allows, so a reader does not infer safety from this file"

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host "RESULT: $($script:checks) of $($script:checks) checks passed" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:failures) of $($script:checks) checks FAILED" -ForegroundColor Red
exit 1
