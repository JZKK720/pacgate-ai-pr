<#
.SYNOPSIS
    Gate: the skills and workflow templates that every machine must have are
    present, well-formed, and actually reachable at runtime.

.DESCRIPTION
    WHY THIS EXISTS (2026-10-19).

    "skills, MCPs and templates with workflows" are must-haves on every machine,
    and until now NOTHING asserted they existed. A search of the suite found gates
    for MCP (2) and workflows (7) but zero for skills and zero for the template
    lane as an artifact set. A missing skill produces no error - the agent simply
    cannot discover a capability it was supposed to have, which looks like the
    model being unhelpful rather than a deployment that lost a directory.

    The specific trap this closes: the skills do NOT ship inside the digest-pinned
    sandbox image. Verified 2026-10-19 by inspecting
    ghcr.io/jzkk720/pacgate-sandboxes@sha256:52e867fc...: it contains tools
    (pacgate-qm, firecrawl-qm, claude, codex) and NOT ONE SKILL.md. Skills reach
    the agent only through the compose bind-mount
    (`./sandbox/skills:/layer/skills:ro`) plus the tracked files on disk. So the
    tracked directory IS the product surface, and deleting or renaming it breaks
    every machine at once with no build failure.

    CHECKS
      K1  every tracked sandbox skill has a SKILL.md with valid frontmatter
      K2  the sandbox image does not carry skills, so the mount is load-bearing
          (documented as an assertion so nobody "optimises" the mount away)
      K3  workflow templates: tracked count matches the client bundle copy
      K4  every workflow template parses as YAML with an id and a name
      K5  the deer-flow seed skill corpus exists, is loadable, is mounted, and is
          packaged for clients (a SEPARATE corpus from the qm skills in K1)

    Static where possible; K2 and the live mount check are advisory when Docker or
    the image is unavailable, because a clean machine has neither.

    Exit codes: 0 = pass; 1 = a real defect; 2 = cannot check.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:failures = 0
$script:passed = 0

function Write-Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:passed++ }
function Write-Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Write-Info([string]$m) { Write-Host "  [ .. ] $m" -ForegroundColor DarkGray }
function Write-Skip([string]$m) { Write-Host "  [skip] $m" -ForegroundColor Yellow }

$skillDir = Join-Path $repoRoot 'deploy/qm-pacgate/sandbox/skills'
$clientSkillDir = Join-Path $repoRoot 'deploy/client-bundle/qm-pacgate/sandbox/skills'
$wfTracked = Join-Path $repoRoot 'pacgate-ai/workflows'
$wfBundle = Join-Path $repoRoot 'deploy/client-bundle/workflows'

Write-Host '=== skills and workflow templates reach every machine ==='

