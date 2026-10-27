# Asserts the memory lane's prompt is PREFIX-STABLE and BOUNDED.
#
# WHY THIS GATE EXISTS
#
# llama.cpp (behind Ollama) reuses a prompt prefix only up to the first
# differing token. The memory lane's prompt template used to read:
#
#     Current Memory State:
#     <current_memory>{current_memory}</current_memory>
#
#     New Conversation to Process:
#     <conversation>{conversation}</conversation>
#
# `current_memory` changes on every successful update, so the prefix changed on
# every update and the cache could never be reused. Measured on the HX370 box
# (Ollama 0.40.11, gemma4:12b-it-qat), holding the conversation constant and
# changing only the memory block:
#
#     update #1 (cold)             77.7 s   cached=0
#     update #2 (memory changed)  68.7 s   cached=0
#     update #3 (memory changed)  68.7 s   cached=0
#     update #3 again (identical)  0.5 s   cached=35028
#
# Three consecutive updates, three full cold prefills. After moving the
# conversation block first and the memory block last, the same sequence at
# 35k tokens measured 68.9 s -> 1.3 s -> 1.2 s (cached=35032).
#
# The second half of the gate covers the input bound. `format_conversation_for_update`
# truncated each message to 1000 chars but capped neither the message count nor
# the total, and `filter_messages_for_memory` keeps every human message plus
# every final AI message - so the memory prompt grew with the conversation and
# reached chat-sized (~35k tokens). That pays a ~70 s cold prefill, evicts the
# chat lane's prompt-cache entry, and competes for the same 8 GiB cache budget.
#
# SCOPE DISCIPLINE: this asserts the SHIPPED PATCH, not a live model call. A
# pass means "the mounted prompt.py puts the stable block first and enforces a
# cap" - not "the cache hit". The cache-hit proof is the measurement above and
# the live probe in plans/031.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. "Cannot check" is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== memory prompt prefix stability + input bound ===' -ForegroundColor Cyan

$bundle = 'deploy/client-bundle'
$patch = Join-Path $bundle 'patches/deer-flow-memory-prompt.py'

# ---------------------------------------------------------------------------
# 1. The patch exists and is syntactically valid Python.
# ---------------------------------------------------------------------------
if (-not (Test-Path $patch)) {
    Write-Host "  exit 2 - $patch not found; cannot verify the memory prompt shape" -ForegroundColor Yellow
    exit 2
}

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) {
    Write-Host '  exit 2 - no python on PATH; cannot parse the patch' -ForegroundColor Yellow
    exit 2
}

$syntax = & $py.Source -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read()); print('ok')" $patch 2>&1
if ($LASTEXITCODE -eq 0 -and "$syntax" -match 'ok') {
    Pass 'patches/deer-flow-memory-prompt.py parses as Python'
}
else {
    Fail "patches/deer-flow-memory-prompt.py does not parse: $syntax"
}

# ---------------------------------------------------------------------------
# 2. The conversation block precedes the memory block in the template.
#
# Anchored to the template's own markers, not to a line number, so a comment
# edit cannot satisfy it and a reflow cannot break it.
# ---------------------------------------------------------------------------
$src = Get-Content $patch -Raw

$convIdx = $src.IndexOf('New Conversation to Process:')
$memIdx = $src.IndexOf('Current Memory State:')

if ($convIdx -lt 0 -or $memIdx -lt 0) {
    Fail 'the template no longer contains both "New Conversation to Process:" and "Current Memory State:" - the prefix-stability check cannot be evaluated'
}
elseif ($convIdx -lt $memIdx) {
    Pass 'the conversation block precedes the memory block (stable prefix)'
}
else {
    Fail 'the memory block precedes the conversation block - {current_memory} changes on every update, so the prompt prefix changes on every update and llama.cpp can never reuse it (measured 68.7 s cold per update vs 1.3 s warm)'
}

