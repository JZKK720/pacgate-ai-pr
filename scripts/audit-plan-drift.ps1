# Cross-check each plan's claimed status against verifiable repo state.
# Reports DRIFT where a plan's status claim does not match the tree.
$out = @()

function Add-Line($s) { $script:out += $s }

# ── 1. Plan index (README.md) vs actual files ────────────────────────────────
Add-Line '=== 1. plans/README.md status table vs actual plan files ==='
$readme = Get-Content plans/README.md -Raw
$actual = (Get-ChildItem plans -File -Filter '0*.md' | ForEach-Object { $_.Name }) | Sort-Object

# Any plan file never mentioned in the README table?
$missingFromIndex = @()
foreach ($f in $actual) {
    $num = ($f -split '-')[0]
    if ($readme -notmatch [regex]::Escape($num)) { $missingFromIndex += $f }
}
if ($missingFromIndex) {
    Add-Line '  Plans NOT referenced in README.md status table:'
    $missingFromIndex | ForEach-Object { Add-Line "    - $_" }
} else {
    Add-Line '  (all plans referenced)'
}
Add-Line ''

# ── 2. Does README claim a next-plan number that is now taken? ───────────────
Add-Line '=== 2. README "next plan is 008" claim ==='
if ($readme -match 'next improve-plan is (\d{3})') {
    $claimed = $Matches[1]
    $exists = $actual | Where-Object { $_ -like "$claimed-*" }
    Add-Line "  README says next = $claimed"
    if ($exists) {
        Add-Line "  DRIFT: $claimed already exists -> $exists"
        Add-Line "  Actual highest plan number: $((($actual | ForEach-Object { [int]($_ -split '-')[0] } | Sort-Object -Descending)[0]).ToString('000'))"
    }
}
Add-Line ''

# ── 3. Status claims inside each plan's first 5 lines ───────────────────────
Add-Line '=== 3. Self-declared status per plan (first 6 lines) ==='
foreach ($f in $actual) {
    $head = Get-Content (Join-Path plans $f) -TotalCount 6
    $statusLine = $head | Where-Object { $_ -match '(?i)status|COMPLETED|DONE|READY|deferr' } | Select-Object -First 1
    if ($statusLine) {
        $clean = ($statusLine -replace '\s+', ' ').Trim()
        if ($clean.Length -gt 110) { $clean = $clean.Substring(0, 110) + '...' }
        Add-Line ("  {0,-46} {1}" -f $f, $clean)
    } else {
        Add-Line ("  {0,-46} (no explicit status line)" -f $f)
    }
}
Add-Line ''

# ── 4. Plan 010 claims COMPLETED; does its compose file exist? ───────────────
Add-Line '=== 4. Plan 010 (COMPLETED) artifact check ==='
$qmCompose = 'deploy/qm-pacgate/compose.qm.yaml'
$qmPatch   = 'deploy/qm-pacgate/patch/pi-models.ts'
$qmTasks   = 'deploy/qm-pacgate/tasks/patch-pi-models.sh'
foreach ($p in @($qmCompose, $qmPatch, $qmTasks)) {
    $tracked = [bool](git ls-files --error-unmatch $p 2>$null)
    Add-Line ("  {0,-48} tracked={1}" -f $p, $tracked)
}
Add-Line ''

# ── 5. Plan 009 claims the .deer-flow mount; is it in the compose? ───────────
Add-Line '=== 5. Plan 009 claim: deer-flow .deer-flow persistence mount ==='
$hits = Select-String -Path deploy/client-bundle/compose.prod.yaml, deploy/client-bundle/compose.bundle.yaml -Pattern 'deer-flow' -SimpleMatch 2>$null
$mount = Select-String -Path deploy/client-bundle/compose.prod.yaml -Pattern '/app/backend/.deer-flow'
if ($mount) { $mount | ForEach-Object { Add-Line ("  {0}:{1}" -f $_.Filename, $_.LineNumber) } }
else { Add-Line '  NOT FOUND in compose.prod.yaml' }
Add-Line ''

# ── 6. Plan 009 pins 0.1.7; what does compose actually pin now? ──────────────
Add-Line '=== 6. Plan 009 target version (0.1.7) vs actual compose pins ==='
foreach ($cf in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/compose.bundle.yaml')) {
    $pins = Select-String -Path $cf -Pattern 'ghcr\.io/pacgate-ai/[a-z\-]+:[0-9.]+' -AllMatches
    foreach ($m in $pins.Matches) { Add-Line ("  {0,-42} {1}" -f $cf, $m.Value) }
}
Add-Line ''

$out -join "`n"