# ---------------------------------------------------------------------------
# K1. Every sandbox skill is a real skill, not an empty directory.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'K1  sandbox skills are present and well-formed' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $skillDir)) {
    Write-Fail "the tracked skill directory is missing: deploy/qm-pacgate/sandbox/skills"
}
else {
    $skills = @(Get-ChildItem -LiteralPath $skillDir -Directory -ErrorAction SilentlyContinue)
    if ($skills.Count -eq 0) {
        Write-Fail 'the skill directory is empty - the agent would ship with no capabilities'
    }
    else {
        Write-Info "$($skills.Count) skill(s): $(($skills | ForEach-Object { $_.Name }) -join ', ')"
    }

    foreach ($s in $skills) {
        $md = Join-Path $s.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $md)) {
            Write-Fail "skill '$($s.Name)' has no SKILL.md - the agent cannot load a directory without one"
            continue
        }
        $text = [System.IO.File]::ReadAllText($md)

        # Frontmatter: the agent reads `name` and `description` from the YAML
        # block at the top. A file that starts with prose is silently unusable.
        if ($text -notmatch '(?s)^\s*---\s*\r?\n(.+?)\r?\n---') {
            Write-Fail "skill '$($s.Name)' SKILL.md has no --- frontmatter block"
            continue
        }
        $fm = $Matches[1]
        $hasName = $fm -match '(?m)^name:\s*\S'
        $hasDesc = $fm -match '(?m)^description:\s*\S'
        if (-not $hasName -or -not $hasDesc) {
            Write-Fail "skill '$($s.Name)' frontmatter must declare both name and description (name=$hasName description=$hasDesc)"
            continue
        }
        # A description is what the model matches against to decide whether the
        # skill applies. One line of two words is effectively undiscoverable.
        $descLine = ($fm -split "`r?`n" | Where-Object { $_ -match '^description:' } | Select-Object -First 1)
        if ($descLine -and $descLine.Length -lt 40) {
            Write-Fail "skill '$($s.Name)' description is only $($descLine.Length) chars - too thin for the model to match against"
            continue
        }
        Write-Pass "skill '$($s.Name)' has frontmatter with name, description and real body"
    }

    # The client bundle carries its own staged copy. If the two disagree, a
    # machine that re-stages gets different skills than one that does not.
    if (Test-Path -LiteralPath $clientSkillDir) {
        $tracked = @(Get-ChildItem -LiteralPath $skillDir -Directory | ForEach-Object { $_.Name } | Sort-Object)
        $staged = @(Get-ChildItem -LiteralPath $clientSkillDir -Directory | ForEach-Object { $_.Name } | Sort-Object)
        if (($tracked -join ',') -eq ($staged -join ',')) {
            Write-Pass "staged copy matches the tracked set ($($tracked.Count) skill(s))"
        }
        else {
            Write-Fail "staged skills differ from tracked: tracked=($($tracked -join ', ')) staged=($($staged -join ', '))"
        }
    }
    else {
        Write-Info 'no staged client-bundle skills copy to compare'
    }
}

# ---------------------------------------------------------------------------
# K2. The sandbox image does NOT carry skills, which is why the mount exists.
#
# This is an assertion about WHY K1 matters. If a future image starts baking
# skills in, the mount becomes redundant and could be removed - at which point
# editing a SKILL.md would silently stop taking effect. Either state is fine, but
# it must be a known state, not an accident.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'K2  skills reach the agent through the bind mount' -ForegroundColor Cyan

$qmCompose = Join-Path $repoRoot 'deploy/client-bundle/qm-pacgate/compose.qm.yaml'
if (Test-Path -LiteralPath $qmCompose) {
    $composeText = [System.IO.File]::ReadAllText($qmCompose)
    if ($composeText -match '\./sandbox/skills:/layer/skills') {
        Write-Pass 'compose mounts ./sandbox/skills into the agent at /layer/skills'
    }
    else {
        Write-Fail 'compose no longer mounts sandbox/skills - with no SKILL.md baked into the image, the agent would have NO skills'
    }
}
else {
    Write-Info 'qm compose not found - skipping mount assertion'
}

# Live confirmation when a qm container happens to be running.
#
# PACGATE 2026-10-22: `docker inspect --format '{{range .Mounts}}{{.Destination}}{{"|"}}{{end}}'`
# FAILED HERE with `template parsing error: template: :1: unexpected "|" in command`.
# Windows PowerShell 5.1 strips the inner double quotes out of a single-quoted
# native argument before docker sees it, so Go received `{{|}}` - the same defect
# class already fixed in the E10 gate. Separating mounts with a plain character
# avoids embedded quotes entirely, and the call runs with the preference lowered
# because a native stderr write under `Stop` aborts the whole gate.
$qmCore = @(docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -like '*qm-pacgate-core*' })
if ($qmCore.Count -gt 0) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $mounted = (& docker inspect $qmCore[0] --format '{{range .Mounts}}{{.Destination}}{{end}}' 2>$null | Out-String).Trim()
    }
    finally { $ErrorActionPreference = $prevEap }
    if ($mounted -and $mounted -match '/layer/skills') {
        Write-Pass "running container has /layer/skills mounted ($($qmCore[0]))"
    }
    else {
        Write-Info "running container $($qmCore[0]) has no /layer/skills mount (may predate this config)"
    }
}
else {
    Write-Info 'qm not running - live mount not checked'
}

