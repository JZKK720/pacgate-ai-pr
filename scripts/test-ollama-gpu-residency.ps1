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
# THE CAUSE WAS AN INSTALL-ORDER RACE, NOT A BROKEN GPU.
#
# The RX 7600 XT (gfx1102) is fully supported by Ollama's bundled ROCm backend.
# The problem was that Ollama enumerates devices ONCE at server start, and it
# unpacks the ROCm backend into lib\ollama\rocm_v7_1 only AFTER it starts. Measured
# on this box:
#
#   server start        09:12:46
#   rocm_v7_1 unpacked  09:13:24   (38 s later)
#   ggml-hip.dll        09:13:32
#
# So the server had already decided "CPU only" before the backend it needed existed,
# and it stayed that way for its whole lifetime. A second instance started later on
# a different port saw the backend and enumerated the card correctly:
#
#   msg="inference compute" library=ROCm compute=gfx1102 \
#       description="AMD Radeon RX 7600 XT" total="16.0 GiB"
#   msg="dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1" \
#       (the 890M iGPU, correctly skipped)
#
# After restarting the app: gemma4 "Reply with exactly: OK" went from 377 s on CPU
# to 7.4 s at 100% GPU, and the agent->MCP end-to-end run went from failing at the
# 120-300 s client timeout to 5/5 passing.
#
# Nothing was wrong with the stack, the models, ROCm, or the GPU driver. The
# symptom was real, the diagnosis people would reach for (broken GPU support) was
# wrong, and every existing gate stayed green the whole time.
#
# So this gate's job is: make "local inference is GPU-backed" an assertion, and
# point at the install-order race as the FIRST thing to check.
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
        Write-Host ""
        Write-Host "         CHECK INSTALL ORDER FIRST - this is the usual cause:" -ForegroundColor Yellow
        Write-Host "         Ollama enumerates devices ONCE, at server start. It unpacks the" -ForegroundColor Yellow
        Write-Host "         ROCm/Vulkan backend into lib\ollama\<vendor>_* shortly AFTER it" -ForegroundColor Yellow
        Write-Host "         starts. A server that started before that unpack stays CPU-only" -ForegroundColor Yellow
        Write-Host "         for its whole lifetime, with a healthy install on disk." -ForegroundColor Yellow
        Write-Host "         Measured 2026-11-04 on the RX 7600 XT box: server pid started" -ForegroundColor Yellow
        Write-Host "         09:12:46, rocm_v7_1 unpacked 09:13:32, so every model ran on CPU" -ForegroundColor Yellow
        Write-Host "         for 3.5 hours until Ollama was restarted." -ForegroundColor Yellow
        Write-Host "         FIX: restart the Ollama app (not the model), then re-run this gate." -ForegroundColor Yellow
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
$cpuOnly = $noGpu -or ($rows.Count -gt 0 -and $failed -gt 0)

if (-not $cpuOnly) {
    Write-Host "RESULT: local inference is GPU-backed" -ForegroundColor Green
    exit 0
}

if ($WarnOnly) {
    # NOT "GPU-backed". -WarnOnly suppresses the exit code, not the finding: a gate
    # that answers "GPU-backed" while it has just detected CPU inference is the same
    # false-green this whole script exists to remove.
    Write-Host "RESULT: CPU-ONLY INFERENCE (exit softened by -WarnOnly, finding stands)" -ForegroundColor Yellow
    exit 0
}

Write-Host "RESULT: FAIL - local inference is not on the GPU" -ForegroundColor Red
exit 1
