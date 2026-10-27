# Pacgate-ai client installer
# Usage: .\install.ps1                (first install)
#        .\install.ps1 -Update         (refresh repo, pull new images, restart)
#        .\install.ps1 -Update -SkipRepoPull
#                                      (update images only; leave the repo alone)
#
# -Update refreshes the repo working tree first (fast-forward only), because
# much of the runtime is bind-mounted from the repo. See deploy/AIPC-UPDATE-GAP-ANALYSIS.md.

param(
    [switch]$Update,
    [switch]$SkipRepoPull
)

$ErrorActionPreference = "Stop"
$DataDir = ".\data"

# Resolve the PowerShell to run the two qm helper scripts with. pwsh 7 is
# PREFERRED (this dev box and the docs assume it), but a client AIPC is not
# guaranteed to have it and forcing an install just to stage qm was the wrong
# trade: all three scripts involved parse and run clean under built-in
# PowerShell 5.1 (verified with the language parser + the Out-File BOM fix in
# setup-qm.ps1). Fall back to whatever the host is already running.
#
# Get-Command pwsh also finds the WindowsApps ALIAS on a machine where PS7 is
# not actually installed; invoking that alias silently opens the Store. A
# version check cannot distinguish (a Store-installed PS7 reports 0.0.0.0
# through the alias), so the discriminator is the install shape itself: only a
# pwsh OUTSIDE WindowsApps is trusted; anything else falls back - and the
# fallback is verified-compatible, so a mis-detected PS7 costs nothing but the
# shell it would have used.
function Get-QmPowerShell {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*\WindowsApps\*' } |
        Select-Object -First 1
    if ($pwsh) { return 'pwsh' }
    return 'powershell'
}
$QmPowerShell = Get-QmPowerShell

# Resolve the residency tier for this machine from its OS-visible memory.
#
# WHY THIS EXISTS (measured 2026-10-20)
#   The two shipped hardware classes are documented as "128 GB dev box" vs
#   "32 GB AIPC", but what Ollama actually binds against is OS-VISIBLE system
#   memory, and on a unified-memory APU that is far below the DIMM total. The
#   Ryzen AI MAX+ 395 dev box reports 8 x 16 GiB DIMMs (128 GiB) but Windows
#   exposes only 31.65 GiB, because the iGPU's fixed UMA carve-out (96 GiB
#   dedicated, per the registry qwMemorySize key) is taken before the OS boots.
#   So the dev box and an HX370 land in the SAME residency bucket - which is
#   the opposite of what the hardware labels suggest, and the reason a
#   single hard-coded tier would ship wrong on one of them.
#
#   The scheduler's own log line records which limit bound:
#     msg="llama-server model predicted to exceed available memory, evicting"
#     predicted="6.2 GiB" available="6.0 GiB" gpu_free="100.6 GiB"
#     system_free="6.0 GiB" system_limited=true
#   On a 96 GiB iGPU with 13.4 GiB of models resident, VRAM was never the
#   constraint (gpu_free 100.6 GiB) - system memory was. Tiers are therefore
#   keyed on system memory, with a secondary VRAM consideration only for the
#   AIPC's discrete card.
function Get-OllamaResidencyProfile {
    $sysGiB = 0
    try {
        $sysGiB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 1)
    } catch { }

    # Discrete VRAM, via the registry key that is NOT truncated to 4 GiB the way
    # AdapterRAM is. A unified-memory iGPU reports an enormous value here (96 GiB
    # on the dev box) that is NOT usable for co-residency, so it is only ever
    # reported, never used to raise a limit.
    $vramGiB = 0
    try {
        $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            $raw = $p.'HardwareInformation.qwMemorySize'
            if ($raw -and [int64]$raw -gt 0) {
                $g = [math]::Round([int64]$raw / 1GB, 1)
                if ($g -lt 64) { $vramGiB = [math]::Max($vramGiB, $g) }   # ignore UMA carve-outs
            }
        }
    } catch { }

    if ($sysGiB -ge 56) {
        # Plenty of SYSTEM memory. Whether that translates into a big tier
        # depends on the GPU, because VRAM is what decides how many model
        # instances fit. A 64 GB host paired with a 16 GB card (a real
        # configuration - the second dev box) must NOT get the 3-model tier that
        # was earned by system memory alone: the third model would have nowhere
        # to live. Only a card with room for three resident models qualifies.
        if ($vramGiB -ge 24) {
            return [pscustomobject]@{
                Tier = 'high'; MaxLoaded = 3; ContextLength = 65536; NumParallel = 2
                CacheRamMiB = 4096; SystemGiB = $sysGiB
                MidTag = 'ornith-1.5:9b'; LowTag = 'gemma4:12b-it-qat'
            }
        }
        return [pscustomobject]@{
            Tier = 'big-ram-small-vram'; MaxLoaded = 2; ContextLength = 32768; NumParallel = 2
            # Generous host RAM, but a small card means the runner is the only
            # large consumer. 2 GiB of prompt cache is still ~30x one prompt.
            CacheRamMiB = 2048; SystemGiB = $sysGiB
            MidTag = 'ornith-1.5:9b'; LowTag = 'gemma4:12b-it-qat'
        }
    }
    if ($sysGiB -ge 24) {
        # AIPC HX370 and any unified-memory APU whose carve-out leaves ~32 GiB.
        # 32768 is chosen, not 16384, because deer-flow escalates local->local at
        # a 40000 message-token threshold; a 16k cap would make that escalation
        # structurally unreachable, while 32k is 80% of 40k so it still fires
        # just before the window is exhausted.
        # Measured residency at NUM_PARALLEL=2: gemma4 7.63 GB (flat 8k->64k,
        # it is QAT/weight-dominated), ornith-1.5:9b 6.12 GB, nomic 0.31 GB.
        return [pscustomobject]@{
            Tier = 'standard'; MaxLoaded = 2; ContextLength = 32768; NumParallel = 2
            CacheRamMiB = 1024; SystemGiB = $sysGiB
            MidTag = 'ornith-1.5:9b'; LowTag = 'gemma4:12b-it-qat'
        }
    }
    # Low-memory fallback: one resident model, minimum viable context.
    return [pscustomobject]@{
        Tier = 'constrained'; MaxLoaded = 1; ContextLength = 16384; NumParallel = 1
        CacheRamMiB = 512; SystemGiB = $sysGiB
        MidTag = 'ornith-1.5:9b'; LowTag = 'gemma4:12b-it-qat'
    }
}

# Run a native command that may write to stderr WITHOUT the Windows built-in
# PowerShell 5.1 turning that stderr into a terminating error.
#
# THE DEFECT THIS EXISTS FOR (measured on this box, not theorised):
#   This script sets $ErrorActionPreference = "Stop" (above). On PowerShell 5.1,
#   ANY native command that writes to stderr becomes a TERMINATING error when a
#   redirection is attached - `2>&1`, `2>$null` and `*>` are ALL affected.
#   `docker compose up -d` writes its progress ("Volume ... Creating",
#   "Container ... Running") to stderr on EVERY run, so the installer died at
#   the compose-up step with a NativeCommandError and never reached the tenant
#   or admin bootstrap. PowerShell 7 does not do this, which is why a dev box
#   running pwsh never saw it and a client AIPC running the built-in shell did.
#
#   try/catch does NOT help: the error is caught, but the remainder of the try
#   block is skipped and any assignment in flight is silently lost. Verified.
#
# WHAT THIS DOES: lowers the preference to "Continue" for the duration of the
#   scriptblock so stderr is non-terminating, then restores it. $LASTEXITCODE is
#   preserved across the boundary, so the explicit exit-code checks that follow
#   still work. A `2>$null` capture is byte-identical to PowerShell 7's.
#
# WHAT THIS DOES NOT DO: it does not make a `2>&1 | Out-String` capture match
#   PowerShell 7 - PS 5.1 still injects NativeCommandError decoration into that
#   text. That is why the capture sites below use `2>$null`, never `2>&1`.
function Invoke-WithNativeStderr {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Script } finally { $ErrorActionPreference = $previous }
}

