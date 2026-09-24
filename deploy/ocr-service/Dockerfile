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

COPY app.py .

ENV OCR_PORT=8100
EXPOSE 8100
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8100"]
