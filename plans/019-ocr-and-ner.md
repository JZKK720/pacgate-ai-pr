# OCR Service and Tier 2-4 NER Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feed the redaction engine (plan 017) and complete its detection coverage: an `ocr-service` container that turns documents into text + spans + bounding boxes, and local Chinese NER so Tier 2-4 identifiers (names, orgs, accounts, credentials) become detectable.

**Architecture:** Two halves, independently shippable. **3a** adds `ocr-service` (a Python container wrapping PaddleOCR) plus the `document_spans` table; pacgate-api calls it over HTTP and caches per document version. **3b** integrates `bert-base-chinese-ner` via Candle into `pacgate-redact` as an additive `Detector` - the deterministic-first rule stays intact because model candidates are only ever *additive* to the rule layer, and the verifier replays the full set.

**Tech Stack:** Python 3.12 + PaddleOCR (Apache-2.0) in Docker · Rust: `candle-core`/`candle-transformers` + `tokenizers` (workspace deps) · Postgres.

**Spec:** `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md` (sections 3.1, 3.2, 3.6, 5.1)

## Locked decisions (evidence-backed 2026-09-18, recorded in design section 9)

| # | Decision | Choice | Evidence |
|---|---|---|---|
| 1 | BBox storage | **own `document_spans` table** (document, version, page, x/y/w/h, label, confidence) - NOT JSONB on kb_chunks | Research lane 1: review panels need row-level queries; v2 pixel redaction needs deterministic coords from the same record. Presidio image redactor stores `ocr_bboxes` as first-class records. A chunk is not a span. |
| 2 | Restore authorization | **role-gated + job-scoped + audit-logged** (one endpoint, three checks) | Research lane 2: auditable minimum. The job token already lives in our placeholders, so scoping is mechanical. Per-job tokens + audit rows were already structural. |
| 3 | Partial jobs | **atomic per document** - a job completes a document version or the whole version stays pending | Partial state has no defined meaning. Fail-closed. mark_sanitized is already document-scoped. |
| 4 | OpenViking gate | **accept clean-inputs-only as a documented limitation** for now | Routing memory writes through pacgate-mcp is a deliberate standalone decision; pre-existing boundary rule (conversational context only) limits exposure. Revisit with the review panel. |

## Global Constraints

- **Cargo on this machine:** `& "$env:USERPROFILE\.cargo\bin\cargo.exe"`, run from `pacgate-ai/`. Verified working (1.94.1). No bare `cargo` - it is not on PATH.
- **Workspace deps:** add to `[workspace.dependencies]` in `pacgate-ai/Cargo.toml` first, then `name.workspace = true`. No direct pins in crate manifests.
- **Deterministic-first:** model candidates are additive. The LLM/NER never performs final replacement; rules run first and the verifier replays the full set.
- **Fail-closed:** OCR unavailable, parse failure, or unrecognised output = the extraction is marked incomplete and the document stays `pending`. Never fall back to unsanitized text.
- **Atomic per document (decision 3):** `mark_sanitized` is called only when a document version completes. No partial states.
- **pending is the default** (already live in migration 005). Extraction must not change it; only a completed job promotes to sanitized.
- **No secrets:** no key, token or password in source, tests, fixtures or commit messages.
- **Hyphens not em-dashes** in visible copy.

---

## Part 3a - OCR service and spans

### Task 1: `document_spans` table (decision 1)

**Files:**
- Create: `pacgate-ai/migrations/006_document_spans.sql`
- Modify: `pacgate-ai/crates/pacgate-rag/src/lib.rs` (`run_migrations`)

**Interfaces:**
- Produces: `document_spans` table, one row per OCR text element.

- [ ] **Step 1: Write the migration**

Create `pacgate-ai/migrations/006_document_spans.sql`:

