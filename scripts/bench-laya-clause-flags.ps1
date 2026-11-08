<#
.SYNOPSIS
    Measure laya clause-flag accuracy against CUAD, with real ground truth.

.DESCRIPTION
    WHY THIS EXISTS (2026-11-01).

    Until now the claim "laya flags risky clauses" rested on four hand-written
    clauses per language. That is a smoke test, not a benchmark. This measures the
    shipped questions against CUAD (Contract Understanding Atticus Dataset): 510
    real commercial contracts, ~13,000 expert span annotations over 41 clause
    categories, CC BY 4.0 and explicitly "free to the public for commercial and
    non-commercial use".

    Four of CUAD's categories are the direct semantic counterparts of the flags in
    pacgate-mcp's `pacgate_clause_flags`, which is why this is possible at all:

        flag                          CUAD category                  positives/510
        uncapped_liability            Uncapped Liability                       111
        termination_for_convenience   Termination For Convenience             183
        auto_renewal                  Renewal Term                            176
        dispute_waiver                Covenant Not To Sue                     100

    DESIGN NOTES THAT MATTER - each of these produced a wrong number first:

    1. NEGATIVES COME FROM UNRELATED CATEGORIES IN THE SAME CONTRACTS. The first
       run used one hand-written benign sentence for every negative, and that
       sentence was itself a CUAD positive ("Either party may terminate ... on
       thirty days' notice" IS a Termination For Convenience). So the flag scored
       AUC 0.235 - worse than chance - and the number described the control, not
       the model.

    2. THE QUESTION MUST NAME THE SAME CONCEPT AS THE LABEL. CUAD's Termination
       For Convenience includes MUTUAL rights; the shipped `unilateral_termination`
       adds an asymmetry requirement CUAD does not label. Measured: the matching
       question ("may a party end without cause") scores AUC 0.988, while the
       asymmetry version scores 0.600 on the same clauses. Both are honest numbers
       about different questions. This script measures the concept CUAD labels.

    3. HARD NEGATIVES WHERE THEY EXIST. For uncapped liability the negative is
       `Cap On Liability` - the direct semantic opposite - not an unrelated clause.
       A benchmark that cannot distinguish those is measuring topic, not risk.

    4. LAYA ROUTES BY SCRIPT. Latin text goes to the `english` checkpoint, so an
       English-only benchmark says nothing about Chinese. This script is English
       only by design and says so in its output.

.PARAMETER Contracts
    Number of contracts to sample. 25 gives 80 predictions in ~25s and is enough to
    separate a working flag from a broken one; raise it for a tighter estimate.

.PARAMETER Seed
    Sampling seed, so a reported number can be reproduced.

.PARAMETER LayaUrl
    laya-serve endpoint. Must be running with the `english` checkpoint loaded.

.PARAMETER Keep
    Keep the downloaded dataset (~38 MB) for the next run.

.EXAMPLE
    pwsh -NoProfile -File scripts/bench-laya-clause-flags.ps1 -Contracts 25

.NOTES
    Exit codes: 0 = benchmark ran and every flag is above chance; 1 = a flag is at
    or below chance (AUC <= 0.55), which means it must not be advertised as a risk
    signal; 2 = cannot check (no laya, no dataset).
#>
[CmdletBinding()]
param(
    [int]$Contracts = 25,
    [int]$Seed = 11,
    [string]$LayaUrl = 'http://127.0.0.1:8000/v1/systemone',
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

# ── preflight ────────────────────────────────────────────────────────────────
try {
    $health = Invoke-RestMethod -Uri ($LayaUrl -replace '/v1/systemone$', '/health') -TimeoutSec 15
    if ($health.loaded -notcontains 'english') {
        Write-Host "  CANNOT CHECK: laya is up but the 'english' checkpoint is not loaded." -ForegroundColor Yellow
        Write-Host "  English text routes to that checkpoint; set LAYA_MODELS=multilingual,english." -ForegroundColor Yellow
        exit 2
    }
    Write-Host "laya ready: $($health.loaded -join ', ')"
}
catch {
    Write-Host "  CANNOT CHECK: laya is not reachable at $LayaUrl" -ForegroundColor Yellow
    Write-Host '  Start it: docker compose --profile laya up -d laya' -ForegroundColor Yellow
    exit 2
}

$dataDir = Join-Path $env:TEMP 'laya-cuad-bench'
$cuad = Join-Path $dataDir 'CUAD_v1.json'
if (-not (Test-Path -LiteralPath $cuad)) {
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $url = 'https://huggingface.co/datasets/theatticusproject/cuad/resolve/main/CUAD_v1/CUAD_v1.json'
    Write-Host '  downloading CUAD (38 MB, CC BY 4.0)...'
    try { Invoke-WebRequest -Uri $url -OutFile $cuad -TimeoutSec 900 }
    catch {
        Write-Host "  CANNOT CHECK: could not download CUAD - $($_.Exception.Message)" -ForegroundColor Yellow
        exit 2
    }
}

# ── the benchmark itself (python: JSON handling here is not worth PS gymnastics) ──
$py = Join-Path $dataDir 'bench.py'
$script = @'
import json, random, sys, time, urllib.request

CUAD, URL, N_CONTRACTS, SEED = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

QUESTIONS = {
 "uncapped_liability": {"type": "noul", "instructions": "Does this clause expose our client to liability with no cap?"},
 "termination_for_convenience": {"type": "noul", "instructions": "May a party end this agreement without cause, for convenience, on notice?"},
 "auto_renewal": {"type": "noul", "instructions": "Does this clause renew the agreement automatically unless notice is given?"},
 "dispute_waiver": {"type": "noul", "instructions": "Does this clause waive or restrict our client's right to litigate or arbitrate?"},
}
POSITIVE_CATEGORY = {
 "uncapped_liability": "Uncapped Liability",
 "termination_for_convenience": "Termination For Convenience",
 "auto_renewal": "Renewal Term",
 "dispute_waiver": "Covenant Not To Sue",
}
# Hard negative where one exists (the semantic opposite), otherwise unrelated
# categories from the same contract so contract style cannot leak the answer.
NEGATIVE_CATEGORIES = {
 "uncapped_liability": ["Cap On Liability"],
 "termination_for_convenience": ["Governing Law", "Parties", "Agreement Date"],
 "auto_renewal": ["Governing Law", "Parties"],
 "dispute_waiver": ["Governing Law", "Parties"],
}

def predict(clause, flag):
    body = json.dumps({"state": clause[:6000], "questions": {flag: QUESTIONS[flag]}}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    return float(json.loads(urllib.request.urlopen(req, timeout=180).read())["answers"][flag]["noul"])

def auc(pos, neg):
    if not pos or not neg: return float("nan")
    w = sum(1 for p in pos for n in neg if p > n) + 0.5 * sum(1 for p in pos for n in neg if p == n)
    return w / (len(pos) * len(neg))

data = json.load(open(CUAD, encoding="utf-8"))
random.seed(SEED)
rows, used, t0 = [], 0, time.time()

for item in data["data"]:
    qas = {q["id"].split("__")[-1]: q for q in item["paragraphs"][0]["qas"]}
    made = False
    for flag, cat in POSITIVE_CATEGORY.items():
        pos = [a["text"] for a in qas.get(cat, {}).get("answers", []) if a.get("text")]
        neg = [a["text"] for c in NEGATIVE_CATEGORIES[flag]
               for a in qas.get(c, {}).get("answers", []) if a.get("text")]
        if not pos or not neg: continue
        rows.append({"flag": flag, "truth": True,  "p": predict(random.choice(pos), flag)})
        rows.append({"flag": flag, "truth": False, "p": predict(random.choice(neg), flag)})
        made = True
    if made: used += 1
    if used >= N_CONTRACTS: break

elapsed = time.time() - t0
print(f"\n{used} contracts, {len(rows)} predictions, {elapsed:.0f}s")
print(f"{'flag':30s} {'n':>3s} {'AUC':>6s} {'P@0.5':>6s} {'R@0.5':>6s} {'F1':>5s}  med(pos) med(neg)")
worst = []
for flag in POSITIVE_CATEGORY:
    rs = [r for r in rows if r["flag"] == flag]
    pos = [r["p"] for r in rs if r["truth"]]; neg = [r["p"] for r in rs if not r["truth"]]
    if not pos or not neg: continue
    a = auc(pos, neg)
    tp = sum(1 for x in pos if x >= .5); fp = sum(1 for x in neg if x >= .5)
    prec = tp / (tp + fp) if tp + fp else 0.0; rec = tp / len(pos)
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    sp, sn = sorted(pos), sorted(neg)
    print(f"{flag:30s} {len(rs):3d} {a:6.3f} {prec:6.2f} {rec:6.2f} {f1:5.2f}   {sp[len(sp)//2]:.2f}     {sn[len(sn)//2]:.2f}")
    if a <= 0.55: worst.append((flag, a))

print("\nNote: English only - laya routes Latin text to the `english` checkpoint,")
print("so this says nothing about Chinese accuracy.")
if worst:
    print(f"\nRESULT: {len(worst)} flag(s) are not better than chance and must not be advertised as risk signals:")
    for f, a in worst: print(f"  {f} (AUC {a:.3f})")
    sys.exit(1)
print("\nRESULT: every flag separates positives from negatives better than chance.")
sys.exit(0)
'@
[System.IO.File]::WriteAllText($py, $script, [System.Text.UTF8Encoding]::new($false))

& python $py $cuad $LayaUrl $Contracts $Seed
$code = $LASTEXITCODE

if (-not $Keep) { Remove-Item -LiteralPath $py -Force -ErrorAction SilentlyContinue }
exit $code
