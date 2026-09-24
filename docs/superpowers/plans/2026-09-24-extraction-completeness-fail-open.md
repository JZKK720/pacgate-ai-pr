# Extraction Completeness Fail-Open Fix - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the pipeline from declaring a document `sanitized` when its pages were never actually read.

**Architecture:** Two services both lose the "did we really read this?" signal. `ocr-service` sets `incomplete` only when OCR *throws*, so a page that renders fine and yields no text is reported as a complete read. `pacgate-api` never persists completeness at all — `extract.rs` returns a literal `incomplete: false` from its cache-hit branch, and `document_spans` has no column to record it. The fix records completeness per document version in a new `document_extractions` table, makes that the cache key instead of "are there any spans", and fails closed when a page produces nothing.

**Tech Stack:** Rust (pacgate-api, sqlx/PostgreSQL), Python (FastAPI, PaddleOCR in ocr-service), PowerShell gate scripts, Docker Compose.

**Spec:** `docs/superpowers/specs/2026-09-24-document-coverage-and-text-sanitize-design.md` — this plan implements §5 (workstream 1, Plan A). Read §2.2 and §5 before starting; they contain the measured evidence this plan is derived from.

## Global Constraints

- **Fail closed.** When completeness cannot be determined, report `incomplete = true`. `sanitize.rs` already refuses on that value, so a refusal is the correct outcome and requires no sanitizer change.
- **Do NOT modify `sanitize.rs`.** §2.5 of the spec proves the redaction logic is sound (2 redactions on a correctly-read ID). Its `if extracted.incomplete { refuse }` guard is the mechanism this plan feeds.
- **Do NOT modify the sanitizer's redaction rules, detectors, or policy.** Out of scope.
- **Deploy path is `origin/main` → GHCR → `install.ps1 -Update`.** No per-machine code, no manual steps on an AIPC.
- **Dev-box image shadowing is expected.** `ocr-service` is pinned to `ghcr.io/jzkk720/ocr-service:0.1.17` in both compose files. Testing a local build requires a retag over that pinned tag plus `--force-recreate`; the shadow is lost on the next `docker compose pull`. This is the established pattern in this repo (see `plans/019-ocr-and-ner.md` lineage and the 0.1.14 frontend retag).
- **Derive the ingress port; never assume one.** The compose file declares nginx on `8089:80`, and the live stack publishes `8089`. Older notes in this repo say `8081` — that is a stale dev-box fact, not a rule. Probe the RUNNING container (`docker port pacgate-nginx 80`), fall back to the compose-declared value, then to `8089`.
- **`/version` is at the nginx ROOT, not under `/pacgate`.** Probing `<base>/version` hits auth middleware and answers 401, which reads as an auth failure. Check both shapes.
- **PowerShell is case-INSENSITIVE for variables.** Use named variables; never a short name that could collide with an existing one differing only in case (this exact trap caused a two-step-away failure in `scripts/test-legal-journey.ps1`).
- **Exit-code semantics for gate scripts:** `0` = pass, `1` = a real failure, `2` = cannot check (environment not available). A "cannot check" must never be reported as a pass.

---

## File Structure

| File | Responsibility |
|---|---|
| `deploy/ocr-service/app.py` | Modify. Page loop must mark a page failed when it yields no text lines, not only when OCR throws. |
| `pacgate-ai/migrations/008_document_extractions.sql` | Create. Records completeness per `(document, version)`. This is the missing column. |
| `pacgate-ai/crates/pacgate-rag/src/lib.rs` | Modify. Register migration 008 in `run_migrations` so it applies at API startup. |
| `pacgate-ai/crates/pacgate-api/src/extract.rs` | Modify. Persist completeness on write; read it on cache hit instead of the `false` literal; key the cache on the extraction record. |
| `scripts/test-empty-extraction-gate.ps1` | Create. The regression gate. Assertions grow as tasks land. |

No file grows unwieldy. `extract.rs` gains roughly 60 lines; the rest are small, single-purpose edits.

---

## Task 1: The failing gate (RED)

**Why first:** the spec's §2.2 is already a reproducible failure. This task turns the ad-hoc probe into a committed gate so the fix has a test that fails for the right reason before any code changes.

**Files:**
- Create: `scripts/test-empty-extraction-gate.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/test-empty-extraction-gate.ps1` with parameters `-BaseUrl`, `-EnvFile`, `-KeepArtifacts`, and exit codes 0/1/2. Later tasks append assertions to this same file and re-run it.

- [ ] **Step 1: Write the gate with the A1 assertion and a CONTROL**

Create `scripts/test-empty-extraction-gate.ps1`:

```powershell
# PROVES an extraction that read nothing cannot pass the sanitization gate.
#
# WHY THIS EXISTS
#
# A blank page reported `incomplete=False`, so sanitize ran on empty text, got a
# pass verdict, marked the document 'sanitized', and the download gate opened.
# A document nobody could read was released.
#
# Three assertions, and the CONTROL is as important as the other two: a fix that
# marks EVERYTHING incomplete would pass A1/A2 while breaking the product, so the
# control must stay green throughout.
#
#   A1  a blank page          -> extract incomplete=true  -> sanitize REFUSED
#   A2  text on p1 + blank p2 -> extract incomplete=true  -> sanitize REFUSED
#   CONTROL  normal text page -> extract incomplete=false -> sanitize PASSES
#
# Exit: 0 = all pass, 1 = a real failure, 2 = cannot check (stack unreachable).

[CmdletBinding()]
param(
    [string]$BaseUrl = '',
    [string]$EnvFile = '',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repo 'deploy/client-bundle/.env' }

$script:failures = 0
$script:checks = 0

function Check($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) {
        Write-Host "  [PASS] $label" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $label" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:failures++
    }
}

function Die($msg) {
    Write-Host "`nCANNOT CHECK: $msg" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== empty-extraction gate ===' -ForegroundColor Cyan

# ── Resolve the ingress port from the RUNNING container, never from a constant ──
# `docker port` reads the live container; `docker compose port` reads the compose
# project, which answers the DECLARED mapping and can differ from what is actually
# published (that mismatch is exactly how a stale 8081/8089 assumption hides).
if (-not $BaseUrl) {
    $derived = ''
    try {
        $published = docker port pacgate-nginx 80 2>$null
        if ($published -match ':(\d+)\s*$') { $derived = $Matches[1] }
    } catch { }
    if (-not $derived) {
        try {
            $published = docker compose -f (Join-Path $repo 'deploy/client-bundle/compose.prod.yaml') port nginx 80 2>$null
            if ($published -match ':(\d+)\s*$') { $derived = $Matches[1] }
        } catch { }
    }
    if (-not $derived) { $derived = '8089' }
    $BaseUrl = "http://localhost:$derived/pacgate"
}
Write-Host "  base: $BaseUrl"