# Invoke an HTTP request and report its status code and body WITHOUT relying on
# PowerShell 7-only parameters.
#
# THE DEFECT THIS EXISTS FOR (measured on this box, 2026-10-13, under the
# client's built-in shell):
#   `-SkipHttpErrorCheck` is a PowerShell 7 parameter. Windows PowerShell 5.1
#   does not have it, so the call raises ParameterBindingException BEFORE any
#   request leaves the machine:
#       "A parameter cannot be found that matches parameter name 'SkipHttpErrorCheck'."
#   The register call below sat inside `try { } catch { }` with nothing after it,
#   so on a client AIPC the failure was SILENT: the response stayed $null, all
#   15 retries failed identically, and the installer printed "could not register
#   the admin" - after which matter provisioning could not authenticate either,
#   so deer-flow fell back to unsanitized on-disk memory. On a pwsh 7 dev box the
#   same code worked, which is why it survived. Same class as the native-stderr
#   defect above: pwsh-7-only behaviour the client's shell does not have.
#
# A non-2xx response is returned as data rather than thrown. The body is read
# from $_.ErrorDetails.Message, which carries it on BOTH shells. The obvious
# alternatives do not: PS 5.1's HttpWebResponse stream reads EMPTY (PowerShell
# has already consumed it) and PS 7's HttpResponseMessage.Content is DISPOSED by
# the time the catch runs. Both measured on this box, 2026-10-13.
function Invoke-ApiRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = 'Get',
        [string]$Body,
        [int]$TimeoutSec = 20
    )
    $result = [pscustomobject]@{ Status = $null; Body = ''; Error = $null }
    try {
        $r = if ($Body) {
            Invoke-WebRequest -Uri $Uri -Method $Method -Body $Body `
                -ContentType 'application/json' -TimeoutSec $TimeoutSec -UseBasicParsing
        }
        else {
            Invoke-WebRequest -Uri $Uri -Method $Method -TimeoutSec $TimeoutSec -UseBasicParsing
        }
        $result.Status = [int]$r.StatusCode
        $result.Body = [string]$r.Content
    }
    catch {
        $wr = $_.Exception.Response
        if ($wr) { $result.Status = [int]$wr.StatusCode }
        $body = [string]$_.ErrorDetails.Message
        if ($body) { $result.Body = $body }
        if (-not $wr -and -not $body) { $result.Error = "$($_.Exception.Message)" }
    }
    return $result
}

Write-Host "=== Pacgate-ai Installer ===" -ForegroundColor Cyan

# Fingerprint the script that is actually executing.
#
# PowerShell parses this whole file before running any of it, so a later
# `install.ps1 -Update` still runs the OLD body even after step 3b replaces the
# file on disk. Recording what we are running lets step 3c detect that mismatch
# and hand off to the new script exactly once (see the comment there).
$script:PacgateInstallScriptHash = $null
try {
    $selfFile = $PSCommandPath
    if (-not $selfFile) { $selfFile = $MyInvocation.MyCommand.Path }
    if ($selfFile -and (Test-Path $selfFile)) {
        $script:PacgateInstallScriptHash = (Get-FileHash -Path $selfFile -Algorithm SHA256).Hash
        $env:PACGATE_INSTALL_SCRIPT_HASH = $script:PacgateInstallScriptHash
    }
} catch { }


# 1. Check Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Docker Desktop not found. Install from https://docs.docker.com/desktop/" -ForegroundColor Red
    exit 1
}
Invoke-WithNativeStderr { docker info *>$null }
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Docker daemon not running. Start Docker Desktop." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Docker detected" -ForegroundColor Green

# 2. Check Ollama
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Ollama not found. Install from https://ollama.com" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Ollama detected" -ForegroundColor Green

# 2b. Apply the model-residency profile for THIS machine.
#
# WHY THIS EXISTS (measured 2026-10-20)
#   Nothing in this bundle ever set an OLLAMA_* variable, so every deployment
#   ran on Ollama's defaults: OLLAMA_CONTEXT_LENGTH=0 (auto-picked from VRAM,
#   which resolves to the model's OWN maximum - 262144 for gemma4), and
#   OLLAMA_NUM_PARALLEL=1 (one server slot per model).
#
#   Both defaults are wrong on a 32 GiB-class machine, and the measurements are
#   not subtle:
#     - Same 9B model, 262144 ctx -> 14 GB resident; 8192 ctx -> 5.7 GB.
#       The KV cache alone was 8.3 GB of avoidable residency.
#     - Neither pacgate-api nor deer-flow ever sends num_ctx (deer-flow passes
#       only max_tokens/temperature; pacgate-llm posts to /v1/chat/completions,
#       whose body has no num_ctx field), so the auto value is what gets used.
#       OLLAMA_CONTEXT_LENGTH DOES apply to that endpoint - verified: context
#       went 262144 -> 16384 and residency 7.9 -> 7.6 GB.
#     - With NUM_PARALLEL=1, three concurrent utility calls ran strictly
#       serialised (1.63 s / 3.02 s / 4.32 s, 5.35 s wall). At NUM_PARALLEL=2-3
#       the same three finished in 2.88 s for ~1 GB more KV. That serialisation
#       is the "hangs with no generation" symptom: a title call, a memory
#       update and a summarizer can all queue behind the user's own chat on one
#       slot.
#
#   OLLAMA_MAX_LOADED_MODELS is NOT the primary lever and is deliberately not
#   set to 1: the scheduler's automatic default is already 3 per GPU, and the
#   binding limit is a memory-fit check (system_limited=true above), so forcing
#   1 only makes eviction unconditional. Verified: with MAX=1, loading gemma4
#   (7.6 GB) evicted a resident ornith (5.6 GB) even with 100 GiB of GPU memory
#   free; with MAX=2/3 the same pair co-resides when system memory allows.
#
# These are USER-level environment variables because Ollama's Windows installer
# runs as a normal user process (not a service), so HKCU is what it reads.
# Writes are idempotent and only touch OLLAMA_* names.
# Ollama is SHARED infrastructure: it serves VS Code / Copilot and anything else
# the operator points at it. Pacgate therefore REPORTS the residency settings and
# never writes them.
#
# WHY THE WRITES WERE REMOVED (2026-10-22)
#   This function used to persist five values as User-scope environment variables
#   and then restart the server so it would pick them up. Two things were wrong:
#
#   1. User scope is not local. Every Ollama server the operator starts inherits
#      those variables, so "Pacgate's own models get 32768" was never true - the
#      whole machine got 32768, including the server VS Code / Copilot uses.
#   2. The restart was destructive. It killed the running server, which dropped
#      live client sessions; the Copilot provider's ephemeral port never came
#      back and the operator saw "Could not connect to local model provider".
#
#   The values are still computed, because they are what the operator needs when
#   sizing a machine and what the docs quote. They are printed as a
#   recommendation, not applied.
function Get-OllamaResidencyReport {
    param([Parameter(Mandatory)] $Profile)

    $recommended = @(
        @{ Name = 'OLLAMA_MAX_LOADED_MODELS'; Value = [string]$Profile.MaxLoaded }
        @{ Name = 'OLLAMA_CONTEXT_LENGTH';    Value = [string]$Profile.ContextLength }
        @{ Name = 'OLLAMA_NUM_PARALLEL';      Value = [string]$Profile.NumParallel }
        # 15m keeps the utility tag warm across a normal working gap without
        # pinning memory forever. The cloud main model costs 0 GB local.
        @{ Name = 'OLLAMA_KEEP_ALIVE';        Value = '15m' }

        # Pacgate 2026-10-21: cap llama.cpp's PROMPT CACHE, which is HOST RAM and
        # grows independently of the model and of VRAM.
        #
        # WHY (measured on the HX370 box, Ollama 0.40.6 / llama-server build 620d2225c)
        #   llama.cpp keeps a cache of whole prompt states so a follow-up call can
        #   skip re-processing its prefix. Its default budget is 8192 MiB, and the
        #   observed footprint was ~6.5 GiB of the host's 61.6 GiB:
        #
        #     cache state: 4 prompts, 6506.381 MiB (limits: 8192.000 MiB, ...)
        #     prompt 0000020EF62A9EF0: 5097 tokens, checkpoints: 7, 1927.274 MiB
        #
        #   Each saved prompt costs roughly its context in KV bytes plus ~240 KiB
        #   per checkpoint (7 cp x 320 MiB for a 5097-token prompt). On a machine
        #   already sitting at 0.03 MB available memory during a workflow, that is
        #   the difference between paging and not.
        #
        #   The cache is also NOT earning its keep on these models. gemma4 is a
        #   sliding-window hybrid (`is_swa_any = 1`), and llama.cpp itself reports:
        #     forcing full prompt re-processing due to lack of cache data
        #     (likely due to SWA or hybrid/recurrent memory ...)
        #   Measured reuse over a full day: 22.8% of requested prompt tokens were
        #   skipped, and 48.5% of prefill events got ZERO reuse. Capping the cache
        #   therefore costs little on the hit rate while returning gigabytes.
        #
        # HOW AN OPERATOR APPLIES IT: Ollama spawns llama-server as a child
        # process, so the variable has to be in the environment of the server
        # process. Pacgate does not set it - that would be machine-wide. To apply
        # it, start a second `ollama serve` on its own port with the variable
        # scoped to that process, and point Pacgate at that port.
        # VERIFIED end to end on this box: with LLAMA_ARG_CACHE_RAM=512 the runner's
        # own log switched from the 8192 default to
        #     cache state: 1 prompts, 20.457 MiB (limits: 512.000 MiB, 8192 tokens, ...)
        # so the value really does bind. A bad value is loud rather than silent
        # (llama-server exits with `error while handling environment variable ...`).
        #
        # Sizing: 512 MiB is still ~30x a short title/memory prompt, 1024 MiB covers
        # several 8k utility prompts - which is the actual traffic on these lanes.
        @{ Name = 'LLAMA_ARG_CACHE_RAM';      Value = [string]$Profile.CacheRamMiB }
    )

    $rows = @()
    foreach ($item in $recommended) {
        $rows += [pscustomobject]@{
            Name        = $item.Name
            Recommended = $item.Value
            Effective   = [Environment]::GetEnvironmentVariable($item.Name, 'User')
        }
    }
    return $rows
}

# The Ollama DESKTOP APP stores a machine-wide `context_length` in
# %LOCALAPPDATA%\Ollama\db.sqlite (`settings` table) and passes it to the server
# it spawns, where it OVERRIDES OLLAMA_CONTEXT_LENGTH.
#
# WE DELIBERATELY DO NOT TOUCH THAT VALUE. Ollama is shared infrastructure on
# these machines - other tools use the same server and expect the operator's own
# context setting. Rewriting a global preference to suit one consumer is the
# wrong fix even though it works, so the app's value is only ever READ and
# reported. Context for Pacgate's own models comes from OLLAMA_CONTEXT_LENGTH,
# which is scoped to the Ollama process this installer configures.
#
# Measured, so the read is not academic: with env=32768 and db=131072 the server
# starts at 131072, and with both at 32768 it starts at 32768. The env var alone
# is a no-op on any machine where the app has been run.
function Get-OllamaAppContextLength {
    $info = [pscustomobject]@{ Path = $null; Value = $null; Status = 'not-applicable'; Detail = '' }

    $db = Join-Path $env:LOCALAPPDATA 'Ollama\db.sqlite'
    if (-not (Test-Path $db)) {
        $info.Detail = 'no app database (OLLAMA_CONTEXT_LENGTH is authoritative)'
        return $info
    }
    $info.Path = $db

    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        $info.Status = 'unknown'
        $info.Detail = 'python not found; cannot read the app setting'
        return $info
    }

    $readScript = @'
import sqlite3, os
p = os.path.join(os.environ["LOCALAPPDATA"], "Ollama", "db.sqlite")
try:
    con = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
    r = con.execute("select context_length from settings where id=1").fetchone()
    print(r[0] if r else "")
    con.close()
except Exception as e:
    print("ERR:%s" % e)
'@
    try {
        # 2>$null (not 2>&1): PS 5.1 injects NativeCommandError decoration on
        # `2>&1` even inside the helper, so that form is banned repo-wide. We only
        # need stdout here - a failure yields an unusable value, reported as
        # 'unknown' rather than silently mistaken for a number.
        $out = (Invoke-WithNativeStderr { $readScript | & $py.Source - 2>$null } | Out-String).Trim()
    } catch {
        $out = "ERR:$_"
    }

    if ($out -match '^\d+$') {
        $info.Value = [int]$out
        $info.Status = 'read'
    } else {
        $info.Status = 'unknown'
        $info.Detail = $out
    }
    return $info
}

# Read (never write) the app's machine-wide context_length. Ollama is shared
# infrastructure here, so this value is reported and respected, not overridden.
$residency = Get-OllamaResidencyProfile
$residencyRows = @()
try {
    $residencyRows = @(Get-OllamaResidencyReport -Profile $residency)
} catch {
    Write-Host "[WARN] Could not compute the Ollama residency recommendation: $_" -ForegroundColor Yellow
}

$appCtx = $null
try {
    $appCtx = Get-OllamaAppContextLength
} catch {
    $appCtx = [pscustomobject]@{ Path = $null; Value = $null; Status = 'unknown'; Detail = "$_" }
}

Write-Host "[OK] Ollama residency profile '$($residency.Tier)' (recommendation only - not applied)" -ForegroundColor Green
foreach ($row in $residencyRows) {
    $have = if ($row.Effective) { $row.Effective } else { '<unset>' }
    $mark = if ($row.Effective -eq $row.Recommended) { '=' } else { '->' }
    Write-Host ("     {0,-26} {1} {2}   (recommended {3})" -f $row.Name, $have, $mark, $row.Recommended) -ForegroundColor DarkGray
}
Write-Host "     Ollama is shared with other tools, so Pacgate does not change these." -ForegroundColor DarkGray
Write-Host "     To apply them, start a second 'ollama serve' on its own port with the" -ForegroundColor DarkGray
Write-Host "     variables scoped to that process, and point Pacgate at that port." -ForegroundColor DarkGray

switch ($appCtx.Status) {
    'read' {
        if ($appCtx.Value -eq [int]$residency.ContextLength) {
            Write-Host "[OK] Ollama app context_length is already $($appCtx.Value)" -ForegroundColor Green
        } else {
            Write-Host "[NOTE] Ollama app context_length is $($appCtx.Value) (machine-wide, shared with other tools)." -ForegroundColor DarkGray
            Write-Host "       Pacgate does not change it. The tier recommendation is $($residency.ContextLength)," -ForegroundColor DarkGray
            Write-Host "       but the app setting wins, so $($appCtx.Value) is what models actually load at." -ForegroundColor DarkGray
        }
    }
    'not-applicable' { Write-Host "[OK] No Ollama app database ($($appCtx.Detail))" -ForegroundColor DarkGray }
    default { Write-Host "[NOTE] Could not read the Ollama app context_length ($($appCtx.Detail)); proceeding." -ForegroundColor DarkGray }
}

# ── Model selection: the operator picks, the installer only reports ─────────
#
# WHY THE DERIVED-TAG MECHANISM WAS REMOVED (2026-10-21)
#   The installer used to run `ollama create` to build `pacgate-mid` / `pacgate-low`
#   tags with `PARAMETER num_ctx` baked in, then write those names into .env. It
#   worked, but it was the wrong shape for a shipped product:
#
#   1. Those tags exist only on a machine where this installer ran. They are in
#      neither origin/main nor any ghcr image, so they cannot be pre-pulled and
#      cannot be a repo default. Every deployment therefore diverged from the
#      published artifact in a way nothing else could reproduce.
#
#   2. It created a SECOND name for the same weights. Ollama keys residency by tag
#      name, so `pacgate-low` and `gemma4:12b-it-qat` (identical blobs, verified via
#      `ollama show --modelfile`) could not co-reside. Measured on the HX370 box:
#      switching between them cost 15.9 s and 15.4 s of reload, and the day's log
#      held 56 llama-server starts, 55 model loads and 13 evictions. That churn was
#      the single largest latency source, and it was self-inflicted.
#
#   3. It assumed one fixed context per tier. A machine with more VRAM should be
#      able to run a wider window, and a machine with less should be able to run a
#      narrower one, without the installer having decided in advance.
#
#   So the model roster is now exactly what the operator selects from the standard
#   Ollama tags that `ollama-models.txt` pre-pulls. Context is whatever the
#   operator's own Ollama server is configured for - Pacgate reports the tier's
#   recommendation and does not apply it, which keeps ONE name per weight set and
#   lets the scheduler keep it warm.
#
#   CAVEAT, measured: the Ollama desktop app's db.sqlite `context_length` OVERRIDES
#   OLLAMA_CONTEXT_LENGTH. On the HX370 box the tier says 32768 but `ollama ps`
#   reports 65536, because the app's value wins. That is the operator's setting and
#   is deliberately not touched - but it means the tier's ContextLength is a
#   REQUEST, not a guarantee, and nothing should budget VRAM from it without
#   reading the effective value back.
#
# WHAT THIS FUNCTION DOES
#   Reports what is installed and what the tier suggests, and writes nothing. The
#   operator's choice lives in .env (PACGATE_MODEL_MAIN/MID/LOW) and in the
#   deer-flow picker; both already accept any installed tag.
function Get-ModelSelectionReport {
    param([Parameter(Mandatory)] $Profile)

    $report = [pscustomobject]@{
        Installed = @()
        Suggested = [ordered]@{}
        Missing   = @()
    }
    try {
        $out = (Invoke-WithNativeStderr { & ollama list 2>$null } | Out-String)
        $report.Installed = @(
            ($out -split "`r?`n") | Select-Object -Skip 1 |
                ForEach-Object { ($_ -split '\s+')[0] } |
                Where-Object { $_ -and $_ -notmatch '^NAME$' }
        )
    } catch { }

    # The tier's suggestion is a STARTING POINT, not a pin. Both are standard tags
    # from ollama-models.txt, so they are pullable on any machine.
    $report.Suggested['PACGATE_MODEL_MID'] = $Profile.MidTag
    $report.Suggested['PACGATE_MODEL_LOW'] = $Profile.LowTag
    foreach ($k in $report.Suggested.Keys) {
        $tag = $report.Suggested[$k]
        if ($report.Installed -notcontains $tag) { $report.Missing += $tag }
    }
    return $report
}

$modelReport = $null
try { $modelReport = Get-ModelSelectionReport -Profile $residency } catch { }

if ($modelReport) {
    Write-Host "[OK] Model selection is the operator's: standard Ollama tags, no derived tags" -ForegroundColor Green
    foreach ($k in $modelReport.Suggested.Keys) {
        $tag = $modelReport.Suggested[$k]
        $state = if ($modelReport.Installed -contains $tag) { 'installed' } else { 'NOT installed' }
        Write-Host ("     {0,-20} {1,-28} {2}" -f $k, $tag, $state) -ForegroundColor DarkGray
    }
    if ($modelReport.Missing.Count -gt 0) {
        Write-Host "     Missing tags are pulled by this installer; if one is still absent, run:" -ForegroundColor Yellow
        Write-Host "       ollama pull <tag>" -ForegroundColor Yellow
    }
    Write-Host "     To use a different local model, set PACGATE_MODEL_MID/LOW in .env to any" -ForegroundColor DarkGray
    Write-Host "     installed tag, or pick it in the deer-flow model picker." -ForegroundColor DarkGray
    # Do NOT claim the tier's ContextLength is what the model will load at. The
    # Ollama desktop app's db.sqlite value OVERRIDES OLLAMA_CONTEXT_LENGTH, and on
    # this box it is 65536 while the tier says 32768 - verified with `ollama ps`.
    # Reporting the tier value as fact is how a capacity budget stops matching
    # reality, so the effective value is read back instead.
    $effectiveCtx = if ($appCtx -and $appCtx.Status -eq 'read') { $appCtx.Value } else { $null }
    if ($effectiveCtx) {
        Write-Host "     Effective context is $effectiveCtx (from the Ollama app setting, which wins" -ForegroundColor DarkGray
        Write-Host "     over any OLLAMA_CONTEXT_LENGTH). Change it in the Ollama app if needed." -ForegroundColor DarkGray
    } else {
        Write-Host "     Context is whatever your Ollama server is configured for. The tier" -ForegroundColor DarkGray
        Write-Host "     recommendation is $($residency.ContextLength); Pacgate does not apply it." -ForegroundColor DarkGray
    }
}

# The residency values above are a RECOMMENDATION and are deliberately not
# applied. Ollama is shared with VS Code / Copilot and anything else the operator
# points at it, so Pacgate neither writes its environment nor restarts it. An
# operator who wants the recommendation applied starts a second `ollama serve` on
# its own port with the variables scoped to that process.

# 3. Check .env
if (-not (Test-Path .env)) {
    if (Test-Path .env.example) {
        Write-Host "ERROR: .env not found. Copy .env.example to .env and fill in passwords." -ForegroundColor Red
        Write-Host "  copy .env.example .env" -ForegroundColor Yellow
        Write-Host "  # then edit .env with your values" -ForegroundColor Yellow
        exit 1
    }
}

# 3b. Refresh the repo working tree (updates only).
#
# WHY THIS EXISTS
#   This script lives at <repo>\deploy\client-bundle, and much of the runtime is
#   bind-mounted straight from the repo: compose image pins, workflows/*.yaml,
#   patches/*.py, nginx/default.conf, and the config templates. Pulling images
#   alone does NOT deliver any of those. Previously the operator had to
#   remember a separate `git pull` first - the single most easily forgotten step
#   in the update path, and when forgotten the machine silently keeps running old
#   config against new images. See deploy/AIPC-UPDATE-GAP-ANALYSIS.md.
#
# SAFETY RULES (this touches a client machine):
#   - NEVER proceed with local changes to TRACKED files. Refuse and name them.
#     No auto-stash, no reset, no checkout -- all would discard someone's work.
#   - Untracked files are NOT a reason to block the refresh: git fast-forwards
#     over them. The ONE exception is a name collision, where the incoming
#     commit adds a path that is untracked here - git refuses that itself, and
#     this script pre-checks it so the operator gets an actionable message.
#   - Fast-forward only. Never create a merge commit on a client machine.
#   - Missing git, or a non-git checkout (tarball install), is a WARNING not a
#     failure - the rest of the update still works.
#
# Runs BEFORE the config renders below, so they render from the newly pulled
# templates rather than the stale ones.
if ($Update -and -not $SkipRepoPull) {
    Write-Host "`nRefreshing repo working tree..." -ForegroundColor Cyan

    # $PSScriptRoot = <repo>\deploy\client-bundle  ->  repo root is two levels up
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "[WARN] git not found - cannot refresh the repo." -ForegroundColor Yellow
        Write-Host "  Only Docker images will be updated. If this machine needs config," -ForegroundColor Yellow
        Write-Host "  workflow, or patch changes, install Git and re-run." -ForegroundColor Yellow
    }
    elseif (-not (Test-Path (Join-Path $repoRoot '.git'))) {
        Write-Host "[WARN] $repoRoot is not a git checkout - cannot refresh." -ForegroundColor Yellow
        Write-Host "  Only Docker images will be updated." -ForegroundColor Yellow
    }
    else {
        Push-Location $repoRoot
        try {
            # A dirty tree means someone edited TRACKED files. Do NOT touch it.
            #
            # TRACKED AND UNTRACKED ARE DIFFERENT RISKS, and treating them the
            # same was a real defect in the update path:
            #
            #   tracked changes   - the pull would have to merge over someone's
            #                       edits. Refuse. Never auto-stash.
            #   untracked files   - git will fast-forward happily UNLESS the
            #                       incoming commit adds a path of the same name,
            #                       in which case git refuses by itself (see
            #                       below). A scratch file is not a reason to
            #                       block the whole repo refresh.
            #
            # The old guard was a bare `git status --porcelain`, so ONE leftover
            # scratch file made every update print "skipping the repo update" and
            # move only the images. That is a silent lost update: image tags
            # advance, workflows/patches/nginx.conf silently stay old, and
            # nothing surfaces the gap. The dev box for this project hit exactly
            # that state (2 untracked files, repo refresh skipped), which is how
            # this was found.
            #
            # `--untracked-files=no` is what narrows the check to tracked state.
            $dirty = @(git status --porcelain --untracked-files=no)
            if ($dirty.Count -gt 0) {
                Write-Host "[WARN] Repo has local changes to tracked files - skipping the repo update." -ForegroundColor Yellow
                Write-Host "  Not modifying anything, because that could discard work. Changed files:" -ForegroundColor Yellow
                $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
                if ($dirty.Count -gt 10) {
                    Write-Host "    ... and $($dirty.Count - 10) more" -ForegroundColor DarkYellow
                }
                Write-Host "  Resolve them (commit, or restore) and re-run to pick up repo updates." -ForegroundColor Yellow

                # Say what this actually costs. A skipped repo refresh does NOT stop
                # the rest of -Update: `compose pull` still runs and step 7c still
                # restarts deer-flow, so the install finishes green and reports
                # success while the bind-mounted code is still the OLD code. There
                # is no error to notice - the machine simply keeps behaving like the
                # previous release. Measured 2026-10-27 on a clone with one edited
                # tracked file: the update reported success and the loop-guard patch
                # was never applied.
                $behindRef = $null
                try {
                    Invoke-WithNativeStderr { git fetch --quiet origin 2>$null }
                    if ($LASTEXITCODE -eq 0) {
                        $remoteHead = (git rev-parse "origin/$((git rev-parse --abbrev-ref HEAD).Trim())" 2>$null | Out-String).Trim()
                        $localHead = (git rev-parse HEAD).Trim()
                        if ($remoteHead -and $remoteHead -ne $localHead) { $behindRef = $remoteHead.Substring(0, 7) }
                    }
                }
                catch { }
                $cur = ((git rev-parse HEAD 2>$null | Out-String).Trim())
                if ($cur) { $cur = $cur.Substring(0, 7) }
                Write-Host ""
                Write-Host "  CONSEQUENCE - this machine is running the OLD repo code, not the new release:" -ForegroundColor Yellow
                Write-Host "    - bind-mounted patches and configs (deer-flow patches/*.py, deer-flow-config.yaml)" -ForegroundColor Yellow
                Write-Host "      stay at their current contents, so any fix that ships by bind-mount is NOT applied" -ForegroundColor Yellow
                Write-Host "    - the images below still update, so image-tag fixes DO apply" -ForegroundColor Yellow
                if ($cur) { Write-Host "    - repo is at $cur$(if ($behindRef) { ", and origin has $behindRef" })" -ForegroundColor Yellow }
                Write-Host "  Fix: git stash (or commit) the listed files, then re-run .\install.ps1 -Update." -ForegroundColor Yellow
                Write-Host "" -ForegroundColor Yellow
            }
            else {
                $before = (git rev-parse HEAD).Trim()

                # Fetch first so we can decide without merging.
                Invoke-WithNativeStderr { git fetch --quiet origin 2>$null }
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[WARN] git fetch failed (offline?) - continuing with the current checkout." -ForegroundColor Yellow
                }
                else {
                    $branch = (git rev-parse --abbrev-ref HEAD).Trim()

                    # A DETACHED HEAD is not a branch. `git rev-parse --abbrev-ref
                    # HEAD` reports the literal string "HEAD" there, which made
                    # $remoteRef "origin/HEAD" and $branch "HEAD" - and
                    # `git pull --ff-only origin HEAD` then fast-forwarded the
                    # detached checkout onto whatever origin/HEAD points at.
                    #
                    # MEASURED 2026-10-20: on a `git checkout v0.1.33` tree (the
                    # documented rollback), that pull moved HEAD from 9af44db to
                    # 3b235ed - it silently UNDID the rollback and carried on with
                    # main. A rollback that quietly un-rolls itself is worse than
                    # no rollback, because the operator believes it worked.
                    #
                    # A detached checkout is a deliberate pin. Never move it.
                    if ($branch -eq 'HEAD') {
                        $described = ''
                        try {
                            $described = (Invoke-WithNativeStderr { git describe --tags --exact-match HEAD 2>$null } | Out-String).Trim()
                        } catch { }
                        $where = if ($described) { $described } else { $before.Substring(0,7) }
                        Write-Host "[OK] Repo is pinned at $where (detached) - leaving it alone." -ForegroundColor Green
                        Write-Host "     Images still update below. To follow a branch instead: git checkout main" -ForegroundColor DarkGray
                        $branch = $null
                    }
                }

                if ($branch) {
                    $remoteRef = "origin/$branch"

                    $behind = 0
                    $counts = Invoke-WithNativeStderr { git rev-list --left-right --count "$remoteRef...$branch" 2>$null }
                    if ($LASTEXITCODE -eq 0 -and $counts) {
                        $behind = [int](($counts -split '\s+')[0])
                    }

                    if ($behind -eq 0) {
                        Write-Host "[OK] Repo already current at $($before.Substring(0,7))" -ForegroundColor Green
                    }
                    else {
                        # ── Untracked-file collision pre-check ──────────────────
                        # Do not let git abort mid-pull. Detect the one untracked
                        # case that genuinely cannot proceed, name those files,
                        # and skip the repo refresh - so the operator gets an
                        # actionable message instead of a git error.
                        #
                        # ONLY a genuine collision blocks. An untracked file that
                        # the incoming commit does NOT touch is left alone: git
                        # fast-forwards over it, and refusing would re-create the
                        # silent-lost-update defect described above.
                        #
                        # Detection is by PATH COMPARISON, not by matching git's
                        # error text. The message ("would be overwritten by
                        # merge") is localized and unstable across git versions,
                        # so parsing it is a trap; the file lists are not.
                        #
                        # -c core.quotepath=false is required: without it git
                        # C-quotes non-ASCII paths ("\346\263\225...") and the
                        # comparison against the real name silently fails. This
                        # repo contains Chinese-named files, so that is not
                        # hypothetical. ls-files is used instead of status
                        # because status COLLAPSES whole untracked directories to
                        # "dir/" and the names would never match.
                        $untracked = Invoke-WithNativeStderr { @(git -c core.quotepath=false ls-files --others --exclude-standard 2>$null | Where-Object { $_ }) }
                        $collisions = @()
                        if ($untracked.Count -gt 0) {
                            $incoming = Invoke-WithNativeStderr { @(git -c core.quotepath=false diff --name-only --diff-filter=A "$before" "$remoteRef" 2>$null | Where-Object { $_ }) }
                            $collisions = @($untracked | Where-Object { $incoming -contains $_ })
                        }

                        if ($collisions.Count -gt 0) {
                            Write-Host "[WARN] Cannot refresh the repo: $($collisions.Count) untracked file(s) would be overwritten." -ForegroundColor Yellow
                            Write-Host "  The incoming update adds files with the same names. Git will not" -ForegroundColor Yellow
                            Write-Host "  destroy untracked work, and neither will this installer. Files:" -ForegroundColor Yellow
                            $collisions | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
                            if ($collisions.Count -gt 10) {
                                Write-Host "    ... and $($collisions.Count - 10) more" -ForegroundColor DarkYellow
                            }
                            Write-Host "  Move, rename, or commit them, then re-run to pick up repo updates." -ForegroundColor Yellow
                            Write-Host "  Only Docker images are being updated in the meantime." -ForegroundColor Yellow
                        }
                        else {
                            # Report the untracked files that are being KEPT, so
                            # proceeding is never silent - the same principle as
                            # naming the changed files below.
                            if ($untracked.Count -gt 0) {
                                Write-Host "[OK] $($untracked.Count) untracked file(s) present; none are touched by this update." -ForegroundColor Green
                            }

                            # --ff-only: refuse rather than create a merge commit. If
                            # the local branch has diverged (commits made on the
                            # machine), this fails loudly instead of quietly
                            # rewriting history under the operator.
                            git pull --ff-only --quiet origin $branch
                            if ($LASTEXITCODE -ne 0) {
                                Write-Host "[WARN] Repo has diverged from $remoteRef - not fast-forwardable." -ForegroundColor Yellow
                                Write-Host "  Local commits exist that the remote does not have. Not merging." -ForegroundColor Yellow
                                Write-Host "  The rest of the update continues; repo content stays as-is." -ForegroundColor Yellow
                            }
                            else {
                                $after = (git rev-parse HEAD).Trim()
                                Write-Host "[OK] Repo updated $($before.Substring(0,7)) -> $($after.Substring(0,7)) ($behind commit(s))" -ForegroundColor Green

                                # Name what changed, so an update is never silent. This
                                # is the same principle as the config render below.
                                $changed = Invoke-WithNativeStderr { git diff --name-only "$before" "$after" 2>$null }
                                if ($changed) {
                                    Write-Host "     Files changed in this update:" -ForegroundColor DarkGray
                                    $changed | Select-Object -First 12 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
                                    if (@($changed).Count -gt 12) {
                                        Write-Host "       ... and $((@($changed).Count) - 12) more" -ForegroundColor DarkGray
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        finally {
            Pop-Location
        }
    }
}

# 3c. Self-update handoff: this file is now STALE.
#
# WHY THIS EXISTS (found 2026-10-20)
#   PowerShell reads and parses the WHOLE script before executing line 1, so
#   everything above ran from the OLD install.ps1, while the repo refresh at 3b
#   has already replaced this file on disk. Nothing before step 3b re-runs.
#
#   That made every install-logic fix a NON-DELIVERABLE: a machine that ran
#   `install.ps1 -Update` executed the previous version's early steps, and the
#   operator would have to run the script a SECOND time by hand to get them.
#   Concretely, the Ollama residency step (2b) shipped in the same commit as
#   this handoff would have been skipped on the very update that introduced it.
#
#   The refresh only fast-forwards a clean tree, so a stale script and a new
#   script cannot both legitimately be running; and the handoff is keyed to a
#   content hash, so it fires exactly once per changed script and cannot loop.
if ($Update -and -not $SkipRepoPull) {
    $selfPath = $PSCommandPath
    if (-not $selfPath) { $selfPath = $MyInvocation.MyCommand.Path }
    if ($selfPath -and (Test-Path $selfPath)) {
        $selfHash = (Get-FileHash -Path $selfPath -Algorithm SHA256).Hash
        $ranHash = $env:PACGATE_INSTALL_SCRIPT_HASH
        if ($ranHash -and $ranHash -ne $selfHash) {
            Write-Host ""
            Write-Host "[NOTICE] installer changed in this update - handing off to the new version." -ForegroundColor Cyan
            Write-Host "         Steps before the repo refresh ran from the previous script;" -ForegroundColor DarkGray
            Write-Host "         re-running now so the new steps actually take effect." -ForegroundColor DarkGray
            $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $selfPath, '-Update')
            if ($SkipRepoPull) { $childArgs += '-SkipRepoPull' }
            $env:PACGATE_INSTALL_SCRIPT_HASH = $selfHash
            & $QmPowerShell @childArgs
            exit $LASTEXITCODE
        }
        $env:PACGATE_INSTALL_SCRIPT_HASH = $selfHash
    }
}

# 4. Create data directories
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    Write-Host "[OK] Created $DataDir" -ForegroundColor Green
}
$OvDir = ".\openviking"
if (-not (Test-Path $OvDir)) {
    New-Item -ItemType Directory -Path $OvDir -Force | Out-Null
    Write-Host "[OK] Created $OvDir" -ForegroundColor Green
}

# 4b. Load .env values.
#
# Parsed ONCE here, outside the per-template guards below. It previously lived
# inside the OpenViking guard, which meant a missing `openviking/ov.conf.template`
# also silently skipped the UNRELATED deer-flow extensions render. Two renders,
# two guards.
$envPath = ".\.env"
$envVars = @{}
if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $envVars[$Matches[1]] = $Matches[2]
        }
    }
}

# 4b-i. Render OpenViking config (OPENVIKING_CONF_CONTENT) from template + secrets
#
# RENDER-AND-COMPARE, not render-if-absent.
#
# This block previously rendered ONLY when the key was missing from .env:
#
#     $needsRender = -not (Test-Path env:OPENVIKING_CONF_CONTENT) -and
#         (-not ($envVars.ContainsKey('OPENVIKING_CONF_CONTENT') -and ...))
#
# Once .env carried the key, that guard was false forever and the template was
# never read again. Verified on this box 2026-10-17: `OPENVIKING_CONF_CONTENT=` IS
# present in .env, so the guard skips and the template has not been re-rendered
# since. Commit e180fc8 changed the template's VLM from `gemma4:12b-it-q8_0` (13 GB)
# to `gemma4:12b-it-qat` (7.2 GB) on 2026-09-21 - and every machine that had already
# rendered kept q8_0, silently, across every subsequent -Update.
#
# This is the IDENTICAL defect the extensions config below was fixed for
# (see deploy/AIPC-UPDATE-GAP-ANALYSIS.md 3a). That path was converted to
# render-and-compare; this one was left behind.
#
# The container reads OPENVIKING_CONF_CONTENT from its ENVIRONMENT (verified:
# `docker exec openviking` sees the var), so .env is the authoritative source and
# this is the right place to fix it. openviking/ov.conf on the host is
# container-generated state and is deliberately left alone.
$ovTemplate = ".\openviking\ov.conf.template"
if ((Test-Path $envPath) -and (Test-Path $ovTemplate)) {
    $ovKey = $envVars['OPENVIKING_ROOT_API_KEY']
    if (-not $ovKey -or $ovKey -match '^change-me') {
        # Cannot render without a usable key. Preserve the previous lenient
        # behaviour (do not fail an otherwise-good install) but SAY so, because a
        # silent skip is what hid this class of drift.
        Write-Host "[WARN] OPENVIKING_ROOT_API_KEY is unset or still 'change-me' - not re-rendering OPENVIKING_CONF_CONTENT." -ForegroundColor Yellow
    } else {
        # -Encoding UTF8: PS 5.1 on a Chinese-locale host decodes BOM-less files as
        # ANSI/GBK; the template carries Chinese text and must stay UTF-8.
        $conf = Get-Content $ovTemplate -Raw -Encoding UTF8
        $conf = $conf.Replace('${OPENVIKING_ROOT_API_KEY}', $ovKey)
        $minified = ($conf -replace '(?m)^\s*//.*$', '' -replace '\r?\n', '' -replace '\s{2,}', ' ')

        $ovExisting = if ($envVars.ContainsKey('OPENVIKING_CONF_CONTENT')) { $envVars['OPENVIKING_CONF_CONTENT'] } else { '' }
        # Compare minified-to-minified so a whitespace-only difference does not look
        # like a change and churn the file on every run.
        $ovUnchanged = ($null -ne $ovExisting) -and ($ovExisting.Trim() -eq $minified.Trim())

        if ($ovUnchanged) {
            Write-Host "[OK] OPENVIKING_CONF_CONTENT already current" -ForegroundColor Green
        } else {
            # Rewrite IN PLACE: preserve every other line, including comments and
            # secrets. Appending here would leave the stale line above the new one,
            # and docker compose's last-one-wins behaviour would make that "work"
            # while the file silently accumulated a stale copy on every update.
            $ovLines = Get-Content $envPath
            $ovFound = $false
            $ovOut = foreach ($line in $ovLines) {
                if ($line -match '^\s*OPENVIKING_CONF_CONTENT\s*=') {
                    $ovFound = $true
                    "OPENVIKING_CONF_CONTENT=$minified"
                } else { $line }
            }
            if (-not $ovFound) {
                # Append with an explicit leading newline: PowerShell 5.1's Add-Content
                # glues the new line onto the last line when .env has no trailing
                # newline, fusing e.g. OPENVIKING_API_KEY=<val> with
                # OPENVIKING_CONF_CONTENT=<json> on one line (corrupting both).
                $rawEnv = [System.IO.File]::ReadAllText((Resolve-Path $envPath))
                $prefix = if ($rawEnv.Length -eq 0 -or $rawEnv.EndsWith("`n")) { '' } else { "`r`n" }
                $ovOut = @($ovLines)
                $ovOut += "$prefix" + "OPENVIKING_CONF_CONTENT=$minified"
            }
            # No BOM: docker compose chokes on a BOM in .env, and Set-Content adds one
            # by default on Windows PowerShell.
            #
            # Resolve to an ABSOLUTE path first. `$envPath` is ".\\.env", and .NET's
            # current directory does NOT follow PowerShell's Set-Location - so a
            # relative path here can silently write somewhere other than the
            # directory this script believes it is in. The original AppendAllText
            # called Resolve-Path for exactly this reason; keep that property.
            [System.IO.File]::WriteAllLines((Resolve-Path $envPath), $ovOut, [System.Text.UTF8Encoding]::new($false))
            Write-Host "[OK] Rendered OPENVIKING_CONF_CONTENT from template (it was stale)" -ForegroundColor Green

            # Name what changed. The silent version of this is what let q8_0 survive
            # the qat rename, and the VLM is the one lane whose staleness is invisible
            # at runtime - extraction still works, just on a 13 GB model instead of 7.2.
            $ovModels = @{}
            foreach ($ovM in [regex]::Matches($minified, '"model":\s*"([^"]+)"')) {
                $ovModels[$ovM.Groups[1].Value] = $true
            }
            foreach ($ovName in @('gemma4:12b-it-q8_0', 'gemma4:12b-it-qat')) {
                if ($ovModels.ContainsKey($ovName)) {
                    Write-Host "     OpenViking VLM now: $ovName" -ForegroundColor Yellow
                }
            }
            if ($minified -match '"model":\s*"gemma4:12b-it-q8_0"') {
                Write-Host "     NOTE: the template still names q8_0 (13 GB). qat is 7.2 GB and shares one resident model with the other utility lanes." -ForegroundColor Yellow
            }

            # Same-run visibility: docker compose reads ${OPENVIKING_CONF_CONTENT}
            # from the process environment, so this avoids needing a second run.
            $envVars['OPENVIKING_CONF_CONTENT'] = $minified
            $env:OPENVIKING_CONF_CONTENT = $minified
        }
    }
}

# 4b-ii. Render deer-flow MCP extensions config (gitignored; compose mounts it :ro).
#
# Guarded by ITS OWN template, not OpenViking's - the two are unrelated.
# Without this, a fresh clone gets a Docker-created directory at the mount
# path and deer-flow's OpenViking recall (OV-2a) silently fails.
#
# RENDER-AND-COMPARE, not render-if-absent.
#
# This block previously rendered ONLY when the file was missing
# (`-not (Test-Path $dfRendered)`), which silently dropped every later
# template change. Commit 453646f added the `pacgate` MCP server (so the
# agent can query legal databases) and fixed the OpenViking X-API-Key in the
# TEMPLATE - but any machine that had already rendered kept the old file,
# retaining the broken key and never gaining pacgate. No error, no warning.
# The template changed three more times afterwards with the same outcome.
# See deploy/AIPC-UPDATE-GAP-ANALYSIS.md.
#
# Now the file is regenerated every run and compared. Identical content is a
# no-op; changed content is backed up before replacement, and the change is
# reported so an update is never silent.
$dfTemplate = ".\deer-flow-extensions-config.template.json"
$dfRendered = ".\deer-flow-extensions-config.json"
if (Test-Path $dfTemplate) {
        $dfKey = $envVars['OPENVIKING_ROOT_API_KEY']
        if (-not $dfKey -or $dfKey -match '^change-me') {
            # No usable key: we cannot render. A missing file is fatal (compose
            # mounts it :ro, so deer-flow memory recall breaks); an existing file
            # is left alone rather than failing an otherwise-good update.
            if (Test-Path $dfRendered) {
                Write-Host "[WARN] OPENVIKING_ROOT_API_KEY is unset or still 'change-me'." -ForegroundColor Yellow
                Write-Host "  Keeping the existing $dfRendered unchanged (cannot re-render without the key)." -ForegroundColor Yellow
            } else {
                Write-Host "ERROR: $dfRendered missing and OPENVIKING_ROOT_API_KEY is unset or still 'change-me'." -ForegroundColor Red
                Write-Host "  Set OPENVIKING_ROOT_API_KEY in .env, then re-run. compose.prod.yaml mounts this" -ForegroundColor Yellow
                Write-Host "  file :ro, so a missing file breaks deer-flow memory recall (OV-2a)." -ForegroundColor Yellow
                exit 1
            }
        } else {
            # The template's openviking entry uses ${OPENVIKING_ROOT_API_KEY} (the
            # server's root key), NOT ${OPENVIKING_API_KEY}. Replacing the wrong
            # placeholder is a no-op and leaves a literal ${...} in the rendered
            # file, which makes openviking return 401 and rolls back the entire MCP
            # tool load (deer-flow uses asyncio.gather). See handbook finding #2.
            # -Encoding UTF8: PS 5.1 on a Chinese-locale host decodes BOM-less files as
            # ANSI/GBK; the template carries Chinese text and must stay UTF-8.
            $df = (Get-Content $dfTemplate -Raw -Encoding UTF8).Replace('${OPENVIKING_ROOT_API_KEY}', $dfKey)

            $dfExisting = if (Test-Path $dfRendered) {
                [System.IO.File]::ReadAllText((Join-Path $PWD $dfRendered))
            } else { $null }

            # Compare with line endings normalised, so a CRLF/LF difference alone
            # does not look like a change and churn backups on every run.
            function Get-NormText([string]$s) {
                if ($null -eq $s) { return $null }
                return ($s -replace "`r`n", "`n").TrimEnd()
            }
            $dfUnchanged = ($null -ne $dfExisting) -and ((Get-NormText $dfExisting) -eq (Get-NormText $df))

            if ($dfUnchanged) {
                Write-Host "[OK] $dfRendered already current" -ForegroundColor Green
            } else {
                if ($null -ne $dfExisting) {
                    $dfStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $dfBackup = "$dfRendered.bak.$dfStamp"
                    Copy-Item -LiteralPath $dfRendered -Destination $dfBackup -Force
                    Write-Host "[OK] Previous $dfRendered backed up to $dfBackup" -ForegroundColor Green
                }

                # Write BOM-free UTF-8. PowerShell 5.1's `Set-Content -Encoding UTF8`
                # prepends a UTF-8 BOM, which deer-flow's JSON parser rejects
                # ("Unexpected UTF-8 BOM"). Use .NET WriteAllText with a no-BOM
                # UTF8Encoding so the rendered config is valid JSON.
                [System.IO.File]::WriteAllText(
                    (Join-Path $PWD $dfRendered),
                    $df,
                    [System.Text.UTF8Encoding]::new($false)
                )
                Write-Host "[OK] Rendered $dfRendered from template" -ForegroundColor Green

                # Name what changed. This is the whole point: the previous silent
                # behaviour is what let pacgate-mcp go missing unnoticed.
                $knownServers = @('openviking', 'pacgate', 'firecrawl')
                $gained = @()
                $lost = @()
                foreach ($srv in $knownServers) {
                    $needle = '"' + $srv + '"'
                    $inOld = ($null -ne $dfExisting) -and ($dfExisting -match $needle)
                    $inNew = ($df -match $needle)
                    if ($inNew -and -not $inOld) { $gained += $srv }
                    if ($inOld -and -not $inNew) { $lost += $srv }
                }
                if ($gained.Count -gt 0) {
                    Write-Host "     MCP servers gained: $($gained -join ', ')" -ForegroundColor Yellow
                }
                if ($lost.Count -gt 0) {
                    Write-Host "     MCP servers REMOVED: $($lost -join ', ') - check the template" -ForegroundColor Red
                }
            }
        }
    }

# 4c. Derive GATEWAY_CORS_ORIGINS (browser sign-in/register gate).
#
# The gateway rejects auth POSTs whose Origin header is not in this list
# (csrf_middleware is_allowed_auth_origin). Browsers ALWAYS send Origin on
# POST, so a user browsing http://<machine-host>:8089 gets 403 "Cross-site
# auth request denied." on EVERY sign-in and registration attempt when the
# list is localhost-only - the compose default. Verified 2026-09-20:
#   POST /api/v1/auth/login/local with Origin http://192.168.8.88:8089 -> 403
#   same POST with Origin http://localhost:8089 -> 401 (gate passed)
# The same-origin escape does NOT work behind our ingress chain (nginx ->
# Next.js rewrite -> gateway): Next.js rewrites Host to the gateway's
# authority, so the gateway can never see the browser's LAN host.
#
# This step auto-derives the machine's own browser origins and appends them
# to .env when the operator has not set GATEWAY_CORS_ORIGINS. Existing
# values are NEVER overwritten - a machine whose operator deliberately set
# the list keeps it; a localhost-only value earns a loud warning instead.
$gwCors = if ($envVars.ContainsKey('GATEWAY_CORS_ORIGINS')) { $envVars['GATEWAY_CORS_ORIGINS'] } else { $null }
if ([string]::IsNullOrWhiteSpace($gwCors)) {
    # Derive this machine's browser origins. The browser may reach the
    # ingress via ANY of: hostname, every non-loopback IPv4, or localhost.
    # Each is http://<host>:<published-port>. The ports must be DERIVED
    # (docker compose port <svc> <container-port>), not hardcoded - this dev box
    # publishes 8081 while compose declares 8089, and an AIPC may have either.

    $corsHosts = New-Object System.Collections.Generic.List[string]
    $corsHosts.Add('localhost')
    try { $corsHosts.Add(([System.Net.Dns]::GetHostName()).ToLower()) } catch { }
    try {
        $lanIps = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
            ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
            Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            ForEach-Object { $_.Address.ToString() } |
            Where-Object { $_ -notmatch '^(127\.|169\.254\.)' }
        foreach ($ip in $lanIps) { if (-not $corsHosts.Contains($ip)) { $corsHosts.Add($ip) } }
    } catch { }

    # Derive BOTH published browser ports, not just the ingress port.
    #
    # Defect fixed 2026-10-19. This used to emit http://<host>:<nginx-port> only.
    # Because compose declares ${GATEWAY_CORS_ORIGINS:-<default>}, writing that
    # narrower value into .env REPLACED a better default - the compose default
    # lists both :8089 and :8090, and the derived value silently dropped :8090.
    # Measured consequence on the dev box: a browser on :8090 was refused by the
    # gateway (403 "Cross-site auth request denied") while :8089 worked, so the
    # machine appeared to have a broken auth service rather than a missing origin.
    #
    # :8090 is deer-flow-frontend's published port and serves the same app; both
    # are legitimate sign-in origins. Enumerate the ports compose actually
    # publishes for nginx (80) and deer-flow-frontend (3000) and fall back to the
    # declared defaults when the stack is not up yet (first install runs this
    # before `up`).
    $corsPorts = New-Object System.Collections.Generic.List[string]
    foreach ($svcPort in @(@('nginx', '80', '8089'), @('deer-flow-frontend', '3000', '8090'))) {
        $svcName = $svcPort[0]; $containerPort = $svcPort[1]; $fallback = $svcPort[2]
        $published = $null
        try {
            $out = Invoke-WithNativeStderr { (docker compose -f compose.prod.yaml port $svcName $containerPort 2>$null | Out-String).Trim() }
            if ($out -match ':(\d+)\s*$') { $published = $Matches[1] }
        } catch { $published = $null }
        if (-not $published) { $published = $fallback }
        if (-not $corsPorts.Contains($published)) { $corsPorts.Add($published) }
    }

    $derivedOrigins = ($corsHosts | ForEach-Object { $h = $_; $corsPorts | ForEach-Object { "http://${h}:$_" } }) -join ','
    # Compose reads ${GATEWAY_CORS_ORIGINS:-...} - the value must be SET in
    # .env so it overrides the compose default, which is localhost-only.
    $rawEnv = [System.IO.File]::ReadAllText((Resolve-Path $envPath))
    $prefix = if ($rawEnv.Length -eq 0 -or $rawEnv.EndsWith("`n")) { '' } else { "`r`n" }
    [System.IO.File]::AppendAllText(
        (Resolve-Path $envPath),
        "$prefix" + "GATEWAY_CORS_ORIGINS=$derivedOrigins`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    $envVars['GATEWAY_CORS_ORIGINS'] = $derivedOrigins
    Write-Host "[OK] Derived GATEWAY_CORS_ORIGINS for this machine: $derivedOrigins" -ForegroundColor Green
    Write-Host "     Browser sign-in/register now accepts this machine's hostname and LAN IP." -ForegroundColor Gray
    Write-Host "     Feeds BOTH origin gates (gateway CORS + frontend trusted origins)." -ForegroundColor Gray
    if ($corsPorts.Count -gt 1) {
        Write-Host "     Ports covered: $(($corsPorts | ForEach-Object { $_ }) -join ', ') (ingress + frontend)." -ForegroundColor Gray
    }
    if ($corsPorts -notcontains '8089') {
        Write-Host "     NOTE: the ingress port is $($corsPorts[0]) (not the default 8089); origins use it." -ForegroundColor Gray
    }
}
else {
    $corsSet = $gwCors.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $onlyLocal = ($corsSet.Count -gt 0) -and -not ($corsSet | Where-Object { $_ -notmatch '^http://(localhost|127\.0\.0\.1)' })
    if ($onlyLocal) {
        # Loud, specific, actionable: this exact value produces the 403 that
        # looks like a broken auth service. The check cannot auto-fix it -
        # an operator who SET the value may be deliberately restricting access.
        Write-Host "[WARN] GATEWAY_CORS_ORIGINS is localhost-only ($gwCors)." -ForegroundColor Yellow
        Write-Host "       Users browsing http://<machine-host>:8089 will get 403 on sign-in" -ForegroundColor Yellow
        Write-Host "       and registration ('Cross-site auth request denied.')." -ForegroundColor Yellow
        Write-Host "       Fix: add this machine's browser origin to .env, e.g." -ForegroundColor Yellow
        $fixHost = try { [System.Net.Dns]::GetHostName().ToLower() } catch { '<machine-host>' }
        Write-Host "         GATEWAY_CORS_ORIGINS=http://${fixHost}:8089,http://${fixHost}:8090,$gwCors" -ForegroundColor Gray
        Write-Host "       then re-run this script." -ForegroundColor Yellow
    }
    else {
        # Present-but-incomplete is the AIPC failure mode, not localhost-only.
        #
        # Fixed 2026-10-19. The old code only WARNed when the value was
        # localhost-only, and did nothing when it covered some hosts but not all
        # published ports. On a client AIPC the installer had already written
        # http://<host>:8089 for the ingress port only, so re-running -Update
        # found the key present, skipped derivation, and left :8090 dead for
        # ever: the machine stayed 403 on the frontend port across every
        # upgrade, and no release could fix it. A value that is missing hosts or
        # ports is a defect, not a preference.
        #
        # Repair is ADDITIVE ONLY. Origins are never removed, so an operator who
        # deliberately allowlisted extra hosts keeps them, and narrowing access
        # by hand still works because a fully-covered list is left untouched.
        $corsPorts = New-Object System.Collections.Generic.List[string]
        foreach ($svcPort in @(@('nginx', '80', '8089'), @('deer-flow-frontend', '3000', '8090'))) {
            $published = $null
            try {
                $out = Invoke-WithNativeStderr { (docker compose -f compose.prod.yaml port $svcPort[0] $svcPort[1] 2>$null | Out-String).Trim() }
                if ($out -match ':(\d+)\s*$') { $published = $Matches[1] }
            } catch { $published = $null }
            if (-not $published) { $published = $svcPort[2] }
            if (-not $corsPorts.Contains($published)) { $corsPorts.Add($published) }
        }
        $corsHosts = New-Object System.Collections.Generic.List[string]
        # localhost MUST be in the additive set too. It is the origin used when
        # someone browses the app ON the AIPC itself, and the historical .env
        # written by the old derivation had it only for :8089.
        $corsHosts.Add('localhost')
        try { $corsHosts.Add(([System.Net.Dns]::GetHostName()).ToLower()) } catch { }
        try {
            $lanIps = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
                ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
                Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.Address.ToString() } |
                Where-Object { $_ -notmatch '^(127\.|169\.254\.)' }
            foreach ($ip in $lanIps) { if (-not $corsHosts.Contains($ip)) { $corsHosts.Add($ip) } }
        } catch { }

        $existing = New-Object System.Collections.Generic.List[string]
        foreach ($o in $corsSet) { if (-not $existing.Contains($o)) { $existing.Add($o) } }
        $added = New-Object System.Collections.Generic.List[string]
        foreach ($h in $corsHosts) {
            foreach ($p in $corsPorts) {
                $candidate = "http://${h}:${p}"
                if (-not $existing.Contains($candidate)) { $existing.Add($candidate); $added.Add($candidate) }
            }
        }

        if ($added.Count -gt 0) {
            $merged = $existing -join ','
            $rawEnv = [System.IO.File]::ReadAllText((Resolve-Path $envPath))
            $lines = [regex]::Split($rawEnv, '\r\n|\n')
            $out = New-Object System.Collections.Generic.List[string]
            $replaced = $false
            foreach ($line in $lines) {
                if (-not $replaced -and $line -match '^\s*GATEWAY_CORS_ORIGINS\s*=') {
                    $out.Add("GATEWAY_CORS_ORIGINS=$merged"); $replaced = $true
                } else { $out.Add($line) }
            }
            $text = ($out -join "`r`n")
            if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
            [System.IO.File]::WriteAllText((Resolve-Path $envPath), $text, [System.Text.UTF8Encoding]::new($false))
            $envVars['GATEWAY_CORS_ORIGINS'] = $merged
            Write-Host "[OK] GATEWAY_CORS_ORIGINS was incomplete - added $($added.Count) origin(s)." -ForegroundColor Green
            Write-Host "     Added: $($added -join ', ')" -ForegroundColor Gray
            Write-Host "     Both origin gates (gateway + frontend) now admit this machine." -ForegroundColor Gray
            Write-Host "     Recreate the affected services for it to take effect:" -ForegroundColor Gray
            Write-Host "       docker compose -f compose.prod.yaml up -d --force-recreate deer-flow deer-flow-frontend" -ForegroundColor Gray
        }
        elseif ($onlyLocal) {
            # Loud, specific, actionable: this exact value produces the 403 that
            # looks like a broken auth service. Deliberately NOT auto-fixed when
            # the list is otherwise complete - an operator who SET a restricted
            # value may be doing so on purpose.
            Write-Host "[WARN] GATEWAY_CORS_ORIGINS is localhost-only ($gwCors)." -ForegroundColor Yellow
            Write-Host "       Users browsing http://<machine-host>:8089 will get 403 on sign-in" -ForegroundColor Yellow
            Write-Host "       and registration ('Cross-site auth request denied.')." -ForegroundColor Yellow
            Write-Host "       Fix: add this machine's browser origin to .env, e.g." -ForegroundColor Yellow
            $fixHost = try { [System.Net.Dns]::GetHostName().ToLower() } catch { '<machine-host>' }
            Write-Host "         GATEWAY_CORS_ORIGINS=http://${fixHost}:8089,http://${fixHost}:8090,$gwCors" -ForegroundColor Gray
            Write-Host "       then re-run this script." -ForegroundColor Yellow
        }
        else {
            Write-Host "[OK] GATEWAY_CORS_ORIGINS set: $gwCors" -ForegroundColor Green
        }
    }
}

# 5. Pull models (first install only)
if (-not $Update) {
    Write-Host "`nPulling Ollama models (this takes a while on first run)..." -ForegroundColor Cyan
    foreach ($model in Get-Content ollama-models.txt -Encoding UTF8) {
        if ($model -and -not $model.StartsWith("#")) {
            Write-Host "  Pulling $model..." -ForegroundColor Yellow
            ollama pull $model
        }
    }
    Write-Host "[OK] Models pulled" -ForegroundColor Green
}

# 6. Pull Docker images
Write-Host "`nPulling Docker images..." -ForegroundColor Cyan
docker compose -f compose.prod.yaml pull
# Capture WHY, not just the fact. `compose pull` writes progress to stderr, so it
# must stay unredirected here (under Windows PowerShell 5.1 any 2>&1 / 2>$null
# makes a native command's stderr TERMINATING). But leaving the exit code
# unexamined meant a pull that failed halfway still printed "[OK] Images pulled",
# and the machine then reported success while running the previous artifact -
# observed on this dev box 2026-10-13, where every image logged "Pulled" and the
# tag still pointed at the old build. A pull result the operator cannot trust is
# the same as no check at all.
$pullExit = $LASTEXITCODE
if ($pullExit -ne 0) {
    Write-Host "[WARN] 'compose pull' exited $pullExit - some images may not be current." -ForegroundColor Yellow
    Write-Host "       The install continues, but the stack may come up on an older artifact." -ForegroundColor Yellow
    Write-Host "       Check with:  docker compose -f compose.prod.yaml pull" -ForegroundColor Gray
} else {
    Write-Host "[OK] Images pulled" -ForegroundColor Green
}

# 6a. Verify the pull ACTUALLY refreshed the tags, and repair it if it did not.
#
# `compose pull` reports "Pulled" for an image even when the local tag does not
# advance. Observed on this dev box 2026-10-13: every image logged "Pulled", the
# command exited 0, and the machine went on running the PREVIOUS build of the same
# version (revision 50252862c826 where 0.1.28 had been re-published as b5ef2b12b8de).
# Nothing reported it, because "did the pull do anything" was never asked.
#
# The digest is the content, so it is the only honest answer. The registry digest
# comes from `buildx imagetools` (which resolves anonymously for these public
# images) and the local one from RepoDigests; when they agree the tag is current.
#
# Degrades quietly: no network, no buildx, or an unreadable digest means "cannot
# assert", which is reported as nothing rather than as a failure. An installer
# that blocks on an unreachable registry is worse than one that cannot check.
if (Test-Path compose.prod.yaml) {
    $firstParty = @([regex]::Matches((Get-Content compose.prod.yaml -Raw -Encoding UTF8),
        '(?m)^\s*image:\s*(?<ref>ghcr\.io/[a-z0-9\-]+/[a-z0-9\-]+:\d+\.\d+\.\d+)\s*$') |
        ForEach-Object { $_.Groups['ref'].Value } | Select-Object -Unique)

    function Get-RegistryImageDigest([string]$Ref) {
        try {
            $d = Invoke-WithNativeStderr { (docker buildx imagetools inspect --format '{{.Manifest.Digest}}' $Ref 2>$null | Out-String).Trim() }
            if ($d -match '^sha256:[0-9a-f]{64}$') { return $d }
        }
        catch { }
        return $null
    }
    function Get-LocalImageDigest([string]$Ref) {
        try {
            $d = Invoke-WithNativeStderr { (docker inspect --format '{{index .RepoDigests 0}}' $Ref 2>$null | Out-String).Trim() }
            if ($d -match '@(?<d>sha256:[0-9a-f]{64})$') { return $Matches['d'] }
        }
        catch { }
        return $null
    }

    $staleRefs = @()
    $checked = 0
    foreach ($ref in $firstParty) {
        $reg = Get-RegistryImageDigest $ref
        if (-not $reg) { continue }         # offline or no buildx: cannot assert
        $checked++
        if ((Get-LocalImageDigest $ref) -ne $reg) { $staleRefs += $ref }
    }

    if ($checked -gt 0 -and $staleRefs.Count -gt 0) {
        Write-Host "[WARN] $($staleRefs.Count) image tag(s) did not refresh during 'compose pull':" -ForegroundColor Yellow
        foreach ($r in $staleRefs) { Write-Host "       $r" -ForegroundColor Gray }
        Write-Host "       Retrying with an explicit pull..." -ForegroundColor Yellow
        foreach ($r in $staleRefs) { docker pull $r }
        $stillStale = @($staleRefs | Where-Object { (Get-LocalImageDigest $_) -ne (Get-RegistryImageDigest $_) })
        if ($stillStale.Count -eq 0) {
            Write-Host "[OK] all $checked image tag(s) now match the registry" -ForegroundColor Green
        }
        else {
            Write-Host "[WARN] still not current after an explicit pull: $($stillStale -join ', ')" -ForegroundColor Yellow
            Write-Host "       The stack may come up on an older build of the same version." -ForegroundColor Yellow
        }
    }
    elseif ($checked -gt 0) {
        Write-Host "[OK] all $checked image tag(s) match the registry" -ForegroundColor Green
    }
}

# 6b. Provision the matter that deer-flow's memory adapter is scoped to.
#
# WHY THIS EXISTS, and why it runs BEFORE the stack starts.
#
# deer-flow selects its memory storage by class path and wraps the instantiation
# in a bare `except Exception` that substitutes its own FileMemoryStorage. The
# trip-wire is a missing PACGATE_MATTER_ID: the adapter raises on it, and that
# exact raise is what the fallback catches. FileMemoryStorage never calls
# pacgate-api, so it bypasses all three matter-memory guards (the 422 scope rule,
# the 64 KiB cap, and the If-Match revision guard) - each enforced server-side.
#
# So a blank matter id does NOT mean "no memory". It means UNSANITIZED memory,
# written to disk, with nothing reporting it as wrong. That happened here on
# 2026-09-19/20 and was only found by reading the files.
#
# Ordering matters as much as the value. Running this before `up -d` means
# deer-flow never starts without a real matter, so the fallback window is zero
# rather than "briefly, on first boot".
function Invoke-MatterProvision {
    param([string]$BaseUrl)

    # Read from $envVars, NOT $env:.
    #
    # install.ps1 parses .env into a local $envVars HASHTABLE (step 4b) and never
    # populates the process environment. The first version of this function read
    # $env:PACGATE_API_EMAIL, which is therefore ALWAYS empty inside the
    # installer - so the credential guard below was false, login was never even
    # attempted, and it reported "Could not authenticate" while the credentials
    # were sitting in .env and worked perfectly by hand. The failure looked like
    # a server fault; it was a wrong variable scope.
    $apiEmail    = if ($envVars.ContainsKey('PACGATE_API_EMAIL'))    { $envVars['PACGATE_API_EMAIL'] }    else { '' }
    $apiPassword = if ($envVars.ContainsKey('PACGATE_API_PASSWORD')) { $envVars['PACGATE_API_PASSWORD'] } else { '' }
    $existing    = if ($envVars.ContainsKey('PACGATE_MATTER_ID'))    { $envVars['PACGATE_MATTER_ID'] }    else { '' }

    # PACGATE_MATTER_ID may already name a real matter (a re-run, or an operator
    # who set it deliberately). Verify before creating a duplicate.
    $H = $null
    if ($apiEmail -and $apiPassword) {
        # RETRY, because /version answering is not the same as being ready to
        # authenticate. The first version polled /version for readiness and then
        # tried login exactly ONCE, which failed on the first real E2E run: the
        # container had just been recreated, nginx answered, and the API was
        # still applying migrations (they are applied at startup and logged
        # AFTER the listener binds). A single attempt turned a transient race
        # into a permanent "could not authenticate", and provisioning was
        # skipped - leaving the placeholder in place, which is the exact state
        # this whole step exists to prevent.
        #
        # 30 attempts x 4s = 120s, comfortably past the observed startup, and it
        # exits the moment one succeeds rather than always sleeping.
        $attempts = 30
        for ($i = 1; $i -le $attempts; $i++) {
            foreach ($p in @("$BaseUrl/api/auth/login", "$BaseUrl/auth/login")) {
                try {
                    $body = @{ email = $apiEmail; password = $apiPassword } | ConvertTo-Json -Compress
                    $login = Invoke-RestMethod -Uri $p -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20
                    if ($login.token) { $H = @{ Authorization = "Bearer $($login.token)" }; break }
                } catch { }
            }
            if ($H) { break }
            if ($i -lt $attempts) { Start-Sleep -Seconds 4 }
        }
    }

    if (-not $H) {
        # Do not silently continue: an unauthenticated run cannot provision, and
        # continuing would leave the blank value in place - the exact state this
        # step exists to prevent.
        Write-Host "  [WARN] Could not authenticate to the API, so no matter could be provisioned." -ForegroundColor Yellow
        Write-Host "         deer-flow will refuse to start its memory adapter and fall back to" -ForegroundColor Yellow
        Write-Host "         writing UNSANITIZED memory to disk. Set PACGATE_MATTER_ID in .env to" -ForegroundColor Yellow
        Write-Host "         a real matter id, or fix the API credentials, then re-run." -ForegroundColor Yellow
        return $false
    }

    if ($existing -and $existing.Trim().Length -gt 0) {
        try {
            $null = Invoke-RestMethod -Uri "$BaseUrl/api/matters/$existing" -Headers $H -TimeoutSec 20
            Write-Host "  [OK] PACGATE_MATTER_ID already names a real matter ($existing)" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "  [WARN] PACGATE_MATTER_ID=$existing does not resolve to a matter the API knows." -ForegroundColor Yellow
            Write-Host "         Provisioning a real one instead." -ForegroundColor Yellow
        }
    }

    try {
        $matter = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Method Post -Headers $H -TimeoutSec 20 `
            -ContentType 'application/json' `
            -Body (@{ name = 'default'; description = 'Default matter for this deployment (created by install.ps1)' } | ConvertTo-Json -Compress)
    } catch {
        Write-Host "  [WARN] matter create failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    if (-not $matter.id) {
        Write-Host "  [WARN] matter create returned no id" -ForegroundColor Yellow
        return $false
    }

    # Write it into .env so every subsequent compose run resolves the real id.
    # Rewrite in place: preserve every other line, including comments and secrets.
    $envPath = Join-Path (Get-Location) '.env'
    $lines = Get-Content $envPath
    $found = $false
    $out = foreach ($line in $lines) {
        if ($line -match '^\s*PACGATE_MATTER_ID\s*=') {
            $found = $true
            "PACGATE_MATTER_ID=$($matter.id)"
        } else { $line }
    }
    if (-not $found) { $out += "PACGATE_MATTER_ID=$($matter.id)" }
    # No BOM: docker compose chokes on a BOM in .env, and Set-Content adds one by
    # default on Windows PowerShell.
    [System.IO.File]::WriteAllLines($envPath, $out, [System.Text.UTF8Encoding]::new($false))

    # Update BOTH the local map and the process env. The map is what the rest of
    # this script reads from (step 4b parses .env once); the process env is what
    # docker compose inherits for its `${PACGATE_MATTER_ID}` substitution in this
    # same run, so the deer-flow container starts with the value rather than
    # needing a recreate afterwards.
    $envVars['PACGATE_MATTER_ID'] = $matter.id
    $env:PACGATE_MATTER_ID = $matter.id
    Write-Host "  [OK] Provisioned matter $($matter.id) and wrote it to .env" -ForegroundColor Green

    # Prove it. A write that is merely attempted is not a write that works, and
    # this whole file exists because "looks configured" hid a broken lane.
    try {
        $probe = Invoke-RestMethod -Uri "$BaseUrl/api/matters/$($matter.id)/memory" -Headers $H -TimeoutSec 20
        Write-Host "  [OK] memory endpoint reachable (revision $($probe.revision))" -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] the matter exists but its memory endpoint did not answer: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $true
}

# 6a. Bootstrap the default tenant and the admin user.
#
# WHY THIS IS HERE, and why it runs BEFORE provisioning.
#
# Nothing used to do this. A fresh install finished with ZERO users, so:
#   * login returned 401
#   * matter provisioning could not authenticate and was skipped
#   * deer-flow then started with a BLANK PACGATE_MATTER_ID, its adapter raised,
#     and get_memory_storage() silently substituted FileMemoryStorage
#   * ...which writes UNSANITIZED matter prose to disk, outside all three
#     matter-memory guards
#
# So "no admin" was not a cosmetic gap - it was the first link in the chain that
# ends with unredacted client text on disk. Found by the clean-clone proof,
# because the dev box already had an admin and could never show it.
#
# Two details are load-bearing and both were wrong in the handbook:
#
#  1. The tenant slug MUST equal PACGATE_DEFAULT_TENANT (default "default-firm").
#     The handbook inserts slug='pacgate-law', which does not match the lookup in
#     auth.rs (`get_by_slug(&state.config.default_tenant)`), so registration fails
#     with "default tenant not found: matter not found: row not found" - an error
#     that reads like a database fault and is really a naming mismatch.
#
#  2. Registration is a POST to /api/auth/register and returns 200 on success.
#     It is idempotent-safe to attempt: an existing user yields a non-2xx error
#     which this step treats as "already bootstrapped", not as a failure.
function Invoke-Bootstrap {
    param([string]$BaseUrl)

    $tenantSlug = if ($envVars.ContainsKey('PACGATE_TENANT_ID') -and $envVars['PACGATE_TENANT_ID']) {
        $envVars['PACGATE_TENANT_ID']
    } else { 'default-firm' }
    $tenantName = if ($envVars.ContainsKey('PACGATE_TENANT_NAME') -and $envVars['PACGATE_TENANT_NAME']) {
        $envVars['PACGATE_TENANT_NAME']
    } else { 'Default Firm' }
    $apiEmail    = if ($envVars.ContainsKey('PACGATE_API_EMAIL'))    { $envVars['PACGATE_API_EMAIL'] }    else { '' }
    $apiPassword = if ($envVars.ContainsKey('PACGATE_API_PASSWORD')) { $envVars['PACGATE_API_PASSWORD'] } else { '' }

    if (-not $apiEmail -or -not $apiPassword) {
        Write-Host "  [WARN] PACGATE_API_EMAIL / PACGATE_API_PASSWORD are not set in .env." -ForegroundColor Yellow
        Write-Host "         Cannot bootstrap the admin user. Set both and re-run." -ForegroundColor Yellow
        return $false
    }

    # (1) The tenant. Created via the API when possible so the row matches what
    # the API expects; falls back to the documented psql path because the tenant
    # lookup is what registration needs, and a first-run API may not expose a
    # tenant-create route at all.
    #
    # Match on SLUG, and use the same slug the lookup will use.
    $sql = "INSERT INTO tenants (name, slug) SELECT '$($tenantName -replace "'","''")', '$($tenantSlug -replace "'","''")' WHERE NOT EXISTS (SELECT 1 FROM tenants WHERE slug = '$($tenantSlug -replace "'","''")');"
    $seedOut = Invoke-WithNativeStderr { docker exec pacgate-db psql -U pacgate -d pacgate -t -c $sql 2>$null }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] tenant '$tenantSlug' present (created if absent)" -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] could not ensure the tenant: $($seedOut -join ' ')" -ForegroundColor Yellow
        return $false
    }

    # (2) The admin. Retry, because the API may still be applying migrations.
    #
    # Uses Invoke-ApiRequest: -SkipHttpErrorCheck is PowerShell 7-only and threw
    # ParameterBindingException on PS 5.1, where the swallow-all catch below hid
    # it. A 403 here is the normal "the first account already exists" answer from
    # this route (it is first-user-only), not a failure - see the message check.
    $registered = $false
    $alreadyThere = $false
    $lastErr = $null
    for ($i = 1; $i -le 15; $i++) {
        $resp = Invoke-ApiRequest -Uri "$BaseUrl/api/auth/register" -Method Post `
            -Body (@{ email = $apiEmail; password = $apiPassword } | ConvertTo-Json -Compress) `
            -TimeoutSec 20
        if ($resp.Error) { $lastErr = $resp.Error }
        if ($null -ne $resp.Status) {
            if ($resp.Status -ge 200 -and $resp.Status -lt 300) { $registered = $true; break }
            # A duplicate is success for our purpose: the admin exists.
            if ($resp.Status -eq 409 -or $resp.Body -match 'already|exists|duplicate') {
                $alreadyThere = $true; break
            }
            $lastErr = "HTTP $($resp.Status): $($resp.Body)"
        }
        if ($i -lt 15) { Start-Sleep -Seconds 4 }
    }

    if ($registered) {
        Write-Host "  [OK] admin '$apiEmail' registered" -ForegroundColor Green
    }
    elseif ($alreadyThere) {
        Write-Host "  [OK] admin '$apiEmail' already exists" -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] could not register the admin '$apiEmail'." -ForegroundColor Yellow
        if ($lastErr) { Write-Host "         Last error: $lastErr" -ForegroundColor DarkYellow }
        Write-Host "         Matter provisioning will fail without a login. Check the API logs." -ForegroundColor Yellow
        return $false
    }

    # (3) ENSURE THE ADMIN CAN ACTUALLY ADMINISTER.
    #
    # Existing a login is not the same as holding the admin role, and until
    # 2026-10-03 this step only checked existence. The register route then
    # hardcoded role='attorney' and never set system_role at all, so the column
    # default 'user' applied and EVERY account it created was a non-admin - while
    # this function logged "[OK] admin '<email>' registered". Verified on the dev
    # box: all four accounts there read system_role='user'.
    #
    # Fixing that in the API only helps a FRESH first user; an account created by
    # an earlier release keeps system_role='user' forever, and with it can never
    # use POST /api/auth/users. So the upgrade path has to exist here.
    #
    # Why direct SQL rather than an API call: promoting an account requires an
    # admin, and on an upgrade there is no admin yet - that is the whole problem.
    # The installer is the trusted actor that breaks the cycle, exactly as it
    # already does for the tenant row above.
    #
    # Guarded to the configured service account only. It never touches another
    # user, and it reports what it changed.
    $emailLiteral = $apiEmail -replace "'", "''"
    $roleBefore = Invoke-WithNativeStderr { (docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c `
        "SELECT system_role FROM users WHERE email = '$emailLiteral';" 2>$null | Out-String).Trim() }

    if ($roleBefore -eq 'admin') {
        Write-Host "  [OK] '$apiEmail' holds the platform admin role" -ForegroundColor Green
    }
    elseif ($roleBefore -eq 'user') {
        Write-Host "  [INFO] '$apiEmail' exists but is NOT a platform admin (system_role='user')." -ForegroundColor Yellow
        Write-Host "         Promoting it: without this the provisioning route is unreachable," -ForegroundColor Yellow
        Write-Host "         because no principal on this machine would hold the admin role." -ForegroundColor Yellow
        $upd = Invoke-WithNativeStderr { docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c `
            "UPDATE users SET system_role = 'admin' WHERE email = '$emailLiteral' RETURNING email;" 2>$null | Out-String }
        if ($upd -match [regex]::Escape($apiEmail)) {
            Write-Host "  [OK] '$apiEmail' promoted to platform admin" -ForegroundColor Green
        }
        else {
            Write-Host "  [WARN] could not promote '$apiEmail': $($upd.Trim())" -ForegroundColor Yellow
            Write-Host "         Run by hand: UPDATE users SET system_role='admin' WHERE email='$apiEmail';" -ForegroundColor Yellow
        }
    }
    else {
        # Empty (the account vanished between the two queries) or an unexpected
        # value. Do not guess; say what was found.
        Write-Host "  [WARN] could not read '$apiEmail's platform role (got '$roleBefore')." -ForegroundColor Yellow
        Write-Host "         Verify manually: SELECT email, role, system_role FROM users;" -ForegroundColor Yellow
    }

    return $true
}

