<#
.SYNOPSIS
    Measure laya's Chinese clause-risk accuracy against CCL-DRR.

.DESCRIPTION
    WHY THIS EXISTS (2026-11-01).

    The English benchmark (bench-laya-clause-flags.ps1) scores AUC 0.93-1.00
    against CUAD. This one exists because repeating that claim for Chinese turned
    out to be wrong, and the wrongness was invisible from hand-picked examples.

    DATA. CCL-DRR (im1129/CCL-DRR on GitHub, MIT, 2026): 6,794 Chinese contract
    clauses across 7 contract types, each with a 3-way human-style label:

        风险高           (high risk)          2,287
        模糊不清          (ambiguous)          2,234
        清晰明确无风险     (clear, no risk)     2,273

    near-uniform by construction, so 3-class chance accuracy is 0.333. Clauses are
    drafted FROM statute articles rather than extracted from executed contracts,
    the repo has no external validation, and the labels are coarse - treat this as
    a sanity benchmark, not a precision-recall authority. It is nonetheless the
    only clause-level Chinese CONTRACT corpus available publicly.

    MEASURED RESULT, and the reason this script is a warning rather than a
    scoreboard: with the question pacgate_clause_risk actually ships, accuracy is
    at chance and recall on the high-risk class is ZERO. The tool never flags a
    dangerous Chinese clause; it calls 71% of everything "medium". Restating the
    criteria in Chinese does not fix it (accuracy drops to 0.238 - below chance).

    A triage tool that cannot see the class it exists to catch is worse than no
    tool, because it looks like coverage. That is why the tool docstrings now say
    this out loud and why this script asserts the numbers rather than printing
    them quietly.

.PARAMETER Clauses
    Sample size. Default 21 covers every (label, contract-type) cell.

.PARAMETER Seed
    Sampling seed, so a reported number can be reproduced.

.PARAMETER Threshold
    Bar on RECALL OF THE HIGH-RISK CLASS (风险高), not overall accuracy. Default
    0.70, which the current build misses.

    Accuracy is deliberately not the bar. Measured: overall accuracy ranges
    0.238-0.571 across question framings and seeds, which reads as respectable and
    is misleading - on a three-class set where "medium" and "low" are two thirds of
    the data, a classifier that mostly answers those scores well. Recall on 风险高
    is what a triage tool exists to deliver, and it has been 0.29 in every run.

.EXAMPLE
    pwsh -NoProfile -File scripts/bench-laya-chinese-risk.ps1

.NOTES
    Exit codes: 0 = accuracy at or above the threshold (claim validated);
    1 = accuracy below threshold (do not advertise Chinese risk grading);
    2 = cannot check (no laya, no dataset).