```sql
-- Pacgate-ai document spans: OCR text elements with coordinates.
-- Migration 006 - decision 1 (own table, not JSONB on kb_chunks).
--
-- One row per text element OCR found. Serves both consumers:
--   v1 review panel : row-level queries - all spans on page 2 of type X
--   v2 pixel redact : exact deterministic coords for the original raster,
--                     without re-running OCR
--
-- kb_chunks stores CHUNKS of text for retrieval; a span is a text ELEMENT
-- with a location. Different shapes, different tables.

CREATE TABLE IF NOT EXISTS document_spans (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    matter_id       UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    document_id     UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    document_version INTEGER NOT NULL,
    page            INTEGER,
    x               INTEGER NOT NULL,
    y               INTEGER NOT NULL,
    width           INTEGER NOT NULL,
    height          INTEGER NOT NULL,
    text            TEXT NOT NULL,
    label           TEXT,                   -- entity code when detected, e.g. CN_ID
    confidence      REAL,                   -- detector/OCR confidence
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_document_spans_doc
    ON document_spans (tenant_id, matter_id, document_id, document_version);
CREATE INDEX IF NOT EXISTS idx_document_spans_page
    ON document_spans (tenant_id, document_id, page);
```

- [ ] **Step 2: Wire into the runner**

In `pacgate-ai/crates/pacgate-rag/src/lib.rs`, inside `run_migrations`, after the 005 block and before `Ok::<(), RagError>(())`:

```rust
            // Migration 006 adds document_spans. Without it, span persistence
            // fails and v2 pixel redaction has no coordinates to work from.
            let spans_sql = include_str!("../../../migrations/006_document_spans.sql");
            sqlx::raw_sql(spans_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;
```

Update the completion log to name 006.

- [ ] **Step 3: Verify against live Postgres**

```
docker compose -f deploy/client-bundle/compose.prod.yaml up -d pacgate-db
Get-Content pacgate-ai/migrations/006_document_spans.sql -Raw | docker exec -i pacgate-db psql -U pacgate -d pacgate -v ON_ERROR_STOP=1
docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c "SELECT column_name FROM information_schema.columns WHERE table_name='document_spans' ORDER BY ordinal_position;"
```

Expected: 15 columns listed. Run the migration a second time - expect `already exists, skipping` notices and exit 0.

- [ ] **Step 4: Commit**

```bash
git add pacgate-ai/migrations/006_document_spans.sql pacgate-ai/crates/pacgate-rag/src/lib.rs
git commit -m "feat(db): add document_spans table for OCR text elements with coordinates"
```

---

### Task 2: ocr-service container (FastAPI + PaddleOCR)

**Files:**
- Create: `deploy/ocr-service/Dockerfile`
- Create: `deploy/ocr-service/app.py`
- Create: `deploy/ocr-service/requirements.txt`
- Modify: `deploy/client-bundle/compose.prod.yaml` (add the service, commented or active)

**Interfaces:**
- Produces: `POST /extract` accepting multipart `file` + `page_from`/`page_to`, returning:
  `{ "text": str, "pages": int, "spans": [ { page, x, y, width, height, text } ... ], "engine": "paddleocr", "incomplete": bool }`
- Consumes: nothing external; the container is stateless. GPU used when available (CUDA), falls back to CPU.

- [ ] **Step 1: Write requirements.txt**

Create `deploy/ocr-service/requirements.txt`:

```
fastapi==0.115.6
uvicorn[standard]==0.34.0
python-multipart==0.0.20
paddlepaddle==3.0.0
paddleocr==2.9.1
```

- [ ] **Step 2: Write app.py**

Create `deploy/ocr-service/app.py`:

```python
"""ocr-service - PaddleOCR wrapped as an HTTP extraction service.

Contract with pacgate-api (design 3.1):
  POST /extract  multipart(file, page_from?, page_to?)
  -> {"text": str, "pages": int,
      "spans": [{"page": int, "x": int, "y": int, "width": int,
                 "height": int, "text": str}, ...],
      "engine": "paddleocr", "incomplete": bool}

`incomplete` is the fail-closed flag: any page that fails to parse leaves it
True, and the caller MUST treat the document as pending rather than trusting
a partial extraction (spec section 7: 不得因未提取到文字就视为不存在敏感信息).
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
        # PaddleOCR accepts image paths directly; PDFs are rasterised first.
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

    images = [tmp_path]
    if suffix.lower() == ".pdf":
        if shutil.which("pdftoppm") is None:
            logger.error("pdftoppm missing: pdf rasterisation unavailable")
            return [(1, None)]
        from pdf2image import convert_from_path

        first = max(page_from, 1)
        last = page_to if page_to >= first else 0
        pages = convert_from_path(tmp_path, first_page=first, last_page=last or None)
        images = []
        import tempfile as tf

        for i, img in enumerate(pages):
            out = tf.NamedTemporaryFile(suffix=".png", delete=False)
            img.save(out.name, format="PNG")
            out.close()
            images.append((first + i, out.name))
    else:
        images = [(1, tmp_path)]
    return images
```

