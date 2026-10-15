"""Fetch the PP-OCRv4 detection/recognition/classification weights at IMAGE BUILD time.

Run once by the Dockerfile so the weights are baked into the ocr-service image
instead of being downloaded from paddleocr.bj.bcebos.com on the client's first
extraction. See the Dockerfile comment for the measurement that motivated it
(269.9s cold vs 3.4s warm, against a 300s client timeout in pacgate-api).

This deliberately constructs PaddleOCR THE SAME WAY app.py does rather than
fetching individual files by URL. Constructing it is what triggers PaddleOCR's
own downloader, so the baked set can never drift from what the service asks for
at runtime - if app.py changes lang or enables another model, this follows
automatically.

The values below MUST stay in step with get_ocr() in app.py.
"""

import logging
import os
import sys

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ocr-warmup")

LANG = os.environ.get("PACGATE_OCR_LANG", "ch")
USE_ANGLE_CLS = True

if __name__ == "__main__":
    from paddleocr import PaddleOCR

    logger.info("fetching PaddleOCR weights (lang=%s, angle_cls=%s)", LANG, USE_ANGLE_CLS)
    PaddleOCR(use_angle_cls=USE_ANGLE_CLS, lang=LANG, show_log=True, use_gpu=False)

    if not os.path.isdir("/root/.paddleocr"):
        logger.error("PaddleOCR did not create /root/.paddleocr - the bake would be empty")
        sys.exit(1)

    total = 0
    count = 0
    for root, _dirs, files in os.walk("/root/.paddleocr"):
        for name in files:
            count += 1
            total += os.path.getsize(os.path.join(root, name))
    logger.info("baked %d file(s), %.1f MB", count, total / 1024 / 1024)