Write-Host "`nBootstrapping the default tenant and admin user..." -ForegroundColor Cyan
# Same nginx-fronted path as provisioning: the API publishes no host port.
$bootstrapped = $false
Invoke-WithNativeStderr {
    docker compose -f compose.prod.yaml up -d pacgate-api pacgate-db nginx | ForEach-Object {
        Write-Host "    $_" -ForegroundColor DarkGray
    }
}
$apiUp = $false
foreach ($attempt in 1..30) {
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:8089/version" -TimeoutSec 5
        $apiUp = $true; break
    } catch { Start-Sleep -Seconds 2 }
}
if ($apiUp) {
    $bootstrapped = Invoke-Bootstrap -BaseUrl 'http://localhost:8089/pacgate'
}
else {
    Write-Host "  [WARN] the API did not become reachable in 60s; skipping bootstrap." -ForegroundColor Yellow
}

# 6b. Provision the matter deer-flow's memory adapter is scoped to.
#
# Runs AFTER 6a by necessity: provisioning authenticates, and before the bootstrap
# there is no admin to authenticate as. The ordering is the point - see the note
# at the top of 6a for the chain that a missing admin sets off.
Write-Host "`nProvisioning the matter for deer-flow memory..." -ForegroundColor Cyan
$provisioned = $false
if ($apiUp) {
    $provisioned = Invoke-MatterProvision -BaseUrl 'http://localhost:8089/pacgate'
}
else {
    Write-Host "  [WARN] the API is not reachable, so no matter could be provisioned." -ForegroundColor Yellow
    Write-Host "         Re-run .\install.ps1 -Update once the stack is healthy." -ForegroundColor Yellow
}