Also add `pdf2image==1.17.0` to requirements.txt, and add `poppler-utils` to the Dockerfile (pdf2image needs `pdftoppm`).

- [ ] **Step 3: Write the Dockerfile**

Create `deploy/ocr-service/Dockerfile`:

```dockerfile
# ocr-service - PaddleOCR extraction over HTTP.
# GPU image variant can be built later; this is the CPU image that also works
# on GPU machines via OCR_USE_GPU=0. Base includes glibc Paddle needs.
FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    poppler-utils \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

ENV OCR_PORT=8100
EXPOSE 8100
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8100"]
```

- [ ] **Step 4: Add the compose service (commented)**

Append to `deploy/client-bundle/compose.prod.yaml`, after the `pacgate-mcp` service:

```yaml
  # ocr-service: PaddleOCR extraction for scanned documents (plan 019).
  # Enabled when pacgate-api grows the extraction call; keep commented until
  # then to avoid a 1.5GB model download on upgrade of existing installs.
  # ocr-service:
  #   image: ghcr.io/jzkk720/ocr-service:0.1.14
  #   container_name: ocr-service
  #   environment:
  #     OCR_USE_GPU: "0"
  #     OCR_LOG_LEVEL: info
  #   restart: unless-stopped
```

- [ ] **Step 5: Build and smoke-test the container**

```
docker build -f deploy/ocr-service/Dockerfile -t ocr-service:local deploy/ocr-service
docker run -d --name ocr-test -p 8100:8100 ocr-service:local
docker logs ocr-test 2>&1 | Select-Object -First 5
```

Smoke test with any image containing text:
```
docker exec ocr-test python -c "from fastapi.testclient import TestClient; from app import app; c = TestClient(app); print(c.get('/health').json())"
```

Expected: `{"status": "ok"}`. Then remove the container. A full OCR test with a real scanned document belongs in Task 5's end-to-end step.

- [ ] **Step 6: Commit**

```bash
git add deploy/ocr-service deploy/client-bundle/compose.prod.yaml
git commit -m "feat(ocr): add ocr-service container wrapping PaddleOCR with span output"
```

---

### Task 3: pacgate-api extraction client with version-bound cache

**Files:**
- Create: `pacgate-ai/crates/pacgate-api/src/extract.rs`
- Modify: `pacgate-ai/crates/pacgate-api/src/lib.rs` (module), `state.rs` (config field)
- Modify: `pacgate-ai/crates/pacgate-api/Cargo.toml` (reqwest)

**Interfaces:**
- Consumes: `document_spans` (Task 1), ocr-service `/extract` (Task 2).
- Produces:
  - `pub struct ExtractedDocument { pub text: String, pub pages: u32, pub spans: Vec<ExtractedSpan>, pub incomplete: bool }`
  - `pub struct ExtractedSpan { pub page: Option<u32>, pub x: i32, pub y: i32, pub width: i32, pub height: i32, pub text: String }`
  - `pub async fn extract_document(state: &AppState, tenant_id: &TenantId, matter_id: &MatterId, document_id: &DocumentId) -> Result<ExtractedDocument, ApiError>` - checks the cache first (a warm cache means zero OCR calls for per-job sanitize, the property the bulk-scale operating condition requires); on cache miss calls ocr-service, persists text into `kb_chunks` **as `pending`** (extraction never promotes), and persists spans into `document_spans`.

- [ ] **Step 1: Add reqwest to pacgate-api**

Append to `[dependencies]` in `pacgate-ai/crates/pacgate-api/Cargo.toml`:

```toml
reqwest.workspace = true
```

(`reqwest` is already in `[workspace.dependencies]`.)

- [ ] **Step 2: Write extract.rs**

Create `pacgate-ai/crates/pacgate-api/src/extract.rs`:

