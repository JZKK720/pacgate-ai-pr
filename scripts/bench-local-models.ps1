# Benchmark the LOCAL Ollama models the AIPC stack can be asked to run, and
# report the numbers that decide the roster: resident footprint, prefill rate,
# decode rate, and whether the runner actually stayed on the GPU.
#
# WHY THIS EXISTS (2026-11-04)
#
# The recurring question is "should the workflow tiers use a bigger local model
# than gemma4:12b?" It keeps getting answered from model names and vendor card
# copy, so the answers disagree with each other and none of them can be re-run.
# Three specific claims were being asserted without measurement:
#
#   1. "12b is the bottleneck"          -> is its DECODE rate the limit, or is
#                                          the limit prefill/VRAM/load time?
#   2. "30-35b has longer ctx memory"   -> every candidate on this box reports
#                                          the same native 262144 ctx. Compare
#                                          the KV COST per token instead, which
#                                          is what actually differs.
#   3. "bigger models infer faster"     -> only true for MoE with a small
#                                          active-expert count, and only while
#                                          the weights are resident. Measure it.
#
# SCOPE, stated plainly because a benchmark that overstates itself is worse
# than none:
#   - It measures THIS box. Absolute numbers are not a client-AIPC spec; the
#     RANKING and the fit verdict are what transfer.
#   - One runner slot. Lanes run sequentially, never in parallel - a concurrent
#     chat starves the measured lane (same constraint as run-benchmark.ps1).
#   - A model that does not fit the card is still measured, but the report says
#     so, because "fast on a spilled runner" is not a result you can ship.
#   - Anything unmeasurable is CANNOT CHECK with a reason, never a pass.
#
# Usage:
#   pwsh -File scripts/bench-local-models.ps1
#   pwsh -File scripts/bench-local-models.ps1 -Markdown > deploy/BENCHMARK-LOCAL-<date>.md
#   pwsh -File scripts/bench-local-models.ps1 -Models ornith-1.5:35b -LongCtx 8192
[CmdletBinding()]
param(
    [string]$OllamaUrl = 'http://localhost:11434',

    # Candidates. Default is the shipped roster plus every larger tag present on
    # this box, so a regression run compares like with like.
    [string[]]$Models = @(
        'gemma4:12b-it-qat',
        'ornith-1.5:9b',
        'qwen3.8:27b-mtp-q4_K_M',
        'ornith-1.5:35b'
    ),

    # Tokens to generate per decode probe. 128 is enough to average out the
    # first-token cost without making a 22 GB spilled model take all afternoon.
    [int]$DecodeTokens = 128,

    # Long-context prefill probe. Prefill rate is measured at this depth because
    # a legal workflow step ingests whole documents, not chat-sized prompts.
    [int]$LongCtx = 8192,

    # Smallest supported client GPU. Mirrors test-aipc-capacity-fit.ps1.
    [double]$AipcVramGB = 16,

    # Floor for free physical RAM after a load. Below roughly this, Windows
    # starts paging the working set and the desktop becomes unresponsive long
    # before anything reports an error - the 2026-11-04 freeze. Overridable for a
    # box being used only for the benchmark.
    [double]$MinHeadroomGB = 4,

    [switch]$Markdown
)

$ErrorActionPreference = 'Continue'

