"""ocr-service - PaddleOCR wrapped as an HTTP extraction service.

Contract with pacgate-api (design 3.1):
  POST /extract  multipart(file, page_from?, page_to?)
  -> {"text": str, "pages": int,
      "spans": [{"page": int, "x": int, "y": int, "width": int,
                 "height": int, "text": str}, ...],
      "engine": "paddleocr", "incomplete": bool}

`incomplete` is the fail-closed flag: any page that FAILS TO PARSE **or YIELDS
NO TEXT** leaves it True, and the caller MUST treat the document as pending
rather than trusting a partial extraction (spec section 7: 不得因未提取到文字就视为不存在敏感信息).

A page that rasterises cleanly but produces no text lines sets this flag. Do not
narrow it to "only when OCR throws" - a page whose content was not recovered is
exactly the case the product must refuse.
"""

import logging
import os

from fastapi import FastAPI, File, Form, UploadFile

logging.basicConfig(level=os.environ.get("OCR_LOG_LEVEL", "INFO"))
logger = logging.getLogger("ocr-service")

app = FastAPI(title="ocr-service", version="0.1.0")

# Initialised lazily on first request so the container starts fast and the
# model download happens once, visible in logs.
_ocr = None


def get_ocr():
    global _ocr
    if _ocr is None:
        from paddleocr import PaddleOCR

        use_gpu = os.environ.get("OCR_USE_GPU", "0") == "1"
        logger.info("initialising PaddleOCR (use_gpu=%s)", use_gpu)
        _ocr = PaddleOCR(use_angle_cls=True, lang="ch", show_log=False, use_gpu=use_gpu)
    return _ocr


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/extract")
async def extract(
    file: UploadFile = File(...),
    page_from: int = Form(0),
    page_to: int = Form(0),
):
    """Extract text + spans from a document.

    page_from/page_to are 1-based; 0/0 means all pages.
    """
    import tempfile

    data = await file.read()
    suffix = os.path.splitext(file.filename or "doc")[1] or ".pdf"

    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(data)
        tmp_path = tmp.name

    try:
        ocr = get_ocr()
        pages = _prepare_pages(tmp_path, suffix, page_from, page_to)
        all_text: list[str] = []
        spans: list[dict] = []
        incomplete = False

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

        return {
            "text": "\n".join(all_text),
            "pages": len(pages),
            "spans": spans,
            "engine": "paddleocr",
            "incomplete": incomplete,
        }
    finally:
        os.unlink(tmp_path)


def _prepare_pages(tmp_path: str, suffix: str, page_from: int, page_to: int):
    """Normalise input to a list of (page_no, image_path).

    Images are returned as-is (page 1). PDFs are rasterised per page with
    pdf2image; a page that fails rasterisation yields (page_no, None) so the
    caller can set the incomplete flag rather than silently skipping.
    """
    import shutil

    if suffix.lower() == ".pdf":
        if shutil.which("pdftoppm") is None:
            logger.error("pdftoppm missing: pdf rasterisation unavailable")
            return [(1, None)]
        from pdf2image import convert_from_path

        first = max(page_from, 1)
        last = page_to if page_to >= first else 0
        try:
            pages = convert_from_path(tmp_path, first_page=first, last_page=last or None)
        except Exception:
            logger.exception("pdf rasterisation failed")
            return [(first, None)]
        images = []
        import tempfile as tf

        for i, img in enumerate(pages):
            out = tf.NamedTemporaryFile(suffix=".png", delete=False)
            img.save(out.name, format="PNG")
            out.close()
            images.append((first + i, out.name))
        return images

    return [(1, tmp_path)]