```rust
//! Document extraction: OCR over HTTP, cached per document version.
//!
//! The cache-first property matters at bulk scale: the client ingests
//! hundreds of documents without sanitizing, then sanitizes a few per job.
//! Extraction happens ONCE per version; a warm cache means a per-job
//! sanitize makes ZERO OCR calls (design section 2).
//!
//! Extraction never promotes sanitization_state. New chunks land as
//! 'pending' (migration 005 default + ingest SQL), so nothing extracted
//! becomes retrievable until a job completes.

use axum::http::StatusCode;
use pacgate_core::{DataLevel, DocumentId, MatterId, TenantId};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::{error::ApiError, state::AppState};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtractedSpan {
    pub page: Option<u32>,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtractedDocument {
    pub text: String,
    pub pages: u32,
    pub spans: Vec<ExtractedSpan>,
    pub incomplete: bool,
}

/// Extract a document, cache-first.
///
/// Returns the cached extraction when this document version was already
/// extracted. The version binding is the correctness property: a new upload
/// bumps documents.version, so the cache can never serve text from an older
/// version of the file.
pub async fn extract_document(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
) -> Result<ExtractedDocument, ApiError> {
    let row = sqlx::query(
        "SELECT version, storage_path FROM documents WHERE id = $1 AND tenant_id = $2 AND matter_id = $3 LIMIT 1",
    )
    .bind(document_id.0)
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| match e {
        sqlx::Error::RowNotFound => ApiError::not_found("document not found"),
        other => ApiError::internal(other.to_string()),
    })?;

    let version: i32 = row.get("version");
    let storage_path: String = row.get("storage_path");

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
        return Ok(ExtractedDocument {
            text,
            pages: cached
                .iter()
                .map(|r| r.get::<Option<i32>, _>("page").unwrap_or(1))
                .max()
                .unwrap_or(1) as u32,
            spans,
            incomplete: false,
        });
    }

    // Cache miss: read the file bytes and call ocr-service.
    let bytes = std::fs::read(&storage_path)
        .map_err(|e| ApiError::internal(format!("failed to read stored document: {e}")))?;

    let ocr_url = state
        .config
        .ocr_service_url
        .clone()
        .ok_or_else(|| ApiError::internal("ocr-service not configured (OCR_SERVICE_URL unset)"))?;

    let client = reqwest::Client::new();
    let part = reqwest::multipart::Part::bytes(bytes)
        .file_name("document")
        .mime_str("application/octet-stream")
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let form = reqwest::multipart::Form::new().part("file", part);

    let resp = client
        .post(format!("{ocr_url}/extract"))
        .multipart(form)
        .timeout(std::time::Duration::from_secs(300))
        .send()
        .await
        .map_err(|e| ApiError::internal(format!("ocr-service unreachable: {e}")))?;

    let status = resp.status();
    if status != StatusCode::OK {
        // Fail closed: an OCR error must not yield text we treat as complete.
        return Err(ApiError::internal(format!(
            "ocr-service returned {status}; extraction is incomplete, document stays pending"
        )));
    }

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| ApiError::internal(format!("ocr-service returned invalid JSON: {e}")))?;

    let incomplete = body.get("incomplete").and_then(|v| v.as_bool()).unwrap_or(true);
    let text = body
        .get("text")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let pages = body.get("pages").and_then(|v| v.as_u64()).unwrap_or(0) as u32;

    let mut spans: Vec<ExtractedSpan> = Vec::new();
    if let Some(arr) = body.get("spans").and_then(|v| v.as_array()) {
        for s in arr {
            spans.push(ExtractedSpan {
                page: s.get("page").and_then(|v| v.as_u64()).map(|p| p as u32),
                x: s.get("x").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                y: s.get("y").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                width: s.get("width").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                height: s.get("height").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                text: s.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            });
        }
    }

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

/// Persist spans. `label`/`confidence` are written as NULL here: labelling
/// happens when a sanitizer job runs, not at extraction time.
async fn persist_extraction(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
    version: i32,
    spans: &[ExtractedSpan],
) -> Result<(), ApiError> {
    for s in spans {
        sqlx::query(
            "INSERT INTO document_spans \
             (tenant_id, matter_id, document_id, document_version, page, x, y, width, height, text) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        )
        .bind(tenant_id.0)
        .bind(matter_id.0)
        .bind(document_id.0)
        .bind(version)
        .bind(s.page.map(|p| p as i32))
        .bind(s.x)
        .bind(s.y)
        .bind(s.width)
        .bind(s.height)
        .bind(&s.text)
        .execute(&state.db)
        .await
        .map_err(|e| ApiError::internal(format!("failed to persist span: {e}")))?;
    }
    Ok(())
}

/// Ingest extracted text as pending chunks.
///
/// Deliberately does NOT mark sanitized: extraction and sanitization are two
/// separate capabilities (design section 2), and the verifier only promotes
/// rows after a job completes.
async fn ingest_text_pending(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
    text: &str,
) -> Result<(), ApiError> {
    let ingestor = pacgate_rag::ChunkIngestor::new(
        state.db.clone(),
        state.embedding.clone(),
    );
    ingestor
        .ingest_document(
            tenant_id,
            matter_id,
            document_id,
            text,
            Some(pacgate_core::Jurisdiction::ChinaMainland),
            pacgate_core::SourceLevel::AuxiliaryDB,
            DataLevel::T3ProjectSpecific,
        )
        .await
        .map_err(|e| ApiError::internal(format!("failed to ingest extracted text: {e}")))?;
    Ok(())
}

/// Load the text half of a cached extraction from kb_chunks.
async fn load_cached_text(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
) -> Result<String, ApiError> {
    let rows = sqlx::query(
        "SELECT content FROM kb_chunks WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 ORDER BY chunk_index",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .bind(document_id.0)
    .fetch_all(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(rows
        .iter()
        .map(|r| r.get::<String, _>("content"))
        .collect::<Vec<_>>()
        .join("\n"))
}
```