# ---------------------------------------------------------------------------
# 3. The conversation input is bounded.
# ---------------------------------------------------------------------------
if ($src -match '(?m)^MEMORY_CONVERSATION_MAX_CHARS\s*=\s*(\d+)') {
    $cap = [int]$Matches[1]
    if ($cap -gt 0 -and $cap -le 32000) {
        Pass "conversation block is capped at $cap chars"
    }
    else {
        Fail "MEMORY_CONVERSATION_MAX_CHARS is $cap; expected 1..32000 (a chat-sized memory prompt evicts the chat lane's cache entry)"
    }
}
else {
    Fail 'MEMORY_CONVERSATION_MAX_CHARS is not defined - the memory prompt grows with the conversation and reaches chat-sized'
}

if ($src -match '(?m)^MEMORY_CONVERSATION_MAX_MESSAGES\s*=\s*(\d+)') {
    $maxMsgs = [int]$Matches[1]
    if ($maxMsgs -gt 0 -and $maxMsgs -le 200) {
        Pass "conversation block is capped at $maxMsgs messages"
    }
    else {
        Fail "MEMORY_CONVERSATION_MAX_MESSAGES is $maxMsgs; expected 1..200"
    }
}
else {
    Fail 'MEMORY_CONVERSATION_MAX_MESSAGES is not defined - message count is unbounded'
}

# ---------------------------------------------------------------------------
# 4. The cap is actually APPLIED, not merely declared.
#
# A declared constant that nothing reads is the failure mode this catches. The
# behavioural proof runs the real function against an oversized conversation.
# ---------------------------------------------------------------------------
$probe = @'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pp", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class Msg:
    def __init__(self, t, c): self.type = t; self.content = c

msgs = []
for i in range(100):
    msgs.append(Msg("human", "q%d " % i + "x" * 880))
    msgs.append(Msg("ai", "a%d " % i + "y" * 880))

out = m.format_conversation_for_update(msgs)
cap = m.MEMORY_CONVERSATION_MAX_CHARS
if len(out) > cap + 10:
    print("FAIL len=%d cap=%d" % (len(out), cap)); sys.exit(1)
if "a99" not in out:
    print("FAIL newest turn dropped"); sys.exit(1)

small = m.format_conversation_for_update([Msg("human", "hi"), Msg("ai", "hello")])
if small != "User: hi\n\nAssistant: hello":
    print("FAIL small conversation was altered: %r" % small); sys.exit(1)

print("ok len=%d cap=%d" % (len(out), cap))
'@

$probePath = Join-Path ([System.IO.Path]::GetTempPath()) "pacgate-memory-prompt-probe.py"
Set-Content -Path $probePath -Value $probe -Encoding UTF8
try {
    $result = & $py.Source $probePath $patch 2>&1
    if ($LASTEXITCODE -eq 0 -and "$result" -match '^ok') {
        Pass "the cap is applied and keeps the newest turn ($result)"
    }
    else {
        Fail "the cap is declared but not applied correctly: $result"
    }
}
finally {
    Remove-Item $probePath -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 5. Every base compose that mounts the memory storage patch also mounts the
#    prompt patch. A machine that gets one and not the other has the bound
#    without the prefix fix, or neither.
# ---------------------------------------------------------------------------
$composes = Get-ChildItem $bundle -Filter 'compose*.yaml' | Sort-Object Name
$checked = 0
foreach ($c in $composes) {
    $text = Get-Content $c.FullName -Raw
    if ($text -notmatch 'deer-flow-memory-storage\.py') { continue }
    $checked++
    if ($text -match 'deer-flow-memory-prompt\.py') {
        Pass "$($c.Name) mounts the memory prompt patch"
    }
    else {
        Fail "$($c.Name) mounts deer-flow-memory-storage.py but NOT deer-flow-memory-prompt.py - the memory lane keeps its unstable prefix and unbounded input"
    }
}
if ($checked -eq 0) {
    Fail 'no compose file mounts deer-flow-memory-storage.py - the discovery anchor is gone; this gate is no longer checking what it thinks it is'
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