# `pwsh -File script.ps1 -Models a,b` hands the whole comma list over as ONE
# string, unlike -Command which parses it into an array. Split here so both
# invocation styles work and a mistyped separator cannot silently benchmark a
# single nonsense tag name.
$Models = @($Models | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# A model whose weights exceed the card cannot be resident, so Ollama spills
# layers to CPU. That is not a fast path, whatever the tok/s says afterwards.
$ComfortRatio = 0.75

function Get-OllamaShow([string]$Model) {
    $body = @{ model = $Model } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$OllamaUrl/api/show" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 60
}

function Get-ModelArchitecture([string]$Model) {
    $show = Get-OllamaShow $Model
    $mi = $show.model_info
    if (-not $mi) { return $null }

    $fam = ($mi.PSObject.Properties.Name |
        Where-Object { $_ -notlike 'general.*' -and $_ -notlike 'tokenizer.*' -and $_ -notlike 'quantize.*' } |
        ForEach-Object { ($_ -split '\.')[0] } |
        Select-Object -Unique | Select-Object -First 1)

    # Deliberately NOT `Select-Object -First 1`: several of these fields are
    # per-layer ARRAYS (gemma4 ships 48 head_count_kv entries and a 48-entry
    # sliding_window_pattern). Taking the first element silently turns a hybrid
    # stack into a fully-dense one and overstates its KV cache by ~47x, which is
    # how "12b has a short context" gets asserted from a spreadsheet.
    function Field([string]$key) {
        ($mi.PSObject.Properties | Where-Object { $_.Name -eq "$fam.$key" }).Value
    }

    $blocks  = Field 'block_count'
    $kvHeads = Field 'attention.head_count_kv'
    $keyLen  = Field 'attention.key_length'
    $valLen  = Field 'attention.value_length'
    $ctxMax  = Field 'context_length'
    $experts = Field 'expert_count'
    $active  = Field 'expert_used_count'
    # nemotron_h_moe does not declare `expert_used_count`; it declares grouped
    # activation (`expert_group_used_count`) and publishes the active parameter
    # count in `size_label` as e.g. "345x8.1B". Falling back to the group count
    # would print "1/496" and read as a typo, so derive the active share from the
    # size label and keep the group count as a note.
    $activeLabel = ''
    $sizeLabel = ($mi.'general.size_label' | Select-Object -First 1)
    if (-not $active -or [int](@($active)[0]) -le 1) {
        if ($sizeLabel -match '(\d+)\s*x\s*([\d.]+)\s*B') {
            $activeLabel = "$($Matches[2])B active"
        }
    }
    $swa     = Field 'attention.sliding_window'

    $kvList = @()
    if ($kvHeads -is [array]) { $kvList = $kvHeads } elseif ($kvHeads) { $kvList = @($kvHeads) }

    # Two distinct hybrid mechanisms, and getting either wrong makes a hand-built
    # KV table badly misleading - which is exactly how "12b has a short context"
    # got asserted in the first place:
    #
    #   qwen3.5+ style: `full_attention_interval = N`. Only every Nth layer keeps
    #   a growing attention cache; the rest are SSM/Gated-DeltaNet with a FIXED
    #   state that does not scale with context. Costing all N layers overstates
    #   the model by roughly the interval.
    #
    #   gemma4 style: `sliding_window_pattern`. Most layers only ever attend to
    #   the last `sliding_window` tokens, so their cache stops growing at the
    #   window. Only the occasional full-attention layer grows with context.
    #
    # Costing per layer needs a per-layer head count, so a scalar head_count_kv
    # is expanded to one entry per block.
    $interval = Field 'full_attention_interval'
    $swPattern = Field 'attention.sliding_window_pattern'
    $window   = if ($swa) { [int](@($swa)[0]) } else { 0 }

    if ($kvList.Count -eq 1 -and $blocks -and [int](@($blocks)[0]) -gt 1) {
        $kvList = @(1..([int](@($blocks)[0])) | ForEach-Object { $kvList[0] })
    }
    $swList = @()
    if ($swPattern) {
        $swRaw = if ($swPattern -is [array]) { $swPattern } else { "$swPattern" -split ',' }
        $swList = @($swRaw | ForEach-Object { "$_".Trim() })
    }

    # Key/value width can be scalar or per-layer too.
    $klList = if ($keyLen -is [array]) { @($keyLen) } elseif ($keyLen) { @([int]$keyLen) } else { @() }
    $vlList = if ($valLen -is [array]) { @($valLen) } elseif ($valLen) { $klList } else { @() }

    # Per-token KV cost in elements (f16) at a context comfortably past the
    # sliding window, i.e. the steady-state marginal cost per extra token.
    $kvPerToken = 0
    $fullLayers = 0
    $windowLayers = 0
    if ($kvList.Count -gt 0 -and $klList.Count -gt 0) {
        for ($i = 0; $i -lt $kvList.Count; $i++) {
            $h = [int]$kvList[$i]
            if ($h -le 0) { continue }
            $kl = [int]$klList[[math]::Min($i, $klList.Count - 1)]
            $vl = if ($vlList.Count -gt 0) { [int]$vlList[[math]::Min($i, $vlList.Count - 1)] } else { $kl }

            if ($swList.Count -gt $i -and $swList[$i] -eq 'True') {
                # Sliding-window layer: cache saturates at the window, so its
                # marginal cost per token past the window is zero.
                $windowLayers++
                continue
            }
            if ($interval -and [int](@($interval)[0]) -gt 1) {
                $isFull = (($i % [int](@($interval)[0])) -eq ([int](@($interval)[0]) - 1))
                if (-not $isFull) { continue }
            }
            $kvPerToken += $h * ($kl + $vl)
            $fullLayers++
        }
    }

    # SSM / linear-attention layers keep a FIXED recurrent state instead of a
    # KV cache. It does not scale with context, so it is not a per-token cost -
    # but it is real VRAM and it is why a "0 KB/token" model is not free.
    #
    #   state = blocks x groups x (state_size*dim + conv_kernel*dim) x 4 bytes
    #
    # dim per group = inner_size / group_count. Reported separately so the
    # table never implies nemotron costs nothing for context.
    $ssmStateMB = 0
    $ssmGroups  = Field 'ssm.group_count'
    $ssmInner   = Field 'ssm.inner_size'
    $ssmState   = Field 'ssm.state_size'
    $ssmConv    = Field 'ssm.conv_kernel'
    if ($ssmGroups -and $ssmInner -and $ssmState -and $blocks) {
        $dimPerGroup = [double]$ssmInner / [double]$ssmGroups
        $convPart    = if ($ssmConv) { [double]$ssmConv * $dimPerGroup } else { 0 }
        $ssmLayers   = if ($interval -and [int](@($interval)[0]) -gt 1) { [int](@($blocks)[0]) - $fullLayers } else { [int](@($blocks)[0]) }
        $bytes = $ssmLayers * [double]$ssmGroups * ([double]$ssmState * $dimPerGroup + $convPart) * 4
        $ssmStateMB = [math]::Round($bytes / 1MB, 0)
    }

    [pscustomobject]@{
        Model        = $Model
        Family       = $fam
        ParamsB      = [math]::Round(([double](@($mi.'general.parameter_count')[0])) / 1e9, 1)
        Quant        = $show.details.quantization_level
        ContextMax   = $ctxMax
        Blocks       = [int](@($blocks)[0])
        FullLayers   = $fullLayers
        Experts      = if ($activeLabel) { $activeLabel }
                       elseif ($experts -and $active) { "$([int](@($active)[0]))/$([int](@($experts)[0]))" }
                       elseif ($experts) { "moe/$([int](@($experts)[0])) experts" }
                       else { 'dense' }
        ExpertsLabel = $activeLabel
        ActiveExperts= if ($active) { [int](@($active)[0]) } else { 0 }
        KvPerTokenKB = [math]::Round($kvPerToken * 2 / 1KB, 1)
        KvAtLongCtxGB= [math]::Round($kvPerToken * 2 * $LongCtx / 1GB, 2)
        SlidingWindow= $window
        WindowLayers = $windowLayers
        SsmStateMB   = $ssmStateMB
        Capabilities = ($show.capabilities -join ',')
    }
}

function Get-OllamaPs {
    try {
        $ps = Invoke-RestMethod -Uri "$OllamaUrl/api/ps" -TimeoutSec 15
        return $ps.models
    }
    catch { return @() }
}

# ---------------------------------------------------------------------------
# Host-memory safety.
#
# WHY THIS EXISTS (measured 2026-11-04, after the box became unresponsive
# mid-run and had to be restarted twice).
#
# A benchmark that walks big models back to back can commit more RAM than the
# machine has, and Windows does not fail the allocation - it degrades into a
# frozen desktop while the GPU still looks healthy. That is the same signature
# already recorded in scripts/test-host-memory-budget.ps1 ("the discrete card
# held 6.4 GiB free while the HOST had 0.03 MB available and 71.1 GB committed"),
# and this script reproduced it.
#
# The specific arithmetic that did it, on a 61.6 GB box:
#
#   74b-a9b-iq2 resident        24.8 GB   (weights on disk)
#   lightning:30b-a3b resident  23.7 GB   (loaded next, before eviction)
#   transient double residency  48.5 GB   <- both held at once
#   + WSL2/Docker VM            24.0 GB
#   --------------------------------
#   committed                   72.5 GB   on 61.6 GB of physical RAM
#
# Two fixes, because either alone is insufficient:
#
#   1. UNLOAD before each model, so the outgoing weights are released before
#      the incoming ones are faulted in. This is what removes the spike.
#   2. REFUSE to start a model that cannot co-exist with the WSL VM and the
#      current commit charge. This is what stops a future tag from silently
#      doing the same thing again.
#
# Neither of these is a VRAM check. VRAM fit is test-aipc-capacity-fit.ps1's
# job; a model can fit the card perfectly and still exhaust host RAM.
# ---------------------------------------------------------------------------

function Clear-OllamaModel([string]$Model) {
    # keep_alive:0 unloads immediately. Ollama normally holds a runner for 5m,
    # which is exactly the window in which the NEXT model loads on top of it.
    try {
        $body = @{ model = $Model; prompt = ''; keep_alive = 0 } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 60 | Out-Null
    }
    catch { }
    # Poll rather than sleep a fixed time: the runner is gone when it is gone.
    for ($i = 0; $i -lt 15; $i++) {
        $still = (Get-OllamaPs) | Where-Object { $_.name -eq $Model }
        if (-not $still) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

function Clear-AllOllamaModels {
    $resident = @(Get-OllamaPs | Where-Object { $_.name })
    if ($resident.Count -eq 0) { return $true }   # nothing to do is a success
    $allGone = $true
    foreach ($r in $resident) {
        if (-not (Clear-OllamaModel $r.name)) { $allGone = $false }
    }
    return $allGone
}

function Get-HostMemory {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $commitGB = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1)
    [pscustomobject]@{ TotalGB = $totalGB; FreeGB = $freeGB; CommitGB = $commitGB }
}

function Get-WslVmGB {
    # The WSL2 VM (which is what Docker Desktop runs in) can grow to its ceiling
    # and does not shrink promptly. It is invisible to a naive "free RAM" check
    # because it is already committed before the first model loads.
    $p = Get-Process vmmemWSL -ErrorAction SilentlyContinue
    if (-not $p) { return 0 }
    [math]::Round(($p | Measure-Object WorkingSet64 -Sum).Sum / 1GB, 1)
}

# Refuse to launch a model that cannot fit in the RAM actually available.
#
# METRIC, and why the obvious one is wrong: Windows "commit charge" is NOT a
# memory-pressure signal. It is backed by a 58 GB pagefile here, so it routinely
# sits at 55+ GiB on a 61.6 GiB box with plenty of usable RAM. Comparing commit
# against physical RAM refuses everything, including models that demonstrably
# run. The signal that predicts a freeze is FREE PHYSICAL RAM falling to zero -
# that is what the 2026-10-21 incident recorded (0.03 MB available), and it is
# what this check uses.
function Assert-ModelFitsHost([string]$Model, [double]$WeightGB) {
    $mem = Get-HostMemory
    $wsl = Get-WslVmGB
    $afterLoad = $mem.FreeGB - $WeightGB

    Write-Host ("  host RAM: total={0} GiB free={1} GiB committed={2} GiB (pagefile-backed) wslVM={3} GiB" -f `
        $mem.TotalGB, $mem.FreeGB, $mem.CommitGB, $wsl)
    Write-Host ("  loading {0} GiB leaves {1:N1} GiB free (headroom target {2} GiB)" -f `
        $WeightGB, $afterLoad, $MinHeadroomGB)

    # Two tiers, calibrated against what was actually observed on this box rather
    # than picked to be safely conservative in one direction:
    #
    #   REFUSE  weights exceed available RAM. The load cannot be mapped and will
    #           page continuously. Observed: 74b-a9b-iq2 (24.8 GB) against
    #           11.7 GiB free thrashed and then froze the desktop.
    #   WARN    weights fit but leave under the headroom target. It will run, and
    #           it may run WELL, because the weights are mmap'd and unused pages
    #           are evictable. Observed: e4b-q8_0 (9.76 GB) at 11.7 GiB free hit
    #           97 tok/s. Refusing this would have hidden the best candidate.
    if ($WeightGB -gt $mem.FreeGB) {
        Write-Host ("  [REFUSED] {0:N1} GiB of weights will not fit in {1:N1} GiB of available RAM." -f `
            $WeightGB, $mem.FreeGB) -ForegroundColor Red
        Write-Host ("            Free RAM (stop containers, close editors) or benchmark this tag alone.") -ForegroundColor Red
        return $false
    }
    if ($afterLoad -lt $MinHeadroomGB) {
        Write-Host ("  [warn] only {0:N1} GiB would remain free; this tag will page and its numbers are a floor." -f `
            $afterLoad) -ForegroundColor Yellow
    }
    return $true
}

# One measured generation. Returns the raw Ollama counters so the report can
# derive rates rather than quote a wall clock that includes a cold weight load.
function Invoke-Probe {
    param(
        [string]$Model,
        [string]$Prompt,
        [int]$NumPredict,
        [int]$NumCtx,
        [string]$Label
    )
    $body = @{
        model   = $Model
        prompt  = $Prompt
        stream  = $false
        options = @{ num_predict = $NumPredict; num_ctx = $NumCtx; temperature = 0 }
        # Bounded hold. Ollama's default 5m keep-alive is what lets the NEXT
        # model load on top of this one; the loop explicitly unloads anyway, but
        # a crash mid-run should not leave 20+ GB pinned for five minutes.
        keep_alive = '2m'
    } | ConvertTo-Json -Depth 5 -Compress

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 3600
        $sw.Stop()

        $loadMs   = [math]::Round($r.load_duration / 1e6, 0)
        $promptMs = [math]::Round($r.prompt_eval_duration / 1e6, 0)
        $evalMs   = [math]::Round($r.eval_duration / 1e6, 0)
        $decode   = if ($evalMs -gt 0) { [math]::Round($r.eval_count / ($evalMs / 1000), 2) } else { 0 }
        $prefill  = if ($promptMs -gt 0) { [math]::Round($r.prompt_eval_count / ($promptMs / 1000), 1) } else { 0 }

        [pscustomobject]@{
            Label        = $Label
            Model        = $Model
            Status       = 'OK'
            LoadMs       = $loadMs
            PromptTokens = $r.prompt_eval_count
            PromptMs     = $promptMs
            PrefillTokS  = $prefill
            EvalTokens   = $r.eval_count
            EvalMs       = $evalMs
            DecodeTokS   = $decode
            WallMs       = $sw.ElapsedMilliseconds
        }
    }
    catch {
        $sw.Stop()
        [pscustomobject]@{
            Label = $Label; Model = $Model; Status = "ERR $($_.Exception.Message)"
            LoadMs = ''; PromptTokens = ''; PromptMs = ''; PrefillTokS = ''
            EvalTokens = ''; EvalMs = ''; DecodeTokS = ''; WallMs = $sw.ElapsedMilliseconds
        }
    }
}

# Build a prompt of roughly N tokens. ~4 chars/token is the usual rule of thumb
# for this tokenizer family; the probe reports the TRUE token count from Ollama,
# so the estimate only has to be close enough to exercise prefill.
function New-LongPrompt([int]$ApproxTokens) {
    $clause = '结算条款约定，甲方应在收到合规发票后三十个工作日内支付，逾期按每日万分之五计息；争议提交上海仲裁委员会。 '
    $per = [math]::Max(1, [int][math]::Ceiling(($clause.Length) / 1.6))
    $n = [math]::Ceiling($ApproxTokens / $per)
    $sb = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $n; $i++) { [void]$sb.Append($clause) }
    [void]$sb.Append(' 用一句话回答：上述条款的付款期限是多少天？')
    $sb.ToString()
}