- [ ] **Step 3: Register the module and config**

In `pacgate-ai/crates/pacgate-api/src/lib.rs`, add `pub mod extract;` alongside the other modules. In `state.rs`, find the `config` struct and add:

```rust
    /// Base URL of ocr-service, e.g. http://ocr-service:8100. None disables
    /// extraction (fail closed: extract_document errors rather than guessing).
    pub ocr_service_url: Option<String>,
```

and populate it in the config loader from `OCR_SERVICE_URL` (follow the existing pattern for `max_upload_mb`).

- [ ] **Step 4: Verify signature compatibility**

`ChunkIngestor::ingest_document` has a specific parameter order. Confirm before compiling:

```
Select-String -Path pacgate-ai/crates/pacgate-rag/src/ingest.rs -Pattern "pub async fn ingest_document" -Context 0,10
```

Adjust the call in `ingest_text_pending` to the real parameter order - the plan above shows the expected shape, not a verified one.

- [ ] **Step 5: Compile**

```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" check -p pacgate-api
```
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add pacgate-ai/crates/pacgate-api
git commit -m "feat(api): add cache-first OCR extraction client persisting spans and pending chunks"
```

---

### Task 4: Extraction HTTP route (fail-closed)

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/lib.rs` (route), `matters.rs` (handler)

**Interfaces:**
- Produces: `POST /api/documents/:id/extract` (protected) returning the `ExtractedDocument` JSON. On any OCR failure the API returns 500 and the document stays `pending` - there is no code path where a failed extraction yields retrievable text.

- [ ] **Step 1: Add the handler to matters.rs**

```rust
pub async fn extract_document_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id): Path<String>,
) -> Result<Json<crate::extract::ExtractedDocument>, ApiError> {
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;

    // The document's matter scopes the call; fetch it to enforce the tenant
    // boundary before extracting.
    let doc = fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;
    let extracted =
        crate::extract::extract_document(&state, &tenant_id, &doc.matter_id, &document_id).await?;
    Ok(Json(extracted))
}
```

- [ ] **Step 2: Wire the route**

In `lib.rs`, in the `protected` router, next to the other document routes:

```rust
.route("/api/documents/:id/extract", post(documents_extract))
```

with the import adjusted to wherever the handler lands. Compile with `cargo check -p pacgate-api`, then commit:

```bash
git add pacgate-ai/crates/pacgate-api
git commit -m "feat(api): add fail-closed POST /api/documents/:id/extract route"
```

---

### Task 5: End-to-end OCR proof

**Files:**
- Create: `scripts/test-ocr-extraction.ps1`

**Interfaces:**
- Consumes: Tasks 2-4.
- Produces: an executable proof that a scanned image with a known 身份证-shaped string comes back as text + one span with coordinates, persisted to `document_spans`.

- [ ] **Step 1: Create the test fixture and script**