# 7. Start stack
Write-Host "`nStarting Pacgate-ai..." -ForegroundColor Cyan
docker compose -f compose.prod.yaml up -d
Write-Host "[OK] Stack running" -ForegroundColor Green

# 7a. Prove deer-flow is on the SANITIZED lane, not the fallback. This is the
# only check that observes the running container rather than the configuration.
if ($provisioned) {
    $lane = Invoke-WithNativeStderr { docker exec deer-flow sh -c 'echo $PACGATE_MATTER_ID' 2>$null }
    if ($lane -and $lane.Trim().Length -gt 0) {
        Write-Host "[OK] deer-flow has PACGATE_MATTER_ID=$($lane.Trim())" -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] deer-flow is running with a BLANK PACGATE_MATTER_ID." -ForegroundColor Yellow
        Write-Host "       Its adapter raises on that, and deer-flow silently falls back to" -ForegroundColor Yellow
        Write-Host "       FileMemoryStorage - UNSANITIZED memory on disk. Check that .env" -ForegroundColor Yellow
        Write-Host "       has the value and that the container was recreated, not just restarted." -ForegroundColor Yellow
    }
}

# 7b. Reload nginx config if it changed. The nginx service uses the stock
# nginx:1.27-alpine image with a BIND-MOUNTED ./nginx/default.conf, so `git
# pull` brings in a new config but `up -d` does NOT recreate the container or
# reload the file. Reloading makes AIPC2 pick up ingress/proxy changes (e.g.
# the resolver + variable proxy_pass fix) without a full recreate.
Write-Host "`nReloading nginx config..." -ForegroundColor Cyan
Invoke-WithNativeStderr { docker exec pacgate-nginx nginx -t *>$null }
if ($LASTEXITCODE -eq 0) {
    docker exec pacgate-nginx nginx -s reload
    Write-Host "[OK] nginx config reloaded" -ForegroundColor Green
} else {
    Write-Host "[WARN] nginx config test failed; leaving running config unchanged" -ForegroundColor Yellow
}