if (-not (Test-Path $EnvFile)) { Die "credentials file not found: $EnvFile" }

$email = $null; $password = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^PACGATE_API_EMAIL=(.+)$')    { $email    = $Matches[1].Trim() }
    if ($line -match '^PACGATE_API_PASSWORD=(.+)$') { $password = $Matches[1].Trim() }
}
if (-not $email -or -not $password) { Die 'PACGATE_API_EMAIL / PACGATE_API_PASSWORD missing from .env' }

# ── Reachability: /version is at the nginx ROOT, not under /pacgate ──
$rootUrl = ($BaseUrl -replace '/pacgate/?$', '')
$version = $null
foreach ($candidate in @("$rootUrl/version", "$BaseUrl/version")) {
    try {
        $v = Invoke-RestMethod -Uri $candidate -TimeoutSec 10
        if ($v.version) { $version = $v; break }
    } catch { }
}
if (-not $version) { Die "no version answered at $rootUrl/version or $BaseUrl/version" }
Write-Host "  version=$($version.version) revision=$($version.revision)"

# ── Auth ──
$token = $null
foreach ($path in @("$BaseUrl/api/auth/login", "$BaseUrl/auth/login")) {
    try {
        $body = @{ email = $email; password = $password } | ConvertTo-Json -Compress
        $login = Invoke-RestMethod -Uri $path -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 20
        if ($login.token) { $token = $login.token; break }
    } catch { }
}
if (-not $token) { Die 'login failed on both route shapes' }
$AuthHeaders = @{ Authorization = "Bearer $token" }

# ── Fixture builder: runs inside the ocr-service image, which has PIL ──
# Only 'blank' and 'control' come from here. The partial case needs page 1 to
# carry text and page 2 to be blank, so it has its own builder below - an earlier
# draft tried to fold it in here and produced two blank pages, which would have
# made A2 assert the wrong thing.
function New-FixturePdf {
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$Kind   # blank | control
    )
    if ($Kind -ne 'blank' -and $Kind -ne 'control') {
        throw "New-FixturePdf: unsupported Kind '$Kind' (use blank or control)"
    }
    $dir = Split-Path $OutPath -Parent
    $leaf = Split-Path $OutPath -Leaf
    # `-c` with a PowerShell here-string, matching the two existing fixture
    # builders in this repo (test-legal-journey.ps1:161, test-sanitizer-e2e.ps1:18).
    # An earlier draft piped the script to `python3 -` over stdin; NO gate in this
    # repo uses that form, so it was replaced with the pattern proven on this box.
    docker run --rm -v "${dir}:/fix" --entrypoint python3 ocr-service:local -c @"
from PIL import Image, ImageDraw, ImageFont
W, H = 1400, 500
try:
    font = ImageFont.truetype('DejaVuSans-Bold.ttf', 56)
except OSError:
    font = ImageFont.load_default()

if '$Kind' == 'blank':
    Image.new('RGB', (W, H), 'white').save('/fix/$leaf', 'PDF', resolution=150)
else:
    img = Image.new('RGB', (W, H), 'white')
    d = ImageDraw.Draw(img)
    d.text((40, 150), '11010519491231002X', fill='black', font=font)
    d.text((40, 280), '13812345678', fill='black', font=font)
    img.save('/fix/$leaf', 'PDF', resolution=150)
"@ 2>&1 | Out-Null
    return (Test-Path $OutPath)
}

function New-PartialFixturePdf {
    param([Parameter(Mandatory)][string]$OutPath)
    $dir = Split-Path $OutPath -Parent
    $leaf = Split-Path $OutPath -Leaf
    $pyScript = @"
from PIL import Image, ImageDraw, ImageFont
W, H = 1400, 500
try:
    font = ImageFont.truetype('DejaVuSans-Bold.ttf', 56)
except OSError:
    font = ImageFont.load_default()
p1 = Image.new('RGB', (W, H), 'white')
d = ImageDraw.Draw(p1)
d.text((40, 150), '11010519491231002X', fill='black', font=font)
p2 = Image.new('RGB', (W, H), 'white')
p1.save('/fix/$leaf', 'PDF', resolution=150, save_all=True, append_images=[p2])
"@
    docker run --rm -v "${dir}:/fix" --entrypoint python3 ocr-service:local -c $pyScript 2>&1 | Out-Null
    return (Test-Path $OutPath)
}

