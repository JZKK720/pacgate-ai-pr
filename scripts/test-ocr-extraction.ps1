# test-ocr-extraction.ps1 - End-to-end OCR extraction proof (plan 019 Task 5).
#
# Proves: a PNG containing an ID-card-shaped string is OCR'd by ocr-service,
# text comes back, spans carry page/coordinates, and /extract reports
# incomplete=false. Run from the repo root on a machine with Docker.
#
# Usage: powershell -File scripts/test-ocr-extraction.ps1
param(
    # The ocr-service image under test. Empty = the release image at the version in
    # pacgate-ai/Cargo.toml, DERIVED so it follows the release instead of relying
    # on an invented `ocr-service:local` tag that nothing builds.
    [string]$OcrImage = ''
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$failed = $false
function Assert-True($cond, $name) {
    if ($cond) { Write-Output "PASS: $name" }
    else { Write-Output "FAIL: $name"; $script:failed = $true }
}

if (-not $OcrImage) {
    . (Join-Path $PSScriptRoot 'lib/Release-ImageState.ps1')
    $OcrImage = Get-ReleaseOcrImage
}
if (-not $OcrImage) {
    Write-Output 'SKIP: could not derive the release ocr-service image from Cargo.toml/compose.prod.yaml'
    exit 2
}
# Release window: the tag may not be published yet. Say so, rather than failing at
# `docker run` with a message that reads like a product fault.
if ((Test-ReleaseOcrImagePresent -Reference $OcrImage) -eq 'absent') {
    Write-Output "SKIP: $OcrImage is not published yet and is not present locally."
    exit 2
}

$cid = "ocr-e2e-" + (Get-Random)
$cleanup = { docker rm -f $cid 2>$null | Out-Null }

# 1. Start ocr-service
#
# Note there is NO weights volume, and that is now the PRODUCTION shape: the
# PP-OCRv4 weights are baked into the image and nothing may be mounted over
# /root/.paddleocr (a mount shadows the baked copy). This script therefore
# doubles as a proof of the bake, and `test-ocr-bake-integrity.ps1` keeps it
# that way.
Write-Output "== starting ocr-service ($OcrImage) =="
docker run -d --name $cid -p 8110:8100 $OcrImage | Out-Null
try {
    # Wait for boot
    $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        $h = (& cmd /c "docker exec $cid python -c ""from fastapi.testclient import TestClient; from app import app; print(TestClient(app).get('/health').json()['status'])"" 2>nul")
        if ($h -match 'ok') { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    Assert-True $ready "ocr-service boots and /health returns ok"

    # 2. Build the fixture PNG inside the container (Pillow is present).
    Write-Output "== building fixture =="
    docker exec $cid python -c "from PIL import Image, ImageDraw; im = Image.new('RGB', (420, 90), 'white'); d = ImageDraw.Draw(im); d.text((15, 30), 'ID 11010519491231002X', fill='black'); im.save('/tmp/e2e.png')"
    docker cp ${cid}:/tmp/e2e.png "$env:TEMP\pacgate-e2e.png" | Out-Null
    Assert-True (Test-Path "$env:TEMP\pacgate-e2e.png") "fixture PNG created"

    # 3. POST to /extract over the mapped port.
    Write-Output "== POST /extract =="
    # PIL's default font may not render digits; fall back to a real check:
    $boundary = [System.Guid]::NewGuid().ToString()
    $fileBytes = [System.IO.File]::ReadAllBytes("$env:TEMP\pacgate-e2e.png")
    $LF = [System.Text.Encoding]::ASCII.GetBytes("`r`n")
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"e2e.png`"`r`nContent-Type: image/png`r`n`r`n"))
    $bw.Write($fileBytes)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary--`r`n"))
    $bw.Flush()
    $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:8110/extract' -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $ms.ToArray() -UseBasicParsing
    $json = $resp.Content | ConvertFrom-Json

    Assert-True ($json.incomplete -eq $false) "incomplete == false"
    Assert-True ($json.text -match '110105') "text contains the ID-card digits"
    Assert-True ($json.spans.Count -ge 1) "at least one span returned"
    if ($json.spans.Count -ge 1) {
        Assert-True ($json.spans[0].page -eq 1) "span page == 1"
        Assert-True ($json.spans[0].x -ge 0 -and $json.spans[0].y -ge 0) "span coordinates non-negative"
        Write-Output "  span: page=$($json.spans[0].page) x=$($json.spans[0].x) y=$($json.spans[0].y) w=$($json.spans[0].width) h=$($json.spans[0].height) text='$($json.spans[0].text)'"
    }
    Write-Output "  pages=$($json.pages) engine=$($json.engine)"

    # 4. Persistence proof is exercised by plan Task 5's full path through
    # pacgate-api; this script proves the ocr-service half end to end.
} finally {
    & $cleanup
    Remove-Item "$env:TEMP\pacgate-e2e.png" -ErrorAction SilentlyContinue
}

if ($failed) { Write-Output "== RESULT: FAIL =="; exit 1 }
Write-Output "== RESULT: PASS =="