Write-Host "=== Local model benchmark ===" -ForegroundColor White
Write-Host "endpoint: $OllamaUrl   long-ctx probe: $LongCtx   decode: $DecodeTokens tokens"

$mem0 = Get-HostMemory
Write-Host ("host: {0} GiB RAM, {1} GiB free, {2} GiB committed, WSL VM {3} GiB" -f `
    $mem0.TotalGB, $mem0.FreeGB, $mem0.CommitGB, (Get-WslVmGB))
Write-Host "models are unloaded between lanes; a lane that cannot coexist with the WSL VM is REFUSED, not run"

$tags = $null
try { $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 15 }
catch {
    Write-Host "CANNOT CHECK: Ollama not reachable at $OllamaUrl ($($_.Exception.Message))" -ForegroundColor Yellow
    exit 2
}

$installed = @{}
foreach ($t in $tags.models) { $installed[$t.name] = $t.size }

$rows = @()
foreach ($m in $Models) {
    Write-Host "`n--- $m ---" -ForegroundColor Cyan

    if (-not $installed.ContainsKey($m)) {
        Write-Host "  [SKIP] not installed - cannot benchmark a tag this box does not have" -ForegroundColor Yellow
        $rows += [pscustomobject]@{
            Model = $m; Status = 'NOT INSTALLED'; OnDiskGB = ''; ParamsB = ''; Experts = ''
            Residency = ''; LoadMs = ''; PrefillTokS = ''; DecodeTokS = ''; CtxMax = ''; KvPerTokenKB = ''
        }
        continue
    }

    $arch = Get-ModelArchitecture $m
    # Decimal GB (1e9), matching test-aipc-capacity-fit.ps1's $KnownSizesGB table
    # (it records the 12B as 7.2 for 7,151,003,754 bytes). Using GiB here instead
    # would report 6.7 and make every model look ~7% smaller than the gate that
    # actually decides fit, which is the wrong direction to disagree in.
    $onDiskGB = if ($installed[$m] -gt 0) { [math]::Round($installed[$m] / 1e9, 1) } else { 0 }

    if ($arch) {
        Write-Host ("  params={0}B quant={1} arch={2} experts={3} active={4} ctxMax={5} KV/token={6}KB fullLayers={7} windowLayers={8} ssmState={9}MB" -f `
            $arch.ParamsB, $arch.Quant, $arch.Family, $arch.Experts, $arch.ActiveExperts, `
            $arch.ContextMax, $arch.KvPerTokenKB, $arch.FullLayers, $arch.WindowLayers, $arch.SsmStateMB)
    }

    # Release the PREVIOUS model before faulting this one in. Without this the
    # two resident sets overlap and the box can commit more than it owns - see
    # the host-memory note above the Clear-OllamaModel definition.
    $unloaded = Clear-AllOllamaModels
    if (-not $unloaded) {
        Write-Host "  [warn] a runner did not unload; the next load may double-commit" -ForegroundColor Yellow
    }

    # Then decide whether this model may be loaded at all.
    if (-not (Assert-ModelFitsHost -Model $m -WeightGB $onDiskGB)) {
        $rows += [pscustomobject]@{
            Model = $m; Status = 'REFUSED (host RAM)'; OnDiskGB = $onDiskGB; ParamsB = if ($arch) { $arch.ParamsB } else { '' }
            Experts = if ($arch) { $arch.Experts } else { '' }; Residency = ''; LoadMs = ''
            PrefillTokS = ''; DecodeTokS = ''; CtxMax = if ($arch) { $arch.ContextMax } else { '' }
            KvPerTokenKB = if ($arch) { $arch.KvPerTokenKB } else { '' }
        }
        continue
    }

    # Warm the runner at the long-ctx size FIRST. Loading cold at the probe size
    # would charge the load cost to the first lane and make the second lane look
    # faster for no reason.
    $short = Invoke-Probe -Model $m -Prompt 'Reply with exactly: PONG' -NumPredict 8 -NumCtx $LongCtx -Label 'warmup'
    Write-Host ("  warmup: status={0} load={1}ms" -f $short.Status, $short.LoadMs)

    # Sample residency AFTER a short settle. Reading it immediately after the
    # first response races the scheduler and intermittently reported "not
    # resident" for models that were plainly resident, so a fit verdict built on
    # a single immediate read is unreliable.
    $me = $null
    for ($try = 0; $try -lt 5; $try++) {
        Start-Sleep -Seconds 2
        $me = (Get-OllamaPs) | Where-Object { $_.name -eq $m } | Select-Object -First 1
        if ($me -and $me.size -gt 0) { break }
    }
    # /api/ps reports size + size_vram. `size_vram` equal to `size` means every
    # layer is on the card; anything less means layers spilled to CPU, which is
    # the failure this benchmark exists to expose rather than average away.
    $residency = if ($me) {
        $vramPct = if ($me.size -gt 0) { [math]::Round(100 * $me.size_vram / $me.size, 1) } else { 0 }
        "{0} GB resident, {1}% on GPU, ctx={2}" -f [math]::Round($me.size / 1GB, 2), $vramPct, $me.context_length
    } else { 'not resident after probe' }
    # Report the exact share rather than a binary verdict. A hard 99.5% cut
    # labelled a model SPILLED when ~2% of it sat on the CPU, which is a real
    # cost but not the same claim as "does not fit":
    #   GPU     - every layer on the card
    #   GPU n%  - nearly all on the card; a small CPU share still slows decode
    #   PARTIAL - most on the card, but the CPU layers are paid on every token
    #   SPILLED - less than half on the card
    #   CPU     - nothing on the card
    $device = if (-not $me -or $me.size -le 0) { 'unknown' }
              else {
                  $pct = 100 * $me.size_vram / $me.size
                  if ($pct -ge 99.5) { 'GPU' }
                  elseif ($pct -ge 90) { "GPU $([math]::Round($pct,0))%" }
                  elseif ($pct -ge 50) { "PARTIAL $([math]::Round($pct,0))%" }
                  elseif ($pct -gt 0) { "SPILLED $([math]::Round($pct,0))%" }
                  else { 'CPU' }
              }
    Write-Host "  residency: $residency  -> $device"

    $decode = Invoke-Probe -Model $m `
        -Prompt '写一段 200 字的中文项目说明，说明交付范围、验收标准和付款节点。' `
        -NumPredict $DecodeTokens -NumCtx $LongCtx -Label 'decode'

    $prefill = Invoke-Probe -Model $m -Prompt (New-LongPrompt $LongCtx) `
        -NumPredict 32 -NumCtx $LongCtx -Label 'prefill@longctx'

    Write-Host ("  decode:  {0} tok/s ({1} tok in {2}ms)  status={3}" -f $decode.DecodeTokS, $decode.EvalTokens, $decode.EvalMs, $decode.Status)
    Write-Host ("  prefill: {0} tok/s ({1} tok in {2}ms)  status={3}" -f $prefill.PrefillTokS, $prefill.PromptTokens, $prefill.PromptMs, $prefill.Status)

    $rows += [pscustomobject]@{
        Model         = $m
        Status        = 'OK'
        OnDiskGB      = $onDiskGB
        Fit           = if ($onDiskGB -le ($AipcVramGB * $ComfortRatio)) { 'FITS' }
                        elseif ($onDiskGB -le $AipcVramGB) { 'MARGINAL' } else { 'OVER_CAP' }
        ParamsB       = if ($arch) { $arch.ParamsB } else { '' }
        Experts       = if ($arch) { $arch.Experts } else { '' }
        CtxMax        = if ($arch) { $arch.ContextMax } else { '' }
        KvPerTokenKB  = if ($arch) { $arch.KvPerTokenKB } else { '' }
        LoadMs        = $short.LoadMs
        Residency     = $residency
        Device        = $device
        PrefillTokS   = $prefill.PrefillTokS
        DecodeTokS    = $decode.DecodeTokS
    }
}

# Release the last model too. Leaving a 20+ GB runner resident after the report
# is printed is how a benchmark quietly breaks the next thing you run.
Clear-AllOllamaModels | Out-Null
$memEnd = Get-HostMemory
Write-Host ("`nfinished; host now {0} GiB free, {1} GiB committed" -f $memEnd.FreeGB, $memEnd.CommitGB)

if ($Markdown) {
    Write-Output ''
    Write-Output '| Model | Fit (16 GB) | On disk | Params | Experts | Ctx max | KV/token | Load | Runner | Prefill tok/s | Decode tok/s |'
    Write-Output '|---|---|---|---|---|---|---|---|---|---|---|'
    foreach ($r in $rows) {
        if ($r.Status -ne 'OK') {
            Write-Output "| ``$($r.Model)`` | $($r.Status) | - | - | - | - | - | - | - | - | - |"
            continue
        }
        Write-Output ("| ``{0}`` | {1} | {2} GB | {3}B | {4} | {5} | {6} KB | {7} ms | {8} | {9} | {10} |" -f `
            $r.Model, $r.Fit, $r.OnDiskGB, $r.ParamsB, $r.Experts, $r.CtxMax, `
            $r.KvPerTokenKB, $r.LoadMs, $r.Device, $r.PrefillTokS, $r.DecodeTokS)
    }
    Write-Output ''
    Write-Output "_Measured $((Get-Date).ToString('yyyy-MM-dd HH:mm')) on $env:COMPUTERNAME, long-ctx probe $LongCtx tokens, decode probe $DecodeTokens tokens._"
}
else {
    Write-Output ''
    $rows | Format-Table -AutoSize Model, Fit, OnDiskGB, ParamsB, Experts, CtxMax, KvPerTokenKB, LoadMs, Device, PrefillTokS, DecodeTokS | Out-String -Width 200
}