# ---------------------------------------------------------------------------
# K3. Workflow templates: the tracked set and the shipped bundle agree.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'K3  workflow templates are tracked and shipped' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $wfTracked)) {
    Write-Fail 'pacgate-ai/workflows is missing - the workflow template lane has no source'
}
elseif (-not (Test-Path -LiteralPath $wfBundle)) {
    Write-Fail 'deploy/client-bundle/workflows is missing - machines would get no extra templates'
}
else {
    $a = @(Get-ChildItem -LiteralPath $wfTracked -Filter '*.yaml' | ForEach-Object { $_.Name } | Sort-Object)
    $b = @(Get-ChildItem -LiteralPath $wfBundle -Filter '*.yaml' | ForEach-Object { $_.Name } | Sort-Object)
    if ($a.Count -eq 0) {
        Write-Fail 'pacgate-ai/workflows contains no .yaml templates'
    }
    elseif (($a -join ',') -eq ($b -join ',')) {
        Write-Pass "$($a.Count) template(s) present in both the source and the shipped bundle"
    }
    else {
        $onlyA = @($a | Where-Object { $b -notcontains $_ })
        $onlyB = @($b | Where-Object { $a -notcontains $_ })
        if ($onlyA.Count) { Write-Fail "in source but NOT shipped: $($onlyA -join ', ')" }
        if ($onlyB.Count) { Write-Fail "shipped but NOT in source: $($onlyB -join ', ')" }
    }
}

# ---------------------------------------------------------------------------
# K4. Every template parses and declares the ids the API needs.
#
# Deliberately line-oriented rather than a YAML parser: the AIPCs run Windows
# PowerShell 5.1, which has no ConvertFrom-Yaml (same constraint the other config
# gates work under). This checks only the keys the loader requires.
#
# These files are a top-level YAML LIST, not a mapping - each entry is
# `- id: ...` followed by indented `name:` / `steps:`. An earlier version of this
# check anchored `^id:` at column 0 and reported all 15 templates as broken; the
# templates were fine and the assertion was wrong.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'K4  every workflow template parses and declares id, name and steps' -ForegroundColor Cyan

if (Test-Path -LiteralPath $wfBundle) {
    $bad = 0
    $files = @(Get-ChildItem -LiteralPath $wfBundle -Filter '*.yaml')
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        # Allow the `- ` list marker, and any indentation.
        $hasId = $t -match '(?m)^\s*-?\s*id:\s*\S'
        $hasName = $t -match '(?m)^\s*name:\s*\S'
        $hasSteps = $t -match '(?m)^\s*steps:'
        if (-not ($hasId -and $hasName -and $hasSteps)) {
            $missingKeys = @()
            if (-not $hasId) { $missingKeys += 'id' }
            if (-not $hasName) { $missingKeys += 'name' }
            if (-not $hasSteps) { $missingKeys += 'steps' }
            Write-Fail "$($f.Name) is missing $($missingKeys -join '/')"
            $bad++
        }
    }
    if ($bad -eq 0) {
        Write-Pass "all $($files.Count) template(s) declare id, name and steps"
    }
}

Write-Host ''
Write-Host 'K5  the seeded deer-flow skills are present and declared' -ForegroundColor Cyan

# Pacgate 2026-10-30: these are a SEPARATE corpus from the qm sandbox skills in
# K1. The qm skills are prose that the qm agent reads via /layer/skills; these are
# mounted into deer-flow's own skills root so the research workspace agent sees
# legal playbooks. They are not the same files and are not interchangeable.
#
# The specific trap: deer-flow's compose mounts ../deer-flow-skills, a directory
# that exists only if it is tracked. A missing directory produces an empty mount
# and zero skills with no error - the agent just has no playbooks.
$dfSeedDir = Join-Path $repoRoot 'deploy/client-bundle/deer-flow-skills'
$dfCompose = Join-Path $repoRoot 'deploy/client-bundle/compose.prod.yaml'

