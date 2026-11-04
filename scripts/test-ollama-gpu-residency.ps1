# Gate: local model inference must actually be on the GPU.
#
# WHY THIS EXISTS (measured 2026-11-04)
#
# The user's complaint was "a simple prompt runs past 36 steps and the LLM never
# answers". The turn loop was NOT the defect - deer-flow was calling the model and
# calling MCP tools correctly. The model itself was running on the CPU:
#
#   $ ollama ps
#   NAME                 ID   SIZE    PROCESSOR  CONTEXT  RUNNER
#   gemma4:12b-it-qat    ...  9.7 GB  100% CPU   65536    llamacpp
#
# and Ollama's own startup log showed it had enumerated exactly one device:
#
#   msg="inference compute" library=cpu compute="" name=cpu \
#       total="61.6 GiB" available="17.9 GiB"
#
# So there was no GPU backend at all, and a 12B model on CPU generated at roughly
# 1-2 tokens/second. One trivial run against the live stack took:
#
#   run started 07:27:36 -> first model call returned 07:32:41  (305 s)
#   tool call issued + completed at 07:32:44
#   no further model call completed for the next 15+ minutes
#
# while every existing gate stayed green. A direct prompt of "hi" took 377 s.
# Nothing failed; the product was simply unusable, and no check said so.
#
# A stack-level smoke test cannot catch this: pacgate-api, pacgate-mcp, OCR and
# the frontends are all healthy, and the chat request is accepted. The GPU is the
# only place the truth is visible.
#
# Exit: 0 = every resident runner is on a GPU (or none is loaded)
#       1 = a runner is on CPU -> the stack will appear to hang
#       2 = CANNOT CHECK (ollama not reachable) and is never a pass
[CmdletBinding()]
param(
    # Treat a CPU-only runner as a hard failure. Set -WarnOnly to report without
    # failing, for a deliberately CPU-only demo box.
    [switch]$WarnOnly
)

$ErrorActionPreference = 'Continue'

function Ok($m)   { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow }

Write-Host "=== Ollama GPU residency gate ===" -ForegroundColor White

# ── Can we see Ollama at all? ────────────────────────────────────────────────
$tags = $null
try {
    $tags = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 10
} catch {
    Skip "ollama is not reachable at http://localhost:11434 - CANNOT CHECK, not a pass"
    exit 2
}
Write-Host "  ollama reachable, $($tags.models.Count) model(s) installed" -ForegroundColor Gray

# ── Which device did the server enumerate? ───────────────────────────────────
#
# This is the decisive signal and it is available BEFORE anything is loaded, which
# matters: an unloaded server reports no runner, so `ollama ps` alone would let a
# completely broken GPU setup look clean right up until the first chat.
$serverLog = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'
$computeLines = @()
if (Test-Path $serverLog) {
    $computeLines = @(Get-Content $serverLog -Tail 20000 |
        Select-String -Pattern 'msg="inference compute"')
}

$gpuDevices = @()
if ($computeLines.Count -gt 0) {
    # Use the LAST boot's enumeration, not every boot this log has ever seen: a
    # machine whose GPU stopped being detected must not pass on a stale line.
    $lastBoot = $computeLines | Select-Object -Last 1
    $bootStamp = ([regex]::Match($lastBoot.Line, 'time=(\S+)')).Groups[1].Value
    if ($bootStamp) {
        $bootDate = try { [datetimeoffset]::Parse($bootStamp).UtcDateTime } catch { $null }
        if ($bootDate) {
            $computeLines = @($computeLines | Where-Object {
                $t = ([regex]::Match($_.Line, 'time=(\S+)')).Groups[1].Value
                $d = try { [datetimeoffset]::Parse($t).UtcDateTime } catch { $null }
                $d -and ([math]::Abs(($d - $bootDate).TotalMinutes) -lt 5)
            })
        }
    }
    foreach ($cl in $computeLines) {
        $lib = ([regex]::Match($cl.Line, 'library=(\S+)')).Groups[1].Value
        $nm  = ([regex]::Match($cl.Line, 'name=(\S+)')).Groups[1].Value
        if ($lib -and $lib -ne 'cpu') { $gpuDevices += [pscustomobject]@{ Library = $lib; Name = $nm } }
    }
}

if ($computeLines.Count -eq 0) {
    Skip "no 'inference compute' line in $serverLog - cannot tell which device ollama enumerated"
} elseif ($gpuDevices.Count -eq 0) {
    $seen = ($computeLines | ForEach-Object { ([regex]::Match($_.Line, 'library=(\S+)')).Groups[1].Value }) -join ', '
    if ($WarnOnly) {
        Skip "ollama enumerated ONLY CPU (libraries: $seen). Inference will be unusably slow; -WarnOnly set."
    } else {
        Bad "ollama enumerated NO GPU device (libraries: $seen)"
        Write-Host "         Every local model will run on the CPU at ~1-2 tokens/second." -ForegroundColor Yellow
        Write-Host "         A chat turn then takes minutes per step and looks exactly like a hang." -ForegroundColor Yellow
        Write-Host "         Fix the Ollama install / GPU driver for this vendor and restart the Ollama app." -ForegroundColor Yellow
    }
} else {
    Ok ("ollama enumerated GPU device(s): " + (($gpuDevices | ForEach-Object { "$($_.Name) [$($_.Library)]" }) -join ', '))
}

# ── Is any LOADED runner actually on the GPU? ────────────────────────────────
#
# The enumeration above can be right while a specific model still spills to CPU
# because its KV cache does not fit at the requested context. That is a different
# failure with the same symptom, so it is checked separately.
$rows = @()
$psOut = & ollama ps 2>$null
if ($psOut) {
    foreach ($line in ($psOut | Select-Object -Skip 1)) {
        if (-not $line.Trim()) { continue }
        $f = @($line.Trim() -split '\s{2,}')
        if ($f.Count -lt 6) { continue }
        $rows += [pscustomobject]@{
            Name = $f[0]; Size = $f[2]; Processor = $f[3]; Context = $f[4]
        }
    }
}

if ($rows.Count -eq 0) {
    Write-Host "  no runner loaded right now - residency is checked at enumeration only" -ForegroundColor Gray
    Ok "no runner loaded (nothing can be on the CPU yet)"
} else {
    foreach ($r in $rows) {
        # "100% GPU", "100% CPU", or a split such as "48%/52% CPU/GPU".
        if ($r.Processor -match 'GPU' -and $r.Processor -notmatch '^\s*100%\s*CPU') {
            Ok "$($r.Name) is on the GPU ($($r.Processor), ctx $($r.Context), $($r.Size))"
        } elseif ($WarnOnly) {
            Skip "$($r.Name) is on the CPU ($($r.Processor), ctx $($r.Context)) - -WarnOnly set"
        } else {
            Bad "$($r.Name) is running on the CPU ($($r.Processor), ctx $($r.Context), $($r.Size))"
            Write-Host "         A loaded model on the CPU is the 'agent never answers' symptom." -ForegroundColor Yellow
        }
    }
}

Write-Host ''
$failed = @($rows | Where-Object {
    -not ($_.Processor -match 'GPU' -and $_.Processor -notmatch '^\s*100%\s*CPU')
}).Count
$noGpu = ($computeLines.Count -gt 0 -and $gpuDevices.Count -eq 0)

if (-not $WarnOnly -and ($noGpu -or ($rows.Count -gt 0 -and $failed -gt 0))) {
    Write-Host "RESULT: FAIL - local inference is not on the GPU" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: local inference is GPU-backed" -ForegroundColor Green
exit 0
