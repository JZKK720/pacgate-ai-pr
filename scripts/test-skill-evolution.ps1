<#
.SYNOPSIS
    Gate: skill evolution is enabled, the seeded legal skills load, and the
    allowed-tools union has not amputated the agent's tool surface.

.DESCRIPTION
    WHY THIS EXISTS (2026-10-30).

    Self-evolving legal skills were entirely config-gated: on 0.2.7 the live
    container loaded ZERO skills and `skill_manage` was not bound, because
    `skill_evolution.enabled` defaults to false and the skills root defaulted to
    `/app/backend/skills` - a path that does not exist in the image and is not on
    a mounted volume. Turning it on is two keys and one path, and NOTHING would
    notice if a future edit silently reverted them. The symptom is not an error:
    the agent simply stops being able to learn, and stops seeing the seeded
    playbooks, which reads as "the assistant got dumber".

    THE FAILURE THIS GATE EXISTS FOR is subtler than a missing key.
    `filter_tools_by_skill_allowed_tools` runs on EVERY agent build
    (lead_agent/agent.py:597,624). `allowed_tools` is a UNION across loaded
    skills, and once ANY skill declares it, skills that omit it contribute
    nothing. Measured on 0.2.7:

        two skills, neither declares   -> None   (all 45 tools)
        one declares ["bash"]          -> {'bash'}  (44 tools gone)
        one declares ["bash","read_file"] -> those two only

    So one agent-authored skill declaring a short allowed-tools list silently
    removes bash, read_file, write_file, present_files, every openviking_* and
    every pacgate_pacgate_* tool - mid-conversation, with no error, presenting as
    the assistant getting worse. A self-evolving agent can author exactly that.

    Also measured: a SCALAR declaration (`allowed-tools: pacgate`) does not fall
    back to allow-all - the loader rejects the skill outright with "must be a
    list of strings" and it never loads.

    CHECKS
      E1  config declares skill_evolution.enabled: true
      E2  skills.path resolves onto the persistent .deer-flow volume
      E3  both compose lanes mount the seed skills read-only
      E4  every seeded skill has valid frontmatter (name matches directory,
          description long enough to be matchable)
      E5  no seeded skill declares a partial `allowed-tools` - the union footgun
      E6  (live, advisory) the running stack loads the seeds and the resulting
          tool surface still contains the tools the agent depends on

    E1-E5 are static and run everywhere. E6 needs the stack up.

    Exit codes: 0 = pass; 1 = a real defect; 2 = cannot check.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$bundle = Join-Path $repoRoot 'deploy/client-bundle'
$configPath = Join-Path $bundle 'deer-flow-config.yaml'
$seedDir = Join-Path $bundle 'deer-flow-skills'

# The tools whose loss the union footgun would silently cause. If E6 runs and
# any of these is gone, the surface has been amputated.
$requiredTools = @(
    'bash', 'read_file', 'write_file', 'present_files', 'ask_clarification',
    'skill_manage', 'openviking_search', 'pacgate_pacgate_kb_search'
)

$script:failures = 0
$script:passed = 0
function Write-Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:passed++ }
function Write-Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Write-Info([string]$m) { Write-Host "  [ .. ] $m" -ForegroundColor DarkGray }
function Write-Skip([string]$m) { Write-Host "  [skip] $m" -ForegroundColor Yellow }

Write-Host '=== skill evolution and seeded legal skills ==='

# ---------------------------------------------------------------------------
# E1. The flag that decides whether `skill_manage` is bound at all.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E1  skill evolution is enabled' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Fail "config not found: deploy/client-bundle/deer-flow-config.yaml"
}
else {
    $cfg = [System.IO.File]::ReadAllText($configPath)

    # Line-oriented on purpose: the AIPCs run Windows PowerShell 5.1, which has no
    # ConvertFrom-Yaml. A commented-out `enabled: true` must not pass, so strip
    # comments before matching rather than searching the raw text.
    $uncommented = ($cfg -split "`r?`n" | ForEach-Object { ($_ -split '#')[0] }) -join "`n"

    if ($uncommented -match '(?m)^skill_evolution:\s*$') {
        # Take the block that follows the key and look for enabled: true inside it.
        $block = [regex]::Match($uncommented, '(?ms)^skill_evolution:\s*\r?\n(?<body>(?:[ \t]+.*\r?\n?)+)').Groups['body'].Value
        if ($block -match '(?m)^\s+enabled:\s*true\s*$') {
            Write-Pass 'skill_evolution.enabled is true - skill_manage will be bound'
        }
        else {
            Write-Fail 'skill_evolution block exists but enabled is not true - skill_manage will NOT be bound and the agent cannot author skills'
        }
    }
    else {
        Write-Fail 'no skill_evolution: block - skill_evolution defaults to enabled=false, so skill_manage is never bound'
    }

    # The scanner fails CLOSED, so pointing it at an unavailable model blocks
    # every skill write. Leaving it unset rides the primary local model, which is
    # the intended state (skill bodies quote client content; do not send them to
    # a cloud model).
    if ($uncommented -match '(?m)^\s+moderation_model_name:\s*\S') {
        $mod = [regex]::Match($uncommented, '(?m)^\s+moderation_model_name:\s*(\S+)').Groups[1].Value
        Write-Info "moderation_model_name is pinned to '$mod' - confirm it is a LOCAL model"
    }
    else {
        Write-Pass 'moderation_model_name unset - scanner rides the primary (local) model'
    }
}

