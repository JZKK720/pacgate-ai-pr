# ocr-service - PaddleOCR extraction over HTTP.
# CPU image; works on GPU machines with OCR_USE_GPU=0. A CUDA base variant can
# be added when measured throughput demands it (plan 019 limitation).
FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    libgl1 \
    poppler-utils  \
    libgomp1 \
    fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Bake the PP-OCRv4 weights into the image.
#
# WHY. The weights were deliberately NOT baked ("the model download happens on
# first extraction"), and that is a deployability defect, not just a latency one.
# The single upstream source is paddleocr.bj.bcebos.com, so on an AIPC behind a
# restrictive network the FIRST extraction may never complete: measured
# 2026-10-13 on this box, a cold /extract of a one-page fixture took 269.9s
# against a 300s client timeout in pacgate-api (crates/pacgate-api/src/extract.rs)
# - roughly 10% headroom, so it fails intermittently rather than consistently.
# With the weights present the same call is 3.4s and a second call is 0.14s.
#
# It is also cheap: the download is ~17 MB, not the ~1.5GB the CI comment used to
# claim. Baking removes an entire external-network dependency from the client
# install path, which is the point - a fresh AIPC must not need a Chinese CDN to
# read its first document.
#
# The weights live at /root/.paddleocr/whl/{det,rec,cls}/. NOTHING may be mounted
# over /root/.paddleocr from here on: a mount point REPLACES the directory rather
# than layering over it, so a mounted volume shadows this baked copy and PaddleOCR
# goes back to bcebos for whatever the volume lacks. compose.prod.yaml and
# compose.bundle.yaml used to mount a `paddleocr-models` volume here and no longer
# do; `scripts/test-ocr-bake-integrity.ps1` fails if one comes back.
#
# The warm-up runs the REAL construction path rather than fetching specific
# files, so the baked set always matches what app.py actually asks for. The
# lang/angle_cls values here MUST stay in step with get_ocr() in app.py -
# warm_up.py is the single source for the download and is invoked the same way.
# That agreement is asserted statically by the same gate.
ARG PACGATE_OCR_LANG=ch
COPY warm_up.py .
RUN PACGATE_OCR_LANG="${PACGATE_OCR_LANG}" python warm_up.py \
    && test -d /root/.paddleocr/whl/det \
    && test -d /root/.paddleocr/whl/rec \
    && test -d /root/.paddleocr/whl/cls \
    && du -sh /root/.paddleocr

COPY app.py .

ENV OCR_PORT=8100
EXPOSE 8100
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8100"]