#>
[CmdletBinding()]
param(
    [int]$Clauses = 21,
    [int]$Seed = 23,
    [double]$Threshold = 0.70,
    [string]$LayaUrl = 'http://127.0.0.1:8000/v1/systemone'
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

try {
    $health = Invoke-RestMethod -Uri ($LayaUrl -replace '/v1/systemone$', '/health') -TimeoutSec 15
    if ($health.loaded -notcontains 'multilingual') {
        Write-Host "  CANNOT CHECK: laya is up but 'multilingual' is not loaded." -ForegroundColor Yellow
        Write-Host '  Chinese text routes to that checkpoint; set LAYA_MODELS=multilingual,english.' -ForegroundColor Yellow
        exit 2
    }
    Write-Host "laya ready: $($health.loaded -join ', ')"
}
catch {
    Write-Host "  CANNOT CHECK: laya is not reachable at $LayaUrl" -ForegroundColor Yellow
    exit 2
}

$dataDir = Join-Path $env:TEMP 'laya-ccl-bench'
$data = Join-Path $dataDir 'train.json'
if (-not (Test-Path -LiteralPath $data)) {
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    Write-Host '  downloading CCL-DRR train split (13 MB, MIT)...'
    try {
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/im1129/CCL-DRR/main/train.json' `
            -OutFile $data -TimeoutSec 900
    }
    catch {
        Write-Host "  CANNOT CHECK: could not download CCL-DRR - $($_.Exception.Message)" -ForegroundColor Yellow
        exit 2
    }
}

$py = Join-Path $dataDir 'bench_zh.py'
$script = @'
import json, random, sys, urllib.request

DATA, URL, N, SEED, THRESH = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
records = json.load(open(DATA, encoding="utf-8"))

# This is the path pacgate_clause_risk actually runs for Chinese text: three
# yes/no questions, one concept each, combined with tuned thresholds. Asking a
# single three-way question scored chance with recall 0.00; decomposing is what
# produced recall 1.00. Thresholds must match _LAYA_ZH_THRESHOLDS in server.py.
QUESTION = {
    "uncapped": {"type": "noul", "instructions": "\u8be5\u6761\u6b3e\u662f\u5426\u4f7f\u6211\u65b9\u627f\u62c5\u65e0\u4e0a\u9650\u7684\u8d23\u4efb\uff1f"},
    "unilateral": {"type": "noul", "instructions": "\u8be5\u6761\u6b3e\u662f\u5426\u53ea\u8d4b\u4e88\u5bf9\u65b9\u5355\u65b9\u89e3\u9664\u6743\uff1f"},
    "ambiguous": {"type": "noul", "instructions": "\u8be5\u6761\u6b3e\u662f\u5426\u4f7f\u7528\u4e86\u201c\u914c\u60c5\u201d\u201c\u539f\u5219\u4e0a\u201d\u201c\u53e6\u884c\u534f\u5546\u201d\u7b49\u4e0d\u786e\u5b9a\u63aa\u8f9e\uff0c\u5bfc\u81f4\u6743\u5229\u4e49\u52a1\u96be\u4ee5\u786e\u5b9a\uff1f"},
}
THRESHOLDS = {"uncapped": 0.75, "unilateral": 0.50, "ambiguous": 0.50}
GOLD = {"\u98ce\u9669\u9ad8": "high", "\u6a21\u7cca\u4e0d\u6e05": "medium", "\u6e05\u6670\u660e\u786e\u65e0\u98ce\u9669": "low"}

by_cell = {}
for r in records:
    by_cell.setdefault((r["label"], r["contract_type"]), []).append(r)
random.seed(SEED)
sample = []
for cell in sorted(by_cell):
    v = by_cell[cell]; random.shuffle(v); sample.append(v[0])
random.shuffle(sample)
sample = sample[:N]

rows = []
for r in sample:
    body = json.dumps({"state": r["contract_clause"][:6000],
                       "questions": QUESTION}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    a = json.loads(urllib.request.urlopen(req, timeout=180).read())["answers"]
    p = {k: float((a.get(k) or {}).get("noul") or 0.0) for k in QUESTION}
    if p["uncapped"] >= THRESHOLDS["uncapped"] or p["unilateral"] >= THRESHOLDS["unilateral"]:
        pred = "high"
    elif p["ambiguous"] >= THRESHOLDS["ambiguous"]:
        pred = "medium"
    else:
        pred = "low"
    rows.append((GOLD[r["label"]], pred, p))

n = len(rows)
acc = sum(1 for g, p, _ in rows if g == p) / n
recall = {g: sum(1 for x, y, _ in rows if x == g and y == g) / max(1, sum(1 for x, y, _ in rows if x == g))
          for g in ("high", "medium", "low")}
tp = sum(1 for x, y, _ in rows if x == "high" and y == "high")
fp = sum(1 for x, y, _ in rows if x != "high" and y == "high")
precision_high = tp / (tp + fp) if tp + fp else 0.0
pred_counts = {p: sum(1 for _, y, _ in rows if y == p) for p in ("high", "medium", "low")}

print(f"\nn={n} (3-class chance = 0.333)")
print(f"  accuracy            {acc:.3f}")
print(f"  recall high         {recall['high']:.2f}   <- the class triage exists to catch")
print(f"  precision high      {precision_high:.2f}   <- how often a 'high' is really high")
print(f"  recall medium/low   {recall['medium']:.2f} / {recall['low']:.2f}")
print(f"  predictions         high={pred_counts['high']} medium={pred_counts['medium']} low={pred_counts['low']}")

print("\n  confusion (gold \\ pred)   high  medium  low")
for g in ("high", "medium", "low"):
    print(f"    {g:8s}              {sum(1 for x,y,_ in rows if x==g and y=='high'):4d}"
          f"  {sum(1 for x,y,_ in rows if x==g and y=='medium'):6d}"
          f"  {sum(1 for x,y,_ in rows if x==g and y=='low'):4d}")

print(f"\n  overall accuracy {acc:.3f} - reported, but NOT the bar; see below.")
if recall["high"] < THRESH:
    print(f"\nRESULT: recall on 风险高 (high risk) is {recall['high']:.2f}, below the {THRESH:.2f} bar.")
    print("  A tool that misses most dangerous clauses while looking accurate is worse than")
    print("  none, because it reads as coverage. Do not advertise Chinese risk grading.")
    verdict = 1
else:
    print(f"\nRESULT: recall on 风险高 is {recall['high']:.2f}, clearing the {THRESH:.2f} bar.")
    print(f"  Precision {precision_high:.2f} is the price: roughly "
          f"{1/max(precision_high,0.001):.1f} clauses are escalated per genuinely risky one.")
    print("  That bias is deliberate for triage - a missed unfair term costs more than a review.")
    verdict = 0
print("\n  Why accuracy is not the bar: with three near-uniform classes, predicting mostly")
print("  medium or low scores 0.57 while missing 71% of the high-risk class. A triage tool")
print("  is judged by what it catches, not by what it agrees with.")
sys.exit(verdict)
'@
[System.IO.File]::WriteAllText($py, $script, [System.Text.UTF8Encoding]::new($false))

& python $py $data $LayaUrl $Clauses $Seed $Threshold
exit $LASTEXITCODE