# ---------------------------------------------------------------------------
# E2. The skills root must be on the persistent volume, or every learned skill
#     dies at the next container recreation.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E2  skills root is on the persistent volume' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Fail 'config not found'
}
else {
    $cfg = [System.IO.File]::ReadAllText($configPath)
    $uncommented = ($cfg -split "`r?`n" | ForEach-Object { ($_ -split '#')[0] }) -join "`n"
    $skillsBlock = [regex]::Match($uncommented, '(?ms)^skills:\s*\r?\n(?<body>(?:[ \t]+.*\r?\n?)+)').Groups['body'].Value

    if (-not $skillsBlock) {
        Write-Fail 'no skills: block - the root falls back to /app/backend/skills, which does not exist in the image and is NOT on a volume'
    }
    else {
        $pathMatch = [regex]::Match($skillsBlock, '(?m)^\s+path:\s*(\S+)')
        if (-not $pathMatch.Success) {
            Write-Fail 'skills.path is unset - learned skills would not survive container recreation'
        }
        else {
            $p = $pathMatch.Groups[1].Value.Trim()
            # `.deer-flow` is the path compose mounts as ./data/deer-flow.
            if ($p -match '^\.deer-flow(/|$)') {
                Write-Pass "skills.path = '$p' resolves under the mounted .deer-flow volume"
            }
            else {
                Write-Fail "skills.path = '$p' is not under .deer-flow - it is not on a mounted volume, so learned skills are lost on recreation"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# E3. Both compose lanes must deliver the seeds, or one lane ships no skills.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E3  both compose lanes mount the seed skills' -ForegroundColor Cyan

foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $lanePath = Join-Path $bundle $lane
    if (-not (Test-Path -LiteralPath $lanePath)) {
        Write-Fail "$lane is missing"
        continue
    }
    $text = [System.IO.File]::ReadAllText($lanePath)
    if ($text -match '\./deer-flow-skills:/app/backend/\.deer-flow/skills/public:ro') {
        Write-Pass "$lane mounts ./deer-flow-skills read-only into the skills root"
    }
    else {
        Write-Fail "$lane does not mount ./deer-flow-skills - that lane would load no seeded skills"
    }
}

# ---------------------------------------------------------------------------
# E4. Every seeded skill must be loadable. The loader rejects a bad frontmatter
#     silently (a log line, not an error), so a typo produces a missing
#     capability rather than a failure.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E4  seeded skills have valid frontmatter' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $seedDir)) {
    Write-Fail 'deploy/client-bundle/deer-flow-skills is missing'
}
else {
    $seeds = @(Get-ChildItem -LiteralPath $seedDir -Directory)
    if ($seeds.Count -eq 0) {
        Write-Fail 'no seeded skills - self-evolution would start from an empty corpus and produce generic output'
    }
    foreach ($s in $seeds) {
        $md = Join-Path $s.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $md)) {
            Write-Fail "seed '$($s.Name)' has no SKILL.md"
            continue
        }
        $text = [System.IO.File]::ReadAllText($md)
        $fmMatch = [regex]::Match($text, '(?s)^\s*---\s*\r?\n(?<fm>.+?)\r?\n---')
        if (-not $fmMatch.Success) {
            Write-Fail "seed '$($s.Name)' has no --- frontmatter block"
            continue
        }
        $fm = $fmMatch.Groups['fm'].Value

        $nameMatch = [regex]::Match($fm, '(?m)^name:\s*(\S+)')
        if (-not $nameMatch.Success) {
            Write-Fail "seed '$($s.Name)' frontmatter has no name"
            continue
        }
        # The loader requires frontmatter name == directory name. A mismatch is
        # rejected with a log line and the skill never appears.
        if ($nameMatch.Groups[1].Value.Trim() -ne $s.Name) {
            Write-Fail "seed '$($s.Name)' frontmatter name is '$($nameMatch.Groups[1].Value.Trim())' - the loader requires it to match the directory"
            continue
        }
        if ($s.Name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
            Write-Fail "seed '$($s.Name)' is not hyphen-case - the loader rejects it"
            continue
        }

        # The loader parses frontmatter with yaml.safe_load (parser.py:92), so a
        # folded (`description: >`) or literal (`|`) block scalar is valid YAML
        # and resolves to the joined text. Matching only the first physical line
        # captures the literal '>' and rejects a perfectly loadable skill. That
        # is a false failure, and false failures teach people to ignore gates.
        $descMatch = [regex]::Match($fm, '(?m)^description:[ \t]*(.*)$')
        if (-not $descMatch.Success) {
            Write-Fail "seed '$($s.Name)' frontmatter has no description"
            continue
        }
        $descText = $descMatch.Groups[1].Value.Trim()
        if ($descText -match '^[>|][+-]?$') {
            # Block scalar: take the indented continuation lines that follow.
            $after = $fm.Substring($descMatch.Index + $descMatch.Length)
            $blockLines = @()
            foreach ($line in ($after -split '\r?\n')) {
                if ($line -match '^\s+\S') { $blockLines += $line.Trim() }
                elseif ($line.Trim() -eq '') { }
                else { break }
            }
            $descText = ($blockLines -join ' ').Trim()
        }
        if ($descText.Length -lt 40) {
            Write-Fail "seed '$($s.Name)' description is too short for the model to match against (resolved $($descText.Length) chars, need 40)"
            continue
        }
        Write-Pass "seed '$($s.Name)' is loadable (name matches directory, description is matchable)"
    }
}