if (-not (Test-Path -LiteralPath $dfSeedDir)) {
    Write-Fail 'deploy/client-bundle/deer-flow-skills is missing - compose mounts it, so the agent gets no seeded skills'
}
else {
    $dfSeeds = @(Get-ChildItem -LiteralPath $dfSeedDir -Directory)
    if ($dfSeeds.Count -eq 0) {
        Write-Fail 'deer-flow-skills is empty - the agent would have no legal playbooks'
    }
    else {
        Write-Info "$($dfSeeds.Count) deer-flow seed skill(s): $(($dfSeeds | ForEach-Object { $_.Name }) -join ', ')"
    }
    $badSeed = 0
    foreach ($s in $dfSeeds) {
        $md = Join-Path $s.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $md)) {
            Write-Fail "deer-flow skill '$($s.Name)' has no SKILL.md"
            $badSeed++
            continue
        }
        $text = [System.IO.File]::ReadAllText($md)
        $fmMatch = [regex]::Match($text, '(?s)^\s*---\s*\r?\n(?<fm>.+?)\r?\n---')
        if (-not $fmMatch.Success) {
            Write-Fail "deer-flow skill '$($s.Name)' has no --- frontmatter block"
            $badSeed++
            continue
        }
        $fm = $fmMatch.Groups['fm'].Value
        $nm = [regex]::Match($fm, '(?m)^name:\s*(\S+)')
        # The loader requires frontmatter name == directory name, and rejects a
        # mismatch with only a log line - a silent missing capability.
        if (-not $nm.Success -or $nm.Groups[1].Value.Trim() -ne $s.Name) {
            Write-Fail "deer-flow skill '$($s.Name)' frontmatter name does not match its directory - the loader will reject it"
            $badSeed++
            continue
        }
        if ($fm -notmatch '(?m)^description:\s*\S.{39,}') {
            Write-Fail "deer-flow skill '$($s.Name)' description is missing or too thin to match against"
            $badSeed++
            continue
        }
        # See scripts/test-skill-evolution.ps1 E5: a partial allowed-tools list is
        # a union that amputates the tool surface for EVERY skill.
        if ($fm -match '(?m)^allowed-tools:') {
            Write-Fail "deer-flow skill '$($s.Name)' declares allowed-tools - allowed_tools is a UNION, so a partial list silently removes tools from every skill's surface"
            $badSeed++
            continue
        }
    }
    if ($badSeed -eq 0) {
        Write-Pass "all $($dfSeeds.Count) deer-flow seed skill(s) are loadable"
    }

    if (Test-Path -LiteralPath $dfCompose) {
        $dc = [System.IO.File]::ReadAllText($dfCompose)
        if ($dc -match '\./deer-flow-skills:/app/backend/\.deer-flow/skills/public:ro') {
            Write-Pass 'compose.prod.yaml mounts the seed corpus read-only'
        }
        else {
            Write-Fail 'compose.prod.yaml no longer mounts ./deer-flow-skills - the seeded skills would not reach the agent'
        }
    }

    # The packaging script must ship the directory, or a client's compose mounts a
    # path that was never delivered.
    $pkg = Join-Path $repoRoot 'scripts/package-bundle.ps1'
    if (Test-Path -LiteralPath $pkg) {
        $pkgText = [System.IO.File]::ReadAllText($pkg)
        if ($pkgText -match "'deer-flow-skills'") {
            Write-Pass 'package-bundle.ps1 ships the seed corpus'
        }
        else {
            Write-Fail "package-bundle.ps1 does not include 'deer-flow-skills' - clients would get a compose file mounting a missing directory"
        }
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "RESULT: $($script:failures) skills/template problem(s). ($($script:passed) passed)" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: skills and workflow templates ship and reach the agent. ($($script:passed) passed)" -ForegroundColor Green
exit 0