# 7c. Restart services whose CODE is bind-mounted.
#
# A changed bind-mounted FILE does not alter compose config, so `up -d` does NOT
# recreate the container - and Python imports its modules at process start with
# no hot reload. Without this restart, patched code (patches/*.py) and
# deer-flow-config.yaml sit on disk doing nothing. See
# deploy/AIPC-UPDATE-GAP-ANALYSIS.md defect 3b.
#
# deer-flow-frontend is restarted for the SAME reason since 2026-10-13: it now
# bind-mounts deploy/frontend-patches/files/next.config.js, and `next start`
# reads that file only at process boot. Its config carries
# experimental.proxyTimeout, without which Next.js tears down every proxied
# gateway call longer than its 30s default - the caller sees the failure while
# the run keeps executing (deploy/DEFECT-frontend-proxy-timeout.md). A repo
# update that changes that file is inert until the process restarts, so omitting
# this restart would leave an updated machine still broken.
#
# Only needed on -Update: a first install mounts the files before the container
# starts, so they are already in effect.
if ($Update) {
    Write-Host "`nRestarting services with bind-mounted code..." -ForegroundColor Cyan
    # Deer-flow: patches/*.py and deer-flow-config.yaml are bind-mounted and read
    # at process start only. The literal `restart deer-flow` below is also the
    # marker scripts/audit-aipc-update-coverage.ps1 matches on for BOTH the
    # personas/patches and deer-flow-config.yaml rows, so keep it explicit.
    $dfRunning = docker compose -f compose.prod.yaml ps -q deer-flow
    if ($dfRunning) {
        docker compose -f compose.prod.yaml restart deer-flow
        Write-Host "[OK] deer-flow restarted (patches/*.py and config.yaml now in effect)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] deer-flow is not running; skipped restart" -ForegroundColor Yellow
    }
    # Frontend: next.config.js is bind-mounted (deploy/frontend-patches/files/) and
    # `next start` reads it only at boot. Its experimental.proxyTimeout is what
    # stops Next.js tearing down proxied gateway calls longer than its 30s default
    # (deploy/DEFECT-frontend-proxy-timeout.md). Without this restart a repo update
    # leaves the OLD config in force and an updated machine stays broken - the fix
    # would look shipped and be inert.
    $feRunning = docker compose -f compose.prod.yaml ps -q deer-flow-frontend
    if ($feRunning) {
        docker compose -f compose.prod.yaml restart deer-flow-frontend
        Write-Host "[OK] deer-flow-frontend restarted (next.config.js proxyTimeout now in effect)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] deer-flow-frontend is not running; skipped restart" -ForegroundColor Yellow
    }
    # pacgate-mcp: deploy/pacgate-mcp/server.py is bind-mounted over the image's
    # copy (compose.prod.yaml, the SANITIZE_TIMEOUT_S override). Python imports
    # its modules at process start with no hot reload, so a repo update that
    # changes server.py leaves the OLD module running. This is the same failure
    # class as the two restarts above, and it was missing: the MCP memory-write
    # fix (PacgateApi.post() had no `headers` kwarg, so every
    # pacgate_write_memory raised TypeError) would have looked shipped on every
    # updated machine while the running process still had the broken signature.
    $mcpRunning = docker compose -f compose.prod.yaml ps -q pacgate-mcp
    if ($mcpRunning) {
        docker compose -f compose.prod.yaml restart pacgate-mcp
        Write-Host "[OK] pacgate-mcp restarted (bind-mounted server.py now in effect)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] pacgate-mcp is not running; skipped restart" -ForegroundColor Yellow
    }

    # 7c-bis. PROVE the restarted deer-flow actually loaded the bind-mounted code.
    #
    # Step 7c restarts deer-flow so mounted code takes effect, but a restart
    # proves only that the process started - not that the file it imported is the
    # one in the repo. Two real ways that diverges, both silent:
    #   - the repo pull was SKIPPED (dirty tracked file), so the mount still
    #     resolves to the OLD file and we restart onto old code;
    #   - the mount did not land (renamed upstream path, typo), so the container
    #     runs its baked copy.
    # In both cases the install finishes green and the machine behaves like the
    # previous release. Measured 2026-10-27: a clone with one edited tracked file
    # reported a successful update while the loop-guard patch was never applied.
    #
    # This asserts from INSIDE the container, because that is the only view that
    # matters. It checks a marker that exists ONLY in the windowed patch
    # (_tool_name_counter), so it fails on the old monotonic middleware.
    # Advisory, never fatal: an operator's own edit is not an install failure, and
    # blocking an update on it would be the wrong trade - the point is that it can
    # no longer be INVISIBLE.
    $dfRunning = docker compose -f compose.prod.yaml ps -q deer-flow
    if ($dfRunning) {
        $probe = @'
import sys
sys.path.insert(0, "/app/backend/packages/harness")
p = "/app/backend/packages/harness/deerflow/agents/middlewares/loop_detection_middleware.py"
try:
    src = open(p, encoding="utf-8").read()
except Exception as e:
    print("LOOPGUARD=UNREADABLE %s" % e); raise SystemExit(0)
print("LOOPGUARD=WINDOWED" if "_tool_name_counter" in src else "LOOPGUARD=MONOTONIC")
'@
        $lg = ($probe | docker exec -i deer-flow /app/backend/.venv/bin/python 2>&1 | Out-String)
        if ($lg -match 'LOOPGUARD=WINDOWED') {
            Write-Host "[OK] deer-flow loaded the windowed loop guard from the repo patch" -ForegroundColor Green
        }
        elseif ($lg -match 'LOOPGUARD=MONOTONIC') {
            Write-Host "[WARN] deer-flow is running the OLD (monotonic) loop guard." -ForegroundColor Yellow
            Write-Host "  The bind-mounted patch in the container is not the repo's version," -ForegroundColor Yellow
            Write-Host "  so the 50-bash force-stop is STILL active on this machine." -ForegroundColor Yellow
            Write-Host "  Usual cause: the repo pull was skipped (see the warning above)." -ForegroundColor Yellow
            Write-Host "  Fix: resolve the dirty files, then re-run .\install.ps1 -Update." -ForegroundColor Yellow
        }
        else {
            Write-Host "[WARN] could not verify the loop guard inside deer-flow (it may still be starting)." -ForegroundColor Yellow
        }
    }
}