# ---------------------------------------------------------------------------
# E5. The union footgun. This is the check that earns the gate its keep.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E5  no seeded skill declares a partial allowed-tools' -ForegroundColor Cyan

if (Test-Path -LiteralPath $seedDir) {
    $declared = @()
    foreach ($s in @(Get-ChildItem -LiteralPath $seedDir -Directory)) {
        $md = Join-Path $s.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $md)) { continue }
        $text = [System.IO.File]::ReadAllText($md)
        $fmMatch = [regex]::Match($text, '(?s)^\s*---\s*\r?\n(?<fm>.+?)\r?\n---')
        if (-not $fmMatch.Success) { continue }
        if ($fmMatch.Groups['fm'].Value -match '(?m)^allowed-tools:\s*(.+)$') {
            $declared += [pscustomobject]@{ Skill = $s.Name; Value = $Matches[1].Trim() }
        }
    }

    if ($declared.Count -eq 0) {
        Write-Pass 'no seed declares allowed-tools - the tool surface is a union of nothing, i.e. all tools'
    }
    else {
        # A declaration is only safe if it covers every tool the agent needs.
        # Anything less amputates the surface for EVERY skill, not just this one.
        foreach ($d in $declared) {
            $missing = @()
            foreach ($t in $requiredTools) {
                if ($d.Value -notmatch [regex]::Escape($t)) { $missing += $t }
            }
            if ($missing.Count -gt 0) {
                Write-Fail "seed '$($d.Skill)' declares allowed-tools '$($d.Value)' which omits $($missing -join ', ') - that union REMOVES those tools from every skill's surface"
            }
            else {
                Write-Pass "seed '$($d.Skill)' declares allowed-tools covering the required set"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# E6. Live: does the running stack actually load them, with the surface intact?
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E6  the running stack loads the seeds (live, advisory)' -ForegroundColor Cyan

$running = @()
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $running = @(& docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -eq 'deer-flow' })
}
finally { $ErrorActionPreference = $prevEap }

if ($running.Count -eq 0) {
    Write-Skip 'deer-flow is not running - live check not performed'
}
else {
    # A container created before this change has neither the seed mount nor the
    # new config, so asserting on it would be red-for-the-wrong-reason - the
    # failure would be "nobody ran docker compose up", not "the config is wrong".
    # Distinguish the two: if the mount is absent from the RUNNING container, the
    # deployment simply predates this change and needs a recreate.
    $mountText = ''
    $ErrorActionPreference = 'Continue'
    try {
        $mountText = (& docker inspect deer-flow --format '{{range .Mounts}}{{.Destination}};{{end}}' 2>$null | Out-String)
    }
    finally { $ErrorActionPreference = $prevEap }

    if ($mountText -notmatch '/app/backend/\.deer-flow/skills/public') {
        Write-Skip 'the running deer-flow container predates this change (no seed mount) - recreate it to activate, then re-run'
    }
    elseif ($mountText -notmatch '/app/backend/\.deer-flow;') {
        Write-Fail 'the skills root is not on a persistent mount in the RUNNING container - learned skills will be lost on recreation'
    }
    else {
        $probe = @'
import json
from deerflow.config import get_app_config
from deerflow.skills.storage import get_or_new_skill_storage
from deerflow.skills.tool_policy import allowed_tool_names_for_skills, filter_tools_by_skill_allowed_tools
from deerflow.tools.tools import get_available_tools

cfg = get_app_config()
storage = get_or_new_skill_storage(app_config=cfg)
skills = storage.load_skills(enabled_only=True)
tools = get_available_tools(app_config=cfg)
kept = filter_tools_by_skill_allowed_tools(tools, skills)
print("ROOT=" + str(storage.get_skills_root_path()))
print("SKILLS=" + "|".join(s.name for s in skills))
print("UNION=" + "|".join(sorted(allowed_tool_names_for_skills(skills) or [])))
print("TOOLS_BEFORE=" + str(len(tools)))
print("TOOLS_AFTER=" + str(len(kept)))
print("LOST=" + "|".join(sorted({t.name for t in tools} - {t.name for t in kept})))
'@
        # Written to a file, not piped, because 5.1 mangles quoting in a one-liner.
        $probePath = Join-Path ([System.IO.Path]::GetTempPath()) ("skill-evo-probe-{0}.py" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.File]::WriteAllText($probePath, $probe, [System.Text.UTF8Encoding]::new($false))

        try {
            $ErrorActionPreference = 'Continue'
            $copyOut = & docker cp $probePath deer-flow:/tmp/skill_evo_probe.py 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Skip "could not stage the probe into the container: $copyOut"
            }
            else {
                $out = & docker exec -w /app/backend deer-flow sh -lc '.venv/bin/python /tmp/skill_evo_probe.py' 2>&1
                $lines = @($out | ForEach-Object { "$_" })

                $root = ($lines | Where-Object { $_ -like 'ROOT=*' }) -replace '^ROOT=', ''
                $skillLine = ($lines | Where-Object { $_ -like 'SKILLS=*' }) -replace '^SKILLS=', ''
                $unionLine = ($lines | Where-Object { $_ -like 'UNION=*' }) -replace '^UNION=', ''
                $before = ($lines | Where-Object { $_ -like 'TOOLS_BEFORE=*' }) -replace '^TOOLS_BEFORE=', ''
                $after = ($lines | Where-Object { $_ -like 'TOOLS_AFTER=*' }) -replace '^TOOLS_AFTER=', ''

                if (-not $skillLine) {
                    Write-Skip 'probe produced no parseable output'
                }
                else {
                    Write-Info "skills root: $root"

                    # Pipe-delimited, not JSON. Windows PowerShell 5.1's
                    # `ConvertFrom-Json` unrolls a single-element JSON array into a
                    # scalar, so a correct one-skill result read as
                    # "1 skill(s): System.Object[]" and a genuinely-empty one was
                    # indistinguishable. A plain delimiter has no such behavior.
                    $names = @($skillLine -split '\|' | Where-Object { $_ })

                    if ($names.Count -eq 0) {
                        Write-Fail 'the running agent loads ZERO skills despite the seed mount - the skills path or the mount target is wrong; a lawyer sees no legal playbooks'
                    }
                    else {
                        Write-Pass "the running agent loads $($names.Count) skill(s): $($names -join ', ')"
                    }

                    if (-not $unionLine) {
                        Write-Pass 'allowed-tools union is empty, so the tool surface is unrestricted'
                    }
                    else {
                        Write-Fail "allowed-tools union is '$($unionLine -replace '\|', ', ')' - this REMOVES every tool not listed from the agent's surface"
                    }

                    if ($before -and $before -eq $after) {
                        Write-Pass "tool surface intact before and after the skill policy filter ($before tools)"
                    }
                    elseif ($before) {
                        Write-Fail "skill policy filter removed $([int]$before - [int]$after) of $before tools"
                    }
                }
                & docker exec deer-flow sh -lc 'rm -f /tmp/skill_evo_probe.py' 2>&1 | Out-Null
            }
        }
        finally {
            Remove-Item -LiteralPath $probePath -ErrorAction SilentlyContinue
            $ErrorActionPreference = $prevEap
        }
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} failed - skill evolution is NOT correctly configured." -f $script:passed, $script:failures) -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: skill evolution is enabled, seeded, and cannot silently amputate the tool surface. ({0} passed)" -f $script:passed) -ForegroundColor Green
exit 0