Create `scripts/test-ocr-extraction.ps1` that:
1. Builds a tiny PNG containing the text `身份证 11010519491231002X` (Pillow, in the ocr-service container so no host dependency).
2. Starts `ocr-service:local` + posts it to `/extract`.
3. Asserts `incomplete == false`, `text` contains `110105`, and `spans` has at least 1 element with page 1 and non-negative coordinates.
4. Cleans up.

- [ ] **Step 2: Run it and record the result**

The script must print PASS/FAIL per assertion and exit non-zero on failure. Commit the script plus a note in `deploy/README-BUILD.md` describing how to run the proof locally.

```bash
git add scripts/test-ocr-extraction.ps1 deploy/README-BUILD.md
git commit -m "test(ocr): prove extraction returns text plus span coordinates end to end"
```

---

## Part 3b - Tier 2-4 NER

### Task 6: NER detector behind the existing Detector trait

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/detect/ner.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/detect/mod.rs`, `Cargo.toml`

**Interfaces:**
- Consumes: `Detector` trait (plan 017 Task 4).
- Produces:
  - `pub struct NerDetector { /* model handle */ }` implementing `Detector` with `name() == "ner-zh"`
  - `pub fn ner_detector(model_dir: &str) -> RedactResult<Box<dyn Detector>>` - loads `bert-base-chinese-ner` from a local directory via Candle; errors loudly if the model is missing (fail closed: no silent degradation to rules-only).
  - Only maps labels `PER`, `ORG`, `LOC` to `EntityType::PersonName` / `OrgName` / `Location`. Credentials and accounts stay rule+context territory; a model guess is never authoritative for those.

- [ ] **Step 1: Add workspace deps**

In `pacgate-ai/Cargo.toml` `[workspace.dependencies]`:

```toml
candle-core = "0.9"
candle-transformers = "0.9"
tokenizers = "0.21"
hf-hub = "0.3"
```

(`hf-hub` is already present; verify before adding. Add to `pacgate-redact/Cargo.toml` as `.workspace = true` and under `[features]` nothing - keep it simple.)

- [ ] **Step 2: Write ner.rs**

Implementation shape (full code to be written in the executing session against the candle-transformers BERT API of the pinned version; the contract is what matters here):

```rust
//! Local Chinese NER via bert-base-chinese-ner over Candle.
//!
//! Additive by design: the deterministic rules run first (plan 017 Task 4),
//! and this detector contributes candidates the rules cannot see - person,
//! org and location names. Model output is NEVER authoritative on its own:
//! the verifier replays the combined set, and the noise filter still drops
//! overlaps in favour of the longer, checksum-anchored spans.

use crate::detect::Detector;
use crate::{EntityType, Match, MatchSource, RedactError, RedactResult};

pub struct NerDetector {
    // candle model + tokenizer handles (typed in the executing session)
}

impl NerDetector {
    pub fn load(model_dir: &str) -> RedactResult<Self> {
        // Fail closed: a missing model dir is an error, not a silent skip.
        if !std::path::Path::new(model_dir).exists() {
            return Err(RedactError::Internal(format!(
                "NER model directory not found: {model_dir}"
            )));
        }
        // TODO(executing session): load safetensors + tokenizer via
        // candle-transformers::models::bert. Pin the model files in
        // deploy/client-bundle so AIPC installs do not download at runtime.
        unimplemented!("filled in executing session against pinned candle API")
    }
}

impl Detector for NerDetector {
    fn name(&self) -> &'static str {
        "ner-zh"
    }

    fn detect(&self, _text: &str) -> RedactResult<Vec<Match>> {
        // TODO(executing session): tokenise, run, map PER/ORG/LOC spans to
        // byte offsets, emit Matches with source = MatchSource::Model and
        // confidence from the model.
        unimplemented!("filled in executing session")
    }
}
```

**This task is explicitly marked as requiring the executing session** because the Candle BERT API is version-sensitive; the contract above (trait conformance, fail-closed load, PER/ORG/LOC-only mapping, `MatchSource::Model`) is the stable part.

- [ ] **Step 3: Register in the detector set**

In `detect/mod.rs`, extend `tier_one_detectors()` OR add `pub fn full_detectors(model_dir: &str) -> RedactResult<Vec<Box<dyn Detector>>>` returning rules + NER. Prefer the latter: Tier-1-only stays available for tests without a model.

- [ ] **Step 4: Model fixture test**

A test that skips when the model directory is absent (`if !Path::new(dir).exists() { eprintln!("skipping: no model"); return; }`) so CI without the model stays green, plus one that runs when it is present asserting a person name in a synthetic sentence produces a `PersonName` match.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact pacgate-ai/Cargo.toml
git commit -m "feat(redact): add local Chinese NER detector for Tier 2-4 candidates"
```