# 7d. Report qm sandbox drift.
#
# qm's agent executes inside a sandbox image PINNED BY DIGEST in
# deploy/qm-pacgate/qm.config.jsonc. Digest pinning is right - the isolation
# boundary should be immutable - but it means a repo update can change
# deploy/qm-pacgate/sandbox/ and the pinned image stays exactly as it was:
# the agent keeps running the OLD skills and tools, with no error. See
# plans/014 step 4.
#
# This REPORTS rather than rebuilds, deliberately:
#   - the rebuild needs Node 24 + npm + docker buildx and takes minutes;
#   - the digest must be repinned afterwards, which is a config change we should
#     not make unattended on a client machine;
#   - qm may not even be deployed on this machine.
# A wrong automatic rebuild would be a worse failure than a visible warning, so
# this makes the drift loud and leaves the decision to the operator.
if ($Update) {
    $qmScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts/qm-sandbox-fingerprint.ps1'
    # Only meaningful if this machine actually runs qm.
    if ((Test-Path $qmScript) -and (Invoke-WithNativeStderr { docker ps --format '{{.Names}}' 2>$null | Select-String -SimpleMatch 'qm-' })) {
        Write-Host "`nChecking qm sandbox provenance..." -ForegroundColor Cyan
        $fpOut = Invoke-WithNativeStderr { & $QmPowerShell -NoProfile -File $qmScript -Json 2>$null }
        $fp = $null
        try { $fp = ($fpOut | Out-String).Trim() | ConvertFrom-Json } catch { }
        if ($fp) {
            switch ($fp.state) {
                'CURRENT' {
                    Write-Host "[OK] qm sandbox matches its source ($($fp.fingerprint.Substring(0,12))...)" -ForegroundColor Green
                }
                'NOT_RECORDED' {
                    Write-Host "[WARN] qm sandbox image is digest-pinned with no recorded source fingerprint." -ForegroundColor Yellow
                    Write-Host "       Cannot tell whether it matches deploy/qm-pacgate/sandbox/." -ForegroundColor Yellow
                    Write-Host "       See plans/014 step 4 for the rebuild + repin procedure." -ForegroundColor Yellow
                }
                'DRIFT' {
                    Write-Host "[WARN] qm sandbox source has CHANGED since the image was pinned." -ForegroundColor Yellow
                    Write-Host "       qm is running OLD skills and tools. Rebuild + repin:" -ForegroundColor Yellow
                    Write-Host "         cd deploy\qm-pacgate" -ForegroundColor Gray
                    Write-Host "         npm exec qm -- sandbox build   # then repin the printed digest" -ForegroundColor Gray
                    Write-Host "         pwsh -File ..\..\scripts\qm-sandbox-fingerprint.ps1 -Write" -ForegroundColor Gray
                }
            }
        }
        else {
            Write-Host "[WARN] qm sandbox check produced no parseable result; skipped." -ForegroundColor Yellow
        }
    }
}

