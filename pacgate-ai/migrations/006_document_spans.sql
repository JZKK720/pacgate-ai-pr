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
    label           TEXT,
    confidence      REAL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_document_spans_doc
    ON document_spans (tenant_id, matter_id, document_id, document_version);
CREATE INDEX IF NOT EXISTS idx_document_spans_page
    ON document_spans (tenant_id, document_id, page);