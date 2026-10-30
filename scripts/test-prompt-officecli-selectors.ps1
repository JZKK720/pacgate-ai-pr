# Guard: the lead-agent prompt must not teach an officecli syntax the sandbox rejects.
#
# WHY THIS EXISTS (measured 2026-10-30, officecli 1.0.149 on 0.2.7)
#
#   officecli set  <f> body/p[1] --prop text=x   -> No elements matched selector
#   officecli set  <f> /body/p[1] --prop text=x  -> Updated /body/p[1]
#
# `set` only accepts the slash form. But deer-flow's
# `validate_local_bash_command_paths` rejects any `/`-prefixed token on a bash
# command line:
#
#   officecli add /mnt/user-data/outputs/x.docx /body --type paragraph
#     -> Unsafe absolute paths in command: /body
#   officecli get /mnt/user-data/outputs/x.docx /body --depth 2 --json
#     -> Unsafe absolute paths in command: /body
#
# The shipped prompt told the agent to run both of those. The only form both accept
# is `officecli batch <f> --input <json>`, where the selector is file content.
# `create` and `validate` take a plain path and are allowed.
#
# This gate asserts the prompt teaches the form that works. Prose that merely
# MENTIONS the slash form while explaining why it is unavailable is fine - the
# check is that no officecli verb is followed by a slash selector as an instruction.
#
# Exit 2 means CANNOT CHECK.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$prompt = 'deploy/client-bundle/patches/deer-flow-prompt.py'
$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== prompt vs officecli selector contract ===' -ForegroundColor Cyan
Check 'the prompt patch exists' (Test-Path $prompt) $prompt
if (-not (Test-Path $prompt)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$src = Get-Content $prompt -Raw

# ── P1 ───────────────────────────────────────────────────────────────────────
# An INSTRUCTION looks like: backtick, officecli, a mutating verb, args, a slash
# selector, closing backtick. The explanation in the selector note is prose inside
# a bullet, and it names the verbs without a backticked slash selector, so it does
# not match. Anchoring on the backtick is what separates "run this" from "do not
# run this".
$bad = [regex]::Matches($src, '`officecli\s+(add|get|set|remove|move|swap)\s+[^`\r\n]*?/(body|slide|sheet|para)\b')
Check 'P1 no backticked officecli verb takes a slash selector' `
      ($bad.Count -eq 0) `
      (($bad | ForEach-Object { $_.Value.Trim() }) -join ' | ')

# ── P2 ───────────────────────────────────────────────────────────────────────
Check 'P2 the prompt documents officecli batch --input' `
      ($src -match 'officecli batch')
Check 'P2 the batch form shows the --input flag' ($src -match '--input')

# ── P3 ───────────────────────────────────────────────────────────────────────
# create and validate take a plain path; they must remain the direct forms, or the
# agent loses the two verbs it can actually run.
Check 'P3 officecli create is still documented' ($src -match 'officecli create')

# ── P4 ───────────────────────────────────────────────────────────────────────
# The reason must be recorded, so a future edit does not "simplify" it back.
Check 'P4 the prompt explains why the slash form is unavailable' `
      ($src -match 'Unsafe absolute paths')
Check 'P4 the prompt records that set rejects the slash-free form' `
      ($src -match 'No elements matched selector')

# ── P5 (live, advisory) ──────────────────────────────────────────────────────
# The two forms the prompt now teaches must actually pass the sandbox validator.
$running = $false
try { $running = ((docker inspect -f '{{.State.Health.Status}}' deer-flow 2>$null) -eq 'healthy') } catch { $running = $false }

if (-not $running) {
    Write-Host '  [skip] CANNOT CHECK: deer-flow is not running healthy.' -ForegroundColor Yellow
} else {
    $probeDir = Join-Path $env:TEMP ("officecli-contract-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    $probeFile = Join-Path $probeDir 'probe.py'
    @'
from deerflow.sandbox.tools import validate_local_bash_command_paths
from deerflow.config.paths import get_paths

p = get_paths()
td = {"workspace_path": str(p.sandbox_work_dir("T1", user_id="u")),
      "uploads_path": str(p.sandbox_uploads_dir("T1", user_id="u")),
      "outputs_path": str(p.sandbox_outputs_dir("T1", user_id="u"))}

allowed = ['officecli create /mnt/user-data/outputs/x.docx',
           'officecli validate /mnt/user-data/outputs/x.docx',
           'officecli batch /mnt/user-data/outputs/x.docx --input cmds.json']
blocked = ['officecli add /mnt/user-data/outputs/x.docx /body --type paragraph']

for c in allowed:
    try:
        validate_local_bash_command_paths(c, td)
        print("ALLOW_OK", c)
    except Exception:
        print("ALLOW_ERR", c)
for c in blocked:
    try:
        validate_local_bash_command_paths(c, td)
        print("BLOCK_ERR", c)
    except Exception:
        print("BLOCK_OK", c)
'@ | Out-File -FilePath $probeFile -Encoding utf8
    docker cp $probeFile "deer-flow:/tmp/officecli_contract_probe.py" 2>$null | Out-Null
    $probe = docker exec deer-flow sh -c "cd /app/backend && .venv/bin/python /tmp/officecli_contract_probe.py" 2>$null
    Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue

    Check 'P5 the documented create/validate/batch forms pass the validator' `
          (($probe | Select-String 'ALLOW_OK').Count -eq 3) `
          (($probe | Out-String).Trim() -replace '\s+', ' ')
    Check 'P5 the slash-selector form is still the one the sandbox blocks' `
          (($probe | Select-String 'BLOCK_OK').Count -eq 1) `
          'if officecli ever fixes set(), this line tells you to delete the workaround note'
}

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