# 7e. Staleness marker: report what is ACTUALLY running, not what was pulled.
#
# The failure this guards against has no other symptom. `compose pull` fetches
# new images, but the running containers keep executing the OLD ones until they
# are recreated - and on a machine where someone has been debugging, the gap can
# be days wide. Nothing errors; the app simply behaves like the old release. A
# "what am I running" answer is the difference between diagnosing that in
# seconds and a dev logging in to poke at it.
#
# The URL is <nginx-host-port>/version - NOT /build-info. nginx maps the clean
# `/version` location onto pacgate-api's /build-info, and pacgate-api itself
# publishes NO host port (`docker compose port pacgate-api` is empty), so nginx
# is the only way in from the host. Probing /build-info at the nginx port would
# hit the deer-flow frontend instead and return HTML, so the path matters.
#
# The host port is DERIVED, not assumed. compose.prod.yaml maps 8089:80, but a
# machine can legitimately remap it (the dev box for this project runs 8081),
# and a hardcoded 8089 would silently probe nothing and report "unreachable" on
# a perfectly healthy install - a false alarm that trains people to ignore the
# check. `docker compose port` answers with whatever is actually published.
#
# The response reports the version COMPILED INTO THE RUNNING BINARY, not the
# image tag. Those record what was deployed, and the failure worth catching is
# the deployed artifact disagreeing with the process actually serving traffic.
#
# Reports and never fails the install: an unreachable API during a restart is
# normal, and blocking an update on a health probe would be the wrong trade.
if ($Update) {
    Write-Host "`nChecking the running runtime version..." -ForegroundColor Cyan

    # Resolve the nginx host port. Try compose first; fall back to reading the
    # running container, which is authoritative when an override file was used.
    $frontPort = $null
    try {
        $portOut = Invoke-WithNativeStderr { (docker compose -f compose.prod.yaml port nginx 80 2>$null | Out-String).Trim() }
        if ($portOut -match ':(\d+)\s*$') { $frontPort = $Matches[1] }
    }
    catch { }
    if (-not $frontPort) {
        try {
            $insp = Invoke-WithNativeStderr { docker port pacgate-nginx 2>$null }
            foreach ($l in @($insp)) { if ($l -match ':(\d+)\s*$') { $frontPort = $Matches[1]; break } }
        }
        catch { }
    }
    if (-not $frontPort) { $frontPort = '8089' }  # documented default

    $versionUrl = "http://localhost:$frontPort/version"

    # Read the version compose pins, so the reported value is compared against
    # something rather than printed with nothing to check it against.
    $pinned = $null
    $pinnedRef = $null
    try {
        # -Encoding UTF8: PS 5.1 on a Chinese-locale host decodes BOM-less files as
        # ANSI/GBK; compose.prod.yaml carries Chinese comments.
        $composeTxt = Get-Content compose.prod.yaml -Raw -Encoding UTF8
        $m = [regex]::Match($composeTxt, '(?m)^\s*image:\s*(?<ref>ghcr\.io/[a-z0-9\-]+/pacgate-api:(?<v>\d+\.\d+\.\d+))\s*$')
        if ($m.Success) { $pinned = $m.Groups['v'].Value; $pinnedRef = $m.Groups['ref'].Value }
    }
    catch { }

    $reported = $null
    $revision = $null

    # Image identity, for the version-vs-content comparison below. Read AFTER the
    # pull (step 6), so $localTagId is what the tag points at NOW. The reference
    # comes from compose rather than being rebuilt here, so a namespace change
    # cannot silently make this check inspect a different image than the stack runs.
    $localTagId = $null
    $containerId = $null
    if ($Update -and $pinnedRef) {
        try {
            $localTagId = Invoke-WithNativeStderr { (docker inspect --format '{{.Id}}' $pinnedRef 2>$null | Out-String).Trim() }
            $containerId = Invoke-WithNativeStderr { (docker inspect --format '{{.Image}}' pacgate-api 2>$null | Out-String).Trim() }
        }
        catch { }
    }

    foreach ($attempt in 1..3) {
        try {
            $resp = Invoke-RestMethod -Uri $versionUrl -Method Get -TimeoutSec 5
            if ($resp.version) { $reported = $resp.version; $revision = $resp.revision; break }
        }
        catch { Start-Sleep -Seconds 3 }
    }

    if ($reported) {
        $rev = if ($revision -and $revision -ne 'unknown') { $revision.Substring(0, [Math]::Min(12, $revision.Length)) } else { 'unknown' }

        # REPORT THE REVISION EVEN WHEN THE VERSION MATCHES.
        #
        # This is the one case the version comparison CANNOT catch, and it is not
        # hypothetical - it is how the current release was cut. The version is
        # baked from CARGO_PKG_VERSION, which comes from the crate manifest, while
        # the revision comes from PAC_SOURCE_REVISION, which is the commit. If a
        # release ships without bumping Cargo.toml, a machine running the PREVIOUS
        # release and one running the new one both answer the same version, and
        # that comparison says OK. The revision is the only field that differs, so
        # it is printed here rather than buried.
        #
        # The install cannot resolve this on its own: knowing whether the tag
        # implies a rebuild is a decision about the workflow (whether it bumps the
        # manifest), and that is a repo property, not a machine property.
        if ($pinned -and $reported -ne $pinned) {
            # Pulled X, running Y. Not necessarily an error - the recreate may
            # still be in flight - but it is the exact condition that presents as
            # "the update did nothing".
            Write-Host "[WARN] Running pacgate-api is $reported but compose pins $pinned." -ForegroundColor Yellow
            Write-Host "       The container has not been recreated yet. If this persists:" -ForegroundColor Yellow
            Write-Host "         docker compose -f compose.prod.yaml up -d --force-recreate pacgate-api" -ForegroundColor Gray
        }
        elseif ($Update -and $localTagId -and $containerId -and $localTagId -ne $containerId) {
            # THE CASE A VERSION COMPARISON CANNOT SEE, and it is the one that
            # actually happened here (2026-10-13).
            #
            # A version is a NAME; a digest is the CONTENT. Re-publishing the same
            # version with a different build moves the digest without moving the
            # version, so "running 0.1.28, compose pins 0.1.28" reads OK while the
            # machine executes the previous build. That is exactly how the 0.1.28
            # OCR-weights-tag re-point worked: 50252862c826 -> b5ef2b12b8de, same
            # version string, different image. This box ran the old one through a
            # whole "-Update" that printed [OK], because the only comparison made
            # was on the version.
            #
            # $localTagId is re-read AFTER the pull, so a stale local tag is not
            # being compared against itself.
            Write-Host "[WARN] pacgate-api reports $reported, but the RUNNING container is not the image the tag now points to." -ForegroundColor Yellow
            Write-Host "       running  $($containerId.Substring(0,[Math]::Min(12,$containerId.Length)))" -ForegroundColor Gray
            Write-Host "       tag now  $($localTagId.Substring(0,[Math]::Min(12,$localTagId.Length)))" -ForegroundColor Gray
            Write-Host "       Same version, different build - a re-published tag. Recreate to apply:" -ForegroundColor Yellow
            Write-Host "         docker compose -f compose.prod.yaml up -d" -ForegroundColor Gray
        }
        else {
            Write-Host "[OK] pacgate-api reports $reported (source revision $rev)" -ForegroundColor Green
            if ($rev -eq 'unknown') {
                # A missing revision means the build arg was not passed, so this
                # machine cannot state which commit it runs. Report it as the gap
                # it is rather than letting 'unknown' read as a value.
                Write-Host "       NOTE: the revision is 'unknown', so this machine cannot confirm" -ForegroundColor Yellow
                Write-Host "             WHICH commit it is running - only which version string." -ForegroundColor Yellow
                Write-Host "             A rebuild of old source at a new tag is invisible here." -ForegroundColor Yellow
            }
        }
    }
    else {
        # TWO distinct causes, and conflating them sends people down the wrong
        # path. An old image predates /build-info entirely, in which case the
        # answer is "this install is behind", not "wait for startup".
        $img = Invoke-WithNativeStderr { (docker inspect pacgate-api --format '{{.Config.Image}}' 2>$null | Out-String).Trim() }
        Write-Host "[WARN] Could not read $versionUrl; skipping the staleness check." -ForegroundColor Yellow
        if ($img -match 'jzkk720|:0\.1\.[0-9]$') {
            Write-Host "       The running image is $img" -ForegroundColor Yellow
            Write-Host "       This image predates /version, so it cannot report its build." -ForegroundColor Yellow
        }
        else {
            Write-Host "       Expected while the stack is still starting." -ForegroundColor Yellow
        }
        Write-Host "       Check manually:  curl $versionUrl" -ForegroundColor Gray
    }
}