# ── Upload helper ──
function Send-Upload {
    param([string]$MatterId, [string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $boundary = "----emptygate$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $prefix = "--$boundary`r`nContent-Disposition: form-data; name=`"matter_id`"`r`n`r`n$MatterId`r`n" +
              "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"case.pdf`"`r`n" +
              "Content-Type: application/pdf`r`n`r`n"
    $suffix = "`r`n--$boundary--`r`n"
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes($prefix))
    $bw.Write($bytes)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes($suffix))
    $bw.Flush()
    return Invoke-RestMethod -Uri "$BaseUrl/api/documents" -Method Post `
        -Headers $AuthHeaders -ContentType "multipart/form-data; boundary=$boundary" `
        -Body $ms.ToArray() -TimeoutSec 120
}

# ── Matter ──
$matter = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Method Post -Headers $AuthHeaders `
    -TimeoutSec 20 -ContentType 'application/json' `
    -Body (@{ name = "emptygate-$([guid]::NewGuid().ToString('N').Substring(0,8))";
               description = 'empty-extraction gate' } | ConvertTo-Json -Compress)
$matterId = $matter.id
if (-not $matterId) { Die 'matter create returned no id' }
Write-Host "  matter=$matterId"
$script:createdDocs = @()

$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "emptygate-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

function Invoke-Case {
    param([string]$Label, [string]$FilePath, [string]$ExpectIncomplete)
    Write-Host ''
    Write-Host "== $Label" -ForegroundColor Cyan

    $doc = Send-Upload -MatterId $matterId -FilePath $FilePath
    if (-not $doc.id) { Check "$Label - upload" $false 'upload returned no id'; return }
    $script:createdDocs += $doc.id

    $extract = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$($doc.id)/extract" -Method Post `
        -Headers $AuthHeaders -ContentType 'application/json' -Body '{}' -TimeoutSec 300
    Write-Host "     extract incomplete=$($extract.incomplete) chars=$(($extract.text | Measure-Object -Character).Characters)"
    Check "$Label - extract reports incomplete=$ExpectIncomplete" `
        ("$($extract.incomplete)" -eq $ExpectIncomplete) `
        "got incomplete=$($extract.incomplete), expected $ExpectIncomplete"

    $sanitizeStatus = $null
    try {
        $sanitizeStatus = (Invoke-WebRequest -Uri "$BaseUrl/api/documents/$($doc.id)/sanitize" -Method Post `
            -Headers $AuthHeaders -ContentType 'application/json' -Body '{"data_level":"T3"}' `
            -TimeoutSec 300 -UseBasicParsing).StatusCode
    } catch {
        $sanitizeStatus = [int]$_.Exception.Response.StatusCode.value__
    }

    $downloadStatus = $null
    try {
        $downloadStatus = (Invoke-WebRequest -Uri "$BaseUrl/api/documents/$($doc.id)/download" `
            -Headers $AuthHeaders -TimeoutSec 60 -UseBasicParsing).StatusCode
    } catch {
        $downloadStatus = [int]$_.Exception.Response.StatusCode.value__
    }

    if ($ExpectIncomplete -eq 'true') {
        Check "$Label - sanitize is REFUSED (not 200)" ($sanitizeStatus -ne 200) `
            "sanitize returned $sanitizeStatus; an unread document must not be sanitized"
        Check "$Label - download is REFUSED (not 200)" ($downloadStatus -ne 200) `
            "download returned $downloadStatus; the egress gate must stay shut"
    } else {
        Check "$Label - sanitize PASSES (200)" ($sanitizeStatus -eq 200) `
            "sanitize returned $sanitizeStatus; a readable document must still sanitize"
        Check "$Label - download ALLOWED (200)" ($downloadStatus -eq 200) `
            "download returned $downloadStatus; the egress gate must open"
    }
}

# A1 - blank page. THE assertion this plan exists for.
$blankPdf = Join-Path $fixtureDir 'blank.pdf'
if (-not (New-FixturePdf -OutPath $blankPdf -Kind 'blank')) {
    Die 'could not build the blank fixture (is ocr-service:local present?)'
}
Invoke-Case -Label 'A1 blank page' -FilePath $blankPdf -ExpectIncomplete 'true'

# A2 - text on page 1, blank page 2. A half-read document must not be complete.
$partialPdf = Join-Path $fixtureDir 'partial.pdf'
if (-not (New-PartialFixturePdf -OutPath $partialPdf)) {
    Die 'could not build the partial fixture'
}
Invoke-Case -Label 'A2 partial read' -FilePath $partialPdf -ExpectIncomplete 'true'

# CONTROL - a normal readable page must still sanitize. This is what stops a
# lazy fix (mark everything incomplete) from looking green.
$controlPdf = Join-Path $fixtureDir 'control.pdf'
if (-not (New-FixturePdf -OutPath $controlPdf -Kind 'control')) {
    Die 'could not build the control fixture'
}
Invoke-Case -Label 'CONTROL readable page' -FilePath $controlPdf -ExpectIncomplete 'false'

# ── Cleanup ──
if (-not $KeepArtifacts) {
    foreach ($docId in $script:createdDocs) {
        try { Invoke-RestMethod -Uri "$BaseUrl/api/documents/$docId" -Method Delete -Headers $AuthHeaders -TimeoutSec 60 | Out-Null } catch { }
    }
    try { Invoke-RestMethod -Uri "$BaseUrl/api/matters/$matterId" -Method Delete -Headers $AuthHeaders -TimeoutSec 60 | Out-Null } catch { }
    Remove-Item -Recurse -Force $fixtureDir -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  cleanup done' -ForegroundColor DarkGray
}

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host "RESULT: $($script:checks) of $($script:checks) checks passed" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:failures) of $($script:checks) checks FAILED" -ForegroundColor Red
exit 1
```

- [ ] **Step 2: Run the gate and watch A1 and A2 fail**

Run:
```powershell
pwsh -File scripts/test-empty-extraction-gate.ps1
```

Expected: exit 1, with **6 of 9 checks FAILED**.

That is: A1 (3 checks) and A2 (3) each fail all three of theirs;
`CONTROL readable page` passes all three of ITS checks. `Invoke-Case` emits 3
checks per case — the fourth (`- upload`) only fires when the upload returns no
id, so it does not appear on a healthy run.

If the CONTROL does not pass all three, stop — the gate is wrong, not the product, and a broken gate would make the fix unfalsifiable.

- [ ] **Step 3: Commit the failing gate**

```powershell
git add scripts/test-empty-extraction-gate.ps1
git commit -m "test: failing gate for the empty-extraction fail-open

A blank page reports incomplete=False, so sanitize runs on empty text, marks the
document 'sanitized', and the download gate opens. This gate asserts the refusal
(A1), the partial-read case (A2), and - critically - that a readable page still
sanitizes (CONTROL), so a fix that marks everything incomplete cannot pass."
```

---

## Task 2: `ocr-service` marks a no-text page as failed

**Files:**
- Modify: `deploy/ocr-service/app.py` (the page loop inside `extract`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `/extract` returns `incomplete: true` when any page yields zero text lines. Response shape is unchanged: `{text, pages, spans, engine, incomplete}`.

**Context for the implementer:** `incomplete` currently becomes true only inside the two `except` paths. A rasterised page that OCRs to nothing hits `if not result: continue` and stays complete. A page whose `result[0]` is empty or None has the same problem one level deeper.

- [ ] **Step 1: Make the page loop fail closed**

In `deploy/ocr-service/app.py`, replace the page loop body. The current code is:

```python
        for page_no, img_path in pages:
            if img_path is None:
                incomplete = True
                continue
            try:
                result = ocr.ocr(img_path, cls=True)
            except Exception:
                logger.exception("page %s failed to parse", page_no)
                incomplete = True
                continue
            if not result:
                continue
            for line in result[0] or []:
                box, (text, _conf) = line[0], line[1]
                xs = [int(p[0]) for p in box]
                ys = [int(p[1]) for p in box]
                spans.append(
                    {
                        "page": page_no,
                        "x": min(xs),
                        "y": min(ys),
                        "width": max(xs) - min(xs),
                        "height": max(ys) - min(ys),
                        "text": text,
                    }
                )
                all_text.append(text)
```

Replace it with:

```python
        for page_no, img_path in pages:
            if img_path is None:
                incomplete = True
                continue
            try:
                result = ocr.ocr(img_path, cls=True)
            except Exception:
                logger.exception("page %s failed to parse", page_no)
                incomplete = True
                continue

            # FAIL CLOSED on a page that produced nothing.
            #
            # Two shapes mean "this page yielded no text": an empty/None `result`,
            # and a `result[0]` that is empty or None. The previous code used
            # `continue` for the first and iterated past the second, leaving
            # `incomplete = False` - so a page whose content was never recovered
            # was reported as a COMPLETE read. That is the fail-open this guards.
            #
            # A blank page is indistinguishable here from a page whose read
            # failed, so both are reported incomplete. The caller decides whether
            # to refuse; reporting a false "complete" is not an option.
            if not result:
                logger.warning("page %s produced no OCR result; marking incomplete", page_no)
                incomplete = True
                continue

            page_lines = result[0] or []
            if not page_lines:
                logger.warning("page %s produced no text lines; marking incomplete", page_no)
                incomplete = True
                continue

            page_span_count = 0
            for line in page_lines:
                box, (text, _conf) = line[0], line[1]
                xs = [int(p[0]) for p in box]
                ys = [int(p[1]) for p in box]
                spans.append(
                    {
                        "page": page_no,
                        "x": min(xs),
                        "y": min(ys),
                        "width": max(xs) - min(xs),
                        "height": max(ys) - min(ys),
                        "text": text,
                    }
                )
                all_text.append(text)
                page_span_count += 1

            if page_span_count == 0:
                logger.warning("page %s yielded no spans; marking incomplete", page_no)
                incomplete = True
```

- [ ] **Step 2: Update the module docstring's contract line**

In the same file, the docstring currently says:

```python
`incomplete` is the fail-closed flag: any page that fails to parse leaves it
True, and the caller MUST treat the document as pending rather than trusting
a partial extraction (spec section 7: 不得因未提取到文字就视为不存在敏感信息).
```

Replace with:

```python
`incomplete` is the fail-closed flag: any page that FAILS TO PARSE **or YIELDS
NO TEXT** leaves it True, and the caller MUST treat the document as pending
rather than trusting a partial extraction (spec section 7: 不得因未提取到文字就视为不存在敏感信息).

A page that rasterises cleanly but produces no text lines sets this flag. Do not
narrow it to "only when OCR throws" - a page whose content was not recovered is
exactly the case the product must refuse.
```

- [ ] **Step 3: Rebuild and shadow the pinned image on the dev box**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
docker build -t ocr-service:local deploy/ocr-service
docker tag ocr-service:local ghcr.io/jzkk720/ocr-service:0.1.17
cd deploy/client-bundle
docker compose -f compose.prod.yaml up -d --force-recreate ocr-service
```

Note: `--force-recreate` is required. Compose does not recreate a container when only the image content under an unchanged tag changed, so without it the old container keeps running and the gate would test stale code.

- [ ] **Step 4: Run the gate - A1 should now be fully green; A2 stays half red (expected)**

Run:
```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
pwsh -File scripts/test-empty-extraction-gate.ps1
```

Expected: **`RESULT: 7 of 9 checks passed`**, exit **1**.

What flips and what does not:

- **A1 passes all 3.** A blank page yields `chars=0` and ZERO spans, so `sanitize`
  re-extracts FRESH and hits the path this task fixed. Its refusal and download
  checks flip to passing with no change to `sanitize.rs` — it already refuses on
  `incomplete == true`.
- **A2's extract check passes** (`incomplete=True`), but **its sanitize and download
  checks still FAIL**.
- **CONTROL still passes all 3.** Any CONTROL failure means the fix is marking
  readable content incomplete — stop and report.

**Why A2 is only half fixed, and why that is correct at this point.** `sanitize.rs`
calls `extract_document` itself (`sanitize.rs:124`). By the time the gate sanitizes,
spans for that `(document, version)` already exist from the earlier `/extract` call,
so `extract.rs:80` takes the **cache branch** — which still returns the hardcoded
`incomplete: false` at `extract.rs:102`. A2's two remaining failures are therefore
the CACHE defect, which Task 4 fixes. They are not a sign that this task failed.

An earlier draft of this step predicted `9 of 9` here, reasoning that honest
`incomplete` alone would flip the refusals. That was wrong — it ignored that the
gate's own `/extract` call warms the cache before `/sanitize` runs. Measured
reality: `7 of 9`.

Do NOT "fix" A2 by touching `sanitize.rs` or the gate. If you believe either is
wrong, stop and report.

- [ ] **Step 5: Commit**

```powershell
git add deploy/ocr-service/app.py
git commit -m "fix(ocr): fail closed when a page yields no text

incomplete was set only when OCR threw. A page that rasterised cleanly and
yielded zero text lines fell through as a COMPLETE read, so an unreadable page
was reported as a successful extraction and sanitize acted on empty text.

A blank page is indistinguishable here from a failed read, so both now report
incomplete=true and the caller refuses. The caller keeps the policy decision;
this service stops claiming a read it did not perform."
```

---

## Task 3: A2 for the CACHE path (RED again)

**Why a second RED:** Task 2 fixes a FRESH extraction. The cache is a separate path with its own defect — `extract.rs` returns a literal `incomplete: false`, so the SECOND read of a partial extraction reports complete. This task extends the gate to prove it.

**Files:**
- Modify: `scripts/test-empty-extraction-gate.ps1`

**Interfaces:**
- Consumes: the gate script from Task 1.
- Produces: an `-AssertCache` block that reads the same document twice and asserts the second read still reports `incomplete=true`. Task 4 makes it pass.

- [ ] **Step 1: Add the cache assertion to the gate**

In `scripts/test-empty-extraction-gate.ps1`, add this function immediately before the `# A1 - blank page` block:

```powershell
function Invoke-CacheCase {
    <#
      Proves the extraction CACHE can represent an incomplete extraction.

      A partial read is recorded on the first /extract call. The second call takes
      the cache branch. If that branch returns a hardcoded `incomplete: false`,
      the cached answer contradicts the live one - and because
      pacgate_ocr_batch exists to PRE-WARM this cache, a sanitize that runs later
      would inherit "complete" for a document that was only half read.
    #>
    param([string]$Label, [string]$FilePath)

    Write-Host ''
    Write-Host "== $Label" -ForegroundColor Cyan

    $doc = Send-Upload -MatterId $matterId -FilePath $FilePath
    if (-not $doc.id) { Check "$Label - upload" $false 'upload returned no id'; return }
    $script:createdDocs += $doc.id

    $first = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$($doc.id)/extract" -Method Post `
        -Headers $AuthHeaders -ContentType 'application/json' -Body '{}' -TimeoutSec 300
    Check "$Label - first extract incomplete=true" ("$($first.incomplete)" -eq 'true') `
        "got incomplete=$($first.incomplete)"

    $second = Invoke-RestMethod -Uri "$BaseUrl/api/documents/$($doc.id)/extract" -Method Post `
        -Headers $AuthHeaders -ContentType 'application/json' -Body '{}' -TimeoutSec 300
    Write-Host "     cached read: incomplete=$($second.incomplete) chars=$(($second.text | Measure-Object -Character).Characters)"
    Check "$Label - CACHED extract still reports incomplete=true" `
        ("$($second.incomplete)" -eq 'true') `
        "the cache branch reported incomplete=$($second.incomplete); the stored completeness was lost"
}
```

Then add the call immediately before the CONTROL block:

```powershell
# A2-cache - the SAME partial document read twice. The cache must not upgrade a
# partial extraction to complete.
Invoke-CacheCase -Label 'A2c cached partial read' -FilePath $partialPdf
```

- [ ] **Step 2: Run the gate and watch the cache assertion fail**

Run:
```powershell
pwsh -File scripts/test-empty-extraction-gate.ps1
```

Expected: exit 1 again, with **3 of 11 checks FAILED**.

At this point the gate has A1 (3), A2 (3), A2c cache (2) and CONTROL (3) = 11
checks. Task 2 made the LIVE read path honest, so:

- `A1` — all 3 PASS (a blank page has zero spans, so `sanitize` re-extracts fresh)
- `A2` — extract PASSES; `sanitize` and `download` **still FAIL** (2 failures)
- `A2c` — `first extract` PASSES; `CACHED extract` **FAILS** (1 failure)
- `CONTROL` — all 3 PASS

**3 failures, all the same defect seen from two angles.** `A2c` sees the cache
directly (two `/extract` calls). `A2` sees it indirectly: `sanitize.rs:124` calls
`extract_document` itself, and by then spans exist from the gate's earlier
`/extract`, so the cache branch runs and returns the literal `false`.

An earlier draft of this step said "2 of 11, the only failures are A2c's". That was
stale — written before Task 2's correction established that A2 stays half red. The
plan's own Task 4 section already states it fixes BOTH `A2c` and A2's two checks,
which is the correct reading; this step now agrees with it.

If `A2c`'s CACHED check passes, stop and report — that would mean the cache path is
already correct, contradicting `extract.rs:102`. Do not "fix" anything in that case.

- [ ] **Step 3: Commit**

```powershell
git add scripts/test-empty-extraction-gate.ps1
git commit -m "test: assert the extraction cache preserves incompleteness

The cache branch returns a hardcoded incomplete:false, so the second read of a
partial extraction reports complete. This assertion runs before the fix, so the
cache defect is proven rather than inferred."
```

---

## Task 4: Persist completeness and make it the cache key

**Files:**
- Create: `pacgate-ai/migrations/008_document_extractions.sql`
- Modify: `pacgate-ai/crates/pacgate-rag/src/lib.rs:414-440` (register the migration)
- Modify: `pacgate-ai/crates/pacgate-api/src/extract.rs:60-180` (cache key, read, write)

**Interfaces:**
- Consumes: the `incomplete` flag produced by `/extract` (Task 2).
- Produces: table `document_extractions(tenant_id, matter_id, document_id, document_version, incomplete BOOLEAN NOT NULL, engine TEXT, pages INTEGER, extracted_at TIMESTAMPTZ)` with `UNIQUE (document_id, document_version)`. `extract_document` continues to return `ExtractedDocument { text, pages, spans, incomplete }` — same shape, now honest on the cache path.

- [ ] **Step 1: Create the migration**

Create `pacgate-ai/migrations/008_document_extractions.sql`:

```sql
-- Pacgate-ai extraction completeness record. Migration 008.
--
-- WHY THIS TABLE EXISTS
--
-- Extraction is cached so that a per-job sanitize costs ZERO OCR calls on a warm
-- cache, and so a bulk OCR pass can pre-warm it once for many later sanitizes.
-- The cached artifact is document_spans + kb_chunks.
--
-- But `incomplete` - whether every page was really read - had nowhere to live.
-- extract.rs's cache branch returned a hardcoded false, so any document with at
-- least one span read back as COMPLETE, however much of it was never parsed.
-- sanitize.rs refuses only on incomplete=true, so a partially-read document was
-- declared 'sanitized' and released through the egress gate.
--
-- This row is the missing fact. It is also the CACHE KEY: a document whose pages
-- all yielded nothing has zero spans, and keying the cache on "are there spans"
-- would have made that case a permanent cache miss (re-OCRing forever) while
-- still being unable to record that it was incomplete.
--
-- NO BACKFILL, deliberately. Rows extracted before this migration have unknown
-- completeness. Backfilling them as complete would bake the old defect into the
-- new column. They are treated as cache misses and re-extracted on first access,
-- which records the TRUE flag. That costs one OCR pass per pre-existing document
-- and cannot mislabel one.

CREATE TABLE IF NOT EXISTS document_extractions (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id         UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    matter_id         UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    document_id       UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    document_version  INTEGER NOT NULL,
    -- TRUE when any page failed to parse or yielded no text. sanitize.rs refuses
    -- on TRUE, so this column is what keeps an unread document out of egress.
    incomplete        BOOLEAN NOT NULL,
    -- Which extractor produced this. 'paddleocr' today; a text-native converter
    -- will add its own label, and the label makes a stale cache detectable when
    -- the extractor changes.
    engine            TEXT,
    pages             INTEGER NOT NULL DEFAULT 0,
    extracted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- One row per document version. The version binding is the correctness
    -- property: a new upload bumps documents.version, so a stale row can never
    -- be served for a newer file.
    UNIQUE (document_id, document_version)
);

CREATE INDEX IF NOT EXISTS idx_document_extractions_doc
    ON document_extractions (tenant_id, matter_id, document_id, document_version);
```

- [ ] **Step 2: Register the migration so it applies at API startup**

In `pacgate-ai/crates/pacgate-rag/src/lib.rs`, find the block that applies migration 007:

```rust
            // Migration 007 adds the sanitizer job + ledger tables. Without it,
            // the job API (plan 020) has nowhere to persist the vault or the
            // redaction evidence.
            let sanitizer_sql = include_str!("../../../migrations/007_sanitizer_jobs.sql");
            sqlx::raw_sql(sanitizer_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;

            Ok::<(), RagError>(())
```

Replace with:

```rust
            // Migration 007 adds the sanitizer job + ledger tables. Without it,
            // the job API (plan 020) has nowhere to persist the vault or the
            // redaction evidence.
            let sanitizer_sql = include_str!("../../../migrations/007_sanitizer_jobs.sql");
            sqlx::raw_sql(sanitizer_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;

            // Migration 008 records extraction COMPLETENESS per document version.
            // Without it, extract.rs cannot distinguish a fully-read document from
            // a partially-read one, and a document whose pages yielded no text is
            // reported as complete - which lets it be marked 'sanitized' and
            // released through the egress gate.
            let extractions_sql = include_str!("../../../migrations/008_document_extractions.sql");
            sqlx::raw_sql(extractions_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;

            Ok::<(), RagError>(())
```

Then update the success log line so the applied set is not understated:

```rust
        tracing::info!(
            "RAG migrations applied (002_schema + 003_enrichment + 004_data_level + 005_sanitization_state + 006_document_spans + 007_sanitizer_jobs + 008_document_extractions)"
        );
```

- [ ] **Step 3: Make the cache read completeness instead of a literal**

In `pacgate-ai/crates/pacgate-api/src/extract.rs`, find the cache block. It currently begins:

```rust
    // Cache check: any spans stored for this exact (document, version) mean
    // the extraction already ran.
    let cached = sqlx::query(
        "SELECT id, page, x, y, width, height, text FROM document_spans \
         WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 AND document_version = $4 \
         ORDER BY page, y, x",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .bind(document_id.0)
    .bind(version)
    .fetch_all(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;

    if !cached.is_empty() {
        let text = load_cached_text(state, tenant_id, matter_id, document_id).await?;
        let spans = cached
            .iter()
            .map(|r| ExtractedSpan {
                page: r.get::<Option<i32>, _>("page").map(|p| p as u32),
                x: r.get("x"),
                y: r.get("y"),
                width: r.get("width"),
                height: r.get("height"),
                text: r.get("text"),
            })
            .collect();
        let pages = cached
            .iter()
            .map(|r| r.get::<Option<i32>, _>("page").unwrap_or(1))
            .max()
            .unwrap_or(1) as u32;
        return Ok(ExtractedDocument {
            text,
            pages,
            spans,
            incomplete: false,
        });
    }
```

Replace that whole block with:

```rust
    // Cache check: a recorded extraction for this exact (document, version) means
    // the extraction already ran.
    //
    // KEYED ON document_extractions, NOT on span-emptiness. A document whose pages
    // yielded no text has ZERO spans, so keying on spans made that case a
    // permanent cache miss (re-OCRing on every call) while still being unable to
    // say it was incomplete. The extraction record exists for every attempt, so
    // it is the correct cache key and the only place completeness can live.
    let extraction_state = sqlx::query(
        "SELECT incomplete, pages FROM document_extractions \
         WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 AND document_version = $4 \
         LIMIT 1",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .bind(document_id.0)
    .bind(version)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;

    if let Some(record) = extraction_state {
        let cached = sqlx::query(
            "SELECT id, page, x, y, width, height, text FROM document_spans \
             WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 AND document_version = $4 \
             ORDER BY page, y, x",
        )
        .bind(tenant_id.0)
        .bind(matter_id.0)
        .bind(document_id.0)
        .bind(version)
        .fetch_all(&state.db)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

        let text = load_cached_text(state, tenant_id, matter_id, document_id).await?;
        let spans = cached
            .iter()
            .map(|r| ExtractedSpan {
                page: r.get::<Option<i32>, _>("page").map(|p| p as u32),
                x: r.get("x"),
                y: r.get("y"),
                width: r.get("width"),
                height: r.get("height"),
                text: r.get("text"),
            })
            .collect();
        let recorded_pages: i32 = record.get("pages");
        let pages = if recorded_pages > 0 {
            recorded_pages as u32
        } else {
            cached
                .iter()
                .map(|r| r.get::<Option<i32>, _>("page").unwrap_or(1))
                .max()
                .unwrap_or(1) as u32
        };
        // The stored flag, not a literal. This is the line that was the defect.
        let incomplete: bool = record.get("incomplete");
        return Ok(ExtractedDocument {
            text,
            pages,
            spans,
            incomplete,
        });
    }
```

- [ ] **Step 4: Persist completeness on the write path**

In the same file, the tail of `extract_document` currently reads:

```rust
    // Persist: spans to document_spans, text to kb_chunks as pending.
    persist_extraction(state, tenant_id, matter_id, document_id, version, &spans).await?;
    if !text.is_empty() {
        ingest_text_pending(state, tenant_id, matter_id, document_id, &text).await?;
    }

    Ok(ExtractedDocument {
        text,
        pages,
        spans,
        incomplete,
    })
}
```

Replace with:

```rust
    // Persist: spans to document_spans, text to kb_chunks as pending, and the
    // completeness fact to document_extractions. Order matters for the cache:
    // the extraction record is written FIRST, so a crash between the two writes
    // leaves a record with no spans (a cache hit reporting honestly, with empty
    // text) rather than spans with no record (a cache miss that re-OCRs).
    record_extraction(
        state,
        tenant_id,
        matter_id,
        document_id,
        version,
        incomplete,
        pages,
        &engine,
    )
    .await?;
    persist_extraction(state, tenant_id, matter_id, document_id, version, &spans).await?;
    if !text.is_empty() {
        ingest_text_pending(state, tenant_id, matter_id, document_id, &text).await?;
    }

    Ok(ExtractedDocument {
        text,
        pages,
        spans,
        incomplete,
    })
}

/// Record extraction completeness for a document version.
///
/// Upsert on `(document_id, document_version)` so a re-extraction of the same
/// version replaces its own record rather than accumulating rows.
///
/// The `incomplete` flag is the reason this exists: it is what `sanitize.rs`
/// reads to decide whether the document may be sanitized at all.
#[allow(clippy::too_many_arguments)]
async fn record_extraction(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
    version: i32,
    incomplete: bool,
    pages: u32,
    engine: &str,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO document_extractions \
         (tenant_id, matter_id, document_id, document_version, incomplete, engine, pages) \
         VALUES ($1, $2, $3, $4, $5, $6, $7) \
         ON CONFLICT (document_id, document_version) DO UPDATE SET \
             incomplete = EXCLUDED.incomplete, \
             engine = EXCLUDED.engine, \
             pages = EXCLUDED.pages, \
             extracted_at = NOW()",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .bind(document_id.0)
    .bind(version)
    .bind(incomplete)
    .bind(engine)
    .bind(pages as i32)
    .execute(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("failed to record extraction state: {e}")))?;
    Ok(())
}
```

- [ ] **Step 5: Capture the engine label**

`record_extraction` takes `engine`. In `extract_document`, the engine is not currently extracted from the OCR response. Immediately after the `pages` binding, add:

```rust
    // The engine label is stored so a future extractor change is detectable:
    // a cache row whose engine differs from the configured one is stale text,
    // not a valid cache hit.
    let engine = body
        .get("engine")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string();
```

Find the existing lines:

```rust
    let pages = body.get("pages").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
```

and replace with:

```rust
    let pages = body.get("pages").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
    // The engine label is stored so a future extractor change is detectable:
    // a cache row whose engine differs from the configured one is stale text,
    // not a valid cache hit.
    let engine = body
        .get("engine")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string();
```

- [ ] **Step 6: Build the API**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
cargo build -p pacgate-api
```

Expected: compiles. If `record.get("incomplete")` fails to resolve, note that `sqlx::Row` must be in scope — it already is at the top of `extract.rs` (`use sqlx::Row;`).

- [ ] **Step 7: Apply the migration to the live database**

The API applies migrations at startup, but the running container is the published 0.1.17 image and does not have migration 008. Apply it directly so the gate can run before a release:

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
Get-Content pacgate-ai/migrations/008_document_extractions.sql -Raw |
    docker exec -i pacgate-db psql -U pacgate -d pacgate -v ON_ERROR_STOP=1
```

Verify:
```powershell
docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c "SELECT column_name FROM information_schema.columns WHERE table_name='document_extractions' ORDER BY ordinal_position;"
```

Expected: `id`, `tenant_id`, `matter_id`, `document_id`, `document_version`, `incomplete`, `engine`, `pages`, `extracted_at`.

- [ ] **Step 8: Run the gate - all assertions pass**

The gate needs the new API binary, not just the migration. Build and shadow it the same way as Task 2:

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
docker build -t pacgate-api:local -f pacgate-ai/Dockerfile pacgate-ai
docker tag pacgate-api:local ghcr.io/jzkk720/pacgate-api:0.1.17
cd deploy/client-bundle
docker compose -f compose.prod.yaml up -d --force-recreate pacgate-api
```

Then run:
```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
pwsh -File scripts/test-empty-extraction-gate.ps1
```

Expected: `RESULT: 11 of 11 checks passed`, exit 0.

The count is A1 (3) + A2 (3) + A2c cache (2) + CONTROL (3). Note that Task 4 fixes
BOTH A2c and A2's sanitize/download checks, because both exercise the cache path.
A2c is still worth keeping: it asserts the cache contract DIRECTLY (two
`/extract` calls, no sanitize in between), whereas A2's failures only reach the
cache indirectly through `sanitize`'s internal extract call. A direct assertion
survives a future change that stops `sanitize` from re-extracting.

If the script reports a different total, trust the script's own count — the
requirement is **zero FAILED**, not a particular number.

A note on the build: the API Dockerfile's paths assume context = `pacgate-ai/` (matching `build-ghcr.yml`'s `context: pacgate-ai`), so `-f pacgate-ai/Dockerfile pacgate-ai` is the correct invocation. `pacgate-ai/.dockerignore` exists and excludes `target/`, so the context stays small.

- [ ] **Step 9: Commit**

```powershell
git add pacgate-ai/migrations/008_document_extractions.sql pacgate-ai/crates/pacgate-rag/src/lib.rs pacgate-ai/crates/pacgate-api/src/extract.rs
git commit -m "fix(extract): persist extraction completeness and key the cache on it

extract.rs returned a hardcoded incomplete:false from the cache branch, and
document_spans had no column to record the truth. A partially-read document
therefore reported COMPLETE on every cached read, and pacgate_ocr_batch made it
worse by pre-warming that cache - so a later sanitize inherited 'complete' for a
document only half read.

Migration 008 adds document_extractions, one row per document version, holding
the incomplete flag. The cache branch reads it instead of a literal, and the
cache is now keyed on the extraction record rather than on span-emptiness - a
document whose pages yielded no text has zero spans, so the old key made that
case a permanent cache miss that still could not report itself as incomplete.

No backfill: pre-existing rows have unknown completeness, and defaulting them to
'complete' would bake the old defect into the new column. They re-extract once on
first access and record the true flag."
```

---

## Task 5: Wire the gate into the suite

**Files:**
- Modify: `scripts/run-all-checks.ps1`

**Interfaces:**
- Consumes: `scripts/test-empty-extraction-gate.ps1` from Tasks 1-3.
- Produces: the gate runs as part of the standard suite, so a regression is caught by the suite rather than by memory.

- [ ] **Step 1: Read how the suite invokes an existing live-stack gate**

Run:
```powershell
pwsh -Command "Select-String -Path scripts/run-all-checks.ps1 -Pattern 'test-sanitizer-e2e|test-legal-journey|exit 2|CannotCheck' -Context 3,3"
```

Read the surrounding pattern before editing. The suite distinguishes a real failure from "cannot check" — a live-stack gate that exits 2 must not fail the suite, because a developer without the stack running should still get a green suite.

- [ ] **Step 2: Add the gate following that exact pattern**

Insert the invocation next to the other live-stack gates, matching the file's existing style for naming, colouring, and the exit-2 carve-out. Use the path `scripts/test-empty-extraction-gate.ps1`.

- [ ] **Step 3: Run the suite**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
pwsh -File scripts/run-all-checks.ps1
```

Expected: the new gate is listed and passes; no other suite regresses. If another suite fails, investigate it before committing — do not comment out the new gate to get green.

- [ ] **Step 4: Commit**

```powershell
git add scripts/run-all-checks.ps1
git commit -m "test: run the empty-extraction gate in the standard suite

A regression gate nobody runs is not a gate. Wired in beside the other
live-stack gates, preserving the suite's exit-2 'cannot check' carve-out so a
developer without the stack running still gets a meaningful suite result."
```

---

## Task 6: Verify the deploy path delivers it

**Why this task exists:** the spec's Global Constraints require delivery via `install.ps1 -Update`. A fix that only works on this dev box (because of a local image shadow) is not delivered. This task proves the shadow is the only local dependency and that the release path carries the change.

**Files:**
- No file changes. Verification only.

- [ ] **Step 1: Confirm the local shadows are exactly the two components changed**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
docker inspect pacgate-api ocr-service --format '{{.Name}} image={{.Config.Image}}'
docker image ls --format '{{.Repository}}:{{.Tag}} {{.ID}}' | Select-String 'pacgate-api|ocr-service'
```

Expected: both containers run a tag matching `ghcr.io/jzkk720/*:0.1.17`, and the local images `pacgate-api:local` / `ocr-service:local` share an ID with that tag. This confirms the shadow is by retag, not a different reference — so `docker compose pull` would revert BOTH, and the fix is only real once released.

**Do NOT use `/version` to identify the shadow — it cannot.** On a dev-box retag
`/version` reports `revision=unknown`, because the local build command does not pass
`--build-arg PAC_SOURCE_REVISION=...` and the Dockerfile defaults it to `unknown`
outside CI. So the staleness marker the Dockerfile exists to provide is INERT on a
shadow, and `unknown` will never distinguish new code from stale.

Prove the running container carries the NEW code by inspecting the binary instead:

```powershell
# Plan A's marker: the new error string in record_extraction
docker exec pacgate-api grep -c 'failed to record extraction state' /usr/local/bin/pacgate-server
docker exec pacgate-api ls /app/migrations | Select-String '008'
docker logs pacgate-api 2>&1 | Select-String '008_document_extractions' | Select-Object -Last 1
```

Expected: `1`, `008_document_extractions.sql`, and a startup line naming 008 in the
applied-migrations log. That trio is the real proof.

**Use `--no-deps` when force-recreating a single service:**
`docker compose up -d --force-recreate --no-deps pacgate-api`. Without `--no-deps`,
compose may also recreate the service's dependencies, which violates the
"do not tear down other services" rule in this plan.

- [ ] **Step 2: Record the release requirement in the spec**

Append to §12 (Delivery) of `docs/superpowers/specs/2026-09-24-document-coverage-and-text-sanitize-design.md`:

```markdown
### Plan A release requirement

`ocr-service` and `pacgate-api` are both single-container images (the Dockerfiles
`COPY app.py` / build the crate), so neither can be delivered by a bind-mount or a
config change. Plan A therefore requires a **tagged release** that rebuilds both
images. Migration 008 is applied automatically by `pacgate-api` at startup, so no
separate migration step is needed on a client machine.

Until that release ships, the fix exists only as a dev-box image shadow and
`docker compose pull` reverts it.
```

- [ ] **Step 3: Commit the spec update**

```powershell
git add docs/superpowers/specs/2026-09-24-document-coverage-and-text-sanitize-design.md
git commit -m "docs(spec): record Plan A's release requirement

ocr-service and pacgate-api are both baked into their images, so neither can be
delivered by config or a bind-mount - Plan A needs a tagged release that rebuilds
both. Migration 008 applies automatically at API startup."
```

---

## Self-Review

**Spec coverage (§5, workstream 1):**

| §5 requirement | Task |
|---|---|
| `ocr-service` sets incomplete when a page yields neither text nor spans | Task 2 |
| New migration recording completeness per document version | Task 4, Step 1 |
| `extract.rs` cache branch reads the record instead of the literal | Task 4, Step 3 |
| `sanitize.rs` unchanged | Global Constraints; no task touches it — and Task 2 Step 4 shows the refusal already works |
| Test: blank page must not reach `sanitized` or download 200 | Task 1 (A1) |
| Test: cached partial extraction reports incomplete | Task 3 (A2c) |

**Gaps deliberately left:** spec §7's conversion coverage gate (header/footer detection) belongs to Plan B — it protects the *converter* path, which does not exist yet. Spec §2.3's missing bridge is Plan B. Neither is in scope here.

**Placeholder scan:** every step carries real code. The one count I could not state exactly is the gate's final check total in Task 4 Step 8, which is stated as "adjust to what the script reports; the requirement is zero FAILED" rather than a fabricated number.

**Type consistency:**
- `record_extraction(state, tenant_id, matter_id, document_id, version, incomplete, pages, &engine)` — declared in Task 4 Step 4, called in Step 4's write path with `version` (the `i32` read at the top of `extract_document`), `incomplete`/`pages` (from the OCR response), `&engine` (`String`, so `&String` coerces to `&str`).
- `document_extractions` columns used in Step 3's SELECT (`incomplete`, `pages`) match Step 1's DDL and Step 4's INSERT.
- `ExtractedDocument.incomplete` is unchanged as a field name and type (`bool`) across the cache and fresh branches.
- The gate's `Send-Upload`, `Invoke-Case`, `Invoke-CacheCase`, and `New-FixturePdf`/`New-PartialFixturePdf` are all defined before first use.

**One correction applied during review:** the first draft of Task 1's fixture builder had a `partial` branch that generated two blank pages (a copy-paste error) while the assertion expected page 1 to carry text. It was split into `New-PartialFixturePdf`, which builds page 1 with the ID and page 2 blank, so A2 tests a genuine partial read. `New-FixturePdf` now rejects any `Kind` other than `blank`/`control` rather than silently falling through to the control branch.

**Second correction:** an invalid `.Substring()` call was chained onto `Write-Host` output. `Write-Host` returns nothing, so the call would have thrown under `$ErrorActionPreference = 'Stop'` before any assertion ran — the gate would have died at the reachability banner and reported nothing useful.

**Third correction:** the expected gate total was stated as 12 before the checks were counted; the script produces 11. The number is now derived from the assertions rather than guessed, and the plan states the real requirement (zero FAILED) in case the count shifts as assertions are added.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-24-extraction-completeness-fail-open.md`.

Two execution options:

**1. Subagent-Driven (recommended)** — a fresh subagent per task, with review between tasks. The per-task review matters here because Task 2 and Task 4 both produce a RED-then-GREEN transition that is easy to fake by adjusting the test.

**2. Inline Execution** — execute the tasks in this session with checkpoints.

**Which approach?**
