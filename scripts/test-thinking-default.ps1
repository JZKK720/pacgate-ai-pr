# Guard: an UNSET chat mode must not enable thinking.
#
# WHY THIS EXISTS (measured 2026-10-30)
#
# `hooks.ts` computed `thinking_enabled: context.mode !== "flash"`. The mode default
# lives in local storage, so on a fresh profile mode is `undefined` and
# `undefined !== "flash"` is TRUE - thinking on for every first-turn run. A second
# site compounded it: `getResolvedMode()` returned "pro" whenever the model
# supported thinking, and its caller is a mount effect.
#
# Consequence: `when_thinking_disabled: {reasoning_effort: none}` in
# deer-flow-config.yaml - present for every thinking-capable model - is applied only
# when thinking_enabled is false, so it never fired. 12 deepseek-v4.1-flash replies
# finished with reason=length after 8192/8192 tokens of reasoning and an empty
# message.
#
# This is BUILD-TIME source. The frontend image ships compiled output and has no
# source mount, so a container restart cannot pick this up - only a rebuild can. The
# gate asserts the source so the next image build carries the fix.
#
# Exit 2 means CANNOT CHECK.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$hooks = 'deploy/frontend-patches/files/src/core/threads/hooks.ts'
$box   = 'deploy/frontend-patches/files/src/components/workspace/input-box.tsx'
$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== thinking default ===' -ForegroundColor Cyan
Check 'hooks.ts exists' (Test-Path $hooks) $hooks
Check 'input-box.tsx exists' (Test-Path $box) $box
if (-not (Test-Path $hooks) -or -not (Test-Path $box)) { Write-Host 'RESULT: cannot continue'; exit 1 }

$h = Get-Content $hooks -Raw
$b = Get-Content $box -Raw

# ── T1 ───────────────────────────────────────────────────────────────────────
# The exact defect. A negation is what made it true for undefined.
Check 'T1 thinking is not derived from a "!= flash" negation' `
      ($h -notmatch 'thinking_enabled\s*:\s*[^\r\n]*?!=="flash"' -and
       $h -notmatch 'thinking_enabled\s*:\s*[^\r\n]*?!==\s*"flash"') `
      'thinking_enabled: context.mode !== "flash" is true when mode is undefined'

# ── T2 ───────────────────────────────────────────────────────────────────────
# The three mode names must sit inside the SAME expression. Checking for
# `=== "pro"` anywhere in the file would pass on the unrelated is_plan_mode line
# two lines below it.
$t2 = [regex]::Match($h, 'thinking_enabled:[\s\S]{0,500}?(?=\n\s*is_plan_mode:)')
Check 'T2 the thinking_enabled expression can be isolated' $t2.Success
if ($t2.Success) {
    Check 'T2 it names "thinking"' ($t2.Value -match 'context\.mode\s*===\s*"thinking"')
    Check 'T2 it names "pro"'      ($t2.Value -match 'context\.mode\s*===\s*"pro"')
    Check 'T2 it names "ultra"'    ($t2.Value -match 'context\.mode\s*===\s*"ultra"')
}

# ── T3 ───────────────────────────────────────────────────────────────────────
Check 'T3 getResolvedMode does not default to pro' `
      ($b -notmatch 'return supportsThinking \? "pro" : "flash"') `
      'that default runs on mount and turns thinking on before the user chooses'
Check 'T3 an unset mode resolves to flash' ($b -match 'return mode \?\? "flash"')

# ── T4 ───────────────────────────────────────────────────────────────────────
# The reason must be recorded at both sites, so a future edit does not "simplify"
# the negation back.
Check 'T4 hooks.ts records why the negation was wrong' ($h -match 'UNSET mode must not enable thinking')
Check 'T4 input-box.tsx records why the pro default was removed' ($b -match 'do NOT default an unset mode')

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