# 7f. Re-stage the qm runtime config from the tracked source.
#
# R2 in deploy/qm-pacgate/INTEGRATION-MAP.md, the largest remaining gap in the
# unattended-update goal. `setup-qm.ps1` stages deploy/qm-pacgate/ into this
# directory, and step 1 above refreshes the TRACKED copy on every -Update. But
# the RUNTIME copy is a different directory that nothing re-staged, so a qm
# config change reaching a deployed machine required re-running setup-qm.ps1 by
# hand - and that script prompts for admin email and bridge credentials, so it is
# not something to run unattended.
#
# There is a second, quieter consequence. `qm-sandbox-fingerprint.ps1` reads and
# writes the TRACKED qm.config.jsonc (its $qmDir is deploy/qm-pacgate), while qm
# actually RUNS the runtime copy. So the drift detector can report CURRENT while
# the config being executed is an older revision - the check inspects a different
# file than the one in play. Re-staging converges them, which is what makes the
# detector's answer meaningful.
#
# SAFE BY CONSTRUCTION:
#   - .env is EXCLUDED, so generated secrets are never overwritten.
#   - node_modules and .generated are excluded (machine-local, bulky, rebuildable).
#   - *.bak.* is excluded, so backups are not copied onto themselves.
#   - It copies FILES ONLY. No container is restarted and `qm up` is never run,
#     so the R4 contention between `qm up` and compose.qm.yaml cannot be triggered.
#
# A config change needs qm restarted to take effect, and that is deliberately
# left to the operator with the exact command printed - the same reasoning as
# step 7d's sandbox report. An unattended restart of a client's co-working stack
# is a worse failure than a precise instruction.
if ($Update) {
    $qmRuntime = Join-Path $PSScriptRoot 'qm-pacgate'
    $qmSource = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'deploy/qm-pacgate'

    if ((Test-Path $qmRuntime) -and (Test-Path $qmSource)) {
        Write-Host "`nRe-staging the qm runtime config from the tracked source..." -ForegroundColor Cyan

        $qmExclude = @('.env', 'node_modules', '.generated')
        $changed = @()
        $added = @()

        $tracked = Get-ChildItem -LiteralPath $qmSource -Recurse -File -Force | Where-Object {
            $rel = $_.FullName.Substring($qmSource.Length).TrimStart('\', '/')
            $top = ($rel -split '[\\/]')[0]
            ($qmExclude -notcontains $top) -and ($_.Name -notmatch '\.bak\.')
        }

        foreach ($f in $tracked) {
            $rel = $f.FullName.Substring($qmSource.Length).TrimStart('\', '/')
            $dest = Join-Path $qmRuntime $rel

            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

            if (Test-Path $dest) {
                # Compare CONTENT, not timestamps: a git checkout rewrites mtimes
                # on files whose bytes are identical, which would report every
                # file as changed on every update and bury the real change.
                $srcHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                $dstHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
                if ($srcHash -ne $dstHash) {
                    Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                    $changed += $rel
                }
            }
            else {
                Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                $added += $rel
            }
        }

        if ($changed.Count -eq 0 -and $added.Count -eq 0) {
            Write-Host "[OK] qm config already matches the tracked source" -ForegroundColor Green
        }
        else {
            if ($added.Count -gt 0) {
                Write-Host "  NEW tracked files staged: $($added -join ', ')" -ForegroundColor Yellow
            }
            if ($changed.Count -gt 0) {
                Write-Host "  UPDATED (were stale on this machine): $($changed -join ', ')" -ForegroundColor Yellow
            }
            Write-Host "  [ACTION] qm must be restarted to pick these up. It is NOT restarted" -ForegroundColor Yellow
            Write-Host "           automatically: an unattended restart of the co-working" -ForegroundColor Yellow
            Write-Host "           stack is not something to do blind. To apply now:" -ForegroundColor Yellow
            Write-Host "             cd qm-pacgate" -ForegroundColor Gray
            Write-Host "             docker compose -f compose.qm.yaml restart" -ForegroundColor Gray
            Write-Host "           Do NOT also run 'qm up' in the same directory - both paths" -ForegroundColor Yellow
            Write-Host "           contend for the same volumes and network (R4)." -ForegroundColor Yellow
        }

        # Secrets are preserved by design; say so, because "re-staged" could
        # otherwise read as "rese t".
        if (Test-Path (Join-Path $qmRuntime '.env')) {
            Write-Host "  (.env preserved - generated qm secrets are left untouched)" -ForegroundColor Gray

            # Additive repair of a NON-SECRET key that the re-stage cannot supply.
            #
            # The staged compose.qm.yaml now derives six browser-facing OAuth URLs
            # from ${QM_PUBLIC_URL:-http://localhost:8181}. A machine installed
            # before that key existed has no QM_PUBLIC_URL in .env, so compose
            # falls back to localhost - and because OAuth is a BROWSER redirect,
            # remote users are sent to their own loopback and can never sign in.
            #
            # This is the same trap as GATEWAY_CORS_ORIGINS above: a correct
            # tracked default does nothing on a machine whose generated file was
            # written by an older release. -Update re-stages config but does NOT
            # run setup-qm.ps1 (which is interactive), so without this the fix
            # would reach AIPC 1 and AIPC 2 as dead config. The key is not a
            # secret and is not bound to any volume, so it is safe to add here.
            $qmEnvPath = Join-Path $qmRuntime '.env'
            $qmEnvRaw = [System.IO.File]::ReadAllText($qmEnvPath)
            if ($qmEnvRaw -match '(?m)^\s*QM_PUBLIC_URL\s*=') {
                Write-Host "  [OK] QM_PUBLIC_URL already set (browser-facing OAuth origin)" -ForegroundColor Green
            }
            else {
                $qmHostName = try { ([System.Net.Dns]::GetHostName()).ToLower() } catch { 'localhost' }
                if ([string]::IsNullOrWhiteSpace($qmHostName)) { $qmHostName = 'localhost' }
                $qmUrl = "http://${qmHostName}:8181"
                $nl = if ($qmEnvRaw.Length -eq 0 -or $qmEnvRaw.EndsWith("`n")) { '' } else { "`r`n" }
                [System.IO.File]::AppendAllText(
                    $qmEnvPath,
                    "$nl" + "QM_PUBLIC_URL=$qmUrl`r`n",
                    [System.Text.UTF8Encoding]::new($false)
                )
                Write-Host "  [OK] Added QM_PUBLIC_URL=$qmUrl to the qm .env" -ForegroundColor Green
                Write-Host "       Without it the OAuth issuer advertised localhost, so signing in" -ForegroundColor Gray
                Write-Host "       from any other computer redirected to that computer instead." -ForegroundColor Gray
            }
        }
    }
    elseif ((Test-Path $qmRuntime) -and -not (Test-Path $qmSource)) {
        Write-Host "`n[WARN] qm is deployed but the tracked source is missing:" -ForegroundColor Yellow
        Write-Host "       $qmSource" -ForegroundColor Yellow
        Write-Host "       Refusing to re-stage; the runtime config is left as it is." -ForegroundColor Yellow
    }
}

# 7g. Bring up qm (Runtime 3) on a FIRST install.
#
# WHY THIS IS NEW. Until 2026-10-03 the installer deliberately never started qm -
# every qm step only re-staged config and printed an instruction, because qm was
# an optional side-lane. The deployment model is now "every AIPC runs all three
# runtimes", so leaving qm down means the installer ships a stack that is missing
# a third of its product.
#
# WHY ONLY ON FIRST INSTALL, NOT -Update. A restart of the co-working stack is
# user-visible (qm is where staff work), and the R4 contention between `qm up` and
# compose.qm.yaml means an automated path has to pick one and be right. On a FIRST
# install nobody is mid-session, so there is nothing to interrupt; on -Update the
# operator may be in it. -Update therefore keeps the existing print-the-command
# behaviour, and this block only runs when the stack is not already up.
#
# The bridge is a SEPARATE, least-privilege service account. It is NOT the
# deployment's own PACGATE_API_EMAIL: the sandbox runs model-directed tool calls,
# so it gets its own attorney-scoped credential. Because self-registration is
# first-user-only, this block provisions that account through POST /api/auth/users
# using the admin the installer bootstrapped in step 6a.
if (-not $Update) {
    $qmDir  = Join-Path $PSScriptRoot 'qm-pacgate'
    $qmRuntimeEnv = Join-Path $qmDir '.env'
    $qmSetup = Join-Path $PSScriptRoot 'setup-qm.ps1'

    Write-Host "`nBringing up qm (Runtime 3 - co-working workspace)..." -ForegroundColor Cyan

    # Detect a RUNNING STACK, not the presence of a directory.
    #
    # The first attempt tested `Test-Path $qmDir` and treated "the directory does
    # not exist" as "this is a first install". That is a different question, and it
    # is the wrong one twice over:
    #   * the directory is created by setup-qm.ps1 when it stages, so bootstrap and
    #     staging were the same branch - meaning the stage-only path below could
    #     never run, and the bridge identity would never be written;
    #   * `docker ps | Select-String 'qm-'` counts CONTAINERS, and the substring
    #     also matches `qm-mailpit`, so a lone mailpit container reported "qm is
    #     already running" and skipped everything.
    # Ask the actual question: has qm been bootstrapped AND is it up?
    $qmRunning = @(Invoke-WithNativeStderr { docker ps --filter 'name=qm-pacgate-' --format '{{.Names}}' 2>$null }).Count -ge 6
    if ($qmRunning) {
        Write-Host "[OK] qm is already running - left untouched" -ForegroundColor Green
    }
    elseif (-not (Test-Path $qmSetup)) {
        Write-Host "[WARN] setup-qm.ps1 not found; skipping Runtime 3." -ForegroundColor Yellow
    }
    else {
        # Two INDEPENDENT questions, deliberately not nested:
        #   (1) does the bridge account need creating? (bootstrap - needs an admin)
        #   (2) does the qm runtime config need staging? (setup-qm.ps1, stage only)
        # The first attempt answered both from `$qmDir exists`, which conflated them
        # and made the 409 recovery path unreachable (it looked for an `.env` that
        # could not exist in a branch that only ran when the directory did not).
        $needsBootstrap = -not (Test-Path $qmRuntimeEnv)
        $bridgeEmail = 'qm-bridge@pacgate.local'
        $bridgePass  = ''
        $bridgeReady = $false

        $qmAdmin     = if ($envVars.ContainsKey('PACGATE_API_EMAIL'))    { $envVars['PACGATE_API_EMAIL'] }    else { '' }
        $qmAdminPass = if ($envVars.ContainsKey('PACGATE_API_PASSWORD')) { $envVars['PACGATE_API_PASSWORD'] } else { '' }

        if ($needsBootstrap) {
            # The bridge is a SEPARATE, least-privilege service account, per the
            # deployment handbooks ("Pacgate bridge - a service account in
            # pacgate-api, used by the sandbox tool"). The sandbox runs
            # model-directed tool calls, so it gets its own attorney-scoped
            # credential instead of the deployment's own identity.
            #
            # Provisioning it needs an administrator, so this block:
            #   1. logs in as the admin the installer just bootstrapped,
            #   2. creates the bridge account via POST /api/auth/users (the route
            #      that exists precisely because self-registration is
            #      first-user-only),
            #   3. hands the credential to setup-qm.ps1 below.
            # If any step fails it says so and leaves Runtime 3 to a manual run
            # rather than guessing a credential, because a wrong bridge password
            # surfaces much later as a 401 inside a sandbox tool call.
            if (-not $qmAdmin -or -not $qmAdminPass) {
                Write-Host "[WARN] PACGATE_API_EMAIL / PACGATE_API_PASSWORD are not set in .env -" -ForegroundColor Yellow
                Write-Host "       cannot provision the bridge account. Run .\setup-qm.ps1 by hand." -ForegroundColor Yellow
            }
            else {
                Write-Host "  provisioning the qm bridge account ('$bridgeEmail')..." -ForegroundColor Gray
                $BaseUrl = 'http://localhost:8089/pacgate'
                try {
                    $loginBody = @{ email = $qmAdmin; password = $qmAdminPass } | ConvertTo-Json -Compress
                    $login = Invoke-RestMethod -Uri "$BaseUrl/api/auth/login" -Method Post `
                        -Body $loginBody -ContentType 'application/json' -TimeoutSec 20
                    $tok = $login.token
                    if (-not $tok) { throw "login returned no token" }

                    # 32 bytes of CSPRNG hex, byte-for-byte the same construction as
                    # setup-qm.ps1's New-SecretHex.
                    #
                    # NOT inlined as a clever one-liner. The first attempt here was
                    # `-join ((New-Object byte[] 32) | ForEach-Object { RNG.GetBytes($_); $_ } |
                    # ForEach-Object { $_.ToString('x2') })`, which looked reasonable
                    # and produced SIXTY-FOUR ZEROS - the pipeline bound the byte
                    # array as a single item, so it was never filled element-wise and
                    # `.ToString('x2')` on the array yielded "0" repeated. That would
                    # have silently set a fixed all-zero bridge password. Verified by
                    # running it, not by reading it.
                    $rngBytes = New-Object byte[] 32
                    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rngBytes)
                    $bridgePass = -join ($rngBytes | ForEach-Object { $_.ToString('x2') })
                    if ($bridgePass.Length -ne 64 -or $bridgePass -match '^0+$') {
                        # Refuse to ship a credential that failed to generate. An
                        # all-zero or short password is indistinguishable from a
                        # working one until an authentication fails elsewhere.
                        throw "bridge password generation produced an invalid value (length $($bridgePass.Length))"
                    }

                    $hdr = @{ Authorization = "Bearer $tok" }
                    $createBody = @{ email = $bridgeEmail; password = $bridgePass; role = 'attorney' } | ConvertTo-Json -Compress
                    try {
                        Invoke-RestMethod -Uri "$BaseUrl/api/auth/users" -Method Post -Headers $hdr `
                            -Body $createBody -ContentType 'application/json' -TimeoutSec 20 | Out-Null
                        Write-Host "  [OK] bridge account created" -ForegroundColor Green
                        $bridgeReady = $true
                    }
                    catch {
                        # 409 = the account already exists, which is not an error
                        # (re-running the installer is expected) but also means the
                        # stored password is unknown. A NEW password must not be
                        # written to .env for it, or the account and the config
                        # would disagree - so this is reported, not papered over.
                        #
                        # `?.` is PS7-only and install.ps1 must parse under the
                        # Windows built-in PowerShell 5.1 too (the AIPC runbook
                        # invokes .\install.ps1 without a pwsh prerequisite, and
                        # a parse error kills the whole installer). Expand it
                        # for both PS 5.1 and 7+: a DNS failure,
                        # connection-refused, or timeout leaves Response null;
                        # without the null guard the property access throws and
                        # the operator sees a null-reference error instead of
                        # the transport failure.
                        $code = $null
                        if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
                        if ($code -eq 409) {
                            Write-Host "  [OK] bridge account already exists" -ForegroundColor Green
                            Write-Host "       its password is whatever was set when it was created." -ForegroundColor Gray
                            Write-Host "       setup-qm.ps1 will prompt for it below." -ForegroundColor Gray
                        }
                        elseif ($null -eq $code) {
                            throw "could not reach $BaseUrl (transport failure, not a duplicate)"
                        }
                        else {
                            throw "create_user returned HTTP $code"
                        }
                    }
                }
                catch {
                    # `ErrorDetails.Message` carries the API's JSON body; for an
                    # HTTP error, `Exception.Message` is only
                    # "Response status code does not indicate success: 401 ...".
                    # The whole premise of this work is that the admin previously
                    # was not an admin, so a 401/403 here is the LIKELIEST first
                    # failure and the operator needs the reason, not the status.
                    $detail = $_.ErrorDetails.Message
                    if (-not $detail) { $detail = $_.Exception.Message }
                    Write-Host "[WARN] could not provision the bridge account: $detail" -ForegroundColor Yellow
                    Write-Host "       Runtime 3 will need '.\setup-qm.ps1' run by hand." -ForegroundColor Yellow
                }
            }
        }

        # Stage + start. setup-qm.ps1 is called in BOTH cases, because it owns the
        # staging into $qmDir - so on a first install this is also what creates the
        # directory. It is idempotent: with an .env present it preserves it and only
        # refreshes the tracked definition files, which is exactly the re-stage the
        # -Update path documents.
        $setupArgs = @('-NoProfile', '-File', $qmSetup, '-AdminEmail', $qmAdmin)
        if ($bridgeReady) {
            $setupArgs += @('-BridgeEmail', $bridgeEmail, '-BridgePassword', $bridgePass)
        }
        try {
            if ($bridgeReady) {
                Write-Host "  staging + bootstrapping qm (bridge=$bridgeEmail)..." -ForegroundColor Gray
            }
            else {
                Write-Host "  staging qm (bridge credentials must be entered when prompted)..." -ForegroundColor Gray
            }
            & $QmPowerShell @setupArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[WARN] setup-qm.ps1 exited $LASTEXITCODE - Runtime 3 may not be up." -ForegroundColor Yellow
                Write-Host "       Re-run it by hand to see the error in full." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "[WARN] setup-qm.ps1 failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Start it. `docker compose` and NOT `qm up`: the CLI's which() shells out
        # to POSIX /bin/sh, which does not exist on native Windows, so `qm up`
        # cannot run on an AIPC at all. compose bypasses that entirely and is the
        # path the project already uses (plans/010 migrated to it for this reason).
        # R4 is respected by picking exactly ONE path - compose - and never mixing.
        if (Test-Path (Join-Path $qmDir 'compose.qm.yaml')) {
            # External network/volumes are declared `external: true`, so they must
            # exist before compose will start; compose does not create them.
            Invoke-WithNativeStderr { docker network create qm-pacgate *>$null }
            Invoke-WithNativeStderr { docker volume create qm-pacgate-coredata *>$null }
            Invoke-WithNativeStderr { docker volume create qm-pacgate-pgdata *>$null }

            Push-Location $qmDir
            try {
                docker compose -f compose.qm.yaml up -d
                if ($LASTEXITCODE -eq 0) {
                    Start-Sleep -Seconds 15
                    # Same container filter as the guard above: `qm-pacgate-` counts
                    # the six stack services and excludes qm-mailpit.
                    $qmUp = @(Invoke-WithNativeStderr { docker ps --filter 'name=qm-pacgate-' --format '{{.Names}}' 2>$null }).Count
                    if ($qmUp -ge 6) {
                        Write-Host "[OK] qm running ($qmUp containers)" -ForegroundColor Green
                    }
                    else {
                        Write-Host "[WARN] only $qmUp qm container(s) up (expected 6)." -ForegroundColor Yellow
                        Write-Host "       A crash-looping container is usually a config value:" -ForegroundColor Yellow
                        Write-Host "         docker logs qm-pacgate-auth --tail 30" -ForegroundColor Gray
                    }
                }
                else {
                    Write-Host "[WARN] 'docker compose -f compose.qm.yaml up -d' exited $LASTEXITCODE." -ForegroundColor Yellow
                }
            }
            finally { Pop-Location }
        }
        else {
            Write-Host "[WARN] qm was not staged ($qmDir\compose.qm.yaml is missing) - Runtime 3 is NOT up." -ForegroundColor Yellow
            Write-Host "       Run .\setup-qm.ps1 by hand, then: cd qm-pacgate; docker compose -f compose.qm.yaml up -d" -ForegroundColor Yellow
        }
    }
}

# 8. Wait for health
Write-Host "`nWaiting for services to start..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

# 9. Show status
Write-Host "`n=== Status ===" -ForegroundColor Cyan
docker compose -f compose.prod.yaml ps

Write-Host "`n=== Pacgate-ai is running ===" -ForegroundColor Green
Write-Host "Open browser to: http://localhost:8089" -ForegroundColor White
Write-Host "  /          - Landing page" -ForegroundColor Gray
Write-Host "  /api/      - Metadata API (internal)" -ForegroundColor Gray
Write-Host "  /research/  - Legal research (deer-flow)" -ForegroundColor Gray
Write-Host ""
# This block described qm as a manual, separate step. Step 7g now brings it up on
# a first install, so telling the operator to run anything by hand is stale - and
# it was wrong twice over: `qm up` cannot run on Windows (its which() shells out to
# POSIX /bin/sh), and 8182 is the web-ui, not the sign-in front door. Both mistakes
# sent the reader somewhere that does not work. Describe what actually happened
# instead of prescribing steps the installer already took.
Write-Host "QM (co-working workspace):" -ForegroundColor Cyan
if (Test-Path (Join-Path $PSScriptRoot 'qm-pacgate/compose.qm.yaml')) {
    $qmCount = @(Invoke-WithNativeStderr { docker ps --filter 'name=qm-pacgate-' --format '{{.Names}}' 2>$null }).Count
    if ($qmCount -ge 6) {
        Write-Host "  Running ($qmCount containers). Sign in at http://localhost:8181" -ForegroundColor Gray
        Write-Host "  (8181 is the portal FRONT DOOR - it proxies to web-ui 8182 and" -ForegroundColor Gray
        Write-Host "   admin 8183. Opening 8182 directly skips auth.)" -ForegroundColor Gray
    }
    else {
        Write-Host "  NOT running ($qmCount of 6 containers up). To bring it up:" -ForegroundColor Yellow
        Write-Host "    cd qm-pacgate" -ForegroundColor Gray
        Write-Host "    docker compose -f compose.qm.yaml up -d" -ForegroundColor Gray
        Write-Host "  Do NOT use 'qm up' - it needs a POSIX shell and cannot run here." -ForegroundColor Yellow
    }
}
else {
    Write-Host "  Not staged. Run .\setup-qm.ps1, then:" -ForegroundColor Yellow
    Write-Host "    cd qm-pacgate; docker compose -f compose.qm.yaml up -d" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Manage:" -ForegroundColor Cyan
Write-Host "  docker compose -f compose.prod.yaml logs -f    (view logs)" -ForegroundColor Gray
Write-Host "  docker compose -f compose.prod.yaml down       (stop)" -ForegroundColor Gray
Write-Host "  .\install.ps1 -Update                            (update to new version)" -ForegroundColor Gray