---

### Task 7: Recall reporting per tier (the spec's layer-separated rule)

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/tests/recall.rs`

**Interfaces:**
- Produces: `tests/recall.rs` asserting, per tier, that every synthetic fixture is caught when the detector set is `full_detectors` (with model) and that Tier-1 fixtures are caught with rules only.

- [ ] **Step 1: Write the recall harness**

```rust
//! Per-tier recall reporting (spec section 9: 不能相互替代).
//!
//! Rule-layer row  : Tier-1 fixtures caught by rules only.
//! Model-layer row : Tier-2 fixtures (person/org names) caught by NER.
//! These are separate assertions on purpose - one does not substitute the other.

use pacgate_redact::detect::tier_one_detectors;
use pacgate_redact::{MappingVersion, Sanitizer, Tier, EntityType};
use pacgate_core::DataLevel;

fn run(text: &str) -> pacgate_redact::SanitizeOutcome {
    Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT)
        .sanitize(text, DataLevel::T3ProjectSpecific)
        .unwrap()
}

#[test]
fn rule_layer_tier_one_recall() {
    let fixtures = [
        ("11010519491231002X", EntityType::CnResidentId),
        ("13812345678", EntityType::CnMobile),
        ("4111111111111111", EntityType::BankCard),
        ("a@b.com", EntityType::Email),
    ];
    for (value, entity) in fixtures {
        let out = run(value);
        assert!(!out.text.contains(value), "Tier-1 miss ({entity:?}): {value}");
    }
}

#[test]
fn model_layer_tier_two_recall() {
    // Skips without the model; runs with it. The skip is loud, not silent.
    let model_dir = std::env::var("PACGATE_NER_MODEL_DIR").unwrap_or_default();
    if model_dir.is_empty() || !std::path::Path::new(&model_dir).exists() {
        eprintln!("SKIP model_layer_tier_two_recall: PACGATE_NER_MODEL_DIR not set or missing");
        return;
    }
    // With the model: full detector set must catch a person name.
    // (Executed in the session that owns Task 6's real implementation.)
}
```

- [ ] **Step 2: Run and commit**

```bash
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --test recall
git add pacgate-ai/crates/pacgate-redact/tests/recall.rs
git commit -m "test(redact): add per-tier recall harness separating rule and model layers"
```

---

## Follow-on work

| Step | Content | Blocked on |
|---|---|---|
| **019 (this)** | ocr-service + spans + Tier 2-4 NER | - |
| 020 (Step 4) | vault, MCP tools, restore endpoint (role + job scope + audit per decision 2), mark_sanitized wiring after ledger seal | this plan |
| 021 (Step 5) | deer-flow sanitizer agent + review panel (spans feed the panel view) | 019 + 020 |

**The ordering rule 020 must not break:** seal the ledger FIRST, then call `mark_sanitized`. A promoted chunk with no ledger row claims sanitization with no evidence.

## Known limitations

- **PDF handling in 3a is image-only.** Born-digital PDFs (text layer) are better served by markitdown (already integrated); ocr-service rasterises and OCRs everything. A format dispatcher (born-digital vs scanned) is Step 4/5 territory - until then, callers should prefer markitdown for text PDFs and ocr-service for scans.
- **No GPU image variant yet.** `OCR_USE_GPU=0` is the default; a CUDA base image can be added when measured throughput demands it.
- **NER model distribution is unresolved.** The model must be pinned into the client bundle (no runtime downloads on AIPC). Size (~400MB) and licensing of bert-base-chinese-ner need checking in the executing session.
- **`incomplete` handling on partial-page extraction** follows the page list; a PDF that fails at page 50 of 100 sets the flag but pages 1-49 are still persisted. The document stays `pending` overall (fail closed), but the flag semantics should be revisited if partial results become useful.